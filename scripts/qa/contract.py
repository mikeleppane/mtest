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
    informal (§20), so checks lean on the STABLE surfaces: exit codes (§9), the
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
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from typing import TYPE_CHECKING, NoReturn

from scripts.checks.reports import collect_stream as collect_stream_oracle
from scripts.checks.reports import json_stream as json_stream_oracle


if TYPE_CHECKING:
    from collections.abc import Callable, Iterator


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

    # -- retry: crashes on its first attempt and passes once the marker exists,
    #    so `--retries 1` yields a FLAKY file with nothing else failing. The
    #    marker is written in the invocation root, which is the working
    #    directory every test binary is spawned in.
    w(
        "retry/test_crash_once.mojo",
        "from std.os import abort\n"
        "from std.os.path import exists\n"
        "from std.testing import assert_equal, TestSuite\n\n\n"
        "def test_eventually_passes() raises:\n"
        '    if not exists("retry.marker"):\n'
        '        with open("retry.marker", "w") as f:\n'
        '            f.write("1")\n'
        '        abort("POISON: the first attempt always aborts")\n'
        "    assert_equal(1, 1)\n" + MAIN,
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
    "collect: --fail-on-flaky rejected in collect -> 4",
    "run: --fail-on-flaky green run stays 0",
    "run: --seed without --shuffle -> 4",
    "run: --shuffle with --ff -> 4",
    "collect: --shuffle rejected -> 4",
    "collect: --format bogus -> 4",
    "run: --format is collect-only -> 4",
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
    "debug: plain path operand -> 4",
    "debug: unknown test -> 4",
    "debug: reporter flag refused -> 4",
    "debug: --retries refused -> 4",
    "run: --report bad format -> 4",
    "run: --report duplicate format -> 4",
    "run: --report md=html collision -> 4",
    "run: --report collides with --junit-xml -> 4",
    "run: --report relative-alias collision -> 4",
    "collect: --report rejected -> 4",
    "doctor: --report rejected -> 4",
    "collect: --report-style rejected -> 4",
    "doctor: --report-style rejected -> 4",
    "value: --report-style bad value -> 4",
    "run: --json collides with --junit-xml -> 4",
    "debug: --report rejected -> 4",
    "completions: bash prints a sourceable function",
    "completions: zsh prints a compdef script",
    "completions: fish prints complete rules",
    "completions: no shell operand -> 4",
    "completions: an unrenderable shell -> 4",
    "completions: a trailing operand after --help -> 4",
    "served: -n accepted (not exit 4)",
    "served: --workers accepted (not exit 4)",
    "served: --serial accepted (not exit 4)",
    "served: --retries accepted (not exit 4)",
    "served: --compile-timeout accepted (not exit 4)",
    "served: --junit-xml accepted (not exit 4)",
    "served: --gh-annotations accepted (not exit 4)",
    "served: --json accepted (not exit 4)",
    "served: collect --shard partitions (not exit 4)",
    "served: collect --serial accepted, inert (not exit 4)",
    "served: doctor --no-cache accepted, inert (not exit 4)",
    "served: doctor --cache-clear accepted, inert (not exit 4)",
    "served: --collect-only --format json is a collection (not exit 4)",
    "collect: exact node-id set for tests/",
    "determinism: collect byte-identical",
    "collect: --format json agrees with the lines listing and the exit",
    "collect: a listing larger than the pipe buffer survives an early close",
    "pipe: every direct-output command survives a closed stdout",
    "io: an unwritable output descriptor exits 3, never a crash",
    "io: an undelivered report still releases the JUnit spool",
    "collect: an interrupted --format json run agrees with its own exit",
    "determinism: --shuffle --seed repeats its file order",
    "help: --help -> stdout, exit 0",
    "usage error: -V -> stderr, exit 4",
    "collect: streams split, listing continues past a bad probe",
    "color: --color always beats NO_COLOR",
    "precompile: success path resolves import (auto -I)",
    "symlink: a symlinked test file is collected and run, never dropped",
    "shape: a test-named non-file walk entry is announced, never dropped",
    "shape: an unsupported operand is refused with its real problem",
    "path: a '::' path is skipped, never listed, and refused by name",
    "value: 2^63 refused for every non-negative integer flag",
    "report: --json to a readerless FIFO fails fast, never blocks",
    "path: a long-but-legal path builds, never a false COMPILE-ERROR",
    "flaky: --fail-on-flaky turns a FLAKY-only run's 0 into 1",
    "debug: the handoff is the test's own exit, with no mtest verdict",
    "new: scaffolds a discoverable file",
    "new: refuses to overwrite -> 4",
    "new: non-discoverable name -> 4",
    "new: node-id-shaped path -> 4",
    "new: the scaffolded file runs green",
    "new: a hostile basename still compiles and passes",
    "init: --ci github bootstraps a runnable project",
    "init: a second run skips every artifact, still 0",
    "init: --ci gitlab -> 4",
    "report: --report md publishes a document for a green run",
    "report: --report md+html describes a failing run in both formats",
    "report: --report-style full sections a file concise leaves out",
    "determinism: two --report runs agree once durations are normalized",
    "report: an unwritable --report target exits 3, prior report intact",
    "report: a configured md destination with a missing parent -> 4",
    "report: a configured html destination with a missing parent -> 4",
    "report: a case-only destination alias follows the volume's rule",
    "config show: colliding destinations render with provenance, exit 0",
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
`-V`), so those names are adjacent here and move together;
`check_init_scaffold` records three the same way, `check_run_report` records
four, and `check_run_report_configured_missing_parent` records two.
"""


class ContractRosterError(Exception):
    """The gate did not perform the checks it reports."""


class ContractStreamExitError(Exception):
    """A run whose stream was to be compared did not exit as the check needs."""


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


# Two fields of a summary line are properties of the machine and the store
# rather than of any behavior under test: the wall time, and the build-cache
# counters, which depend on what the store held when the run started. Both are
# elided before an exact comparison, so a warm scaffold cannot flap a check.
_RUN_SPECIFICS = re.compile(r", builds: \d+, cached: \d+| in \d+\.\d+s")

I_FLAGS = ["-I", "build"]
"""The `-I` include flag every scaffolded run needs, for the bespoke checks.

