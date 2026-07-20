"""Retry, timeout, attribution, precompile, and interrupt E2E scenarios."""

from __future__ import annotations

import inspect
import os
import shutil
import signal
import time

from scripts.e2e import main_open as main_open_check
from scripts.e2e.assertions import (
    SUMMARY_RE,
    expect,
    expect_accounting,
    expect_exit,
    summary,
    verdict_line,
    verdict_paths_in_order,
)
from scripts.e2e.runner import (
    FAKE_CRASH_MOJO,
    FAKE_RETRY_CRASH_MOJO,
    FAKE_SLOW_MOJO,
    REPO_ROOT,
    SHORT_TIMEOUT,
    ScenarioContext,
    ScenarioError,
)


RESILIENCE_MATRIX = {
    "run crash: std.os.abort target trap (SIGILL x86_64 / SIGTRAP arm64)": (
        "default-suite"
    ),
    "run crash: SIGSEGV": "retries-flaky",
    "run timeout: polite exit inside the grace": "timeout",
    "run timeout: SIGKILL escalation past the grace": "timeout-escalation",
    "compile timeout: the build step": "compile-timeout",
    "compile timeout: the precompile step": "precompile-timeout",
    "compiler crash: death by SIGNAL": "precompile-crash-retry",
    "compiler crash: crash SIGNATURE + nonzero exit": "compile-crash-signature",
    "compiler crash: a retried build's binary is the one attributed": (
        "attribution-reruns-crashed-binary"
    ),
    "precompile crash": "precompile-crash-retry",
    "promotion: a killed compile never touches OUT": "precompile-promotion",
}


RESILIENCE_SHIM_MARKERS = ("FAKE_CRASH_MOJO", "FAKE_SLOW_MOJO", "FAKE_RETRY_CRASH_MOJO")


def s_resilience_matrix(context: ScenarioContext) -> str:
    """The matrix as a WHOLE: every kill/timeout/crash class has a live scenario.

    The individual scenarios prove their own behavior; this one pins the SET, so
    a future change that quietly drops a class from the gate is caught by the
    gate. Checked both ways, mirroring `s_manifest_completeness`:

      * every class in RESILIENCE_MATRIX names a REGISTERED scenario (delete or
        rename `s_compile_timeout` and this goes red, instead of the compile
        timeout simply ceasing to be tested);
      * every registered scenario that drives a crash/slow compiler stand-in is
        named by the matrix (add a resilience scenario and you must say which
        class it serves).

    This asserts COVERAGE, never behavior — it runs no mtest of its own.
    """
    registered = {name for name, _fn in context.registry}
    classified = set(RESILIENCE_MATRIX.values())

    dangling = sorted(
        f"{cls!r} -> {scen!r}"
        for cls, scen in RESILIENCE_MATRIX.items()
        if scen not in registered
    )
    expect(
        not dangling,
        "the resilience matrix names scenarios that are not registered — a "
        f"kill/timeout/crash class lost its end-to-end proof: {dangling}",
    )

    unclassified = sorted(
        name
        for name, fn in context.registry
        if name not in classified
        and any(marker in inspect.getsource(fn) for marker in RESILIENCE_SHIM_MARKERS)
    )
    expect(
        not unclassified,
        "these scenarios drive a crash/slow compiler stand-in but no resilience "
        f"class claims them — add a RESILIENCE_MATRIX row: {unclassified}",
    )
    return (
        f"{len(RESILIENCE_MATRIX)} kill/timeout/crash classes, each covered by a "
        f"registered scenario; no unclassified resilience scenario"
    )


def s_retries_flaky(context: ScenarioContext) -> str:
    """`--retries` re-runs a crash-class failure; a late pass is FLAKY.

    The flaky fixture crashes by SIGSEGV on its first run (dropping a marker) and
    passes on a re-run (marker present). The harness OWNS the scratch dir and
    resets the marker before each run so ordering is deterministic:
      * --retries 1 -> the crashed first attempt shows a TRY line, the file is
        reported FLAKY, and the process exits 0;
      * --retries 0 -> the first crash stands as CRASH and the process exits 1.
    Structure is asserted (a TRY line and a FLAKY token are present), never the
    exact console bytes."""
    rel = "e2e/flaky/test_flaky.mojo"
    scratch = os.path.join(REPO_ROOT, "build", "e2e-scratch")
    marker = os.path.join(scratch, "flaky_marker")

    def reset() -> None:
        os.makedirs(scratch, exist_ok=True)
        if os.path.exists(marker):
            os.remove(marker)

    try:
        # --retries 1: crash then pass -> FLAKY, exit 0, with a TRY line.
        reset()
        run1 = context.runner.run_mtest([rel, "--retries", "1"], timeout=SHORT_TIMEOUT)
        expect_exit(run1, 0)
        expect(
            verdict_line(run1, "TRY", rel) is not None,
            f"--retries 1 showed no TRY line for the crashed first attempt:\n"
            f"{run1.stdout}",
        )
        expect(
            verdict_line(run1, "FLAKY", rel) is not None,
            f"--retries 1 did not report the file FLAKY:\n{run1.stdout}",
        )
        expect_accounting(run1)

        # --retries 0: the first crash stands -> CRASH, exit 1.
        reset()
        run0 = context.runner.run_mtest([rel, "--retries", "0"], timeout=SHORT_TIMEOUT)
        expect_exit(run0, 1)
        expect(
            verdict_line(run0, "CRASH", rel) is not None,
            f"--retries 0 did not report the file CRASH:\n{run0.stdout}",
        )

        # SELECTION variant: retries must NOT be inert under -k/node-id. The same
        # crash-then-pass via a keyword selection is FLAKY with a TRY line.
        reset()
        runk = context.runner.run_mtest(
            ["e2e/flaky", "-k", "flaky", "--retries", "1"],
            timeout=SHORT_TIMEOUT,
        )
        expect_exit(runk, 0)
        expect(
            verdict_line(runk, "TRY", rel) is not None,
            f"-k selection + --retries 1 showed no TRY line:\n{runk.stdout}",
        )
        expect(
            verdict_line(runk, "FLAKY", rel) is not None,
            f"-k selection + --retries 1 did not report FLAKY:\n{runk.stdout}",
        )
    finally:
        if os.path.exists(marker):
            os.remove(marker)
    return (
        "retries: default --retries 1 -> TRY + FLAKY (exit 0); --retries 0 ->"
        " CRASH (exit 1); -k selection --retries 1 -> TRY + FLAKY (exit 0)"
    )


