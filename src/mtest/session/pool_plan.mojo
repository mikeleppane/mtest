"""Pure worker-count and build-token arithmetic for the parallel scheduler.

Layer 4, beneath the pool driver. Every function here is pure: it reads its
arguments, computes, and returns, touching no process, environment, or clock.
The one impure read — the machine's logical core count — is fed in as a
parameter so the resolver and the token budget are unit-pinnable against any
core count without a real machine to stand on.

Three decisions live here and nowhere else:

- The provisional `auto` worker count: `min(4, max(1, cores // 2))`. It is
  provisional because the sizing benchmark refines it later; until then it is a
  conservative half-the-cores capped at four.
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
"""


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
    """The provisional `auto` worker count for a machine with `cores` cores.

    `min(4, max(1, cores // 2))`: half the logical cores, never below one and
    never above four. Provisional — the sizing benchmark refines the ceiling
    later — and pure in `cores`, so it pins against any core count.

    Args:
        cores: The machine's logical core count.

    Returns:
        The auto worker count, in `1 ..= 4`.
    """
    return min(4, max(1, cores // 2))


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
