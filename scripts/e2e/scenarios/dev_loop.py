"""Developer-loop scenarios: the controls used while hunting a flaky suite.

`--shuffle` is the first of them. Its claim is about the relationship between
two whole runs, so nothing inside one process can settle it: only a second run
of the same command shows that a seed reproduces an order, and only a third run
under a different seed shows that the order was ever randomized at all.

The comparison is deliberately made over the `--json` stream's ordered
`file_started` projection rather than over console bytes. The console carries
the run's wall clock and its build-cache counters, which the contract excludes
from byte identity, so two console outputs of the identical run differ for
reasons that have nothing to do with ordering.

`debug` is the second, and its claim is about what is left of mtest after it
hands a terminal to a single test: the exit status has to be the test's own,
nothing may dress a handed-over zero up as an mtest verdict, and the process
the test wakes up in has to be a clean one. All three are black-box facts about
a finished process, so all three are asserted from out here rather than from
inside the runner.

`new` is the third, and its claim is about a file rather than a process: the
bytes it scaffolds have to compile and pass, and a second scaffold has to leave
an existing file exactly as it found it. Only building and running the real
output settles the first, and only putting known content in the way settles the
second.

`init` is the fourth and widens that claim from a file to a directory: the
project it bootstraps has to run with no operands at all, which is a fact about
the configuration and the test file together, and a second bootstrap has to
change nothing — including the `.gitignore` it is the one command here allowed
to rewrite.
"""

from __future__ import annotations

import fcntl
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
from typing import TYPE_CHECKING

from scripts.e2e.assertions import expect, expect_exit, stream_files
from scripts.e2e.runner import E2ERunner, ScenarioError


if TYPE_CHECKING:
    from scripts.e2e.runner import Run, ScenarioContext


SUITE = "e2e/suite"
"""The committed known-outcome tree. Seven run files is enough that two seeds
drawing the same permutation would be a coincidence worth investigating rather
than an ordinary collision."""


def _order(context: ScenarioContext, seed: str) -> tuple[str, ...]:
    """The ordered `file_started` paths of one seeded shuffled run of SUITE.

    Args:
        context: The scenario context whose runner drives the binary.
        seed: The `--seed` value to run under.

    Returns:
        The run files in the order the stream announced them.

    Raises:
        ScenarioError: If the run did not exit with the suite's known failing
            verdict, since a run that died early carries no ordering fact.
    """
    run = context.runner.run_mtest(
        [
            SUITE,
            "--shuffle",
            "--seed",
            seed,
            "--json",
            "-",
            "--gh-annotations",
            "off",
        ]
    )
    # The suite carries failing members, so 1 is its ordinary verdict, and it
    # must not move because the order did.
    expect_exit(run, 1)
    return stream_files(run.stdout).started


ALTERNATIVES = ("9", "2", "3")
"""Seeds tried in turn until one draws a different order from the reference.

Fixing a single alternative would make the scenario fail whenever that
particular pair happens to draw the same permutation, which a change to the
suite's file set could cause at any time. Only every alternative agreeing is
evidence that nothing was randomized. They are tried lazily, so the ordinary
run costs one extra session, not three.
"""


def s_shuffle_seed_reproduces(context: ScenarioContext) -> str:
    """A seed replays its file order, and a different seed draws another one.

    Both halves are needed. Two same-seed runs agreeing is also what a
    `--shuffle` that never moved a file produces, so the different-seed run is
    what proves the randomization is real. Comparing the two orders' sets before
    their sequences separates "the order changed" from "a different set of files
    ran", which would be a far more serious defect with the same symptom.
    """
    first = _order(context, "7")
    again = _order(context, "7")

    expect(
        len(first) >= 3,
        f"too few files ran to carry an order at all: {first}",
    )
    expect(
        first == again,
        f"one seed drew two different orders:\n  {first}\n  {again}",
    )

    reordered_by = ""
    for seed in ALTERNATIVES:
        other = _order(context, seed)
        expect(
            sorted(first) == sorted(other),
            f"seed {seed} ran a different SET of files, not a different order:"
            f"\n  {sorted(first)}\n  {sorted(other)}",
        )
        if other != first:
            reordered_by = seed
            break
    expect(
        bool(reordered_by),
        f"no seed in {ALTERNATIVES} reordered {first}, so nothing was randomized",
    )
    return (
        f"seed 7 replayed {len(first)} files in order; "
        f"seed {reordered_by} reordered them"
    )


DEBUG_NODE = "e2e/suite/test_passing.mojo::test_two_passes"
"""A node whose test passes, so the handed-over binary exits 0 on its own."""

