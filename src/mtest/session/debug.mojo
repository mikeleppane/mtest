"""The debug path: prepare one test, then let `main` become it.

Layer 4's answer to "just run this one test in front of me". It reuses the same
build-and-probe front half the selection and collect pipelines use, then stops:
it spawns no run, drives no reporter, prints nothing, and hands `main` a plan
plus a mapped exit code.

The split matters. Everything that can go wrong — a malformed node id, a file
that will not compile, a probe that crashes or drifts, a test name the file
never collected — is decided here, while mtest is still the process that exits,
and every one of those classes has a row in `_from_build` and `_from_probe`.
Once `main` execs the binary there is no mtest left: the exit status belongs to
the test, and nothing in this module or above it renders a summary or claims a
verdict over it.
"""
from mtest.cache import BuildRegistry
from mtest.config import (
    ActiveConfigKeys,
    ResolvedConfig,
    RunnerConfig,
    lossy_utf8,
    shell_join,
)
from mtest.discover import discover, DiscoveryResult
from mtest.exec import ExecRuntime, interrupt_requested
from mtest.model import (
    EXIT_INTERNAL_ERROR,
    EXIT_INTERRUPTED,
    EXIT_FAILURE,
    EventKind,
    FileFinishedPayload,
    Outcome,
    ParseDisposition,
    escape_one_line,
    split_node_token,
)
from mtest.select import FileIntent, select_from
from mtest.session.build import (
    _BuildOutcome,
    _ProbeOutcome,
    _build_for_selection,
    _probe_file,
)
from mtest.session.file_result import FileResult
from mtest.session.effective_settings import (
    _compat_resolved_config,
    effective_file_settings,
)
from mtest.session.precompile import PrecompileResult, _run_precompile
from mtest.session.store import CacheContext, finalize_includes

comptime _EXIT_USAGE_ERROR = 4
"""The pre-handoff usage refusal, decided before any test could have run.

Stated here rather than imported because it is not the model's to resolve: like
`main`'s own copy, it is decided before there are any run facts to rank.
"""


@fieldwise_init
struct DebugPlan(Copyable, Movable):
    """Everything `main` needs to hand the terminal to one test."""

    var build_line: String
    """The exact `mojo build ...` argv, shell-joined for display."""

    var run_argv: List[String]
    """The binary invocation: always `[binary, "--only", name]`.

    The selector is unconditional so the printed line, the exec, and the test
    that actually runs can never diverge."""

    var run_line: String
    """`run_argv`, shell-joined for display."""

    var binary: String
    """The root-relative binary path, taken from the build outcome.

    Never re-derived: display and exec have to name the same file, and only the
    build knows where it put it."""

    @staticmethod
    def none() -> DebugPlan:
        """The placeholder plan a nonzero outcome carries.

        Returns:
            An empty plan; meaningful only in that nothing reads it.
        """
        return DebugPlan(String(""), List[String](), String(""), String(""))


@fieldwise_init
struct DebugOutcome(Copyable, Movable):
    """`prepare_debug`'s total result: a plan, or a mapped terminal code."""

    var code: Int
    """0 when `plan` is ready, else the exit code: 1, 2, 3, or 4."""

    var diagnostics: List[String]
    """Stderr lines explaining a nonzero code; empty on success."""

    var plan: DebugPlan
    """Meaningful only when `code` is 0."""

    @staticmethod
    def refused(code: Int, var diagnostic: String) -> DebugOutcome:
        """A terminal outcome carrying one diagnostic line.

        Args:
            code: The mapped exit code.
            diagnostic: The single stderr line explaining it. Consumed.

        Returns:
            A newly allocated outcome whose plan is a placeholder.
        """
        var lines = List[String]()
        lines.append(diagnostic^)
        return DebugOutcome(code, lines^, DebugPlan.none())


comptime _OUTPUT_LINE_CAP = 100
"""How many captured lines a failing preparation may put on stderr.

A compiler banner is a few dozen lines and a crashing probe can be unbounded,
so the tail is dropped with a note rather than allowed to bury the diagnostic
that explains what happened.
"""


def _output_lines(text: String) -> List[String]:
    """Split captured child output into bounded, control-safe stderr lines.

    Args:
        text: The decoded output of a build or probe. Not mutated.

    Returns:
        Up to `_OUTPUT_LINE_CAP` escaped lines, plus one note when more were
        dropped. Empty for empty input. Allocates the returned list.
    """
    var lines = List[String]()
    if text == "":
        return lines^
    var pieces = text.split("\n")
    var total = len(pieces)
    # A trailing newline yields one empty final piece. Interior blank lines are
    # part of a compiler banner's shape and are kept.
    if total > 0 and String(pieces[total - 1]) == "":
        total -= 1
    var kept = total if total < _OUTPUT_LINE_CAP else _OUTPUT_LINE_CAP
    for i in range(kept):
        lines.append(escape_one_line(String(pieces[i])))
    if total > kept:
        lines.append(
            "debug: ... "
            + String(total - kept)
            + " further output line(s) omitted"
        )
    return lines^


