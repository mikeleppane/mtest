"""Selection, collection, and build-reuse E2E scenarios."""

from __future__ import annotations

import json
import os
import shutil
import tempfile

from scripts.e2e.assertions import (
    expect,
    expect_accounting,
    expect_exit,
    verdict_line,
)
from scripts.e2e.runner import (
    E2E_ROOT,
    LOGGING_MOJO,
    PATH_MOJO,
    REPO_ROOT,
    SHORT_TIMEOUT,
    ScenarioContext,
    ScenarioError,
)


COLLECT_MATRIX_EXPECTED = [
    "e2e/matrix/test_alpha.mojo::test_alpha_one",
    "e2e/matrix/test_alpha.mojo::test_alpha_three",
    "e2e/matrix/test_alpha.mojo::test_alpha_two",
    "e2e/matrix/test_beta.mojo::test_beta_one",
    "e2e/matrix/test_beta.mojo::test_beta_two",
]


COLLECT_DIR_EXPECTED = [
    "e2e/collect/test_probe_ok.mojo::test_one",
    "e2e/collect/test_probe_ok.mojo::test_two",
]


def s_collect(context: ScenarioContext) -> str:
    """`collect` / `--collect-only`: STDOUT is byte-clean and is ONLY the sorted
    node-id listing; every diagnostic goes to STDERR; the total per-file policy
    holds (qualifying listed; compile-error/crash/timeout/malformed -> stderr +
    continue + exit-1; drift -> exit 3; nothing collectable -> exit 5).

    STDOUT purity is asserted MECHANICALLY: stdout is split into lines and the
    lines must be exactly the sorted expected node-id set — nothing else may ride
    stdout, ever."""
    # 1. Byte-purity on a clean tree: stdout is EXACTLY the sorted listing.
    run = context.runner.run_mtest(["collect", "e2e/matrix"])
    expect_exit(run, 0)
    node_ids = run.stdout.splitlines()
    expect(
        node_ids == sorted(node_ids),
        f"collect listing is not lexicographically sorted: {node_ids}",
    )
    expect(
        node_ids == COLLECT_MATRIX_EXPECTED,
        f"collect listing {node_ids} != expected {COLLECT_MATRIX_EXPECTED}",
    )
    # STDOUT ends in exactly one newline per node id and carries nothing else.
    expect(
        run.stdout == "".join(n + "\n" for n in COLLECT_MATRIX_EXPECTED),
        f"stdout is not the byte-clean listing:\n{run.stdout!r}",
    )
    expect(
        run.stderr.strip() == "",
        f"an all-qualifying collect must keep stderr empty:\n{run.stderr}",
    )

    # 2. `--collect-only` is byte-identical to the `collect` subcommand.
    co = context.runner.run_mtest(["--collect-only", "e2e/matrix"])
    expect_exit(co, 0)
    expect(
        co.stdout == run.stdout,
        "--collect-only stdout differs from the collect subcommand",
    )

    # 3. The per-file matrix: a crashing probe and a hanging probe (bounded by a
    # short --timeout) each write a diagnostic to STDERR while the good file's
    # node ids are still listed; exit-1 class. No diagnostic leaks onto STDOUT.
    mtx = context.runner.run_mtest(
        ["collect", "e2e/collect", "--timeout", "2"], timeout=SHORT_TIMEOUT
    )
    expect_exit(mtx, 1)
    mtx_ids = mtx.stdout.splitlines()
    expect(
        mtx_ids == COLLECT_DIR_EXPECTED,
        f"the good file's node ids were not listed: {mtx_ids}",
    )
    expect(
        "collect:" not in mtx.stdout,
        f"a diagnostic leaked onto STDOUT:\n{mtx.stdout!r}",
    )
    expect(
        "test_probe_crash.mojo" in mtx.stderr,
        f"the crashing probe had no STDERR diagnostic:\n{mtx.stderr}",
    )
    expect(
        "test_probe_hang.mojo" in mtx.stderr,
        f"the hanging probe had no STDERR diagnostic:\n{mtx.stderr}",
    )

    # 4. An off-grammar probe is DRIFT (exit 3); STDOUT stays empty.
    liar = context.runner.run_mtest(
        ["collect", "e2e/hostile/test_liar.mojo"], timeout=SHORT_TIMEOUT
    )
    expect_exit(liar, 3)
    expect(liar.stdout == "", f"drift left bytes on STDOUT:\n{liar.stdout!r}")
    expect(
        "drift" in liar.stderr.lower(),
        f"the off-grammar probe surfaced no drift diagnostic:\n{liar.stderr}",
    )

    # 5. A malformed suite (silent) is exit-1; STDOUT stays empty.
    silent = context.runner.run_mtest(
        ["collect", "e2e/hostile/test_silent.mojo"], timeout=SHORT_TIMEOUT
    )
    expect_exit(silent, 1)
    expect(silent.stdout == "", "a malformed probe left bytes on STDOUT")
    expect(
        "test_silent.mojo" in silent.stderr,
        f"the malformed probe had no STDERR diagnostic:\n{silent.stderr}",
    )

    # 6. Nothing collectable -> exit 5; STDOUT empty.
    tmp = tempfile.mkdtemp(
        prefix=".e2e_collect_empty_", dir=E2E_ROOT
    )
    try:
        rel = os.path.relpath(tmp, REPO_ROOT)
        empt = context.runner.run_mtest(["collect", rel], timeout=SHORT_TIMEOUT)
        expect_exit(empt, 5)
        expect(empt.stdout == "", "nothing-collectable left bytes on STDOUT")
    finally:
        os.rmdir(tmp)

    return (
        "byte-clean sorted listing; --collect-only == collect; "
        "crash/hang/malformed -> stderr + continue (exit 1); drift exit 3; "
        "empty exit 5"
    )


