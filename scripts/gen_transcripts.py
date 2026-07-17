#!/usr/bin/env python3
"""Generate protocol snapshots by running the committed fixtures.

The toolchain IS the oracle. For every scenario in the matrix below this script
builds the fixture, runs the binary with the scenario's arguments, captures
stdout and stderr SEPARATELY and byte-exactly, records the termination
structurally (exit code vs terminating signal — never the shell 128+N
encoding), applies an ANCHORED, versioned normalization, and writes a
line-oriented transcript with a provenance header. It then HARD-ASSERTS a set of
structural pins and regenerates the whole matrix a second time to prove the
output is byte-identical.

Determinism is the whole point: a transcript must be identical across
regenerations and across machines, or `transcripts-check` is noise instead of a
protocol pin. The only content rewrites applied to captured output are (1) the
repo-root absolute prefix -> <REPO> (the compiler bakes absolute source paths),
(2) timing tokens -> [ T ] on report-grammar lines WITHIN the report block only,
and (3) collapsing a crash stack dump to <STACK-DUMP>. Everything else is
captured verbatim.

Usage:
    python scripts/gen_transcripts.py              # write into tests/snapshots/protocol/
    python scripts/gen_transcripts.py --out DIR    # write into DIR (check harness)
"""
from __future__ import annotations

import argparse
import os
import platform
import re
import subprocess
import sys
import tempfile

NORMALIZER_VERSION = "v1"
REPO_ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
FIXTURES_DIR = os.path.join(REPO_ROOT, "tests", "fixtures", "protocol")

# --- The scenario matrix -----------------------------------------------------
# (scenario_id, fixture, argv). The transcript filename is
# "<fixture>--<scenario_id>.txt". This table is the single source of truth; the
# generator asserts the emitted MANIFEST equals it exactly.
MATRIX = [
    ("default", "passing", []),
    ("default", "mixed", []),
    ("default", "empty", []),
    ("default", "crashing", []),
    ("default", "segfault", []),
    ("default", "noisy", []),
    ("default", "twofail", []),
    ("default", "raising", []),
    ("skip-all", "passing", ["--skip-all"]),
    ("skip-all", "empty", ["--skip-all"]),
    ("only-selected-fail", "mixed", ["--only", "test_second_fails"]),
    ("only-many", "passing", ["--only", "test_zeta_passes", "test_mid_passes"]),
    ("only-unknown", "passing", ["--only", "test_missing"]),
    ("only-noargs", "passing", ["--only"]),
    ("skip-one", "mixed", ["--skip", "test_second_fails"]),
    ("skip-unknown", "passing", ["--skip", "test_missing"]),
    ("flag-unknown", "passing", ["--bogus-flag"]),
    ("no-compose", "passing", ["--only", "test_zeta_passes", "--skip", "test_alpha_passes"]),
    ("skip-all-args", "passing", ["--skip-all", "--only", "x"]),
    # Conditional: only because 1.0.0b2's TestSuite exposes an in-code skip API.
    ("default", "skipped", []),
    ("skip-all", "skipped", ["--skip-all"]),
    ("only-native", "skipped", ["--only", "test_natively_skipped"]),
]

# Scenarios whose fixture crashes the process — their stderr carries a stack
# dump. `crashing` aborts (SIGILL + an ABORT line); `segfault` faults on an
# invalid load (SIGSEGV, no ABORT line). Both die by signal; the stderr of each
# is treated as a crash stream and collapsed to <STACK-DUMP>.
CRASH_FIXTURES = {"crashing", "segfault"}

# --- Normalization patterns --------------------------------------------------
RUNNING_RE = re.compile(r"^Running \d+ tests for ")
REPORT_LINE_RE = re.compile(r"^(    (?:PASS|FAIL|SKIP)) \[ [^\]]* \] (.*)$")
SUMMARY_RE = re.compile(r"^(Summary) \[ [^\]]* \] (.*)$")
STACK_HEADER_RE = re.compile(r"^Stack dump")
# A stack frame in EITHER form the runtime emits — the shape depends on whether
# llvm-symbolizer is on PATH, so both must collapse to the same <STACK-DUMP>:
#   symbol-less:  "<n>  <module> 0x<hex>"           (no header requires PATH)
#   symbolized:   "#<n> 0x<hex> <sym> <file>:<l>:<c>" (leaks binary + lib paths)
FRAME_RE = re.compile(r"^\d+\s+\S+\s+0x[0-9a-f]+|^\s*#\d+ 0x[0-9a-f]+")


class GenError(Exception):
    """A structural pin failed — generation aborts loudly, never silently."""


