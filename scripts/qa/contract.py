#!/usr/bin/env python3
"""Black-box contract-conformance validator for the mtest CLI.

The executable oracle behind the `validating-mtest` skill. It scaffolds a
throwaway Mojo project (a library, clean suites, deliberately-broken "poison"
files) outside the repo, drives the built `mtest` binary against it, and
asserts per check the exit code and the stdout/stderr content, every assertion
tagged with the `docs/cli-contract.md` section it enforces.

Design:
  * The contract is the oracle. A check asserts what the contract PROMISES
    rather than what the implementation happens to render. Console wording is
    informal (§20), so checks lean on the FROZEN surfaces: exit codes (§9), the
    `collect` listing (§16), stream routing (§16/§19), and outcome
    distinctions (§10).
  * The dominant defect class is SILENT test-set corruption: running the wrong
    SET while still printing a plausible green summary. So the oracle asserts
    the EXACT collected node-id set and EXACT counts, and uses POISON probes (a
    test that would FAIL or CRASH if it ran) so a broken selection, exclusion,
    or early stop flips the frozen exit code.
  * No false green. A run that selects zero checks, SKIPs a check under
    `--strict`, or did not perform every check on `EXPECTED_CHECK_NAMES` exits
    non-zero. The roster exists because deleting a check's call site is
    otherwise invisible: the remaining checks keep `ran > 0` and the gate
    prints "0 failed, 0 skipped". Setup failures exit 2, distinct from a
    contract failure's 1.
  * Freshness of the binary under test is enforced. `pixi run contract-check`
    rebuilds a missing-or-stale `build/mtest` before validating; the blocking
    `pixi run contract-check-strict` gate instead runs `--no-rebuild` against
    the binary its own Pixi `build-bin` dependency JUST produced, and fails
    closed (exit 2) if that binary is missing or looks stale.

Usage:
    pixi run contract-check --                         # rebuild-if-stale, run all
    pixi run contract-check -- -k selection            # filter by check name
    pixi run contract-check -- --strict                # SKIP -> failure
    pixi run contract-check -- --keep --no-rebuild -v
    pixi run contract-check-strict                     # the blocking release-floor gate

Exit: 0 all passed; 1 a contract check failed (or a --strict skip); 2 setup
failure (no toolchain, binary won't build, --no-rebuild found a missing/stale
binary, zero checks ran, or the roster of performed checks was incomplete).
"""

from __future__ import annotations

import argparse
import contextlib
from dataclasses import dataclass, field
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from typing import TYPE_CHECKING, NoReturn


if TYPE_CHECKING:
    from collections.abc import Callable


# --------------------------------------------------------------------------- #
# Repo + toolchain.
# --------------------------------------------------------------------------- #
def _die(msg: str) -> NoReturn:
    """Setup failure: exit 2, distinct from a contract-nonconformance exit 1."""
    print(f"setup: {msg}", file=sys.stderr)
    sys.exit(2)


def find_repo_root(start: Path) -> Path:
    """The nearest directory at or above `start` that holds a `pixi.toml`.

    Args:
        start: A path inside the repository, normally this module's own file.

    Returns:
        The first directory in `[start, *start.parents]` containing
        `pixi.toml`.

    Raises:
        SystemExit: No such directory exists. Nothing else here can be located
            without the repo root, so that is a setup failure (exit 2).
    """
    for d in [start, *start.parents]:
        if (d / "pixi.toml").is_file():
            return d
    _die("could not find repo root (no pixi.toml above this script)")


REPO = find_repo_root(Path(__file__).resolve())
MTEST = REPO / "build" / "mtest"


