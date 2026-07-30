"""The data value `discover` returns.

`DiscoveryResult` is pure data: the ordered gate and run file sets, the
excluded files each paired with the pattern that removed it, the stale exclude
patterns that matched nothing, and the two loud channels a walk fills — the
symlinks it refused and the test-named entries that are not runnable files. The
session turns this into events: a loud skip line per excluded file and a
warning per stale pattern, refused symlink, and non-regular entry. This module
reads and prints nothing.
"""


@fieldwise_init
struct ExcludedEntry(Copyable, Movable):
    """One excluded file: the path removed and the pattern that removed it.

    Owns its strings, so copies are explicit; the session emits one loud skip
    line from each entry.
    """

    var path: String
    """The root-relative path of the excluded file."""

    var pattern: String
    """The `--exclude` glob that matched and removed `path`."""


@fieldwise_init
struct DiscoveryResult(Copyable, Movable):
    """The concrete, ordered file set a session will run.

    Deliberately `Copyable, Movable` but not `ImplicitlyCopyable`: it owns
    several `List`s, so every copy is a visible `.copy()` in review.
    """

    var gate_files: List[String]
    """`--gate` files, root-relative, deduped, exclusions removed, in the order
    the gates were listed."""

    var run_files: List[String]
    """Non-gate files to run, root-relative, deduped, exclusions and gate
    overlaps removed, sorted lexicographically for deterministic scheduling."""

    var excluded: List[ExcludedEntry]
    """Every excluded file with the pattern that removed it, sorted by path."""

    var stale_excludes: List[String]
    """Every `--exclude` pattern that matched nothing, in listed order."""

    var skipped_links: List[String]
    """Every symlink a walk refused, root-relative and sorted: a symlinked
    directory (not descended, for cycle safety) or a `test_*.mojo` link that
    resolves to no usable file — deleted, unreachable, or a FIFO, socket, or
    device. The session warns once per entry — a dropped selection is never
    silent."""

    var skipped_nonregular: List[String]
    """Every test-named walk entry that is not a runnable file, root-relative
    and sorted: a directory wearing a `test_*.mojo` name, or a FIFO, socket, or
    device sitting where a test file is expected. The session warns once per
    entry, for the same reason it warns about a refused symlink."""