def toolchain() -> tuple[str, str]:
    out = subprocess.run(
        ["mojo", "--version"], check=True, capture_output=True, text=True
    ).stdout.strip()
    m = re.search(r"Mojo (\S+) \(([0-9a-f]+)\)", out)
    if not m:
        raise GenError(f"cannot parse mojo version from: {out!r}")
    return m.group(1), m.group(2)


def os_arch() -> str:
    return f"{platform.system().lower()}-{platform.machine()}"


def _normalize_timing(line: str) -> str:
    m = REPORT_LINE_RE.match(line)
    if m:
        return f"{m.group(1)} [ T ] {m.group(2)}"
    m = SUMMARY_RE.match(line)
    if m:
        return f"{m.group(1)} [ T ] {m.group(2)}"
    return line


def normalize(raw: bytes, *, is_crash_stream: bool) -> str:
    """Apply the anchored, versioned normalization to one captured stream."""
    text = raw.decode("utf-8", errors="surrogateescape")
    # (2) repo-root absolute prefix -> <REPO>. This is the ONLY rewrite applied
    # to captured content that touches paths; the compiler bakes the absolute
    # canonicalized source path into every location line.
    text = text.replace(REPO_ROOT, "<REPO>")

    had_trailing_nl = text.endswith("\n")
    core = text[:-1] if had_trailing_nl else text
    lines = core.split("\n") if core != "" else []

    # (3) Stack collapse — crash stderr only. Collapse the maximal trailing block
    # starting at the first `Stack dump` header (or a frame line) to a single
    # <STACK-DUMP>, HEADER INCLUDED: the header text varies with llvm-symbolizer
    # presence in PATH and must never reach a snapshot. Every line after the header
    # must match a frame pattern, or generation fails so the rule is extended
    # deliberately, never silently.
    if is_crash_stream:
        start = None
        for i, ln in enumerate(lines):
            if STACK_HEADER_RE.match(ln) or FRAME_RE.match(ln):
                start = i
                break
        if start is not None:
            header_is_stackdump = bool(STACK_HEADER_RE.match(lines[start]))
            body_start = start + 1 if header_is_stackdump else start
            for ln in lines[body_start:]:
                if not FRAME_RE.match(ln):
                    raise GenError(
                        "unrecognized line inside the stack-dump block "
                        f"(rule must be extended deliberately): {ln!r}"
                    )
            lines = lines[:start] + ["<STACK-DUMP>"]

    # (1) Timing tokens -> [ T ], ANCHORED: only on report-grammar lines at or
    # after the `Running <N> tests for` line that OPENS the real report block.
    # A real report always ends in a `Summary ` line, so the anchor is the last
    # `Running` line that is followed by a `Summary ` line. This matters on a
    # crash stream, where the report is LOST: a `Running`-lookalike a test prints
    # before aborting has no `Summary` after it, so it never becomes the anchor
    # and the lines a test printed stay byte-exact. Requiring the Summary is what
    # keeps "anchor on the last Running line" from over-normalizing user output.
    summary_idxs = [i for i, ln in enumerate(lines) if ln.startswith("Summary [ ")]
    if summary_idxs:
        last_summary = summary_idxs[-1]
        running_before = [
            i
            for i, ln in enumerate(lines)
            if RUNNING_RE.match(ln) and i < last_summary
        ]
        if running_before:
            anchor = running_before[-1]
            for i in range(anchor, len(lines)):
                lines[i] = _normalize_timing(lines[i])

    result = "\n".join(lines)
    if had_trailing_nl:
        result += "\n"
    return result


def termination(returncode: int) -> str:
    # Python reports death-by-signal as a negative returncode. Record the raw
    # signal number, structurally — never the shell-encoded 128+N.
    if returncode < 0:
        return f"signal {-returncode}"
    return f"exit {returncode}"


def build_fixture(fixture: str, out_dir: str) -> str:
    src = os.path.join(FIXTURES_DIR, f"{fixture}.mojo")
    binpath = os.path.join(out_dir, fixture)
    subprocess.run(
        ["mojo", "build", "--no-optimization", src, "-o", binpath],
        check=True,
        capture_output=True,
    )
    return binpath


def run_scenario(binpath: str, argv: list[str]) -> tuple[bytes, bytes, int]:
    proc = subprocess.run([binpath] + argv, capture_output=True)
    return proc.stdout, proc.stderr, proc.returncode


