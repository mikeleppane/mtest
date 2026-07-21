#!/usr/bin/env python3
"""Validate a JUnit XML artifact against the vendored junit-10 schema plus the
arithmetic and structural invariants the schema cannot express.

`xmllint --schema junit-10.xsd --noout` enforces structure and required
attributes — `flakyFailure`'s `type` chief among them — over the shipped
artifact directly. It does not, however, check that declared counts agree
with the rows that carry them: `tests`/`failures`/`errors`/`skipped` are all
`xs:string` in junit-10, so any digits validate. junit-10 also defines no
`skipped` attribute on the `<testsuites>` root at all, so the root-level
skipped total can only ever be an arithmetic fact, recomputed from the child
`<testsuite>` elements, never a schema-checked attribute.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import subprocess
import sys
from xml.etree import ElementTree as ET


ROOT = Path(__file__).resolve().parents[3]
SCHEMA = ROOT / "scripts" / "schemas" / "junit-10.xsd"
DEFAULT_ARTIFACT = ROOT / "scripts" / "fixtures" / "junit" / "mock.xml"
_BUILD_SENTINEL = "[build]"
_ATTEMPTS_SENTINEL = "[attempts]"
# A testcase's direct child element names that carry an outcome, mapped to the
# <testsuite> aggregate attribute each one counts against. A testcase with
# none of these children (including a bare sentinel row, or one that carries
# only flakyFailure/rerunFailure/rerunError/flakyError) counts as a passing row.
_OUTCOME_ATTRIBUTE = {"failure": "failures", "error": "errors", "skipped": "skipped"}


class CheckFailure(RuntimeError):
    """One schema, arithmetic, or structural violation."""


def run_xmllint(
    artifact: Path, schema: Path = SCHEMA
) -> subprocess.CompletedProcess[str]:
    """Run the vendored junit-10 schema over `artifact` with `--noout`."""
    return subprocess.run(
        ["xmllint", "--schema", str(schema), "--noout", str(artifact)],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def validate_schema(artifact: Path, schema: Path = SCHEMA) -> None:
    """Raise CheckFailure if `artifact` does not validate against `schema`."""
    result = run_xmllint(artifact, schema)
    if result.returncode != 0:
        raise CheckFailure(
            f"schema validation failed for {artifact}:\n{result.stdout.strip()}"
        )


def _int_attr(element: ET.Element, name: str) -> int:
    raw = element.get(name)
    if raw is None:
        return 0
    try:
        return int(raw)
    except ValueError as exc:
        raise CheckFailure(
            f"attribute {name!r}={raw!r} on <{element.tag}> is not an integer"
        ) from exc


def _outcome_attribute(testcase: ET.Element) -> str | None:
    """Return the aggregate attribute this testcase's outcome counts against."""
    for child in testcase:
        attribute = _OUTCOME_ATTRIBUTE.get(child.tag)
        if attribute is not None:
            return attribute
    return None


@dataclass(frozen=True)
class SuiteTotals:
    """One <testsuite>'s tests/failures/errors/skipped counts."""

    tests: int
    failures: int
    errors: int
    skipped: int


