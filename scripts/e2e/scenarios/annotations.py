"""GitHub annotation mode, cap, conflict, and fencing E2E scenarios."""

from __future__ import annotations

from scripts.checks.reports import annotations as annotations_check
from scripts.checks.reports import json_stream as json_stream_check
from scripts.e2e.assertions import expect, expect_exit
from scripts.e2e.runner import ScenarioContext


def _annotation_lines(stdout: str) -> list[str]:
    """mtest's OWN annotation tail: annotation lines outside every fence."""
    return annotations_check.annotation_tail_outside_fences(stdout)


def s_annotations_modes(context: ScenarioContext) -> str:
    """MODE resolution: `on` always renders the tail; `auto` follows
    GITHUB_ACTIONS; `off` never renders even under Actions.

    The tail is the node-id-sorted `::error` block then the single `::notice`,
    printed to stdout AFTER the console summary band, only when resolved-on."""
    fail = "e2e/annotations/test_many_fail.mojo"

    # `on`: the tail renders regardless of GITHUB_ACTIONS.
    run = context.runner.run_mtest([fail, "--gh-annotations", "on"])
    expect_exit(run, 1)
    tail = _annotation_lines(run.stdout)
    annotations_check.check_tail(tail)
    expect(any(a.startswith("::notice::") for a in tail), "on: no ::notice tail")
    expect(any(a.startswith("::error ") for a in tail), "on: no ::error tail")

    # `auto` OUTSIDE Actions: nothing annotation-shaped on stdout.
    run = context.runner.run_mtest(
        [fail, "--gh-annotations", "auto"],
        env_overrides={"GITHUB_ACTIONS": ""},
    )
    expect_exit(run, 1)
    expect(
        not _annotation_lines(run.stdout),
        f"auto outside Actions still emitted a tail:\n{run.stdout}",
    )

    # `auto` INSIDE Actions: the tail renders.
    run = context.runner.run_mtest(
        [fail, "--gh-annotations", "auto"],
        env_overrides={"GITHUB_ACTIONS": "true"},
    )
    expect_exit(run, 1)
    expect(
        any(a.startswith("::notice::") for a in _annotation_lines(run.stdout)),
        "auto inside Actions rendered no tail",
    )

    # `off` even INSIDE Actions: never a tail.
    run = context.runner.run_mtest(
        [fail, "--gh-annotations", "off"],
        env_overrides={"GITHUB_ACTIONS": "true"},
    )
    expect_exit(run, 1)
    expect(
        not _annotation_lines(run.stdout),
        f"off under Actions still emitted a tail:\n{run.stdout}",
    )
    return "on renders; auto follows GITHUB_ACTIONS; off never renders"


def s_annotations_caps(context: ScenarioContext) -> str:
    """The 10-error per-STEP cap: twelve failures render nine node-id-sorted
    rows plus ONE `... and 3 more errors` aggregate — never eleven lines."""
    run = context.runner.run_mtest(
        ["e2e/annotations/test_many_fail.mojo", "--gh-annotations", "on"]
    )
    expect_exit(run, 1)
    tail = _annotation_lines(run.stdout)
    annotations_check.check_tail(tail)
    errors = [a for a in tail if a.startswith("::error")]
    expect(
        len(errors) == 10,
        f"error block was not capped at 10 lines: {len(errors)}",
    )
    expect(
        any("... and 3 more errors" in a for a in errors),
        f"no cap-minus-one aggregate line:\n{chr(10).join(errors)}",
    )
    return "12 failures -> 9 rows + '... and 3 more errors' (10 lines, capped)"


