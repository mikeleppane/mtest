"""The pure data model behind the run report, plus its report-layer rulings.

`report_md.mojo` and `report_html.mojo` turn these plain, allocation-free
value types into Markdown/HTML fragments. Nothing here does I/O, and nothing
here decides document structure: nesting, spooling, and assembly are the
report writer's job, not this module's. Every struct is a caller-populated
snapshot — the report writer reads events and other reporters' own inputs
(`TestResult`, `Summary`) and reshapes them into these report-specific shapes,
which stay stable even if the event payloads they were built from evolve.

`outcome_label` is the report layer's own code-to-label mapping, kept apart
from the console's private verdict tokens (`console._verdict_token` and
friends) because the two surfaces are allowed to diverge in wording without
coordinating: the console optimizes for a human watching a live run, this
module for a document read later, possibly by a machine. `needs_action` is
the report layer's other shared ruling — which outcomes belong on a
document's machine index — hoisted here rather than duplicated per renderer,
since both renderers must agree on it by construction.
"""
from mtest.model import Outcome, TestResult


@fieldwise_init
struct ReportHeaderFacts(Copyable, Movable):
    """The two build-time facts a run report's header names.

    Both are supplied once, by `main`, exactly as `JsonStreamReporter` is
    handed its own `version` at construction — neither is a session fact, so
    neither belongs on `ReportFinalizeContext`.
    """

    var version: String
    """The mtest version label, the same string `main` binds into every other
    reporter's header."""
    var platform: String
    """The resolved platform label, the same source `doctor`'s platform line
    reads from."""


@fieldwise_init
struct ReportRow(Copyable, Movable):
    """One file's line in the report's summary table.

    Carries no separate flaky flag: a flaky file's row says `FLAKY` through
    `outcome_label` (`Outcome.FLAKY.code == 9`), because that mapping is
    already total over the vocabulary. The file-count for a run's flaky
    tally lives on `ReportFinalizeContext.flaky_files` instead, since that is
    a run-wide fact rather than a per-row one.
    """

    var path: String
    """The file's root-relative path."""
    var outcome_code: Int
    """The file's outcome, an `Outcome.code` value rendered through
    `outcome_label`."""
    var duration_seconds: Float64
    """The file's run-only wall-clock duration, rendered through
    `format_seconds`."""
    var passed: Int
    """How many of the file's tests passed."""
    var failed: Int
    """How many of the file's tests failed."""
    var skipped: Int
    """How many of the file's tests were skipped."""
    var attempts: Int
    """How many attempts the file's run took, 1 for a file that never
    retried."""


@fieldwise_init
struct ReportSectionInput(Copyable, Movable):
    """One file's per-file report section, before rendering.

    A superset of what a summary row carries: the per-test results, the
    captured streams, and the retry/build narrative a full-detail section
    names. `reproduce_node` is the single reproduce/debug target for the
    whole section — the file's path, or a more specific single failing
    node id when the section concerns exactly one test — so the renderer
    emits exactly one reproduce/debug pair per section rather than one per
    failing test.
    """

    var path: String
    """The file's root-relative path."""
    var root: String
    """The run root a compiler-baked `At <path>` line inside a raw FAIL
    detail is relativized against, via `normalize_detail` — the same root
    every other reporter in this run was given, so a report's backtraces
    read exactly as the console's do."""
    var outcome_code: Int
    """The file's outcome, an `Outcome.code` value rendered through
    `outcome_label`."""
    var tests: List[TestResult]
    """The file's per-test results, in report order."""
    var stdout_text: String
    """The file's captured stdout, already bounded and decoded."""
    var stderr_text: String
    """The file's captured stderr, already bounded and decoded."""
    var stdout_truncated: Bool
    """Whether `stdout_text` was cut down from a larger capture."""
    var stderr_truncated: Bool
    """Whether `stderr_text` was cut down from a larger capture."""
    var attempts: List[String]
    """One bounded one-line summary per non-final retry attempt, in order."""
    var build_line: String
    """The build command line for this file, empty when not applicable."""
    var reproduce_node: String
    """The path or node id this section's reproduce/debug lines target;
    empty renders neither line."""