DEBUG_FAILING_NODE = "e2e/suite/test_failing.mojo::test_second_fails"
"""A node whose test fails, so the handed-over binary exits nonzero on its own.

The pair is what makes the no-verdict assertion mean something: a build that
printed a summary band would print one for both, and a build that laundered the
handoff into a verdict would have to disagree with one of the two exits."""

ACTOR_SOURCE = """\
from std.os import getenv, listdir
from std.os.path import exists
from std.ffi import external_call
from std.testing import TestSuite
from std.time import sleep


def test_debug_environment() raises:
    # SAFETY: libc `getpid` takes no arguments and returns `pid_t`, an `int` on
    # both supported targets, so this fixed declaration matches each ABI. It
    # reads no memory this process owns, retains no pointer, and cannot fail.
    var pid = external_call["getpid", Int32]()
    print("debug-actor: pid=" + String(Int(pid)))
    if not exists("/proc/self/status"):
        print("debug-actor: proc=absent")
        return
    var handle = open("/proc/self/status", "r")
    var status = String(handle.read())
    handle.close()
    for line in status.split("\\n"):
        var text = String(line)
        if text.startswith("SigIgn:"):
            print("debug-actor: " + text)
    var names = String("")
    for entry in listdir("/proc/self/fd"):
        if names != "":
            names += ","
        names += String(entry)
    print("debug-actor: fds=" + names)


def test_broken_pipe() raises:
    var release = getenv("MTEST_DEBUG_RELEASE", "")
    var waited = 0
    while release != "" and not exists(release) and waited < 3000:
        sleep(0.01)
        waited += 1
    var chunk = String("")
    for _ in range(64):
        chunk += "0123456789abcdef"
    for _ in range(64):
        print(chunk)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
    var ready = getenv("MTEST_DEBUG_READY", "")
    if ready != "":
        with open(ready, "w") as marker:
            marker.write("ready")
"""
"""The suite the debug scenarios drive, and the barriers they synchronise on.

It is written in Mojo and compiled by the real toolchain rather than faked,
because the instrument has to be trustworthy about the things these scenarios
measure. A Python actor cannot be: CPython sets `SIGPIPE` to `SIG_IGN` during
interpreter startup, so a Python debuggee reads its own disposition back no
matter what it inherited, and would report a restoration failure that never
happened. A compiled Mojo binary changes no disposition and reports what it was
handed.

Three roles. `test_debug_environment` reports the process it woke up in: its
pid from `getpid`, so the identity half holds on both platforms, and the two
`/proc` facts only where that filesystem exists — their absence is announced
rather than assumed. `test_broken_pipe` waits on a release file and then floods
stdout, which is how a scenario can close the reader first and watch what the
inherited `SIGPIPE` disposition actually does. And `main` writes a ready marker
after the suite returns, so a scenario can know the `--skip-all` probe has
finished without guessing at a duration.

Everything printed is a fact, not a verdict: the assertions live in the
scenarios, where a failure can say what it means."""

READY_ENV = "MTEST_DEBUG_READY"
"""Environment variable naming the file the actor touches after its probe."""

RELEASE_ENV = "MTEST_DEBUG_RELEASE"
"""Environment variable naming the file `test_broken_pipe` waits for."""

BARRIER_DEADLINE = 180.0
"""Seconds a scenario waits for a marker before calling the run hung. Sized for
a cold `mojo build` of the actor, which every one of these runs pays."""

WCHAN_DEADLINE = 5.0
"""How long to wait for the kernel to report a task blocked in a pipe write.

Its own budget rather than `BARRIER_DEADLINE`: this poll waits on a state a
process reaches in milliseconds, so anything past a few seconds means the
kernel is not going to answer — `wchan` reads back empty without
`CONFIG_KALLSYMS`, and a `hidepid` mount hides it too. Reusing the 180-second
budget would spend eighteen minutes over the six graces below before falling
back to them.
"""

BARRIER_POLL = 0.01
"""Seconds between marker polls."""

SIGPIPE_BIT = 1 << (13 - 1)
"""`SIGPIPE`'s bit in the `SigIgn` mask, which is indexed from signal 1."""


def _marker_lines(run: Run) -> tuple[str, str]:
    """The two lines `debug` prints before it hands the terminal over.

    Args:
        run: A completed `mtest debug` run.

    Returns:
        The `build: ` and `run: ` lines, in that order.

    Raises:
        ScenarioError: If stdout does not open with both of them, which means
            the handover was never announced or something printed ahead of it.
    """
    lines = run.stdout.splitlines()
    expect(
        len(lines) >= 2,
        f"debug printed fewer than two lines before handing over: {run.stdout!r}",
    )
    expect(
        lines[0].startswith("build: "),
        f"the first stdout line is not the build line: {lines[0]!r}",
    )
    expect(
        lines[1].startswith("run: "),
        f"the second stdout line is not the run line: {lines[1]!r}",
    )
    return lines[0], lines[1]


