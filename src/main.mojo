"""The `mtest` binary entry point.

`main` is the only place that reads the process argv and environment, talks to
the terminal, and calls `exit`. It parses argv and resolves project config.
`doctor` runs its contained environment checks before main acquires the
invocation root or exec runtime. A `config show` request renders its resolution
and exits before state loading or run resources. Otherwise main loads last-run
state, constructs the exec runtime, resolves report destinations, composes
reporters into the `StandardReportCoordinator` interface the session drives,
runs the session, closes every resource, conditionally promotes the next state
file, and exits with the session's resolved code.

Five output classes bypass the event seam by design: pre-session diagnostics
go straight to stderr; `config show` writes its resolution-only TOML directly
to stdout; doctor writes its fixed check lines directly to stdout;
`--collect-only` writes its frozen node-id listing directly to stdout; and a
post-close state-write failure goes to stderr after the terminal event already
sealed the stream.

The parser owns argv syntax; config owns typed conversion, layering, and state
bytes; the console resolves color from the inputs main supplies; the session
states the run's facts and `resolve_exit_code` in the model layer ranks them.
`main` owns only process-level discovery, file I/O, resource ordering, and the
dedicated pre-run usage refusal. All FFI stays below in `exec`.
`stdout_isatty()` and `stderr_isatty()` are the terminal probes, while argv,
cwd, getenv, file operations, and exit are ordinary program-level operations
via `std`.
"""
from std.io import FileDescriptor
from std.os import getenv, listdir, makedirs, remove, rmdir
from std.os.path import dirname, exists, isdir
from std.pathlib import cwd
from std.sys import argv, exit

from mtest.cli import (
    MTEST_VERSION,
    ParseResult,
    build_flags_string,
    help_text,
    parse_args,
    run_doctor,
    version_text,
)
from mtest.exec import ExecRuntime, stderr_isatty, stdout_isatty
from mtest.config import (
    ConfigEnvironment,
    FileConfig,
    LastRunState,
    Provenance,
    ResolvedConfig,
    RunnerConfig,
    StateDelta,
    TOML_SOURCE_MAX_BYTES,
    annotations_resolved_on,
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
    TerminalFacts,
    resolve_exit_code,
)
from mtest.platform import (
    BoundedRegularFileRead,
    close_checked_fd,
    create_unique_temp,
    process_id,
    read_bounded_regular_file,
    rename_path,
    write_all_fd,
)
from mtest.report import (
    AnnotationsReporter,
    ConsoleReporter,
    JsonStreamReporter,
    JunitReporter,
    StandardReportCoordinator,
    close_json_fd,
    open_json_fd,
    open_junit_artifact,
    open_junit_spool,
    resume_delimiter,
)
from mtest.session import (
    CollectResult,
    SessionResult,
    run_collect,
    run_session_with_state,
)


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


def _eprintln(text: String):
    """Write `text` and a newline to standard error (fd 2), flushed."""
    print(text, file=FileDescriptor(2), flush=True)


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
    return Optional[String](None)


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


def _resolution_defaults(parsed: RunnerConfig) -> RunnerConfig:
    var defaults = RunnerConfig.default()
    defaults.exitfirst = parsed.exitfirst
    defaults.keyword = parsed.keyword.copy()
    defaults.collect = parsed.collect
    defaults.last_failed = parsed.last_failed
    defaults.failed_first = parsed.failed_first
    defaults.shard_mode = parsed.shard_mode
    defaults.shard_m = parsed.shard_m
    defaults.shard_n = parsed.shard_n
    defaults.no_cache = parsed.no_cache
    defaults.cache_clear = parsed.cache_clear
    return defaults^


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
    var directory = root + "/.mtest-cache"
    var target = _state_path(root)
    var template = target + ".tmp." + String(process_id()) + ".XXXXXX"
    var temp = String("")
    var owned_fd = -1
    try:
        makedirs(directory, exist_ok=True)
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

    `main` takes these resources at three different points: the exec runtime
    first, then the machine-stream descriptor, then the JUnit scratch. Every
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

        The ladder, stated once: discard the JUnit scratch, close the
        machine-stream descriptor when `main` owns it, then restore the exec
        runtime. The precedence over `code` follows from what each release can
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
        var resolved = code
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
        print(help_text(), end="", flush=True)
        exit(0)
    if result.is_version():
        print(version_text(), flush=True)
        exit(0)
    if result.is_doctor():
        var diagnosis = run_doctor(result, MTEST_VERSION)
        var rendered = String("")
        for line in diagnosis.lines:
            rendered += line + "\n"
        print(rendered, end="", flush=True)
        exit(diagnosis.code)

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

    var loaded = _load_config(root, result.config_path, result.no_config)
    if loaded.error_code != 0:
        _eprintln(loaded.error)
        exit(loaded.error_code)

    var environment = ConfigEnvironment(
        mtest_mojo=getenv("MTEST_MOJO", ""),
        no_color=_no_color_set(),
    )
    var resolved = resolve_config(
        _resolution_defaults(result.config),
        loaded.file,
        environment,
        result.overlay,
    )
    resolved.config_file = loaded.config_file.copy()
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
        print(
            render_config_show(resolved, state_present),
            end="",
            flush=True,
        )
        exit(0)

    var destination_error = _resolved_destination_error(resolved)
    if destination_error:
        _eprintln(destination_error.value())
        exit(EXIT_USAGE_ERROR)

    var config = resolved.config.copy()
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
    var resources = RunResources(runtime^, -1, False, String(""), String(""))

    # Collect mode: probe every discovered file for its node ids and print the
    # SORTED listing to STDOUT, byte-clean, running no test body. This print is
    # the SECOND sanctioned exception to the event seam (usage errors are the
    # first): the listing is a frozen machine-readable contract, so it is written
    # OUTSIDE any reporter, STDOUT carries ONLY the listing, and every diagnostic
    # goes to STDERR. A discover: usage error still routes to exit 4.
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
        var listing = String("")
        for nid in collected.listing:
            listing += nid + "\n"
        print(listing, end="", flush=True)
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

    # Each reporter is independently inert when its feature is off: no `--json`,
    # no `--junit-xml`, annotations resolved off. The coordinator exposes the
    # stream latch, the JUnit finalize, and the annotation tail by name, so no
    # caller depends on the order they are constructed in.
    var stream = JsonStreamReporter(json_fd, MTEST_VERSION, json_active)
    var junit = JunitReporter(
        junit_spool, junit_active, junit_target, junit_temp
    )
    var annotations = AnnotationsReporter(annotations_on)
    var comp = StandardReportCoordinator(
        console^, stream^, junit^, annotations^
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
    var fence_token = comp.fence_token()
    if gh_actions and fence_token != "":
        print(
            resume_delimiter(fence_token),
            file=FileDescriptor(console_fd),
            flush=True,
        )
    if annotations_on:
        var tail = comp.annotation_tail()
        var rendered = String("")
        for line in tail:
            rendered += line + "\n"
        print(rendered, end="", file=FileDescriptor(console_fd), flush=True)

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