def s_crash_attribution(context: ScenarioContext) -> str:
    """A CRASH file gets a bounded isolation post-pass that NEVER moves the verdict.

    The honesty pair, and the doctrine's core claim asserted directly:

      * the DETERMINISTIC crasher — one test always dies — is ATTRIBUTED: the
        pass names test_boom as the culprit;
      * the ORDER-DEPENDENT crasher — crashes only with its tests run together —
        is NO-REPRODUCTION: each test passes alone, so the culprit stays
        UNATTRIBUTED and is never guessed.

    Both files must produce the IDENTICAL verdict and exit code: attribution is
    secondary evidence, so a run where it succeeds and a run where it fails must
    be indistinguishable in everything a verdict is made of. That equality —
    exit 1, a CRASH verdict line, and a byte-equal summary accounting tuple — is
    asserted between the two runs, not merely against the manifest. Structure
    only; never console bytes."""
    attributed_rel = "e2e/attribution/test_deterministic_crasher.mojo"
    unattributed_rel = "e2e/attribution/test_order_dependent_crasher.mojo"

    def verdict_facts(rel: str) -> tuple:
        run = context.runner.run_mtest([rel], timeout=SHORT_TIMEOUT)
        # THE claim: the CRASH verdict and the exit code stand on their own.
        expect_exit(run, 1)
        crash_line = verdict_line(run, "CRASH", rel)
        expect(
            crash_line is not None,
            f"{rel} did not report the file CRASH:\n{run.stdout}",
        )
        summ = expect_accounting(run)
        expect(
            summ.crashed == 1,
            f"{rel}: band counted {summ.crashed} crashed files, expected 1",
        )
        # The pass announces itself before spawning anything, so a watcher of a
        # long run is never left wondering where the extra processes came from.
        expect(
            "crash-attribution-start" in run.combined,
            f"{rel}: the attribution pass never announced itself:\n{run.stdout}",
        )
        line = verdict_line(run, "ATTRIBUTION", rel)
        expect(
            line is not None,
            f"{rel}: no ATTRIBUTION line for a crashed file:\n{run.stdout}",
        )
        facts = (
            summ.passed,
            summ.failed,
            summ.skipped,
            summ.crashed,
            summ.excluded,
            summ.not_run,
        )
        return run.returncode, facts, line

    attributed_rc, attributed_facts, attributed_line = verdict_facts(attributed_rel)
    unattributed_rc, unattributed_facts, unattributed_line = verdict_facts(
        unattributed_rel
    )

    # The deterministic crasher's culprit is NAMED.
    expect(
        "ATTRIBUTED" in attributed_line and "test_boom" in attributed_line,
        f"the deterministic crasher's culprit was not attributed to test_boom: "
        f"{attributed_line!r}",
    )
    expect(
        "UNATTRIBUTED" not in attributed_line,
        f"an ATTRIBUTED line still called the culprit unknown: {attributed_line!r}",
    )

    # The order-dependent crasher's culprit is NOT guessed.
    expect(
        "NO-REPRODUCTION" in unattributed_line,
        f"the order-dependent crasher did not report NO-REPRODUCTION: "
        f"{unattributed_line!r}",
    )
    expect(
        "UNATTRIBUTED" in unattributed_line,
        f"a failed isolation search did not say the culprit is UNATTRIBUTED: "
        f"{unattributed_line!r}",
    )
    for name in ("test_corrupts_shared_state", "test_trips_over_shared_state"):
        expect(
            name not in unattributed_line,
            f"a NO-REPRODUCTION line named {name} — attribution GUESSED a "
            f"culprit it never reproduced: {unattributed_line!r}",
        )

    # THE DOCTRINE: attribution success and attribution failure leave the
    # verdict and the exit code indistinguishable.
    expect(
        attributed_rc == unattributed_rc == 1,
        f"attribution changed the exit code: attributed={attributed_rc}, "
        f"unattributed={unattributed_rc} (both must be 1)",
    )
    expect(
        attributed_facts == unattributed_facts,
        f"attribution changed the summary accounting: attributed="
        f"{attributed_facts} != unattributed={unattributed_facts}",
    )
    # The REGISTRY-listing branch. A bare path operand is not a selection, so
    # both runs above took the plain loop and the fallback probe; the branch that
    # reads the already-recorded `rel::name` listing (and strips that prefix)
    # would never execute. A strip bug there is INVISIBLE by construction: the
    # malformed names would feed `--only`, every rerun would exit nonzero but
    # UNSIGNALED, and the pass would report a falsely honest NO-REPRODUCTION on a
    # file whose culprit is plainly nameable. `-k boom` forces the selection path,
    # so the listing comes from the registry — and the culprit must still be named.
    keyword = context.runner.run_mtest(
        [attributed_rel, "-k", "boom"], timeout=SHORT_TIMEOUT
    )
    expect_exit(keyword, 1)
    expect(
        verdict_line(keyword, "CRASH", attributed_rel) is not None,
        f"-k boom did not report the file CRASH:\n{keyword.stdout}",
    )
    keyword_line = verdict_line(keyword, "ATTRIBUTION", attributed_rel)
    expect(
        keyword_line is not None,
        f"-k boom produced no ATTRIBUTION line:\n{keyword.stdout}",
    )
    expect(
        "ATTRIBUTED" in keyword_line and "test_boom" in keyword_line,
        f"the registry-recorded listing did not name the culprit (a node-id "
        f"prefix-strip bug would surface exactly here): {keyword_line!r}",
    )

    return (
        "attribution: deterministic -> ATTRIBUTED (test_boom); order-dependent "
        "-> NO-REPRODUCTION (UNATTRIBUTED); both exit 1 with identical CRASH "
        f"accounting {attributed_facts}; -k selection -> ATTRIBUTED off the "
        "registry listing"
    )