`build_matrix` names the same pair locally; the bespoke `Runner` methods below
are outside that function and cannot see it.
"""

# EVERY machine-dependent cell in a run report, anchored so nothing else is
# masked: the header's wall time, the build-cache counters (whose values depend
# on what the store held when the run started), and the summary table's per-file
# duration column. Normalizing only the wall time would let a per-file duration
# flap two identical runs apart; normalizing bare `\d+\.\d+` everywhere would
# quietly mask a real difference in some other number.
_REPORT_MEASURED = re.compile(
    r"(?<=wall time: )\d+\.\d+s"
    r"|^builds: \d+ built, \d+ cached$"
    r"|(?<=\| )\d+\.\d+(?= \|)",
    re.MULTILINE,
)


def _first_yaml_fence(page: Path) -> bytes:
    """The body of the first ```yaml block on `page`, byte for byte.

    Extracted at check time rather than copied into this file, so the page and
    the runner cannot drift apart without something going red. The FIRST fence
    is the one that counts because the page carries a second, sharded variant
    further down, and anchoring on a heading would anchor on prose that can be
    reworded.

    Bytes, not text. Reading either side in text mode normalizes CRLF to LF, so
    a page with Windows line endings compares equal to a scaffold with Unix
    ones while the two files genuinely differ — a byte-parity gate that cannot
    see a difference in bytes.

    Args:
        page: The Markdown document to read.

    Returns:
        Every byte between the opening ```yaml fence line and its closing
        fence line, its own terminators included. A page with no such block is
        a setup failure (exit 2), because a missing oracle must be loud rather
        than a silently-passing comparison against an empty string.
    """
    lines = page.read_bytes().splitlines(keepends=True)
    for index, line in enumerate(lines):
        if line.rstrip(b"\r\n") != b"```yaml" or not line.endswith(b"\n"):
            continue
        for close in range(index + 1, len(lines)):
            if lines[close].rstrip(b"\r\n") == b"```":
                return b"".join(lines[index + 1 : close])
        break
    _die(f"{page} has no closed ```yaml block to compare the scaffold against")


def _sole_line(lines: list[str], prefix: str) -> str | None:
    """The one line starting with `prefix`, or None when there is not exactly one."""
    matched = [ln for ln in lines if ln.startswith(prefix)]
    return matched[0] if len(matched) == 1 else None


def _flaky_surface_problems(
    label: str,
    result: subprocess.CompletedProcess[str],
    want_exit: int,
    want_body: str,
) -> list[str]:
    """Check one half of the fail-on-flaky pair on all three of its surfaces.

    The exit code, the console summary band, and the annotation `::notice` are
    produced by three separate paths, so all three are asserted. The band and
    the notice are compared as WHOLE lines against the same expected body: a
    substring would pass against duplicated or malformed rendering, and
    checking only one of the two would miss a reporter that lost its wiring.

    Args:
        label: Which half this is, for the failure detail.
        result: The completed `mtest` run.
        want_exit: The exit code the contract freezes for this half.
        want_body: The exact summary text both surfaces must carry, with the
            wall time and cache counters removed.

    Returns:
        One string per property that did not hold; empty when the half passed.
    """
    probs: list[str] = []
    if result.returncode != want_exit:
        probs.append(f"{label}: exit {result.returncode}, want {want_exit}")
    lines = result.stdout.splitlines()

    band = _sole_line(lines, "===== ")
    if band is None:
        probs.append(f"{label}: expected exactly one console summary band")
    else:
        got = _RUN_SPECIFICS.sub("", band.removeprefix("===== ").removesuffix(" ====="))
        if got != want_body:
            probs.append(f"{label}: band is {got!r}, want {want_body!r}")

    notice = _sole_line(lines, "::notice::")
    if notice is None:
        probs.append(f"{label}: expected exactly one ::notice line")
    else:
        got = _RUN_SPECIFICS.sub("", notice.removeprefix("::notice::"))
        if got != want_body:
            probs.append(f"{label}: notice is {got!r}, want {want_body!r}")
    return probs


def _close_stdout() -> None:
    """Close descriptor 1 in the forked child, exactly as `>&-` does.

    `subprocess` performs its own `dup2` redirection before it calls this, so
    closing here leaves the child with no descriptor 1 at all rather than one
    pointing at a sink. That is the state a write must report `EBADF` for.
    """
    os.close(1)


def _close_stderr() -> None:
    """Close descriptor 2 in the forked child, exactly as `2>&-` does."""
    os.close(2)


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
        self, argv: list[str], timeout: int = 180, cwd: Path | None = None
    ) -> subprocess.CompletedProcess[str]:
        """Run the binary under test inside the scaffold, capturing both streams.

        Args:
            argv: Arguments passed after the binary path.
            timeout: Seconds to wait before `subprocess.TimeoutExpired` is
                raised; callers turn that into a FAIL, never a pass.
            cwd: A working directory other than the scaffold. The invocation
                root is the working directory (§2), so a check about a command
                that writes into that root needs one of its own rather than
                the shared scaffold whose contents other checks pin exactly.

        Returns:
            The completed process, with both streams decoded as text.
        """
        return subprocess.run(
            [str(MTEST), *argv],
            cwd=cwd if cwd is not None else self.root,
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

    def check_collect_json(self) -> None:
        """Assert the collect stream agrees with the listing it replaces.

        Three properties, each catching a different lie. The node ids must
        equal the `--format lines` run's stdout lines IN ORDER, so the stream
        cannot list a different set or a different order from the format it
        mirrors. Every record must satisfy the oracle's frozen schema, which is
        what catches a `node` whose triple does not decompose — a defect counts
        and ordering cannot see. And two runs must be byte-identical, the same
        determinism the listing itself promises.

        A fourth once collected a file under a `::`-named directory, to prove
        `node_id` was split at its LAST separator rather than its first. §5 is
        enforced now, so no such file is ever listed and the scenario cannot be
        built through the binary at all — `path: a '::' path is skipped, never
        listed, and refused by name` asserts exactly that. The mis-split it
        guarded against is still caught: the oracle rejects a `name` carrying a
        separator, and `scripts/tests/test_collect_stream.py` drives both
        splittings through it with synthetic records, which needs no `::` file
        on disk.

        **What this does NOT cover.** `terminal.exit_code == returncode` is
        asserted, but that equality alone does not prove the runner resolves
        the code BEFORE printing: in collect mode nothing owns a `--json` or
        JUnit descriptor, so the only thing teardown can still escalate is a
        `runtime.close()` failure, and the fault-injection symbols that would
        force one live in the test-only native object that `build/mtest` never
        links. Both orderings therefore pass this check. The ordering is
        argued in `src/main.mojo` and unproven by any gate.
        """
        ref = "§16/§17 collect --format json: same nodes, same exit, byte-stable"
        name = "collect: --format json agrees with the lines listing and the exit"
        lines = self.mtest(["collect", "-I", "build", "tests"])
        first = self.mtest(["collect", "--format", "json", "-I", "build", "tests"])
        again = self.mtest(["collect", "--format", "json", "-I", "build", "tests"])
        try:
            report = collect_stream_oracle.parse_collect_stream(first.stdout)
        except collect_stream_oracle.CollectStreamError as exc:
            self.record(FAIL, name, ref, f"stream did not parse: {exc}")
            return
        problems = []
        if lines.returncode != 0 or first.returncode != 0:
            problems.append(
                f"lines exited {lines.returncode}, json exited {first.returncode}"
            )
        expected = lines.stdout.splitlines()
        if not expected:
            problems.append("the lines listing was empty, so it proves nothing")
        if report.node_ids != expected:
            problems.append(f"node ids {report.node_ids} != listing {expected}")
        if report.nodes != len(expected):
            problems.append(f"terminal nodes={report.nodes}, listed {len(expected)}")
        if report.exit_code != first.returncode:
            problems.append(
                f"terminal exit_code={report.exit_code} but the process exited "
                f"{first.returncode}"
            )
        if report.torn_tail:
            problems.append("a complete run produced a torn tail")
        if first.stdout != again.stdout:
            problems.append("two identical runs produced different streams")
        ok = not problems
        self.record(PASS if ok else FAIL, name, ref, "" if ok else "; ".join(problems))

    def _write_oversized_listing_tree(self) -> str:
        """Scaffold one file whose node-id listing exceeds the pipe buffer.

        A pipe holds 64 KiB before a write blocks, and the listing goes out in
        a single write, so a listing under that ceiling is delivered whole no
        matter what the reader does — the check below would pass against a
        binary with the defect. Length is bought with long names rather than
        many files because every file costs a compile: one file with 500 tests
        under a long directory and a long basename yields roughly 108 KB.

        Returns:
            The directory operand, relative to the scaffold root.
        """
        directory = "collect_pipe_" + "x" * 60
        stem = "test_" + "n" * 60
        target = self.root / directory
        target.mkdir(exist_ok=True)
        body = ["from std.testing import TestSuite, assert_equal\n\n"]
        body.extend(
            f"def {stem}_{i:04d}() raises:\n    assert_equal(1, 1)\n\n\n"
            for i in range(500)
        )
        body.append(
            "def main() raises:\n"
            "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
        )
        (target / f"{stem}.mojo").write_text("".join(body))
        return directory

    def check_collect_pipe_early_close(self) -> None:
        """Assert a cut stdout pipe never takes `collect` outside its exit domain.

        §9 and §16 close `collect`'s exit domain at `{0, 1, 2, 3, 4, 5}`. Death
        by `SIGPIPE` is 141 — a status in none of them, and one a shell reports
        as a failure for a run that in fact listed everything it was asked for.

        This is the mid-write half of the property: the reader is still there
        when the write starts and leaves partway through, so the listing has to
        be larger than the pipe buffer for any of the write to still be
        outstanding, which is what `_write_oversized_listing_tree` is for. The
        already-gone half is `check_direct_output_closed_pipe`.

        Both formats are covered. `--format json` tears down before it renders,
        because its terminal record must carry the finalized exit code, so its
        write is the one that happens with the runtime's own `SIGPIPE`
        carve-out already restored — which is exactly why the writer installs
        its own.
        """
        ref = "§9/§16 collect's exit domain survives a consumer that stops reading"
        name = "collect: a listing larger than the pipe buffer survives an early close"
        directory = self._write_oversized_listing_tree()
        probe = self.mtest(["collect", "-I", "build", directory])
        if probe.returncode != 0 or len(probe.stdout) <= 65536:
            self.record(
                FAIL,
                name,
                ref,
                f"the fixture proves nothing: exit {probe.returncode}, "
                f"{len(probe.stdout)} bytes (need > 65536 and exit 0)",
            )
            return
        statuses: list[tuple[str, int | str]] = []
        for fmt in ("lines", "json"):
            for _ in range(3):
                reader = subprocess.Popen(
                    ["head", "-1"],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.DEVNULL,
                )
                writer = subprocess.Popen(
                    [
                        str(MTEST),
                        "collect",
                        "--format",
                        fmt,
                        "-I",
                        "build",
                        directory,
                    ],
                    cwd=self.root,
                    env=self.env,
                    stdout=reader.stdin,
                    stderr=subprocess.DEVNULL,
                )
                # The parent's copy of the write end must go, or the pipe never
                # reports a broken reader and this measures nothing.
                if reader.stdin is not None:
                    reader.stdin.close()
                try:
                    statuses.append((fmt, writer.wait(timeout=180)))
                except subprocess.TimeoutExpired:
                    writer.kill()
                    statuses.append((fmt, "timeout"))
                reader.wait(timeout=30)
        bad = [s for s in statuses if s[1] != 0]
        self.record(
            PASS if not bad else FAIL,
            name,
            ref,
            ""
            if not bad
            else f"statuses {statuses}; a negative or 141 is death by SIGPIPE, "
            "which is outside the frozen exit domain",
        )

    def check_direct_output_closed_pipe(self) -> None:
        """Assert every direct-output command survives a reader that is gone.

        The sibling of `check_collect_pipe_early_close`, and the deterministic
        one: the read end is closed before the child is even spawned, so the
        very first write returns `EPIPE` and no output size, pipe capacity, or
        scheduling luck is involved. Every command that writes straight to a
        descriptor rather than through a reporter is here, because each one
        publishes its own frozen exit domain and 141 is in none of them: help
        and version (§19), `config show` and `doctor` (§27), `completions`
        (§30), `new` and `init` (§29, which additionally promise the artifacts
        exist afterwards), and `collect --format json` (§16).

        Both run drivers are here too, and they are the reason this check and
        `check_unwritable_output_descriptor` have to be read together: an
        undelivered console report escalates a run to 3, but a consumer that
        walked away is not that case and must leave the run's own verdict
        alone. `EPIPE` is the whole difference, and asserting only one side
        would let a fix for either one quietly eat the other.

        Each command is asserted against the exact code its domain gives a
        successful run, so a process that dies of `SIGPIPE` (a negative return
        code from `subprocess`, 141 from a shell) fails here and names itself.
        """
        ref = "§19/§27/§28/§29 a closed stdout leaves each domain intact"
        cases: list[tuple[str, list[str], int, str]] = [
            ("help: --help", ["--help"], 0, ""),
            ("help: version", ["version"], 0, ""),
            ("config show", ["config", "show"], 0, ""),
            ("completions bash", ["completions", "bash"], 0, ""),
            ("doctor", ["doctor"], 0, ""),
            ("new", ["new", "tests/test_pipe.mojo"], 0, "tests/test_pipe.mojo"),
            ("init", ["init"], 0, "mtest.toml"),
            (
                "collect --format json",
                ["collect", "--format", "json", "-I", "build", "tests"],
                0,
                "",
            ),
            ("run", ["-I", "build", "tests"], 0, ""),
            ("run -n 2", ["-I", "build", "-n", "2", "tests"], 0, ""),
        ]
        probs: list[str] = []
        for label, argv, want, artifact in cases:
            cwd = self.root
            if artifact:
                cwd = self.root / f"closed-pipe-{argv[0]}"
                cwd.mkdir(exist_ok=True)
            read_fd, write_fd = os.pipe()
            os.close(read_fd)
            try:
                proc = subprocess.run(
                    [str(MTEST), *argv],
                    cwd=cwd,
                    env=self.env,
                    stdout=write_fd,
                    stderr=subprocess.DEVNULL,
                    timeout=180,
                    check=False,
                )
                code: int | str = proc.returncode
            except subprocess.TimeoutExpired:
                code = "timeout"
            finally:
                os.close(write_fd)
            if code != want:
                probs.append(f"{label}: exit {code}, want {want}")
            if artifact and not (cwd / artifact).exists():
                probs.append(f"{label}: {artifact} was never created")
        self.record(
            PASS if not probs else FAIL,
            "pipe: every direct-output command survives a closed stdout",
            ref,
            "; ".join(probs),
        )

    def _unwritable_stdout_mechanisms(self) -> list[str]:
        """The ways this host can hand the binary a stdout it cannot write.

        Two are portable and always present; one is Linux-only and additive.
        The portable pair is what keeps this check meaningful on macOS, where
        there is no `/dev/full` at all — a sub-case silently dropped there
        would leave the platform whose `ECONNRESET` value is asserted rather
        than measured with no coverage of the escalation it feeds.

        Returns:
            Mechanism names for `_run_with_broken_stdout`, most portable
            first, so a failure names the mechanism that produced it.
        """
        available = ["closed", "readonly"]
        if Path("/dev/full").exists():
            available.append("full")
        return available

    @contextlib.contextmanager
    def _readonly_sink(self) -> Iterator[int]:
        """Yield a descriptor open for READING on a real file this gate owns.

        Writing to an `O_RDONLY` descriptor fails with `EBADF` on Linux and
        Darwin alike, which is what makes this the portable stand-in for
        `/dev/full`. Unlike closing the descriptor outright it keeps the slot
        OCCUPIED, so the next file the child opens cannot land on descriptor 1
        and quietly absorb output the check needs to see fail.

        The file is one this gate creates in its own scratch, never a system
        path like `/etc/hostname`: a check that depends on someone else's
        filesystem layout is a check that reports on the wrong thing the day
        the layout differs.
        """
        anchor = self.root / "unwritable-sink"
        if not anchor.exists():
            anchor.write_text("a file this gate opens read-only\n")
        fd = os.open(anchor, os.O_RDONLY)
        try:
            yield fd
        finally:
            os.close(fd)

    def _run_with_broken_stdout(
        self, argv: list[str], cwd: Path, mechanism: str
    ) -> int | str:
        """Run the binary with a stdout that cannot take bytes.

        Args:
            argv: Arguments passed after the binary path.
            cwd: The invocation root for this run.
            mechanism: `"closed"` for no descriptor 1 at all (`>&-`, `EBADF`),
                `"readonly"` for a descriptor open for reading (`EBADF`, with
                the slot still occupied), or `"full"` for `/dev/full`
                (`ENOSPC`, Linux only).

        Returns:
            The child's exit status, negative when a signal killed it, or the
            string `"timeout"`.
        """
        try:
            if mechanism == "closed":
                return subprocess.run(
                    [str(MTEST), *argv],
                    cwd=cwd,
                    env=self.env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=180,
                    check=False,
                    preexec_fn=_close_stdout,
                ).returncode
            if mechanism == "readonly":
                with self._readonly_sink() as sink:
                    return subprocess.run(
                        [str(MTEST), *argv],
                        cwd=cwd,
                        env=self.env,
                        stdout=sink,
                        stderr=subprocess.DEVNULL,
                        timeout=180,
                        check=False,
                    ).returncode
            with Path("/dev/full").open("wb") as full_sink:
                return subprocess.run(
                    [str(MTEST), *argv],
                    cwd=cwd,
                    env=self.env,
                    stdout=full_sink,
                    stderr=subprocess.DEVNULL,
                    timeout=180,
                    check=False,
                ).returncode
        except subprocess.TimeoutExpired:
            return "timeout"

    def check_unwritable_output_descriptor(self) -> None:
        """Assert undelivered PRIMARY output exits 3, and a diagnostic does not.

        The sibling of `check_direct_output_closed_pipe`, from the other side
        of one policy: a departed consumer is absorbed, but a destination that
        cannot take the bytes at all is not, because the command's own success
        code would then be a lie about output nobody received.

        Three shapes stand for that, and every command is put through each one
        this host can build: a CLOSED descriptor (`>&-`), a descriptor open
        for READING (both `EBADF`), and a full destination (`/dev/full`,
        `ENOSPC`, Linux only). The first two are portable on purpose — the
        `/dev/full` case alone would test nothing on macOS, and one classifier
        reached through two different errnos is worth more than one errno
        reached on one platform.

        Every command whose product IS its text is here, since each publishes
        its own exit domain and each admits 3 on this condition: help and
        version (§19), `config show` and `doctor` (§27), `completions` (§30),
        `new` and `init` (§29, whose artifacts must still exist afterwards).
        A run is here too,
        for both drivers: its console report is primary output, so an
        undelivered one escalates through the same delivery precedence a dead
        `--json` destination uses (§9).

        A USAGE ERROR is the counter-case, and it is the reason this check
        asserts two different codes rather than one. There the exit code is
        itself the machine-readable product, and it was delivered perfectly;
        the prose on stderr is a diagnostic about it. §9 freezes 4 for a
        pre-run refusal, so 4 it stays whether or not stderr took the bytes —
        `2>/dev/null` and `2>&-` are two spellings of "I do not want the
        diagnostic", and only a broken runner should be able to turn either
        into a 3.
        """
        ref = "§9/§19/§27/§29 undelivered primary output exits 3; a refusal keeps 4"
        name = "io: an unwritable output descriptor exits 3, never a crash"
        probs: list[str] = []
        cases: list[tuple[str, list[str], str]] = [
            ("help: --help", ["--help"], ""),
            ("help: version", ["version"], ""),
            ("config show", ["config", "show"], ""),
            ("completions bash", ["completions", "bash"], ""),
            ("doctor", ["doctor"], ""),
            ("new", ["new", "tests/test_closed.mojo"], "tests/test_closed.mojo"),
            ("init", ["init"], "mtest.toml"),
        ]
        # Both run drivers join the list, because each drains the console
        # itself: the sequential loop and, under `-n`, the parallel pool with
        # its progress overlay. A run whose console report went nowhere has not
        # reported, so its own verdict is no longer authoritative and 3
        # displaces it.
        cases += [
            ("run", ["-I", "build", "tests"], ""),
            ("run -n 2", ["-I", "build", "-n", "2", "tests"], ""),
        ]
        mechanisms = self._unwritable_stdout_mechanisms()
        for mechanism in mechanisms:
            for label, argv, artifact in cases:
                cwd = self.root
                if artifact:
                    cwd = self.root / f"broken-{mechanism}-{argv[0]}"
                    cwd.mkdir(exist_ok=True)
                code = self._run_with_broken_stdout(argv, cwd, mechanism)
                if code != 3:
                    probs.append(f"{label}: {mechanism} stdout exit {code}, want 3")
                if artifact and not (cwd / artifact).exists():
                    probs.append(f"{label}: {artifact} was never created")

        # A usage error keeps its frozen 4: the code IS the product and it was
        # delivered. Every spelling of a discarded diagnostic must agree, so
        # the stderr side runs the same portable mechanisms.
        for mechanism in mechanisms:
            refused = self._run_with_broken_stderr(["-V"], mechanism)
            if refused != 4:
                probs.append(f"usage error: {mechanism} stderr exit {refused}, want 4")

        self.record(
            PASS if not probs else FAIL,
            name,
            ref,
            "; ".join(probs),
        )

    def _run_with_broken_stderr(self, argv: list[str], mechanism: str) -> int | str:
        """Run the binary with a stderr that cannot take bytes.

        The mirror of `_run_with_broken_stdout` and the same three mechanisms,
        because the property under test is the difference between the two
        streams: an undelivered diagnostic must not move a code the command
        already resolved, however the descriptor was broken.

        Args:
            argv: Arguments passed after the binary path.
            mechanism: `"closed"`, `"readonly"`, or `"full"`, as above.

        Returns:
            The child's exit status, negative when a signal killed it, or the
            string `"timeout"`.
        """
        try:
            if mechanism == "closed":
                return subprocess.run(
                    [str(MTEST), *argv],
                    cwd=self.root,
                    env=self.env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=180,
                    check=False,
                    preexec_fn=_close_stderr,
                ).returncode
            if mechanism == "readonly":
                with self._readonly_sink() as sink:
                    return subprocess.run(
                        [str(MTEST), *argv],
                        cwd=self.root,
                        env=self.env,
                        stdout=subprocess.DEVNULL,
                        stderr=sink,
                        timeout=180,
                        check=False,
                    ).returncode
            with Path("/dev/full").open("wb") as full_sink:
                return subprocess.run(
                    [str(MTEST), *argv],
                    cwd=self.root,
                    env=self.env,
                    stdout=subprocess.DEVNULL,
                    stderr=full_sink,
                    timeout=180,
                    check=False,
                ).returncode
        except subprocess.TimeoutExpired:
            return "timeout"

    def check_undelivered_output_releases_its_resources(self) -> None:
        """Assert a run that cannot write its report still frees its scratch.

        The JUnit spool is a directory `main` creates under `TMPDIR` and owns:
        no other process sweeps it, so an exit that skips the resource ladder
        leaks it once per invocation, forever. `open_junit_spool` exists
        precisely to keep leftovers out of a shared temp, and an exit taken
        from inside the write primitive walked around it.

        The forcing shape is the annotation epilogue: under
        `--gh-annotations on` a failing run writes its tail to the console
        AFTER the session has finalized, which is the last write before the
        ladder runs. Pointed at a stdout that cannot take it, that write fails,
        so the run must both escalate to 3 (undelivered primary output, §9) and
        leave `TMPDIR` exactly as it found it — the spool, its `suite-*.xml`
        fragments, and the target temp all gone.

        The descriptor has to stay OCCUPIED for this one, which is why it is
        not simply closed: with descriptor 1 free, the next file the run opens
        lands on it and the epilogue writes into that file instead of failing.
        A descriptor open for reading keeps the slot and still fails `EBADF`,
        on Linux and Darwin alike; `/dev/full` reaches the same classifier
        through `ENOSPC` and runs beside it where the host provides one. This
        check never skips: a leak is a leak on every platform, and the lane
        that would have to notice it treats a skip as a failure.

        The control is the same argv with a writable stdout: it must exit 1,
        publish the report, and leave `TMPDIR` empty too, so a check that
        passed by never creating a spool cannot look like a check that passed
        by cleaning one up.
        """
        ref = "§9/§15.2 no owned scratch survives any exit path"
        name = "io: an undelivered report still releases the JUnit spool"
        d = self.root / "probes_spool"
        d.mkdir(exist_ok=True)
        (d / "test_pass.mojo").write_text(
            HEAD + "def test_spool_ok() raises:\n"
            '    assert_equal(reverse("ab"), "ba")\n' + MAIN
        )
        (d / "test_fail.mojo").write_text(
            HEAD + "def test_spool_fails() raises:\n    assert_equal(1, 2)\n" + MAIN
        )
        argv = [
            "-I",
            "build",
            "--gh-annotations",
            "on",
            "--junit-xml",
            "spool-report.xml",
            "probes_spool",
        ]
        probs: list[str] = []
        # The control first, so a scaffold that never produces a spool at all
        # is caught before any conclusion is drawn from an empty TMPDIR.
        occupied = [m for m in self._unwritable_stdout_mechanisms() if m != "closed"]
        for label, want in [("control", 1)] + [(m, 3) for m in occupied]:
            tmp = self.root / f"spool-tmp-{label}"
            shutil.rmtree(tmp, ignore_errors=True)
            tmp.mkdir(parents=True)
            env = dict(self.env, TMPDIR=str(tmp), GITHUB_ACTIONS="")
            try:
                if label == "control":
                    code: int | str = subprocess.run(
                        [str(MTEST), *argv],
                        cwd=self.root,
                        env=env,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=180,
                        check=False,
                    ).returncode
                else:
                    code = self._run_with_broken_stdout_in(argv, env, label)
            except subprocess.TimeoutExpired:
                code = "timeout"
            if code != want:
                probs.append(f"{label}: exit {code}, want {want}")
            leftovers = sorted(item.name for item in tmp.iterdir())
            if leftovers:
                probs.append(f"{label}: TMPDIR still holds {leftovers}")
            shutil.rmtree(tmp, ignore_errors=True)
        self.record(PASS if not probs else FAIL, name, ref, "; ".join(probs))

    def _run_with_broken_stdout_in(
        self, argv: list[str], env: dict[str, str], mechanism: str
    ) -> int | str:
        """`_run_with_broken_stdout` with a caller-supplied environment.

        Separate only because the spool check needs its own `TMPDIR` on the
        child, which is the whole point of that check and no business of the
        exit-code one.

        Args:
            argv: Arguments passed after the binary path.
            env: The complete child environment.
            mechanism: `"readonly"` or `"full"`; a closed descriptor is not
                offered here, since the slot has to stay occupied.

        Returns:
            The child's exit status, negative when a signal killed it.
        """
        if mechanism == "readonly":
            with self._readonly_sink() as sink:
                return subprocess.run(
                    [str(MTEST), *argv],
                    cwd=self.root,
                    env=env,
                    stdout=sink,
                    stderr=subprocess.DEVNULL,
                    timeout=180,
                    check=False,
                ).returncode
        with Path("/dev/full").open("wb") as full_sink:
            return subprocess.run(
                [str(MTEST), *argv],
                cwd=self.root,
                env=env,
                stdout=full_sink,
                stderr=subprocess.DEVNULL,
                timeout=180,
                check=False,
            ).returncode

    def check_collect_interrupted_json(self) -> None:
        """Assert an interrupted collect stream reports the code it exits with.

        Exit 2 is reachable under `collect` — `run_collect` resolves it the
        moment the interrupt latch is set — and the stream's whole promise is
        that `collect_finished.exit_code` is the code the process really ends
        with. An interrupt is the one path where the two could most easily
        drift apart, because the code is decided by a latch rather than by the
        collection's own outcome.

        The interrupt goes to the process group so the in-flight compiler
        child dies with it, and it is timed to land inside the collection
        rather than after it: the terminal must say `2`, not the `0` the
        finished collection would have produced. `--no-cache` is what makes
        that timing reliable — the check above leaves the build store warm, and
        a cached collection of this tree finishes well inside the delay, which
        would quietly turn this into an assertion about an uninterrupted run.
        """
        ref = "§9/§16 an interrupted collect exits 2 and its terminal says so"
        name = "collect: an interrupted --format json run agrees with its own exit"
        directory = self._write_oversized_listing_tree()
        proc = subprocess.Popen(
            [
                str(MTEST),
                "collect",
                "--format",
                "json",
                "--no-cache",
                "-I",
                "build",
                directory,
            ],
            cwd=self.root,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        time.sleep(0.4)
        try:
            os.killpg(proc.pid, signal.SIGINT)
        except ProcessLookupError:
            proc.kill()
            self.record(FAIL, name, ref, "the collection finished before the SIGINT")
            return
        try:
            out, _ = proc.communicate(timeout=180)
        except subprocess.TimeoutExpired:
            proc.kill()
            self.record(FAIL, name, ref, "mtest ignored the SIGINT; killed at 180s")
            return
        problems = []
        if proc.returncode != 2:
            problems.append(f"exit {proc.returncode}, want 2")
        try:
            report = collect_stream_oracle.parse_collect_stream(out)
        except collect_stream_oracle.CollectStreamError as exc:
            problems.append(f"stream did not parse: {exc}")
        else:
            if report.torn_tail:
                problems.append("the stream was torn, so it carries no terminal")
            elif report.exit_code != proc.returncode:
                problems.append(
                    f"terminal exit_code={report.exit_code} but the process "
                    f"exited {proc.returncode}"
                )
        ok = not problems
        self.record(PASS if ok else FAIL, name, ref, "" if ok else "; ".join(problems))

    def _shuffled_file_order(self, seed: str) -> tuple[str, ...]:
        """The ordered `file_started` paths of one seeded shuffled run.

        Reads the byte-pure `--json -` stream through the stream oracle rather
        than the console, because §17 excludes the wall clock and the
        build-cache counters from byte identity: two console outputs of the same
        run legitimately differ, so comparing them proves nothing either way.

        Args:
            seed: The `--seed` value to run under.

        Returns:
            The paths in the order the run announced them.

        Raises:
            StreamError: If the stream is corrupt.
            ContractStreamExitError: If the run did not exit 0, so its order is not
                evidence about ordering.
        """
        run = self.mtest(
            [
                "-I",
                "build",
                "--shuffle",
                "--seed",
                seed,
                "-n",
                "1",
                "--json",
                "-",
                "--gh-annotations",
                "off",
                "tests",
            ]
        )
        if run.returncode != 0:
            raise ContractStreamExitError(
                f"--shuffle --seed {seed} exited {run.returncode}: {run.stderr}"
            )
        report = json_stream_oracle.parse_stream(run.stdout)
        return tuple(
            str(record.get("path", ""))
            for record in report.records
            if record.get("event") == "file_started"
        )

    def check_shuffle_determinism(self) -> None:
        """Assert a seed repeats its order and another seed really moves files.

        Two same-seed runs agreeing is necessary but nowhere near sufficient: a
        `--shuffle` that never reordered anything agrees with itself too. A run
        under a different seed is what separates a working shuffle from a no-op
        — and comparing the two orders' SETS first separates "the order moved"
        from "a different set of files ran", which would be a far worse defect
        wearing the same symptom.

        The alternative seeds are TRIED IN TURN rather than fixed at one value.
        Over a small file set two particular seeds can legitimately draw the
        same permutation, and a scaffold edit could make the pair collide, which
        would report a working shuffle as broken. Only every candidate agreeing
        is evidence of a no-op.

        What this check cannot see: WHERE the shuffle sits relative to the
        `--shard` partition. Nothing here is sharded, so a shuffle moved above
        the partition would pass every assertion below.
        `test_shard_membership_is_chosen_before_the_shuffle` owns that property.
        """
        ref = "§17/§18 a seed reproduces its order; another seed changes it"
        name = "determinism: --shuffle --seed repeats its file order"
        reference, candidates = "7", ("9", "2", "3")
        try:
            first = self._shuffled_file_order(reference)
            again = self._shuffled_file_order(reference)
            others = {seed: self._shuffled_file_order(seed) for seed in candidates}
        except (json_stream_oracle.StreamError, ContractStreamExitError) as exc:
            self.record(FAIL, name, ref, str(exc))
            return
        problems = []
        if len(first) < 3:
            problems.append(f"too few files ran to carry an order: {first}")
        if first != again:
            problems.append(f"one seed drew two orders: {first} then {again}")
        wrong_set = {s: o for s, o in others.items() if sorted(o) != sorted(first)}
        if wrong_set:
            problems.append(f"a second seed ran a different SET: {wrong_set}")
        elif all(order == first for order in others.values()):
            problems.append(
                f"no seed in {candidates} reordered {first}, so nothing was randomized"
            )
        ok = not problems
        self.record(PASS if ok else FAIL, name, ref, "" if ok else "; ".join(problems))

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

    def check_separator_in_path(self) -> None:
        """Assert `::` in a path is enforced, announced, and named honestly.

        §5 always said `::` in a file path is unsupported, and nothing
        enforced it. A walk discovered such a file, `collect` listed it, and a
        run ran it — but no operand could reach it, because an operand splits
        at its FIRST separator, so `mtest 'tests/co::l/test_x.mojo'` answered
        `no such path 'tests/co'`: a path the caller never wrote, describing a
        problem that was not theirs.

        Three properties, one tree. The walk skips the file and says so with
        the `skipped-unaddressable` warning §5 names, so the run cannot go
        quietly green over a smaller set; `collect` lists files rather than
        warnings, so it simply omits it; and the operand is refused with exit
        4 quoting itself. The POISON test inside would FAIL if it ran, so a
        walk that regressed flips the exit code rather than only the text.
        """
        ref = "§5/§9 `::` in a path is unsupported: skipped, unlisted, refused"
        name = "path: a '::' path is skipped, never listed, and refused by name"
        d = self.root / "probes_sep"
        d.mkdir(exist_ok=True)
        (d / "test_plain.mojo").write_text(
            HEAD + "def test_sep_plain_ok() raises:\n"
            '    assert_equal(reverse("ab"), "ba")\n' + MAIN
        )
        nested = d / "co::l"
        nested.mkdir(exist_ok=True)
        (nested / "test_x.mojo").write_text(
            HEAD + "def test_sep_poison() raises:\n"
            "    assert_equal(1, 2)  # POISON: an addressable file would run\n" + MAIN
        )

        probs: list[str] = []
        run = self.mtest(["-I", "build", "probes_sep"])
        both = run.stdout + run.stderr
        warned = [ln for ln in both.splitlines() if "skipped-unaddressable" in ln]
        if run.returncode != 0:
            probs.append(f"run: exit {run.returncode} (want 0)")
        if "1 passed" not in both:
            probs.append("run: the addressable sibling did not pass alone")
        if len(warned) != 1 or "co::l/test_x.mojo" not in warned[0]:
            probs.append(f"run: warnings={warned}, want exactly one naming the file")

        listed = self.mtest(["collect", "-I", "build", "probes_sep"])
        if "co::l" in listed.stdout:
            probs.append("collect: listed a node id nothing could address")
        if "skipped-unaddressable" in listed.stdout + listed.stderr:
            probs.append("collect: emitted a discovery warning")

        for operand in ("probes_sep/co::l/test_x.mojo", "probes_sep/co::l"):
            refused = self.mtest(["-I", "build", operand])
            text = refused.stdout + refused.stderr
            if refused.returncode != 4:
                probs.append(f"{operand}: exit {refused.returncode} (want 4)")
            if "unsupported path" not in text:
                probs.append(f"{operand}: no unsupported-path diagnostic")
            if operand not in text:
                probs.append(f"{operand}: the refusal did not quote the operand")
            if "no such path" in text:
                probs.append(f"{operand}: still reports a truncated prefix")

        # The rule is applied only AFTER an entry is characterized, so a `::`
        # directory this process may read but not search stays what §5 lines
        # 324-326 call it: an entry the walk cannot inspect, exit 4. Deciding
        # unaddressability first would answer for entries nobody had looked at
        # and hand back a green run over a subtree that was never read.
        nested.chmod(0o644)
        try:
            blind = self.mtest(["-I", "build", "probes_sep"])
        finally:
            nested.chmod(0o755)
        blind_text = blind.stdout + blind.stderr
        if blind.returncode != 4:
            probs.append(f"unsearchable '::' dir: exit {blind.returncode} (want 4)")
        if "cannot inspect" not in blind_text:
            probs.append("unsearchable '::' dir: no inspection-failure diagnostic")

        self.record(PASS if not probs else FAIL, name, ref, "; ".join(probs))

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
            "--seed",
        ):
            # `--seed` is refused outright without `--shuffle`, so it is passed
            # with it: otherwise this check would pass on the wrong refusal and
            # say nothing about the wrapped value.
            prefix = ["-I", "build"] + (["--shuffle"] if flag == "--seed" else [])
            for value in ("9223372036854775808", "9223372036854775809"):
                r = self.mtest([*prefix, flag, value, "tests/"])
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

    def check_fail_on_flaky(self) -> None:
        """Assert a FLAKY-only run exits 0, and 1 once `--fail-on-flaky` is set.

        A paired run over one scaffold, with the crash-once marker reset between
        halves so the two differ only in the flag. The exit codes alone are not
        an oracle: a runner that never retried at all would also exit 0 on the
        first half, so each half is held to the exact summary text on BOTH
        independently composed surfaces (§15.1's console band and §15.3's
        `::notice`). `--gh-annotations on` is what makes the tail render outside
        GitHub Actions at all; without it the notice never appears and this
        check would silently stop covering the reporter it names.
        """
        ref = "§13/§15.3 --fail-on-flaky demotes a would-be 0 and says why"
        name = "flaky: --fail-on-flaky turns a FLAKY-only run's 0 into 1"
        marker = self.root / "retry.marker"
        argv = [
            "-I",
            "build",
            "--retries",
            "1",
            "--gh-annotations",
            "on",
            "retry/test_crash_once.mojo",
        ]

        try:
            marker.unlink(missing_ok=True)
            off = self.mtest(argv)
            marker.unlink(missing_ok=True)
            on = self.mtest([*argv, "--fail-on-flaky"])
        except subprocess.TimeoutExpired:
            self.record(FAIL, name, ref, "timed out running the retry probe")
            return
        finally:
            marker.unlink(missing_ok=True)

        bare = "1 passed, 0 failed, 0 skipped, 1 flaky (0 excluded, 0 not run)"
        named = (
            "1 passed, 0 failed, 0 skipped, 1 flaky (failing: --fail-on-flaky)"
            " (0 excluded, 0 not run)"
        )
        probs = _flaky_surface_problems("without the flag", off, 0, bare)
        probs += _flaky_surface_problems("with the flag", on, 1, named)
        if probs:
            self.record(FAIL, name, ref, "; ".join(probs))
        else:
            self.record(PASS, name, ref)

    def check_debug_handoff(self) -> None:
        """Assert `debug` hands the terminal over and claims nothing afterwards.

        Two halves over the same surface, one passing node and one failing one.
        Each asserts the two marker lines, then the test binary's OWN report
        text after them, then the exit code the binary itself produced. The
        third assertion is the load-bearing one and applies to both halves: no
        summary band anywhere. A zero from a handed-over run is the binary's
        statement, and a band would be mtest claiming a verdict it is in no
        position to have — there is deliberately no machinery that could
        produce one, so its absence is what proves the handoff was real.
        """
        ref = "§28 debug prepares, prints two lines, then becomes the test"
        name = "debug: the handoff is the test's own exit, with no mtest verdict"
        halves = [
            ("passing", "tests/test_reverse.mojo::test_reverse_ab", 0),
            ("failing", "probes/test_fail.mojo::test_x", 1),
        ]
        probs: list[str] = []
        for label, node, want_exit in halves:
            try:
                r = self.mtest(["debug", "-I", "build", node])
            except subprocess.TimeoutExpired:
                probs.append(f"{label}: timed out")
                continue
            if r.returncode != want_exit:
                probs.append(f"{label}: exit {r.returncode}, want {want_exit}")
            lines = r.stdout.splitlines()
            if not lines or not lines[0].startswith("build: "):
                probs.append(f"{label}: first stdout line is not the build line")
            elif "build/bin/" not in lines[0]:
                probs.append(f"{label}: the build line names no build/bin/ output")
            selector = "--only " + node.rpartition("::")[2]
            if len(lines) < 2 or not lines[1].startswith("run: "):
                probs.append(f"{label}: second stdout line is not the run line")
            elif not lines[1].endswith(selector):
                probs.append(f"{label}: the run line does not end in {selector!r}")
            # The binary's own report, produced after the exec, on the same
            # descriptor mtest was writing to a moment earlier.
            if "tests run:" not in r.stdout:
                probs.append(f"{label}: the test binary's own report never arrived")
            if "=====" in r.stdout or "=====" in r.stderr:
                probs.append(f"{label}: an mtest summary band survived the handoff")
        if probs:
            self.record(FAIL, name, ref, "; ".join(probs))
        else:
            self.record(PASS, name, ref)

    # -- new (§29). Each of these builds its OWN directory, never `tests/`,
    #    whose node-id set `EXPECTED_TESTS` pins exactly. Independent setup is
    #    the point: an earlier version chained them, and `-k 'refuses to
    #    overwrite'` then passed by creating the file it meant to find already
    #    there, which is the failure mode a filtered run exists to expose.
    def _new_dir(self, name: str) -> Path:
        """A fresh, empty directory under the scaffold for one `new` check."""
        directory = self.root / name
        if directory.exists():
            shutil.rmtree(directory)
        directory.mkdir()
        return directory

    def check_new_creates(self) -> None:
        """Assert `mtest new` writes the file and says so, into an empty dir."""
        ref = "§29 new PATH creates one discoverable file, exit 0 on stdout"
        name = "new: scaffolds a discoverable file"
        directory = self._new_dir("new_ok")
        r = self.mtest(["new", "new_ok/test_scaffolded.mojo"])
        probs: list[str] = []
        if r.returncode != 0:
            probs.append(f"exit {r.returncode}, want 0")
        if r.stdout != "created new_ok/test_scaffolded.mojo\n":
            probs.append(f"stdout is not the frozen success line: {r.stdout!r}")
        if r.stderr:
            probs.append(f"a successful scaffold wrote diagnostics: {r.stderr!r}")
        written = sorted(p.name for p in directory.iterdir())
        if written != ["test_scaffolded.mojo"]:
            probs.append(f"the publication left litter beside the file: {written}")
        else:
            # The oracle is a file created here the ordinary way, not a
            # hard-coded bit pattern: "the mode an editor would have produced"
            # is exactly the umask's answer, and pinning `0o044` instead makes
            # this red under `umask 077` with no defect present.
            ordinary = directory / "ordinary.probe"
            ordinary.write_text("x")
            want_mode = ordinary.stat().st_mode & 0o777
            ordinary.unlink()
            mode = directory.joinpath("test_scaffolded.mojo").stat().st_mode & 0o777
            if mode != want_mode:
                probs.append(
                    f"the file carries mode {mode:#o}, not the {want_mode:#o} an "
                    "ordinary create in this directory produces"
                )
        self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

    def check_new_refuses_to_overwrite(self) -> None:
        """Assert an occupied target is refused with its bytes untouched.

        The exit code alone would pass against an implementation that
        truncated the file and then failed, so the surviving content and the
        absence of a leftover temporary are asserted beside it.
        """
        ref = "§29 an existing target is refused (4), never modified"
        name = "new: refuses to overwrite -> 4"
        directory = self._new_dir("new_taken")
        target = directory / "test_taken.mojo"
        mine = "# hand-written, and not to be replaced\n"
        target.write_text(mine)
        r = self.mtest(["new", "new_taken/test_taken.mojo"])
        probs: list[str] = []
        if r.returncode != 4:
            probs.append(f"exit {r.returncode}, want 4")
        if "refusing to overwrite" not in r.stderr:
            probs.append(f"the refusal does not name itself: {r.stderr!r}")
        if r.stdout:
            probs.append(f"a refused scaffold wrote to stdout: {r.stdout!r}")
        if target.read_text() != mine:
            probs.append(f"the target's bytes changed: {target.read_text()!r}")
        left = sorted(p.name for p in directory.iterdir())
        if left != ["test_taken.mojo"]:
            probs.append(f"the refusal left a temporary behind: {left}")
        self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

    def check_new_refuses_unusable_names(self) -> None:
        """Assert the two name refusals, each against an untouched directory.

        A basename no walk would collect, and a path carrying `::`, which the
        node-id grammar reserves — mtest would be unable to address the file
        afterwards, so it declines to create it in the first place.
        """
        cases = [
            (
                "new: non-discoverable name -> 4",
                "§5,§29 a scaffold must be a file a directory walk collects",
                "new_bad/helper.mojo",
                "test_*.mojo",
            ),
            (
                "new: node-id-shaped path -> 4",
                "§5,§29 `::` is the node-id separator and cannot name a path",
                "new_colon/test_a::b.mojo",
                "contains '::'",
            ),
        ]
        for name, ref, operand, wanted_text in cases:
            directory = self.root / operand.split("/")[0]
            if directory.exists():
                shutil.rmtree(directory)
            r = self.mtest(["new", operand])
            probs: list[str] = []
            if r.returncode != 4:
                probs.append(f"exit {r.returncode}, want 4")
            if wanted_text not in r.stderr:
                probs.append(f"the refusal does not say {wanted_text!r}: {r.stderr!r}")
            if directory.exists():
                probs.append(
                    "the refusal created the parent directory of a file it "
                    "declined to write"
                )
            self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

    def check_new_scaffold_runs(self) -> None:
        """Assert the file `mtest new` wrote actually compiles and passes.

        The exit-code checks above prove the refusals; this proves the point.
        A scaffold a reader has to repair before it runs is worse than no
        scaffold at all, and nothing about its exit code would say so — only
        building and running the bytes it wrote can. The second half runs the
        same gauntlet through a basename carrying the two characters that end
        a Mojo string literal, because the stem is interpolated into the
        file's own docstring: unescaped, `new` reports success and emits a
        file that does not compile.
        """
        ref = "§29 the scaffolded file is runnable as written, any legal name"
        halves = [
            ("new: the scaffolded file runs green", "new_run", "test_scaffolded.mojo"),
            (
                "new: a hostile basename still compiles and passes",
                "new_hostile",
                'test_a"""b\\.mojo',
            ),
        ]
        for name, directory_name, basename in halves:
            directory = self._new_dir(directory_name)
            operand = f"{directory_name}/{basename}"
            probs: list[str] = []
            created = self.mtest(["new", operand])
            if created.returncode != 0:
                probs.append(f"new exited {created.returncode}: {created.stderr!r}")
            elif not (directory / basename).is_file():
                probs.append("new reported success but wrote no file")
            else:
                try:
                    r = self.mtest([operand])
                except subprocess.TimeoutExpired:
                    probs.append("timed out running the scaffolded file")
                    r = None
                if r is not None:
                    if r.returncode != 0:
                        probs.append(f"exit {r.returncode}, want 0")
                    if "1 passed" not in r.stdout:
                        probs.append(
                            f"the summary does not report the one scaffolded "
                            f"test: {r.stdout!r}{r.stderr!r}"
                        )
            self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

    # -- init (§29.2). Its invocation root is where it writes, so every run
    #    below gets its own directory rather than the shared scaffold, whose
    #    `tests/` node-id set `EXPECTED_TESTS` pins exactly.
    def check_init_scaffold(self) -> None:
        """Assert `init` bootstraps a runnable project, twice, and refuses once.

        Three claims, in the order they can be settled. First that the
        artifacts are what §29.2 says: the workflow is compared byte-for-byte
        against the first YAML block of `docs/ci.md`, extracted here rather
        than copied, so the page stays the one place it is written down and a
        drifted pin reds this gate through the real binary. Then that the
        scaffolded project runs — the `mtest.toml` it wrote is what makes a
        bare `mtest` find the test file it wrote beside it, so running with no
        operands tests both at once. Then that a second `init` changes nothing
        and still succeeds, and that an unknown provider is refused before any
        artifact exists.
        """
        ref = "§29.2 init bootstraps a project; artifacts are never replaced"
        name = "init: --ci github bootstraps a runnable project"
        directory = self._new_dir("init_ok")
        probs: list[str] = []
        first = self.mtest(["init", "--ci", "github"], cwd=directory)
        if first.returncode != 0:
            probs.append(f"exit {first.returncode}, want 0: {first.stderr!r}")
        if first.stderr:
            probs.append(f"a successful init wrote diagnostics: {first.stderr!r}")
        wanted_lines = [
            "created tests/test_example.mojo",
            "created mtest.toml",
            "created .github/workflows/test.yml",
            "created .gitignore",
            "next: pixi init .",
            "next: pixi workspace channel add https://conda.modular.com/max/",
            (
                "next: pixi workspace channel add "
                "https://repo.prefix.dev/modular-community"
            ),
            "next: pixi add mtest",
            "next: mtest",
            ("next: commit pixi.toml and pixi.lock, which the workflow installs from"),
        ]
        if first.stdout.splitlines() != wanted_lines:
            probs.append(f"stdout is not the §29.2 report: {first.stdout!r}")
        written = directory / ".github" / "workflows" / "test.yml"
        if not written.is_file():
            probs.append("no workflow was written under --ci github")
        else:
            # Both sides read as bytes: text mode would fold CRLF into LF and
            # report two genuinely different files as identical.
            documented = _first_yaml_fence(REPO / "docs" / "ci.md")
            emitted = written.read_bytes()
            if emitted != documented:
                probs.append(
                    "the scaffolded workflow is not byte-identical to the "
                    f"first yaml block of docs/ci.md ({len(emitted)} bytes "
                    f"emitted, {len(documented)} documented)"
                )
        ignore = directory / ".gitignore"
        if not ignore.is_file() or ".mtest-cache/" not in ignore.read_text(
            encoding="utf-8"
        ):
            probs.append("the build cache was not added to .gitignore")
        if not probs:
            # No operands: the `[run] paths` it just wrote is what has to make
            # this find the test file it just wrote.
            try:
                ran = self.mtest([], cwd=directory)
            except subprocess.TimeoutExpired:
                probs.append("timed out running the bootstrapped project")
                ran = None
            if ran is not None:
                if ran.returncode != 0:
                    probs.append(
                        f"the bootstrapped project exited {ran.returncode}: "
                        f"{ran.stdout!r}{ran.stderr!r}"
                    )
                if "1 passed" not in ran.stdout:
                    probs.append(
                        f"the scaffolded suite did not report its one test: "
                        f"{ran.stdout!r}"
                    )
        self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

        name = "init: a second run skips every artifact, still 0"
        probs = []
        before = ignore.read_text(encoding="utf-8") if ignore.is_file() else ""
        second = self.mtest(["init", "--ci", "github"], cwd=directory)
        if second.returncode != 0:
            probs.append(f"exit {second.returncode}, want 0")
        skipped = [ln for ln in second.stdout.splitlines() if ln.startswith("skipped ")]
        if len(skipped) != 4:
            probs.append(f"not every artifact was skipped: {second.stdout!r}")
        if "created " in second.stdout:
            probs.append(f"a second init created something: {second.stdout!r}")
        if ignore.is_file() and ignore.read_text(encoding="utf-8") != before:
            probs.append("a second init rewrote .gitignore")
        self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

        name = "init: --ci gitlab -> 4"
        ref = "§29.2 an unknown --ci provider is refused before anything exists"
        probs = []
        untouched = self._new_dir("init_refused")
        refused = self.mtest(["init", "--ci", "gitlab"], cwd=untouched)
        if refused.returncode != 4:
            probs.append(f"exit {refused.returncode}, want 4")
        if "gitlab" not in refused.stderr:
            probs.append(f"the refusal does not name the value: {refused.stderr!r}")
        if refused.stdout:
            probs.append(f"a refused init wrote to stdout: {refused.stdout!r}")
        left = sorted(p.name for p in untouched.iterdir())
        if left:
            probs.append(f"the refusal created artifacts anyway: {left}")
        self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

    # -- run report: the document a caller was promised actually lands, says
    #    what the run did, and never survives a doomed destination (§15.5).
    def check_run_report(self) -> None:
        """Assert `--report` publishes documents that describe the real run.

        Four properties, each its own rostered verdict: a green run publishes a
        Markdown document naming the file it ran; a failing run publishes both
        formats and both name the failing test; `--report-style full` sections a
        file that `concise` deliberately leaves out; and two identical runs
        produce byte-identical documents once every measured duration is
        normalized away.
        """
        ref = "§15.5 --report writes a self-contained document per format"
        out = self.root / "reports"
        out.mkdir(exist_ok=True)

        # (1) A green run: the document exists and carries a real summary ROW
        #     for the file it ran. Anchored on the whole row rather than on the
        #     path and the word PASS separately, because a document that merely
        #     mentioned the path somewhere and the header's own "files: N PASS"
        #     would satisfy those two independently while describing nothing.
        name = "report: --report md publishes a document for a green run"
        green = out / "green.md"
        beside = out / "green.xml"
        run = self.mtest(
            [
                *I_FLAGS,
                "--report",
                f"md:{green}",
                "--junit-xml",
                f"{beside}",
                "tests",
            ]
        )
        probs: list[str] = []
        if run.returncode != 0:
            probs.append(f"exit {run.returncode}, want 0")
        # The published report must be an ordinary readable file, not the 0600
        # its `mkstemp` temp arrives as: it is written for a CI job, a reviewer,
        # or a web server, none of which run as the runner's user (§15.5).
        #
        # The PRIMARY assertion is absolute and machine-independent: the mode is
        # what any other tool would have produced here — the 0666 an `open(2)`
        # asks for, minus this process's umask, which is exactly what `mtest new`
        # gives a scaffolded file.
        #
        # The second is a CROSS-CHECK and is deliberately weaker: it says the
        # report is readable wherever the JUnit artifact from the SAME run is,
        # EXCEPT where this process's umask withheld the bit from both. Three
        # honest caveats. Only the READ bits are compared, because the two
        # writers differ on the write bits by design — this one honors the umask
        # and the JUnit path's `open` does not, so a byte-equal comparison would
        # pin a world-writable report as correct. The `& ~previous` term is
        # load-bearing for the same reason: without it a CORRECT report goes red
        # under any umask that masks a read bit (0o007, 0o027, 0o037, 0o070,
        # 0o077 — verified), precisely because the report honors the umask and
        # its sibling does not. And its strength depends on the sibling's own
        # mode, which this branch does not control: under a restrictive umask it
        # can have nothing left to say, and the primary assertion above is what
        # carries the pin there.
        if not beside.is_file():
            probs.append("no junit artifact was published to compare modes with")
        if green.is_file() and beside.is_file():
            previous = os.umask(0)
            os.umask(previous)
            report_mode = green.stat().st_mode & 0o777
            junit_mode = beside.stat().st_mode & 0o777
            expected = 0o666 & ~previous
            if report_mode != expected:
                probs.append(f"report mode {report_mode:#o}, want {expected:#o}")
            # The other half of the same promise: on a filesystem that DOES
            # apply the mode, the run says nothing about it. The best-effort
            # clause is announced on stderr, so a silent warning here would
            # mean the mode above was reached by accident rather than applied.
            if "could not give" in run.stderr:
                probs.append(
                    f"the mode was applied but still warned about: {run.stderr!r}"
                )
            if junit_mode & 0o444 & ~previous & ~report_mode:
                probs.append(
                    f"report mode {report_mode:#o} is less readable than the "
                    f"junit artifact's {junit_mode:#o} allows under umask "
                    f"{previous:#o}"
                )
        if not green.is_file():
            probs.append("no markdown report was published")
        else:
            body = green.read_text()
            probs += [
                f"the report omits {needed!r}"
                for needed in (
                    "# mtest report",
                    "| tests/test_reverse.mojo | PASS |",
                    "| tests/test_palindrome.mojo | PASS |",
                )
                if needed not in body
            ]
        self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

        # (2) A failing run, both formats: each document names the failing test,
        #     and the exit code is the run's own 1 rather than a report failure.
        name = "report: --report md+html describes a failing run in both formats"
        fail_md, fail_html = out / "fail.md", out / "fail.html"
        run = self.mtest(
            [
                *I_FLAGS,
                "--report",
                f"md:{fail_md}",
                "--report",
                f"html:{fail_html}",
                "probes/test_fail.mojo",
            ]
        )
        probs = []
        if run.returncode != 1:
            probs.append(f"exit {run.returncode}, want 1")
        # The NODE ID, not a substring of the path: `probes/test_fail.mojo`
        # already contains "test_f", so a check for that would pass against a
        # document that named no test at all. Only `::test_x` proves the report
        # identified the failing TEST. The row and the assertion text prove it
        # carried the verdict and the detail rather than a bare heading.
        node = "probes/test_fail.mojo::test_x"
        wanted_per_format = {
            fail_md: (node, "| probes/test_fail.mojo | FAIL |", "comparison failed"),
            fail_html: (node, "<td>FAIL</td>", "comparison failed", "<html"),
        }
        for doc, needed_all in wanted_per_format.items():
            if not doc.is_file():
                probs.append(f"{doc.name} was not published")
                continue
            body = doc.read_text()
            probs += [
                f"{doc.name} omits {needed!r}"
                for needed in needed_all
                if needed not in body
            ]
        self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

        # (3) `full` sections a passing file; `concise` gives it a row only.
        name = "report: --report-style full sections a file concise leaves out"
        concise_md, full_md = out / "concise.md", out / "full.md"
        a = self.mtest(
            [*I_FLAGS, "--report", f"md:{concise_md}", "tests/test_palindrome.mojo"]
        )
        b = self.mtest(
            [
                *I_FLAGS,
                "--report",
                f"md:{full_md}",
                "--report-style",
                "full",
                "tests/test_palindrome.mojo",
            ]
        )
        probs = []
        if a.returncode != 0 or b.returncode != 0:
            probs.append(f"exits {a.returncode}/{b.returncode}, want 0/0")
        if not (concise_md.is_file() and full_md.is_file()):
            probs.append("one of the two documents was not published")
        else:
            heading = "## `tests/test_palindrome.mojo`"
            if heading in concise_md.read_text():
                probs.append("concise sectioned a file that needs no action")
            if heading not in full_md.read_text():
                probs.append("full did not section every file")
        self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

        # (4) Determinism. Every duration cell is measured, so the comparison
        #     normalizes ALL of them — the summary line, the table column, and
        #     any in-section timing — rather than sampling one.
        name = "determinism: two --report runs agree once durations are normalized"
        first, second = out / "det1.md", out / "det2.md"
        r1 = self.mtest([*I_FLAGS, "--report", f"md:{first}", "tests"])
        r2 = self.mtest([*I_FLAGS, "--report", f"md:{second}", "tests"])
        probs = []
        if r1.returncode != 0 or r2.returncode != 0:
            probs.append(f"exits {r1.returncode}/{r2.returncode}, want 0/0")
        if not (first.is_file() and second.is_file()):
            probs.append("one of the two documents was not published")
        else:
            a_body = _REPORT_MEASURED.sub("<t>", first.read_text())
            b_body = _REPORT_MEASURED.sub("<t>", second.read_text())
            if a_body != b_body:
                probs.append("two identical runs produced different documents")
            if not a_body.strip():
                probs.append("the normalized document is empty")
        self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

    def check_run_report_construction_failure(self) -> None:
        """Assert an unpreparable `--report` target exits 3 and keeps the prior.

        The JUnit precedent, exactly: the parent EXISTS (so pre-run validation
        passes and this is not the exit-4 missing-parent case) but is not
        writable, so the unique temp cannot be created at session start. That is
        a construction failure, exit 3, and the report already at PATH is never
        touched.
        """
        ref = "§15.5/§9 an unpreparable report destination is a pre-run exit 3"
        name = "report: an unwritable --report target exits 3, prior report intact"
        locked = self.root / "locked"
        locked.mkdir(exist_ok=True)
        target = locked / "run.md"
        prior = "# PRIOR REPORT\nkeep me\n"
        target.write_text(prior)
        probs: list[str] = []
        os.chmod(locked, 0o500)
        try:
            run = self.mtest([*I_FLAGS, "--report", f"md:{target}", "tests"])
            if run.returncode != 3:
                probs.append(f"exit {run.returncode}, want 3")
            if "internal error" not in run.stderr.lower():
                probs.append(f"not reported as an internal error: {run.stderr!r}")
            if target.read_text() != prior:
                probs.append("the prior report at PATH was modified")
        finally:
            os.chmod(locked, 0o700)
        self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

    def check_run_report_configured_missing_parent(self) -> None:
        """Assert a CONFIGURED report destination's parent is checked pre-run.

        The command-line spelling of this is masked: the parser validates
        `--report FORMAT:PATH` as it parses it, so a missing parent supplied on
        the command line never reaches resolved validation at all. A project
        file's `[report]` destination has no such parser, which makes the
        config layer the only origin that exercises the resolved check — and
        the origin where a gap would surface as exit 3 from the temp creation
        instead of the exit 4 §15.5 and §24.4 both promise.

        Both formats are asserted independently rather than together, because
        one branch present and one absent is exactly the shape this defect had.
        The `[report] junit-xml` sibling in the same table is the control: it is
        the behavior the two report destinations must match.
        """
        ref = "§15.5/§24.4 a nonexistent destination parent is a pre-run exit 4"
        project = self.root / "cfgparent"
        project.mkdir(exist_ok=True)
        (project / "tests").mkdir(exist_ok=True)
        # The control, run first and folded into BOTH verdicts: the sibling
        # destination in the SAME table, whose exit code the two report
        # destinations must equal. A change that regressed all three together
        # would otherwise leave the pair looking self-consistent.
        (project / "mtest.toml").write_text('[report]\njunit-xml = "nodir/r.xml"\n')
        sibling = self.mtest([*I_FLAGS, "tests"], cwd=project)
        control: list[str] = []
        if sibling.returncode != 4:
            control.append(
                f"the [report] junit-xml control exited {sibling.returncode}, want 4"
            )
        for fmt, name in (
            ("md", "report: a configured md destination with a missing parent -> 4"),
            (
                "html",
                "report: a configured html destination with a missing parent -> 4",
            ),
        ):
            (project / "mtest.toml").write_text(f'[report]\n{fmt} = "nodir/run.out"\n')
            run = self.mtest([*I_FLAGS, "tests"], cwd=project)
            probs: list[str] = [*control]
            if run.returncode != 4:
                probs.append(f"exit {run.returncode}, want 4")
            probs += [
                f"stderr omits {needed!r}: {run.stderr!r}"
                for needed in (
                    "config: ",
                    f"[report] {fmt}",
                    "destination parent directory does not exist",
                )
                if needed not in run.stderr
            ]
            if "internal error" in run.stderr.lower():
                probs.append("refused as an internal error rather than a usage error")
            self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

    def check_run_report_case_alias(self) -> None:
        """Assert a case-only alias is judged by the VOLUME, not by the OS.

        `Run.out` and `run.out` are two files on ext4 and one file on APFS,
        which is the default on a supported platform. Comparing spellings alone
        would let the pair through there, publish both documents onto one
        inode, and exit 0 with one requested artifact missing — success reported
        for a run that lost a requested product.

        So the expectation is derived from the filesystem this check is standing
        on, the same way mtest derives it: create one name, ask whether its
        case-flipped spelling resolves. Where it does, the pair must be refused
        before the run; where it does not, the pair is legal and BOTH documents
        must land, which is the false-positive half of the same rule.
        """
        ref = "§15.5 destination collisions are compared as the volume sees them"
        name = "report: a case-only destination alias follows the volume's rule"
        out = self.root / "casealias"
        out.mkdir(exist_ok=True)
        probe = out / "casecheck"
        probe.write_text("x")
        folds = (out / "CASECHECK").exists()
        probe.unlink()
        upper, lower = out / "Run.out", out / "run.out"
        for stale in (upper, lower):
            if stale.exists():
                stale.unlink()
        run = self.mtest(
            [
                *I_FLAGS,
                "--report",
                f"md:{upper}",
                "--report",
                f"html:{lower}",
                "tests",
            ]
        )
        probs: list[str] = []
        if folds:
            if run.returncode != 4:
                probs.append(
                    f"a case-folding volume accepted the alias: exit "
                    f"{run.returncode}, want 4"
                )
            if "same destination" not in run.stderr:
                probs.append(f"not refused as a collision: {run.stderr!r}")
            if upper.exists() or lower.exists():
                probs.append("a refused run still published a document")
        else:
            if run.returncode != 0:
                probs.append(
                    f"a case-sensitive volume refused a legal pair: exit "
                    f"{run.returncode}, want 0"
                )
            # Both documents, and each in its own format: one file holding the
            # other's bytes is the loss this rule exists to prevent.
            if not upper.is_file() or not lower.is_file():
                probs.append("one of the two requested documents is missing")
            else:
                if not upper.read_text().startswith("# mtest report"):
                    probs.append("the markdown destination does not hold markdown")
                if not lower.read_text().startswith("<!doctype html>"):
                    probs.append("the html destination does not hold html")
        self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

    def check_config_show_report(self) -> None:
        """Assert `config show` renders a collision instead of refusing it.

        The run path refuses two destinations that name one file (§15.5), and
        `config show` must not: it resolves without touching the filesystem, so
        it renders both values with their provenance and exits 0. Pinned here
        because the two commands read the same resolved config and could
        otherwise drift silently.
        """
        ref = "§27.1 config show resolves only; §15.5 collisions are a run refusal"
        name = "config show: colliding destinations render with provenance, exit 0"
        project = self.root / "showcfg"
        project.mkdir(exist_ok=True)
        (project / "mtest.toml").write_text(
            '[report]\nmd = "same.md"\njson = "same.md"\nstyle = "full"\n'
        )
        run = self.mtest(["config", "show"], cwd=project)
        probs: list[str] = []
        if run.returncode != 0:
            probs.append(f"exit {run.returncode}, want 0")
        probs += [
            f"stdout omits {needed!r}"
            for needed in (
                'md = "same.md"  # (mtest.toml)',
                'json = "same.md"  # (mtest.toml)',
                'style = "full"  # (mtest.toml)',
            )
            if needed not in run.stdout
        ]
        if "same destination" in run.stdout + run.stderr:
            probs.append("config show refused a collision it must only render")
        self.record(FAIL if probs else PASS, name, ref, "; ".join(probs))

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
        # Outcomes + STABLE exit codes (§9,§10). CRASH must stay distinct from
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
            "collect: --fail-on-flaky rejected in collect -> 4",
            "§4",
            ["collect", *I, "--fail-on-flaky", "tests"],
            4,
        ),
        # The flag alone never moves a clean run: only a FLAKY file does.
        Check(
            "run: --fail-on-flaky green run stays 0",
            "§13",
            [*I, "--fail-on-flaky", "tests"],
            0,
        ),
        # Ordering flags: a seed without the flag it seeds, and two flags that
        # each choose an order, are both refused pre-run (§18).
        Check(
            "run: --seed without --shuffle -> 4",
            "§4",
            [*I, "--seed", "1", "tests"],
            4,
        ),
        Check(
            "run: --shuffle with --ff -> 4",
            "§4",
            [*I, "--shuffle", "--ff", "tests"],
            4,
        ),
        Check(
            "collect: --shuffle rejected -> 4",
            "§4",
            ["collect", *I, "--shuffle", "tests"],
            4,
        ),
        # `--format` is the mirror image of the rows above: the one flag that
        # belongs to collect alone, refused everywhere else.
        Check(
            "collect: --format bogus -> 4",
            "§16",
            ["collect", *I, "--format", "xml", "tests"],
            4,
        ),
        Check(
            "run: --format is collect-only -> 4",
            "§4",
            [*I, "--format", "json", "tests"],
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
        # debug (§28): every refusal is made BEFORE the handoff, so each of
        # these exits 4 with mtest still owning its own exit code.
        Check(
            "debug: plain path operand -> 4",
            "§28",
            ["debug", *I, "tests/test_reverse.mojo"],
            4,
            err_has=["PATH::TEST"],
        ),
        Check(
            "debug: unknown test -> 4",
            "§28",
            ["debug", *I, "tests/test_reverse.mojo::nope"],
            4,
            err_has=["unknown test"],
        ),
        Check(
            "debug: reporter flag refused -> 4",
            "§28",
            ["debug", *I, "--json", "-", "tests/test_reverse.mojo::test_reverse_ab"],
            4,
            err_has=["no terminal record could be written"],
        ),
        Check(
            "debug: --retries refused -> 4",
            "§28",
            ["debug", *I, "--retries", "1", "tests/test_reverse.mojo::test_reverse_ab"],
            4,
            err_has=["cannot be combined with 'debug'"],
        ),
        # The run report's pre-run refusals (§15.5). Every one is decided
        # before a file is built, so none of them can leave a partial document.
        Check(
            "run: --report bad format -> 4",
            "§15.5",
            [*I, "--report", "xml:r.xml", "tests"],
            4,
            err_has=["md:PATH or html:PATH"],
        ),
        Check(
            "run: --report duplicate format -> 4",
            "§15.5",
            [*I, "--report", "md:a.md", "--report", "md:b.md", "tests"],
            4,
            err_has=["given twice"],
        ),
        Check(
            "run: --report md=html collision -> 4",
            "§15.5",
            [*I, "--report", "md:out.md", "--report", "html:out.md", "tests"],
            4,
            err_has=["same destination"],
        ),
        Check(
            "run: --report collides with --junit-xml -> 4",
            "§15.5",
            [*I, "--report", "md:out.md", "--junit-xml", "out.md", "tests"],
            4,
            err_has=["same destination"],
        ),
        # The alias case: two spellings of ONE file, which a string comparison
        # of the raw values would let through.
        Check(
            "run: --report relative-alias collision -> 4",
            "§15.5",
            [*I, "--report", "md:out.md", "--json", "./out.md", "tests"],
            4,
            err_has=["same destination"],
        ),
        Check(
            "collect: --report rejected -> 4",
            "§4",
            ["collect", *I, "--report", "md:r.md", "tests"],
            4,
            err_has=["run-only"],
        ),
        Check(
            "doctor: --report rejected -> 4",
            "§4",
            ["doctor", "--report", "md:r.md"],
            4,
            err_has=["'--report' is a reporter flag and cannot be combined"],
        ),
        Check(
            "collect: --report-style rejected -> 4",
            "§4",
            ["collect", *I, "--report-style", "full", "tests"],
            4,
            err_has=["'--report-style' is a run-only flag"],
        ),
        Check(
            "doctor: --report-style rejected -> 4",
            "§4",
            ["doctor", "--report-style", "full"],
            4,
            err_has=["'--report-style' is a reporter flag and cannot be combined"],
        ),
        Check(
            "value: --report-style bad value -> 4",
            "§9,§15.5",
            [*I, "--report-style", "loud", "tests"],
            4,
            err_has=["wants 'concise' or 'full'"],
        ),
        # The collision rule is not a --report rule: it governs every active
        # file destination, so it must hold with no report flag in the argv.
        Check(
            "run: --json collides with --junit-xml -> 4",
            "§15.2,§15.4,§15.5",
            [*I, "--json", "shared.out", "--junit-xml", "./shared.out", "tests"],
            4,
            err_has=["same destination"],
        ),
        Check(
            "debug: --report rejected -> 4",
            "§28",
            [
                "debug",
                *I,
                "--report",
                "md:r.md",
                "tests/test_reverse.mojo::test_reverse_ab",
            ],
            4,
            err_has=["no terminal record could be written"],
        ),
        # §30. Each shell gets the frame its own completion system needs, and
        # the bash probe additionally pins the two head-resolution statements
        # the section makes: a bare `config` completes exactly `show`, and a
        # value arm is keyed on the command as well as the flag, so
        # `doctor --report-style` has no arm at all.
        Check(
            "completions: bash prints a sourceable function",
            "§30",
            ["completions", "bash"],
            0,
            out_has=[
                "complete -F _mtest_complete mtest",
                'config-pending) COMPREPLY=($(compgen -W "show"',
                '"run:--report-style"',
            ],
            any_absent=["doctor:--report-style"],
        ),
        Check(
            "completions: zsh prints a compdef script",
            "§30",
            ["completions", "zsh"],
            0,
            out_has=["#compdef mtest", "compdef _mtest mtest", "--collect-only"],
        ),
        Check(
            "completions: fish prints complete rules",
            "§30",
            ["completions", "fish"],
            0,
            out_has=["complete -c mtest", "__mtest_head_is", "-l 'collect-only'"],
        ),
        Check(
            "completions: no shell operand -> 4",
            "§30",
            ["completions"],
            4,
            err_has=["'completions' wants one of bash, zsh, fish"],
        ),
        Check(
            "completions: an unrenderable shell -> 4",
            "§30",
            ["completions", "tcsh"],
            4,
            err_has=["'completions' wants one of bash, zsh, fish", "tcsh"],
        ),
        # Help is a directive, not a stop: §30 permits one operand and help
        # and nothing else, so the whole vector is judged before help wins.
        # Returning on sight of `--help` printed help and exited 0 here.
        Check(
            "completions: a trailing operand after --help -> 4",
            "§30",
            ["completions", "bash", "--help", "garbage"],
            4,
            err_has=["'completions' wants one shell", "garbage"],
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
    # §4 marks `--serial` accepted-inert under `collect`, beside `-n`, and for
    # the same reason: refusing a flag every earlier build accepted would break
    # invocations that pass one flag set to both subcommands. Every other
    # run-only flag is an exit-4 refusal there, so which side of that line this
    # one sits on needs a gate rather than a table entry alone.
    checks.append(
        Check(
            "served: collect --serial accepted, inert (not exit 4)",
            "§4,§18,§24.1",
            ["collect", *I, "--serial", "tests/*", "tests"],
            0,
            any_absent=["v1 contract", "run-only flag"],
        )
    )
    # The cache flags are accepted-inert under `doctor` for the same reason
    # `--serial` is under `collect`. `doctor` renders its diagnosis and returns
    # before the store is read or `--cache-clear` acts, so neither value is
    # honored and neither is refused. Both sit one word away from the run,
    # build, selection, state, and reporter flags `doctor` DOES refuse, so
    # which side of that line they fall on needs a gate: this pair drifted
    # between the table and the parser undetected because nothing probed it.
    checks.extend(
        Check(
            f"served: doctor {flag} accepted, inert (not exit 4)",
            "§4,§8.5,§27.2",
            ["doctor", flag],
            0,
            any_absent=["v1 contract", "cannot be combined"],
        )
        for flag in ("--no-cache", "--cache-clear")
    )
    # `--format` belongs to the collection MODE, not to the `collect` head
    # token. `--collect-only` selects that mode, so this is a listing and the
    # flag applies; the neighboring `run: --format is collect-only -> 4` check
    # pins the other side, where there is no listing to shape.
    checks.append(
        Check(
            "served: --collect-only --format json is a collection (not exit 4)",
            "§4,§16",
            [*I, "--collect-only", "--format", "json", "tests"],
            0,
            out_has=["test_reverse_ab"],
            any_absent=["v1 contract", "collect-only flag"],
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
        if wanted("collect: --format json agrees with the lines listing and the exit"):
            runner.check_collect_json()
        if wanted(
            "collect: a listing larger than the pipe buffer survives an early close"
        ):
            runner.check_collect_pipe_early_close()
        if wanted("pipe: every direct-output command survives a closed stdout"):
            runner.check_direct_output_closed_pipe()
        if wanted("io: an unwritable output descriptor exits 3, never a crash"):
            runner.check_unwritable_output_descriptor()
        if wanted("io: an undelivered report still releases the JUnit spool"):
            runner.check_undelivered_output_releases_its_resources()
        if wanted("collect: an interrupted --format json run agrees with its own exit"):
            runner.check_collect_interrupted_json()
        if wanted("determinism: --shuffle --seed repeats its file order"):
            runner.check_shuffle_determinism()
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
        if wanted("path: a '::' path is skipped, never listed, and refused by name"):
            runner.check_separator_in_path()
        if wanted("value: 2^63 refused for every non-negative integer flag"):
            runner.check_integer_overflow_values()
        if wanted("report: --json to a readerless FIFO fails fast, never blocks"):
            runner.check_json_fifo_does_not_block()
        if wanted("path: a long-but-legal path builds, never a false COMPILE-ERROR"):
            runner.check_long_path_builds()
        if wanted("flaky: --fail-on-flaky turns a FLAKY-only run's 0 into 1"):
            runner.check_fail_on_flaky()
        if wanted("debug: the handoff is the test's own exit, with no mtest verdict"):
            runner.check_debug_handoff()
        if wanted("new: scaffolds a discoverable file"):
            runner.check_new_creates()
        if wanted("new: refuses to overwrite -> 4"):
            runner.check_new_refuses_to_overwrite()
        if wanted("new: non-discoverable name -> 4") or wanted(
            "new: node-id-shaped path -> 4"
        ):
            runner.check_new_refuses_unusable_names()
        if wanted("new: the scaffolded file runs green") or wanted(
            "new: a hostile basename still compiles and passes"
        ):
            runner.check_new_scaffold_runs()
        if (
            wanted("init: --ci github bootstraps a runnable project")
            or wanted("init: a second run skips every artifact, still 0")
            or wanted("init: --ci gitlab -> 4")
        ):
            runner.check_init_scaffold()
        if (
            wanted("report: --report md publishes a document for a green run")
            or wanted(
                "report: --report md+html describes a failing run in both formats"
            )
            or wanted("report: --report-style full sections a file concise leaves out")
            or wanted(
                "determinism: two --report runs agree once durations are normalized"
            )
        ):
            runner.check_run_report()
        if wanted("report: an unwritable --report target exits 3, prior report intact"):
            runner.check_run_report_construction_failure()
        if wanted(
            "report: a configured md destination with a missing parent -> 4"
        ) or wanted("report: a configured html destination with a missing parent -> 4"):
            runner.check_run_report_configured_missing_parent()
        if wanted("report: a case-only destination alias follows the volume's rule"):
            runner.check_run_report_case_alias()
        if wanted("config show: colliding destinations render with provenance, exit 0"):
            runner.check_config_show_report()
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
