"""Pure worker-count and build-token arithmetic for the parallel scheduler.

Layer 4, beneath the pool driver. Every function here is pure: it reads its
arguments, computes, and returns, touching no process, environment, or clock.
The one impure read — the machine's logical core count — is fed in as a
parameter so the resolver and the token budget are unit-pinnable against any
core count without a real machine to stand on.

Three decisions live here and nowhere else:

- The `auto` worker count: `max(1, cores // 2)` — half the logical cores, never
  below one. The sizing benchmark measured scaling that keeps paying well past a
  handful of workers, so there is no small ceiling; taking half rather than the
  whole machine is a politeness bound — it leaves cores for other work and holds
  the peak output-capture memory to `cores // 2 * 16 MiB` — not a compile-
  starvation limit.
- The clamp: the resolved count is the requested-or-auto count capped by the
  effective descriptor ceiling the exec layer reports. A clamp is loud — it
  names the ceiling — because a run that asked for more parallelism than the
  machine can honor should say so.
- The build token budget: `K = max(1, cores // min(workers, cores))` threads per
  build, so concurrent builds never oversubscribe the cores. A build acquires
  `K` tokens against a `cores`-wide budget and spawns `mojo build` with
  `--num-threads K`; a run takes no tokens. At `workers == 1` the budget is
  never consulted: the sequential path adds no `--num-threads` flag at all, so
  its build argv stays byte-identical to a single-worker run.

The `--serial` partition also lives here as pure list arithmetic: which run
files are pinned to the one-at-a-time serial pass and which stay in the parallel
batch, and which `--serial` globs matched no discovered file (stale). Both fold a
file list against the glob patterns via `fnmatch` and return, touching nothing
else, so they pin against any file set without a real run.
"""

from mtest.discover import fnmatch


@fieldwise_init
struct WorkerPlan(Copyable, Movable):
    """The resolved worker count and whether the effective cap clamped it.

    Plain integer and Bool fields with no owned resources, so copies and moves
    are trivial.
    """

    var resolved: Int
    """The worker count the run will actually use, in `1 ..= cap`."""
    var requested: Int
    """The count the caller asked for: `0` for `auto`, else the explicit `-n`."""
    var cap: Int
    """The effective descriptor ceiling the resolved count was capped by."""
    var clamped: Bool
    """Whether the requested-or-auto count exceeded the cap and was lowered."""

    def limiting_note(self) -> String:
        """The loud warning detail for a clamp, or empty when none applies.

        Returns:
            A sentence naming the requested count, the cap, and that the file
            descriptor ceiling is the limiting resource; empty when the plan
            did not clamp.
        """
        if not self.clamped:
            return String("")
        var asked = "auto" if self.requested <= 0 else String(self.requested)
        return (
            "requested "
            + asked
            + " workers but the environment's file-descriptor ceiling caps"
            " concurrency at "
            + String(self.cap)
            + "; running with "
            + String(self.resolved)
        )


def resolve_auto_workers(cores: Int) -> Int:
    """The `auto` worker count for a machine with `cores` cores.

    `max(1, cores // 2)`: half the logical cores, never below one. The sizing
    benchmark measured scaling that keeps paying past a handful of workers, so
    the count is not capped at a small ceiling; taking half rather than all the
    cores is a politeness bound — it leaves headroom for other work and holds the
    peak output-capture memory to `cores // 2 * 16 MiB` — not a starvation limit.
    Pure in `cores`, so it pins against any core count.

    Args:
        cores: The machine's logical core count.

    Returns:
        The auto worker count, at least one.
    """
    return max(1, cores // 2)


def resolve_workers(requested: Int, cores: Int, cap: Int) -> WorkerPlan:
    """Resolve the worker count from the request, the cores, and the cap.

    A non-positive `requested` means `auto`, which `resolve_auto_workers`
    decides from `cores`; a positive `requested` is the explicit `-n` count. The
    requested-or-auto count is then capped by `cap` (the exec layer's effective
    descriptor ceiling), and the plan records whether that cap lowered it.

    Args:
        requested: The caller's request: `0` (or negative) for `auto`, else the
            explicit worker count.
        cores: The machine's logical core count, feeding the `auto` resolver.
        cap: The effective descriptor ceiling, at least one.

    Returns:
        The resolved plan, with `resolved` in `1 ..= cap` and `clamped` set when
        the cap lowered the requested-or-auto count.
    """
    var want = resolve_auto_workers(cores) if requested <= 0 else requested
    if want < 1:
        want = 1
    var resolved = want
    var clamped = False
    if resolved > cap:
        resolved = cap
        clamped = True
    return WorkerPlan(resolved, requested, cap, clamped)


@fieldwise_init
struct SerialPartition(Movable):
    """A run-file list split by `--serial` pinning.

    Owns its two lists; copies are explicit.
    """

    var parallel: List[String]
    """Files matching no serial glob — the parallel batch, in input order."""
    var serial: List[String]
    """Files matching at least one serial glob — the serial pass, in input
    order."""


def partition_serial(
    files: List[String], globs: List[String]
) -> SerialPartition:
    """Split `files` into the parallel batch and the serial pass.

    A file matching at least one `--serial` glob (whole-path `fnmatch`, the same
    match `--exclude` uses) is pinned to the serial pass; every other file stays
    in the parallel batch. Each output preserves the input order as a stable
    sub-sequence, so the two batches together dispatch exactly the input files in
    their original relative order. Empty `globs` leaves every file parallel.

    Args:
        files: The run files actually dispatched to the pool, in order.
        globs: The `--serial` glob patterns; empty means no pinning.

    Returns:
        The parallel and serial sub-lists.
    """
    var parallel = List[String]()
    var serial = List[String]()
    for f in files:
        var pinned = False
        for g in globs:
            if fnmatch(f, g):
                pinned = True
                break
        if pinned:
            serial.append(f)
        else:
            parallel.append(f)
    return SerialPartition(parallel^, serial^)


def stale_serials(files: List[String], globs: List[String]) -> List[String]:
    """The `--serial` globs that matched no file in `files`, in glob order.

    A stale serial glob is reported with a loud warning exactly as a stale
    `--exclude` is: it names a pattern the run universe never satisfies, so the
    caller almost certainly mistyped it. Pure in both arguments.

    Args:
        files: The discovered run universe to test each glob against.
        globs: The `--serial` glob patterns.

    Returns:
        The subset of `globs` that matched nothing, in their original order.
    """
    var stale = List[String]()
    for g in globs:
        var matched = False
        for f in files:
            if fnmatch(f, g):
                matched = True
                break
        if not matched:
            stale.append(g)
    return stale^


def build_tokens(workers: Int, cores: Int) -> Int:
    """The per-build thread budget `K = max(1, cores // min(workers, cores))`.

    A build acquires `K` tokens against a `cores`-wide budget and spawns
    `mojo build --num-threads K`, so the concurrent builds' threads never
    exceed the cores: at most `cores // K == min(workers, cores)` builds run at
    once, each with `K` threads. Pure in both arguments.

    Args:
        workers: The resolved worker count.
        cores: The machine's logical core count.

    Returns:
        The per-build thread budget, at least one.
    """
    if cores < 1:
        return 1
    var denom = min(workers, cores)
    if denom < 1:
        denom = 1
    return max(1, cores // denom)