def s_attribution_reruns_the_binary_that_crashed(context: ScenarioContext) -> str:
    """Attribution reruns the binary that ACTUALLY crashed, not a reconstructed name.

    The one path where the pass could point at the WRONG thing. A crash-class
    BUILD failure is retried, and the retry rebuilds to a FRESH
    `build/bin/<mangled>.attempt-2` and then RUNS that binary — so a file whose
    rebuilt binary crashes at runtime has a CRASH verdict earned by a path the
    mangled name does not name. A runner that reconstructed `build/bin/<mangled>`
    would probe either a nonexistent file or a STALE binary from an earlier run,
    and a stale binary can yield a culprit out of code that never ran: a
    misleading ATTRIBUTED.

    The fake retry-crash toolchain fixture makes that divergence real: its
    first `build` truncates `-o` and hangs until `--compile-timeout` kills it
    (crash-class -> retried), and its second writes a working binary at the
    retry's fresh `.attempt-2` path. So `build/bin/<mangled>` exists but is
    non-runnable, and only `.attempt-2` can answer a probe. ATTRIBUTED naming
    test_boom is therefore reachable ONLY by rerunning the binary that ran."""
    rel = "e2e/attribution/test_deterministic_crasher.mojo"
    scratch = os.path.join(REPO_ROOT, "build", "e2e-scratch")
    marker = os.path.join(scratch, "retry_crash_build_marker")

    def reset() -> None:
        os.makedirs(scratch, exist_ok=True)
        if os.path.exists(marker):
            os.remove(marker)

    try:
        reset()
        run = context.runner.run_mtest(
            [
                "--mojo",
                FAKE_RETRY_CRASH_MOJO,
                rel,
                "--compile-timeout",
                "1",
                "--retries",
                "1",
            ],
            timeout=SHORT_TIMEOUT,
        )
        # The first build was killed and retried, and the rebuilt binary crashed:
        # the verdict is CRASH, exit 1 — attribution changes neither.
        expect_exit(run, 1)
        expect(
            verdict_line(run, "TRY", rel) is not None,
            f"the killed first build showed no TRY line:\n{run.stdout}",
        )
        expect(
            verdict_line(run, "CRASH", rel) is not None,
            f"the rebuilt binary's runtime crash was not reported CRASH:\n"
            f"{run.stdout}",
        )
        line = verdict_line(run, "ATTRIBUTION", rel)
        expect(
            line is not None,
            f"no ATTRIBUTION line for the retried-build crash:\n{run.stdout}",
        )
        # THE claim: only the `.attempt-2` binary can name this culprit.
        expect(
            "ATTRIBUTED" in line and "test_boom" in line,
            f"attribution did not rerun the binary that crashed — a "
            f"reconstructed build/bin/<mangled> would land exactly here "
            f"(PROBE-FAILED, or a culprit named out of a stale binary): "
            f"{line!r}",
        )
    finally:
        if os.path.exists(marker):
            os.remove(marker)
    return (
        "build-retry crash: verdict CRASH exit 1 (unchanged), and attribution "
        "named test_boom off the .attempt-2 binary that actually ran"
    )


