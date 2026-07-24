"""Pure last-failed filtering and failed-first admission ordering.

Layer 2 selection policy only: persisted records are intersected with
already-discovered files and already-collected test names without filesystem
reads, events, or raising selection lookups.
"""
from mtest.config import LastRunRecordKind, LastRunState
from mtest.model import split_node_token


@fieldwise_init
struct CollectedNames(Copyable, Movable):
    """One discovered file's full universe and ordinary selected subset."""

    var path: String
    """The root-relative discovered path."""

    var names: List[String]
    """The collected names in source order."""

    var selected: List[String]
    """The ordinary CLI-selected names in collection order."""


@fieldwise_init
struct FailureFileSelection(Copyable, Movable):
    """The surviving remembered selection for one discovered file."""

    var path: String
    """The root-relative discovered path."""

    var whole_file: Bool
    """Whether selection came from a file-scoped persisted record."""

    var names: List[String]
    """The surviving test names in collection order when not whole-file."""


@fieldwise_init
struct LastFailedSelection(Copyable, Movable):
    """The non-raising intersection of remembered failures and collection."""

    var files: List[FailureFileSelection]
    """Surviving files in discovery order."""

    var stale_ids: List[String]
    """Dropped identifiers, escaped to one physical diagnostic line."""

    var matched: Bool
    """Whether at least one remembered failure survives."""


@fieldwise_init
struct FailedFirstOrder(Copyable, Movable):
    """Gate, parallel, and serial bands after stable failed-first ordering."""

    var gates: List[String]
    """The untouched gate band."""

    var parallel: List[String]
    """The parallel band, remembered files first and otherwise stable."""

    var serial: List[String]
    """The serial band, remembered files first and otherwise stable."""


def _safe_identifier(identifier: String) -> String:
    var escaped = String("")
    comptime HEX = "0123456789abcdef"
    for cp in identifier.codepoints():
        var value = Int(cp)
        if value == 10:
            escaped += "\\n"
        elif value == 13:
            escaped += "\\r"
        elif value == 9:
            escaped += "\\t"
        elif (value >= 0 and value < 32) or (value >= 128 and value < 160):
            escaped += "\\x"
            escaped += String(HEX[byte=value // 16])
            escaped += String(HEX[byte=value % 16])
        elif value == 127:
            escaped += "\\x7f"
        elif value == 0x2028:
            escaped += "\\u2028"
        elif value == 0x2029:
            escaped += "\\u2029"
        else:
            escaped += String(cp)
    return escaped


def _has_file(files: List[String], path: String) -> Bool:
    for file in files:
        if file == path:
            return True
    return False


def _names_for(collected: List[CollectedNames], path: String) -> List[String]:
    for item in collected:
        if item.path == path:
            return item.names.copy()
    return []


def _has_name(names: List[String], name: String) -> Bool:
    for candidate in names:
        if candidate == name:
            return True
    return False


def _file_recorded(state: LastRunState, path: String) -> Bool:
    for record in state.records:
        if record.kind == LastRunRecordKind.FILE and record.identifier == path:
            return True
    return False


def _test_recorded(state: LastRunState, path: String, name: String) -> Bool:
    for record in state.records:
        if record.kind != LastRunRecordKind.TEST:
            continue
        var split = split_node_token(record.identifier)
        if (
            split.sep_count == 1
            and split.file_part == path
            and split.name_part == name
        ):
            return True
    return False


def resolve_last_failed(
    files: List[String],
    collected: List[CollectedNames],
    state: LastRunState,
) -> LastFailedSelection:
    """Intersect remembered records with discovered files and collected names.

    Missing files and test names become safe stale identifiers instead of
    raising usage errors. Surviving files follow discovery order and surviving
    names follow collection order.

    Args:
        files: The ordinary discovered run files. Not mutated.
        collected: The per-file collected names. Not mutated.
        state: The parsed persisted records. Not mutated.

    Returns:
        A newly allocated soft-filter result and its nonfatal drops.
    """
    var stale = List[String]()
    for record in state.records:
        if record.kind == LastRunRecordKind.FILE:
            if not _has_file(files, record.identifier):
                stale.append(_safe_identifier(record.identifier))
            continue
        var split = split_node_token(record.identifier)
        if split.sep_count != 1 or not _has_file(files, split.file_part):
            stale.append(_safe_identifier(record.identifier))
            continue
        var names = _names_for(collected, split.file_part)
        if not _has_name(names, split.name_part):
            stale.append(_safe_identifier(record.identifier))

    var selected = List[FailureFileSelection]()
    for path in files:
        if _file_recorded(state, path):
            selected.append(FailureFileSelection(path, True, []))
            continue
        var chosen = List[String]()
        var ordinary = List[String]()
        for item in collected:
            if item.path == path:
                ordinary = item.selected.copy()
                break
        for name in ordinary:
            if _test_recorded(state, path, name):
                chosen.append(name)
        if len(chosen) > 0:
            selected.append(FailureFileSelection(path, False, chosen^))
    return LastFailedSelection(selected^, stale^, len(selected) > 0)


def _path_was_failing(state: LastRunState, path: String) -> Bool:
    if _file_recorded(state, path):
        return True
    for record in state.records:
        if record.kind != LastRunRecordKind.TEST:
            continue
        var split = split_node_token(record.identifier)
        if split.sep_count == 1 and split.file_part == path:
            return True
    return False


def remembered_file_matches(files: List[String], state: LastRunState) -> Bool:
    """Whether any persisted record names one of the discovered files.

    Args:
        files: The discovered run files. Not mutated.
        state: The parsed persisted records. Not mutated.

    Returns:
        True when a file or test record has a discovered file path.
    """
    for file in files:
        if _path_was_failing(state, file):
            return True
    return False


def missing_file_identifiers(
    files: List[String], state: LastRunState
) -> List[String]:
    """Return safe identifiers whose persisted file path is undiscovered.

    Args:
        files: The discovered run files. Not mutated.
        state: The parsed persisted records. Not mutated.

    Returns:
        Fresh escaped identifiers in state order.
    """
    var missing = List[String]()
    for record in state.records:
        var path = record.identifier.copy()
        if record.kind == LastRunRecordKind.TEST:
            var split = split_node_token(record.identifier)
            if split.sep_count == 1:
                path = split.file_part
        if not _has_file(files, path):
            missing.append(_safe_identifier(record.identifier))
    return missing^


def _stable_failed_first(
    files: List[String], state: LastRunState
) -> List[String]:
    var ordered = List[String]()
    for file in files:
        if _path_was_failing(state, file):
            ordered.append(file)
    for file in files:
        if not _path_was_failing(state, file):
            ordered.append(file)
    return ordered^


def order_failed_first(
    gates: List[String],
    parallel: List[String],
    serial: List[String],
    state: LastRunState,
) -> FailedFirstOrder:
    """Move remembered files first independently inside both run bands.

    Args:
        gates: The gate band, returned byte-for-byte in the same order.
        parallel: The parallel run band. Not mutated.
        serial: The serial run band. Not mutated.
        state: The parsed persisted failures. Not mutated.

    Returns:
        Fresh stable bands. Serial membership never changes and gates are
        untouched.
    """
    return FailedFirstOrder(
        gates.copy(),
        _stable_failed_first(parallel, state),
        _stable_failed_first(serial, state),
    )