def _disposition(fr: FileResult) -> ParseDisposition:
    """The parse disposition of a terminal result, or `NO_REPORT` if it has no
    verdict event.

    Args:
        fr: The terminal result to read.

    Returns:
        The recorded disposition; `NO_REPORT` for an internal-error event,
        which carries no parse at all.
    """
    if fr.event.kind != EventKind.FILE_FINISHED:
        return ParseDisposition.NO_REPORT
    return fr.event.data[FileFinishedPayload].parse_disposition


def _captured(fr: FileResult) -> List[String]:
    """The child's captured stderr, as bounded stderr diagnostic lines.

    A `run` echoes what the compiler or the binary wrote; a debug refusal has
    no reporter to echo it through, so it carries the same bytes on its own
    diagnostic channel. Without this a failed preparation says only that the
    build failed and never says why.

    Args:
        fr: The terminal result whose captured stderr to render.

    Returns:
        The bounded escaped lines, empty when nothing was captured.
    """
    if fr.event.kind != EventKind.FILE_FINISHED:
        return List[String]()
    return _output_lines(
        lossy_utf8(fr.event.data[FileFinishedPayload].captured_stderr)
    )


def _debug_phrase(fr: FileResult) -> String:
    """Name what went wrong, for every terminal class debug can reach.

    Every branch states the class it actually observed. The final one is
    deliberately loud: an outcome with no phrase is a runner defect, and
    borrowing a neighbouring class's wording would report a build killed at its
    deadline as a malformed suite.

    Args:
        fr: The terminal result to describe.

    Returns:
        The phrase, without the `debug: <path>: ` framing the caller adds.
    """
    var outcome = fr.outcome
    if outcome == Outcome.COMPILE_ERROR:
        return "the build failed to compile"
    if outcome == Outcome.COMPILE_TIMEOUT:
        return "the build was killed at --compile-timeout"
    if outcome == Outcome.CRASH:
        return "the --skip-all probe crashed"
    if outcome == Outcome.TIMEOUT:
        return "the --skip-all probe timed out"
    if fr.is_drift:
        return (
            "the --skip-all probe drifted off the pinned grammar (drift, exit"
            " 3)"
        )
    if _disposition(fr) == ParseDisposition.CAPTURE_OVERFLOW:
        return (
            "the --skip-all probe's output overflowed the capture bound and no"
            " complete report survived in the retained tail"
        )
    if outcome == Outcome.MALFORMED_SUITE:
        return "the --skip-all probe did not list its tests (malformed suite)"
    return (
        "the preparation ended on outcome "
        + String(outcome.code)
        + ", which debug has no phrase for; this is a runner defect"
    )


def _from_build(rel: String, bo: _BuildOutcome) -> DebugOutcome:
    """Map a terminal build outcome to its code and its own diagnostic.

    The two machinery classes get their own wording rather than the probe
    vocabulary: a compiler that could not be spawned has said nothing about
    the test file, and a diagnostic claiming otherwise would send a reader to
    read a report that was never produced.

    Args:
        rel: The root-relative file the build was for.
        bo: A build outcome whose `terminal` flag is set.

    Returns:
        2 for an interrupt, 3 for a spawn or machinery failure, else 1 for the
        compile-error class.
    """
    if bo.result.interrupted:
        return DebugOutcome.refused(
            EXIT_INTERRUPTED, String("debug: interrupted during the build")
        )
    if bo.result.internal_error:
        # The machinery failure said something on the child's stderr — which
        # program could not be spawned, and why. Dropping it left a bare
        # "internal build failure" nobody can act on, and under `debug` there
        # is no reporter anywhere else that would still echo those bytes.
        var machinery = List[String]()
        machinery.append(
            "debug: " + escape_one_line(rel) + ": internal build failure"
        )
        machinery += _captured(bo.result)
        return DebugOutcome(EXIT_INTERNAL_ERROR, machinery^, DebugPlan.none())
    var lines = List[String]()
    lines.append(
        "debug: " + escape_one_line(rel) + ": " + _debug_phrase(bo.result)
    )
    lines += _captured(bo.result)
    return DebugOutcome(EXIT_FAILURE, lines^, DebugPlan.none())