def s_usage_refusals(context: ScenarioContext) -> str:
    """collect is now served, so the collect-subcommand refusal is gone. The
    remaining usage refusal this build enforces is a RUN-ONLY flag combined with
    collect mode: a listing is not a run, so every served run-only flag
    (--maxfail, -x/--exitfirst, --gate, -s/--show-output) is refused with exit 4,
    while --timeout is NOT refused (it bounds the probes). Every flag in the v1
    contract is served now, so there is no availability refusal left to probe.
    (--json is now SERVED — its destination taxonomy is proven by
    s_json_destination_taxonomy, not here.)"""
    run = context.runner.run_mtest(
        ["collect", "--maxfail", "1", "e2e/matrix"], timeout=SHORT_TIMEOUT
    )
    expect_exit(run, 4)
    expect(
        "--maxfail" in run.stderr,
        f"collect+--maxfail did not name --maxfail on stderr:\n{run.stderr}",
    )
    expect(
        "run-only" in run.stderr,
        f"collect+--maxfail did not explain the run-only refusal:\n{run.stderr}",
    )
    expect(
        run.stdout == "",
        f"a usage error must print no listing to stdout, got:\n{run.stdout!r}",
    )

    gate = context.runner.run_mtest(
        ["collect", "--gate", "e2e/matrix/test_alpha.mojo", "e2e/matrix"],
        timeout=SHORT_TIMEOUT,
    )
    expect_exit(gate, 4)
    expect(
        "--gate" in gate.stderr,
        f"collect+--gate did not name --gate on stderr:\n{gate.stderr}",
    )
    expect(
        "run-only" in gate.stderr,
        f"collect+--gate did not explain the run-only refusal:\n{gate.stderr}",
    )
    expect(
        gate.stdout == "",
        f"a usage error must print no listing to stdout, got:\n{gate.stdout!r}",
    )

    show = context.runner.run_mtest(
        ["collect", "-s", "e2e/matrix"], timeout=SHORT_TIMEOUT
    )
    expect_exit(show, 4)
    expect(
        "run-only" in show.stderr,
        f"collect+-s did not explain the run-only refusal:\n{show.stderr}",
    )
    expect(
        show.stdout == "",
        f"a usage error must print no listing to stdout, got:\n{show.stdout!r}",
    )

    return (
        "run-only flags (--maxfail, --gate, -s) + collect -> exit 4 on "
        "stderr, no listing"
    )