@fieldwise_init
struct ReportFinalizeContext(Copyable, Movable):
    """The run-wide facts the report's header and epilogue render from.

    Gathered once, at finalize, from the same session-level facts the other
    reporters already consult (`Summary`, `TestCounts`, the exit-code
    resolver's `TerminalFacts`, `SessionStartedPayload`) — this struct is the
    report layer's own snapshot of them, not a new source of truth.
    """

    var counts: List[Int]
    """One count per outcome, indexed by `Outcome.code`, exactly
    `Outcome.COUNT` long — the same shape as `Summary.counts`."""
    var tests_passed: Int
    """The authoritative passed-test total for the whole run."""
    var tests_failed: Int
    """The authoritative failed-test total for the whole run."""
    var tests_skipped: Int
    """The authoritative skipped-test total for the whole run."""
    var flaky_files: Int
    """How many files passed only after a retry, run-wide."""
    var built_files: Int
    """How many files were admitted at a first-attempt compile."""
    var cached_files: Int
    """How many files were admitted from a build-cache hit."""
    var wall_seconds: Float64
    """The whole session's wall-clock duration, rendered through
    `format_seconds`."""
    var interrupted: Bool
    """Whether an interrupt stopped the session before it finished
    naturally."""
    var drift: Bool
    """Whether any report drifted off the pinned toolchain grammar during the
    run."""
    var workers: Int
    """The resolved worker count for the run; 1 for a sequential run."""
    var shuffle: Bool
    """Whether run-file order was randomized for this run."""
    var shuffle_seed: Int
    """The seed order was drawn from; meaningless unless `shuffle`."""
    var shard_label: String
    """The shard identity for a sharded run, such as `"2/5"`; empty when the
    run was not sharded."""


def outcome_label(code: Int) -> String:
    """Total outcome-code to label mapping for the report layer.

    Kept apart from the console's own private verdict tokens: the two
    surfaces are free to diverge in wording without coordinating. A flaky
    file's row says `FLAKY` through this same mapping
    (`Outcome.FLAKY.code == 9`), which is why `ReportRow` carries no separate
    flaky flag — the run-wide file count lives on
    `ReportFinalizeContext.flaky_files` instead.

    Args:
        code: An `Outcome.code` value; not required to be one of the known
            discriminants.

    Returns:
        The fixed label for each known discriminant, and `"OUTCOME(<code>)"`
        for anything else — `code` is a stable integer, not a closed enum the
        compiler can check exhaustively.
    """
    if code == Outcome.PASS.code:
        return String("PASS")
    if code == Outcome.FAIL.code:
        return String("FAIL")
    if code == Outcome.SKIP.code:
        return String("SKIP")
    if code == Outcome.CRASH.code:
        return String("CRASH")
    if code == Outcome.TIMEOUT.code:
        return String("TIMEOUT")
    if code == Outcome.COMPILE_ERROR.code:
        return String("COMPILE_ERROR")
    if code == Outcome.COMPILE_TIMEOUT.code:
        return String("COMPILE_TIMEOUT")
    if code == Outcome.MALFORMED_SUITE.code:
        return String("MALFORMED_SUITE")
    if code == Outcome.PRECOMPILE_ERROR.code:
        return String("PRECOMPILE_ERROR")
    if code == Outcome.FLAKY.code:
        return String("FLAKY")
    if code == Outcome.DESELECTED.code:
        return String("DESELECTED")
    if code == Outcome.EXCLUDED.code:
        return String("EXCLUDED")
    if code == Outcome.NOT_RUN.code:
        return String("NOT_RUN")
    return String("OUTCOME(") + String(code) + String(")")


def needs_action(outcome_code: Int) -> Bool:
    """Whether a row's outcome belongs on a report's machine index.

    The report layer's own definition of "needs a second look": excludes
    exactly `PASS` (nothing wrong), `SKIP` (the child suite's own choice, not
    a stop condition), `DESELECTED`, and `EXCLUDED` (both intentionally kept
    out of the run, not casualties of it). Every other outcome — `FAIL`,
    `CRASH`, `TIMEOUT`, `COMPILE_ERROR`, `COMPILE_TIMEOUT`,
    `MALFORMED_SUITE`, `PRECOMPILE_ERROR`, `FLAKY`, and `NOT_RUN` — is
    included, `FLAKY` and `NOT_RUN` among them because a flaky pass and an
    unrun file both warrant a second look even though neither fails the run.
    Shared by every report's machine index (`md_machine_index`,
    `html_machine_index`) so the ruling cannot drift between renderings.

    Args:
        outcome_code: An `Outcome.code` value; not required to be one of the
            known discriminants.

    Returns:
        `True` when the outcome belongs on the machine index.
    """
    return not (
        outcome_code == Outcome.PASS.code
        or outcome_code == Outcome.SKIP.code
        or outcome_code == Outcome.DESELECTED.code
        or outcome_code == Outcome.EXCLUDED.code
    )
