"""The session-scoped BuildProducts registry (the `cache` layer, a leaf).

`mtest` builds each test file once, then may probe it (`--skip-all`) and run it —
and `collect`, `probe`, and `run` must all SHARE that one build. This registry is
the passive store that makes the sharing possible: a map keyed by root-relative
path, each entry carrying the built binary, the canonical source path `mojo build`
baked in (the report parser's identity key), and — once probed — the qualifying
collection listing.

It is a PURE data structure. It performs no building, probing, or I/O of its own;
the session drives those and records the results here. That keeps it trivially
unit-testable, and it is what the once-built / once-probed bookkeeping rests on:
the store holds the state, and the session's check-then-record pattern (build only
when `not has(rel)`) is what makes the build happen exactly once.

Storage is a `Dict[String, Int]` index into a `List[BuildProduct]`: the dict maps
a rel-path to its slot, so lookup is O(1) and `record_build` replaces a slot's
whole `BuildProduct` in place — an atomic entry replacement no prior field
survives, which is exactly what stale-name recovery (rebuild -> fresh entry)
relies on.
"""
from std.collections import Dict


@fieldwise_init
struct BuildProduct(Copyable, Movable):
    """One file's build (and, once probed, collection) state.

    A built product carries its binary and canonical source; a compile-error
    product carries only the captured compiler output and its `compile_error`
    flag set, which the session checks to skip probe and run.
    """

    var rel_path: String
    """The root-relative path — the registry key."""
    var binary_path: String
    """The built test binary (e.g. `build/bin/<mangled>`); empty on a compile
    error."""
    var canonical_source: String
    """The realpath `mojo build` baked into the child's report — the parser's
    identity key; empty on a compile error."""
    var compile_error: Bool
    """The build failed; the session short-circuits probe and run for this file.
    """
    var compile_output: String
    """The captured compiler stderr for the error message (empty if none)."""
    var probed: Bool
    """A `--skip-all` probe has run for this file."""
    var qualified: Bool
    """The probe qualified as a collection listing."""
    var listing: List[String]
    """The qualifying node-id names (empty unless probed and qualified)."""

    @staticmethod
    def built(
        rel_path: String, binary_path: String, canonical_source: String
    ) -> BuildProduct:
        """A freshly built, not-yet-probed product for `rel_path`."""
        return BuildProduct(
            rel_path,
            binary_path,
            canonical_source,
            False,
            String(""),
            False,
            False,
            List[String](),
        )

    @staticmethod
    def compile_error_product(
        rel_path: String, compile_output: String
    ) -> BuildProduct:
        """A compile-error product for `rel_path` carrying the compiler output.
        """
        return BuildProduct(
            rel_path,
            String(""),
            String(""),
            True,
            compile_output,
            False,
            False,
            List[String](),
        )


struct BuildRegistry(Movable):
    """A session-scoped map from root-relative path to its `BuildProduct`.

    Passive: callers `record_build` (insert or atomically replace an entry),
    `record_compile_error`, and `record_probe` (attach a probe result to an
    existing entry); `has`/`get`/`size` read it back. Owns its storage; a `get`
    returns a copy so the caller cannot mutate an entry behind the registry.
    """

    var _index: Dict[String, Int]
    """rel_path -> slot in `_items`."""
    var _items: List[BuildProduct]
    """The entries, in insertion order; a slot is replaced in place on rebuild."""

    def __init__(out self):
        """An empty registry."""
        self._index = Dict[String, Int]()
        self._items = List[BuildProduct]()

    def has(self, rel: String) -> Bool:
        """Whether an entry (built or compile-error) exists for `rel`."""
        return rel in self._index

    def get(self, rel: String) raises -> BuildProduct:
        """A copy of the entry for `rel`; the caller must `has(rel)` first.

        Raises:
            An error if no entry exists for `rel`.
        """
        var pos = self._index.get(rel)
        if not pos:
            raise Error("cache: get for absent rel '" + rel + "'")
        return self._items[pos.value()].copy()

    def record_build(mut self, product: BuildProduct):
        """Insert `product`, or atomically REPLACE the whole entry for its
        `rel_path`.

        On replacement no field of the prior entry survives — the probe state
        resets unless `product` itself carries it. This is what a stale-name
        rebuild relies on: a rebuild yields a completely fresh entry.
        """
        var pos = self._index.get(product.rel_path)
        if pos:
            self._items[pos.value()] = product.copy()
        else:
            self._index[product.rel_path] = len(self._items)
            self._items.append(product.copy())

    def record_compile_error(mut self, rel: String, compile_output: String):
        """Store a compile-error entry for `rel` (insert or replace)."""
        self.record_build(
            BuildProduct.compile_error_product(rel, compile_output)
        )

    def record_probe(
        mut self, rel: String, qualified: Bool, listing: List[String]
    ) raises:
        """Attach a probe result to the existing entry for `rel`.

        Sets `probed=True`, `qualified`, and `listing`. The entry must already
        exist — the session always builds before probing.

        Raises:
            An error naming `rel` if no entry exists for it.
        """
        var pos = self._index.get(rel)
        if not pos:
            raise Error("cache: record_probe for unbuilt rel '" + rel + "'")
        var idx = pos.value()
        self._items[idx].probed = True
        self._items[idx].qualified = qualified
        self._items[idx].listing = listing.copy()

    def size(self) -> Int:
        """The number of entries."""
        return len(self._items)