MATRIX_ALPHA = "e2e/matrix/test_alpha.mojo"


MATRIX_BETA = "e2e/matrix/test_beta.mojo"


CHAMELEON = "e2e/chameleon/test_chameleon.mojo"


def s_selection_keyword(context: ScenarioContext) -> str:
    """`-k` narrows a file to a subset run under --only; the rest are DESELECTED.

    `-k two` selects only test_alpha_two of the three; the file runs under
    --only, PASSes, and the two unselected tests are counted DESELECTED (a
    summary count, never a listed verdict row)."""
    run = context.runner.run_mtest([MATRIX_ALPHA, "-k", "two"])
    expect_exit(run, 0)
    summ = expect_accounting(run)
    expect(
        verdict_line(run, "PASS", MATRIX_ALPHA) is not None,
        "the -k subset selection did not PASS the file",
    )
    expect(
        summ.deselected == 2,
        f"expected 2 deselected under -k two, got {summ.deselected}",
    )
    return "-k selects a subset (--only), rest DESELECTED; exit 0"


def s_selection_node_id(context: ScenarioContext) -> str:
    """A node-id operand selects exactly one test; the rest are DESELECTED."""
    run = context.runner.run_mtest([f"{MATRIX_ALPHA}::test_alpha_one"])
    expect_exit(run, 0)
    summ = expect_accounting(run)
    expect(
        verdict_line(run, "PASS", MATRIX_ALPHA) is not None,
        "the node-id selection did not PASS the file",
    )
    expect(
        summ.deselected == 2,
        f"expected 2 deselected for a single node id, got {summ.deselected}",
    )
    return "node-id operand selects one test; 2 DESELECTED; exit 0"


def s_selection_union(context: ScenarioContext) -> str:
    """A dir operand UNIONs with a node id under it: the whole tree still runs.

    `mtest e2e/matrix e2e/matrix/test_alpha.mojo::test_alpha_one`
    covers test_alpha.mojo with BOTH a plain dir operand and a node id — the
    plain operand wins (whole), so every test in both files runs and nothing is
    deselected."""
    run = context.runner.run_mtest(["e2e/matrix", f"{MATRIX_ALPHA}::test_alpha_one"])
    expect_exit(run, 0)
    summ = expect_accounting(run)
    expect(
        verdict_line(run, "PASS", MATRIX_ALPHA) is not None,
        "union run did not PASS test_alpha.mojo",
    )
    expect(
        verdict_line(run, "PASS", MATRIX_BETA) is not None,
        "union run did not PASS test_beta.mojo (the dir must keep it whole)",
    )
    expect(
        summ.deselected == 0,
        f"union kept everything, but {summ.deselected} were deselected",
    )
    return "dir + node-id union runs the whole tree; 0 DESELECTED; exit 0"


def s_selection_malformed_node_id(context: ScenarioContext) -> str:
    """More than one `::` is a MALFORMED node id -> exit 4, never 'unknown test'.
    """
    run = context.runner.run_mtest(
        [f"{MATRIX_ALPHA}::test_alpha_one::extra"], timeout=SHORT_TIMEOUT
    )
    expect_exit(run, 4)
    expect(
        "malformed node id" in run.stderr,
        f"malformed node id did not say so on stderr:\n{run.stderr}",
    )
    expect(
        "unknown test" not in run.stderr,
        f"a malformed node id must NOT be reported as 'unknown test':\n{run.stderr}",
    )
    return "malformed node id (>1 '::') -> exit 4, names it, never 'unknown test'"


def s_selection_unknown_test(context: ScenarioContext) -> str:
    """A node id naming a test the file does not collect -> exit 4 'unknown test'.
    """
    run = context.runner.run_mtest([f"{MATRIX_ALPHA}::test_does_not_exist"], timeout=SHORT_TIMEOUT)
    expect_exit(run, 4)
    expect(
        "unknown test" in run.stderr,
        f"an unknown test name did not report 'unknown test':\n{run.stderr}",
    )
    return "unknown test name (after the probe) -> exit 4"