def _expect_no_verdict(run: Run) -> None:
    """Assert nothing in either stream claims an mtest verdict.

    Args:
        run: A completed `mtest debug` run that reached the handoff.

    Raises:
        ScenarioError: If a summary band, a verdict row, or a reproduce line
            survived the handover. Past the exec there is no mtest left to
            produce one, so any of them would mean the process never handed
            over at all.

    The forbidden verdict tokens are matched at the start of a line, which is
    where mtest's own console rows begin. `TestSuite`'s per-test rows carry the
    same words indented, and those are exactly what this run is supposed to
    show — the point is that the words arrive from the test binary rather than
    from a runner that is no longer there.
    """
    forbidden = ("=====", "PASS ", "FAIL ", "CRASH ", "reproduce:")
    for stream, text in (("stdout", run.stdout), ("stderr", run.stderr)):
        for line in text.splitlines():
            for token in forbidden:
                expect(
                    not line.startswith(token),
                    f"{stream} carries an mtest {token!r} row after the "
                    f"handoff, claiming a verdict it is in no position to "
                    f"have: {line!r}",
                )


def s_debug_hands_over(context: ScenarioContext) -> str:
    """`debug` announces two commands, becomes the test, and claims nothing.

    Both halves assert the same three things against different exits: the two
    marker lines come first, the test binary's own report text follows them on
    the same stream, and the process exits with the code the binary itself
    produced. The absence of a summary band is the proof that a zero here is
    the binary's statement rather than an mtest PASS.
    """
    passing = context.runner.run_mtest(["debug", DEBUG_NODE])
    expect_exit(passing, 0)
    build_line, run_line = _marker_lines(passing)
    expect(
        "build/bin/" in build_line,
        f"the build line names no deterministic output path: {build_line!r}",
    )
    expect(
        run_line.endswith("--only test_two_passes"),
        f"the run line does not end in the selector: {run_line!r}",
    )
    expect(
        "tests run:" in passing.stdout,
        f"the test binary's own report never arrived: {passing.stdout!r}",
    )
    _expect_no_verdict(passing)

    failing = context.runner.run_mtest(["debug", DEBUG_FAILING_NODE])
    expect_exit(failing, 1)
    _marker_lines(failing)
    expect(
        "tests run:" in failing.stdout,
        f"the failing binary's own report never arrived: {failing.stdout!r}",
    )
    _expect_no_verdict(failing)
    return "handed over twice; the exit was the test's own both times"


def s_debug_refusals(context: ScenarioContext) -> str:
    """Every `debug` refusal lands before the handoff, as a usage error.

    A refusal that arrived after the exec could not exist — there would be no
    mtest to make it — so each of these is also a check that the preparation
    really does run to completion before anything is handed anywhere.
    """
    plain = context.runner.run_mtest(["debug", "e2e/suite/test_passing.mojo"])
    expect_exit(plain, 4)
    expect(
        "PATH::TEST" in plain.stderr,
        f"the plain-path refusal does not name the wanted form: {plain.stderr!r}",
    )
    expect(
        not plain.stdout,
        f"a refused debug printed to stdout: {plain.stdout!r}",
    )

    retries = context.runner.run_mtest(["debug", "--retries", "1", DEBUG_NODE])
    expect_exit(retries, 4)
    expect(
        "--retries" in retries.stderr,
        f"the --retries refusal does not name the flag: {retries.stderr!r}",
    )

    unknown = context.runner.run_mtest(
        ["debug", "e2e/suite/test_passing.mojo::test_nope"]
    )
    expect_exit(unknown, 4)
    expect(
        "unknown test" in unknown.stderr,
        f"the unknown-name refusal is not the select one: {unknown.stderr!r}",
    )
    return "plain path, --retries, and an unknown name all refused with 4"