def suite_arithmetic(suite: ET.Element) -> tuple[SuiteTotals, list[str]]:
    """Recompute one <testsuite>'s totals from its <testcase> rows.

    `tests` must equal the number of passing rows plus failures plus errors
    plus skipped, counting every <testcase> row including sentinel rows like
    `[build]`/`[attempts]`/`[not-run]`/`[output]`. Also enforces that at most
    one of the outcome-carrying sentinels `[build]`/`[attempts]` appears per
    suite.
    """
    name = suite.get("name", "<unnamed>")
    testcases = [child for child in suite if child.tag == "testcase"]
    counted = {"failures": 0, "errors": 0, "skipped": 0}
    for testcase in testcases:
        attribute = _outcome_attribute(testcase)
        if attribute is not None:
            counted[attribute] += 1
    recomputed = SuiteTotals(
        tests=len(testcases),
        failures=counted["failures"],
        errors=counted["errors"],
        skipped=counted["skipped"],
    )
    declared = SuiteTotals(
        tests=_int_attr(suite, "tests"),
        failures=_int_attr(suite, "failures"),
        errors=_int_attr(suite, "errors"),
        skipped=_int_attr(suite, "skipped"),
    )

    findings: list[str] = []
    if declared != recomputed:
        findings.append(
            f"suite {name!r}: declared {declared} != recomputed {recomputed} "
            "(tests must equal passing rows + failures + errors + skipped, "
            "counting sentinel rows)"
        )

    sentinel_names = {testcase.get("name") for testcase in testcases}
    if _BUILD_SENTINEL in sentinel_names and _ATTEMPTS_SENTINEL in sentinel_names:
        findings.append(
            f"suite {name!r}: both {_BUILD_SENTINEL} and {_ATTEMPTS_SENTINEL} "
            "sentinels present (at most one outcome-carrying sentinel per suite)"
        )

    return recomputed, findings


def root_arithmetic(root: ET.Element) -> tuple[SuiteTotals, list[str]]:
    """Recompute the <testsuites> root totals from its child <testsuite>s.

    Returns the summed totals (the root-level skipped total lives here, since
    junit-10 defines no `skipped` attribute on <testsuites> at all) plus any
    findings: a mismatch against the declared root attributes, or the root
    attribute being present in the first place.
    """
    findings: list[str] = []
    suite_totals: list[SuiteTotals] = []
    for suite in root:
        if suite.tag != "testsuite":
            continue
        totals, suite_findings = suite_arithmetic(suite)
        suite_totals.append(totals)
        findings.extend(suite_findings)

    summed = SuiteTotals(
        tests=sum(totals.tests for totals in suite_totals),
        failures=sum(totals.failures for totals in suite_totals),
        errors=sum(totals.errors for totals in suite_totals),
        skipped=sum(totals.skipped for totals in suite_totals),
    )

    if root.get("skipped") is not None:
        findings.append(
            "root <testsuites> must not carry a `skipped` attribute "
            "(junit-10 defines none; the root skipped total is arithmetic only)"
        )
    for attribute in ("tests", "failures", "errors"):
        declared_value = _int_attr(root, attribute)
        summed_value = getattr(summed, attribute)
        if declared_value != summed_value:
            findings.append(
                f"root {attribute}={declared_value} != sum of suites {summed_value}"
            )

    return summed, findings


def validate_arithmetic(artifact: Path) -> SuiteTotals:
    """Parse `artifact` and enforce every arithmetic/structural invariant."""
    tree = ET.parse(artifact)
    root = tree.getroot()
    if root.tag != "testsuites":
        raise CheckFailure(
            f"{artifact}: root element is <{root.tag}>, expected <testsuites>"
        )
    summed, findings = root_arithmetic(root)
    if findings:
        raise CheckFailure(f"{artifact}: " + "; ".join(findings))
    return summed


def check_artifact(artifact: Path, schema: Path = SCHEMA) -> SuiteTotals:
    """Run the schema gate, then the arithmetic/structural gate, in order."""
    validate_schema(artifact, schema)
    return validate_arithmetic(artifact)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "artifact",
        nargs="?",
        type=Path,
        default=DEFAULT_ARTIFACT,
        help="JUnit XML artifact to validate (default: the committed mock fixture)",
    )
    parser.add_argument("--schema", type=Path, default=SCHEMA)
    args = parser.parse_args()

    try:
        summed = check_artifact(args.artifact, args.schema)
    except CheckFailure as exc:
        print(f"junit-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print(
        f"junit-check: OK: {args.artifact} "
        f"(tests={summed.tests} failures={summed.failures} "
        f"errors={summed.errors} skipped={summed.skipped})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