def s_selection_empty(context: ScenarioContext) -> str:
    """A `-k` that matches nothing deselects every test -> nothing runs -> exit 5.
    """
    run = context.runner.run_mtest([MATRIX_ALPHA, "-k", "no_such_keyword_zzz"])
    expect_exit(run, 5)
    return "empty final selection (all deselected) -> exit 5"


def s_selection_chameleon(context: ScenarioContext) -> str:
    """The chameleon: recollect-once then MALFORMED-SUITE (exit-1), never exit 3.

    Selecting the ghost forces a --only run; the suite lists it under --skip-all
    but refuses it under --only, so mtest warns loudly, rebuilds + recollects,
    retries, sees the same refusal, and reports MALFORMED-SUITE."""
    run = context.runner.run_mtest([CHAMELEON, "-k", "ghost"], timeout=SHORT_TIMEOUT)
    expect_exit(run, 1)
    expect(
        verdict_line(run, "MALFORMED-SUITE", CHAMELEON) is not None,
        f"the chameleon was not reported MALFORMED-SUITE:\n{run.stdout}",
    )
    expect(
        "stale-name" in run.combined or "WARNING" in run.combined,
        f"the recover-once flow did not warn loudly:\n{run.combined}",
    )
    return "chameleon: loud recollect-once then MALFORMED-SUITE, exit 1 (not 3)"


def _mojo_log_path() -> str:
    """A fresh path for MTEST_MOJO_LOG, absent until the logging wrapper writes
    it — proves the wrapper (not some pre-existing file) produced the log."""
    fd, path = tempfile.mkstemp(prefix="mtest_mojo_log_", suffix=".tsv")
    os.close(fd)
    os.remove(path)
    return path


def _mojo_log_lines(path: str) -> list[str]:
    """The logging wrapper's recorded lines, or [] if it never wrote the file."""
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as fh:
        return [ln.rstrip("\n") for ln in fh if ln.strip()]


def _count_builds(lines: list[str], rel: str) -> int:
    """How many `build\\t<rel>\\t...` entries the wrapper logged for `rel`."""
    count = 0
    for ln in lines:
        fields = ln.split("\t")
        if len(fields) >= 2 and fields[0] == "build" and fields[1] == rel:
            count += 1
    return count


def s_single_build(context: ScenarioContext) -> str:
    """The BuildProducts registry shares ONE `mojo build` per file between the
    selection probe and the run — proved with the committed logging `--mojo`
    wrapper (scripts/fixtures/toolchain/logging_mojo.py) over a SINGLE selection-run invocation.
    Two separate `mtest` invocations would legitimately rebuild; this scenario
    never does that.

    `-k one` over the whole e2e/matrix tree matches test_alpha_one AND
    test_beta_one, so BOTH files are touched — a multi-file selection. Phase 1
    (probe every run file) builds each file once; Phase 2 (run the selected
    subset) reuses that same binary. The wrapper's log is the independent
    witness: exactly one `mojo build <file>` line per file, not two."""
    log_path = _mojo_log_path()
    try:
        run = context.runner.run_mtest(
            ["--mojo", LOGGING_MOJO, "-k", "one", "e2e/matrix"],
            env_overrides={"MTEST_MOJO_LOG": log_path},
        )
        expect_exit(run, 0)
        expect(
            os.path.exists(log_path),
            "the logging --mojo wrapper never wrote a log file",
        )
        lines = _mojo_log_lines(log_path)
        for rel in (MATRIX_ALPHA, MATRIX_BETA):
            n = _count_builds(lines, rel)
            expect(
                n == 1,
                f"expected exactly 1 'mojo build {rel}' over one selection-run "
                f"invocation (probe+run must share the build), got {n}: {lines}",
            )
        return (
            f"one invocation selects across 2 files (-k one); each built "
            f"exactly once ({len(lines)} mojo invocations logged total)"
        )
    finally:
        if os.path.exists(log_path):
            os.remove(log_path)


