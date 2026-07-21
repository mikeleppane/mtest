"""The stateless, deterministic `--shard` partition.

CI sharding splits the discovered run-file set across `N` shards, so shard `M`
runs a fixed, disjoint slice of it and the union of all `N` shards is the whole
suite. The partition is pure logic: no I/O, no process, no clock.

Two modes (see `mtest.config.ShardMode`):

- HASH (default): a file is owned by shard `M` iff `fnv1a64(path) % N == M - 1`.
  Assignment depends only on the path bytes, so it is stable across machines and
  independent of discovery order.
- SLICE: the eligible files, already sorted lexicographically by `discover`, are
  dealt round-robin; the file at sorted index `i` is owned iff `i % N == M - 1`.

The hash is canonical FNV-1a 64-bit with frozen constants (offset basis
`0xcbf29ce484222325`, prime `0x100000001b3`), hashing the lexical root-relative
path string exactly as `discover` produced it, never a realpath or canonical
source. Realpaths vary between machines and would break cross-machine
stability.

Grammar validation (`1 <= M <= N`) lives in the cli parser; this module trusts
its inputs.
"""
from mtest.config import ShardMode


comptime _FNV_OFFSET_BASIS: UInt64 = 0xCBF29CE484222325
"""The frozen FNV-1a 64-bit offset basis (the empty-string hash)."""

comptime _FNV_PRIME: UInt64 = 0x100000001B3
"""The frozen FNV-1a 64-bit prime."""


def fnv1a64(s: String) -> UInt64:
    """The canonical FNV-1a 64-bit hash of the string's UTF-8 bytes.

    `h = offset_basis; for each byte b: h = (h XOR b) * prime`, all in UInt64,
    so the arithmetic wraps modulo 2^64. The constants are frozen: this hash is
    a cross-machine contract, and changing it repartitions every shard.

    Reference vectors: `fnv1a64("") == 0xcbf29ce484222325`, `fnv1a64("a") ==
    0xaf63dc4c8601ec8c`, `fnv1a64("foobar") == 0x85944171f73967e8`. They are
    verified in `tests/unit/test_session_shard.mojo`.

    Args:
        s: The string whose UTF-8 bytes are hashed.

    Returns:
        The 64-bit FNV-1a hash.
    """
    var h = _FNV_OFFSET_BASIS
    for b in s.as_bytes():
        h = (h ^ UInt64(Int(b))) * _FNV_PRIME
    return h


def _owns_index(hash_or_index: UInt64, m: Int, n: Int) -> Bool:
    """Whether `hash_or_index % n == m - 1`. Assumes `1 <= m <= n`."""
    return Int(hash_or_index % UInt64(n)) == m - 1


def shard_owns(path: String, m: Int, n: Int) -> Bool:
    """Whether shard `m` of `n` owns `path` by hash.

    Hash ownership only. SLICE ownership is by list index, which a lone path
    does not carry, so use `partition` for slice sharding. Assumes a validated
    `1 <= m <= n`, which the cli parser enforces.

    Args:
        path: The lexical root-relative path (a `disc.run_files` element).
        m: This shard's 1-based index.
        n: The total shard count.

    Returns:
        True iff `fnv1a64(path) % n == m - 1`.
    """
    return _owns_index(fnv1a64(path), m, n)


def partition(
    var files: List[String], mode: ShardMode, m: Int, n: Int
) -> List[String]:
    """The subset of `files` owned by shard `m` of `n`, in input order.

    HASH mode assigns each file by `fnv1a64(path) % n`, ignoring its position;
    SLICE mode assigns by position `i % n` in the input list, ignoring the hash.
    Both modes preserve the input order. Callers pass the already
    lexicographically sorted `disc.run_files`, so slice ownership is by sorted
    index. Assumes a validated `1 <= m <= n`.

    Args:
        files: The eligible root-relative run file paths. Consumed.
        mode: HASH (by path hash) or SLICE (by sorted index).
        m: This shard's 1-based index.
        n: The total shard count.

    Returns:
        Only the owned files, in the input order.
    """
    var owned = List[String]()
    for i in range(len(files)):
        var mine: Bool
        if mode == ShardMode.SLICE:
            mine = _owns_index(UInt64(i), m, n)
        else:
            mine = _owns_index(fnv1a64(files[i]), m, n)
        if mine:
            owned.append(files[i])
    return owned^
