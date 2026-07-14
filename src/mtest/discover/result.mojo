"""The data value `discover` returns.

`DiscoveryResult` is pure data: the ordered gate and run file sets, the excluded
files each paired with the pattern that removed it, and the stale exclude
patterns that matched nothing. The session (a later layer) turns this into
events — a loud SKIP line per excluded file, a warning per stale pattern. This
module reads and prints nothing.
"""


@fieldwise_init
struct ExcludedEntry(Copyable, Movable):
    """One excluded file: the path removed and the pattern that removed it.

    Owns its strings, so copies are explicit; the session emits one loud SKIP
    line from each entry. Reads do not mutate or raise.
    """

    var path: String
    """The root-relative path of the excluded file."""

    var pattern: String
    """The `--exclude` glob that matched and removed `path`."""


@fieldwise_init
struct DiscoveryResult(Copyable, Movable):
    """The concrete, ordered file set a session will run.

    Deliberately `Copyable, Movable` but not `ImplicitlyCopyable`: it owns
    several `List`s, so every copy is a visible `.copy()` in review. Reads do
    not mutate or raise.
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
