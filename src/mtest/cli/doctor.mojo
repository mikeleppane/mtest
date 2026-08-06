"""The contained, read-only `mtest doctor` check runner.

Layer 5 owns this command because it diagnoses the fully composed invocation:
configuration, platform I/O, and the exec substrate. It never enters session
or reporter code. Filesystem probes are removed unless the filesystem itself
refuses cleanup, which is reported as a failed check.
"""
from std.os import getenv, makedirs, remove, rmdir
from std.os.path import exists, isdir
from std.pathlib import cwd
from std.sys.info import CompilationTarget, is_triple

from mtest.cli.destinations import active_destinations
from mtest.cli.parse_result import ParseResult
from mtest.config import (
    CliOverlay,
    ConfigEnvironment,
    FileConfig,
    Provenance,
    ResolvedConfig,
    RunnerConfig,
    TOML_SOURCE_MAX_BYTES,
    cli_only_resolution_defaults,
    lossy_utf8,
    parse_last_run_state,
    parse_toml,
    resolve_config,
    safe_path_label,
    validate_resolved_config,
)
from mtest.exec import (
    ExecRuntime,
    ProcessSpec,
    interrupt_requested,
    run_supervised,
)
from mtest.model import is_interpreted_control
from mtest.platform import (
    BoundedRegularFileRead,
    close_checked_fd,
    create_unique_temp,
    process_id,
    read_bounded_regular_file,
)


comptime _CHECK_COUNT = 10
comptime _TOOLCHAIN_DEADLINE_MS = 5000
comptime _STATE_MAX_BYTES = 1024 * 1024
comptime _PINNED_MOJO_IDENTITY = "Mojo 1.0.0b2 (2cf4d08a)"


@fieldwise_init
struct DoctorReport(Copyable, Movable):
    """The deterministic doctor lines and their dedicated exit code."""

    var lines: List[String]
    """Exactly one rendered line per attempted check."""

    var code: Int
    """Zero for healthy, one for failed checks, or two for interruption."""


@fieldwise_init
struct _ConfigLoad(Copyable, Movable):
    var file: FileConfig
    var selected: String
    var error: String


struct _DoctorContext(Movable):
    var request: ParseResult
    var root: String
    var root_ok: Bool
    var runtime: ExecRuntime
    var runtime_ok: Bool
    var exec_line: String
    var config_loaded: Bool
    var config_load: _ConfigLoad
    var resolved: ResolvedConfig

    def __init__(out self, request: ParseResult):
        self.request = request.copy()
        self.root = ""
        self.root_ok = False
        self.runtime = ExecRuntime()
        self.runtime_ok = False
        self.exec_line = _line("FAIL", "exec", "runtime not acquired")
        self.config_loaded = False
        self.config_load = _ConfigLoad(FileConfig.empty(), "", "")
        self.resolved = resolve_config(
            cli_only_resolution_defaults(request.config),
            FileConfig.empty(),
            _environment(),
            request.overlay,
        )


def _line(status: String, name: String, detail: String) -> String:
    return status + " " + name + ": " + safe_path_label(detail)


def _has_control(text: String) -> Bool:
    """Whether `text` carries any code point a terminal would interpret.

    Covers the same code points `safe_path_label` escapes, so a toolchain
    identity made only of C1 controls is rejected as unusable rather than
    compared, printed, and trusted.

    Args:
        text: Untrusted display text, already valid UTF-8.

    Returns:
        True when `text` holds a C0 control, DEL, or a C1 control.
    """
    for cp in text.codepoints():
        if is_interpreted_control(Int(cp), preserve_lf_tab=False):
            return True
    return False


def _toolchain_identity_is_pinned(identity: String) -> Bool:
    return identity == _PINNED_MOJO_IDENTITY


def _config_detail(diagnostic: String) -> String:
    if diagnostic.startswith("config: "):
        return String(diagnostic.removeprefix("config: "))
    return diagnostic


def _exec_detail(diagnostic: String) -> String:
    if diagnostic.startswith("exec: "):
        return String(diagnostic.removeprefix("exec: "))
    return diagnostic


def _check_name(index: Int) -> String:
    if index == 0:
        return "version"
    if index == 1:
        return "platform"
    if index == 2:
        return "root"
    if index == 3:
        return "exec"
    if index == 4:
        return "toolchain"
    if index == 5:
        return "config"
    if index == 6:
        return "config-semantics"
    if index == 7:
        return "state"
    if index == 8:
        return "temp"
    return "report-destinations"


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
    return normalized^


