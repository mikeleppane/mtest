"""The private session temp directory both spooling reporters are handed.

`JunitReporter` and `ReportWriter` each stream one fragment per finished file
to disk instead of holding a whole document in memory, so each needs a fresh,
private, writable directory for the duration of a run. The requirements are
identical and the failure mode is subtle, so the creation lives here once
rather than once per reporter.

Deliberately avoids `std.tempfile.mkdtemp`: at the pinned toolchain its
candidate-name generator is unseeded, so every process walks the same name
sequence. In a shared `/tmp` those exact names already exist from earlier runs,
mkdtemp exhausts its internal attempts, and the feature dies before a single
test is built.
"""
from std.os import getenv, mkdir
from std.time import perf_counter_ns

from mtest.platform import process_id

comptime _SPOOL_ATTEMPTS = 64
"""How many distinct spool-directory names one call may try before giving up.

Every candidate re-reads the nanosecond clock, so a repeat needs two readings
to land on the same nanosecond; the budget therefore guards against an unusable
temp base rather than a collision rate.
"""


def _spool_nonce() -> String:
    """A per-process token isolating this run's spool paths.

    Two mtest processes writing the same destination, which `--shard` makes
    plausible, must never collide on a spool directory one's cleanup would
    delete. The process id is stable within a run and distinct across concurrent
    runs, so it keys each invocation's disposable paths apart.

    Returns:
        The process id, rendered in decimal.
    """
    return String(process_id())


def open_spool_dir(kind: String) raises -> String:
    """Create and return one run's private temp directory for fragments.

    The key is a monotonic nanosecond reading taken fresh on every attempt, with
    `mkdir`'s own atomic exclusive create as the arbiter, under an
    `mtest-<kind>-<pid>-` prefix that ties a stray directory back to the run
    that left it. The pid alone cannot be the key: pids recur across pid
    namespaces and after wraparound, so a fixed per-pid stem walked in index
    order would have to step over every leftover a previous same-pid run
    abandoned, which against a persisted `/tmp` reproduces the budget exhaustion
    this function exists to remove. A re-read clock cannot be walked into again.

    Honors `TMPDIR`, then `TEMP`, then `TMP`, falling back to `/tmp`. That is the
    same precedence `gettempdir()` applies behind the `mkdtemp()` this replaces,
    so confining a run's scratch keeps working exactly as it did before.

    Args:
        kind: The consumer's short name, used both in the directory prefix and
            in the failure message, so a stray directory and a diagnostic each
            say which reporter wanted it.

    Returns:
        The path of the freshly created, empty directory, mode 0o700. The
        caller owns it and is responsible for removing it.

    Raises:
        Error: When no candidate could be created within the attempt budget,
            because the temp base is missing, is not a directory, or is
            unwritable. The message carries the last underlying failure
            verbatim, since every one of those causes burns the whole budget
            identically and only the errno text tells them apart. The caller
            resolves this to the pre-run internal-error exit code.

    Examples:

    ```mojo
    from mtest.report.spool_dir import open_spool_dir

    var spool = open_spool_dir("junit")
    ```
    """
    var base = getenv("TMPDIR", "")
    if base == "":
        base = getenv("TEMP", "")
    if base == "":
        base = getenv("TMP", "")
    if base == "":
        base = String("/tmp")
    if base.byte_length() > 1 and base.endswith("/"):
        base = String(base.removesuffix("/"))
    var stem = base + "/mtest-" + kind + "-" + _spool_nonce() + "-"
    # Seeded so the raise below is always well-formed; the budget is positive,
    # so a real failure always overwrites this.
    var last = String("no attempt was made")
    for attempt in range(_SPOOL_ATTEMPTS):
        var candidate = stem + String(perf_counter_ns()) + "-" + String(attempt)
        try:
            mkdir(candidate, 0o700)
        except e:
            last = String(e)
            continue
        return candidate^
    raise Error(
        "report: could not create a "
        + kind
        + " spool directory under '"
        + base
        + "' ("
        + String(_SPOOL_ATTEMPTS)
        + " attempts; last: "
        + last
        + ")"
    )