def s_compile_timeout(context: ScenarioContext) -> str:
    """`--compile-timeout` bounds the BUILD; a blown deadline is COMPILE-TIMEOUT.

    Uses the committed slow-compiler `--mojo` stand-in
    (scripts/fixtures/toolchain/fake_slow_mojo.py), which sleeps forever on `build` but honors
    SIGTERM promptly — so this exercises the GRACEFUL half of the supervised kill
    protocol against a normal, perfectly valid fixture. The file is only slow to
    compile, never broken: that is exactly what separates COMPILE-TIMEOUT from
    COMPILE-ERROR.

      * --compile-timeout 1 -> COMPILE-TIMEOUT, the split-or-exclude hint, exit 1;
      * --compile-timeout 1 --retries 1 -> the first timed-out compile shows a TRY
        line and the compile-kill-residual warning (the rebuild ran quarantined
        against a fresh module cache), then the retry times out too and the file
        is still COMPILE-TIMEOUT at exit 1.

    Structure is asserted, never the exact console bytes."""
    rel = "e2e/suite/test_passing.mojo"

    # --compile-timeout 1: one bounded build, killed at the deadline.
    run = context.runner.run_mtest(
        ["--mojo", FAKE_SLOW_MOJO, rel, "--compile-timeout", "1"],
        timeout=SHORT_TIMEOUT,
    )
    expect_exit(run, 1)
    expect(
        verdict_line(run, "COMPILE-TIMEOUT", rel) is not None,
        f"--compile-timeout 1 did not report COMPILE-TIMEOUT:\n{run.stdout}",
    )
    expect(
        "compile timeout" in run.stdout and "split" in run.stdout,
        f"the COMPILE-TIMEOUT banner carried no split-or-exclude hint:\n{run.stdout}",
    )
    expect(
        "--compile-timeout 1" in run.stdout,
        f"the COMPILE-TIMEOUT banner's repro line never named the deadline:\n"
        f"{run.stdout}",
    )
    expect(
        verdict_line(run, "COMPILE-ERROR", rel) is None,
        f"a build WE killed was reported as a COMPILE-ERROR:\n{run.stdout}",
    )
    expect_accounting(run)

    # --retries 1: a compile-timeout is crash-class, so it retries + quarantines.
    runr = context.runner.run_mtest(
        ["--mojo", FAKE_SLOW_MOJO, rel, "--compile-timeout", "1", "--retries", "1"],
        timeout=SHORT_TIMEOUT,
    )
    expect_exit(runr, 1)
    expect(
        verdict_line(runr, "TRY", rel) is not None,
        f"--retries 1 showed no TRY line for the timed-out first compile:\n"
        f"{runr.stdout}",
    )
    expect(
        "compile-kill-residual" in runr.stdout,
        f"a killed compile fired no cache-residual warning:\n{runr.stdout}",
    )
    expect(
        "quarantin" in runr.stdout,
        f"the retried compile never mentioned the cache quarantine:\n{runr.stdout}",
    )
    expect(
        verdict_line(runr, "COMPILE-TIMEOUT", rel) is not None,
        f"a retry-exhausted compile timeout is still COMPILE-TIMEOUT:\n{runr.stdout}",
    )
    expect_accounting(runr)

    return (
        "compile-timeout: --compile-timeout 1 -> COMPILE-TIMEOUT + hint (exit 1);"
        " --retries 1 -> TRY + quarantined rebuild + COMPILE-TIMEOUT (exit 1)"
    )