def _absolute_from_root(root: String, path: String) -> String:
    if path.startswith("/"):
        return _normalize_absolute(path)
    return _normalize_absolute(root + "/" + path)


def _relative_to_root(root: String, absolute: String) -> String:
    var normalized_root = _normalize_absolute(root)
    var prefix = "/" if normalized_root == "/" else normalized_root + "/"
    if absolute.startswith(prefix):
        return String(absolute[byte = prefix.byte_length() :])
    return absolute


def _environment() -> ConfigEnvironment:
    return ConfigEnvironment(
        mtest_mojo=getenv("MTEST_MOJO", ""),
        no_color=getenv("NO_COLOR", "").byte_length() > 0,
    )


def _load_config(
    root: String, root_ok: Bool, request: ParseResult
) -> _ConfigLoad:
    if request.no_config:
        return _ConfigLoad(FileConfig.empty(), "", "")
    var explicit = request.config_path != ""
    var requested = request.config_path if explicit else "mtest.toml"
    var absolute: String
    var selected: String
    if requested.startswith("/"):
        absolute = _normalize_absolute(requested)
        selected = _relative_to_root(
            root, absolute
        ) if root_ok else absolute.copy()
    elif not root_ok:
        return _ConfigLoad(
            FileConfig.empty(), "", "dependency root unavailable"
        )
    else:
        absolute = _absolute_from_root(root, requested)
        selected = _relative_to_root(root, absolute)
    var label = safe_path_label(selected)
    if not exists(absolute):
        if explicit:
            return _ConfigLoad(
                FileConfig.empty(),
                selected,
                "config: " + label + ": configuration file does not exist",
            )
        return _ConfigLoad(FileConfig.empty(), "", "")
    var opened: BoundedRegularFileRead
    try:
        opened = read_bounded_regular_file(absolute, TOML_SOURCE_MAX_BYTES)
    except:
        return _ConfigLoad(
            FileConfig.empty(),
            selected,
            "config: " + label + ": could not read configuration file",
        )
    if not opened.is_regular:
        return _ConfigLoad(
            FileConfig.empty(),
            selected,
            "config: " + label + ": configuration path is not a regular file",
        )
    if opened.text.byte_length() > TOML_SOURCE_MAX_BYTES:
        return _ConfigLoad(
            FileConfig.empty(),
            selected,
            "config: "
            + label
            + ": configuration file exceeds "
            + String(TOML_SOURCE_MAX_BYTES)
            + "-byte limit",
        )
    var parsed = parse_toml(opened.text, label)
    if not parsed.is_ok:
        return _ConfigLoad(
            FileConfig.empty(), selected, parsed.failure.render()
        )
    return _ConfigLoad(parsed.config.copy(), selected, "")


def _ensure_config(mut context: _DoctorContext):
    if context.config_loaded:
        return
    context.config_load = _load_config(
        context.root, context.root_ok, context.request
    )
    context.resolved = resolve_config(
        cli_only_resolution_defaults(context.request.config),
        context.config_load.file,
        _environment(),
        context.request.overlay,
    )
    context.resolved.config_file = context.config_load.selected.copy()
    context.config_loaded = True


def _probe_directory(
    path: String, stem: String, inject_remove_refusal: Bool = False
) raises:
    var created_path = String("")
    var owned_fd = -1
    try:
        var created = create_unique_temp(
            path + "/." + stem + "." + String(process_id()) + ".XXXXXX"
        )
        created_path = created.path.copy()
        owned_fd = created.fd
        var closing_fd = owned_fd
        owned_fd = -1
        try:
            close_checked_fd(closing_fd)
        except e:
            raise Error(
                "could not close unique probe '"
                + created_path
                + "': "
                + String(e)
            )
        if inject_remove_refusal:
            raise Error(
                "injected primary probe failure for unique probe '"
                + created_path
                + "'"
            )
        try:
            remove(created_path)
        except e:
            raise Error(
                "could not remove unique probe '"
                + created_path
                + "': "
                + String(e)
            )
    except e:
        var detail = String(e)
        if owned_fd >= 0:
            var closing_fd = owned_fd
            try:
                close_checked_fd(closing_fd)
            except cleanup:
                detail += (
                    "; cleanup could not close unique probe fd: "
                    + String(cleanup)
                )
        if created_path != "":
            try:
                remove(created_path)
                if inject_remove_refusal:
                    raise Error("injected cleanup remove refusal")
            except cleanup:
                detail += (
                    "; cleanup could not remove unique probe '"
                    + created_path
                    + "': "
                    + String(cleanup)
                )
        raise Error(detail^)