def render(
    fixture: str,
    scenario: str,
    argv: list[str],
    ver: str,
    commit: str,
    oa: str,
    out_norm: str,
    err_norm: str,
    returncode: int,
) -> str:
    cmd = "<BIN>" + ("" if not argv else " " + " ".join(argv))
    header = (
        f"# generated by scripts/gen_transcripts.py — mojo {ver} ({commit}), "
        f"{oa}, normalizer {NORMALIZER_VERSION}, fixture {fixture}.mojo, "
        f"scenario {scenario} — do not hand-edit"
    )
    body = header + "\n" + f"cmd: {cmd}\n" + f"termination: {termination(returncode)}\n"
    body += "--- stdout ---\n"
    body += out_norm
    if out_norm and not out_norm.endswith("\n"):
        body += "\n"
    body += "--- stderr ---\n"
    body += err_norm
    if err_norm and not err_norm.endswith("\n"):
        body += "\n"
    return body


# --- Structural self-verification (hard asserts) -----------------------------
def _report_result_lines(out_norm: str) -> list[tuple[str, str]]:
    """Return (result, name) for each per-test line in the report block."""
    lines = out_norm.split("\n")
    anchors = [i for i, ln in enumerate(lines) if RUNNING_RE.match(ln)]
    if not anchors:
        return []
    res = []
    for ln in lines[anchors[-1] :]:
        m = re.match(r"^    (PASS|FAIL|SKIP) \[ T \] (\S+)$", ln)
        if m:
            res.append((m.group(1), m.group(2)))
    return res


def verify_scenario(fixture, scenario, out_norm, err_norm, returncode, transcript):
    # Framing guard: captured output must never contain a line starting "--- ",
    # which would collide with the section markers.
    for stream_name, stream in (("stdout", out_norm), ("stderr", err_norm)):
        for ln in stream.split("\n"):
            if ln.startswith("--- "):
                raise GenError(
                    f"{fixture}--{scenario}: captured {stream_name} contains a "
                    f"section-marker-lookalike line: {ln!r}"
                )

    # No absolute path may survive into a normalized transcript.
    for needle in (REPO_ROOT, "llvm-symbolizer", "Stack dump"):
        if needle in transcript:
            raise GenError(
                f"{fixture}--{scenario}: normalized transcript still contains "
                f"{needle!r} — a path or symbolizer-dependent line leaked"
            )

    # Crash scenarios must terminate by signal.
    if fixture in CRASH_FIXTURES:
        if returncode >= 0:
            raise GenError(
                f"{fixture}--{scenario}: expected death by signal, got exit "
                f"{returncode}"
            )
        # An ABORT line is NOT universal to crashes: a controlled abort() emits
        # one, a raw segfault emits none. So the pin is two-part.
        # (a) If ANY ABORT line appears on stdout it must be well-formed —
        # normalized to the <REPO>-rewritten fixture-path shape, never leaking
        # an absolute path. This holds for every crash fixture.
        for ln in out_norm.split("\n"):
            if ln.startswith("ABORT:") and not ln.startswith(
                "ABORT: <REPO>/tests/fixtures/protocol/"
            ):
                raise GenError(
                    f"{fixture}--{scenario}: ABORT line present but not "
                    f"normalized to the <REPO> fixture-path shape: {ln!r}"
                )
        # (b) A fixture that aborts() MUST still emit its ABORT line — without it
        # the crash pin has nothing to anchor on. Scoped to `crashing`, the only
        # fixture that aborts; a segfault fixture is exempt by design.
        if fixture == "crashing" and (
            "ABORT: <REPO>/tests/fixtures/protocol/" not in out_norm
        ):
            raise GenError(
                f"{fixture}--{scenario}: ABORT line did not survive normalization"
            )

    # skip-all collection: the SKIP listing equals the fixture's test names.
    if scenario == "skip-all" and fixture == "passing":
        names = [n for (r, n) in _report_result_lines(out_norm) if r == "SKIP"]
        expected = ["test_zeta_passes", "test_alpha_passes", "test_mid_passes"]
        if names != expected:
            raise GenError(
                f"skip-all listing {names} != fixture test names {expected}"
            )

    # native-skip skip-all collection: BOTH names are listed as SKIP, in source
    # (discovery) order — pins that a natively skipped test is not omitted or
    # reordered by --skip-all.
    if scenario == "skip-all" and fixture == "skipped":
        names = [n for (r, n) in _report_result_lines(out_norm) if r == "SKIP"]
        expected = ["test_runs_normally", "test_natively_skipped"]
        if names != expected:
            raise GenError(
                f"skip-all listing {names} != fixture test names {expected}"
            )

    # native-skip survives explicit selection: --only the natively-skipped test
    # still reports it as SKIP, not PASS — the native skip is not overridden by
    # being explicitly named. The OTHER (unselected) test also reports SKIP —
    # that is the ordinary selection-induced SKIP --only already gives every
    # unselected test (see e.g. skipped--only-native's sibling behavior in
    # mixed--skip-one.txt) — so both rows are SKIP, for two different reasons,
    # and a bare row list cannot distinguish them; that ambiguity is exactly
    # what downstream reconciliation must resolve.
    if scenario == "only-native" and fixture == "skipped":
        rows = _report_result_lines(out_norm)
        expected_rows = [
            ("SKIP", "test_runs_normally"),
            ("SKIP", "test_natively_skipped"),
        ]
        if rows != expected_rows:
            raise GenError(
                f"only-native rows {rows} != expected {expected_rows}"
            )

    # noisy: the report-lookalike and timing-lookalike user lines must survive
    # byte-exact (NOT normalized to [ T ]).
    if fixture == "noisy" and scenario == "default":
        if "    PASS [ 0.001 ] fake_impostor\n" not in out_norm:
            raise GenError("noisy: report-lookalike user line was altered")
        if "[ 0.001 ] mid-sentence" not in out_norm:
            raise GenError("noisy: timing-lookalike user line was altered")

    # Every report must reconcile: declared count == rows == summary tallies.
    rows = _report_result_lines(out_norm)
    if rows:
        lines = out_norm.split("\n")
        run_line = [ln for ln in lines if RUNNING_RE.match(ln)][-1]
        declared = int(re.match(r"^Running (\d+) tests for ", run_line).group(1))
        summ = [ln for ln in lines if ln.startswith("Summary ")]
        if summ:
            m = re.search(
                r"(\d+) tests run: (\d+) passed , (\d+) failed , (\d+) skipped",
                summ[-1],
            )
            total, p, f, s = (int(x) for x in m.groups())
            got_p = sum(1 for r, _ in rows if r == "PASS")
            got_f = sum(1 for r, _ in rows if r == "FAIL")
            got_s = sum(1 for r, _ in rows if r == "SKIP")
            if not (declared == total == len(rows) == p + f + s):
                raise GenError(
                    f"{fixture}--{scenario}: count mismatch declared={declared} "
                    f"summary_total={total} rows={len(rows)} p+f+s={p + f + s}"
                )
            if (got_p, got_f, got_s) != (p, f, s):
                raise GenError(
                    f"{fixture}--{scenario}: tally mismatch rows={got_p, got_f, got_s} "
                    f"summary={p, f, s}"
                )