def s_compile_crash_signature(context: ScenarioContext) -> str:
    """The stderr CRASH SIGNATURE — not the nonzero exit — decides a build retry.

    A compiler can crash and still exit under its own control: an ICE that prints
    the LLVM banner and returns nonzero looks, to the supervisor, exactly like a
    rejected program. Only the stderr tells them apart, so `retry_classify` scans
    it (`has_crash_signature`). This scenario is the DISCRIMINATING PAIR that
    proves the scan actually gates the decision:

      * (a) WITH the banner  -> crash-class: a TRY line, the compile-kill-residual
        warning, the quarantined rebuild — then the retry crashes the same way and
        the file lands on its deterministic COMPILE-ERROR;
      * (b) WITHOUT the banner -> deterministic: NO TRY line, NO residual warning,
        one attempt only, straight to COMPILE-ERROR.

    Both halves run the SAME shim with the SAME argv and the SAME `--retries 1`,
    and the shim exits nonzero (never by a signal) in both. The ONLY difference is
    the stderr text. A single (a)-style scenario would pass even if the runner
    retried EVERY nonzero build — i.e. even if the signature list did nothing; (b)
    is what makes that impossible. Delete the `has_crash_signature(...)` condition
    from `retry_classify` (or force it true) and (b) fails on the TRY line.

    Structure is asserted, never the exact console bytes."""
    rel = "e2e/suite/test_passing.mojo"
    argv = ["--mojo", FAKE_CRASH_MOJO, rel, "--retries", "1"]

    # (a) nonzero exit WITH the ICE banner -> crash-class -> retried.
    sig = context.runner.run_mtest(
        argv, timeout=SHORT_TIMEOUT, env_overrides={"MTEST_FAKE_BUILD_CRASH": "signature"}
    )
    expect_exit(sig, 1)
    expect(
        verdict_line(sig, "TRY", rel) is not None,
        f"a nonzero build with a crash banner was NOT retried (no TRY line) — the "
        f"crash-signature scan is not reaching the retry decision:\n{sig.stdout}",
    )
    expect(
        "compile-crash" in sig.stdout,
        f"the retried build's TRY line did not classify it compile-crash:\n{sig.stdout}",
    )
    expect(
        "compile-kill-residual" in sig.stdout and "quarantin" in sig.stdout,
        f"a crash-class build fired no quarantined-rebuild warning:\n{sig.stdout}",
    )
    expect(
        verdict_line(sig, "COMPILE-ERROR", rel) is not None,
        f"the retry-exhausted crash-class build did not land on COMPILE-ERROR:\n"
        f"{sig.stdout}",
    )
    expect_accounting(sig)

    # (b) the SAME shim, the SAME nonzero exit, ordinary stderr -> deterministic.
    plain = context.runner.run_mtest(
        argv, timeout=SHORT_TIMEOUT, env_overrides={"MTEST_FAKE_BUILD_CRASH": "plain"}
    )
    expect_exit(plain, 1)
    expect(
        verdict_line(plain, "TRY", rel) is None,
        f"an ordinary compile error was RETRIED — `--retries` must never re-run a "
        f"deterministic build failure, and only the stderr text differs from the "
        f"crash-class run:\n{plain.stdout}",
    )
    expect(
        "compile-kill-residual" not in plain.stdout,
        f"a deterministic compile error fired the cache-residual warning:\n"
        f"{plain.stdout}",
    )
    expect(
        verdict_line(plain, "COMPILE-ERROR", rel) is not None,
        f"an ordinary compile error did not report COMPILE-ERROR:\n{plain.stdout}",
    )
    expect_accounting(plain)

    return (
        "compile-crash signature: nonzero exit + ICE banner -> TRY + quarantined"
        " retry -> COMPILE-ERROR; the SAME nonzero exit with ordinary stderr ->"
        " no TRY, no warning, COMPILE-ERROR (only the stderr text differs)"
    )


def s_timeout(context: ScenarioContext) -> str:
    """The POLITE half of the escalation pair (the stubborn half is
    timeout-escalation). This fixture sleeps without disarming SIGTERM, so the
    supervisor's polite signal ends it inside the grace and NO SIGKILL is ever
    sent. The verdict must therefore name the deadline and say nothing about an
    escalation: this is the assertion that makes the escalation clause a
    CONDITIONAL fact rather than a constant, so a clause appended unconditionally
    fails HERE while the stubborn scenario stays green.
    """
    rel = "e2e/slow/test_hanging.mojo"
    run = context.runner.run_mtest([rel, "--timeout", "1"], timeout=SHORT_TIMEOUT)
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.timed_out == 1, f"expected 1 timed out, got {summ.timed_out}")
    verdict = verdict_line(run, "TIMEOUT", rel)
    expect(verdict is not None, "no TIMEOUT verdict line")
    expect(
        "timed out after 1s" in verdict,
        f"the TIMEOUT verdict did not name the deadline:\n{verdict}",
    )
    expect(
        "escalated" not in verdict and "SIGKILL" not in verdict,
        f"a child that died on the polite SIGTERM was narrated as having been"
        f" escalated to SIGKILL — the escalation clause is not conditional on the"
        f" latched Termination:\n{verdict}",
    )
    expect(run.wall < 10.0, f"mtest took {run.wall:.1f}s to honor --timeout 1")
    return (
        f"TIMEOUT verdict names the deadline and claims NO escalation (polite"
        f" SIGTERM sufficed), exit 1, returned in {run.wall:.1f}s"
    )


