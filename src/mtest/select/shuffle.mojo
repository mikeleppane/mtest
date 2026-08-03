"""Deterministic order randomization for `--shuffle`.

A tiny, frozen PRNG lives here rather than behind `std.random` so a seed is a
cross-invocation contract: the same seed reproduces the same file order in
every 1.x build, on every platform, regardless of stdlib changes.
"""


@fieldwise_init
struct SplitMix64(Copyable, Movable):
    """SplitMix64: one 64-bit state word, one output per step.

    The constants are frozen: a reproduce line quotes a seed, and changing
    the generator would silently change what that seed reproduces.
    """

    var state: UInt64
    """The generator state; advances by the golden-gamma increment per draw."""

    def next(mut self) -> UInt64:
        """Advance one step and return the next 64-bit output.

        Returns:
            The next pseudo-random 64-bit value.
        """
        self.state += 0x9E3779B97F4A7C15
        var z = self.state
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) * 0x94D049BB133111EB
        return z ^ (z >> 31)


def shuffle_strings(mut items: List[String], seed: UInt64):
    """Fisher-Yates-shuffle `items` in place, deterministically per seed.

    The draw is `next() % (i + 1)`: the modulo bias is bounded by
    len(items) / 2^64, unmeasurable at any real suite size, accepted in
    exchange for a loop that never rejects a draw and retries, and
    provably terminates.

    Args:
        items: The list reordered in place.
        seed: Any `UInt64` value; equal seeds produce equal orders.
    """
    var rng = SplitMix64(seed)
    var i = len(items) - 1
    while i > 0:
        var j = Int(rng.next() % UInt64(i + 1))
        if j != i:
            items.swap_elements(i, j)
        i -= 1