def _temp_base() -> String:
    var base = getenv("TMPDIR", "")
    if base == "":
        base = getenv("TEMP", "")
    if base == "":
        base = getenv("TMP", "")
    if base == "":
        return "/tmp"
    if base.byte_length() > 1 and base.endswith("/"):
        return String(base.removesuffix("/"))
    return base^


def _mojo_source(resolved: ResolvedConfig) -> String:
    var source = resolved.provenance.mojo_path
    if source == Provenance.MTEST_TOML:
        return "mtest.toml"
    if source == Provenance.ENV_MTEST_MOJO:
        return "MTEST_MOJO"
    if source == Provenance.CLI:
        return "CLI"
    return "PATH default"


def _acquire_runtime(mut context: _DoctorContext):
    try:
        context.runtime.open()
        context.runtime_ok = True
        context.exec_line = _line("PASS", "exec", "runtime acquired")
    except e:
        var detail = String(e)
        try:
            context.runtime.close()
        except cleanup:
            detail += "; cleanup failed: " + String(cleanup)
        context.runtime_ok = False
        context.exec_line = _line("FAIL", "exec", _exec_detail(detail^))


def _check_toolchain(mut context: _DoctorContext) raises -> String:
    _ensure_config(context)
    if context.config_load.error != "":
        return _line("FAIL", "toolchain", "dependency config unavailable")
    if not context.runtime_ok:
        return _line("FAIL", "toolchain", "dependency exec unavailable")
    var mojo = context.resolved.config.mojo_path.copy()
    var subject = "'" + mojo + "' from " + _mojo_source(context.resolved)
    var result = run_supervised(
        context.runtime,
        ProcessSpec.command([mojo, "--version"], _TOOLCHAIN_DEADLINE_MS),
    )
    var ending = result.termination
    if ending.is_spawn_failed():
        return _line(
            "FAIL",
            "toolchain",
            subject + ": could not execute",
        )
    if ending.is_timed_out():
        if interrupt_requested():
            return _line(
                "FAIL",
                "toolchain",
                subject + ": interrupted during version probe",
            )
        return _line("FAIL", "toolchain", subject + ": version probe timed out")
    if ending.is_signaled():
        return _line(
            "FAIL",
            "toolchain",
            subject
            + ": version probe terminated by signal "
            + String(ending.value),
        )
    if not ending.is_exited() or ending.value != 0:
        return _line(
            "FAIL",
            "toolchain",
            subject + ": version probe exited " + String(ending.value),
        )
    if result.stdout_truncated or result.stderr_truncated:
        return _line(
            "FAIL",
            "toolchain",
            subject + ": version probe output was truncated",
        )
    var stdout_identity = String(lossy_utf8(result.stdout_bytes).strip())
    var stderr_identity = String(lossy_utf8(result.stderr_bytes).strip())
    if stdout_identity != "" and stderr_identity != "":
        return _line(
            "FAIL",
            "toolchain",
            (
                subject
                + ": expected "
                + _PINNED_MOJO_IDENTITY
                + ","
                + " got output on both streams"
            ),
        )
    var identity = (
        stdout_identity^ if stdout_identity != "" else stderr_identity^
    )
    if identity == "" or _has_control(identity):
        return _line(
            "FAIL",
            "toolchain",
            (
                subject
                + ": expected "
                + _PINNED_MOJO_IDENTITY
                + ","
                + " got no usable identity"
            ),
        )
    if not _toolchain_identity_is_pinned(identity):
        return _line(
            "FAIL",
            "toolchain",
            (
                subject
                + ": expected "
                + _PINNED_MOJO_IDENTITY
                + ", got '"
                + identity
                + "'"
            ),
        )
    return _line(
        "PASS",
        "toolchain",
        subject + ": " + identity,
    )


