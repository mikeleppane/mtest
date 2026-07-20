#!/usr/bin/env python3
"""Black-box contract-conformance validator for the mtest CLI.

The executable oracle behind the `validating-mtest` skill. It does what a new
*user* does: scaffolds a throwaway Mojo project (a library, clean suites, and
deliberately-broken / "poison" files) outside the repo, then drives the built
`mtest` binary against it and asserts, per check, the exit code and the
stdout/stderr content — every assertion tagged with the `docs/cli-contract.md`
section it enforces.

Design (hardened after adversarial review):
  * The contract is the oracle. A check asserts what the contract PROMISES, not
    what the implementation happens to render. Console *wording* is informal
    (§20), so checks lean on the FROZEN surfaces: exit codes (§9), the `collect`
    listing (§16), stream routing (§16/§19), and outcome *distinctions* (§10).
  * Verdict fidelity over label presence. The dominant defect class is SILENT
    test-set corruption — running the wrong SET while still printing a plausible
    green summary. So the oracle asserts the EXACT collected node-id set and
    EXACT counts, and uses POISON probes: a test that would FAIL/CRASH if it ran,
    so a broken selection/exclusion/early-stop flips the frozen exit code.
  * No false green. A stale binary is rebuilt before validating; a run that
    selects zero checks, or SKIPs a safety-critical check under --strict, exits
    non-zero. Setup failures exit 2 (distinct from a contract failure's 1).

Usage:
    python scripts/validate_contract.py                 # rebuild-if-stale, run all
    python scripts/validate_contract.py -k selection    # filter by check name
    python scripts/validate_contract.py --strict         # SKIP of a check -> failure
    python scripts/validate_contract.py --keep --no-rebuild -v

Exit: 0 all passed; 1 a contract check failed (or --strict skip / zero checks);
2 setup failure (no toolchain, binary won't build). CI-usable.
"""
from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path


# --------------------------------------------------------------------------- #
# Repo + toolchain.
# --------------------------------------------------------------------------- #
def find_repo_root(start: Path) -> Path:
    for d in [start, *start.parents]:
        if (d / "pixi.toml").is_file():
            return d
    _die("could not find repo root (no pixi.toml above this script)")


def _die(msg: str) -> "None":
    """Setup failure: exit 2, distinct from a contract-nonconformance exit 1."""
    print(f"setup: {msg}", file=sys.stderr)
    sys.exit(2)


REPO = find_repo_root(Path(__file__).resolve())
MTEST = REPO / "build" / "mtest"


def pixi_env() -> dict[str, str]:
    """The environment `pixi run` activates (mojo/clang on PATH), as a dict.

    `MTEST_MOJO` is scrubbed: the scaffold library is precompiled with pixi's
    pinned mojo, so a caller's stray override would build tests with a different
    toolchain and manufacture false findings (it also leaves §7 precedence for a
    dedicated check, not an ambient accident).
    """
    out = subprocess.run(
        ["pixi", "run", "bash", "-c", "env -0"],
        cwd=REPO, capture_output=True, text=True,
    )
    if out.returncode != 0:
        _die(f"`pixi run` failed — is pixi installed?\n{out.stderr}")
    env: dict[str, str] = {}
    for entry in out.stdout.split("\0"):
        if "=" in entry:
            k, _, v = entry.partition("=")
            env[k] = v
    env.pop("MTEST_MOJO", None)
    return env


def _newest_mtime(dirs: list[Path]) -> float:
    m = 0.0
    for d in dirs:
        if d.is_dir():
            for f in d.rglob("*"):
                if f.is_file():
                    m = max(m, f.stat().st_mtime)
    return m


def ensure_binary(env: dict[str, str], rebuild: bool, allow_rebuild: bool) -> None:
    """Build `build/mtest`, and REBUILD it when older than any source file.

    A stale binary validates the *old* code and reports a false green — this bit
    the project during its own QA pass. Freshness is enforced, not just warned.
    """
    stale = MTEST.is_file() and MTEST.stat().st_mtime < _newest_mtime(
        [REPO / "src", REPO / "native"]
    )
    if MTEST.is_file() and not rebuild and not stale:
        return
    if not allow_rebuild and MTEST.is_file():
        print("warning: build/mtest is STALE vs src/ but --no-rebuild set — "
              "validating possibly-old code", file=sys.stderr)
        return
    why = "missing" if not MTEST.is_file() else ("forced" if rebuild else "stale")
    print(f"setup: building build/mtest ({why}) ...", flush=True)
    r = subprocess.run(["pixi", "run", "build-bin"], cwd=REPO, env=env)
    if r.returncode != 0 or not MTEST.is_file():
        _die("could not build build/mtest")