def s_stale_recovery_two_builds(context: ScenarioContext) -> str:
    """The chameleon's stale-name recovery rebuilds the file EXACTLY TWICE: the
    initial Phase-1 build, then the one recollect-once rebuild the recovery
    flow triggers when the suite refuses under `--only` a name it just listed
    under `--skip-all`. The run still ends MALFORMED-SUITE (exit-1 class),
    never exit 3 — the recovery is a bounded retry, not a drift."""
    log_path = _mojo_log_path()
    try:
        run = context.runner.run_mtest(
            ["--mojo", LOGGING_MOJO, CHAMELEON, "-k", "ghost"],
            env_overrides={"MTEST_MOJO_LOG": log_path},
            timeout=SHORT_TIMEOUT,
        )
        expect_exit(run, 1)
        expect(
            verdict_line(run, "MALFORMED-SUITE", CHAMELEON) is not None,
            "the chameleon was not reported MALFORMED-SUITE under the logging "
            f"wrapper:\n{run.stdout}",
        )
        lines = _mojo_log_lines(log_path)
        n = _count_builds(lines, CHAMELEON)
        expect(
            n == 2,
            f"expected exactly 2 'mojo build {CHAMELEON}' entries (initial + "
            f"one stale-name rebuild), got {n}: {lines}",
        )
        return (
            "chameleon: 2 builds logged (initial + stale-name rebuild), "
            "MALFORMED-SUITE exit 1 (not 3)"
        )
    finally:
        if os.path.exists(log_path):
            os.remove(log_path)


PRECEDENCE_FILE = "e2e/matrix/test_beta.mojo"
"""The one file every precedence case compiles: two passing tests, no fixture
arming, and a build product whose name is fixed by the path mangler."""

PRECEDENCE_BUILD_ARGV = (
    "build",
    PRECEDENCE_FILE,
    "-o",
    "build/bin/e2e_smatrix_stest_ubeta",
)
"""The exact vector mtest hands the compiler, `argv[0]` excluded.

Pinned in full because the point of the scenario is that the SELECTED wrapper
received mtest's real work: a wrapper that was merely executed — probed for a
version, say — would log a different vector, and a check that only counted log
lines could not tell the two apart."""

PRECEDENCE_SOURCES = ("flag", "env", "path")
"""The three resolution sources, in the precedence order mtest must honor. Each
names both a wrapper directory (`<root>/<source>/mojo`) and its log variable."""


def _install_precedence_wrappers(root: str) -> dict[str, str]:
    """Install one identity-logging `mojo` copy per resolution source.

    Each copy lands at `<root>/<source>/mojo`, so the file the kernel executes
    is literally named `mojo` — the PATH candidate has to be, and making all
    three identical keeps the only difference between them the directory that
    selects them.

    Args:
        root: A scratch directory this run owns.

    Returns:
        Each source name mapped to its installed wrapper's absolute path.
    """
    installed: dict[str, str] = {}
    for source in PRECEDENCE_SOURCES:
        directory = os.path.join(root, source)
        os.makedirs(directory)
        wrapper = os.path.join(directory, "mojo")
        shutil.copyfile(PATH_MOJO, wrapper)
        os.chmod(wrapper, 0o755)
        installed[source] = wrapper
    return installed


