"""The discovery pipeline: normalize, deduplicate, order.

`discover` turns a `RunnerConfig`'s operands, gates, and exclude globs,
resolved against an explicit invocation `root`, into a `DiscoveryResult`. The
`root` is a parameter (production passes the current working directory, tests
pass a temp directory), so the walk is unit-testable without touching the
process's cwd.

The stages:

1. Default path. With no operands, walk `tests/` if it exists under the root,
   else the root itself.
2. Normalize each operand and gate to root-relative form, lexically. A
   directory is walked for `test_*.mojo` files; an explicitly named file is
   taken regardless of the pattern. A node id (`PATH::TEST`) resolves to its
   file part. A nonexistent operand, an operand that escapes the root, an
   operand with more than one `::`, a node id whose path is a directory, an
   operand of a file type mtest cannot run, and a path that cannot be
   inspected each raise a `discover:` usage error (the exit-4 class). An empty
   walk is not an error: it yields empty run files.
3. Deduplicate on the root-relative path; a file that is both a gate and in a
   walk lands once, in `gate_files` (gate-overlap promotion).
4. Apply excludes (fnmatch against the whole path). An exclusion wins over both
   a gate and an explicit path, loudly: the file moves to `excluded` with the
   pattern that removed it. A pattern matching nothing becomes a stale entry.
5. Order. `run_files` sorted lexicographically; `gate_files` in listed order;
   `excluded` sorted by path; `stale_excludes` in listed order; both loud walk
   channels — the refused symlinks and the test-named entries that are not
   runnable files — deduplicated and sorted.
"""
from std.builtin.sort import sort
from std.os import lstat
from std.os.path import exists, isdir, isfile

from mtest.config import RunnerConfig
from mtest.model import escape_one_line, split_node_token
from mtest.discover.fnmatch import fnmatch
from mtest.discover.normalize import normalize_operand, normalize_root
from mtest.discover.result import DiscoveryResult, ExcludedEntry
from mtest.discover.walk import walk_dir

comptime _S_IFMT = 0xF000
"""File-type mask over `st_mode`; POSIX fixes it on Linux and Darwin alike."""

comptime _S_IFDIR = 0x4000
"""`S_IFDIR`: the `st_mode` file-type value for a directory."""

comptime _S_IFLNK = 0xA000
"""`S_IFLNK`: the `st_mode` file-type value for a symbolic link."""

comptime _S_IFREG = 0x8000
"""`S_IFREG`: the `st_mode` file-type value for a regular file."""


def _abs_of(nroot: String, rel: String) -> String:
    """The absolute filesystem path of a root-relative `rel` under `nroot`."""
    if rel == "":
        return nroot
    return nroot + "/" + rel


def _contains(haystack: List[String], needle: String) -> Bool:
    """Whether `needle` equals any element of `haystack`."""
    for x in haystack:
        if x == needle:
            return True
    return False


def _dedup_preserve(items: List[String]) -> List[String]:
    """`items` with later duplicates dropped, first-occurrence order kept."""
    var out = List[String]()
    for x in items:
        if not _contains(out, x):
            out.append(String(x))
    return out^


def _malformed_node_id_error(op: String) -> Error:
    """The exit-4 usage error for an operand with more than one `::`."""
    return Error(
        "discover: malformed node id '"
        + escape_one_line(op)
        + "': a node id is PATH::TEST with a single '::' (see mtest --help)"
    )


def _node_id_names_directory_error(op: String, dir_part: String) -> Error:
    """The exit-4 usage error for a node id whose path resolves to a directory.

    A node id is FILE::TEST: it selects one test in one file. A directory path
    is refused as malformed rather than walked, since walking it would drop the
    `::TEST` selector and run the whole tree.
    """
    return Error(
        "discover: malformed node id '"
        + escape_one_line(op)
        + "': '"
        + escape_one_line(dir_part)
        + "' is a directory, but a node id is FILE::TEST (see mtest --help)"
    )


def _classify(
    op: String,
    nroot: String,
    mut into: List[String],
    mut skipped: List[String],
    mut nonregular: List[String],
) raises:
    """Resolve one operand into `into` (walked files, or one explicit file).

    A node id (`PATH::TEST`) resolves to its file part; per-test name selection
    is applied later by the session. More than one `::`, or a node id whose
    path is a directory, is a malformed node id. Also raises for a nonexistent
    path, an operand escaping the root, an operand of a file type mtest cannot
    run (a FIFO, socket, or device — refused for what it actually is, never as
    "no such path"), and an operand that `exists` accepted but `lstat` cannot
    characterize. Every raise is the exit-4 class.

    One accepted bound: `exists` folds an unsearchable parent directory into
    plain absence, so an operand under one still reports "no such path".
    Distinguishing the two needs errno detail this layer cannot see; neither
    case is a silent loss, since both refuse the run.

    Any symlink a walk refused is appended to `skipped`, and any test-named
    walk entry that is not a runnable file to `nonregular`, for the caller to
    warn about. An explicitly named operand is never refused for being a
    symlink: naming a file is a direct selection, and `exists` already accepted
    it.
    """
    var split = split_node_token(op)
    if split.sep_count > 1:
        raise _malformed_node_id_error(op)
    var is_node_id = split.sep_count == 1
    var file_op = op if not is_node_id else split.file_part
    var rel = normalize_operand(file_op, nroot)  # raises on root escape
    var fpath = _abs_of(nroot, rel)
    if not exists(fpath):
        raise Error("discover: no such path '" + escape_one_line(file_op) + "'")
    var kind: Int
    try:
        kind = Int(lstat(fpath).st_mode) & _S_IFMT
    except:
        raise Error(
            "discover: cannot inspect '" + escape_one_line(file_op) + "'"
        )
    # For a symlink operand the target's type decides, as before: naming a link
    # is a direct selection, and `exists` already followed it.
    var names_dir = kind == _S_IFDIR or (kind == _S_IFLNK and isdir(fpath))
    var names_file = kind == _S_IFREG or (kind == _S_IFLNK and isfile(fpath))
    if names_dir:
        if is_node_id:
            raise _node_id_names_directory_error(op, file_op)
        var walked = walk_dir(fpath, rel)
        for f in walked.files:
            into.append(f)
        for s in walked.skipped_links:
            skipped.append(s)
        for s in walked.skipped_nonregular:
            nonregular.append(s)
    elif names_file:
        into.append(rel)
    else:
        raise Error(
            "discover: unsupported file type at '"
            + escape_one_line(file_op)
            + "'"
        )