def _check_state(mut context: _DoctorContext) raises -> String:
    if not context.root_ok:
        return _line("FAIL", "state", "dependency root unavailable")
    var directory = context.root + "/.mtest-cache"
    var made_directory = False
    try:
        if exists(directory):
            if not isdir(directory):
                return _line("FAIL", "state", ".mtest-cache is not a directory")
        else:
            makedirs(directory)
            made_directory = True
        _probe_directory(directory, "mtest-doctor-state")
        var state_path = directory + "/lastrun"
        if exists(state_path):
            var opened = read_bounded_regular_file(state_path, _STATE_MAX_BYTES)
            if not opened.is_regular:
                raise Error("lastrun is not a regular file")
            if opened.text.byte_length() > _STATE_MAX_BYTES:
                raise Error("lastrun exceeds the diagnostic size limit")
            var parsed = parse_last_run_state(
                opened.text, ".mtest-cache/lastrun"
            )
            if len(parsed.diagnostics) > 0:
                raise Error(parsed.diagnostics[0].render())
    except e:
        var detail = String(e)
        if made_directory:
            try:
                rmdir(directory)
            except cleanup:
                detail += (
                    "; cleanup could not remove created state directory '"
                    + directory
                    + "': "
                    + String(cleanup)
                )
        return _line("FAIL", "state", detail^)
    if made_directory:
        try:
            rmdir(directory)
        except e:
            return _line(
                "FAIL",
                "state",
                (
                    "cleanup could not remove created state directory '"
                    + directory
                    + "': "
                    + String(e)
                ),
            )
    return _line("PASS", "state", "cache and lastrun usable")


def _check_report_destinations(
    mut context: _DoctorContext,
) raises -> String:
    """Probe the parent directory of every destination this config would open.

    The destination set is the run path's own, so a project file the runner
    would refuse cannot pass here: doctor and the run agree on which keys are
    active and which values name a real file.
    """
    _ensure_config(context)
    if context.config_load.error != "":
        return _line(
            "FAIL",
            "report-destinations",
            "dependency config unavailable",
        )
    var destinations = active_destinations(context.resolved)
    for i in range(len(destinations)):
        var parent = destinations[i].parent
        if not context.root_ok and not parent.startswith("/"):
            return _line(
                "FAIL", "report-destinations", "dependency root unavailable"
            )
        var absolute = context.root if parent == "" else _absolute_from_root(
            context.root, parent
        )
        if not isdir(absolute):
            return _line(
                "FAIL",
                "report-destinations",
                destinations[i].format
                + " parent does not exist: '"
                + safe_path_label(parent)
                + "'",
            )
        _probe_directory(absolute, "mtest-doctor-" + destinations[i].format)
    if len(destinations) == 0:
        return _line("PASS", "report-destinations", "none")
    return _line(
        "PASS",
        "report-destinations",
        String(len(destinations)) + " parent(s) usable",
    )


def platform_label(macos: Bool) -> String:
    """Name one supported platform, as `doctor`'s platform line names it.

    Args:
        macos: Whether the label describes Darwin rather than Linux.

    Returns:
        The bare platform identity, with no verdict or qualifier attached.
    """
    return String("macOS arm64") if macos else String("Linux x86_64")


def host_platform_label() -> String:
    """This build's own platform identity, resolved at compile time.

    The same source `doctor`'s platform line reads from, so a run report's
    header and a `doctor` block can never name two different platforms for one
    binary.

    Returns:
        `macOS arm64` on Darwin, `Linux x86_64` on Linux.
    """
    comptime if CompilationTarget.is_macos():
        return platform_label(True)
    else:
        return platform_label(False)


def _platform_line(macos: Bool) -> String:
    if macos:
        return _line(
            "WARN",
            "platform",
            platform_label(True)
            + " supported; hosted runtime evidence pending",
        )
    return _line("PASS", "platform", platform_label(False) + " supported")


def _execute_check(
    mut context: _DoctorContext, index: Int, version: String
) raises -> String:
    if index == 0:
        return _line("PASS", "version", "mtest " + version)
    if index == 1:
        comptime if CompilationTarget.is_macos():
            comptime assert (
                not CompilationTarget.is_x86()
            ), "doctor supports macOS arm64 only"
            return _platform_line(True)
        else:
            comptime assert (
                CompilationTarget.is_linux()
            ), "doctor supports Linux or macOS only"
            comptime assert is_triple[
                "x86_64-unknown-linux-gnu"
            ](), "doctor supports Linux x86_64 only"
            return _platform_line(False)
    if index == 2:
        context.root = String(cwd())
        context.root_ok = True
        return _line("PASS", "root", context.root)
    if index == 3:
        return context.exec_line.copy()
    if index == 4:
        return _check_toolchain(context)
    if index == 5:
        _ensure_config(context)
        if context.config_load.error != "":
            return _line(
                "FAIL",
                "config",
                _config_detail(context.config_load.error),
            )
        if context.config_load.selected == "":
            return _line("PASS", "config", "none")
        return _line(
            "PASS", "config", "valid '" + context.config_load.selected + "'"
        )
    if index == 6:
        _ensure_config(context)
        if context.config_load.error != "":
            return _line(
                "FAIL",
                "config-semantics",
                "dependency config unavailable",
            )
        var validation = validate_resolved_config(context.resolved)
        if validation:
            return _line("FAIL", "config-semantics", validation.value())
        return _line("PASS", "config-semantics", "resolved values valid")
    if index == 7:
        return _check_state(context)
    if index == 8:
        if not context.root_ok:
            return _line("FAIL", "temp", "dependency root unavailable")
        _probe_directory(context.root, "mtest-doctor-root")
        var system = _temp_base()
        _probe_directory(system, "mtest-doctor-system")
        return _line("PASS", "temp", "invocation root and system temp usable")
    return _check_report_destinations(context)


