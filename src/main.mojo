"""The `mtest` binary entry point.

`main` is the only place that reads the process argv and environment, talks to
the terminal, and calls `exit`. It parses argv and resolves project config.
`doctor` runs its contained environment checks before main acquires the
invocation root or exec runtime. `new` scaffolds one test file, and `init`
bootstraps a whole project, just after the root and before any configuration is
read, because nothing in a project file can change what either one writes — and
`init` writes that project file itself. A `config show` request renders its
resolution and exits before state loading or run resources. Otherwise main loads last-run
state, constructs the exec runtime, resolves report destinations, composes
reporters into the `StandardReportCoordinator` interface the session drives,
runs the session, closes every resource, conditionally promotes the next state
file, and exits with the session's resolved code.

Several output classes bypass the event seam by design, all of them from
commands that never open a session: pre-session diagnostics go straight to
stderr; `config show` writes its resolution-only TOML directly to stdout;
doctor writes its fixed check lines directly to stdout; `new` and `init` write
their artifact lines directly to stdout and everything else to stderr;
`--collect-only` writes its frozen node-id listing — plain lines, or the
NDJSON collect stream under `--format json` — directly to stdout; and a
post-close state-write failure goes to stderr after the terminal event already
sealed the stream. Every one of them goes through `_write_direct`, so a
consumer that stops reading costs the write and nothing else, while a
destination that cannot take the bytes at all — a closed descriptor, a full
filesystem — costs the command its success code and exits 3.

The parser owns argv syntax; config owns typed conversion, layering, and state
bytes; the console resolves color from the inputs main supplies; the session
states the run's facts and `resolve_exit_code` in the model layer ranks them.
`main` owns only process-level discovery, file I/O, resource ordering, and the
dedicated pre-run usage refusal. All FFI stays below in `exec`.
`stdout_isatty()` and `stderr_isatty()` are the terminal probes, while argv,
cwd, getenv, file operations, and exit are ordinary program-level operations
via `std`.
"""
from std.os import getenv, listdir, remove, rmdir
from std.os.path import basename, dirname, exists, isdir
from std.pathlib import cwd
from std.sys import argv, exit

from mtest.cli import (
    MTEST_VERSION,
    ParseResult,
    build_flags_string,
    help_text,
    host_platform_label,
    parse_args,
    run_doctor,
    run_init,
    run_new,
    version_text,
)
from mtest.exec import (
    ExecRuntime,
    interrupt_requested,
    stderr_isatty,
    stdout_isatty,
)
from mtest.config import (
    ActiveConfigKeys,
    ConfigEnvironment,
    FileConfig,
    LastRunState,
    Provenance,
    ReportStyle,
    ResolvedConfig,
    RunnerConfig,
    StateDelta,
    TOML_SOURCE_MAX_BYTES,
    annotations_resolved_on,
    cli_only_resolution_defaults,
    encode_last_run_state,
    merge_last_run_state,
    parse_toml,
    parse_last_run_state,
    render_config_show,
    resolve_config,
    validate_resolved_config,
)
from mtest.model import (
    EXIT_INTERNAL_ERROR,
    EXIT_INTERRUPTED,
    TerminalFacts,
    resolve_exit_code,
    split_rendered_node_id,
)
from mtest.platform import (
    BoundedRegularFileRead,
    close_checked_fd,
    create_unique_temp,
    case_folded_identity,
    default_file_mode,
    destination_identity,
    directory_ignores_case,
    direct_write_failed,
    exec_replace,
    ignore_broken_pipe,
    process_id,
    read_bounded_regular_file,
    rename_path,
    set_permissions,
    write_all_bytes_fd_status,
    write_all_fd,
    write_errno_name,
)
from mtest.report import (
    REPORT_STYLE_CONCISE,
    REPORT_STYLE_FULL,
    AnnotationsReporter,
    ConsoleReporter,
    JsonStreamReporter,
    JunitReporter,
    ReportArtifact,
    ReportHeaderFacts,
    ReportWriter,
    StandardReportCoordinator,
    close_json_fd,
    collect_finished_line,
    collect_node_line,
    collect_stream_header,
    open_json_fd,
    open_junit_artifact,
    open_junit_spool,
    open_report_spool,
    resume_delimiter,
)
from mtest.session import (
    CollectResult,
    DebugOutcome,
    DebugPlan,
    SessionResult,
    prepare_debug,
    run_collect,
    run_session_with_state,
)
from mtest.session.store import clear_cache_root, ensure_cache_root


comptime _STATE_MAX_BYTES = 1024 * 1024
"""The accepted `.mtest-cache/lastrun` payload ceiling.

Matches the doctor check's ceiling so the two agree on what a usable state
file is. State is an accelerator, never a verdict input, so an oversized or
non-regular file is ignored loudly rather than treated as a failure.
"""


comptime EXIT_USAGE_ERROR = 4
"""The invocation was refused before any run existed: a usage error.

The one exit code that is not the model's to resolve, and so the one that lives
here. It is decided before there are any run outcomes or run facts to rank, and
it dominates every code a run could have produced because no run happened.
"""


def _argv_tail() -> List[String]:
    """The process argument tokens, excluding the program name (argv[0])."""
    var raw = argv()
    var tail = List[String]()
    for i in range(1, len(raw)):
        tail.append(String(raw[i]))
    return tail^


def _no_color_set() -> Bool:
    """Whether `NO_COLOR` is set to a non-empty value in the environment.

    Per the `NO_COLOR` convention any non-empty value disables color; an unset
    or empty variable does not. The console's auto color mode reads this.
    """
    return getenv("NO_COLOR", "").byte_length() > 0


def _write_direct(text: String, fd: Int) -> Bool:
    """Write `text` verbatim to `fd`; report whether the bytes were delivered.

    The one path for every byte `main` writes outside a reporter: help,
    version, the doctor lines, `new` and `init`'s artifact lines, the resolved
    configuration, both `collect` listings, the `debug` plan, the annotation
    epilogue, and every diagnostic. Ignoring `SIGPIPE` first is what keeps a
    consumer that stops reading — `mtest collect --format json | head -1` —
    from killing this process at signal 13, a status outside every documented
    exit domain (§9, §16, §27, §28, §29). Such a write reports delivered: the
    consumer chose to stop, and §9's carve-out is about exactly that.

    A raw `write(2)` rather than a `FileDescriptor`, and that is the whole
    difference between working and crashing: constructing one takes ownership
    of the descriptor, and its teardown closes a descriptor this process does
    not own and may already have lost. Against a closed `fd` that teardown
    faults, so `mtest --version >&-` died of SIGSEGV — after the command had
    done its work — for every subcommand alike.

    It reports rather than exits, and that is the whole reason it returns a
    value: only the caller knows whether these bytes were the command's
    PRODUCT or a diagnostic ABOUT one, and only the caller knows which
    resources are still owned. `_eprintln` discards the answer, so a usage
    error keeps its frozen 4 whatever stderr does with the prose; a command
    whose output IS its text escalates to 3; and a caller past
    `RunResources` routes that 3 through `close_into` so no owned scratch
    survives.

    The one place this must NOT be used is between the exec runtime's release
    and the `debug` handoff: the debuggee inherits this process's dispositions,
    and a test that dies of a genuine broken pipe has to be able to say so.

    Args:
        text: The complete bytes to write, terminator included.
        fd: The destination descriptor.

    Returns:
        True when every byte was written or a consumer departed mid-write;
        False when the destination could not take them at all, after a
        best-effort note on stderr naming the errno. Writes nothing to stderr
        when stderr is itself the descriptor that failed, so one failed write
        can never become two.
    """
    ignore_broken_pipe()
    var status = write_all_bytes_fd_status(fd, text.as_bytes())
    if not direct_write_failed(status):
        return True
    if fd != 2:
        var reason = String("made no progress")
        if status > 0:
            reason = "errno " + String(status)
            var named = write_errno_name(status)
            if named != "":
                reason += " — " + named
        var note = (
            "mtest: could not write to file descriptor "
            + String(fd)
            + " ("
            + reason
            + ")\n"
        )
        # Best-effort by construction: an unwritable stderr must not turn one
        # failed write into two, so this result is deliberately discarded.
        _ = write_all_bytes_fd_status(2, note.as_bytes())
    return False