def s_timeout_escalation(context: ScenarioContext) -> str:
    """A child that IGNORES SIGTERM forces the supervisor's full kill protocol:
    SIGTERM -> 300ms run-step grace -> SIGKILL. The escalation is latched on the
    Termination, and BOTH places that can narrate it must:

      * --retries 0 -> no attempt is non-final, so there is no TRY line and the
        TIMEOUT VERDICT line is the only place the reader can learn the child had
        to be killed. This is the common case (`mtest --timeout N`).
      * --retries 1 -> attempt 1 is a crash-class run-timeout, so it also gets a
        TRY line, and the two must agree.

    Structure only — the wording is an informal surface, so this asserts the
    lines, the escalation clause, and the final TIMEOUT verdict, never exact
    bytes. Only SIGKILL can end this fixture; if the escalation ever regressed,
    the child would survive its deadline and the harness guard (not these
    assertions) would fire.
    """
    rel = "e2e/stubborn/test_stubborn.mojo"

    # --retries 0: the verdict line alone carries the story.
    run0 = context.runner.run_mtest([rel, "--timeout", "1", "--retries", "0"], timeout=SHORT_TIMEOUT)
    expect_exit(run0, 1)
    summ0 = expect_accounting(run0)
    expect(summ0.timed_out == 1, f"expected 1 timed out, got {summ0.timed_out}")
    expect(
        "TRY" not in run0.stdout,
        f"--retries 0 scheduled only one attempt but showed a TRY line:\n{run0.stdout}",
    )
    verdict0 = verdict_line(run0, "TIMEOUT", rel)
    expect(verdict0 is not None, f"no TIMEOUT verdict line:\n{run0.stdout}")
    expect(
        "escalated to SIGKILL" in verdict0,
        f"a SIGTERM-ignoring child's TIMEOUT verdict did not report the SIGKILL"
        f" escalation, so nothing in the run did:\n{verdict0}",
    )
    expect(
        "timed out after 1s" in verdict0,
        f"the TIMEOUT verdict did not name the deadline:\n{verdict0}",
    )

    # --retries 1: the TRY line tells the same story, and so does the verdict.
    run = context.runner.run_mtest([rel, "--timeout", "1", "--retries", "1"], timeout=SHORT_TIMEOUT)
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.timed_out == 1, f"expected 1 timed out, got {summ.timed_out}")
    try_line = verdict_line(run, "TRY", rel)
    expect(
        try_line is not None,
        f"the timed-out first attempt showed no TRY line:\n{run.stdout}",
    )
    expect(
        "escalated to SIGKILL" in try_line,
        f"a SIGTERM-ignoring child's TRY line did not report the SIGKILL"
        f" escalation:\n{try_line}",
    )
    expect(
        "timed out" in try_line,
        f"the TRY line did not name the deadline as the cause:\n{try_line}",
    )
    verdict = verdict_line(run, "TIMEOUT", rel)
    expect(verdict is not None, f"no final TIMEOUT verdict line:\n{run.stdout}")
    expect(
        "escalated to SIGKILL" in verdict,
        f"the TRY line reported the escalation but the final verdict did not:\n{verdict}",
    )
    return (
        "SIGTERM ignored -> --retries 0: TIMEOUT verdict itself reports the SIGKILL"
        f" escalation (no TRY line); --retries 1: TRY + verdict agree; exit 1, {run.wall:.1f}s"
    )


def s_precompile(context: ScenarioContext) -> str:
    rel = "e2e/pkg/test_uses_pkg.mojo"
    # Success: package precompiled, auto -I resolves the import -> PASS.
    ok = context.runner.run_mtest([rel, "--precompile", "e2e/pkg/mathlib"])
    expect_exit(ok, 0)
    expect(verdict_line(ok, "PASS", rel) is not None, "precompiled import did not PASS")
    expect(
        "COMPILE-ERROR" not in ok.stdout,
        "auto -I failed: importing test hit a COMPILE-ERROR",
    )
    # Failure: broken package -> PRECOMPILE banner, casualties, exit 1.
    bad = context.runner.run_mtest([rel, "--precompile", "e2e/pkg_broken/badlib"])
    expect_exit(bad, 1)
    expect(
        "PRECOMPILE" in bad.combined,
        "no PRECOMPILE banner on a failed precompile step",
    )
    expect(
        "could not run" in bad.combined or "casualt" in bad.combined.lower(),
        "failed precompile did not list dependent files as casualties",
    )
    bsumm = summary(bad)
    expect(bsumm.not_run >= 1, "casualty file not accounted as NOT-RUN")
    return "precompile PASS (auto -I) + broken precompile banner/casualty exit 1"


def s_precompile_timeout(context: ScenarioContext) -> str:
    """`--compile-timeout` bounds a `--precompile` step too; a blown deadline is
    a PRECOMPILE-ERROR that NAMES the timeout.

    Uses the slow-compiler stand-in (scripts/fixtures/toolchain/fake_slow_mojo.py), which sleeps
    forever on `precompile` and honors SIGTERM promptly. The package is fine; only
    the compiler is slow — so this separates "we killed it at our deadline" from
    "the compiler rejected the code", which read identically at exit 1 unless the
    banner says which one happened.

    Structure is asserted, never the exact console bytes."""
    rel = "e2e/pkg/test_uses_pkg.mojo"
    run = context.runner.run_mtest(
        [
            "--mojo",
            FAKE_SLOW_MOJO,
            rel,
            "--precompile",
            "e2e/pkg/mathlib",
            "--compile-timeout",
            "1",
        ],
        timeout=SHORT_TIMEOUT,
    )
    expect_exit(run, 1)
    expect(
        "PRECOMPILE-ERROR" in run.combined,
        f"a timed-out precompile did not report PRECOMPILE-ERROR:\n{run.stdout}",
    )
    # The ending, in words: the deadline WE enforced — never a bare exit code.
    expect(
        "timed out after 1s" in run.combined,
        f"the PRECOMPILE-ERROR banner never named the timeout:\n{run.stdout}",
    )
    # The compiler's own output rides verbatim, and the dependents are named.
    expect(
        "lowering module" in run.combined,
        f"the PRECOMPILE-ERROR banner dropped the compiler output:\n{run.stdout}",
    )
    expect(
        rel in run.combined and "could not run" in run.combined,
        f"the timed-out precompile listed no casualties:\n{run.stdout}",
    )
    expect(run.wall < 20.0, f"mtest took {run.wall:.1f}s to honor --compile-timeout 1")
    return "precompile --compile-timeout 1 -> PRECOMPILE-ERROR naming the timeout + casualties (exit 1)"