def s_annotations_conflict(context: ScenarioContext) -> str:
    """The `--json -` conflict rule, BOTH endings plus the one that runs.

    `--json - --gh-annotations on` and the default `auto` beside `--json -` are
    each usage errors (exit 4) naming both fixes; only explicit `off` runs, and
    then stdout is the byte-pure stream with no annotation line."""
    # (1) explicit `on` conflicts: exit 4, message names both fixes.
    run = context.runner.run_mtest(["e2e/suite", "--json", "-", "--gh-annotations", "on"])
    expect_exit(run, 4)
    expect(
        "gh-annotations off" in run.stderr and "--json PATH" in run.stderr,
        f"the on-conflict message names neither fix:\n{run.stderr}",
    )

    # (2) the DEFAULT (auto) also conflicts with `--json -`: exit 4.
    run = context.runner.run_mtest(["e2e/suite", "--json", "-"])
    expect_exit(run, 4)
    expect(
        "gh-annotations off" in run.stderr,
        f"the auto-conflict message names no fix:\n{run.stderr}",
    )

    # (3) explicit `off` is the ONLY combination that runs beside `--json -`.
    run = context.runner.run_mtest(
        ["e2e/suite", "--json", "-", "--gh-annotations", "off"]
    )
    expect(run.returncode in (0, 1), f"off+--json - did not run: {run.returncode}")
    expect(
        not _annotation_lines(run.stdout),
        "the byte-pure stream carried an annotation line",
    )
    report = json_stream_check.parse_stream(run.stdout)
    expect(report.terminal is not None, "off+--json - lost the byte-pure stream")
    return "on/auto beside --json - -> exit 4 (both fixes named); off runs clean"


def s_annotations_fencing(context: ScenarioContext) -> str:
    """The Actions-oriented HOSTILE-CONSOLE cell.

    A child forges a `::error` and seeds a stop-commands fence with a guessed
    token. Under GITHUB_ACTIONS the echoed capture is wrapped in a collision-proof
    fence minted AFTER the child exited: the forge is SEALED (cannot land), the
    seeded token never equals the real token, every fence is terminated (the
    always-runs epilogue restores commands before mtest's own tail), and two runs
    mint DISTINCT tokens (per-run-unique). Fencing is active even when the child
    CRASHES (an error path)."""
    forger = "e2e/annotations/test_console_forger.mojo"
    seeded = "deadbeefdeadbeefdeadbeefdeadbeef"

    run = context.runner.run_mtest(
        [forger, "--gh-annotations", "on", "--show-output", "all"],
        env_overrides={"GITHUB_ACTIONS": "true"},
    )
    expect_exit(run, 1)
    # The forged command is sealed inside a fence; the seeded token is not real.
    annotations_check.check_fencing(
        run.stdout,
        forged_needle="PWNED-BY-CHILD-OUTPUT",
        seeded_token=seeded,
    )
    # mtest's OWN tail (outside the fence) is a well-formed annotation tail.
    annotations_check.check_tail(_annotation_lines(run.stdout))
    real_tokens = set(annotations_check.extract_fence_tokens(run.stdout))
    expect(real_tokens, "no terminated fence was emitted")
    expect(seeded not in real_tokens, "the real token equalled the seeded guess")

    # PER-RUN-UNIQUE: a second run mints a DIFFERENT token.
    run2 = context.runner.run_mtest(
        [forger, "--gh-annotations", "on", "--show-output", "all"],
        env_overrides={"GITHUB_ACTIONS": "true"},
    )
    tokens2 = set(annotations_check.extract_fence_tokens(run2.stdout))
    expect(
        real_tokens.isdisjoint(tokens2),
        f"fence token repeated across runs: {real_tokens & tokens2}",
    )

    # ERROR PATH: a CRASHING child under Actions still fences its capture and
    # restores commands (no unterminated fence), even though it never FAILs
    # cleanly — the always-runs epilogue guarantees the resume delimiter.
    crash = context.runner.run_mtest(
        ["e2e/suite/test_crashing.mojo", "--gh-annotations", "on", "--show-output", "all"],
        env_overrides={"GITHUB_ACTIONS": "true"},
    )
    _fences, dangling = annotations_check.scan_fences(crash.stdout)
    expect(not dangling, "a crash-path run left a fence unterminated")
    return (
        "forge sealed; seeded!=real; per-run-unique tokens; crash-path fence"
        " terminated"
    )