def _eprintln(text: String):
    """Write `text` and a newline to standard error, keeping the caller's code.

    A diagnostic ABOUT an outcome, never the outcome itself. The exit code the
    caller already resolved is the machine-readable statement — a usage error's
    4 says "you typed it wrong" whether or not the prose arrived — so a stderr
    that will not take the words costs the words and nothing else. Escalation
    to 3 belongs to undelivered PRIMARY output, which goes through
    `_exit_with_output` or an explicit `close_into` instead.
    """
    _ = _write_direct(text + "\n", 2)


def _exit_with_output(text: String, fd: Int, code: Int):
    """Write one command's whole output, then exit with `code` — or 3.

    For the commands whose product IS this text and that hold no run
    resources: help, version, `doctor`, `config show`, and a successful `new`
    or `init`. A destination that could not take the bytes leaves the caller
    with nothing, so `code` is no longer an honest answer and 3 (§9's
    environment/I-O failure) replaces it. A departed consumer is not that
    case and keeps `code`.

    Args:
        text: The command's complete output, terminator included.
        fd: The destination descriptor.
        code: The code this command's own domain resolved.
    """
    if not _write_direct(text, fd):
        exit(EXIT_INTERNAL_ERROR)
    exit(code)


def _normalize_absolute(path: String) -> String:
    var components = List[String]()
    for slice in path.split("/"):
        var component = String(slice)
        if component == "" or component == ".":
            continue
        if component == "..":
            if len(components) > 0:
                _ = components.pop()
            continue
        components.append(component^)
    var normalized = String("/")
    for i in range(len(components)):
        if i > 0:
            normalized += "/"
        normalized += components[i]
    return normalized


def _absolute_from_root(root: String, path: String) -> String:
    if path.startswith("/"):
        return _normalize_absolute(path)
    return _normalize_absolute(root + "/" + path)


def _config_file_representation(root: String, absolute: String) -> String:
    var normalized_root = _normalize_absolute(root)
    var prefix = "/" if normalized_root == "/" else normalized_root + "/"
    if absolute.startswith(prefix):
        return String(absolute[byte = prefix.byte_length() :])
    return absolute


