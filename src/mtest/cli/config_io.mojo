"""The two files an invocation reads before a session exists, and writes after.

Layer 5 owns this because both are named back to the reader the way the command
line spells them — a `--config` value, `.mtest-cache/lastrun` — and both are
resolved against the invocation root rather than against anything a session
knows. `main` is the only caller, and it sits inside this package for the
import rules.

Nothing here prints or ends the process. A configuration file that is missing,
unreadable, oversized, or malformed comes back as a complete diagnostic plus
the code that answers it. A state file that cannot be trusted comes back as an
empty or partial state plus one warning per rejected fact, because state only
reorders and narrows a selection: refusing it costs the acceleration, never the
run.
"""
from std.os import remove
from std.os.path import exists

from mtest.config import (
    FileConfig,
    LastRunState,
    TOML_SOURCE_MAX_BYTES,
    parse_last_run_state,
    parse_toml,
    safe_path_label,
)
from mtest.model import EXIT_USAGE_ERROR
from mtest.platform import (
    BoundedRegularFileRead,
    close_checked_fd,
    create_unique_temp,
    process_id,
    read_bounded_regular_file,
    rename_path,
    write_all_fd,
)
from mtest.session import ensure_cache_root


comptime STATE_MAX_BYTES = 1024 * 1024
"""The accepted `.mtest-cache/lastrun` payload ceiling.

Matches the doctor check's ceiling so the two agree on what a usable state
file is. State is an accelerator, never a verdict input, so an oversized or
non-regular file is ignored loudly rather than treated as a failure.
"""


def _normalize_absolute(path: String) -> String:
    """Resolve `.` and `..` lexically, without touching the filesystem.

    Args:
        path: An absolute path, or one already joined onto the root.

    Returns:
        The path with every empty, `.`, and resolvable `..` component removed.
        A `..` above the root is dropped, since there is nothing above `/`.
    """
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
    """Resolve `path` against the invocation root when it is relative.

    Args:
        root: The invocation root.
        path: The requested configuration path.

    Returns:
        The normalized absolute path the read will open.
    """
    if path.startswith("/"):
        return _normalize_absolute(path)
    return _normalize_absolute(root + "/" + path)


def _config_file_representation(root: String, absolute: String) -> String:
    """Name the selected file the way a reader under `root` would spell it.

    Args:
        root: The invocation root.
        absolute: The normalized path the read will open.

    Returns:
        The path relative to the root when it sits inside it, absolute
        otherwise. This is what every diagnostic and `config show` cites.
    """
    var normalized_root = _normalize_absolute(root)
    var prefix = "/" if normalized_root == "/" else normalized_root + "/"
    if absolute.startswith(prefix):
        return String(absolute[byte = prefix.byte_length() :])
    return absolute


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


def load_config(
    root: String, explicit_path: String, no_config: Bool
) -> ConfigLoad:
    """Discover, read, and parse the project configuration file.

    `--no-config` and an absent default `mtest.toml` both resolve to an empty
    layer with no diagnostic, because a project without a configuration file is
    ordinary. A file named explicitly is different: the caller asked for that
    file, so its absence, its type, its size, and its syntax are all usage
    errors carrying the path the way the reader spelled it.

    Args:
        root: The invocation root a relative path resolves against.
        explicit_path: The `--config` value, empty when none was given.
        no_config: Whether `--no-config` suppressed discovery entirely.

    Returns:
        The typed file layer and the selected file's stream representation, or
        a complete diagnostic and the code that answers it. Allocates.
    """
    if no_config:
        return ConfigLoad(FileConfig.empty(), "", "", 0)

    var explicit = explicit_path != ""
    var requested = explicit_path if explicit else "mtest.toml"
    var absolute = _absolute_from_root(root, requested)
    var representation = _config_file_representation(root, absolute)
    var diagnostic_representation = safe_path_label(representation)
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


def state_path(root: String) -> String:
    """The last-run state file under `root`.

    Args:
        root: The invocation root the cache directory hangs under.

    Returns:
        The path, whether or not anything is there.
    """
    return root + "/.mtest-cache/lastrun"


def load_state(root: String) -> StateLoad:
    """Read the previous run's records, refusing whatever cannot be trusted.

    Args:
        root: The invocation root the state file hangs under.

    Returns:
        The accepted records and one warning per rejected fact. An absent file
        is silent; every other refusal names itself. Allocates.
    """
    var path = state_path(root)
    var state_exists = exists(path)
    if not state_exists:
        return StateLoad(LastRunState.empty(), [])
    var opened: BoundedRegularFileRead
    try:
        opened = read_bounded_regular_file(path, STATE_MAX_BYTES)
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
    if text.byte_length() > STATE_MAX_BYTES:
        return StateLoad(
            LastRunState.empty(),
            ["state: .mtest-cache/lastrun: exceeds the size limit — ignored"],
        )
    var parsed = parse_last_run_state(text, ".mtest-cache/lastrun")
    var warnings = List[String]()
    for diagnostic in parsed.diagnostics:
        warnings.append(diagnostic.render())
    return StateLoad(parsed.state.copy(), warnings^)


def persist_state(root: String, text: String) -> Optional[String]:
    """Publish `text` as the next last-run state, atomically.

    The bytes go to a unique temp beside the target and are renamed onto it, so
    a concurrent reader sees the previous state or this one and never a torn
    file. Both the descriptor and the temp are released on every path.

    Args:
        root: The invocation root the state file hangs under.
        text: The encoded state, written verbatim.

    Returns:
        A complete diagnostic when nothing was published, or none on success.
    """
    var target = state_path(root)
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