def _precedence_records(log_path: str) -> list[dict]:
    """The invocations one wrapper copy recorded, in order.

    Args:
        log_path: The copy's log, which exists only if the copy ever ran.

    Returns:
        One decoded record per invocation; empty when the copy never ran.

    Raises:
        ScenarioError: If a recorded line is not one JSON object.
    """
    if not os.path.exists(log_path):
        return []
    records: list[dict] = []
    with open(log_path, encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise ScenarioError(
                    f"wrapper log {log_path} holds a non-JSON line {line!r}: "
                    f"{error}"
                ) from None
    return records


def s_mojo_executable_precedence(context: ScenarioContext) -> str:
    """`--mojo` beats `MTEST_MOJO`, which beats a plain `mojo` on `PATH`.

    Driven through the built command, never through the config unit: three
    identical wrapper copies are installed as `<root>/flag/mojo`,
    `<root>/env/mojo` and `<root>/path/mojo`, each logging its own absolute
    identity and the exact argv it was spawned with. Every case arms all three
    logs and prepends `<root>/path` to `PATH`, so all the losing sources stay
    LIVE and would leave a record the moment mtest consulted one; which log
    comes into existence is the run's own answer.

    The three cases strip one source at a time, so each proves precedence over
    everything below it:

    1. flag + env + PATH -> only the flag log;
    2. env + PATH -> only the env log;
    3. PATH alone -> only the path log.

    Each case is run twice, once as `collect` and once as a full run, because
    resolution has to hold on the collection path as well as the run path. Both
    invocations must land on the selected wrapper with the exact build vector.

    The real compiler is resolved ONCE here, before `PATH` is touched, and
    handed to the wrappers as `MTEST_REAL_MOJO`: the PATH candidate is itself
    called `mojo`, so a wrapper that searched `PATH` for the "real" compiler
    would exec itself forever.
    """
    real_mojo = shutil.which("mojo")
    expect(
        real_mojo is not None,
        "no real `mojo` on PATH: the precedence wrappers exec the real compiler "
        "and cannot stand in for it",
    )
    with tempfile.TemporaryDirectory(prefix="mtest-mojo-precedence-") as root:
        wrappers = _install_precedence_wrappers(root)
        logs = {
            source: os.path.join(root, f"{source}.log")
            for source in PRECEDENCE_SOURCES
        }
        base_env = {
            "MTEST_REAL_MOJO": os.fspath(real_mojo),
            "PATH": os.path.join(root, "path")
            + os.pathsep
            + os.environ.get("PATH", ""),
            # Absent unless a case sets it. `run_mtest` layers overrides onto
            # this process's environment, so an ambient MTEST_MOJO would
            # otherwise silently arm case 3's losing source.
            "MTEST_MOJO": "",
        }
        for source in PRECEDENCE_SOURCES:
            base_env[f"MTEST_PATH_MOJO_LOG_{source.upper()}"] = logs[source]

        cases: tuple[tuple[str, list[str], dict[str, str]], ...] = (
            ("flag", ["--mojo", wrappers["flag"]], {"MTEST_MOJO": wrappers["env"]}),
            ("env", [], {"MTEST_MOJO": wrappers["env"]}),
            ("path", [], {}),
        )
        for expected, extra_args, extra_env in cases:
            for mode, operands in (
                ("collect", ["collect", PRECEDENCE_FILE]),
                ("run", [PRECEDENCE_FILE]),
            ):
                for log_path in logs.values():
                    if os.path.exists(log_path):
                        os.remove(log_path)
                env = {**base_env, **extra_env}
                run = context.runner.run_mtest(
                    [*operands, *extra_args],
                    timeout=240.0,
                    env_overrides=env,
                )
                expect_exit(run, 0)

                wrote = {
                    source: _precedence_records(logs[source])
                    for source in PRECEDENCE_SOURCES
                }
                losers = {
                    source: records
                    for source, records in wrote.items()
                    if source != expected and records
                }
                expect(
                    not losers,
                    f"{mode} with {expected} selected also invoked "
                    f"{sorted(losers)}: precedence did not hold\n{losers}",
                )
                records = wrote[expected]
                expect(
                    len(records) == 1,
                    f"the {expected} wrapper logged {len(records)} invocations "
                    f"for {mode}, want exactly 1: {records}",
                )
                record = records[0]
                expect(
                    record.get("wrapper") == wrappers[expected],
                    f"the {mode} build ran {record.get('wrapper')!r}, want the "
                    f"{expected} wrapper {wrappers[expected]!r}",
                )
                argv = list(record.get("argv", []))
                expect(
                    tuple(argv[1:]) == PRECEDENCE_BUILD_ARGV,
                    f"the {expected} wrapper received argv {argv[1:]} for "
                    f"{mode}, want exactly {list(PRECEDENCE_BUILD_ARGV)}",
                )
    return (
        "--mojo > MTEST_MOJO > PATH: each of collect and run invoked ONLY the "
        f"selected wrapper, with the exact vector {list(PRECEDENCE_BUILD_ARGV)}"
    )