def pixi_env() -> dict[str, str]:
    """The environment `pixi run` activates (mojo/clang on PATH), as a dict.

    `MTEST_MOJO` is scrubbed: the scaffold library is precompiled with pixi's
    pinned mojo, so a caller's stray override would build tests with a different
    toolchain and manufacture false findings. §7 precedence gets its own check.
    """
    out = subprocess.run(
        ["pixi", "run", "bash", "-c", "env -0"],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=False,
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


# Every input whose change can change the bytes of build/mtest. This list is a
# fail-closed HEURISTIC for staleness, not a content-identity proof: mtimes can
# agree by coincidence and a touched-but-unchanged file looks "newer". The
# provenance guarantee for a strict run is the Pixi
# `contract-check-strict -> build-bin` task edge, which always rebuilds
# build/mtest from this exact tree immediately before this checker runs with
# `--no-rebuild`. This scan only fails closed if that edge was bypassed.
BINARY_INPUT_PATHS = [
    REPO / "src",
    REPO / "native",
    REPO / "scripts" / "build" / "production_build.sh",
    REPO / "scripts" / "build" / "native.py",
    REPO / "scripts" / "build" / "native_strict_flags.txt",
    REPO / "pixi.toml",
    REPO / "pixi.lock",
]


def _newest_mtime(paths: list[Path]) -> float:
    m = 0.0
    for p in paths:
        if p.is_dir():
            for f in p.rglob("*"):
                if f.is_file():
                    m = max(m, f.stat().st_mtime)
        elif p.is_file():
            m = max(m, p.stat().st_mtime)
    return m


def _run_build_bin(env: dict[str, str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(["pixi", "run", "build-bin"], cwd=REPO, env=env, check=False)


def ensure_binary(
    binary: Path,
    input_paths: list[Path],
    env: dict[str, str],
    rebuild: bool,
    allow_rebuild: bool,
    build: Callable[[dict[str, str]], subprocess.CompletedProcess[bytes]] | None = None,
) -> None:
    """Build `binary`, and REBUILD it when missing or older than any input.

    A stale binary validates the old code and reports a false green, which bit
    the project during its own QA pass. With `--no-rebuild`
    (`allow_rebuild=False`) a missing or stale binary is a setup failure
    (exit 2), since the caller forbade a build of our own.
    """
    if build is None:
        build = _run_build_bin
    missing = not binary.is_file()
    stale = not missing and binary.stat().st_mtime < _newest_mtime(input_paths)
    if not allow_rebuild:
        if missing:
            _die(
                f"{binary} is missing and --no-rebuild is set — this checker "
                "does not build on its own; run `pixi run build-bin` first "
                "(the contract-check-strict Pixi task does this for you)"
            )
        if stale:
            _die(
                f"{binary} is older than a binary input (src/, native/, the "
                "build scripts, pixi.toml, or pixi.lock) and --no-rebuild is "
                "set — refusing to validate stale bytes"
            )
        return
    if not missing and not rebuild and not stale:
        return
    why = "missing" if missing else ("forced" if rebuild else "stale")
    print(f"setup: building {binary} ({why}) ...", flush=True)
    r = build(env)
    if r.returncode != 0 or not binary.is_file():
        _die(f"could not build {binary}")


def wait_until(
    predicate: Callable[[], bool], deadline: float, poll_interval: float = 0.2
) -> bool:
    """Poll `predicate` until it holds or `deadline` passes, whichever is first.

    Returns True as soon as `predicate()` is true, False once `deadline` (a
    `time.time()`-comparable epoch) passes first. A readiness barrier rather
    than a fixed sleep: the caller sets the bound and gets an answer as soon as
    the condition is met.
    """
    while True:
        if predicate():
            return True
        if time.time() >= deadline:
            return False
        time.sleep(poll_interval)


# --------------------------------------------------------------------------- #
# Exact-process identification for the SIGINT probe. `mtest` builds each test
# file with `mojo build <file> -o <output> ...`, and both the compiler's command
# line and the exec'd binary's own path mention the mangled name, so a plain
# `pgrep -f <mangled-name>` scan matches the test binary AND, while it is still
# running, its own COMPILER. These helpers resolve that ambiguity by argv[0],
# which is the exec'd binary itself, not the compiler invoking it.
#
# `<output>` has three shapes, because the build cache moved where a
# first-attempt build lands:
#
#   build/bin/<mangled>                              (uncached, and every retry)
#   .mtest-cache/build-v1/.tmp-<mangled>-<pid>-<clock>-<attempt>/bin
#                                                    (staged, not yet published)
#   .mtest-cache/build-v1/<mangled>_h<digest32>/bin  (published generation)
#
# All three are matched. The middle one is what a supervised child actually runs
# for the duration of this probe: a first-attempt cached build compiles into
# staging and runs from there, and the rename into a generation happens only
# once the file's verdict is settled. Recognizing only the other two left
# `pgrep -f <mangled>` with nothing to match, so the SIGINT probe waited out its
# full readiness deadline and failed.
#
# The generation's digest (over the toolchain, the environment, the invocation
# root, and every include root's contents) and the staging name's pid, clock
# reading, and attempt index are all run-dependent, so none of them is pinned
# here: the assertions are the store prefix, the mangled name, the `_h`
# separator (which no mangled name can contain), and decimal-only tail fields.
# --------------------------------------------------------------------------- #

CACHE_STORE_PREFIX = ".mtest-cache/build-v1/"
"""Where `mtest` publishes a cached build, relative to the invocation root."""

CACHE_STAGING_PREFIX = ".tmp-"
"""Leading component of a staging directory's name, inside the store.

Mirrors `mtest.session.store._TMP_PREFIX`, kept as a literal rather than
derived: this module asserts the shipped shape from the outside, and a
derivation would agree with a regression instead of catching it.
"""

STAGING_TAIL_FIELDS = 3
"""Decimal fields a staging directory's name carries after the mangled name.

`store_build_target` composes `.tmp-<mangled>-<pid>-<clock>-<attempt>`, whose
last three fields are all-digit and dash-free. Splitting exactly that many
fields off the RIGHT keeps the mangled-name comparison exact even though a
mangled name may itself contain `-` (only `_` and `/` are escaped), so `a`
never matches `a-1`'s staging directory.
"""


def matching_pids(pattern: str) -> list[str]:
    """PIDs whose full command line contains `pattern` (`pgrep -f`).

    Raises `RuntimeError` if `pgrep` is unavailable or misbehaves. Callers route
    that through `_skip_or_fail_result`, so missing platform support is a
    failure under `--strict` rather than a silent pass.
    """
    try:
        r = subprocess.run(
            ["pgrep", "-f", pattern],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(f"pgrep unavailable: {e}") from e
    if r.returncode not in (0, 1):  # 1 == "no match", not an error
        raise RuntimeError(f"pgrep exited {r.returncode}: {r.stderr.strip()}")
    return [p for p in r.stdout.split() if p]


def process_argv0(pid: str) -> str:
    """The first whitespace-separated token of `pid`'s full command line.

    Deliberately `ps -o args=` rather than `ps -o comm=`: Linux truncates `comm`
    to 15 characters and a mangled test-binary name can be longer
    (`irq_stest_u1hang` is 16), so a `comm`-based comparison would fail to match
    the binary this probe must identify. Returns "" if the process has exited.
    """
    try:
        r = subprocess.run(
            ["ps", "-o", "args=", "-p", pid],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(f"ps unavailable: {e}") from e
    args = r.stdout.strip()
    return args.split(None, 1)[0] if args else ""


def process_state(pid: str) -> str:
    """`pid`'s one-letter process state (`ps -o state=`), or "" if gone."""
    try:
        r = subprocess.run(
            ["ps", "-o", "state=", "-p", pid],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(f"ps unavailable: {e}") from e
    return r.stdout.strip()[:1]


def _is_staging_dir(dir_name: str, mangled_name: str) -> bool:
    """Whether `dir_name` is `mangled_name`'s live staging directory.

    Exact rather than a prefix test. A mangled name may itself contain `-`
    (`_mangle` escapes only `_` and `/`), so `.tmp-a-` is a prefix of
    `.tmp-a-1-<pid>-<clock>-<attempt>` and a prefix test would let file `a`
    claim file `a-1`'s running child. The three trailing fields are the only
    fixed-shape part of the name: they are split off the right and required to
    be decimal, and whatever remains is compared to the mangled name whole.
    """
    if not dir_name.startswith(CACHE_STAGING_PREFIX):
        return False
    body = dir_name[len(CACHE_STAGING_PREFIX) :]
    parts = body.rsplit("-", STAGING_TAIL_FIELDS)
    if len(parts) != STAGING_TAIL_FIELDS + 1:
        return False
    return parts[0] == mangled_name and all(f.isdigit() for f in parts[1:])


def is_own_binary(argv0: str, mangled_name: str) -> bool:
    """Whether `argv0` is a test binary built from `mangled_name`'s source.

    True for the three `<output>` shapes above: the uncached output path, whose
    basename IS the mangled name; the staging directory a first-attempt cached
    build compiles into and RUNS from; and a published cache generation, whose
    binary is `bin` inside `<mangled>_h<digest32>`.

    False for a compiler that merely names any of them as its `-o` argument,
    since a compiler's argv[0] is the compiler.
    """
    if argv0.endswith(mangled_name):
        return True
    if not argv0.startswith(CACHE_STORE_PREFIX) or not argv0.endswith("/bin"):
        return False
    dir_name = argv0[len(CACHE_STORE_PREFIX) : -len("/bin")]
    if _is_staging_dir(dir_name, mangled_name):
        return True
    return f"/{mangled_name}_h" in argv0


def exact_process_pid(mangled_name: str) -> str | None:
    """The PID of the process whose OWN executable `mangled_name` built.

    Skips a `mojo build` compiler that merely mentions it as an `-o` argument.
    `None` if no such process is currently running.
    """
    for pid in matching_pids(mangled_name):
        argv0 = process_argv0(pid)
        if argv0 and is_own_binary(argv0, mangled_name):
            return pid
    return None


# The mangled binary name (see `mtest.session.scratch._mangle`) for the one
# file `check_interrupt` needs to still be hanging when it sends SIGINT:
# `irq/test_1hang.mojo` -> strip `.mojo`, escape `/` as `_s` and `_` as `_u`.
HANG_MANGLED_NAME = "irq_stest_u1hang"


def _default_killtree(proc: subprocess.Popen[str]) -> None:
    with contextlib.suppress(OSError, ProcessLookupError):
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    with contextlib.suppress(Exception):
        proc.wait(timeout=5)


def _skip_or_fail_result(strict: bool, detail: str) -> tuple[str, str]:
    if strict:
        return FAIL, detail + " (--strict: counted as failure)"
    return SKIP, detail


def run_interrupt_probe(
    spawn: Callable[[], subprocess.Popen[str]],
    hang_ready: Callable[[], bool],
    hang_present: Callable[[], bool],
    strict: bool,
    outer_deadline: float,
    orphan_timeout: float = 10.0,
    poll_interval: float = 0.2,
    killtree: Callable[[subprocess.Popen[str]], None] | None = None,
    send_sigint: Callable[[int], None] | None = None,
) -> tuple[str, str]:
    """Drive one SIGINT-frees-the-owned-child-group probe attempt.

    Returns `(status, detail)` with `status` one of `PASS`, `FAIL`, `SKIP`.
    This is the code path `Runner.check_interrupt` runs against the real
    `mtest` binary, kept free of `Runner`/`self` so the negative controls in
    `scripts/tests/test_contract.py` can drive it with a fake `spawn`, fake
    `hang_ready`/`hang_present` predicates, and a fake `send_sigint` instead of
    re-implementing this logic in the test.

    A `RuntimeError` from `hang_ready`/`hang_present` (missing platform process
    inspection) goes through `_skip_or_fail_result`: a FAIL under `--strict`, a
    SKIP otherwise. SIGINT is sent to `spawn()`'s process only once
    `hang_ready()` reports true, rather than on a fixed sleep. The readiness
    wait also exits before `outer_deadline` if the spawned process has already
    exited, since a dead supervisor will never spawn the hang child.
    """
    if killtree is None:
        killtree = _default_killtree
    if send_sigint is None:
        send_sigint = lambda pid: os.kill(pid, signal.SIGINT)  # noqa: E731
    try:
        proc = spawn()
    except OSError as e:
        return _skip_or_fail_result(strict, f"could not spawn: {e}")
    try:
        ready = False
        while True:
            try:
                if hang_ready():
                    ready = True
                    break
            except RuntimeError as e:
                proc.kill()
                return _skip_or_fail_result(strict, str(e))
            if proc.poll() is not None:
                break  # the supervisor exited; it will never spawn the child
            if time.time() >= outer_deadline:
                break
            time.sleep(poll_interval)
        if not ready:
            killtree(proc)
            return _skip_or_fail_result(strict, "child never became ready")
        # ONLY the supervisor: its teardown must free the child.
        send_sigint(proc.pid)
        try:
            out, _ = proc.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            killtree(proc)
            return FAIL, "did not exit within 30s of SIGINT"
        try:
            gone = wait_until(
                lambda: not hang_present(),
                time.time() + orphan_timeout,
                poll_interval=poll_interval,
            )
        except RuntimeError as e:
            killtree(proc)
            return _skip_or_fail_result(strict, str(e))
        orphan = not gone
        ok = proc.returncode == 2 and "not run" in out and not orphan
        if ok:
            return PASS, ""
        detail = f"exit {proc.returncode} (want 2); orphaned_child={orphan}"
        if orphan:
            detail += "; child survived cleanup"
        return FAIL, detail
    finally:
        killtree(proc)


# --------------------------------------------------------------------------- #
# Scaffold: a throwaway user project. Clean suites are all-pass with a KNOWN
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

MAIN = (
    "\n\ndef main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
HEAD = (
    "from textkit import reverse, is_palindrome\n"
    "from std.testing import assert_equal, assert_true, TestSuite\n\n\n"
)
CRASH_HEAD = (
    "from std.os import abort\nfrom std.testing import assert_equal, TestSuite\n\n\n"
)

# Exact node-id set the clean `tests/` walk must yield (sorted, root-relative).
EXPECTED_TESTS = [
    "tests/nested/test_nested.mojo::test_nested_ok",
    "tests/test_palindrome.mojo::test_palindrome_true",
    "tests/test_reverse.mojo::test_reverse_ab",
    "tests/test_reverse.mojo::test_reverse_empty",
]


def scaffold(root: Path) -> None:
    """Write the throwaway user project every check drives `mtest` against.

    Args:
        root: An existing empty directory that becomes the project root. It
            gains a `textkit` library, a `build/` output directory, the clean
            `tests/` tree whose node ids `EXPECTED_TESTS` pins exactly, and the
            poison suites whose tests fail or crash if a selection, exclusion,
            or early-stop clause lets them run.
    """

    def w(rel: str, body: str) -> None:
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)

    w("textkit/__init__.mojo", LIB)
    (root / "build").mkdir()

    # -- clean tests/: all pass, exact known set, + one NO-TESTS + one non-test.
    w(
        "tests/test_reverse.mojo",
        HEAD
        + 'def test_reverse_ab() raises:\n    assert_equal(reverse("ab"), "ba")\n\n\n'
        'def test_reverse_empty() raises:\n    assert_equal(reverse(""), "")\n' + MAIN,
    )
    w(
        "tests/test_palindrome.mojo",
        HEAD + "def test_palindrome_true() raises:\n"
        '    assert_true(is_palindrome("racecar"))\n' + MAIN,
    )
    w(
        "tests/nested/test_nested.mojo",
        HEAD
        + 'def test_nested_ok() raises:\n    assert_equal(reverse("x"), "x")\n'
        + MAIN,
    )
    w("tests/test_todo.mojo", "from std.testing import TestSuite\n" + MAIN)  # NO-TESTS
    w(
        "tests/helper.mojo",
        "from std.testing import TestSuite\n\n\n"
        "def make() -> Int:\n    return 1\n" + MAIN,
    )  # not a test_ file

    # -- poison: a test that FAILS/CRASHES if it runs (discriminates selection).
    w(
        "poison/test_pick.mojo",
        HEAD + 'def test_keep() raises:\n    assert_equal(reverse("ab"), "ba")\n\n\n'
        "def test_drop() raises:\n    assert_equal(1, 2)  # POISON: fails if run\n"
        + MAIN,
    )
    # -- excl: exclusion must REALLY remove test_bad (a crash), not just print it.
    w(
        "excl/test_ok.mojo",
        HEAD + "def test_ok() raises:\n    assert_equal(1, 1)\n" + MAIN,
    )
    w(
        "excl/test_bad.mojo",
        CRASH_HEAD
        + 'def test_bad() raises:\n    abort("POISON: crashes if run")\n'
        + MAIN,
    )
    # -- estop: first file FAILS; second would CRASH -> -x must not schedule it.
    w(
        "estop/test_a_fail.mojo",
        HEAD + "def test_a() raises:\n    assert_equal(1, 2)\n" + MAIN,
    )
    w(
        "estop/test_b_poison.mojo",
        CRASH_HEAD
        + 'def test_b() raises:\n    abort("POISON: -x must stop before here")\n'
        + MAIN,
    )
    # -- maxf: one failing test; sibling would CRASH -> --maxfail 1 must stop.
    w(
        "maxf/test_a_fail.mojo",
        HEAD + "def test_a() raises:\n    assert_equal(1, 2)\n" + MAIN,
    )
    w(
        "maxf/test_b_poison.mojo",
        CRASH_HEAD
        + 'def test_b() raises:\n    abort("POISON: --maxfail must stop before here")\n'
        + MAIN,
    )
    # -- gate: two passing files; a failing gate must abort BEFORE they run.
    w(
        "gate/test_g1.mojo",
        HEAD + "def test_g1() raises:\n    assert_equal(1, 1)\n" + MAIN,
    )
    w(
        "gate/test_g2.mojo",
        HEAD + "def test_g2() raises:\n    assert_equal(1, 1)\n" + MAIN,
    )
    w(
        "gatefail/test_smoke.mojo",
        HEAD + "def test_smoke() raises:\n    assert_equal(0, 1)\n" + MAIN,
    )

    # -- probe outcomes.
    w(
        "probes/test_fail.mojo",
        HEAD + "def test_x() raises:\n    assert_equal(1, 2)\n" + MAIN,
    )
    w(
        "probes/test_crash.mojo",
        CRASH_HEAD + 'def test_x() raises:\n    abort("boom")\n' + MAIN,
    )
    w(
        "probes/test_compile_error.mojo",
        HEAD
        + "def test_x() raises:\n    assert_equal(this_is_undefined(), 0)\n"
        + MAIN,
    )
    w("probes/test_malformed.mojo", "def main():\n    pass\n")
    w(
        "probes/test_hang.mojo",
        "from std.time import sleep\nfrom std.testing import TestSuite\n\n\n"
        "def test_x() raises:\n    while True:\n        sleep(3600.0)\n" + MAIN,
    )

    # -- protocol drift: a report present but OFF-GRAMMAR -> exit 3 (§6/§16),
    #    never laundered into a verdict. Mirrors e2e/hostile/test_liar.mojo.
    w(
        "drift/test_liar.mojo",
        "from std.testing import TestSuite, assert_true\n\n\n"
        "def test_one() raises:\n    assert_true(True)\n\n\n"
        "def main() raises:\n"
        "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
        '    print("Summary [ 0.00s ] 1 tests run: '
        '1 passed , 0 failed , 0 skipped ")\n',
    )

    # -- broken package for the precompile-failure path.
    w(
        "brokenlib/__init__.mojo",
        "def busted() -> Int:\n    return undefined_symbol_here()\n",
    )
    (root / "empty").mkdir()


# --------------------------------------------------------------------------- #
# Check model: separate streams; assert on the frozen surfaces.
# --------------------------------------------------------------------------- #
@dataclass
class Check:
    """One table-driven check: an argv, its frozen exit code, its stream text.

    Attributes:
        name: The roster name recorded for this check; it must appear in
            `EXPECTED_CHECK_NAMES` verbatim.
        ref: The `docs/cli-contract.md` section(s) this check enforces.
        argv: Arguments passed after the `mtest` binary path.
        exit: The exact exit code the contract freezes for this argv.
        out_has: Substrings that must appear in stdout.
        err_has: Substrings that must appear in stderr.
        any_has: Substrings that must appear in stdout or stderr.
        any_absent: Substrings that must appear in neither stream.
    """

    name: str
    ref: str
    argv: list[str]
    exit: int
    out_has: list[str] = field(default_factory=list)  # required in stdout
    err_has: list[str] = field(default_factory=list)  # required in stderr
    any_has: list[str] = field(default_factory=list)  # required in either
    any_absent: list[str] = field(default_factory=list)  # forbidden in either


PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"

EXPECTED_CHECK_NAMES: tuple[str, ...] = (
    "help: version prints the version",
    "outcome: passing tests/ -> 0, exact count",
    "outcome: FAIL -> 1",
    "outcome: CRASH is not a FAIL -> 1",
    "outcome: COMPILE-ERROR -> 1",
    "outcome: MALFORMED-SUITE -> 1",
    "outcome: NO-TESTS-only session -> 5",
    "outcome: TIMEOUT -> 1",
    "discover: nonexistent path -> 4 (stderr)",
    "discover: empty dir -> 5",
    "discover: explicit non-test_ file bypasses pattern",
    "discover: operand escaping root -> 4 (stderr)",
    "select: node id runs exactly one; sibling poison must NOT run",
    "select: -k selects the matching set",
    "select: -k case-insensitive",
    "select: -k matches nothing -> 5",
    "select: unknown test in a real file -> 4",
    "select: node id whose path is a DIRECTORY -> 4",
    "exclude: pattern truly removes a would-crash file (exit stays 0)",
    "exclude: stale pattern warns loudly",
    "exclude: everything excluded -> 5",
    "stop: -x stops scheduling; poison sibling stays NOT-RUN",
    "stop: --maxfail 1 stops; poison sibling stays NOT-RUN",
    "stop: failing --gate aborts the whole run (exact not-run)",
    "collect: --durations rejected in collect -> 4",
    "collect: --maxfail rejected in collect -> 4",
    "collect: --retries rejected in collect -> 4",
    "collect: --json rejected in collect -> 4",
    "collect: --junit-xml rejected in collect -> 4",
    "collect: --gh-annotations rejected in collect -> 4 (even off)",
    "collect: -k ignored with a loud notice (\u00a724.3 deviation)",
    "collect: node-id operand lists whole file (\u00a724.3 deviation)",
    "build-arg: -o forbidden -> 4, and the test never ran (pre-run, \u00a79)",
    "build-arg: --emit forbidden -> 4",
    "build-arg: extra source after -- forbidden -> 4",
    "exit-3: bad --mojo (spawn failure) -> 3",
    "exit-3: off-grammar report (drift) -> 3, never a verdict",
    "value: --durations negative -> 4",
    "value: --timeout non-integer -> 4",
    "value: --show-output bad mode -> 4",
    "value: --color bad mode -> 4",
    "value: -q and -v mutually exclusive -> 4",
    "precompile: failure -> PRECOMPILE-ERROR, casualties listed, exit 1",
    "served: -n accepted (not exit 4)",
    "served: --workers accepted (not exit 4)",
    "served: --serial accepted (not exit 4)",
    "served: --retries accepted (not exit 4)",
    "served: --compile-timeout accepted (not exit 4)",
    "served: --junit-xml accepted (not exit 4)",
    "served: --gh-annotations accepted (not exit 4)",
    "served: --json accepted (not exit 4)",
    "served: collect --shard partitions (not exit 4)",
    "collect: exact node-id set for tests/",
    "determinism: collect byte-identical",
    "help: --help -> stdout, exit 0",
    "usage error: -V -> stderr, exit 4",
    "collect: streams split, listing continues past a bad probe",
    "color: --color always beats NO_COLOR",
    "precompile: success path resolves import (auto -I)",
    "symlink: a symlinked test file is collected and run, never dropped",
    "shape: a test-named non-file walk entry is announced, never dropped",
    "shape: an unsupported operand is refused with its real problem",
    "value: 2^63 refused for every non-negative integer flag",
    "report: --json to a readerless FIFO fails fast, never blocks",
    "path: a long-but-legal path builds, never a false COMPILE-ERROR",
    "interrupt: SIGINT frees the owned process group",
)
"""Every check `main` must perform, in order, on an unfiltered run.

Written independently of `build_matrix` and of the dispatch below, so the gate
can notice a check it advertises but never ran. Deleting
`runner.check_interrupt(args.strict)` once left every unit test green, kept
`ran > 0` true from the other checks, and let both blocking
`contract-check-strict` lanes print "0 failed, 0 skipped" and exit 0 with the
SIGINT clause untested. Same shape as `package_consumption.GATE_STAGE_IDS`
against its stage ledger.

`check_help_stream` records two entries from one dispatch (`--help`, then
`-V`), so those names are adjacent here and move together.
"""


class ContractRosterError(Exception):
    """The gate did not perform the checks it reports."""


def verify_every_check_ran(performed: tuple[str, ...], filtered: bool) -> None:
    """Refuse to report a verdict unless the rostered checks actually ran.

    Args:
        performed: The check names `main` recorded, in the order recorded.
        filtered: Whether `--filter` narrowed the run. A filtered run cannot be
            complete, so it is held only to the weaker property that what ran
            is a subset of the roster in roster order, which catches a renamed
            or duplicated check but not a deleted one. The blocking
            `contract-check-strict` task passes no filter, and
            `test_pixi_task_uses_the_package_entry_point` pins that.

    Raises:
        ContractRosterError: A rostered check did not run, an unrostered check
            ran, or checks ran out of their declared order.
    """
    unknown = [name for name in performed if name not in EXPECTED_CHECK_NAMES]
    if unknown:
        raise ContractRosterError(
            f"contract gate ran checks that are not on its roster: {unknown}"
        )
    if not filtered:
        if performed != EXPECTED_CHECK_NAMES:
            missing = [n for n in EXPECTED_CHECK_NAMES if n not in performed]
            raise ContractRosterError(
                "the contract gate did not perform every check it reports: "
                f"ran {len(performed)} of {len(EXPECTED_CHECK_NAMES)}"
                + (f", missing {missing}" if missing else " in that order")
            )
        return
    expected_order = [n for n in EXPECTED_CHECK_NAMES if n in performed]
    if list(performed) != expected_order:
        raise ContractRosterError(
            "the contract gate ran a filtered subset out of roster order or "
            f"more than once: {list(performed)}"
        )


class Runner:
    """Drives the built binary against one scaffold and records each verdict."""

    def __init__(self, root: Path, env: dict[str, str], verbose: bool) -> None:
        """Bind the scaffold, the child environment, and failure verbosity.

        Args:
            root: The scaffolded project directory every `mtest` run uses as
                its working directory.
            env: The environment handed to every child process.
            verbose: Whether a failing check also dumps its argv and both
                captured streams.
        """
        self.root, self.env, self.verbose = root, env, verbose
        self.results: list[tuple[str, str, str, str]] = []

    def mtest(
        self, argv: list[str], timeout: int = 180
    ) -> subprocess.CompletedProcess[str]:
        """Run the binary under test inside the scaffold, capturing both streams.

        Args:
            argv: Arguments passed after the binary path.
            timeout: Seconds to wait before `subprocess.TimeoutExpired` is
                raised; callers turn that into a FAIL, never a pass.

        Returns:
            The completed process, with both streams decoded as text.
        """
        return subprocess.run(
            [str(MTEST), *argv],
            cwd=self.root,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )

    def record(self, status: str, name: str, ref: str, detail: str = "") -> None:
        """Append one verdict to `results` and print its line immediately.

        Recording is what makes a check countable: `verify_every_check_ran`
        reads `name` back out of `results`, so a check that runs without
        recording looks exactly like one that never ran.

        Args:
            status: One of `PASS`, `FAIL`, `SKIP`.
            name: The check's roster name, verbatim.
            ref: The contract section(s) the check enforces.
            detail: Diagnosis printed under the line for a non-PASS verdict.
        """
        self.results.append((status, name, ref, detail))
        mark = {PASS: "  ok ", FAIL: "FAIL ", SKIP: "skip "}[status]
        line = f"[{mark}] {name}  ({ref})"
        if detail and status != PASS:
            line += f"\n         {detail}"
        print(line, flush=True)

    def check(self, c: Check) -> None:
        """Run one table-driven check and record PASS or a FAIL listing every miss.

        A timeout is a FAIL: a binary that does not finish is itself a contract
        failure.

        Args:
            c: The check to run.
        """
        try:
            r = self.mtest(c.argv)
        except subprocess.TimeoutExpired:
            return self.record(
                FAIL, c.name, c.ref, f"timed out: mtest {' '.join(c.argv)}"
            )
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
                d += (
                    f"\n         argv: {c.argv}\n--- stdout ---\n{r.stdout}"
                    f"\n--- stderr ---\n{r.stderr}"
                )
            self.record(FAIL, c.name, c.ref, d)
        else:
            self.record(PASS, c.name, c.ref)
        return None

    # -- bespoke: exact collect set (the anti-silent-corruption oracle) -------- #
    def check_collect_exact(self) -> None:
        """Assert `collect` lists the EXACT expected node-id set, in sort order.

        A substring or count assertion passes while the wrong set is listed, so
        this compares the listing to `EXPECTED_TESTS` element for element and
        names the missing and the extra ids on failure.
        """
        ref = "§16 collect lists EXACTLY the discovered node ids, sorted (§5,§17)"
        name = "collect: exact node-id set for tests/"
        r = self.mtest(["collect", "-I", "build", "tests"])
        got = [ln for ln in r.stdout.splitlines() if "::" in ln]
        if r.returncode == 0 and got == EXPECTED_TESTS:
            self.record(PASS, name, ref)
        else:
            missing = [x for x in EXPECTED_TESTS if x not in got]
            extra = [x for x in got if x not in EXPECTED_TESTS]
            self.record(
                FAIL,
                name,
                ref,
                f"exit {r.returncode}; missing={missing}; extra={extra}; "
                f"sorted={got == sorted(got)}",
            )

    def check_determinism(self) -> None:
        """Assert two identical `collect` runs produce byte-identical stdout.

        An empty listing does not count as identical: both runs must also exit
        0 and print something, so a `collect` that stopped finding anything
        fails here instead of passing twice.
        """
        ref = "§17 machine output (collect) is byte-identical across runs"
        name = "determinism: collect byte-identical"
        a = self.mtest(["collect", "-I", "build", "tests"])
        b = self.mtest(["collect", "-I", "build", "tests"])
        ok = a.returncode == b.returncode == 0 and a.stdout == b.stdout and a.stdout
        self.record(
            PASS if ok else FAIL,
            name,
            ref,
            "" if ok else "two collect runs differed or were empty",
        )

    def check_help_stream(self) -> None:
        """Assert help goes to stdout and a usage error goes to stderr.

        Records TWO roster entries from this one dispatch, `--help` then `-V`,
        which is why those names are adjacent in `EXPECTED_CHECK_NAMES`.
        """
        # §19: --help -> STDOUT, exit 0. A usage error -> STDERR, exit 4.
        h = self.mtest(["--help"])
        self.record(
            PASS
            if (h.returncode == 0 and "usage:" in h.stdout and "usage:" not in h.stderr)
            else FAIL,
            "help: --help -> stdout, exit 0",
            "§19",
            ""
            if h.returncode == 0 and "usage:" in h.stdout
            else f"exit {h.returncode}; stdout has usage: {'usage:' in h.stdout}",
        )
        u = self.mtest(["-V"])
        self.record(
            PASS
            if (u.returncode == 4 and u.stderr.strip() and "usage:" not in u.stdout)
            else FAIL,
            "usage error: -V -> stderr, exit 4",
            "§19",
            ""
            if u.returncode == 4 and u.stderr.strip()
            else f"exit {u.returncode}; stderr empty={not u.stderr.strip()}",
        )

    def check_collect_streams(self) -> None:
        """Assert `collect` splits its streams and keeps listing past a bad file.

        Node ids belong on stdout and per-file diagnostics on stderr, so a
        consumer piping stdout gets only node ids even when one probed file
        fails to compile.
        """
        # §16: node ids -> STDOUT; per-file diagnostics -> STDERR; listing continues.
        ref = (
            "§16 collect: node ids to stdout, diagnostics to stderr, listing continues"
        )
        name = "collect: streams split, listing continues past a bad probe"
        r = self.mtest(["collect", "-I", "build", "cmix"])
        ok_nodes = "cmix/test_ok.mojo::test_ok" in r.stdout  # good file still listed
        diag_err = (
            "compile" in r.stderr.lower() or "error" in r.stderr.lower()
        )  # bad file -> stderr
        no_diag_out = "compile error" not in r.stdout.lower()
        ok = r.returncode == 1 and ok_nodes and diag_err and no_diag_out
        self.record(
            PASS if ok else FAIL,
            name,
            ref,
            ""
            if ok
            else f"exit {r.returncode}; good-node-in-stdout={ok_nodes}; "
            f"diag-in-stderr={diag_err}; clean-stdout={no_diag_out}",
        )

    def check_color(self) -> None:
        """Assert `--color never/always` behaves, and that the flag beats NO_COLOR.

        Each of the three runs is also held to exit 0 on the all-passing
        `tests/test_reverse.mojo`: an ANSI count alone is not an oracle,
        because a run that died after one colored banner still satisfies
        "always > 0".
        """
        # §15.1: --color never -> no ANSI; always -> ANSI; the flag wins over
        # NO_COLOR.
        ref = "§15.1 --color never/always; the flag wins over NO_COLOR"
        name = "color: --color always beats NO_COLOR"

        def esc(mode: str, no_color: bool) -> tuple[int, int]:
            e = dict(self.env)
            if no_color:
                e["NO_COLOR"] = "1"
            else:
                e.pop("NO_COLOR", None)
            r = subprocess.run(
                [str(MTEST), "-I", "build", "--color", mode, "tests/test_reverse.mojo"],
                cwd=self.root,
                env=e,
                capture_output=True,
                text=True,
                check=False,
            )
            return r.stdout.count("\x1b["), r.returncode

        never, never_rc = esc("never", False)
        always, always_rc = esc("always", False)
        wins, wins_rc = esc("always", True)  # flag must beat NO_COLOR (§15.1)
        exits = (never_rc, always_rc, wins_rc)
        ok = never == 0 and always > 0 and wins > 0 and exits == (0, 0, 0)
        self.record(
            PASS if ok else FAIL,
            name,
            ref,
            ""
            if ok
            else f"never={never}(0?) always={always}(>0?) "
            f"NO_COLOR+always={wins}(>0?) exits={exits}(all 0?)",
        )

    def check_precompile_success(self) -> None:
        """Assert a successful `--precompile` auto-adds its own `-I`.

        The dependent test resolves `from textkit import ...` with no manual
        `-I`, and both of its tests must PASS, which proves the auto-added
        include path reached the compiler rather than merely being logged.
        """
        ref = "§8.3 successful --precompile auto-adds -I; dependent test PASSes"
        name = "precompile: success path resolves import (auto -I)"
        r = self.mtest(["--precompile", "textkit", "tests/test_reverse.mojo"])
        ok = (
            r.returncode == 0
            and "PASS" in r.stdout
            and "2 passed" in (r.stdout + r.stderr)
        )
        self.record(
            PASS if ok else FAIL, name, ref, "" if ok else f"exit {r.returncode}"
        )

    def check_symlinked_test_file(self) -> None:
        """Assert a symlinked test file is neither dropped nor called malformed.

        Two defects met here: a directory walk skipped every symlink, so the
        linked tests did not run while the summary still read `0 excluded, 0
        not run`; and naming the link directly reported MALFORMED-SUITE,
        blaming a conforming module for the runner's own identity mismatch (the
        key was `realpath`, the child's report names the lexical path).

        The link points at a POISON file whose test FAILS, so a walk that drops
        it again flips the frozen exit code from 1 to 0 rather than merely
        changing text.
        """
        ref = "§2/§5/§6 a symlinked test file is discovered, run, and honestly judged"
        name = "symlink: a symlinked test file is collected and run, never dropped"
        d = self.root / "symlinked"
        d.mkdir(exist_ok=True)
        (d / "real").mkdir(exist_ok=True)
        (d / "real" / "test_target.mojo").write_text(
            HEAD + "def test_linked_ok() raises:\n"
            '    assert_equal(reverse("ab"), "ba")\n\n\n'
            "def test_linked_poison() raises:\n"
            "    assert_equal(1, 2)  # POISON: a dropped link would hide this\n" + MAIN
        )
        (d / "suite").mkdir(exist_ok=True)
        (d / "suite" / "test_plain.mojo").write_text(
            HEAD + "def test_plain_ok() raises:\n    assert_equal(1, 1)\n" + MAIN
        )
        link = d / "suite" / "test_linked.mojo"
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to("../real/test_target.mojo")

        # The walk must LIST the link's own node ids, under the link's path.
        c = self.mtest(["collect", "-I", "build", "symlinked/suite"])
        listed = sorted(line.strip() for line in c.stdout.splitlines() if "::" in line)
        want = [
            "symlinked/suite/test_linked.mojo::test_linked_ok",
            "symlinked/suite/test_linked.mojo::test_linked_poison",
            "symlinked/suite/test_plain.mojo::test_plain_ok",
        ]
        collected_exactly = c.returncode == 0 and listed == want

        # The poison test must actually RUN: exit 1, and never MALFORMED-SUITE.
        r = self.mtest(["-I", "build", "symlinked/suite"])
        ran_poison = r.returncode == 1
        not_malformed = "MALFORMED" not in (r.stdout + r.stderr).upper()

        # Naming the link directly must judge it honestly too.
        one = self.mtest(["-I", "build", "symlinked/suite/test_linked.mojo"])
        direct_ok = (
            one.returncode == 1 and "MALFORMED" not in (one.stdout + one.stderr).upper()
        )

        ok = collected_exactly and ran_poison and not_malformed and direct_ok
        self.record(
            PASS if ok else FAIL,
            name,
            ref,
            ""
            if ok
            else f"collect exit {c.returncode} listed={listed}; "
            f"walk exit {r.returncode} (1 = the linked poison ran); "
            f"not-malformed={not_malformed}; direct-operand-ok={direct_ok}",
        )

    def check_nonregular_walk_entry(self) -> None:
        """Assert a test-named non-file is announced, never silently dropped.

        Two shapes wear a test file's name without being one: a DIRECTORY
        called `test_*.mojo`, which the walk used to descend — running tests
        from under a name nothing treats as a container — and a FIFO, which
        the walk used to pass over in total silence, shrinking the run with no
        trace. Both are skipped now, and both are reported.

        The directory holds a POISON test whose body FAILS, so descending it
        again flips the exit code from 0 to 1 rather than merely changing text.
        A NON-test-named FIFO stays silent: it cannot hide a test, so warning
        about it would be noise.
        """
        ref = "§5 a test-named entry mtest cannot run is skipped and reported"
        name = "shape: a test-named non-file walk entry is announced, never dropped"
        d = self.root / "probes_shape"
        d.mkdir(exist_ok=True)
        (d / "test_plain.mojo").write_text(
            HEAD + "def test_shape_plain_ok() raises:\n"
            '    assert_equal(reverse("ab"), "ba")\n' + MAIN
        )
        shape_dir = d / "test_shape.mojo"
        shape_dir.mkdir(exist_ok=True)
        (shape_dir / "test_inside.mojo").write_text(
            HEAD + "def test_inside_poison() raises:\n"
            "    assert_equal(1, 2)  # POISON: a descended directory runs this\n" + MAIN
        )

        # Overlapping operands walk the tree twice, so the announcement must
        # still arrive exactly once: a doubled warning is its own dishonesty.
        r = self.mtest(["-I", "build", "probes_shape", "probes_shape"])
        both = r.stdout + r.stderr
        warned = [ln for ln in both.splitlines() if "skipped-nonregular" in ln]
        dir_ok = (
            r.returncode == 0
            and "1 passed" in both
            and "test_inside" not in both
            and len(warned) == 1
            and "test_shape.mojo" in warned[0]
        )
        if not dir_ok:
            self.record(
                FAIL,
                name,
                ref,
                f"directory entry: exit {r.returncode} (want 0); warnings={warned}",
            )
            return

        f = self.root / "probes_fifo"
        f.mkdir(exist_ok=True)
        (f / "test_plain.mojo").write_text(
            HEAD + "def test_fifo_plain_ok() raises:\n"
            '    assert_equal(reverse("ab"), "ba")\n' + MAIN
        )
        named = f / "test_pipe.mojo"
        unnamed = f / "events.fifo"
        for p in (named, unnamed):
            if p.exists() or p.is_symlink():
                p.unlink()
        try:
            os.mkfifo(named)
            os.mkfifo(unnamed)
        except (OSError, AttributeError) as e:  # no FIFO support on this host
            named.unlink(missing_ok=True)
            self.record(
                SKIP, name, ref, f"directory entry held; mkfifo unavailable: {e}"
            )
            return
        try:
            r2 = self.mtest(["-I", "build", "probes_fifo"])
        finally:
            named.unlink(missing_ok=True)
            unnamed.unlink(missing_ok=True)
        both2 = r2.stdout + r2.stderr
        warned2 = [ln for ln in both2.splitlines() if "skipped-nonregular" in ln]
        ok = (
            r2.returncode == 0
            and "1 passed" in both2
            and len(warned2) == 1
            and "test_pipe.mojo" in warned2[0]
            and "events.fifo" not in both2
        )
        self.record(
            PASS if ok else FAIL,
            name,
            ref,
            ""
            if ok
            else f"fifo entry: exit {r2.returncode} (want 0); warnings={warned2}",
        )

    def check_unsupported_operand(self) -> None:
        """Assert an operand mtest cannot run names its real problem.

        A FIFO, socket, or device named directly was refused with
        `no such path` — a false statement about a path that plainly exists,
        which sends the reader hunting for a typo instead of the pipe sitting
        where a test file belongs. The refusal keeps its exit-4 class and now
        says what was actually found. The node-id spelling reaches the same
        classification, so it must answer the same way.
        """
        ref = "§5/§9 an operand of an unsupported file type -> 4, named honestly"
        name = "shape: an unsupported operand is refused with its real problem"
        d = self.root / "probes_operand"
        d.mkdir(exist_ok=True)
        pipe = d / "test_pipe.mojo"
        if pipe.exists() or pipe.is_symlink():
            pipe.unlink()
        try:
            os.mkfifo(pipe)
        except (OSError, AttributeError) as e:  # no FIFO support on this host
            self.record(SKIP, name, ref, f"mkfifo unavailable: {e}")
            return
        bad = []
        try:
            for operand in (
                "probes_operand/test_pipe.mojo",
                "probes_operand/test_pipe.mojo::test_x",
            ):
                r = self.mtest(["-I", "build", operand])
                both = r.stdout + r.stderr
                if r.returncode != 4:
                    bad.append(f"{operand} -> exit {r.returncode} (want 4)")
                if "unsupported file type" not in both:
                    bad.append(f"{operand} -> no unsupported-file-type diagnostic")
                if "no such path" in both:
                    bad.append(f"{operand} -> still claims 'no such path'")
        finally:
            pipe.unlink(missing_ok=True)
        ok = not bad
        self.record(PASS if ok else FAIL, name, ref, "" if ok else "; ".join(bad))

    def check_integer_overflow_values(self) -> None:
        """Assert the decimal values `atol` wraps are refused, not accepted.

        `atol` does not raise across the whole out-of-range domain: at exactly
        `2^63` and `2^63 + 1` it wraps to `Int.MIN`. These flags all treat
        their value as non-negative, so a wrapped value silently disabled
        `--timeout` and defeated `--maxfail` while the run still exited 0.
        Refusal is a §3 usage error, detected before any test runs.
        """
        ref = "§3 an out-of-range integer is a usage error (exit 4), pre-run"
        name = "value: 2^63 refused for every non-negative integer flag"
        bad = []
        for flag in (
            "--timeout",
            "--compile-timeout",
            "--maxfail",
            "--retries",
            "--durations",
        ):
            for value in ("9223372036854775808", "9223372036854775809"):
                r = self.mtest(["-I", "build", flag, value, "tests/"])
                if r.returncode != 4:
                    bad.append(f"{flag} {value} -> exit {r.returncode}")
        # The neighbour below the wrap must still be ACCEPTED: the guard must
        # reject what wraps, not simply narrow the legal domain.
        edge = self.mtest(["-I", "build", "--timeout", "9223372036854775807", "tests/"])
        if edge.returncode == 4:
            bad.append("--timeout 2^63-1 wrongly refused")
        ok = not bad
        self.record(PASS if ok else FAIL, name, ref, "" if ok else "; ".join(bad))

    def check_json_fifo_does_not_block(self) -> None:
        """Assert a readerless FIFO destination fails fast instead of hanging.

        A plain write-open of a FIFO with no reader blocks forever, and it
        happens before the session starts, so `--timeout` cannot bound it: the
        run produced no output and no exit code until something external killed
        it. §9 gives a runtime report-destination failure exit 3. The probe's
        own timeout separates a true block from mere slowness, and
        `TimeoutExpired` is recorded as a FAIL.
        """
        ref = "§9/§15.4 a report destination must resolve, never wedge the run"
        name = "report: --json to a readerless FIFO fails fast, never blocks"
        fifo = self.root / "readerless.fifo"
        if fifo.exists() or fifo.is_symlink():
            fifo.unlink()
        try:
            os.mkfifo(fifo)
        except (OSError, AttributeError) as e:  # no FIFO support on this host
            self.record(SKIP, name, ref, f"mkfifo unavailable: {e}")
            return
        try:
            r = self.mtest(
                ["-I", "build", "--json", str(fifo), "tests/test_palindrome.mojo"],
                timeout=60,
            )
        except subprocess.TimeoutExpired:
            self.record(FAIL, name, ref, "mtest blocked on open(FIFO); killed at 60s")
            return
        finally:
            fifo.unlink(missing_ok=True)
        ok = r.returncode == 3
        self.record(
            PASS if ok else FAIL,
            name,
            ref,
            "" if ok else f"exit {r.returncode} (want 3); stderr={r.stderr[:200]!r}",
        )

    def check_long_path_builds(self) -> None:
        """Assert a legal-but-deep path builds instead of blaming the source.

        The binary name is the whole source path flattened into ONE component,
        so depth becomes filename length. `PATH_MAX` (4096) caps a path but
        `NAME_MAX` (255) caps a component, so a path well inside both limits
        could still mangle past `NAME_MAX`. The build then failed and was
        reported COMPILE-ERROR, inverting §6 fault attribution: the source
        compiles, and mtest's own output name was the illegal thing.
        """
        ref = "§5/§6 a legal source path builds; COMPILE-ERROR means the module's fault"
        name = "path: a long-but-legal path builds, never a false COMPILE-ERROR"
        deep = self.root / "deep"
        # The trigger is the RELATIVE path, since that is what becomes one
        # component: 20 x 16 bytes puts it past NAME_MAX (255) while the
        # absolute path stays near 450. That matters because macOS caps
        # PATH_MAX at 1024 rather than Linux's 4096; the first draft built a
        # ~1040-byte path and died with ENAMETOOLONG on Darwin before it could
        # assert anything.
        for i in range(20):
            deep = deep / f"d{i:02d}abcdefghijkl"
        deep.mkdir(parents=True, exist_ok=True)
        (deep / "test_deep.mojo").write_text(
            HEAD
            + 'def test_deep_ok() raises:\n    assert_equal(reverse("ab"), "ba")\n'
            + MAIN
        )
        rel = (deep / "test_deep.mojo").relative_to(self.root).as_posix()
        if len(rel) <= 255:  # the geometry drifted and no longer probes anything
            self.record(
                FAIL,
                name,
                ref,
                f"probe is inert: rel is {len(rel)} bytes, needs > 255 (NAME_MAX)",
            )
            return
        r = self.mtest(["-I", "build", "deep"])
        ok = r.returncode == 0 and "COMPILE-ERROR" not in (r.stdout + r.stderr)
        self.record(
            PASS if ok else FAIL,
            name,
            ref,
            ""
            if ok
            else f"exit {r.returncode} for a {len(rel)}-byte path "
            f"(PATH_MAX 4096); stderr={r.stderr[:200]!r}",
        )

    # -- interrupt: signal ONLY mtest, so the child's survival tests mtest's own
    #    process-group teardown (§18/§24.2) rather than a signal the child caught.
    def check_interrupt(self, strict: bool) -> None:
        """Assert SIGINT to `mtest` alone frees the child process group it owns.

        Writes the hanging and passing suites this needs, then hands the real
        `spawn` and process-inspection predicates to `run_interrupt_probe`, the
        shared code path the negative controls in
        `scripts/tests/test_contract.py` drive with fakes.

        Args:
            strict: Whether a SKIP from the probe is recorded as a FAIL,
                mirroring `--strict`.
        """
        ref = "§9/§24.2 SIGINT -> exit 2, partial summary, owned child group freed"
        name = "interrupt: SIGINT frees the owned process group"
        (self.root / "irq").mkdir(exist_ok=True)
        (self.root / "irq" / "test_1hang.mojo").write_text(
            "from std.time import sleep\nfrom std.testing import TestSuite\n\n\n"
            "def test_h() raises:\n    while True:\n        sleep(3600.0)\n" + MAIN
        )
        (self.root / "irq" / "test_2pass.mojo").write_text(
            HEAD + "def test_p() raises:\n    assert_equal(1, 1)\n" + MAIN
        )

        def spawn() -> subprocess.Popen[str]:
            return subprocess.Popen(
                [str(MTEST), "-I", "build", "--timeout", "0", "irq"],
                cwd=self.root,
                env=self.env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )

        def hang_present() -> bool:
            return exact_process_pid(HANG_MANGLED_NAME) is not None

        def hang_ready() -> bool:
            pid = exact_process_pid(HANG_MANGLED_NAME)
            return pid is not None and process_state(pid) == "S"

        status, detail = run_interrupt_probe(
            spawn, hang_ready, hang_present, strict, time.time() + 120
        )
        self.record(status, name, ref, detail)


# --------------------------------------------------------------------------- #
# Matrix.
# --------------------------------------------------------------------------- #
def build_matrix() -> list[Check]:
    """The table-driven checks, in the order `EXPECTED_CHECK_NAMES` lists them.

    Returns:
        Every `Check` whose whole assertion is an exit code plus stream text.
        Checks needing more than that (an exact node-id set, two runs
        compared, a signal) are `Runner` methods instead, and the roster
        covers both kinds.
    """
    # `I` names the `-I` include flag every argv below carries.
    I = ["-I", "build"]  # noqa: E741, N806
    # Nothing is refused in this build (§24.1). The refused machinery stays,
    # driving zero checks, so the served/refused loop below still compiles.
    refused: list[tuple[str, str, str]] = []
    # Newly served (§24.1): --retries, --compile-timeout, --shard, --junit-xml,
    # --gh-annotations, and --json are wired up, so none of them may exit 4 with
    # the not-available refusal. Behavior coverage lives in the e2e suite.
    served = [
        ("-n", "2", "§18,§24.1"),
        ("--workers", "2", "§18,§24.1"),
        ("--serial", "*.mojo", "§18,§24.1"),
        ("--retries", "2", "§13,§24.1"),
        ("--compile-timeout", "600", "§18,§24.1"),
        ("--junit-xml", "r.xml", "§15.2,§24.1"),
        ("--gh-annotations", "auto", "§15.3,§24.1"),
        # A file destination: "-" would make --json own stdout, which collides
        # with the default --gh-annotations auto (§15.3), a deliberate usage
        # error distinct from the "not served" refusal this check probes.
        ("--json", "out.ndjson", "§15.4,§24.1"),
    ]
    checks = [
        # Version identity (§19): the version string, not a bare "mtest".
        Check(
            "help: version prints the version",
            "§19",
            ["version"],
            0,
            out_has=["mtest 1.0.0"],
        ),
        # Outcomes + FROZEN exit codes (§9,§10). CRASH must stay distinct from
        # FAIL (§10).
        Check(
            "outcome: passing tests/ -> 0, exact count",
            "§9,§10",
            [*I, "tests"],
            0,
            any_has=["4 passed", "NO-TESTS"],
        ),
        Check(
            "outcome: FAIL -> 1",
            "§9,§10",
            [*I, "probes/test_fail.mojo"],
            1,
            any_has=["FAIL"],
        ),
        Check(
            "outcome: CRASH is not a FAIL -> 1",
            "§10",
            [*I, "probes/test_crash.mojo"],
            1,
            any_has=["CRASH"],
            any_absent=["FAIL "],
        ),
        Check(
            "outcome: COMPILE-ERROR -> 1",
            "§6,§9",
            [*I, "probes/test_compile_error.mojo"],
            1,
            any_has=["COMPILE-ERROR"],
        ),
        Check(
            "outcome: MALFORMED-SUITE -> 1",
            "§6",
            [*I, "probes/test_malformed.mojo"],
            1,
            any_has=["MALFORMED-SUITE"],
        ),
        Check(
            "outcome: NO-TESTS-only session -> 5",
            "§9(nothing collected)",
            [*I, "tests/test_todo.mojo"],
            5,
            any_has=["NO-TESTS"],
        ),
        Check(
            "outcome: TIMEOUT -> 1",
            "§18",
            [*I, "--timeout", "3", "probes/test_hang.mojo"],
            1,
            any_has=["TIMEOUT"],
        ),
        # Discovery (§5).
        Check(
            "discover: nonexistent path -> 4 (stderr)",
            "§5",
            [*I, "tests/nope.mojo"],
            4,
            err_has=["discover"],
        ),
        Check("discover: empty dir -> 5", "§5,§9", [*I, "empty"], 5),
        Check(
            "discover: explicit non-test_ file bypasses pattern",
            "§5",
            [*I, "tests/helper.mojo"],
            5,
            any_has=["NO-TESTS"],
        ),
        Check(
            "discover: operand escaping root -> 4 (stderr)",
            "§2",
            [*I, ".."],
            4,
            err_has=["discover"],
        ),  # structural prefix, not the informal sentence
        # Selection (§5): exact counts + POISON, so a broken filter flips the code.
        Check(
            "select: node id runs exactly one; sibling poison must NOT run",
            "§5,§10.1",
            [*I, "poison/test_pick.mojo::test_keep"],
            0,
            any_has=["1 passed", "1 deselected"],
            any_absent=["CRASH", "test_drop"],
        ),
        Check(
            "select: -k selects the matching set",
            "§5",
            [*I, "-k", "reverse", "tests"],
            0,
            any_has=["2 passed"],
        ),
        Check(
            "select: -k case-insensitive",
            "§5",
            [*I, "-k", "REVERSE", "tests"],
            0,
            any_has=["2 passed"],
        ),
        Check(
            "select: -k matches nothing -> 5",
            "§5,§9",
            [*I, "-k", "zzzznope", "tests"],
            5,
        ),
        Check(
            "select: unknown test in a real file -> 4",
            "§5",
            [*I, "tests/test_reverse.mojo::ghost"],
            4,
        ),
        Check(
            "select: node id whose path is a DIRECTORY -> 4",
            "§5",
            [*I, "tests::test_reverse_ab"],
            4,
        ),
        # Exclusion (§12): the POISON crash file must be REALLY removed.
        Check(
            "exclude: pattern truly removes a would-crash file (exit stays 0)",
            "§12",
            [*I, "--exclude", "*_bad.mojo", "excl"],
            0,
            any_has=["EXCLUDED"],
            any_absent=["CRASH"],
        ),
        Check(
            "exclude: stale pattern warns loudly",
            "§12",
            [*I, "--exclude", "*_missing.mojo", "tests"],
            0,
            any_has=["stale"],
        ),
        Check(
            "exclude: everything excluded -> 5",
            "§12,§9",
            [*I, "--exclude", "*", "excl"],
            5,
        ),
        # Early stop (§11): the not-run COUNT discriminates (poison sibling).
        Check(
            "stop: -x stops scheduling; poison sibling stays NOT-RUN",
            "§11",
            [*I, "-x", "estop"],
            1,
            any_has=["1 not run"],
            any_absent=["POISON must stop", "test_b"],
        ),
        Check(
            "stop: --maxfail 1 stops; poison sibling stays NOT-RUN",
            "§11",
            [*I, "--maxfail", "1", "maxf"],
            1,
            any_has=["1 not run"],
            any_absent=["test_b"],
        ),
        Check(
            "stop: failing --gate aborts the whole run (exact not-run)",
            "§11",
            [*I, "--gate", "gatefail/test_smoke.mojo", "gate"],
            1,
            any_has=["2 not run"],
        ),
        # collect (§16) + run-only rejection (§4) + §24.3 documented deviations.
        Check(
            "collect: --durations rejected in collect -> 4",
            "§4",
            ["collect", *I, "--durations", "3", "tests"],
            4,
        ),
        Check(
            "collect: --maxfail rejected in collect -> 4",
            "§4",
            ["collect", *I, "--maxfail", "1", "tests"],
            4,
        ),
        Check(
            "collect: --retries rejected in collect -> 4",
            "§4",
            ["collect", *I, "--retries", "1", "tests"],
            4,
        ),
        Check(
            "collect: --json rejected in collect -> 4",
            "§4",
            ["collect", *I, "--json", "out.ndjson", "tests"],
            4,
        ),
        Check(
            "collect: --junit-xml rejected in collect -> 4",
            "§4",
            ["collect", *I, "--junit-xml", "r.xml", "tests"],
            4,
        ),
        Check(
            "collect: --gh-annotations rejected in collect -> 4 (even off)",
            "§4",
            ["collect", *I, "--gh-annotations", "off", "tests"],
            4,
        ),
        Check(
            "collect: -k ignored with a loud notice (§24.3 deviation)",
            "§24.3",
            ["collect", *I, "-k", "reverse", "tests"],
            0,
            any_has=["ignored", "test_palindrome_true"],
        ),  # notice + un-filtered listing
        Check(
            "collect: node-id operand lists whole file (§24.3 deviation)",
            "§24.3",
            ["collect", *I, "tests/test_reverse.mojo::test_reverse_ab"],
            0,
            any_has=["test_reverse_ab", "test_reverse_empty"],
        ),
        # Forbidden build args (§8.4), detected pre-run (the poison never runs).
        Check(
            "build-arg: -o forbidden -> 4, and the test never ran (pre-run, §9)",
            "§8.4,§9",
            [*I, "--build-arg", "-o", "--build-arg", "x", "poison/test_pick.mojo"],
            4,
            any_absent=["1 passed", "CRASH"],
        ),
        Check(
            "build-arg: --emit forbidden -> 4",
            "§8.4",
            [*I, "--build-arg", "--emit=llvm", "tests/test_reverse.mojo"],
            4,
        ),
        Check(
            "build-arg: extra source after -- forbidden -> 4",
            "§8.4",
            [*I, "tests/test_reverse.mojo", "--", "extra.mojo"],
            4,
        ),
        # Internal error (§24.2): spawn failure and protocol drift both -> 3.
        Check(
            "exit-3: bad --mojo (spawn failure) -> 3",
            "§24.2",
            [*I, "--mojo", "/nonexistent/mojo", "tests/test_reverse.mojo"],
            3,
        ),
        Check(
            "exit-3: off-grammar report (drift) -> 3, never a verdict",
            "§6,§16,§24.2",
            [*I, "drift/test_liar.mojo"],
            3,
        ),
        # Value validation (§3,§15.1).
        Check(
            "value: --durations negative -> 4",
            "§3",
            [*I, "--durations", "-1", "tests"],
            4,
        ),
        Check(
            "value: --timeout non-integer -> 4",
            "§3",
            [*I, "--timeout", "abc", "tests"],
            4,
        ),
        Check(
            "value: --show-output bad mode -> 4",
            "§3",
            [*I, "--show-output", "bogus", "tests"],
            4,
        ),
        Check(
            "value: --color bad mode -> 4", "§3", [*I, "--color", "bogus", "tests"], 4
        ),
        Check(
            "value: -q and -v mutually exclusive -> 4",
            "§15.1",
            [*I, "-q", "-v", "tests"],
            4,
        ),
        # Precompile failure (§8.3): pass a DIRECTORY, so the casualty path
        # cannot be an operand echo and its presence proves it was listed.
        Check(
            "precompile: failure -> PRECOMPILE-ERROR, casualties listed, exit 1",
            "§8.3,§10",
            ["--precompile", "brokenlib", *I, "tests"],
            1,
            any_has=["PRECOMPILE-ERROR", "tests/test_reverse.mojo"],
            any_absent=["PRECOMPILE-FAILED"],
        ),
    ]
    # Refused v1 flags (§24.1): each names the flag and states it is the v1 contract.
    for flag, val, _cap in refused:
        checks.append(
            Check(
                f"refused: {flag} -> 4 names flag + v1 contract",
                "§24.1",
                [*I, flag, val, "tests"],
                4,
                any_has=["v1 contract", flag],
            )
        )
    # Served flags (§24.1): accepted on the clean suite -> 0, with no
    # not-available refusal.
    for flag, val, ref in served:
        checks.append(
            Check(
                f"served: {flag} accepted (not exit 4)",
                ref,
                [*I, flag, val, "tests"],
                0,
                any_absent=["v1 contract"],
            )
        )
    checks.append(
        Check(
            "served: collect --shard partitions (not exit 4)",
            "§18,§24.1",
            ["collect", *I, "--shard", "1/2", "tests"],
            0,
            any_absent=["v1 contract"],
        )
    )
    return checks


# --------------------------------------------------------------------------- #
def main() -> int:
    """Scaffold a throwaway project, run every check against it, and report.

    Returns:
        0 when every performed check passed, 1 when a contract check failed
        (or `--strict` saw a SKIP), and 2 for a setup failure: no toolchain,
        an unbuildable or stale binary, zero checks matched the filter, or a
        roster of performed checks that does not match
        `EXPECTED_CHECK_NAMES`. The scaffold is removed unless `--keep`.
    """
    ap = argparse.ArgumentParser(description="Black-box contract validator for mtest.")
    ap.add_argument(
        "-k", dest="filter", default="", help="substring filter over check names"
    )
    ap.add_argument(
        "--strict", action="store_true", help="a SKIP of a safety-critical check fails"
    )
    ap.add_argument(
        "--keep", action="store_true", help="keep the scaffolded temp project"
    )
    ap.add_argument(
        "--rebuild", action="store_true", help="force rebuild of build/mtest"
    )
    ap.add_argument(
        "--no-rebuild",
        action="store_true",
        help="never rebuild (may validate stale code)",
    )
    ap.add_argument("--no-interrupt", action="store_true", help="skip the SIGINT check")
    ap.add_argument(
        "-v", "--verbose", action="store_true", help="dump argv+streams on failure"
    )
    args = ap.parse_args()

    env = pixi_env()
    ensure_binary(
        MTEST, BINARY_INPUT_PATHS, env, args.rebuild, allow_rebuild=not args.no_rebuild
    )

    root = Path(tempfile.mkdtemp(prefix="mtest-validate-"))
    try:
        scaffold(root)
        pc = subprocess.run(
            ["mojo", "precompile", "textkit", "-o", "build/textkit.mojopkg"],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        if pc.returncode != 0:
            _die(
                "could not precompile the scaffolded textkit package\n"
                f"{pc.stdout}{pc.stderr}"
            )
        # A mixed dir for the collect stream/continue check: a good file + a
        # compile error.
        (root / "cmix").mkdir()
        (root / "cmix" / "test_ok.mojo").write_text(
            HEAD + "def test_ok() raises:\n    assert_equal(1, 1)\n" + MAIN
        )
        (root / "cmix" / "test_bad.mojo").write_text(
            HEAD + "def test_b() raises:\n    assert_equal(nope(), 0)\n" + MAIN
        )

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
        if wanted("help: --help -> stdout, exit 0") or wanted(
            "usage error: -V -> stderr, exit 4"
        ):
            runner.check_help_stream()
        if wanted("collect: streams split, listing continues past a bad probe"):
            runner.check_collect_streams()
        if wanted("color: --color always beats NO_COLOR"):
            runner.check_color()
        if wanted("precompile: success path resolves import (auto -I)"):
            runner.check_precompile_success()
        if wanted("symlink: a symlinked test file is collected and run, never dropped"):
            runner.check_symlinked_test_file()
        if wanted(
            "shape: a test-named non-file walk entry is announced, never dropped"
        ):
            runner.check_nonregular_walk_entry()
        if wanted("shape: an unsupported operand is refused with its real problem"):
            runner.check_unsupported_operand()
        if wanted("value: 2^63 refused for every non-negative integer flag"):
            runner.check_integer_overflow_values()
        if wanted("report: --json to a readerless FIFO fails fast, never blocks"):
            runner.check_json_fifo_does_not_block()
        if wanted("path: a long-but-legal path builds, never a false COMPILE-ERROR"):
            runner.check_long_path_builds()
        if wanted("interrupt: SIGINT frees the owned process group"):
            if args.no_interrupt:
                # Recorded rather than bypassed: testing --no-interrupt BEFORE
                # wanted() gated the check off before --strict could observe a
                # SKIP, letting a blocking lane drop the one skip-sensitive
                # clause without leaving a trace.
                runner.record(
                    SKIP,
                    "interrupt: SIGINT frees the owned process group",
                    "§9/§24.2 SIGINT -> exit 2, partial summary, owned child "
                    "group freed",
                    "skipped by --no-interrupt",
                )
            else:
                runner.check_interrupt(args.strict)

        try:
            verify_every_check_ran(
                tuple(name for _, name, _, _ in runner.results),
                filtered=bool(args.filter),
            )
        except ContractRosterError as e:
            print(f"error: {e}", file=sys.stderr)
            return 2

        n_pass = sum(1 for s, *_ in runner.results if s == PASS)
        n_fail = sum(1 for s, *_ in runner.results if s == FAIL)
        n_skip = sum(1 for s, *_ in runner.results if s == SKIP)
        ran = len(runner.results)
        print(f"\n===== {n_pass} passed, {n_fail} failed, {n_skip} skipped =====")
        if n_fail:
            print("\nFAILURES (contract clauses NOT upheld):")
            for s, name, ref, detail in runner.results:
                if s == FAIL:
                    print(
                        f"  - {name}  ({ref}): "
                        f"{detail.splitlines()[0] if detail else ''}"
                    )
        if n_skip:
            print(
                f"\nNOTE: {n_skip} check(s) SKIPPED (not a pass). "
                "Use --strict to fail on skip."
            )
        if ran == 0:
            print(
                "error: no checks ran (filter matched nothing) — not a pass",
                file=sys.stderr,
            )
            return 2
        # The NOTE above promises this. It once held only for the one check
        # that converted its own skip to a failure internally, which left
        # `--strict --no-interrupt` reporting an all-green run.
        return 1 if (n_fail or (args.strict and n_skip)) else 0
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