def _safe_path_label(path: String) -> String:
    var escaped = String("")
    comptime HEX = "0123456789abcdef"
    for cp in path.codepoints():
        var value = Int(cp)
        if value == 10:
            escaped += "\\n"
        elif value == 13:
            escaped += "\\r"
        elif value == 9:
            escaped += "\\t"
        elif value >= 0 and value < 32:
            escaped += "\\x"
            escaped += String(HEX[byte=value // 16])
            escaped += String(HEX[byte=value % 16])
        else:
            escaped += String(cp)
    if escaped.count_codepoints() <= 240:
        return escaped
    var shortened = String("")
    var count = 0
    for cp in escaped.codepoint_slices():
        if count == 237:
            break
        shortened += String(cp)
        count += 1
    return shortened + "..."


def _origin_label(
    resolved: ResolvedConfig, source: Provenance, table: String, key: String
) -> String:
    """Name a resolved value the way its own layer spells it.

    A diagnostic that says `cli: '--json'` for a value the project file set
    names a remedy the reader cannot apply: there is no such flag on their
    command line. Key off the provenance the resolver already tracked.

    Args:
        resolved: The layered configuration carrying provenance and the file.
        source: The winning layer for this key.
        table: The `mtest.toml` table holding the key.
        key: The `mtest.toml` spelling of the key.

    Returns:
        A complete diagnostic prefix ending in the offending value's name.
    """
    var origin = resolved.config_file
    if origin == "":
        origin = String("mtest.toml")
    if source == Provenance.MTEST_TOML:
        return "config: " + origin + ": [" + table + "] " + key
    return "cli: '--" + key + "'"


def _resolved_destination_error(
    resolved: ResolvedConfig,
) -> Optional[String]:
    """Refuse an active destination whose parent directory does not exist.

    Every active file destination is checked, not only the ones a flag can
    spell. `--report FORMAT:PATH` is validated as the parser reads it, so a
    command-line value with a missing parent never reaches here — but a
    `[report]` destination that came from the project file has no parser of its
    own, and without a branch here it would sail past resolved validation into
    the session's temp creation and surface as an internal error, exit 3, where
    §15.5 and §24.4 both promise a pre-run usage error, exit 4. Its two sibling
    keys in the same table already give 4, so the gap was also an inconsistency
    between two halves of one feature.

    Args:
        resolved: The layered configuration, after the command projection was
            applied. Not mutated.

    Returns:
        A complete usage diagnostic naming the offending value the way its own
        layer spells it, or none when every active destination can be created.
    """
    if (
        resolved.active_keys.json_dest
        and resolved.config.json_dest != ""
        and resolved.config.json_dest != "-"
    ):
        var parent = String(dirname(resolved.config.json_dest))
        if parent != "" and not isdir(parent):
            return Optional[String](
                _origin_label(
                    resolved, resolved.provenance.json_dest, "report", "json"
                )
                + " destination parent directory does not exist: '"
                + _safe_path_label(parent)
                + "' (see mtest --help)"
            )
    if resolved.active_keys.junit_dest and resolved.config.junit_dest != "":
        var parent = String(dirname(resolved.config.junit_dest))
        if parent != "" and not isdir(parent):
            return Optional[String](
                _origin_label(
                    resolved,
                    resolved.provenance.junit_dest,
                    "report",
                    "junit-xml",
                )
                + " destination parent directory does not exist: '"
                + _safe_path_label(parent)
                + "' (see mtest --help)"
            )
    if (
        resolved.active_keys.report_md_dest
        and resolved.config.report_md_dest != ""
    ):
        var parent = String(dirname(resolved.config.report_md_dest))
        if parent != "" and not isdir(parent):
            return Optional[String](
                _report_origin_label(
                    resolved, resolved.provenance.report_md_dest, "md"
                )
                + " destination parent directory does not exist: '"
                + _safe_path_label(parent)
                + "' (see mtest --help)"
            )
    if (
        resolved.active_keys.report_html_dest
        and resolved.config.report_html_dest != ""
    ):
        var parent = String(dirname(resolved.config.report_html_dest))
        if parent != "" and not isdir(parent):
            return Optional[String](
                _report_origin_label(
                    resolved, resolved.provenance.report_html_dest, "html"
                )
                + " destination parent directory does not exist: '"
                + _safe_path_label(parent)
                + "' (see mtest --help)"
            )
    return Optional[String](None)


@fieldwise_init
struct _Destination(Copyable, Movable):
    """One active file destination, ready to be compared against its siblings.
    """

    var label: String
    """The destination named the way its own layer spells it."""
    var key: String
    """The `destination_identity` key two spellings of one file share."""
    var alias_key: String
    """The folded key a case-ignoring volume ALSO makes two spellings share.

    Empty when this destination's own directory distinguishes case, which is
    what keeps `Run.out` and `run.out` the two different files they are on
    Linux while catching them as one on APFS. Compared only against another
    non-empty `alias_key`, never against `key`.
    """


@fieldwise_init
struct _CaseVerdicts(Movable):
    """One case-sensitivity answer per resolved directory, asked once each.

    The probe creates and unlinks a file, so asking it once per DESTINATION
    would touch a caller's output directory up to four times to learn one thing
    about it. Two destinations resolving into one directory also have to be
    given the same answer, which a cache makes structural rather than
    incidental.
    """

    var parents: List[String]
    """The resolved parent directories already probed, in arrival order."""
    var ignores_case: List[Bool]
    """Parallel to `parents`: what the probe answered for each."""

    @staticmethod
    def empty() -> Self:
        """A cache that has probed nothing yet."""
        return Self(List[String](), List[Bool]())

    def ask(mut self, parent: String) -> Bool:
        """The verdict for `parent`, probing the filesystem at most once."""
        for i in range(len(self.parents)):
            if self.parents[i] == parent:
                return self.ignores_case[i]
        var verdict = directory_ignores_case(parent)
        self.parents.append(parent)
        self.ignores_case.append(verdict)
        return verdict


def _active_destinations(resolved: ResolvedConfig) -> List[_Destination]:
    """Every active destination this run will open, keyed for comparison.

    `--json -` is deliberately absent: it names the inherited stdout stream,
    which has no filesystem identity to collide with. Every other configured
    destination is a real path that will be created or renamed onto, so two of
    them naming one file is a request the runner cannot honor.

    Every folded key starts empty. Filling one asks the filesystem a question,
    which `_destination_collision_error` only does when there are at least two
    destinations for the answer to decide anything between.

    Args:
        resolved: The layered configuration, after the command projection was
            applied. Not mutated.

    Returns:
        A freshly allocated list in a fixed order, so the diagnostic for one
        collision is the same whichever run produced it.
    """
    var destinations = List[_Destination]()
    if (
        resolved.active_keys.json_dest
        and resolved.config.json_dest != ""
        and resolved.config.json_dest != "-"
    ):
        destinations.append(
            _Destination(
                _origin_label(
                    resolved, resolved.provenance.json_dest, "report", "json"
                ),
                destination_identity(resolved.config.json_dest),
                "",
            )
        )
    if resolved.active_keys.junit_dest and resolved.config.junit_dest != "":
        destinations.append(
            _Destination(
                _origin_label(
                    resolved,
                    resolved.provenance.junit_dest,
                    "report",
                    "junit-xml",
                ),
                destination_identity(resolved.config.junit_dest),
                "",
            )
        )
    if (
        resolved.active_keys.report_md_dest
        and resolved.config.report_md_dest != ""
    ):
        destinations.append(
            _Destination(
                _report_origin_label(
                    resolved, resolved.provenance.report_md_dest, "md"
                ),
                destination_identity(resolved.config.report_md_dest),
                "",
            )
        )
    if (
        resolved.active_keys.report_html_dest
        and resolved.config.report_html_dest != ""
    ):
        destinations.append(
            _Destination(
                _report_origin_label(
                    resolved, resolved.provenance.report_html_dest, "html"
                ),
                destination_identity(resolved.config.report_html_dest),
                "",
            )
        )
    return destinations^


def _report_origin_label(
    resolved: ResolvedConfig, source: Provenance, format: String
) -> String:
    """Name a resolved run-report destination the way its own layer spells it.

    `_origin_label` cannot serve here: the CLI spelling of `[report] md` is
    `--report md:`, not `--md`.

    Args:
        resolved: The layered configuration carrying provenance and the file.
        source: The winning layer for this destination.
        format: The `md` or `html` half, which is both the file key and part of
            the flag spelling.

    Returns:
        A complete diagnostic prefix ending in the offending value's name.
    """
    if source == Provenance.MTEST_TOML:
        var origin = resolved.config_file
        if origin == "":
            origin = String("mtest.toml")
        return "config: " + origin + ": [report] " + format
    return "cli: '--report " + format + ":'"


def _destination_collision_error(
    resolved: ResolvedConfig,
) -> Optional[String]:
    """Refuse two active destinations that name one file.

    Two reporters writing one path is not a composition: each one truncates or
    renames over the other's work, and which of them survives depends on
    finalization order rather than on anything the caller asked for. The
    comparison is by resolved identity rather than by spelling, so `out.md` and
    `./out.md` are caught as the one file they are.

    Identity alone is not enough where the volume ignores case. `Run.out` and
    `run.out` are two files on Linux and one file on APFS — the default on a
    supported platform — so a spelling-only comparison would let that pair
    through, publish both documents onto one inode, and exit 0 with one
    requested artifact missing. Where a destination's own directory was
    observed to fold case, its folded key is compared too; where it was not,
    the folded key is empty and nothing extra can match.

    Run-path only. `config show` resolves without touching the filesystem and
    renders a collision with both provenances instead (§27.1), so the two
    commands are deliberately different here.

    Args:
        resolved: The layered configuration, after the command projection was
            applied. Not mutated.

    Returns:
        A complete usage diagnostic naming both offending values, or none.
    """
    var destinations = _active_destinations(resolved)
    if len(destinations) < 2:
        return Optional[String](None)
    # Asked here rather than while the list is built: one destination can
    # collide with nothing, so a run with a single `--junit-xml` never touches
    # its output directory to learn something it cannot use.
    var verdicts = _CaseVerdicts.empty()
    for i in range(len(destinations)):
        if verdicts.ask(String(dirname(destinations[i].key))):
            destinations[i].alias_key = case_folded_identity(
                destinations[i].key
            )
    for i in range(len(destinations)):
        for j in range(i + 1, len(destinations)):
            var same_key = destinations[i].key == destinations[j].key
            var same_folded = (
                destinations[i].alias_key != ""
                and destinations[i].alias_key == destinations[j].alias_key
            )
            if same_key or same_folded:
                return Optional[String](
                    destinations[i].label
                    + " and "
                    + destinations[j].label
                    + " name the same destination '"
                    + _safe_path_label(destinations[j].key)
                    + "'; each report needs its own path"
                    + " (see mtest --help)"
                )
    return Optional[String](None)


def _report_temp_template(destination: String) -> String:
    """The `mkstemp` template for one report destination's unique temp.

    Placed in the destination's OWN directory, not in the spool: creating it
    there is what proves the target directory writable before any build or run,
    and it is also what lets the finished document be published by an atomic
    rename, which only works within one filesystem.

    Args:
        destination: The resolved report path the temp will be renamed onto.

    Returns:
        A template ending in the six `X` bytes `create_unique_temp` requires.
    """
    var target_dir = String(dirname(destination))
    var leaf = (
        "."
        + String(basename(destination))
        + ".mtest-"
        + String(process_id())
        + ".XXXXXX"
    )
    if target_dir == "":
        return leaf^
    return target_dir + "/" + leaf


def _relax_report_temp_mode(temp_path: String):
    """Give one report temp the mode the published report must appear with.

    `create_unique_temp` is `mkstemp(3)`, so the file arrives `0600`: right for
    a temporary, wrong for a report a CI job, a reviewer, or a web server is
    meant to read. `--junit-xml`'s artifact is created through an ordinary
    `open` and lands at the usual `0666 & ~umask`, so a report written beside it
    would otherwise be the one artifact nobody but the runner's own user could
    read.

    Set BEFORE publication, not after: the rename makes the temp's inode the
    published file, so the mode chosen here is the mode the report appears with
    and there is no window in which it is owner-readable only.

    Best-effort and non-raising by design. A mode this could not relax still
    leaves a complete, correct report at the destination, so refusing the whole
    run over it would trade a readable report for no report at all.

    Args:
        temp_path: The just-created unique temp that will be renamed onto the
            report destination.
    """
    try:
        set_permissions(temp_path, default_file_mode())
    except:
        pass


def _report_style_code(style: ReportStyle) -> Int:
    """Translate the config vocabulary into the report layer's own constant.

    Two vocabularies rather than one because the layers may not share a type:
    `config` sits below `report`, so neither can name the other's spelling of
    this choice, and `main` is the composition root that owns the translation.

    Args:
        style: The resolved `--report-style` value.

    Returns:
        `REPORT_STYLE_FULL` or `REPORT_STYLE_CONCISE`.
    """
    if style == ReportStyle.FULL:
        return REPORT_STYLE_FULL
    return REPORT_STYLE_CONCISE


@fieldwise_init
struct ConfigLoad(Copyable, Movable):
    """One root-time configuration discovery and parse result."""

    var file: FileConfig
    """The typed file layer, empty when no file was selected or parsing failed."""

    var config_file: String
    """The stream representation of the selected file, or empty when absent."""

    var error: String
    """The contained diagnostic, or empty on success."""

    var error_code: Int
    """The diagnostic exit code, or zero on success."""


def _load_config(
    root: String, explicit_path: String, no_config: Bool
) -> ConfigLoad:
    if no_config:
        return ConfigLoad(FileConfig.empty(), "", "", 0)

    var explicit = explicit_path != ""
    var requested = explicit_path if explicit else "mtest.toml"
    var absolute = _absolute_from_root(root, requested)
    var representation = _config_file_representation(root, absolute)
    var diagnostic_representation = _safe_path_label(representation)
    var selected_exists = exists(absolute)
    if not selected_exists:
        if explicit:
            return ConfigLoad(
                FileConfig.empty(),
                representation,
                "config: "
                + diagnostic_representation
                + ": configuration file does not exist",
                EXIT_USAGE_ERROR,
            )
        return ConfigLoad(FileConfig.empty(), "", "", 0)

    var opened: BoundedRegularFileRead
    try:
        opened = read_bounded_regular_file(absolute, TOML_SOURCE_MAX_BYTES)
    except:
        return ConfigLoad(
            FileConfig.empty(),
            representation,
            "config: "
            + diagnostic_representation
            + ": could not read configuration file",
            EXIT_USAGE_ERROR,
        )
    if not opened.is_regular:
        return ConfigLoad(
            FileConfig.empty(),
            representation,
            "config: "
            + diagnostic_representation
            + ": configuration path is not a regular file",
            EXIT_USAGE_ERROR,
        )
    var text = opened.text.copy()
    if text.byte_length() > TOML_SOURCE_MAX_BYTES:
        return ConfigLoad(
            FileConfig.empty(),
            representation,
            "config: "
            + diagnostic_representation
            + ": configuration file exceeds "
            + String(TOML_SOURCE_MAX_BYTES)
            + "-byte limit",
            EXIT_USAGE_ERROR,
        )

    var parsed = parse_toml(text, diagnostic_representation)
    if not parsed.is_ok:
        return ConfigLoad(
            FileConfig.empty(),
            representation,
            parsed.failure.render(),
            parsed.failure.exit_code(),
        )
    return ConfigLoad(parsed.config.copy(), representation, "", 0)


@fieldwise_init
struct StateLoad(Copyable, Movable):
    """The previous last-run records plus contained nonfatal read diagnostics.
    """

    var state: LastRunState
    """The accepted previous records, empty when absent or wholly malformed."""

    var warnings: List[String]
    """One physical-line diagnostic per malformed or unreadable input fact."""


def _state_path(root: String) -> String:
    return root + "/.mtest-cache/lastrun"


def _load_state(root: String) -> StateLoad:
    var path = _state_path(root)
    var state_exists = exists(path)
    if not state_exists:
        return StateLoad(LastRunState.empty(), [])
    var opened: BoundedRegularFileRead
    try:
        opened = read_bounded_regular_file(path, _STATE_MAX_BYTES)
    except:
        return StateLoad(
            LastRunState.empty(),
            ["state: .mtest-cache/lastrun: could not read state file"],
        )
    if not opened.is_regular:
        return StateLoad(
            LastRunState.empty(),
            ["state: .mtest-cache/lastrun: not a regular file — ignored"],
        )
    var text = opened.text.copy()
    if text.byte_length() > _STATE_MAX_BYTES:
        return StateLoad(
            LastRunState.empty(),
            ["state: .mtest-cache/lastrun: exceeds the size limit — ignored"],
        )
    var parsed = parse_last_run_state(text, ".mtest-cache/lastrun")
    var warnings = List[String]()
    for diagnostic in parsed.diagnostics:
        warnings.append(diagnostic.render())
    return StateLoad(parsed.state.copy(), warnings^)


def _persist_state(root: String, text: String) -> Optional[String]:
    var target = _state_path(root)
    var template = target + ".tmp." + String(process_id()) + ".XXXXXX"
    var temp = String("")
    var owned_fd = -1
    try:
        # Not a bare `makedirs`: `.mtest-cache` is the directory `--cache-clear`
        # deletes, and it will only delete one carrying mtest's ownership
        # marker. State is written whether or not the cache is enabled, so this
        # is a path that can create the directory on its own — and a directory
        # created without the marker is one mtest could not later prove is its.
        ensure_cache_root(root)
        var created = create_unique_temp(template)
        temp = created.path.copy()
        owned_fd = created.fd
        write_all_fd(owned_fd, text)
        # `close(2)` may release the descriptor even when it reports an error;
        # transfer it out of cleanup ownership before the one checked close.
        var closing_fd = owned_fd
        owned_fd = -1
        close_checked_fd(closing_fd)
        rename_path(temp, target)
        return Optional[String](None)
    except:
        if owned_fd >= 0:
            var closing_fd = owned_fd
            try:
                close_checked_fd(closing_fd)
            except:
                pass
        if temp != "":
            try:
                remove(temp)
            except:
                pass
        return Optional[String](
            "mtest: state: could not persist .mtest-cache/lastrun"
        )


@fieldwise_init
struct RunResources:
    """Everything a configured run owns, and the one ladder that releases it.

    `main` takes these resources at four different points: the exec runtime
    first, then the machine-stream descriptor, then the JUnit scratch, then the
    run-report scratch. Every
    exit path from there on has to release all of them, in one order, under one
    precedence. Holding them together is what lets `close_into` state that
    ladder once instead of once per exit path.

    A resource is recorded here at the moment ownership is actually taken, so
    an empty path or a false ownership flag means there is nothing to release.
    """

    var runtime: ExecRuntime
    """The process-global exec and signal state, owned from a successful open."""

    var json_fd: Int
    """The machine-stream descriptor; meaningful only when `json_owns_fd`."""

    var json_owns_fd: Bool
    """Whether `main` opened `json_fd` and so must close it.

    False under `--json -`, where the stream writes to the inherited stdout
    that `main` never opened and must not close.
    """

    var junit_spool: String
    """The JUnit spool directory `main` created, or "" when it owns none."""

    var junit_temp: String
    """The JUnit target temp file `main` created, or "" when it owns none."""

    var report_spool: String
    """The run-report spool directory `main` created, or "" when it owns none.
    """

    var report_md_temp: String
    """The Markdown report's target temp file, or "" when it owns none."""

    var report_md_fd: Int
    """The Markdown report temp's open descriptor, `-1` when the sink is off.

    Recorded for the record's sake, never closed here. The descriptor is LENT
    to `ReportWriter`, whose `finalize_reports` performs the one close; an abort
    path that skips finalize therefore leaks it into `exit()`, exactly as the
    JUnit scratch path does today. Closing it here would be the second close of
    a descriptor number the kernel may already have handed to something else.
    """

    var report_html_temp: String
    """The HTML report's target temp file, or "" when it owns none."""

    var report_html_fd: Int
    """The HTML report temp's open descriptor, `-1` when the sink is off.

    Borrowed on exactly the terms `report_md_fd` documents.
    """

    def _discard_report_scratch(self):
        """Remove the run-report spool, its fragments, and any leftover temps.

        `main` owns this scratch: it created the spool with `open_report_spool`
        and one temp per active format with `create_unique_temp`, so it frees
        them once the session has finished with them. On success a temp has
        already been renamed onto its report target, so its removal is a no-op
        that never touches the published report; on failure the writer left it
        behind deliberately, and the prior report at the target is what survives.

        The descriptors are NOT closed here — see `report_md_fd`.

        Best-effort and non-raising, so it is safe on every error path and with
        empty or missing paths.
        """
        if self.report_md_temp != "":
            try:
                remove(self.report_md_temp)
            except:
                pass
        if self.report_html_temp != "":
            try:
                remove(self.report_html_temp)
            except:
                pass
        if self.report_spool != "":
            try:
                for name in listdir(self.report_spool):
                    try:
                        remove(self.report_spool + "/" + name)
                    except:
                        pass
                rmdir(self.report_spool)
            except:
                pass

    def _discard_junit_scratch(self):
        """Remove the JUnit spool directory, its fragments, and any leftover temp.

        `main` owns this scratch: it created the spool with `open_junit_spool`
        and the temp with `open_junit_artifact`, so it frees them once the
        session has finished with them. On success the temp has already been
        renamed onto the report target, so its removal is a no-op that never
        touches the published report; on failure the reporter discarded it.
        Either way the fragments and the spool directory are what is left.

        Best-effort and non-raising, so it is safe on every error path and with
        empty or missing paths.
        """
        if self.junit_temp != "":
            try:
                remove(self.junit_temp)
            except:
                pass
        if self.junit_spool != "":
            try:
                for name in listdir(self.junit_spool):
                    try:
                        remove(self.junit_spool + "/" + name)
                    except:
                        pass
                rmdir(self.junit_spool)
            except:
                pass

    def close_into(mut self, code: Int, rank_delivery: Bool) -> Int:
        """Release every owned resource and return the code to exit with.

        The ladder, stated once: discard the JUnit scratch, discard the
        run-report scratch, close the machine-stream descriptor when `main`
        owns it, then restore the exec runtime. The precedence over `code` follows from what each release can
        observe. A descriptor close can surface a deferred write error (a quota
        or network filesystem that reports ENOSPC/EIO only at close), which is
        a delivery fact this presents to `resolve_exit_code` rather than a code
        it transforms itself. A runtime close failure is the runner's own
        machinery failing, reported to stderr, and it yields the internal-error
        code over anything else.

        Args:
            code: The code the caller reached this exit path carrying.
            rank_delivery: Whether `code` is a run code the model ranks, so a
                deferred write error may escalate it. False for a usage
                refusal, which was decided before any run existed and so has
                no run facts to rank against.

        Returns:
            The process exit code. Mutates: every owned resource is released,
            so the result is meaningful once. Never raises.
        """
        self._discard_junit_scratch()
        self._discard_report_scratch()
        var resolved = code
        # `flaky_failed` is False here on purpose: the session already applied
        # it, so a flaky-forced failure arrives as `outcome_code=1` and survives
        # this re-resolution. Re-stating the fact could only demote a 0 that the
        # session had already decided was not one.
        if self.json_owns_fd:
            var delivery_failed = close_json_fd(self.json_fd)
            self.json_owns_fd = False
            if rank_delivery:
                resolved = resolve_exit_code(
                    TerminalFacts(
                        interrupted=False,
                        internal_error=False,
                        drift=False,
                        precompile_failed=False,
                        outcome_code=code,
                        delivery_failed=delivery_failed,
                        flaky_failed=False,
                    )
                )
        try:
            self.runtime.close()
        except e:
            _eprintln("mtest: internal error: " + String(e))
            return EXIT_INTERNAL_ERROR
        return resolved


def main():
    """Parse argv, display config or run the session, and exit truthfully."""
    # The sentinel is never read: every except path below exits the process,
    # but the compiler does not treat `exit` as noreturn, so the value must be
    # initialized on the fall-through path it thinks exists.
    var result = ParseResult.show_help()
    try:
        result = parse_args(_argv_tail())
    except e:
        # A pre-session cli: usage error: the one seam exception — straight to
        # stderr with the dedicated usage exit code 4.
        _eprintln(String(e))
        exit(EXIT_USAGE_ERROR)

    if result.is_help():
        _exit_with_output(help_text(), 1, 0)
    if result.is_version():
        _exit_with_output(version_text() + "\n", 1, 0)
    if result.is_doctor():
        var diagnosis = run_doctor(result, MTEST_VERSION)
        var rendered = String("")
        for line in diagnosis.lines:
            rendered += line + "\n"
        _exit_with_output(rendered, 1, diagnosis.code)

    # Resolve the invocation root, then discover and layer project configuration
    # before taking process-global exec state. An absent file and `--no-config`
    # never call the native TOML parser. A root lookup failure is a pre-session
    # internal error; the honest code is 3.
    var root: String
    try:
        root = String(cwd())
    except e:
        _eprintln("mtest: internal error: " + String(e))
        exit(EXIT_INTERNAL_ERROR)
        return

    # Scaffolding needs the root to resolve a relative path and nothing else:
    # no configuration layer can change which file is created or what goes in
    # it, so a malformed project file must not stop someone from writing their
    # first test. That is why this sits between the root and the config load
    # rather than beside `config show` below.
    if result.is_new():
        # No `try` around this call, and the compiler is what makes that safe
        # rather than optimistic: `run_new` is declared without `raises`, so a
        # raise that escaped its own containment would not compile. The
        # {0, 3, 4} exit domain is therefore closed structurally — an escaping
        # error cannot leave the process on the uncaught-error exit 1, the one
        # code that would read as "your test failed".
        var scaffolded = run_new(root, result.operand)
        var rendered = String("")
        for line in scaffolded.lines:
            rendered += line + "\n"
        # `created <path>` is the command's output and belongs on stdout, so a
        # stdout that will not take it leaves the caller with no record of the
        # file and escalates to 3 (§29). A refusal or an I/O failure is a
        # diagnostic ABOUT a code already resolved: it belongs on stderr, and a
        # stderr that will not take it costs the words, never the verdict.
        if scaffolded.code == 0:
            _exit_with_output(rendered, 1, 0)
        _ = _write_direct(rendered, 2)
        exit(scaffolded.code)

    # Beside `new`, and for the same reason: `init` writes the project file
    # that configuration discovery would read, so it has to run before that
    # discovery rather than after resolving against a file it is about to
    # create. `run_init` is declared without `raises` too, which closes its
    # {0, 3, 4} exit domain structurally.
    if result.is_init():
        var bootstrapped = run_init(root, result.ci)
        var rendered = String("")
        for line in bootstrapped.lines:
            rendered += line + "\n"
        # A failed `init` may already have created something, and the record of
        # what it did belongs with the diagnostic that stopped it rather than
        # split across two streams a reader would have to reassemble. That
        # makes the failure path a diagnostic and the success path the
        # command's product, which is what decides whether an undelivered
        # write may move the code — see `new` above.
        if bootstrapped.code == 0:
            _exit_with_output(rendered, 1, 0)
        _ = _write_direct(rendered, 2)
        exit(bootstrapped.code)

    var loaded = _load_config(root, result.config_path, result.no_config)
    if loaded.error_code != 0:
        _eprintln(loaded.error)
        exit(loaded.error_code)

    var environment = ConfigEnvironment(
        mtest_mojo=getenv("MTEST_MOJO", ""),
        no_color=_no_color_set(),
    )
    var resolved = resolve_config(
        cli_only_resolution_defaults(result.config),
        loaded.file,
        environment,
        result.overlay,
    )
    resolved.config_file = loaded.config_file.copy()
    # The projection is chosen from the parsed command, and `resolve_config`
    # sees only a `RunnerConfig` — which carries collect mode but not the debug
    # subcommand — so the one command whose kind it cannot see is applied here,
    # before any validation reads an active key. Under debug the report keys are
    # inactive, which is what makes a project file's `[report]` destinations
    # neither validated nor opened for a command that will leave no reporter
    # behind to write them.
    if result.is_debug():
        resolved.active_keys = ActiveConfigKeys.debug()
    var validation = validate_resolved_config(resolved)
    if validation:
        _eprintln(validation.value())
        exit(EXIT_USAGE_ERROR)
    # Deliberately NOT before the config-show branch. §27.1 fixes that
    # command's exit domain at {0, 3, 4} with 4 reserved for argv and
    # selected-config failures, and states it resolves only; refusing an
    # unusable report destination there would add an unsanctioned exit cause
    # and make a resolution-only command probe the filesystem.
    if result.is_config_show():
        var state_present = exists(_state_path(root))
        _exit_with_output(render_config_show(resolved, state_present), 1, 0)

    var destination_error = _resolved_destination_error(resolved)
    if destination_error:
        _eprintln(destination_error.value())
        exit(EXIT_USAGE_ERROR)
    # After the parent-directory check, and only on the run path: this is the
    # command that will actually open every one of these destinations, and
    # `destination_identity` resolves a parent the check above just proved
    # exists.
    var collision_error = _destination_collision_error(resolved)
    if collision_error:
        _eprintln(collision_error.value())
        exit(EXIT_USAGE_ERROR)

    var config = resolved.config.copy()

    # `--cache-clear` runs HERE: after configuration is resolved (so a usage
    # error never reaches a deletion) and before the last-run state is read,
    # because that state file lives inside the directory being deleted. Reading
    # it first would hand the session records that no longer exist on disk.
    # A refusal is a pre-session configuration error, so it takes the same shape
    # as a failed `_load_config`: the framed diagnostic to stderr, exit 4.
    var state_cleared = False
    if config.cache_clear:
        # Asked BEFORE the removal, so the warning the session emits under
        # `--lf`/`--ff` claims only what actually happened: with no state file
        # there was nothing to clear, and the session's own `lf-empty` warning
        # already says the selection fell back.
        var had_state = exists(_state_path(root))
        var clear_failure = clear_cache_root(root)
        if clear_failure:
            _eprintln(clear_failure.value())
            exit(EXIT_USAGE_ERROR)
        state_cleared = had_state
    resolved.state_cleared = state_cleared

    var state_enabled = resolved.active_keys.state and resolved.state
    var previous_state = LastRunState.empty()
    if state_enabled:
        var state_load = _load_state(root)
        previous_state = state_load.state.copy()
        resolved.state_warnings = state_load.warnings.copy()
        resolved.last_run_state = previous_state.copy()

    var runtime = ExecRuntime()
    try:
        runtime.open()
    except e:
        var primary = String(e)
        try:
            runtime.close()
        except cleanup_error:
            _eprintln(
                "mtest: internal error: "
                + primary
                + "; "
                + String(cleanup_error)
            )
            exit(EXIT_INTERNAL_ERROR)
            return
        _eprintln("mtest: internal error: " + primary)
        exit(EXIT_INTERNAL_ERROR)
        return

    # From here on the runtime is owned, and every exit path has to release it.
    # The machine-stream descriptor and the JUnit scratch join it below, each
    # recorded the moment it is actually opened.
    var resources = RunResources(
        runtime^,
        -1,
        False,
        String(""),
        String(""),
        String(""),
        String(""),
        -1,
        String(""),
        -1,
    )

    # Debug: prepare one test under ordinary supervision, print the two
    # commands, and then BECOME the test binary. Every refusal is made here,
    # while this process still owns its exit code; after the exec there is no
    # mtest left to report anything, so nothing below the handoff renders a
    # summary or claims a verdict over what the binary goes on to do.
    if result.is_debug():
        var outcome = DebugOutcome(0, List[String](), DebugPlan.none())
        try:
            outcome = prepare_debug(
                resources.runtime, resolved, root, result.operand
            )
        except e:
            # An unclassifiable machinery failure. Caught rather than allowed to
            # escape: an uncaught raise exits 1, which is exactly the code that
            # would read as "your test failed".
            _eprintln("mtest: internal error: " + String(e))
            exit(resources.close_into(EXIT_INTERNAL_ERROR, rank_delivery=False))
        if outcome.code != 0:
            for line in outcome.diagnostics:
                _eprintln(line)
            exit(resources.close_into(outcome.code, rank_delivery=False))
        # The unbuffered write is load-bearing here: `execv` does not flush
        # stdio, so an unflushed pair would vanish with this process image.
        # These two lines are the whole point of `debug` before the handoff —
        # a reader who never got them cannot rerun anything — so an
        # undelivered write is exit 3, taken through the ladder because the
        # exec runtime and the report scratch are already owned.
        if not _write_direct(
            "build: "
            + outcome.plan.build_line
            + "\nrun: "
            + outcome.plan.run_line
            + "\n",
            1,
        ):
            exit(resources.close_into(EXIT_INTERNAL_ERROR, rank_delivery=False))
        # An interrupt that arrived during the preparation — or while the
        # marker write above was blocked on a reader that had stopped reading —
        # is an interrupt of MTEST, and mtest is the only process that can
        # still report it as one. Sampled on both sides of the close, as
        # doctor's is: the first sample sees what the runtime's handler
        # latched, and the second covers restoration itself. Execing on a
        # latched interrupt would hand the terminal over anyway and return the
        # debuggee's own status, which reads as though nothing was interrupted.
        if interrupt_requested():
            exit(resources.close_into(EXIT_INTERRUPTED, rank_delivery=False))
        var handoff_code = resources.close_into(0, rank_delivery=False)
        if handoff_code != 0:
            # A failed restoration is exactly the state in which the debuggee
            # would inherit `SIGPIPE=SIG_IGN` from the runtime and a genuine
            # broken-pipe death could read as a pass. Refuse the handoff.
            exit(handoff_code)
        if interrupt_requested():
            exit(EXIT_INTERRUPTED)
        try:
            # The exec target is absolute, so the handoff never depends on the
            # process cwd; the printed line keeps the rerunnable relative form,
            # and `run_argv` carries it as argv[0] for the same reason.
            exec_replace(
                root + "/" + outcome.plan.binary, outcome.plan.run_argv
            )
        except e:
            _eprintln("mtest: internal error: " + String(e))
            exit(EXIT_INTERNAL_ERROR)
        # Unreachable: `exec_replace` either never returns or raises. Stated
        # anyway because `exit` is not noreturn to the compiler, so without it
        # a debug invocation would fall through into the run path below and
        # execute a whole session nobody asked for.
        exit(EXIT_INTERNAL_ERROR)

    # Collect mode: probe every discovered file for its node ids and print the
    # SORTED listing to STDOUT, byte-clean, running no test body. This print is
    # the SECOND sanctioned exception to the event seam (usage errors are the
    # first): the listing is a frozen machine-readable contract, so it is written
    # OUTSIDE any reporter, STDOUT carries ONLY the listing, and every diagnostic
    # goes to STDERR. A discover: usage error still routes to exit 4. `--format
    # json` renders the same listing as the NDJSON collect stream; the
    # diagnostics stay identical stderr text under either format.
    if config.collect:
        var collected = CollectResult(List[String](), List[String](), 0)
        try:
            # The resolved config, not the flattened one: the compatibility
            # overload carries no override tables, so a configured per-file
            # compile-timeout would be dropped and a probe could hang past it.
            collected = run_collect(resources.runtime, resolved, root)
        except e:
            _eprintln(String(e))
            exit(resources.close_into(EXIT_USAGE_ERROR, rank_delivery=False))
        for line in collected.diagnostics:
            _eprintln(line)
        if config.collect_json:
            # Teardown FIRST, and for this format only: the terminal record
            # carries the code the process exits with, and releasing the
            # runtime can still escalate a collection to 3. Rendering first and
            # resolving after would let the record and `$?` disagree, which is
            # the one thing `collect_finished` promises cannot happen.
            var final_code = resources.close_into(
                collected.code, rank_delivery=True
            )
            var stream = collect_stream_header(MTEST_VERSION) + "\n"
            for nid in collected.listing:
                # Both formats re-split the ONE sorted listing, so a node line
                # and its plain-text twin cannot describe different tests. The
                # split is `render()`'s inverse, at the LAST separator, which
                # is also the only one: §5 keeps `::` out of every discovered
                # path, so a listed id carries exactly one.
                var node = split_rendered_node_id(nid)
                stream += collect_node_line(nid, node.path, node.name) + "\n"
            stream += collect_finished_line(len(collected.listing), final_code)
            stream += "\n"
            # Written after the teardown restored SIGPIPE to its default, so
            # the write needs `_write_direct`'s own guard to keep a consumer
            # that closed early (`mtest collect --format json | head -1`) from
            # killing mtest at 141 — a status outside the frozen {0,1,2,3,4,5}
            # domain (§9, §16) for a listing that completed.
            # The ladder has already run for this format — `final_code` is
            # its result — so nothing is owned here and the 3 is direct.
            if not _write_direct(stream, 1):
                exit(EXIT_INTERNAL_ERROR)
            exit(final_code)
        # The plain listing carries no terminal record, so nothing in it depends
        # on the finalized code and the runtime deliberately stays up across the
        # write. Both the runtime's own SIGPIPE carve-out and `_write_direct`'s
        # cover this write, and neither is redundant: the runtime's holds for
        # every reporter write in a session, and the guard holds for the writes
        # that happen with no runtime at all.
        var listing = String("")
        for nid in collected.listing:
            listing += nid + "\n"
        # The listing IS what `collect` produces, so a stdout that could not
        # take it leaves the caller with nothing to consume. The runtime is
        # still up here, so the 3 goes through the ladder.
        if not _write_direct(listing, 1):
            exit(resources.close_into(EXIT_INTERNAL_ERROR, rank_delivery=True))
        exit(resources.close_into(collected.code, rank_delivery=True))

    # Resolve the machine-stream destination and, with it, the console's own
    # destination. Under `--json -` the stream OWNS stdout (byte-pure), so the
    # whole console relocates to stderr; `--json PATH` streams to the file and
    # leaves the console on stdout. `--color auto` then decides against the
    # console's RESOLVED descriptor — stderr's TTY-ness when relocated, stdout's
    # otherwise — because color is a property of where the human text lands.
    var console_fd = 1
    var json_fd = -1
    var json_active = False
    if config.json_dest == "-":
        json_fd = 1
        json_active = True
        console_fd = 2
    elif config.json_dest != "":
        # Open the destination at session start. A runtime open failure
        # (permissions, a missing parent that slipped past parse-time
        # validation, descriptor exhaustion) is a pre-run internal error: exit 3.
        try:
            json_fd = open_json_fd(config.json_dest)
        except open_error:
            _eprintln("mtest: internal error: " + String(open_error))
            exit(resources.close_into(EXIT_INTERNAL_ERROR, rank_delivery=True))
        json_active = True
        resources.json_fd = json_fd
        resources.json_owns_fd = True

    # The GitHub Actions probe drives BOTH the `auto` annotation resolution and
    # the console's stop-commands FENCING of echoed child output. Fencing is
    # active whenever `GITHUB_ACTIONS=true`, independent of the annotation mode
    # (even `off`): any child-produced `::error` in echoed output would otherwise
    # forge a workflow command. The annotation TAIL renders only when resolved-on.
    var gh_actions = getenv("GITHUB_ACTIONS", "") == "true"
    var annotations_on = annotations_resolved_on(
        config.gh_annotations, gh_actions
    )

    var console_is_tty = stderr_isatty() if console_fd == 2 else stdout_isatty()
    var build_flags = build_flags_string(config)
    var console = ConsoleReporter(
        MTEST_VERSION,
        config.color,
        console_is_tty,
        _no_color_set(),
        config.verbosity,
        config.show_output,
        build_flags^,
        config.durations,
        gh_actions,
        config.fail_on_flaky,
    )
    # Resolve the JUnit report destination. Unlike `--json`, the destination is
    # NEVER opened for live truncation: a unique temp file is created in the
    # TARGET directory now — proving it writable BEFORE any build or run — and the
    # assembled document is atomically renamed onto PATH at session finalization,
    # so a prior report survives every failure. A runtime creation failure here
    # (an unwritable or vanished target directory) is a pre-run internal error:
    # exit 3, mirroring `--json`'s runtime open failure. Report destinations are
    # not root-constrained.
    var junit_active = config.junit_dest != ""
    var junit_spool = String("")
    var junit_temp = String("")
    var junit_target = String("")
    if junit_active:
        try:
            # Record the spool as owned FIRST, so a later failure to open the
            # target temp still leaves the spool directory tracked for cleanup
            # rather than leaking it.
            junit_spool = open_junit_spool()
            resources.junit_spool = junit_spool
            var artifact = open_junit_artifact(junit_spool, config.junit_dest)
            junit_temp = artifact.temp_path
            resources.junit_temp = junit_temp
            junit_target = artifact.target_path
        except junit_error:
            _eprintln("mtest: internal error: " + String(junit_error))
            exit(resources.close_into(EXIT_INTERNAL_ERROR, rank_delivery=True))

    # Resolve the run-report destinations, on exactly the terms `--junit-xml`
    # uses: nothing at PATH is touched until the final atomic rename, and the
    # unique temp created in the TARGET directory now is what proves that
    # directory writable BEFORE any build or run. A creation failure here is a
    # pre-run internal error: exit 3.
    #
    # The descriptor `create_unique_temp` returns is LENT to the writer, which
    # performs the one close inside `finalize_reports`. `RunResources` records
    # the pair so an abort path can unlink the temp by name, and never closes
    # it — a second close would target a descriptor number the kernel may
    # already have reissued.
    var report_md_active = config.report_md_dest != ""
    var report_html_active = config.report_html_dest != ""
    var report_md = Optional[ReportArtifact](None)
    var report_html = Optional[ReportArtifact](None)
    if report_md_active or report_html_active:
        try:
            # Record the spool as owned FIRST, so a later failure to create a
            # target temp still leaves the spool directory tracked for cleanup
            # rather than leaking it.
            resources.report_spool = open_report_spool()
            if report_md_active:
                var md = create_unique_temp(
                    _report_temp_template(config.report_md_dest)
                )
                resources.report_md_temp = md.path.copy()
                resources.report_md_fd = md.fd
                _relax_report_temp_mode(md.path)
                report_md = ReportArtifact(
                    config.report_md_dest.copy(),
                    md.path.copy(),
                    md.fd,
                    False,
                    "",
                )
            if report_html_active:
                var html = create_unique_temp(
                    _report_temp_template(config.report_html_dest)
                )
                resources.report_html_temp = html.path.copy()
                resources.report_html_fd = html.fd
                _relax_report_temp_mode(html.path)
                report_html = ReportArtifact(
                    config.report_html_dest.copy(),
                    html.path.copy(),
                    html.fd,
                    False,
                    "",
                )
        except report_error:
            _eprintln("mtest: internal error: " + String(report_error))
            exit(resources.close_into(EXIT_INTERNAL_ERROR, rank_delivery=True))

    # Each reporter is independently inert when its feature is off: no `--json`,
    # no `--junit-xml`, annotations resolved off, no `--report`. The coordinator
    # exposes the stream latch, the JUnit finalize, the run-report finalize, and
    # the annotation tail by name, so no caller depends on the order they are
    # constructed in.
    var stream = JsonStreamReporter(json_fd, MTEST_VERSION, json_active)
    var junit = JunitReporter(
        junit_spool, junit_active, junit_target, junit_temp
    )
    var annotations = AnnotationsReporter(annotations_on, config.fail_on_flaky)
    # The version and the platform are `main`'s to supply: `session` sits below
    # `cli` and can never name `MTEST_VERSION`, and the platform label comes
    # from the same source `doctor`'s platform line reads.
    var report = ReportWriter(
        ReportHeaderFacts(MTEST_VERSION, host_platform_label()),
        _report_style_code(config.report_style),
        report_md^,
        report_html^,
        resources.report_spool,
        root,
    )
    var comp = StandardReportCoordinator(
        console^, stream^, junit^, annotations^, report^
    )

    var session_result = SessionResult(0, StateDelta.empty())
    try:
        session_result = run_session_with_state(
            resources.runtime, resolved, root, comp, console_fd=console_fd
        )
    except e:
        # The only raise the session propagates is a discover: usage error;
        # like a cli usage error it exits 4 to stderr. The session raised before
        # finalizing, so the epilogue clears the junit scratch it never got to
        # publish. A usage error dominates any close-failure escalation, so the
        # descriptor's close status is not ranked against it.
        _eprintln(String(e))
        exit(resources.close_into(EXIT_USAGE_ERROR, rank_delivery=False))
    var code = session_result.code

    # The session has already flushed the console's fully rendered buffer to its
    # RESOLVED destination — stdout normally, stderr under `--json -` so stdout
    # carries only the byte-pure stream — draining it as the run progressed and
    # sealing it with a closing flush before returning. `main` lent the
    # descriptor and keeps its close; here it only appends the epilogue below.

    # The ALWAYS-RUNS restoration epilogue, then the annotation tail — both to the
    # console's resolved descriptor, right after the summary band. When the
    # console fenced any captured-output region under Actions, emit one final
    # resume delimiter FIRST so workflow commands are guaranteed re-enabled before
    # mtest's OWN `::error`/`::warning`/`::notice` lines — no error or partial path
    # can leave commands disabled. The tail itself renders only when annotations
    # resolved on (never beside `--json -`, refused at parse time).
    #
    # Neither write may exit on its own. Both land after the session finalized
    # and while the JUnit spool, the machine-stream descriptor and the exec
    # runtime are still owned, so an exit taken here would walk around the
    # ladder below and leave the spool and its fragments in TMPDIR, once per
    # invocation. The failure is latched instead and consumed after the code is
    # resolved, exactly as a late machine-stream failure is.
    var epilogue_delivered = True
    var fence_token = comp.fence_token()
    if gh_actions and fence_token != "":
        epilogue_delivered = _write_direct(
            resume_delimiter(fence_token) + "\n", console_fd
        )
    if annotations_on:
        var tail = comp.annotation_tail()
        var rendered = String("")
        for line in tail:
            rendered += line + "\n"
        if not _write_direct(rendered, console_fd):
            epilogue_delivered = False
    if not epilogue_delivered:
        # The console epilogue is part of the run's report, so an undelivered
        # one is a delivery failure the model ranks, not a code this decides.
        # Presenting the already-resolved code with `delivery_failed` set is
        # the documented way to re-apply that one precedence and nothing else:
        # an interrupt's 2 still stands, a 3 stays 3, a 0/1/5 becomes 3.
        code = resolve_exit_code(
            TerminalFacts(
                interrupted=False,
                internal_error=False,
                drift=False,
                precompile_failed=False,
                outcome_code=code,
                delivery_failed=True,
                flaky_failed=False,
            )
        )

    # The session has finalized (the JUnit report was renamed onto its target,
    # or left intact on failure), so the epilogue frees the spool directory and
    # fragments main created for it, closes the machine-stream descriptor main
    # owns — whose deferred write error, if any, the session could not have
    # seen and the resolver re-ranks — and restores the exec runtime. Covers
    # the success, interrupt, finalize-failure, and spool-failure paths alike.
    var state_text = String("")
    var state_drops = List[String]()
    if state_enabled and config.shard_n == 0:
        var merged = merge_last_run_state(
            previous_state, session_result.state_delta
        )
        var encoded = encode_last_run_state(merged)
        state_text = encoded.text
        # A record the codec refuses to write (a control-bearing identifier,
        # for instance) is a failure silently missing from the next --lf.
        # Reporters are closed by write time, so these go to stderr beside the
        # persistence diagnostic rather than through the event stream.
        for diagnostic in encoded.diagnostics:
            state_drops.append(diagnostic.render())

    var final_code = resources.close_into(code, rank_delivery=True)
    if (
        state_enabled
        and config.shard_n == 0
        and (final_code == 0 or final_code == 1)
    ):
        for drop in state_drops:
            _eprintln(drop)
        var state_error = _persist_state(root, state_text)
        if state_error:
            _eprintln(state_error.value())
    exit(final_code)
