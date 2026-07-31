#!/usr/bin/env python3
"""Prove the local and modular-community recipes share one package contract.

Also validates both recipes against the vendored `recipe-format` schema.
modular-community's own `pixi run lint` appears to schema-check submissions but
does not: its hook selects `^[^/]+/recipe.yaml$`, which cannot match the
`recipes/<package>/recipe.yaml` path every recipe in that channel actually
lives at, so the hook reports "no files to check" and skips. This check owns
that verdict here instead of inheriting a gate that never fires.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from scripts.release.public_verify import COMPANION_FILES
from scripts.release.recipe import RenderRequest, render_recipe


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA = REPO_ROOT / "scripts" / "schemas" / "recipe-format.schema.json"
ZERO_SHA = "0" * 40
# Forty digits is a YAML integer, not a string, so the all-zero drift probe
# above cannot exercise the schema's `source[].rev: string` requirement. Real
# commit SHAs are hex and effectively never all-digit; this probe carries a
# letter so the schema check sees the shape a real render produces.
SCHEMA_PROBE_SHA = "a" + "0" * 39


@dataclass(frozen=True)
class SharedRecipeFacts:
    """Package facts that must match across both recipe formats."""

    name: str
    version: str
    build_number: int
    packaged_files: tuple[str, ...]
    build_requirements: tuple[str, ...]
    host_requirements: tuple[str, ...]
    run_requirements: tuple[str, ...]
    license: str
    license_file: str
    homepage: str


def _one(text: str, pattern: str, label: str) -> str:
    matches = re.findall(pattern, text, re.MULTILINE)
    if len(matches) != 1:
        raise AssertionError(f"{label} must appear exactly once; matches={matches!r}")
    return str(matches[0])


def _indented_list(text: str, key: str, label: str) -> tuple[str, ...]:
    block = _one(text, rf"^  {key}:\n((?:    - .+\n)+)", label)
    return tuple(
        line.removeprefix("    - ") for line in block.rstrip("\n").splitlines()
    )


def _facts(text: str) -> SharedRecipeFacts:
    return SharedRecipeFacts(
        name=_one(text, r"^  name: ([^\n]+)$", "package name"),
        version=_one(text, r'^  version: "([^"]+)"$', "context version"),
        build_number=int(_one(text, r"^  number: ([0-9]+)$", "build number")),
        packaged_files=_indented_list(text, "files", "packaged files"),
        build_requirements=_indented_list(text, "build", "build requirements"),
        host_requirements=_indented_list(text, "host", "host requirements"),
        run_requirements=_indented_list(text, "run", "run requirements"),
        license=_one(text, r"^  license: ([^\n]+)$", "license"),
        license_file=_one(text, r"^  license_file: ([^\n]+)$", "license file"),
        homepage=_one(text, r"^  homepage: ([^\n]+)$", "homepage"),
    )


def validate_recipe_schema(recipe: str, label: str, schema: Path = SCHEMA) -> None:
    """Validate one recipe document against the vendored recipe-format schema.

    Args:
        recipe: Recipe YAML text to validate.
        label: Name identifying the document in a failure message.
        schema: Vendored JSON Schema to validate against.

    Raises:
        AssertionError: If `check-jsonschema` rejects the document.
    """
    with tempfile.TemporaryDirectory() as scratch:
        staged = Path(scratch) / "recipe.yaml"
        staged.write_text(recipe, encoding="utf-8")
        result = subprocess.run(
            ["check-jsonschema", "--schemafile", str(schema), str(staged)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    if result.returncode != 0:
        raise AssertionError(
            f"{label} does not validate against {schema.name}:\n{result.stdout}"
        )


def check_recipe_schemas(local_recipe: Path, community_template: Path) -> None:
    """Validate both recipe sources against the vendored recipe-format schema."""
    local = local_recipe.read_text(encoding="utf-8")
    validate_recipe_schema(local, "local recipe")
    rendered = render_recipe(
        community_template.read_bytes(),
        RenderRequest(
            version=_one(local, r'^  version: "([^"]+)"$', "local version"),
            source_rev=SCHEMA_PROBE_SHA,
            build_number=0,
        ),
    ).decode("utf-8")
    validate_recipe_schema(rendered, "community recipe")


def check_recipe_drift(local_recipe: Path, community_template: Path) -> None:
    """Reject shared-package or community-submission semantic drift."""
    local = local_recipe.read_text(encoding="utf-8")
    local_version = _one(local, r'^  version: "([^"]+)"$', "local version")
    rendered = render_recipe(
        community_template.read_bytes(),
        RenderRequest(
            version=local_version,
            source_rev=ZERO_SHA,
            build_number=0,
        ),
    ).decode("utf-8")
    local_facts = _facts(local)
    community_facts = _facts(rendered)
    if local_facts != community_facts:
        raise AssertionError(
            "local/community shared recipe drift: "
            f"local={local_facts!r}, community={community_facts!r}"
        )

    if _one(local, r"^schema_version: ([0-9]+)$", "local schema version") != "1":
        raise AssertionError("local recipe must use schema_version 1")
    if _one(local, r"^  - path: ([^\n]+)$", "local source path") != "..":
        raise AssertionError("local recipe source must remain path: ..")
    if re.search(r"^schema_version:", rendered, re.MULTILINE):
        raise AssertionError("community recipe must omit schema_version")

    exact_community_lines = (
        "  - git: https://github.com/mikeleppane/mtest.git",
        f"    rev: {ZERO_SHA}",
        "    - linux and aarch64",
        "        bash recipe/build.sh",
        '          test "$(mtest --version)" = "mtest ${{ version }}"',
        "          mtest --help >/dev/null",
        "          mtest --no-config test_smoke.mojo",
        "  repository: https://github.com/mikeleppane/mtest",
        "  project_name: mtest",
        # `maintainers`, not conda-forge's `recipe-maintainers`: this is the key
        # the Mojo packaging guide's template uses and the one 34 of the 38
        # recipes already in modular-community carry.
        "  maintainers:",
        "    - mikeleppane",
    )
    for line in exact_community_lines:
        if rendered.splitlines().count(line) != 1:
            raise AssertionError(
                f"community recipe contract line must appear once: {line!r}"
            )
    for relative in COMPANION_FILES:
        if rendered.count(relative) != 2:
            raise AssertionError(
                f"community recipe must check and inventory {relative!r} exactly"
            )


def main() -> int:
    """Check the repository's two recipe sources."""
    local = REPO_ROOT / "recipe" / "recipe.yaml"
    community = REPO_ROOT / "recipe" / "community" / "recipe.yaml.in"
    try:
        check_recipe_drift(local, community)
        check_recipe_schemas(local, community)
    except (AssertionError, OSError, UnicodeError, ValueError) as exc:
        print(f"community-recipe-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print("community-recipe-check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