def _from_probe(rel: String, po: _ProbeOutcome) -> DebugOutcome:
    """Map a non-qualifying probe outcome to its code and diagnostic.

    Args:
        rel: The root-relative file that was probed.
        po: A probe outcome that did not qualify.

    Returns:
        2 for an interrupt, 3 for a spawn failure or off-grammar drift, else 1
        for the crash, timeout, capture-overflow, and malformed-suite class.
    """
    if po.interrupted:
        return DebugOutcome.refused(
            EXIT_INTERRUPTED,
            String("debug: interrupted during the --skip-all probe"),
        )
    if po.internal_error:
        return DebugOutcome.refused(
            EXIT_INTERNAL_ERROR,
            "debug: " + escape_one_line(rel) + ": internal probe failure",
        )
    var code = EXIT_INTERNAL_ERROR if po.result.is_drift else EXIT_FAILURE
    var lines = List[String]()
    lines.append(
        "debug: " + escape_one_line(rel) + ": " + _debug_phrase(po.result)
    )
    lines += _captured(po.result)
    return DebugOutcome(code, lines^, DebugPlan.none())


def prepare_debug(
    mut runtime: ExecRuntime,
    resolved: ResolvedConfig,
    root: String,
    node: String,
) raises -> DebugOutcome:
    """Build and probe the one file `node` names, and plan the handover.

    The preparation is the collect pipeline's, narrowed to a single file: the
    configured precompile steps run, the include set closes, the file is built
    under ordinary supervision, and its `--skip-all` probe learns the test
    names the file actually collects. The requested name is then validated
    against that universe, so a typo is refused here rather than discovered by
    a binary that would have run nothing.

    The cache is off for the whole preparation, deliberately: a stored artifact
    lives under a content-addressed path, and the whole point of the two
    printed lines is that a reader can rerun them, which needs the stable
    `build/bin/<mangled>` output. `retries` is forced to zero for the same
    reason a debug session exists at all — the developer wants to see the one
    attempt, not a quietly repeated one.

    Args:
        runtime: The exec runtime supervising the build and probe spawns.
        resolved: Layered global configuration and per-file override tables.
        root: The invocation root the children run in.
        node: The `PATH::TEST` node id to prepare.

    Returns:
        A ready plan with code 0, or a mapped terminal code with the stderr
        diagnostics that explain it: 4 for a malformed node id, an unknown
        path, a non-file operand, or an unknown test name; 2 for an interrupt;
        3 for drift or a machinery failure; 1 for the compile-error, crash,
        timeout, capture-overflow, and malformed-suite class.

    Raises:
        Error: Only if the build or probe machinery fails in a way it cannot
            classify, which `main` maps to the internal-error code. Every
            classified failure is folded into the returned outcome.
    """
    var split = split_node_token(node)
    if split.sep_count != 1 or split.file_part == "" or split.name_part == "":
        return DebugOutcome.refused(
            _EXIT_USAGE_ERROR,
            "debug: malformed node id '"
            + escape_one_line(node)
            + "': a node id is PATH::TEST with a single '::' (see mtest"
            " --help)",
        )
    var name = split.name_part

    # The operand IS the selection under debug: a project file's paths,
    # excludes, and gates never participate, so none of them can silently move
    # the named file out of the run set. `retries` goes to zero here so a
    # precompile step cannot quietly repeat itself either.
    var config = resolved.config.copy()
    config.paths = [node]
    config.paths_supplied = True
    if not resolved.active_keys.excludes:
        config.excludes = []
    if not resolved.active_keys.gates:
        config.gates = []
    if not resolved.active_keys.retries:
        config.retries = 0

    var disc: DiscoveryResult
    try:
        disc = discover(config, root)
    except e:
        # Every `discover:` raise is the exit-4 class: a nonexistent path, an
        # operand escaping the root, a node id naming a directory, or a file
        # type mtest cannot run.
        return DebugOutcome.refused(_EXIT_USAGE_ERROR, String(e))
    if len(disc.run_files) != 1:
        return DebugOutcome.refused(
            _EXIT_USAGE_ERROR,
            "debug: '"
            + escape_one_line(node)
            + "' did not resolve to exactly one test file",
        )
    var rel = disc.run_files[0]

    # Off for the session, not merely bypassed: a disabled context keys
    # nothing, probes nothing, publishes nothing, and builds to `build/bin`,
    # which is the path the printed lines name.
    var ctx = CacheContext.disabled("debug builds to a rerunnable path")
    var includes = config.include_paths.copy()

    # The precompile steps first, exactly as the collect pipeline runs them,
    # because a step's output directory becomes an include root for the build
    # below. The stamp seam is absent by construction: a disabled context keys
    # no step, so every configured step runs.
    for pc in config.precompiles:
        if interrupt_requested():
            return DebugOutcome.refused(
                EXIT_INTERRUPTED, "debug: interrupted before the build"
            )
        var pr: PrecompileResult
        try:
            pr = _run_precompile(
                runtime, config, root, pc.src, pc.out, includes
            )
        except e:
            # The caught error is the only account of what went wrong here:
            # `_run_precompile` raises for machinery faults that produced no
            # `PrecompileResult` to inspect, so discarding it leaves the step
            # named and the failure unexplained.
            return DebugOutcome.refused(
                EXIT_INTERNAL_ERROR,
                "debug: precompile step '"
                + escape_one_line(pc.src)
                + "' failed; nothing was handed over: "
                + escape_one_line(String(e)),
            )
        if pr.interrupted:
            return DebugOutcome.refused(
                EXIT_INTERRUPTED, "debug: interrupted during precompile"
            )
        if pr.internal_error:
            return DebugOutcome.refused(
                EXIT_INTERNAL_ERROR,
                "debug: precompile step '"
                + escape_one_line(pc.src)
                + "' could not be spawned; nothing was handed over",
            )
        if not pr.ok:
            # A step the compiler REJECTED is a PRECOMPILE-ERROR, the same
            # exit-1 class a run gives it. Only the machinery failures above
            # are exit 3; folding the two together reported an ordinary
            # compile failure as an internal mtest error.
            var failed = List[String]()
            failed.append(
                "debug: precompile step '"
                + escape_one_line(pc.src)
                + "' failed to build; nothing was handed over"
            )
            failed += _output_lines(pr.compiler_output)
            return DebugOutcome(EXIT_FAILURE, failed^, DebugPlan.none())
        includes.append(pr.out_dir)

    finalize_includes(ctx, root, includes)

    var settings = effective_file_settings(resolved, rel)
    # An `[[override]]` table can re-impose `retries` for this very file, so
    # the zero is restated on the settings the build and probe actually read.
    settings.retries = 0

    var reg = BuildRegistry()
    var bo = _build_for_selection(
        runtime, config, settings, root, rel, includes, reg, ctx
    )
    if bo.terminal:
        return _from_build(rel, bo)

    var po = _probe_file(
        runtime,
        settings,
        root,
        rel,
        bo.binary,
        bo.canonical,
        bo.build_argv,
        bo.bdur,
        reg,
    )
    if not po.qualified:
        return _from_probe(rel, po)

    # The name is validated against the universe the probe just read, with the
    # same diagnostic a run gives, so `debug` and `run` refuse a typo alike.
    var names = List[String]()
    names.append(name)
    try:
        _ = select_from(po.universe, rel, FileIntent.named(names^), String(""))
    except e:
        return DebugOutcome.refused(_EXIT_USAGE_ERROR, String(e))

    var run_argv = List[String]()
    run_argv.append(bo.binary)
    run_argv.append("--only")
    run_argv.append(name)
    return DebugOutcome(
        0,
        List[String](),
        DebugPlan(
            shell_join(bo.build_argv),
            run_argv.copy(),
            shell_join(run_argv),
            bo.binary,
        ),
    )