def _apply_excludes(
    files: List[String],
    patterns: List[String],
    mut matched: List[Bool],
    mut excluded: List[ExcludedEntry],
) -> List[String]:
    """Drop files matching any exclude pattern; keep the rest in order.

    Marks every pattern that matches any file (for stale detection) and records
    each dropped file against the first pattern that matched it.
    """
    var kept = List[String]()
    for f in files:
        var hit = -1
        for pi in range(len(patterns)):
            if fnmatch(f, patterns[pi]):
                matched[pi] = True
                if hit == -1:
                    hit = pi
        if hit == -1:
            kept.append(String(f))
        else:
            excluded.append(ExcludedEntry(String(f), String(patterns[hit])))
    return kept^


def _sort_excluded(mut entries: List[ExcludedEntry]):
    """Sort excluded entries lexicographically by path (insertion sort)."""
    for i in range(1, len(entries)):
        var j = i
        while j > 0 and entries[j].path < entries[j - 1].path:
            entries.swap_elements(j, j - 1)
            j -= 1


def discover(config: RunnerConfig, root: String) raises -> DiscoveryResult:
    """Resolve `config`'s operands against `root` into the file set to run.

    Args:
        config: The runner config; its `paths`, `gates`, and `excludes` are
            read.
        root: The invocation root the operands resolve against.

    Returns:
        A `DiscoveryResult` with the ordered gate and run files, the excluded
        files, and the stale exclude patterns.

    Raises:
        Error: A `discover:`-prefixed usage error (exit-4 class) for a
            nonexistent operand, an operand escaping the root, a malformed
            node id, an operand whose file type mtest cannot run, or a path
            the walk cannot inspect. An empty walk is not an error.

    Examples:

    ```mojo
    from mtest.config import RunnerConfig
    from mtest.discover import discover

    var config = RunnerConfig.default()
    config.paths = ["tests"]
    var result = discover(config, "/repo")  # walks tests/ for test_*.mojo
    ```
    """
    var nroot = normalize_root(root)

    # Stage 1: default path when no operands are given.
    var operands = List[String]()
    if len(config.paths) == 0 and not config.paths_supplied:
        if isdir(_abs_of(nroot, "tests")):
            operands.append(String("tests"))
        else:
            operands.append(String("."))
    else:
        for p in config.paths:
            operands.append(String(p))

    # Stage 2: normalize + classify operands and gates into raw file lists.
    # Refused symlinks and test-named non-files accumulate across every operand
    # and gate walk.
    var skipped_links = List[String]()
    var skipped_nonregular = List[String]()
    var run_raw = List[String]()
    for op in operands:
        _classify(op, nroot, run_raw, skipped_links, skipped_nonregular)
    var gate_raw = List[String]()
    for g in config.gates:
        _classify(g, nroot, gate_raw, skipped_links, skipped_nonregular)

    # Stage 3: dedup; a gate that also appears in a walk stays a gate only.
    var gate_files = _dedup_preserve(gate_raw)
    var run_dedup = _dedup_preserve(run_raw)
    var run_promoted = List[String]()
    for f in run_dedup:
        if not _contains(gate_files, f):
            run_promoted.append(String(f))

    # Stage 4: apply excludes to both sets; track stale patterns.
    var patterns = config.excludes.copy()
    var matched = List[Bool]()
    for _ in range(len(patterns)):
        matched.append(False)
    var excluded = List[ExcludedEntry]()
    var gate_kept = _apply_excludes(gate_files, patterns, matched, excluded)
    var run_kept = _apply_excludes(run_promoted, patterns, matched, excluded)
    var stale = List[String]()
    for pi in range(len(patterns)):
        if not matched[pi]:
            stale.append(String(patterns[pi]))

    # Stage 5: order the outputs. Overlapping operands can walk the same
    # subtree twice, so refused links are deduped before they are warned about.
    sort(run_kept)
    _sort_excluded(excluded)
    var links = _dedup_preserve(skipped_links)
    sort(links)
    var nonregular = _dedup_preserve(skipped_nonregular)
    sort(nonregular)

    return DiscoveryResult(
        gate_files=gate_kept^,
        run_files=run_kept^,
        excluded=excluded^,
        stale_excludes=stale^,
        skipped_links=links^,
        skipped_nonregular=nonregular^,
    )
