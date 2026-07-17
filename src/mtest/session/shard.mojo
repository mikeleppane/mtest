"""The stateless, deterministic `--shard` partition of the session layer (L4).

CI sharding splits the discovered RUN-FILE set across `N` shards so shard `M`
runs a fixed, disjoint slice of it and the union of all `N` shards is provably
the whole suite. The partition is PURE LOGIC — no I/O, no process, no clock — so
it is table-tested row by row in `tests/unit/test_session_shard.mojo`.

Two modes (see `mtest.config.ShardMode`):

- HASH (default): a file is owned by shard `M` iff `fnv1a64(path) % N == M - 1`.
  Assignment depends ONLY on the path bytes, so it is stable across machines and
  independent of discovery order — the whole point of hash sharding.
- SLICE: the eligible files (already sorted lexicographically by `discover`) are
  dealt round-robin; the file at sorted index `i` is owned iff `i % N == M - 1`.

The hash is canonical FNV-1a 64-bit with FROZEN constants (offset basis
`0xcbf29ce484222325`, prime `0x100000001b3`), hashing the LEXICAL root-relative
path string exactly as `discover` produced it — never a realpath or canonical
source, which would break cross-machine stability. The reference vectors are
pinned in the unit test; if the hash disagrees, the algorithm is wrong.

Everything here is pure and never raises. Grammar validation (`1 <= M <= N`)
lives in the cli parser; this module trusts its inputs.
"""
from mtest.config import ShardMode


comptime _FNV_OFFSET_BASIS: UInt64 = 0xCBF29CE484222325
"""The frozen FNV-1a 64-bit offset basis (the empty-string hash)."""

comptime _FNV_PRIME: UInt64 = 0x100000001B3
"""The frozen FNV-1a 64-bit prime."""


def fnv1a64(s: String) -> UInt64:
    """The canonical FNV-1a 64-bit hash of the string's UTF-8 bytes. Pure.

    `h = offset_basis; for each byte b: h = (h XOR b) * prime`, all in UInt64
    (arithmetic wraps modulo 2^64). Frozen constants — never "improve" the hash,
    it is a cross-machine contract. Reference vectors: `fnv1a64("") ==
    0xcbf29ce484222325`, `fnv1a64("a") == 0xaf63dc4c8601ec8c`, `fnv1a64("foobar")
    == 0x85944171f73967e8`.

    Args:
        s: The string whose UTF-8 bytes are hashed. Not mutated.

    Returns:
        The 64-bit FNV-1a hash. Does not raise.
    """
    var h = _FNV_OFFSET_BASIS
    for b in s.as_bytes():
        h = (h ^ UInt64(Int(b))) * _FNV_PRIME
    return h


def _owns_index(hash_or_index: UInt64, m: Int, n: Int) -> Bool:
    """Whether `hash_or_index % n == m - 1`. Pure; assumes `1 <= m <= n`."""
    return Int(hash_or_index % UInt64(n)) == m - 1


def shard_owns(path: String, mode: ShardMode, m: Int, n: Int) -> Bool:
    """Whether shard `m` of `n` owns `path` in HASH mode. Pure.

    Only meaningful for HASH mode — SLICE ownership is by list index, which a
    lone path does not carry; use `partition` for slice sharding. Assumes a
    validated `1 <= m <= n` (the cli parser enforces the grammar).

    Args:
        path: The lexical root-relative path (a `disc.run_files` element).
        mode: The shard mode; only `ShardMode.HASH` is honored here.
        m: This shard's 1-based index.
        n: The total shard count.

    Returns:
        True iff `fnv1a64(path) % n == m - 1`. Does not raise.
    """
    return _owns_index(fnv1a64(path), m, n)


def partition(
    var files: List[String], mode: ShardMode, m: Int, n: Int
) -> List[String]:
    """The subset of `files` owned by shard `m` of `n`, in input order. Pure.

    HASH mode assigns each file by `fnv1a64(path) % n`, ignoring its position;
    SLICE mode assigns by position `i % n` in the input list, ignoring the hash.
    In both modes the returned subset preserves the input order. The caller
    passes the already lexicographically sorted `disc.run_files` so slice
    ownership is by SORTED index. Assumes a validated `1 <= m <= n`.

    Args:
        files: The eligible run files (owned; consumed). Root-relative paths.
        mode: HASH (by path hash) or SLICE (by sorted index).
        m: This shard's 1-based index.
        n: The total shard count.

    Returns:
        Only the owned files, in the input order. Does not raise.
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