def s_debug_environment(context: ScenarioContext) -> str:
    """The handed-over process is the SAME process, with a clean environment.

    The debugged test reports three facts about the process it woke up in, and
    each answers a way the handoff could have gone quietly wrong:

    - its pid, compared with the process group the harness created for mtest.
      They are equal only if the image was REPLACED; a spawned child would sit
      in the group under a different pid.
    - its `SigIgn` mask. The exec runtime ignores `SIGPIPE` for its lifetime,
      and POSIX carries an ignored disposition across `execv`, so a debuggee
      that inherited `SIG_IGN` would survive a broken pipe that should have
      killed it and a genuine crash could read as a pass. mtest closes the
      runtime before the exec precisely to restore it.
    - its open descriptors. Everything the process adapter opens is
      close-on-exec, so the debuggee should hold the three standard streams and
      nothing else. The listing itself needs one descriptor while it is read,
      which is why exactly one extra is tolerated and two are not.

    The suite is built in a throwaway project by the real toolchain, so the
    binary under the handoff is an ordinary compiled test rather than a
    stand-in.
    """
    with tempfile.TemporaryDirectory(prefix="mtest-debug-env-") as raw:
        project = Path(raw)
        (project / "tests").mkdir()
        (project / "tests" / "test_env.mojo").write_text(ACTOR_SOURCE, encoding="utf-8")
        runner = E2ERunner(
            repo_root=project,
            mtest=context.runner.mtest,
            default_timeout=context.runner.default_timeout,
            short_timeout=context.runner.short_timeout,
        )
        run = runner.run_mtest(["debug", "tests/test_env.mojo::test_debug_environment"])

    expect_exit(run, 0)
    _marker_lines(run)
    _expect_no_verdict(run)
    facts: dict[str, str] = {}
    for line in run.stdout.splitlines():
        if not line.startswith("debug-actor: "):
            continue
        body = line.removeprefix("debug-actor: ")
        separator = "=" if "=" in body else ":"
        key, _, value = body.partition(separator)
        facts[key.strip()] = value.strip()

    expect(
        "pid" in facts,
        f"the debugged test reported no pid, so nothing shows it was exec'd: {facts}",
    )
    expect(
        run.pgid is not None and facts["pid"] == str(run.pgid),
        f"the test's pid {facts['pid']} is not mtest's own process "
        f"{run.pgid}: the terminal went to a CHILD, not to a replaced image",
    )
    if "SigIgn" not in facts:
        # No `/proc`, so the disposition and descriptor facts do not exist to
        # be read. The pid identity above is platform-independent and still
        # proves the handover was an image replacement.
        return f"same pid {facts['pid']}; {facts.get('proc', 'no /proc')}"

    ignored = int(facts["SigIgn"], 16)
    expect(
        not ignored & SIGPIPE_BIT,
        f"the debuggee inherited SIGPIPE=SIG_IGN (SigIgn {facts['SigIgn']}): "
        "the exec runtime was not restored before the handoff, so a "
        "broken-pipe death would be swallowed",
    )
    extra = sorted(set(facts["fds"].split(",")) - {"0", "1", "2"})
    expect(
        len(extra) <= 1,
        f"the debuggee inherited descriptors beyond 0/1/2 and its own "
        f"directory handle: {facts['fds']}",
    )
    return f"same pid {facts['pid']}, SigIgn {facts['SigIgn']}, fds {facts['fds']}"


def _debug_project(directory: Path) -> Path:
    """Write the actor suite into `directory` and return its source path.

    Args:
        directory: An existing scratch directory that becomes the invocation
            root.

    Returns:
        The path of the written test file.
    """
    (directory / "tests").mkdir()
    source = directory / "tests" / "test_env.mojo"
    source.write_text(ACTOR_SOURCE, encoding="utf-8")
    return source


def _await_marker(marker: Path, what: str) -> None:
    """Block until `marker` exists, under one deadline.

    Args:
        marker: The file the actor creates.
        what: Human-readable subject for the failure message.

    Raises:
        ScenarioError: If the marker never appears, which means the run never
            reached the point the scenario is trying to interrupt or release.
    """
    limit = time.monotonic() + BARRIER_DEADLINE
    while not marker.exists():
        if time.monotonic() >= limit:
            raise ScenarioError(
                f"{what}: {marker} never appeared within {BARRIER_DEADLINE:.0f}s"
            )
        time.sleep(BARRIER_POLL)