# --------------------------------------------------------------------------- #
# Scaffold — a throwaway user project. Clean suites are all-pass with a KNOWN
# exact node-id set; poison suites carry a test that fails/crashes if it runs.
# --------------------------------------------------------------------------- #
LIB = '''\
"""Toy string library so scaffolded suites import a real package, as a user would."""


def reverse(s: String) -> String:
    var chars = List[String]()
    for ch in s.codepoint_slices():
        chars.append(String(ch))
    var out = String("")
    for i in range(len(chars) - 1, -1, -1):
        out += chars[i]
    return out


def is_palindrome(s: String) -> Bool:
    return s == reverse(s)
'''

MAIN = "\n\ndef main() raises:\n    TestSuite.discover_tests[__functions_in_module()]().run()\n"
HEAD = ("from textkit import reverse, is_palindrome\n"
        "from std.testing import assert_equal, assert_true, TestSuite\n\n\n")
CRASH_HEAD = ("from std.os import abort\n"
              "from std.testing import assert_equal, TestSuite\n\n\n")

# Exact node-id set the clean `tests/` walk must yield (sorted, root-relative).
EXPECTED_TESTS = [
    "tests/nested/test_nested.mojo::test_nested_ok",
    "tests/test_palindrome.mojo::test_palindrome_true",
    "tests/test_reverse.mojo::test_reverse_ab",
    "tests/test_reverse.mojo::test_reverse_empty",
]


def scaffold(root: Path) -> None:
    def w(rel: str, body: str) -> None:
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)

    w("textkit/__init__.mojo", LIB)
    (root / "build").mkdir()

    # -- clean tests/: all pass, exact known set, + one NO-TESTS + one non-test.
    w("tests/test_reverse.mojo", HEAD +
      'def test_reverse_ab() raises:\n    assert_equal(reverse("ab"), "ba")\n\n\n'
      'def test_reverse_empty() raises:\n    assert_equal(reverse(""), "")\n' + MAIN)
    w("tests/test_palindrome.mojo", HEAD +
      'def test_palindrome_true() raises:\n    assert_true(is_palindrome("racecar"))\n' + MAIN)
    w("tests/nested/test_nested.mojo", HEAD +
      'def test_nested_ok() raises:\n    assert_equal(reverse("x"), "x")\n' + MAIN)
    w("tests/test_todo.mojo", "from std.testing import TestSuite\n" + MAIN)  # NO-TESTS
    w("tests/helper.mojo", "from std.testing import TestSuite\n\n\n"
      "def make() -> Int:\n    return 1\n" + MAIN)  # not a test_ file

    # -- poison: a test that FAILS/CRASHES if it runs (discriminates selection).
    w("poison/test_pick.mojo", HEAD +
      'def test_keep() raises:\n    assert_equal(reverse("ab"), "ba")\n\n\n'
      'def test_drop() raises:\n    assert_equal(1, 2)  # POISON: fails if run\n' + MAIN)
    # -- excl: exclusion must REALLY remove test_bad (a crash), not just print it.
    w("excl/test_ok.mojo", HEAD +
      'def test_ok() raises:\n    assert_equal(1, 1)\n' + MAIN)
    w("excl/test_bad.mojo", CRASH_HEAD +
      'def test_bad() raises:\n    abort("POISON: crashes if run")\n' + MAIN)
    # -- estop: first file FAILS; second would CRASH -> -x must not schedule it.
    w("estop/test_a_fail.mojo", HEAD +
      'def test_a() raises:\n    assert_equal(1, 2)\n' + MAIN)
    w("estop/test_b_poison.mojo", CRASH_HEAD +
      'def test_b() raises:\n    abort("POISON: -x must stop before here")\n' + MAIN)
    # -- maxf: one failing test; sibling would CRASH -> --maxfail 1 must stop.
    w("maxf/test_a_fail.mojo", HEAD +
      'def test_a() raises:\n    assert_equal(1, 2)\n' + MAIN)
    w("maxf/test_b_poison.mojo", CRASH_HEAD +
      'def test_b() raises:\n    abort("POISON: --maxfail must stop before here")\n' + MAIN)
    # -- gate: two passing files; a failing gate must abort BEFORE they run.
    w("gate/test_g1.mojo", HEAD + 'def test_g1() raises:\n    assert_equal(1, 1)\n' + MAIN)
    w("gate/test_g2.mojo", HEAD + 'def test_g2() raises:\n    assert_equal(1, 1)\n' + MAIN)
    w("gatefail/test_smoke.mojo", HEAD + 'def test_smoke() raises:\n    assert_equal(0, 1)\n' + MAIN)

    # -- probe outcomes.
    w("probes/test_fail.mojo", HEAD + 'def test_x() raises:\n    assert_equal(1, 2)\n' + MAIN)
    w("probes/test_crash.mojo", CRASH_HEAD + 'def test_x() raises:\n    abort("boom")\n' + MAIN)
    w("probes/test_compile_error.mojo", HEAD +
      "def test_x() raises:\n    assert_equal(this_is_undefined(), 0)\n" + MAIN)
    w("probes/test_malformed.mojo", "def main():\n    pass\n")
    w("probes/test_hang.mojo", "from std.time import sleep\nfrom std.testing import TestSuite\n\n\n"
      "def test_x() raises:\n    while True:\n        sleep(3600.0)\n" + MAIN)

    # -- protocol drift: a report present but OFF-GRAMMAR -> exit 3 (§6/§16),
    #    never laundered into a verdict. Mirrors e2e/hostile/test_liar.mojo.
    w("drift/test_liar.mojo", "from std.testing import TestSuite, assert_true\n\n\n"
      "def test_one() raises:\n    assert_true(True)\n\n\n"
      "def main() raises:\n"
      "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
      '    print("Summary [ 0.00s ] 1 tests run: 1 passed , 0 failed , 0 skipped ")\n')

    # -- broken package for the precompile-failure path.
    w("brokenlib/__init__.mojo", "def busted() -> Int:\n    return undefined_symbol_here()\n")
    (root / "empty").mkdir()