def s_precompile_crash_retry(context: ScenarioContext) -> str:
    """A crash-class precompile is retried under `--retries`, then reported.

    Uses the crashing-compiler stand-in (scripts/fixtures/toolchain/fake_crash_mojo.py), which dies
    by SIGSEGV on `precompile`. A signal death is crash-class, so:

      * --retries 0 -> one attempt, PRECOMPILE-ERROR naming the signal, exit 1;
      * --retries 1 -> a TRY line for the first attempt plus the residual warning
        (the retry ran quarantined against a fresh module cache), then the retry
        crashes too and the step is still PRECOMPILE-ERROR at exit 1.
    """
    rel = "e2e/pkg/test_uses_pkg.mojo"
    base = ["--mojo", FAKE_CRASH_MOJO, rel, "--precompile", "e2e/pkg/mathlib"]

    run = context.runner.run_mtest([*base, "--retries", "0"], timeout=SHORT_TIMEOUT)
    expect_exit(run, 1)
    expect(
        "PRECOMPILE-ERROR" in run.combined,
        f"a crashed precompile did not report PRECOMPILE-ERROR:\n{run.stdout}",
    )
    # The ending, in words: the signal that killed the compiler, named.
    expect(
        "died by signal 11 (SIGSEGV, segmentation fault)" in run.combined,
        f"the PRECOMPILE-ERROR banner never named the signal:\n{run.stdout}",
    )
    # At --retries 0 exactly one attempt runs: no TRY line, no retry warning.
    expect(
        "TRY" not in run.stdout,
        f"--retries 0 retried a precompile step:\n{run.stdout}",
    )

    runr = context.runner.run_mtest([*base, "--retries", "1"], timeout=SHORT_TIMEOUT)
    expect_exit(runr, 1)
    expect(
        verdict_line(runr, "TRY", "e2e/pkg/mathlib") is not None,
        f"--retries 1 showed no TRY line for the crashed precompile:\n{runr.stdout}",
    )
    expect(
        "precompile" in runr.stdout and "compile-crash" in runr.stdout,
        f"the precompile TRY line lost its step/classification:\n{runr.stdout}",
    )
    expect(
        "compile-kill-residual" in runr.stdout,
        f"a killed precompile fired no cache-residual warning:\n{runr.stdout}",
    )
    expect(
        "quarantin" in runr.stdout,
        f"the retried precompile never mentioned the cache quarantine:\n{runr.stdout}",
    )
    expect(
        "PRECOMPILE-ERROR" in runr.combined and "2 attempts" in runr.combined,
        f"a retry-exhausted precompile did not report both attempts:\n{runr.stdout}",
    )
    return (
        "precompile crash: --retries 0 -> PRECOMPILE-ERROR naming signal 11 (exit 1);"
        " --retries 1 -> TRY + residual warning + quarantined retry -> PRECOMPILE-ERROR"
    )


def s_precompile_promotion(context: ScenarioContext) -> str:
    """THE promotion guarantee: a failed precompile never touches OUT.

    An attempt builds to a temp path and is renamed onto OUT only after it exits
    0. So a step that is killed at the deadline, or dies by a signal, must leave a
    good package from an earlier run BYTE-IDENTICAL — and leave no temp litter in
    the OUT directory either. Both killed endings are checked against the same
    sentinel: this is the deliverable the whole change exists for.

    This scenario is DISCRIMINATING, not decorative: both shims TRUNCATE their
    `-o` path before sleeping/crashing, the way a real `mojo precompile` owns (and
    on failure deletes) its output. Point mtest at eager promotion — build to OUT
    directly — and every assertion below fails, because the shim then destroys the
    sentinel exactly as the real compiler would. The sentinel survives ONLY
    because mtest never let the compiler near OUT."""
    rel = "e2e/pkg/test_uses_pkg.mojo"
    out_dir = os.path.join(REPO_ROOT, "build", "e2e-promotion")
    out_rel = "build/e2e-promotion/mathlib.mojopkg"
    out_path = os.path.join(REPO_ROOT, out_rel)
    sentinel = b"SENTINEL-PACKAGE-BYTES\n"

    def _litter() -> list[str]:
        return sorted(
            name for name in os.listdir(out_dir) if name.endswith(".tmp")
        )

    try:
        for label, mojo_shim, extra in (
            ("killed at the deadline", FAKE_SLOW_MOJO, ["--compile-timeout", "1"]),
            ("crashed by a signal", FAKE_CRASH_MOJO, []),
        ):
            os.makedirs(out_dir, exist_ok=True)
            with open(out_path, "wb") as fh:
                fh.write(sentinel)
            run = context.runner.run_mtest(
                [
                    "--mojo",
                    mojo_shim,
                    rel,
                    "--precompile",
                    f"e2e/pkg/mathlib:{out_rel}",
                    *extra,
                ],
                timeout=SHORT_TIMEOUT,
            )
            expect_exit(run, 1)
            expect(
                "PRECOMPILE-ERROR" in run.combined,
                f"the precompile {label} did not fail the step:\n{run.stdout}",
            )
            expect(
                os.path.isfile(out_path),
                f"a precompile {label} DESTROYED the good OUT package "
                f"({out_rel} no longer exists)",
            )
            with open(out_path, "rb") as fh:
                after = fh.read()
            expect(
                after == sentinel,
                f"a precompile {label} DAMAGED the good OUT package: "
                f"{after!r} != {sentinel!r}",
            )
            expect(
                _litter() == [],
                f"a precompile {label} left temp litter in OUT: {_litter()}",
            )
    finally:
        shutil.rmtree(out_dir, ignore_errors=True)
    return (
        "promotion: a precompile killed at the deadline and one killed by SIGSEGV"
        " both left the pre-existing OUT byte-identical, with no .tmp litter"
    )