def _fill_pipe(write_fd: int) -> int:
    """Fill a pipe to capacity and leave the descriptor blocking again.

    The descriptor is handed to mtest as its stdout, so it has to be blocking
    when the child inherits it — the flag lives on the shared open file
    description, not on the copy.

    Args:
        write_fd: The pipe's write end.

    Returns:
        How many filler bytes were written.
    """
    flags = fcntl.fcntl(write_fd, fcntl.F_GETFL)
    fcntl.fcntl(write_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    filler = b"." * 4096
    written = 0
    try:
        while True:
            written += os.write(write_fd, filler)
    except BlockingIOError:
        pass
    finally:
        fcntl.fcntl(write_fd, fcntl.F_SETFL, flags)
    return written


def _await_blocked_pipe_write(pid: int) -> bool:
    """Wait until the kernel reports `pid` asleep inside a pipe write.

    This is the barrier the scenario below needs and the ready marker could
    never be: the marker says the probe actor finished, which is several steps
    short of mtest reaching the write the scenario is trying to interrupt. On
    Linux the kernel answers the real question directly — `/proc/<pid>/wchan`
    names the function the task is sleeping in, and mtest's only pipe is the
    stdout the caller deliberately filled, so `pipe_write` is unambiguous.

    Args:
        pid: The mtest process to observe.

    Returns:
        True once the process is observed blocked in a pipe write. False when
        the kernel cannot be asked — no `/proc`, or a `hidepid` mount — which
        leaves the caller to fall back on its own retry budget rather than
        reporting a failure it has no evidence for.
    """
    wchan = Path(f"/proc/{pid}/wchan")
    if not wchan.exists():
        return False
    limit = time.monotonic() + WCHAN_DEADLINE
    while time.monotonic() < limit:
        try:
            state = wchan.read_text()
        except OSError:
            return False
        # `anon_pipe_write` on current kernels, `pipe_write` on older ones.
        if "pipe_write" in state:
            return True
        time.sleep(0.002)
    return False


INTERRUPT_GRACES = (0.0, 0.02, 0.1, 0.5, 2.0, 5.0)
"""Delays tried in turn where the kernel barrier above is unavailable.

Only reached on a platform without a readable `/proc`. Each entry is one whole
attempt, and every attempt still asserts the property that must always hold, so
the budget buys coverage of the write window rather than permission to fail.
"""


def _interrupt_before_handoff(
    context: ScenarioContext, grace: float
) -> tuple[int, str]:
    """Interrupt one `debug` run while its marker write is blocked.

    Args:
        context: The scenario context supplying the binary under test.
        grace: Seconds to wait after the probe marker before signalling, used
            only when `_await_blocked_pipe_write` could not answer.

    Returns:
        The run's exit code, and everything it wrote to stdout past the filler.
    """
    with tempfile.TemporaryDirectory(prefix="mtest-debug-int-") as raw:
        project = Path(raw)
        _debug_project(project)
        ready = project / "probe-ready"
        read_fd, write_fd = os.pipe()
        errors = project / "stderr.txt"
        filler = _fill_pipe(write_fd)
        child_env = dict(os.environ)
        child_env["GITHUB_ACTIONS"] = ""
        child_env[READY_ENV] = str(ready)
        with open(errors, "wb") as error_sink:
            process = subprocess.Popen(
                [
                    os.fspath(context.runner.mtest),
                    "debug",
                    "tests/test_env.mojo::test_debug_environment",
                ],
                cwd=project,
                stdout=write_fd,
                stderr=error_sink,
                env=child_env,
                start_new_session=True,
            )
        os.close(write_fd)
        try:
            _await_marker(ready, "the --skip-all probe")
            if not _await_blocked_pipe_write(process.pid):
                time.sleep(grace)
            os.kill(process.pid, signal.SIGINT)
            captured = b""
            while True:
                chunk = os.read(read_fd, 65536)
                if not chunk:
                    break
                captured += chunk
            code = process.wait(timeout=BARRIER_DEADLINE)
        finally:
            os.close(read_fd)
            if process.poll() is None:
                process.kill()
                process.wait()
        text = captured[filler:].decode("utf-8", errors="replace")
    return code, text


def s_debug_interrupt_before_handoff(context: ScenarioContext) -> str:
    """An interrupt latched before the exec is answered by mtest, not the test.

    The window is real and was reachable: the two marker lines are written
    before the handoff, and a reader that has stopped reading blocks that write
    for as long as it likes. An interrupt arriving then used to be carried
    straight through the exec, and the process exited with whatever the test
    binary went on to return — a SIGINT answered with a green run.

    The pipe is filled to capacity before mtest is spawned, so its marker write
    is guaranteed to block, and the SIGINT is sent only once the kernel says
    mtest is sleeping in that write. Waiting on the actor's ready marker alone
    was not enough and was not a rare miss: the marker says the probe finished,
    which is several steps before the write, so on a single CPU the signal won
    the race every time and the scenario reported that it had proved nothing.
    A platform whose kernel cannot be asked falls back to a retry budget, and
    the properties that must always hold — an exit of two, and no output from
    the test binary — are asserted on every attempt either way.
    """
    for attempt, grace in enumerate(INTERRUPT_GRACES, start=1):
        code, text = _interrupt_before_handoff(context, grace)
        expect(
            code == 2,
            f"an interrupt before the handoff exited {code}, want 2; mtest "
            f"handed the terminal over while holding a latched SIGINT\n{text!r}",
        )
        expect(
            "tests run:" not in text,
            f"the test binary ran anyway, so the exec happened despite the "
            f"latched interrupt: {text!r}",
        )
        if "build: " in text and "run: " in text:
            return (
                "SIGINT during the blocked marker write -> exit 2, no handoff "
                f"(attempt {attempt} of {len(INTERRUPT_GRACES)})"
            )
    raise ScenarioError(
        "every attempt interrupted mtest before it reached the marker write, "
        "so the handoff window went untested; the kernel barrier is "
        "unavailable here and the retry budget was not enough"
    )


def s_debug_default_sigpipe(context: ScenarioContext) -> str:
    """The debuggee dies of a broken pipe, which is the property that matters.

    Reading the disposition out of `/proc` proves the bookkeeping and is Linux
    only. This proves the behaviour on every platform: the reader is closed
    after the two marker lines arrive, the debuggee is released, and its first
    write to the dead pipe has to kill it. Under an inherited `SIG_IGN` — the
    state a handoff that skipped the runtime close would leave — that write
    would return `EPIPE` instead and the process would live on, which is
    exactly how a crash comes to read as a pass.
    """
    with tempfile.TemporaryDirectory(prefix="mtest-debug-pipe-") as raw:
        project = Path(raw)
        _debug_project(project)
        release = project / "release"
        errors = project / "stderr.txt"
        child_env = dict(os.environ)
        child_env["GITHUB_ACTIONS"] = ""
        child_env[RELEASE_ENV] = str(release)
        with open(errors, "wb") as error_sink:
            process = subprocess.Popen(
                [
                    os.fspath(context.runner.mtest),
                    "debug",
                    "tests/test_env.mojo::test_broken_pipe",
                ],
                cwd=project,
                stdout=subprocess.PIPE,
                stderr=error_sink,
                env=child_env,
                start_new_session=True,
            )
        reader = process.stdout
        if reader is None:  # pragma: no cover - Popen was asked for a pipe
            raise ScenarioError("the run was spawned without a stdout pipe")
        try:
            markers = [reader.readline(), reader.readline()]
            reader.close()
            release.write_bytes(b"go")
            code = process.wait(timeout=BARRIER_DEADLINE)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
        detail = errors.read_text(encoding="utf-8", errors="replace")

    expect(
        markers[0].startswith(b"build: ") and markers[1].startswith(b"run: "),
        f"the handoff was never announced: {markers!r}\n{detail}",
    )
    expect(
        code == -signal.SIGPIPE,
        f"the debuggee exited {code}, want {-signal.SIGPIPE} (death by "
        "SIGPIPE): it inherited an ignored disposition from the exec runtime, "
        f"so a broken pipe no longer kills it\n{detail}",
    )
    return "the debuggee died of SIGPIPE, so it inherited the default"


def s_debug_inactive_config(context: ScenarioContext) -> str:
    """Report destinations and last-run state are never acted on under debug.

    Both halves are black-box, because both are about files that must not
    appear or change. The project asks for a JUnit report and a JSON stream and
    carries a last-run state file with known bytes; after a successful handoff
    neither destination exists and the state is byte-identical.

    The second half pins the boundary the contract now states explicitly:
    inactive is not unparsed. A malformed value in an inactive table is still a
    usage error, because the document is validated before any command
    projection exists — the same answer `run` and `collect` give.
    """
    with tempfile.TemporaryDirectory(prefix="mtest-debug-cfg-") as raw:
        project = Path(raw)
        _debug_project(project)
        (project / ".mtest-cache").mkdir()
        state = project / ".mtest-cache" / "lastrun"
        state.write_bytes(b"mtest-lastrun v1\ntest\ttests/gone.mojo::test_x\n")
        before = state.read_bytes()
        config = project / "mtest.toml"
        config.write_text(
            '[report]\njunit-xml = "report.xml"\njson = "stream.ndjson"\n',
            encoding="utf-8",
        )
        runner = E2ERunner(
            repo_root=project,
            mtest=context.runner.mtest,
            default_timeout=context.runner.default_timeout,
            short_timeout=context.runner.short_timeout,
        )
        run = runner.run_mtest(["debug", "tests/test_env.mojo::test_debug_environment"])
        expect_exit(run, 0)
        _marker_lines(run)
        expect(
            not (project / "report.xml").exists(),
            "a configured JUnit destination was created by a command that "
            "renders no report",
        )
        expect(
            not (project / "stream.ndjson").exists(),
            "a configured stream destination was created by a command that "
            "emits no events",
        )
        expect(
            state.read_bytes() == before,
            f"the last-run state changed under debug: {state.read_bytes()!r}",
        )

        config.write_text('[report]\ncolor = "not-a-color"\n', encoding="utf-8")
        malformed = runner.run_mtest(
            ["debug", "tests/test_env.mojo::test_debug_environment"]
        )
        expect_exit(malformed, 4)
        expect(
            "color" in malformed.stderr,
            f"the document diagnostic does not name the offending key: "
            f"{malformed.stderr!r}",
        )
    return "no report written, lastrun untouched, malformed document still 4"


def s_new_then_run(context: ScenarioContext) -> str:
    """The scaffolded file runs green, and a second scaffold never replaces it.

    The deliverable is not the exit code of `mtest new`; it is that the bytes
    it wrote are a test file the real toolchain compiles and the real runner
    passes. So the scenario runs them, in a throwaway root, rather than
    comparing them with a copy of the template.

    The second half is the never-overwrite promise, asserted the only way that
    means anything: the target is replaced with hand-written content, the
    scaffold is asked for again, and the refusal is checked together with the
    bytes still being exactly what was put there. The last half runs the same
    build through a basename carrying the characters that would end the
    docstring the name is interpolated into, and pins the two refusals that
    exist so no file is created that mtest could not address afterwards.
    """
    with tempfile.TemporaryDirectory(prefix="mtest-new-") as raw:
        project = Path(raw)
        runner = E2ERunner(
            repo_root=project,
            mtest=context.runner.mtest,
            default_timeout=context.runner.default_timeout,
            short_timeout=context.runner.short_timeout,
        )
        created = runner.run_mtest(["new", "tests/nested/test_scaffolded.mojo"])
        expect_exit(created, 0)
        expect(
            created.stdout == "created tests/nested/test_scaffolded.mojo\n",
            f"the success line is not the contract's: {created.stdout!r}",
        )
        expect(
            created.stderr == "",
            f"a successful scaffold wrote diagnostics: {created.stderr!r}",
        )

        scaffolded = project / "tests" / "nested" / "test_scaffolded.mojo"
        expect(
            scaffolded.is_file(),
            "the scaffolded file is missing, so the parent directories were "
            "never created",
        )
        siblings = sorted(p.name for p in scaffolded.parent.iterdir())
        expect(
            siblings == ["test_scaffolded.mojo"],
            f"the publication left something beside the file it created: {siblings}",
        )
        # Compared against a file created here the ordinary way rather than
        # against a fixed bit pattern: "the mode an editor would have
        # produced" is whatever the umask says, so `0o044` would go red under
        # `umask 077` with nothing wrong. The probe is made after the litter
        # check above and removed immediately.
        ordinary = scaffolded.parent / "ordinary.probe"
        ordinary.write_text("x")
        want_mode = ordinary.stat().st_mode & 0o777
        ordinary.unlink()
        mode = scaffolded.stat().st_mode & 0o777
        expect(
            mode == want_mode,
            f"the scaffolded file carries mode {mode:#o}, not the "
            f"{want_mode:#o} an ordinary create in this directory produces",
        )

        ran = runner.run_mtest(["tests/nested/test_scaffolded.mojo"])
        expect_exit(ran, 0)
        expect(
            "1 passed" in ran.stdout,
            f"the scaffolded file did not run as one passing test: {ran.stdout!r}",
        )

        mine = "# hand-written, and not to be replaced\n"
        scaffolded.write_text(mine, encoding="utf-8")
        refused = runner.run_mtest(["new", "tests/nested/test_scaffolded.mojo"])
        expect_exit(refused, 4)
        expect(
            "refusing to overwrite" in refused.stderr,
            f"the refusal does not say what it refused: {refused.stderr!r}",
        )
        expect(
            refused.stdout == "",
            f"a refused scaffold wrote to stdout: {refused.stdout!r}",
        )
        expect(
            scaffolded.read_text(encoding="utf-8") == mine,
            "the refused scaffold overwrote the file it refused to overwrite: "
            f"{scaffolded.read_text(encoding='utf-8')!r}",
        )
        leftovers = sorted(p.name for p in scaffolded.parent.iterdir())
        expect(
            leftovers == ["test_scaffolded.mojo"],
            f"the refusal left a temporary file behind: {leftovers}",
        )

        # The stem is interpolated into the scaffolded file's own docstring, so
        # a basename carrying the two characters that end a Mojo string
        # literal is the case where `new` can report success and leave behind
        # something that does not compile. Only building it settles that.
        hostile = 'test_a"""b\\.mojo'
        made = runner.run_mtest(["new", hostile])
        expect_exit(made, 0)
        hostile_run = runner.run_mtest([hostile])
        expect_exit(hostile_run, 0)
        expect(
            "1 passed" in hostile_run.stdout,
            f"a hostile basename scaffolded a file that does not run: "
            f"{hostile_run.stdout!r}{hostile_run.stderr!r}",
        )

        # `::` is the node-id separator, so a file created under it is one
        # mtest could never be pointed at again; it is refused before the
        # directory is created rather than written and then unreachable.
        colon = runner.run_mtest(["new", "colon/test_a::b.mojo"])
        expect_exit(colon, 4)
        expect(
            "contains '::'" in colon.stderr,
            f"the node-id refusal does not name its cause: {colon.stderr!r}",
        )
        expect(
            not (project / "colon").exists(),
            "the refusal created the parent directory of a file it declined to write",
        )
    return (
        "scaffold ran green (hostile basename included); a second scaffold "
        "refused and changed nothing"
    )


def s_init_bootstraps(context: ScenarioContext) -> str:
    """A bootstrapped project runs, and a second bootstrap changes nothing.

    The claim `init` makes is about a directory rather than a file, and only
    one thing settles it: run the real binary with no operands in the directory
    it just wrote. That exercises the `mtest.toml` it wrote (without it there
    are no paths to walk) and the test file it wrote (without it there is
    nothing to pass) in a single verdict.

    The second half is the never-replace promise from the other direction: an
    all-skip second run still succeeds, and `.gitignore` — the one file `init`
    rewrites rather than creates — keeps the bytes that were already in it.
    """
    with tempfile.TemporaryDirectory(prefix="mtest-init-") as raw:
        project = Path(raw)
        runner = E2ERunner(
            repo_root=project,
            mtest=context.runner.mtest,
            default_timeout=context.runner.default_timeout,
            short_timeout=context.runner.short_timeout,
        )
        mine = "build/\n"
        (project / ".gitignore").write_text(mine, encoding="utf-8")

        started = runner.run_mtest(["init", "--ci", "github"])
        expect_exit(started, 0)
        expect(
            started.stderr == "",
            f"a successful init wrote diagnostics: {started.stderr!r}",
        )
        expect(
            started.stdout.splitlines()
            == [
                "created tests/test_example.mojo",
                "created mtest.toml",
                "created .github/workflows/test.yml",
                "updated .gitignore",
                "next: pixi init .",
                "next: pixi workspace channel add https://conda.modular.com/max/",
                (
                    "next: pixi workspace channel add "
                    "https://repo.prefix.dev/modular-community"
                ),
                "next: pixi add mtest",
                "next: mtest",
                (
                    "next: commit pixi.toml and pixi.lock, which the workflow "
                    "installs from"
                ),
            ],
            f"the report is not the contract's: {started.stdout!r}",
        )

        ignored = (project / ".gitignore").read_text(encoding="utf-8")
        expect(
            ignored.startswith(mine),
            f"the .gitignore rewrite dropped what was already there: {ignored!r}",
        )
        expect(
            ignored.endswith(".mtest-cache/\n"),
            f"the build cache was not appended to .gitignore: {ignored!r}",
        )

        # No operands: the configuration `init` wrote is what has to make this
        # find the test file `init` wrote beside it.
        ran = runner.run_mtest([])
        expect_exit(ran, 0)
        expect(
            "1 passed" in ran.stdout,
            f"the bootstrapped project did not run as one passing test: "
            f"{ran.stdout!r}{ran.stderr!r}",
        )

        again = runner.run_mtest(["init", "--ci", "github"])
        expect_exit(again, 0)
        expect(
            "created " not in again.stdout,
            f"a second init created something: {again.stdout!r}",
        )
        expect(
            len([ln for ln in again.stdout.splitlines() if ln.startswith("skipped ")])
            == 4,
            f"a second init did not skip every artifact: {again.stdout!r}",
        )
        expect(
            (project / ".gitignore").read_text(encoding="utf-8") == ignored,
            "a second init rewrote a .gitignore that already had the entry",
        )

        refused = runner.run_mtest(["init", "--ci", "gitlab"])
        expect_exit(refused, 4)
        expect(
            "gitlab" in refused.stderr,
            f"the refusal does not name the value: {refused.stderr!r}",
        )

        # A directory sitting where an artifact goes is a refusal, not a skip:
        # reporting `skipped` there would claim a file exists that does not.
        with tempfile.TemporaryDirectory(prefix="mtest-init-blocked-") as other:
            blocked_root = Path(other)
            (blocked_root / "mtest.toml").mkdir()
            blocked_runner = E2ERunner(
                repo_root=blocked_root,
                mtest=context.runner.mtest,
                default_timeout=context.runner.default_timeout,
                short_timeout=context.runner.short_timeout,
            )
            blocked = blocked_runner.run_mtest(["init"])
            expect_exit(blocked, 4)
            expect(
                "mtest.toml" in blocked.stderr,
                f"the refusal does not name the blocked artifact: {blocked.stderr!r}",
            )
            expect(
                not (blocked_root / "tests").exists(),
                "a refused init created an artifact before refusing",
            )
    return "bootstrapped project ran green; a second init skipped everything"