# --------------------------------------------------------------------------- #
# Check model — separate streams; assert on the frozen surfaces.
# --------------------------------------------------------------------------- #
@dataclass
class Check:
    name: str
    ref: str
    argv: list[str]
    exit: int
    out_has: list[str] = field(default_factory=list)   # required in stdout
    err_has: list[str] = field(default_factory=list)   # required in stderr
    any_has: list[str] = field(default_factory=list)   # required in either
    any_absent: list[str] = field(default_factory=list)  # forbidden in either


PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"
CRITICAL = {"interrupt: SIGINT frees the owned process group"}  # skip-sensitive under --strict


class Runner:
    def __init__(self, root: Path, env: dict[str, str], verbose: bool):
        self.root, self.env, self.verbose = root, env, verbose
        self.results: list[tuple[str, str, str, str]] = []

    def mtest(self, argv: list[str], timeout: int = 180):
        return subprocess.run([str(MTEST), *argv], cwd=self.root, env=self.env,
                              capture_output=True, text=True, timeout=timeout)

    def record(self, status, name, ref, detail=""):
        self.results.append((status, name, ref, detail))
        mark = {PASS: "  ok ", FAIL: "FAIL ", SKIP: "skip "}[status]
        line = f"[{mark}] {name}  ({ref})"
        if detail and status != PASS:
            line += f"\n         {detail}"
        print(line, flush=True)

    def check(self, c: Check):
        try:
            r = self.mtest(c.argv)
        except subprocess.TimeoutExpired:
            return self.record(FAIL, c.name, c.ref, f"timed out: mtest {' '.join(c.argv)}")
        both = r.stdout + "\n" + r.stderr
        probs = []
        if r.returncode != c.exit:
            probs.append(f"exit {r.returncode}, want {c.exit}")
        probs += [f"stdout missing {s!r}" for s in c.out_has if s not in r.stdout]
        probs += [f"stderr missing {s!r}" for s in c.err_has if s not in r.stderr]
        probs += [f"missing {s!r}" for s in c.any_has if s not in both]
        probs += [f"unexpected {s!r}" for s in c.any_absent if s in both]
        if probs:
            d = "; ".join(probs)
            if self.verbose:
                d += f"\n         argv: {c.argv}\n--- stdout ---\n{r.stdout}\n--- stderr ---\n{r.stderr}"
            self.record(FAIL, c.name, c.ref, d)
        else:
            self.record(PASS, c.name, c.ref)

    # -- bespoke: exact collect set (the anti-silent-corruption oracle) -------- #
    def check_collect_exact(self):
        ref = "§16 collect lists EXACTLY the discovered node ids, sorted (§5,§17)"
        name = "collect: exact node-id set for tests/"
        r = self.mtest(["collect", "-I", "build", "tests"])
        got = [ln for ln in r.stdout.splitlines() if "::" in ln]
        if r.returncode == 0 and got == EXPECTED_TESTS:
            self.record(PASS, name, ref)
        else:
            missing = [x for x in EXPECTED_TESTS if x not in got]
            extra = [x for x in got if x not in EXPECTED_TESTS]
            self.record(FAIL, name, ref,
                        f"exit {r.returncode}; missing={missing}; extra={extra}; sorted={got == sorted(got)}")

    def check_determinism(self):
        ref = "§17 machine output (collect) is byte-identical across runs"
        name = "determinism: collect byte-identical"
        a = self.mtest(["collect", "-I", "build", "tests"])
        b = self.mtest(["collect", "-I", "build", "tests"])
        ok = a.returncode == b.returncode == 0 and a.stdout == b.stdout and a.stdout
        self.record(PASS if ok else FAIL, name, ref,
                    "" if ok else "two collect runs differed or were empty")

    def check_help_stream(self):
        # §19: --help -> STDOUT, exit 0. A usage error -> STDERR, exit 4.
        h = self.mtest(["--help"])
        self.record(
            PASS if (h.returncode == 0 and "usage:" in h.stdout and "usage:" not in h.stderr) else FAIL,
            "help: --help -> stdout, exit 0", "§19",
            "" if h.returncode == 0 and "usage:" in h.stdout else f"exit {h.returncode}; stdout has usage: {'usage:' in h.stdout}")
        u = self.mtest(["-V"])
        self.record(
            PASS if (u.returncode == 4 and u.stderr.strip() and "usage:" not in u.stdout) else FAIL,
            "usage error: -V -> stderr, exit 4", "§19",
            "" if u.returncode == 4 and u.stderr.strip() else f"exit {u.returncode}; stderr empty={not u.stderr.strip()}")

    def check_collect_streams(self):
        # §16: node ids -> STDOUT; per-file diagnostics -> STDERR; listing continues.
        ref = "§16 collect: node ids to stdout, diagnostics to stderr, listing continues"
        name = "collect: streams split, listing continues past a bad probe"
        r = self.mtest(["collect", "-I", "build", "cmix"])
        ok_nodes = "cmix/test_ok.mojo::test_ok" in r.stdout           # good file still listed
        diag_err = ("compile" in r.stderr.lower() or "error" in r.stderr.lower())  # bad file -> stderr
        no_diag_out = "compile error" not in r.stdout.lower()
        ok = r.returncode == 1 and ok_nodes and diag_err and no_diag_out
        self.record(PASS if ok else FAIL, name, ref,
                    "" if ok else f"exit {r.returncode}; good-node-in-stdout={ok_nodes}; diag-in-stderr={diag_err}; clean-stdout={no_diag_out}")

    def check_color(self):
        # §15.1: --color never -> no ANSI; always -> ANSI; and the flag WINS over
        # NO_COLOR. This is the exact interaction the original QA pass false-flagged.
        ref = "§15.1 --color never/always; the flag wins over NO_COLOR"
        name = "color: --color always beats NO_COLOR"

        def esc(mode: str, no_color: bool) -> int:
            e = dict(self.env)
            if no_color:
                e["NO_COLOR"] = "1"
            else:
                e.pop("NO_COLOR", None)
            r = subprocess.run(
                [str(MTEST), "-I", "build", "--color", mode, "tests/test_reverse.mojo"],
                cwd=self.root, env=e, capture_output=True, text=True)
            return r.stdout.count("\x1b[")

        never = esc("never", False)
        always = esc("always", False)
        wins = esc("always", True)  # flag must beat NO_COLOR (§15.1)
        ok = never == 0 and always > 0 and wins > 0
        self.record(PASS if ok else FAIL, name, ref,
                    "" if ok else f"never={never}(0?) always={always}(>0?) NO_COLOR+always={wins}(>0?)")

    def check_precompile_success(self):
        # §8.3: a successful --precompile builds the pkg and auto-adds its -I so a
        # dependent test resolves `from textkit import ...` with NO manual -I.
        ref = "§8.3 successful --precompile auto-adds -I; dependent test PASSes"
        name = "precompile: success path resolves import (auto -I)"
        r = self.mtest(["--precompile", "textkit", "tests/test_reverse.mojo"])
        ok = r.returncode == 0 and "PASS" in r.stdout and "2 passed" in (r.stdout + r.stderr)
        self.record(PASS if ok else FAIL, name, ref,
                    "" if ok else f"exit {r.returncode}")

    # -- interrupt: signal ONLY mtest so the child's survival tests mtest's own
    #    process-group teardown (§18/§24.2), not a signal the child caught directly.
    def check_interrupt(self, strict: bool):
        ref = "§9/§24.2 SIGINT -> exit 2, partial summary, owned child group freed"
        name = "interrupt: SIGINT frees the owned process group"
        (self.root / "irq").mkdir(exist_ok=True)
        (self.root / "irq" / "test_1hang.mojo").write_text(
            "from std.time import sleep\nfrom std.testing import TestSuite\n\n\n"
            "def test_h() raises:\n    while True:\n        sleep(3600.0)\n" + MAIN)
        (self.root / "irq" / "test_2pass.mojo").write_text(
            HEAD + "def test_p() raises:\n    assert_equal(1, 1)\n" + MAIN)

        def pgrep_hang() -> bool:
            try:
                return subprocess.run(["pgrep", "-f", "irq_stest_"],
                                      capture_output=True).returncode == 0
            except OSError:
                raise RuntimeError("pgrep unavailable")

        try:
            proc = subprocess.Popen(
                [str(MTEST), "-I", "build", "--timeout", "0", "irq"],
                cwd=self.root, env=self.env, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                start_new_session=True)
        except OSError as e:
            return self._skip_or_fail(strict, name, ref, f"could not spawn: {e}")
        try:
            deadline = time.time() + 120
            running = False
            while time.time() < deadline:
                try:
                    if pgrep_hang():
                        running = True
                        break
                except RuntimeError as e:
                    proc.kill()
                    return self._skip_or_fail(strict, name, ref, str(e))
                if proc.poll() is not None:
                    break
                time.sleep(0.2)
            if not running:
                self._killtree(proc)
                return self._skip_or_fail(strict, name, ref, "hang binary never observed")
            time.sleep(1.0)
            os.kill(proc.pid, signal.SIGINT)  # ONLY mtest — teardown must free the child
            try:
                out, _ = proc.communicate(timeout=30)
            except subprocess.TimeoutExpired:
                self._killtree(proc)
                return self.record(FAIL, name, ref, "did not exit within 30s of SIGINT")
            time.sleep(0.5)
            orphan = pgrep_hang()
            ok = proc.returncode == 2 and "not run" in out and not orphan
            self.record(PASS if ok else FAIL, name, ref,
                        "" if ok else f"exit {proc.returncode} (want 2); orphaned_child={orphan}")
        finally:
            self._killtree(proc)

    def _killtree(self, proc):
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass
        try:
            proc.wait(timeout=5)
        except Exception:
            pass

    def _skip_or_fail(self, strict, name, ref, detail):
        self.record(FAIL if strict else SKIP, name, ref,
                    detail + (" (--strict: counted as failure)" if strict else ""))