def prepare_debug(
    resolved: ResolvedConfig, root: String, node: String
) raises -> DebugOutcome:
    """Prepare a debug handover with a locally owned runtime.

    Args:
        resolved: Layered global configuration and per-file override tables.
        root: The invocation root the children run in.
        node: The `PATH::TEST` node id to prepare.

    Returns:
        The outcome the primary overload produces.

    Raises:
        Error: If the runtime cannot be opened or closed, or if the primary
            overload raises. A close failure during error handling is appended
            to the original message.
    """
    var runtime = ExecRuntime()
    try:
        runtime.open()
        var outcome = prepare_debug(runtime, resolved, root, node)
        runtime.close()
        return outcome^
    except error:
        var primary = String(error)
        try:
            runtime.close()
        except cleanup_error:
            raise Error(primary + "; " + String(cleanup_error))
        raise Error(primary)


def prepare_debug(
    config: RunnerConfig, root: String, node: String
) raises -> DebugOutcome:
    """Prepare a debug handover from the compatibility config.

    Args:
        config: The resolved runner configuration, with no override tables.
        root: The invocation root the children run in.
        node: The `PATH::TEST` node id to prepare.

    Returns:
        The outcome the layered overload produces.

    Raises:
        Error: As the layered overload does.

    Examples:

    ```mojo
    from mtest.config import RunnerConfig
    from mtest.session import prepare_debug

    var cfg = RunnerConfig.default()
    var outcome = prepare_debug(cfg, "/path/to/checkout", "t/test_a.mojo::t_x")
    # outcome.plan.run_argv is [binary, "--only", "t_x"] when code is 0.
    ```
    """
    var resolved = _compat_resolved_config(config)
    resolved.active_keys = ActiveConfigKeys.debug()
    return prepare_debug(resolved, root, node)
