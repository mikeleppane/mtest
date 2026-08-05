#!/usr/bin/env python3
"""Generate protocol snapshots by running the committed fixtures.

The toolchain is the oracle. For every scenario in the matrix below this script
builds the fixture, runs it with the scenario's arguments, captures stdout and
stderr separately and byte-exactly, records the termination structurally (exit
code or terminating signal, never the shell 128+N encoding), applies an
anchored versioned normalization, and writes a line-oriented transcript with a
provenance header. It then hard-asserts a set of structural pins and
regenerates the whole matrix a second time to prove the output is
byte-identical.

A transcript must be identical across regenerations and across machines, or
`transcripts-check` is noise rather than a protocol pin. `normalize` carries the
only three rewrites applied to captured content; everything else is verbatim.

Usage:
    python -m scripts.gen_transcripts             # write into tests/snapshots/protocol/
    python -m scripts.gen_transcripts --out DIR   # write into DIR (check harness)
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
# "<fixture>--<scenario_id>.txt". The generator asserts the emitted MANIFEST
# equals this table exactly.
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
    (
        "no-compose",
        "passing",
        ["--only", "test_zeta_passes", "--skip", "test_alpha_passes"],
    ),
    ("skip-all-args", "passing", ["--skip-all", "--only", "x"]),
    # Conditional: only because 1.0.0b2's TestSuite exposes an in-code skip API.
    ("default", "skipped", []),
    ("skip-all", "skipped", ["--skip-all"]),
    ("only-native", "skipped", ["--only", "test_natively_skipped"]),
]

# Fixtures that crash the process, so their stderr carries a stack dump.
# `crashing` aborts (SIGILL plus an ABORT line); `segfault` faults on an invalid
# load (SIGSEGV, no ABORT line). Both die by signal, and both stderr streams are
# treated as crash streams and collapsed to <STACK-DUMP>.
CRASH_FIXTURES = {"crashing", "segfault"}

# The `mojo --version` banner, as the pinned toolchain prints it. Named here
# because the header this generator stamps is read back by other tooling, and a
# second spelling of the same pattern would let the writer and the reader
# disagree about what a toolchain identity looks like.
MOJO_VERSION_RE = re.compile(r"Mojo (\S+) \(([0-9a-f]+)\)")

# --- Normalization patterns --------------------------------------------------
RUNNING_RE = re.compile(r"^Running \d+ tests for ")
REPORT_LINE_RE = re.compile(r"^(    (?:PASS|FAIL|SKIP)) \[ [^\]]* \] (.*)$")
SUMMARY_RE = re.compile(r"^(Summary) \[ [^\]]* \] (.*)$")
STACK_HEADER_RE = re.compile(r"^Stack dump")
# A stack frame in either form the runtime emits. The shape depends on whether
# llvm-symbolizer is on PATH, so both must collapse to the same <STACK-DUMP>:
#   symbol-less:  "<n>  <module> 0x<hex>"           (no header requires PATH)
#   symbolized:   "#<n> 0x<hex> <sym> <file>:<l>:<c>" (leaks binary + lib paths)
FRAME_RE = re.compile(r"^\d+\s+\S+\s+0x[0-9a-f]+|^\s*#\d+ 0x[0-9a-f]+")


class GenError(Exception):
    """A structural pin failed, so generation aborts."""


def toolchain() -> tuple[str, str]:
    """Return the toolchain identity every transcript header records.

    Returns:
        The `mojo` version string and its build commit hash, in that order.

    Raises:
        GenError: If the `mojo --version` output carries no parsable version and
            commit, since a transcript may not claim an unknown toolchain.
    """
    out = subprocess.run(
        ["mojo", "--version"], check=True, capture_output=True, text=True
    ).stdout.strip()
    m = MOJO_VERSION_RE.search(out)
    if not m:
        raise GenError(f"cannot parse mojo version from: {out!r}")
    return m.group(1), m.group(2)


def os_arch() -> str:
    """Return the `<os>-<machine>` tag the transcript header records.

    Returns:
        The lowercased system name joined to the machine name, e.g.
        `linux-x86_64`.
    """
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
    # (2) repo-root absolute prefix -> <REPO>, the only path rewrite. The
    # compiler bakes the absolute canonicalized source path into every location
    # line.
    text = text.replace(REPO_ROOT, "<REPO>")

    had_trailing_nl = text.endswith("\n")
    core = text[:-1] if had_trailing_nl else text
    lines = core.split("\n") if core != "" else []

    # (3) Stack collapse, on crash stderr only: the maximal trailing block
    # starting at the first `Stack dump` header (or frame line) becomes a single
    # <STACK-DUMP>, header included, since the header text varies with
    # llvm-symbolizer presence in PATH. Every line after the header must match a
    # frame pattern, so extending the rule stays a deliberate act.
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
            lines = [*lines[:start], "<STACK-DUMP>"]

    # (1) Timing tokens -> [ T ], anchored: only on report-grammar lines at or
    # after the `Running <N> tests for` line that opens the real report block.
    # A real report always ends in a `Summary ` line, so the anchor is the last
    # `Running` line followed by one. Requiring the Summary keeps user output
    # byte-exact on a crash stream, where the report is lost and a
    # `Running`-lookalike a test printed before aborting has no Summary after it.
    summary_idxs = [i for i, ln in enumerate(lines) if ln.startswith("Summary [ ")]
    if summary_idxs:
        last_summary = summary_idxs[-1]
        running_before = [
            i for i, ln in enumerate(lines) if RUNNING_RE.match(ln) and i < last_summary
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
    """Render how a scenario ended, structurally rather than shell-encoded.

    Args:
        returncode: A `subprocess` return code, negative for death by signal.

    Returns:
        `signal <n>` for a signalled death, otherwise `exit <n>`.
    """
    # Python reports death-by-signal as a negative returncode. Record the raw
    # signal number, not the shell-encoded 128+N.
    if returncode < 0:
        return f"signal {-returncode}"
    return f"exit {returncode}"


def build_fixture(fixture: str, out_dir: str) -> str:
    """Build one committed protocol fixture into a throwaway directory.

    The build is unoptimized; nothing about the protocol under snapshot depends
    on optimization.

    Args:
        fixture: Fixture stem under `tests/fixtures/protocol`, without `.mojo`.
        out_dir: Directory the binary is written into, normally a temp dir so
            its path can never leak into a transcript.

    Returns:
        The path of the built binary.

    Raises:
        subprocess.CalledProcessError: If the compile fails, since a snapshot
            may not be generated from a fixture that did not build.
    """
    src = os.path.join(FIXTURES_DIR, f"{fixture}.mojo")
    binpath = os.path.join(out_dir, fixture)
    subprocess.run(
        ["mojo", "build", "--no-optimization", src, "-o", binpath],
        check=True,
        capture_output=True,
    )
    return binpath


def run_scenario(binpath: str, argv: list[str]) -> tuple[bytes, bytes, int]:
    """Run one built fixture and capture both streams byte-exactly.

    Streams are captured separately and undecoded because the snapshot pins each
    stream's exact content.

    Args:
        binpath: The built fixture binary to run.
        argv: The scenario's arguments, appended after the binary path.

    Returns:
        The raw stdout bytes, the raw stderr bytes, and the return code, which
        is negative when the fixture died by a signal.
    """
    # check=False: a nonzero exit and a fatal signal are both expected outcomes
    # here, so the return code is recorded rather than raised on.
    proc = subprocess.run([binpath, *argv], capture_output=True, check=False)
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
    """Render one transcript: provenance header, command, termination, streams.

    The binary path is written as the fixed token `<BIN>`, so the transcript
    does not depend on where the throwaway build directory happened to be.

    Args:
        fixture: Fixture stem the scenario ran.
        scenario: Scenario id from the matrix.
        argv: The scenario's arguments, rendered after `<BIN>`.
        ver: The `mojo` version recorded in the header.
        commit: The `mojo` build commit recorded in the header.
        oa: The `<os>-<machine>` tag recorded in the header.
        out_norm: Already-normalized stdout text.
        err_norm: Already-normalized stderr text.
        returncode: The scenario's return code, rendered by `termination`.

    Returns:
        The full transcript text, with each stream section newline-terminated.
    """
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


def verify_scenario(
    fixture: str,
    scenario: str,
    out_norm: str,
    err_norm: str,
    returncode: int,
    transcript: str,
) -> None:
    """Hard-assert every structural pin one scenario's transcript must hold.

    The pins cover section-marker framing, path and symbolizer leakage, crash
    shape, the selection scenarios' SKIP listings, byte-exact survival of the
    noisy fixture's user output, and count reconciliation.

    Args:
        fixture: Fixture stem the scenario ran.
        scenario: Scenario id from the matrix.
        out_norm: Normalized stdout text.
        err_norm: Normalized stderr text.
        returncode: The scenario's return code, negative for death by signal.
        transcript: The fully rendered transcript, checked for leaked paths.

    Raises:
        GenError: On the first pin that fails, naming the fixture, the scenario,
            and what was expected.
    """
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
        # An ABORT line is not universal to crashes: a controlled abort() emits
        # one, a raw segfault emits none. So the pin is two-part.
        # (a) Any ABORT line on stdout must be normalized to the
        # <REPO>-rewritten fixture-path shape. Holds for every crash fixture.
        for ln in out_norm.split("\n"):
            if ln.startswith("ABORT:") and not ln.startswith(
                "ABORT: <REPO>/tests/fixtures/protocol/"
            ):
                raise GenError(
                    f"{fixture}--{scenario}: ABORT line present but not "
                    f"normalized to the <REPO> fixture-path shape: {ln!r}"
                )
        # (b) A fixture that aborts() must still emit its ABORT line, or the
        # crash pin has nothing to anchor on. Scoped to `crashing`, the only
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
            raise GenError(f"skip-all listing {names} != fixture test names {expected}")

    # native-skip skip-all collection: both names are listed as SKIP, in source
    # (discovery) order, pinning that a natively skipped test is neither omitted
    # nor reordered by --skip-all.
    if scenario == "skip-all" and fixture == "skipped":
        names = [n for (r, n) in _report_result_lines(out_norm) if r == "SKIP"]
        expected = ["test_runs_normally", "test_natively_skipped"]
        if names != expected:
            raise GenError(f"skip-all listing {names} != fixture test names {expected}")

    # native-skip survives explicit selection: --only the natively-skipped test
    # still reports it as SKIP, so naming a test does not override its native
    # skip. The unselected test reports SKIP too, for the ordinary
    # selection-induced reason, so both rows read SKIP for two different reasons
    # and a bare row list cannot tell them apart. Downstream reconciliation is
    # what must resolve that ambiguity.
    if scenario == "only-native" and fixture == "skipped":
        rows = _report_result_lines(out_norm)
        expected_rows = [
            ("SKIP", "test_runs_normally"),
            ("SKIP", "test_natively_skipped"),
        ]
        if rows != expected_rows:
            raise GenError(f"only-native rows {rows} != expected {expected_rows}")

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
        run_match = re.match(r"^Running (\d+) tests for ", run_line)
        if run_match is None:
            # Cannot fire: `run_line` was selected by RUNNING_RE, which is this
            # same pattern without the capture group.
            raise GenError(f"{fixture}--{scenario}: unparsable run line {run_line!r}")
        declared = int(run_match.group(1))
        summ = [ln for ln in lines if ln.startswith("Summary ")]
        if summ:
            m = re.search(
                r"(\d+) tests run: (\d+) passed , (\d+) failed , (\d+) skipped",
                summ[-1],
            )
            if m is None:
                raise GenError(
                    f"{fixture}--{scenario}: summary line does not carry the "
                    f"tally grammar: {summ[-1]!r}"
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
    """Build, run, normalize, verify, and render the whole scenario matrix once.

    Each fixture is built at most once per pass and reused across the scenarios
    that share it.

    Returns:
        A mapping from transcript filename to transcript text, one entry per
        matrix row.

    Raises:
        GenError: If a structural pin fails or the temporary build directory
            leaks into a transcript.
    """
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
    """Generate the matrix twice, pin the manifest, and write the snapshots.

    Files are written only after both passes agree byte for byte and the emitted
    name set equals the matrix exactly.

    Returns:
        0 once every transcript and the MANIFEST have been written.

    Raises:
        GenError: If the generated name set differs from the matrix, or any
            transcript differs between the two generations.
    """
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
        with open(
            os.path.join(args.out, name), "w", encoding="utf-8", newline="\n"
        ) as fh:
            fh.write(first[name])
    with open(
        os.path.join(args.out, "MANIFEST.txt"), "w", encoding="utf-8", newline="\n"
    ) as fh:
        fh.write("\n".join(expected_names) + "\n")

    print(f"wrote {len(expected_names)} transcripts + MANIFEST.txt to {args.out}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GenError as e:
        print(f"gen_transcripts: STRUCTURAL PIN FAILED: {e}", file=sys.stderr)
        sys.exit(2)