def s_internal_error(context: ScenarioContext) -> str:
    """A spawn/machinery failure must surface a diagnostic, not a silent exit 3.

    Point the runner at a nonexistent `--mojo`, so spawning `mojo build` fails
    with ENOENT before any file can be built. Assert exit 3, an INTERNAL-ERROR
    banner naming the build step, the missing program, and the errno; that NO
    false PASS/verdict line appears for the file; and that the file is accounted
    NOT-RUN in the summary."""
    rel = "e2e/suite/test_passing.mojo"
    missing = "/no/such/mojo/compiler"
    run = context.runner.run_mtest(["--mojo", missing, rel], timeout=SHORT_TIMEOUT)
    expect_exit(run, 3)
    summ = expect_accounting(run)

    expect(
        "INTERNAL-ERROR" in run.stdout,
        f"no INTERNAL-ERROR banner on a spawn failure:\n{run.stdout}",
    )
    expect(
        "build" in run.stdout,
        f"internal-error banner did not name the build step:\n{run.stdout}",
    )
    expect(
        missing in run.stdout,
        f"internal-error banner did not name the missing program:\n{run.stdout}",
    )
    expect(
        "errno" in run.stdout,
        f"internal-error banner did not report an errno:\n{run.stdout}",
    )
    # No false verdict: the file must never be reported PASS (or any verdict).
    expect(
        verdict_line(run, "PASS", rel) is None,
        f"spawn failure produced a false PASS verdict for {rel}",
    )
    expect(
        not verdict_paths_in_order(run),
        f"spawn failure produced verdict lines: {verdict_paths_in_order(run)}",
    )
    expect(
        summ.not_run >= 1,
        f"spawn-failed file not accounted NOT-RUN (not_run={summ.not_run})",
    )

    # A precompile spawn failure must name the real errno too, not a generic
    # errno 0. Point --precompile at a step whose compiler cannot be spawned: the
    # banner names the precompile step, the missing program, and ENOENT (errno 2)
    # exactly as the build path does — the errno is threaded, not dropped.
    pc = context.runner.run_mtest(
        ["--mojo", missing, rel, "--precompile", "e2e/pkg/mathlib"],
        timeout=SHORT_TIMEOUT,
    )
    expect_exit(pc, 3)
    expect(
        "INTERNAL-ERROR" in pc.stdout,
        f"no INTERNAL-ERROR banner on a precompile spawn failure:\n{pc.stdout}",
    )
    expect(
        "precompile" in pc.stdout,
        f"internal-error banner did not name the precompile step:\n{pc.stdout}",
    )
    expect(
        "errno 2" in pc.stdout,
        f"precompile spawn failure dropped the real errno (expected ENOENT):"
        f"\n{pc.stdout}",
    )
    return (
        "exit 3; build+precompile INTERNAL-ERROR banners name step/program/"
        "errno; file NOT-RUN"
    )


def s_runtime_open_failure(context: ScenarioContext) -> str:
    """The real CLI main must report and explicitly repair failed signal open."""
    try:
        return main_open_check.check_main_open_failure()
    except main_open_check.MainOpenCheckError as error:
        raise ScenarioError(str(error)) from error


def s_interrupt(context: ScenarioContext) -> str:
    """Spawn mtest against slow/ in its OWN process group, wait until it has
    clearly started (its header appears), let it enter the hang, then SIGINT the
    group. Assert exit 2, a partial summary with NOT-RUN accounting, and that the
    process group is gone (no orphan). Hard-guarded so it can never hang CI."""
    run, pgid = context.runner.run_mtest_signaled(
        ["e2e/slow"],
        signal_number=signal.SIGINT,
        delay=8.0,
        timeout=60.0,
    )
    expect(
        run.returncode == 2,
        f"expected exit 2 on interrupt, got {run.returncode}\n"
        f"{run.stdout}\n{run.stderr}",
    )
    combined = run.combined
    m = SUMMARY_RE.search(combined)
    expect(m is not None, f"no partial summary after interrupt:\n{combined}")
    not_run = int(m.group("not_run"))
    expect(not_run >= 1, f"interrupt summary showed no NOT-RUN accounting (not_run={not_run})")

    # The process group must be gone — no orphaned children.
    time.sleep(0.5)
    orphan = True
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        orphan = False
    expect(not orphan, f"process group {pgid} still alive after mtest exit (orphan)")
    return f"exit 2; partial summary with {not_run} NOT-RUN; no orphaned process group"