def generate() -> dict[str, str]:
    ver, commit = toolchain()
    oa = os_arch()
    transcripts: dict[str, str] = {}
    with tempfile.TemporaryDirectory() as bindir:
        built: dict[str, str] = {}
        for scenario, fixture, argv in MATRIX:
            if fixture not in built:
                built[fixture] = build_fixture(fixture, bindir)
            out_b, err_b, rc = run_scenario(built[fixture], argv)
            is_crash = fixture in CRASH_FIXTURES
            out_norm = normalize(out_b, is_crash_stream=False)
            err_norm = normalize(err_b, is_crash_stream=is_crash)
            transcript = render(
                fixture, scenario, argv, ver, commit, oa, out_norm, err_norm, rc
            )
            # The build tmpdir must never leak into a transcript.
            if bindir in transcript:
                raise GenError(f"{fixture}--{scenario}: build tmpdir leaked")
            verify_scenario(fixture, scenario, out_norm, err_norm, rc, transcript)
            transcripts[f"{fixture}--{scenario}.txt"] = transcript
    return transcripts


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--out",
        default=os.path.join(REPO_ROOT, "tests", "snapshots", "protocol"),
        help="output directory for transcripts + MANIFEST",
    )
    args = ap.parse_args()

    first = generate()

    # MANIFEST must equal the matrix exactly.
    expected_names = sorted(f"{fx}--{sc}.txt" for (sc, fx, _argv) in MATRIX)
    if sorted(first.keys()) != expected_names:
        raise GenError(
            f"generated set {sorted(first.keys())} != matrix {expected_names}"
        )

    # Double generation: the whole matrix, byte-identical the second time.
    second = generate()
    for name in expected_names:
        if first[name] != second[name]:
            raise GenError(f"non-deterministic transcript on regeneration: {name}")

    os.makedirs(args.out, exist_ok=True)
    for name in expected_names:
        with open(os.path.join(args.out, name), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(first[name])
    with open(os.path.join(args.out, "MANIFEST.txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(expected_names) + "\n")

    print(f"wrote {len(expected_names)} transcripts + MANIFEST.txt to {args.out}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GenError as e:
        print(f"gen_transcripts: STRUCTURAL PIN FAILED: {e}", file=sys.stderr)
        sys.exit(2)