# --------------------------------------------------------------------------- #
# Matrix.
# --------------------------------------------------------------------------- #
def build_matrix() -> list[Check]:
    I = ["-I", "build"]  # noqa: E741
    # Still refused (§24.1): exactly -n/--workers and --serial. Every other v1
    # flag this build knows the spelling of is served now.
    refused = [("--workers", "4", "parallel workers"), ("-n", "4", "parallel workers"),
               ("--serial", "*.mojo", "serial")]
    # Newly served (§24.1): --retries, --compile-timeout, --shard, --junit-xml,
    # --gh-annotations, and --json are all wired up — the parser accepts them and
    # they run, so none of them may exit 4 with the not-available refusal. Assert
    # the flip so the validator stops asserting a falsehood, without duplicating
    # the e2e's behavior coverage.
    served = [
        ("--retries", "2", "§13,§24.1"),
        ("--compile-timeout", "600", "§18,§24.1"),
        ("--junit-xml", "r.xml", "§15.2,§24.1"),
        ("--gh-annotations", "auto", "§15.3,§24.1"),
        # A file destination, not "-": "-" would make --json own stdout, which
        # collides with the default --gh-annotations auto (§15.3) — a distinct,
        # deliberate usage error, not the "not served" refusal this check probes.
        ("--json", "out.ndjson", "§15.4,§24.1"),
    ]
    checks = [
        # Version identity (§19) — discriminating, not a bare "mtest".
        Check("help: version prints the version", "§19", ["version"], 0, out_has=["mtest 0.4.0"]),
        # Outcomes + FROZEN exit codes (§9,§10). CRASH must stay distinct from FAIL (§10).
        Check("outcome: passing tests/ -> 0, exact count", "§9,§10", I + ["tests"], 0,
              any_has=["4 passed", "NO-TESTS"]),
        Check("outcome: FAIL -> 1", "§9,§10", I + ["probes/test_fail.mojo"], 1, any_has=["FAIL"]),
        Check("outcome: CRASH is not a FAIL -> 1", "§10", I + ["probes/test_crash.mojo"], 1,
              any_has=["CRASH"], any_absent=["FAIL "]),
        Check("outcome: COMPILE-ERROR -> 1", "§6,§9", I + ["probes/test_compile_error.mojo"], 1,
              any_has=["COMPILE-ERROR"]),
        Check("outcome: MALFORMED-SUITE -> 1", "§6", I + ["probes/test_malformed.mojo"], 1,
              any_has=["MALFORMED-SUITE"]),
        Check("outcome: NO-TESTS-only session -> 5", "§9(nothing collected)", I + ["tests/test_todo.mojo"], 5,
              any_has=["NO-TESTS"]),
        Check("outcome: TIMEOUT -> 1", "§18", I + ["--timeout", "3", "probes/test_hang.mojo"], 1,
              any_has=["TIMEOUT"]),
        # Discovery (§5).
        Check("discover: nonexistent path -> 4 (stderr)", "§5", I + ["tests/nope.mojo"], 4,
              err_has=["discover"]),
        Check("discover: empty dir -> 5", "§5,§9", I + ["empty"], 5),
        Check("discover: explicit non-test_ file bypasses pattern", "§5", I + ["tests/helper.mojo"], 5,
              any_has=["NO-TESTS"]),
        Check("discover: operand escaping root -> 4 (stderr)", "§2", I + [".."], 4,
              err_has=["discover"]),  # structural prefix, not the informal sentence
        # Selection (§5) — exact counts + POISON so a broken filter flips exit code.
        Check("select: node id runs exactly one; sibling poison must NOT run", "§5,§10.1",
              I + ["poison/test_pick.mojo::test_keep"], 0, any_has=["1 passed", "1 deselected"],
              any_absent=["CRASH", "test_drop"]),
        Check("select: -k selects the matching set", "§5", I + ["-k", "reverse", "tests"], 0,
              any_has=["2 passed"]),
        Check("select: -k case-insensitive", "§5", I + ["-k", "REVERSE", "tests"], 0, any_has=["2 passed"]),
        Check("select: -k matches nothing -> 5", "§5,§9", I + ["-k", "zzzznope", "tests"], 5),
        Check("select: unknown test in a real file -> 4", "§5", I + ["tests/test_reverse.mojo::ghost"], 4),
        Check("select: node id whose path is a DIRECTORY -> 4", "§5", I + ["tests::test_reverse_ab"], 4),
        # Exclusion (§12) — POISON crash file must be REALLY removed, not just named.
        Check("exclude: pattern truly removes a would-crash file (exit stays 0)", "§12",
              I + ["--exclude", "*_bad.mojo", "excl"], 0, any_has=["EXCLUDED"], any_absent=["CRASH"]),
        Check("exclude: stale pattern warns loudly", "§12", I + ["--exclude", "*_missing.mojo", "tests"], 0,
              any_has=["stale"]),
        Check("exclude: everything excluded -> 5", "§12,§9", I + ["--exclude", "*", "excl"], 5),
        # Early stop (§11) — the not-run COUNT is the discriminator (poison sibling).
        Check("stop: -x stops scheduling; poison sibling stays NOT-RUN", "§11",
              I + ["-x", "estop"], 1, any_has=["1 not run"], any_absent=["POISON must stop", "test_b"]),
        Check("stop: --maxfail 1 stops; poison sibling stays NOT-RUN", "§11",
              I + ["--maxfail", "1", "maxf"], 1, any_has=["1 not run"], any_absent=["test_b"]),
        Check("stop: failing --gate aborts the whole run (exact not-run)", "§11",
              I + ["--gate", "gatefail/test_smoke.mojo", "gate"], 1, any_has=["2 not run"]),
        # collect (§16) + run-only rejection (§4) + §24.3 documented deviations.
        Check("collect: --durations rejected in collect -> 4", "§4",
              ["collect"] + I + ["--durations", "3", "tests"], 4),
        Check("collect: --maxfail rejected in collect -> 4", "§4",
              ["collect"] + I + ["--maxfail", "1", "tests"], 4),
        Check("collect: --retries rejected in collect -> 4", "§4",
              ["collect"] + I + ["--retries", "1", "tests"], 4),
        Check("collect: --json rejected in collect -> 4", "§4",
              ["collect"] + I + ["--json", "out.ndjson", "tests"], 4),
        Check("collect: --junit-xml rejected in collect -> 4", "§4",
              ["collect"] + I + ["--junit-xml", "r.xml", "tests"], 4),
        Check("collect: --gh-annotations rejected in collect -> 4 (even off)", "§4",
              ["collect"] + I + ["--gh-annotations", "off", "tests"], 4),
        Check("collect: -k ignored with a loud notice (§24.3 deviation)", "§24.3",
              ["collect"] + I + ["-k", "reverse", "tests"], 0,
              any_has=["ignored", "test_palindrome_true"]),  # notice + un-filtered listing
        Check("collect: node-id operand lists whole file (§24.3 deviation)", "§24.3",
              ["collect"] + I + ["tests/test_reverse.mojo::test_reverse_ab"], 0,
              any_has=["test_reverse_ab", "test_reverse_empty"]),
        # Forbidden build args (§8.4) — and pre-run detection (poison never runs).
        Check("build-arg: -o forbidden -> 4, and the test never ran (pre-run, §9)", "§8.4,§9",
              I + ["--build-arg", "-o", "--build-arg", "x", "poison/test_pick.mojo"], 4,
              any_absent=["1 passed", "CRASH"]),
        Check("build-arg: --emit forbidden -> 4", "§8.4", I + ["--build-arg", "--emit=llvm", "tests/test_reverse.mojo"], 4),
        Check("build-arg: extra source after -- forbidden -> 4", "§8.4",
              I + ["tests/test_reverse.mojo", "--", "extra.mojo"], 4),
        # Internal error (§24.2) — spawn failure and protocol drift both -> exit 3.
        Check("exit-3: bad --mojo (spawn failure) -> 3", "§24.2", I + ["--mojo", "/nonexistent/mojo", "tests/test_reverse.mojo"], 3),
        Check("exit-3: off-grammar report (drift) -> 3, never a verdict", "§6,§16,§24.2",
              I + ["drift/test_liar.mojo"], 3),
        # Value validation (§3,§15.1).
        Check("value: --durations negative -> 4", "§3", I + ["--durations", "-1", "tests"], 4),
        Check("value: --timeout non-integer -> 4", "§3", I + ["--timeout", "abc", "tests"], 4),
        Check("value: --show-output bad mode -> 4", "§3", I + ["--show-output", "bogus", "tests"], 4),
        Check("value: --color bad mode -> 4", "§3", I + ["--color", "bogus", "tests"], 4),
        Check("value: -q and -v mutually exclusive -> 4", "§15.1", I + ["-q", "-v", "tests"], 4),
        # Precompile failure (§8.3) — pass a DIRECTORY so the casualty path is not
        # an operand echo: its presence proves it was LISTED as a casualty.
        Check("precompile: failure -> PRECOMPILE-ERROR, casualties listed, exit 1", "§8.3,§10",
              ["--precompile", "brokenlib"] + I + ["tests"], 1,
              any_has=["PRECOMPILE-ERROR", "tests/test_reverse.mojo"], any_absent=["PRECOMPILE-FAILED"]),
    ]
    # Refused v1 flags (§24.1): each names the flag and states it is the v1 contract.
    for flag, val, _cap in refused:
        checks.append(Check(f"refused: {flag} -> 4 names flag + v1 contract", "§24.1",
                            I + [flag, val, "tests"], 4, any_has=["v1 contract", flag]))
    # Served flags (§24.1): accepted on the clean suite -> 0, never the
    # not-available refusal.
    for flag, val, ref in served:
        checks.append(Check(f"served: {flag} accepted (not exit 4)", ref,
                            I + [flag, val, "tests"], 0, any_absent=["v1 contract"]))
    checks.append(Check("served: collect --shard partitions (not exit 4)", "§18,§24.1",
                        ["collect"] + I + ["--shard", "1/2", "tests"], 0, any_absent=["v1 contract"]))
    return checks


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description="Black-box contract validator for mtest.")
    ap.add_argument("-k", dest="filter", default="", help="substring filter over check names")
    ap.add_argument("--strict", action="store_true", help="a SKIP of a safety-critical check fails")
    ap.add_argument("--keep", action="store_true", help="keep the scaffolded temp project")
    ap.add_argument("--rebuild", action="store_true", help="force rebuild of build/mtest")
    ap.add_argument("--no-rebuild", action="store_true", help="never rebuild (may validate stale code)")
    ap.add_argument("--no-interrupt", action="store_true", help="skip the SIGINT check")
    ap.add_argument("-v", "--verbose", action="store_true", help="dump argv+streams on failure")
    args = ap.parse_args()

    env = pixi_env()
    ensure_binary(env, args.rebuild, allow_rebuild=not args.no_rebuild)

    root = Path(tempfile.mkdtemp(prefix="mtest-validate-"))
    try:
        scaffold(root)
        pc = subprocess.run(["mojo", "precompile", "textkit", "-o", "build/textkit.mojopkg"],
                            cwd=root, env=env, capture_output=True, text=True)
        if pc.returncode != 0:
            _die(f"could not precompile the scaffolded textkit package\n{pc.stdout}{pc.stderr}")
        # A mixed dir for the collect stream/continue check: a good file + a compile error.
        (root / "cmix").mkdir()
        (root / "cmix" / "test_ok.mojo").write_text(HEAD + "def test_ok() raises:\n    assert_equal(1, 1)\n" + MAIN)
        (root / "cmix" / "test_bad.mojo").write_text(HEAD + "def test_b() raises:\n    assert_equal(nope(), 0)\n" + MAIN)

        runner = Runner(root, env, args.verbose)
        print(f"mtest contract validator — binary: {MTEST}\n", flush=True)

        def wanted(name: str) -> bool:
            return not args.filter or args.filter in name

        for c in build_matrix():
            if wanted(c.name):
                runner.check(c)
        if wanted("collect: exact node-id set for tests/"):
            runner.check_collect_exact()
        if wanted("determinism: collect byte-identical"):
            runner.check_determinism()
        if wanted("help: --help -> stdout, exit 0") or wanted("usage error: -V -> stderr, exit 4"):
            runner.check_help_stream()
        if wanted("collect: streams split, listing continues past a bad probe"):
            runner.check_collect_streams()
        if wanted("color: --color always beats NO_COLOR"):
            runner.check_color()
        if wanted("precompile: success path resolves import (auto -I)"):
            runner.check_precompile_success()
        if not args.no_interrupt and wanted("interrupt: SIGINT frees the owned process group"):
            runner.check_interrupt(args.strict)

        n_pass = sum(1 for s, *_ in runner.results if s == PASS)
        n_fail = sum(1 for s, *_ in runner.results if s == FAIL)
        n_skip = sum(1 for s, *_ in runner.results if s == SKIP)
        ran = len(runner.results)
        print(f"\n===== {n_pass} passed, {n_fail} failed, {n_skip} skipped =====")
        if n_fail:
            print("\nFAILURES (contract clauses NOT upheld):")
            for s, name, ref, detail in runner.results:
                if s == FAIL:
                    print(f"  - {name}  ({ref}): {detail.splitlines()[0] if detail else ''}")
        if n_skip:
            print(f"\nNOTE: {n_skip} check(s) SKIPPED (not a pass). Use --strict to fail on skip.")
        if ran == 0:
            print("error: no checks ran (filter matched nothing) — not a pass", file=sys.stderr)
            return 2
        return 1 if n_fail else 0
    finally:
        if args.keep:
            print(f"\n(kept scaffold at {root})")
        else:
            try:
                shutil.rmtree(root)
            except OSError as e:
                print(f"warning: could not remove {root}: {e}", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