def _run_checks(
    request: ParseResult,
    version: String,
    inject_at: Int,
    check_limit: Int,
) -> DoctorReport:
    var context = _DoctorContext(request)
    _acquire_runtime(context)
    var lines = List[String]()
    var failed = False
    var interrupted = False
    for index in range(check_limit):
        try:
            if index == inject_at:
                raise Error("injected\nunexpected\tthrow")
            var rendered = _execute_check(context, index, version)
            if rendered.startswith("FAIL "):
                failed = True
            lines.append(rendered^)
        except e:
            failed = True
            lines.append(
                _line(
                    "FAIL",
                    _check_name(index),
                    "unexpected error: " + String(e),
                )
            )
        if interrupt_requested():
            interrupted = True
    var interrupted_before_close = interrupt_requested()
    if context.runtime.active:
        try:
            context.runtime.close()
            context.runtime_ok = False
        except e:
            failed = True
            _record_exec_failure(lines, String(e))
    var interrupted_after_close = interrupt_requested()
    var code = _doctor_exit_code(
        failed,
        interrupted or interrupted_before_close,
        interrupted_after_close,
    )
    return DoctorReport(lines^, code)


def _doctor_exit_code(
    failed: Bool,
    interrupted_before_close: Bool,
    interrupted_after_close: Bool,
) -> Int:
    if interrupted_before_close or interrupted_after_close:
        return 2
    return 1 if failed else 0


def _record_exec_failure(mut lines: List[String], detail: String):
    if len(lines) > 3:
        lines[3] = _line("FAIL", "exec", _exec_detail(detail))


def run_doctor(request: ParseResult, version: String) -> DoctorReport:
    """Run every doctor check with per-check containment and cleanup.

    A check that throws is recorded as one failed line and the checks after it
    still run. Cleanup refusal is itself a failed check, and it may leave the
    named unique probe or the created state directory behind.

    Args:
        request: The parsed doctor controls. Not mutated.
        version: The mtest build identity to report.

    Returns:
        Ten deterministic check lines and the dedicated doctor exit code.
        Allocates transient probe results.

    Examples:

    ```mojo
    from mtest.cli import run_doctor
    from mtest.cli import MTEST_VERSION, parse_args

    var argv: List[String] = ["doctor", "--no-config"]
    var report = run_doctor(parse_args(argv), MTEST_VERSION)
    print(report.lines[0], report.code)
    ```
    """
    return _run_checks(request, version, -1, _CHECK_COUNT)


def _doctor_containment_probe() -> DoctorReport:
    """Inject a throw into the real ordered doctor check driver.

    Returns:
        The real version/platform/root prefix with the platform check replaced
        by a contained failure: the driver continues past a throw and exits one.
    """
    return _run_checks(
        ParseResult.doctor(
            RunnerConfig.default(),
            CliOverlay.default(),
        ),
        "containment",
        1,
        3,
    )


def _doctor_root_dependency_probe(
    request: ParseResult,
) raises -> List[String]:
    var context = _DoctorContext(request)
    _ensure_config(context)
    var config_status = (
        "available" if context.config_load.error
        == "" else context.config_load.error.copy()
    )
    var toolchain = _check_toolchain(context)
    return [config_status^, toolchain^]


def _doctor_cleanup_failure_probe() -> String:
    try:
        _probe_directory(
            String(cwd()), "mtest-doctor-cleanup", inject_remove_refusal=True
        )
    except e:
        return String(e)
    return "cleanup refusal was not injected"


def _doctor_close_failure_probe() -> String:
    var lines: List[String] = [
        String("PASS version: mtest probe"),
        String("PASS platform: probe"),
        String("PASS root: /probe"),
        String("PASS exec: runtime acquired"),
    ]
    _record_exec_failure(
        lines, "exec: runtime close failed (operation 7, errno 5)"
    )
    return lines[3].copy()


def _doctor_platform_probe(macos: Bool) -> String:
    return _platform_line(macos)
