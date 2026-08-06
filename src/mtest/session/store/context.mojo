"""The session's cache state and the key prefix every file forks from.

Layer 4 (`session`), inside `store`. `CacheContext` carries the partially fed
`KeyBuilder` a per-file key forks from, the walk memos, and the one switch that
turns the cache off for the rest of the session.

`collect_env_base` feeds frames 1-7 of the wire order — toolchain identity,
version, libraries, environment, root, build arguments — into `ctx.base`, which
is complete before the precompile loop runs. `finalize_includes` then forks
`base` into `ctx.prefix` and appends, per include root in order and then per
`-I` recorded out of the build arguments, an `include` frame followed by that
root's walked contents. `prefix` is what a per-file key forks from, which is why
`Sha256.copy()` forking a partially fed hasher is load-bearing: the shared
prefix is absorbed once per session, not once per file.

Hashing the compiler is the single most expensive thing the store does, so both
toolchain reads sit behind process-lifetime memos declared here.
"""
from std.ffi import _Global
from std.os import lstat, stat
from std.os.path import dirname, realpath

from mtest.cache import (
    ARG_FLAG,
    ARG_INCLUDE_DIR,
    ARG_UNKNOWN,
    KeyBuilder,
    classify_build_args,
    sha256_hex,
    unsafe_tag_reason,
)
from mtest.config import RunnerConfig
from mtest.exec import ExecRuntime, ProcessResult, ProcessSpec, run_supervised
from mtest.platform import (
    S_IFMT,
    S_IFREG,
    read_regular_file_bytes,
    resolve_executable,
)
from mtest.session.store.support import (
    _BIN_CAP,
    _absolute,
    _env_value,
    _list_sorted,
)
from mtest.session.store.tags import (
    TAG_ARG,
    TAG_ARG_FILE,
    TAG_ENV_MODULAR_CACHE_DIR,
    TAG_ENV_MODULAR_DERIVED_PATH,
    TAG_ENV_MODULAR_HOME,
    TAG_ENV_MODULAR_NVPTX_COMPILER_PATH,
    TAG_ENV_XDG_CACHE_HOME,
    TAG_INCLUDE,
    TAG_ROOT,
    TAG_TOOLCHAIN,
    TAG_TOOLCHAIN_LIB,
    TAG_TOOLCHAIN_LIB_CONTENT,
    TAG_TOOLCHAIN_LIB_COUNT,
    TAG_TOOLCHAIN_VERSION,
    _feed_optional,
    cache_key_tags,
)
from mtest.session.store.walk import (
    _SourceDirScan,
    _StatWitness,
    _names_contain,
    _walk_include_root_scanned,
)


comptime _VERSION_DEADLINE_MS = 5000
"""Deadline for the one `<compiler> --version` spawn, in milliseconds."""

comptime _ABSENT_MARK = "absent"
"""The `toolchain-lib-count` payload when there is no library directory.

Disjoint from every real count, which is decimal digits, so "no directory" and
"a directory holding N libraries" can never render alike.
"""


@fieldwise_init
struct _SourceDirMemo(Copyable, Movable):
    """One test-file directory's walk, computed once and reused by every file
    in it.

    Both walk variants live here side by side rather than one replacing the
    other, because a single directory can need both: a file that imports an
    omitted neighbour keys over the whole directory while its neighbours keep
    the precise key. Conflating them would silently promote every file in the
    directory to the conservative key the moment one file needed it.
    """

    var dir: String
    """The directory, relative to the invocation root."""

    var digest: String
    """The walk that omits the directory's discovered test files."""

    var full_digest: String
    """The walk that omits nothing, empty until some file in the directory needs
    it. Computed on demand: most directories never do."""

    var skip_modules: List[String]
    """Module names the omitting walk left out, for matching against a file's
    own imports."""

    var needs_full: Bool
    """True when something the omitting walk framed makes the omission unsafe
    for every file here, so `digest` must not be used at all."""

    var witnesses: List[_StatWitness]
    """The omitting walk's stat records, one per framed file and descended
    directory.

    Memoized with the digest and copied into every key that uses that digest:
    the walk runs once per directory per session, and a record that stayed here
    would protect the first file in the directory and no other.
    """

    var full_witnesses: List[_StatWitness]
    """The unomitted walk's stat records, empty until that walk runs."""


struct CacheContext(Movable):
    """The session's cache state: the key so far, the walk memos, and the off
    switch.

    Key material and nothing else — a run's compile admissions are accounted by
    `session.CacheAdmissions`, which the drivers own. One context per session,
    threaded `mut` through every path that can build. It is Movable and not
    Copyable on purpose: two contexts would mean two independent off switches,
    and the first-reason-wins rule only holds for a single owner.

    Examples:

    ```mojo
    from mtest.session.store import CacheContext, finalize_includes

    var ctx = CacheContext()
    ctx.disable("unrecognized build argument '--sysroot=/x'")
    ctx.disable("later symptom")  # ignored: the first cause is the actionable
    ```
    """

    var enabled: Bool
    """Whether the cache may be read or written at all."""

    var disable_reason: String
    """Why the cache is off, in words a user can act on; empty while enabled."""

    var warned: Bool
    """Whether the cache-off warning has already been emitted; it fires once."""

    var base: KeyBuilder
    """Frames 1-7, complete before the precompile loop runs."""

    var prefix: KeyBuilder
    """`base` plus every include walk. Valid only after `finalize_includes`;
    per-file keys fork from here."""

    var extra_walk_dirs: List[String]
    """Include directories found inside the build arguments (`-I <dir>`), in
    command-line order, walked by `finalize_includes` after the configured
    roots."""

    var include_imports: List[String]
    """Every module name the include roots' own sources import.

    Written by `finalize_includes` and read when a test directory decides
    whether it may omit its test files: a library under `-I` that bare-imports
    one of those names puts it back on the compiler's path, so the directory
    holding it must be walked whole. Duplicates are kept — the list is a handful
    of names per include root, and matching is a linear scan either way.
    """

    var include_unscannable: Bool
    """Whether some include-root source's imports could not be read at all.

    Such a source could name any omitted test file in the session, so every
    directory that omits anything is walked whole instead.
    """

    var source_dirs: List[_SourceDirMemo]
    """Test-file directories already walked this session, in first-use order.

    A list rather than a map: a session sees a handful of distinct directories,
    so a linear scan costs less than a hash and keeps the memo inspectable.
    """

    def __init__(out self):
        """Start an enabled context with empty builders and no memos."""
        self.enabled = True
        self.disable_reason = String("")
        self.warned = False
        self.base = KeyBuilder()
        self.prefix = KeyBuilder()
        self.extra_walk_dirs = List[String]()
        self.include_imports = List[String]()
        self.include_unscannable = False
        self.source_dirs = List[_SourceDirMemo]()

    @staticmethod
    def disabled(reason: String) -> CacheContext:
        """A context that is off from the start, with the warning suppressed.

        The `--no-cache` shape: the user asked for the cache to be off, so
        warning them that it is off would be noise. `warned` is therefore set,
        and every other caller of `disable` leaves it clear so the session emits
        exactly one `cache-off` warning.

        Args:
            reason: Why the cache is off.

        Returns:
            A disabled context with `warned` already set.
        """
        var ctx = CacheContext()
        ctx.enabled = False
        ctx.disable_reason = reason
        ctx.warned = True
        return ctx^

    def disable(mut self, reason: String):
        """Switch the cache off, keeping the first reason given.

        Idempotent. The first cause is the one the user can act on — an
        unrecognized flag, a missing file — while everything after it is a
        downstream symptom, so a later call never overwrites the reason.

        Args:
            reason: Why the cache is off. Ignored if it is already off.
        """
        if not self.enabled:
            return
        self.enabled = False
        self.disable_reason = reason


def refuse_unsafe_tags(mut ctx: CacheContext, tags: List[String]) -> Bool:
    """Switch the cache off when `tags` cannot frame a key safely.

    The store's fail-closed channel for the one key hazard that lives in
    mtest's own source rather than in the tree it is keying: a base tag wearing
    one of the suffixes `feed_file` derives makes two different builds key alike
    and serves a stale binary, and an empty or NUL-bearing tag names a
    contribution nothing can quote back. `KeyBuilder` cannot refuse any of them
    — `feed` and `feed_file` are total by contract, as is every caller of theirs
    here — so the namespace that declares the tags refuses on their behalf,
    before a single frame is fed.

    Args:
        ctx: The session's cache state, switched off when a tag is unsafe.
        tags: The declared tag namespace, normally `cache_key_tags()`.

    Returns:
        True when the cache was switched off, which is also the caller's signal
        to stop: a namespace this run cannot frame will not become safe later.
    """
    var reason = unsafe_tag_reason(tags)
    if reason == "":
        return False
    ctx.disable(reason)
    return True


@fieldwise_init
struct _ToolchainDigest(Copyable, Movable):
    """One compiler binary's identity: which file, how long, and its digest.

    The triple frame 2 keys on, and what `_toolchain_identity` hands back on
    every path — a cold read and a memo hit produce the same three values. It is
    NOT what the memo stores; see `_ToolchainMemo` for why that is a separate,
    heap-free type.
    """

    var path: String
    """The canonical path the digest was taken from."""

    var size: Int
    """The number of bytes actually read and hashed."""

    var sha_hex: String
    """The 64-hex SHA-256 of those bytes."""


comptime _MEMO_PATH_CAP = 4096
"""Bytes of compiler path `_ToolchainMemo` can hold inline.

`PATH_MAX` is 4096 on Linux and 1024 on Darwin, both counting the terminating
NUL, and a `realpath` result is bounded by it, so every canonical compiler path
this runner can resolve fits here with a byte to spare. The number is a capacity
and not a precondition: `_ToolchainMemo.of` refuses a path that does not fit
rather than truncating it, so getting the bound wrong costs one recomputation
per session and can never produce a false hit.
"""

comptime _MEMO_SHA_LEN = 64
"""Hex digits `_ToolchainMemo` reserves for the memoized digest.

SHA-256 is 32 bytes and `sha256_hex` renders each as two lowercase hex digits,
so 64 is a property of the algorithm rather than of any input.
`_ToolchainMemo.of` re-checks the length anyway and refuses anything else,
because a digest of a different length is not one this record can represent.
"""


struct _ToolchainMemo(Copyable, Movable):
    """A `_ToolchainDigest` flattened into fixed-width storage, owning no heap.

    Exists so `_TOOLCHAIN_MEMO` below can hold a compiler's identity without
    holding an allocation. A process-lifetime memo is never torn down — there is
    no exit hook to run and nothing to run it — so a `String` field there is
    still live when the process calls `exit`, LeakSanitizer reports it as a
    direct leak, and the ASan lane fails a run in which nothing actually went
    wrong. Every field here is inline, so the slot owns nothing to report. What
    callers get back is still a `_ToolchainDigest`: rebuilding its 64-character
    digest on a hit costs one small allocation that its owner frees normally,
    against the 141 MB read it replaces.

    The path is compared byte for byte rather than through a digest of its own.
    A digest would be smaller but would need a collision argument, and this
    module's contract is that every question it cannot answer exactly resolves
    against the cache; comparing the whole path needs no such argument, because
    two compilers that are not the same file cannot be spelled the same way.
    """

    var path: InlineArray[UInt8, _MEMO_PATH_CAP]
    """The canonical path's bytes. Only the leading `path_len` are meaningful;
    the rest is the fill this record was constructed with."""

    var path_len: Int
    """How many bytes of `path` are in use. Zero means "nothing memoed yet", a
    state no real record can reach because `of` refuses an empty path."""

    var size: Int
    """The number of bytes actually read and hashed under that path."""

    var sha: InlineArray[UInt8, _MEMO_SHA_LEN]
    """The digest's hex characters. Meaningful only when `path_len` is
    nonzero."""

    def __init__(out self):
        """Start empty, so the first lookup in a process always misses."""
        self.path = InlineArray[UInt8, _MEMO_PATH_CAP](fill=0)
        self.path_len = 0
        self.size = 0
        self.sha = InlineArray[UInt8, _MEMO_SHA_LEN](fill=0)

    @staticmethod
    def of(
        path: String, size: Int, sha_hex: String
    ) -> Optional[_ToolchainMemo]:
        """The memoizable form of one digest, or nothing when it does not fit.

        Total by construction: nothing is truncated and nothing is approximated,
        so a record that comes back is exact and one that does not come back
        simply is not stored. Refusing costs the next session in this process a
        recomputation, which is the same price an unreachable memo already pays.

        Args:
            path: The canonical path the digest was taken from. An empty path is
                refused, because zero length is this record's "empty" marker.
            size: The number of bytes read and hashed.
            sha_hex: The digest rendering, which must be exactly
                `_MEMO_SHA_LEN` characters.

        Returns:
            The fixed-width record, or `None` when the path is empty, the path
            is longer than `_MEMO_PATH_CAP`, or the digest is not
            `_MEMO_SHA_LEN` characters.
        """
        var path_bytes = path.as_bytes()
        var sha_bytes = sha_hex.as_bytes()
        if len(path_bytes) == 0 or len(path_bytes) > _MEMO_PATH_CAP:
            return None
        if len(sha_bytes) != _MEMO_SHA_LEN:
            return None
        var memo = _ToolchainMemo()
        for i in range(len(path_bytes)):
            memo.path[i] = path_bytes[i]
        memo.path_len = len(path_bytes)
        memo.size = size
        for i in range(_MEMO_SHA_LEN):
            memo.sha[i] = sha_bytes[i]
        return Optional(memo^)

    def matches(self, path: String, size: Int) -> Bool:
        """Whether this record was taken from `path` at exactly `size` bytes.

        Args:
            path: The canonical path being looked up.
            size: The byte count `stat` reports for it now.

        Returns:
            True only for a populated record whose stored path and size both
            equal the arguments. An empty record matches nothing.
        """
        if self.path_len == 0 or self.size != size:
            return False
        var bytes = path.as_bytes()
        if len(bytes) != self.path_len:
            return False
        for i in range(self.path_len):
            if self.path[i] != bytes[i]:
                return False
        return True

    def sha_hex(self) raises -> String:
        """Rebuild the memoized digest as an owned string.

        Returns:
            The `_MEMO_SHA_LEN` stored characters, allocated fresh for the
            caller to own.

        Raises:
            Error: The stored bytes are not well-formed UTF-8, which no digest
                this module wrote can be. Raising rather than reinterpreting
                keeps the checked `from_utf8` decoder here instead of an unsafe
                one, and the single caller already treats any failure to reach
                the memo as a reason to recompute.
        """
        return String(StringSlice(from_utf8=Span(self.sha)))


def _no_toolchain_memo() -> _ToolchainMemo:
    """The empty memo slot every process starts with.

    Returns:
        A record whose zero `path_len` matches no real compiler, so the first
        lookup always misses.
    """
    return _ToolchainMemo()


comptime _TOOLCHAIN_MEMO = _Global[
    "mtest_store_toolchain_digest", _no_toolchain_memo
]
"""The process-lifetime memo for the compiler's content digest.

Hashing the compiler is the single most expensive thing this module does — on a
141 MB toolchain, roughly 0.7 s optimized and some twenty times that in the
unoptimized test lane — and it is recomputed identically by every session in a
process. One session per process is the production shape, so this buys
production nothing; the aggregate test binary, which drives many sessions back
to back, is what it is for.

Deliberately IN-PROCESS ONLY. An on-disk memo keyed by path, size, and mtime
was considered and rejected: it would survive a toolchain swap that preserved
those three fields, turning the one input that identifies the compiler into a
poisonable indirection. This memo dies with the process that made it, so the
worst it can do is reuse a digest taken moments earlier by the same process.

`_Global` is stdlib-private at the pinned toolchain. It is used because Mojo
1.0.0b2 offers no other process-lifetime mutable slot without a foreign symbol,
and the pin means it cannot move underneath this code. The session layer is
single-threaded — concurrency in this runner is child PROCESSES, never threads —
so the unsynchronized read-modify-write below has no racing writer.

It holds `_ToolchainMemo` and not `_ToolchainDigest` because nothing ever frees
what a slot like this holds: the process exits with the last value still in it,
and a heap field there is a live allocation at `exit` that LeakSanitizer reports
and the ASan lane fails on. `_ToolchainMemo` is entirely inline, so the slot
owns no allocation and there is nothing to report.
"""


def _toolchain_identity(path: String) -> Optional[_ToolchainDigest]:
    """The compiler's size and digest, computed at most once per process.

    The memo hits only when the canonical path AND the byte count both match
    what was hashed before. The size comes from a `stat` that costs nothing next
    to the read it guards, and it catches every toolchain swap that changes the
    binary's length. It cannot catch a same-path, same-length replacement — but
    that would have to happen between two sessions of one live process, and the
    memo never outlives that process.

    The key bytes are unaffected either way: a hit returns exactly the `size`
    and `sha_hex` a miss would have recomputed, so a memoized run and a cold run
    frame identical bytes.

    Args:
        path: The compiler's canonical path, from `resolve_executable`.

    Returns:
        Its identity, or `None` when the file could not be stat'd or read —
        which the caller turns into a disabled cache.
    """
    var size: Int
    try:
        size = Int(stat(path).st_size)
    except:
        return None
    # Every memo touch is wrapped: `get_or_create_ptr` is fallible, and so is
    # decoding the stored digest, and a memo that cannot be reached must cost a
    # recomputation, never an answer. Both `except` arms therefore fall through
    # to the full read.
    try:
        var slot = _TOOLCHAIN_MEMO.get_or_create_ptr()
        if slot[].matches(path, size):
            return Optional(_ToolchainDigest(path, size, slot[].sha_hex()))
    except:
        pass
    var data: List[UInt8]
    try:
        data = read_regular_file_bytes(path, _BIN_CAP)
    except:
        return None
    # The read, not the stat, is the authority on length: if the file changed in
    # between, the digest and the size must describe the SAME bytes.
    var fresh = _ToolchainDigest(path, len(data), sha256_hex(data))
    # A path too long to store inline is memoized not at all rather than
    # partially: the next session in this process re-reads the compiler, the
    # exact price an unreachable memo already pays.
    var memo = _ToolchainMemo.of(fresh.path, fresh.size, fresh.sha_hex)
    if memo:
        try:
            _TOOLCHAIN_MEMO.get_or_create_ptr()[] = memo.value().copy()
        except:
            pass
    return Optional(fresh^)


comptime _TOOLCHAIN_LIB_MEMO = _Global[
    "mtest_store_toolchain_lib_digest", _no_toolchain_memo
]
"""The process-lifetime memo for the toolchain library directory's contents.

The same reasoning as `_TOOLCHAIN_MEMO`, on the same record type and for the
same reason it is heap-free: a process-lifetime slot is never torn down, so a
`String` in it is a live allocation at `exit` that LeakSanitizer reports and the
ASan lane fails on. Its `path` field holds the library directory and its `size`
field the total number of bytes the regular files in it hold, which is what a
lookup re-establishes by `lstat` before deciding to skip the reads.

That leaves one thing uncaught, and it is the same one the compiler memo
carries: a replacement preserving both the path and the total byte count,
between two sessions of one LIVE process. The names, types, and individual
sizes of the entries are framed fresh on every session and do not go through
here, so a listing that changes at all still moves the key.
"""


@fieldwise_init
struct _LibEntry(Copyable, Movable):
    """One entry of the toolchain library directory, characterized no-follow."""

    var name: String
    """The entry's name inside the directory."""

    var kind: Int
    """Its `st_mode` file-type bits, from `lstat`: a symlink reads as a symlink
    rather than as whatever it points at."""

    var size: Int
    """Its byte count; meaningful for a regular file and ignored otherwise."""


@fieldwise_init
struct _LibListing(Copyable, Movable):
    """A toolchain library directory's entries, or which of two absences it is.

    The two absences are not interchangeable. A toolchain that ships no library
    directory keys perfectly well — the compiler's own digest still identifies
    it, and the `--mojo <wrapper>` shape puts the compiler somewhere nothing
    else looks like a toolchain. A library directory that exists but will not
    open is a build input this key cannot represent, and the cache has to go
    off. `isdir` answers False to both, which is why this type exists.
    """

    var readable: Bool
    """Whether `names` describes the directory. False in both other states."""

    var absent: Bool
    """Whether the directory is provably not there. Read only when `readable`
    is False; False there means the question could not be answered at all,
    which resolves the same way as unreadable."""

    var names: List[String]
    """The directory's entries in byte order; empty unless `readable`."""


def _toolchain_lib_listing(bin_dir: String) -> _LibListing:
    """List `<bin_dir>/../lib/mojo`, separating "not there" from "cannot read".

    `lstat` cannot make that separation: it raises both for a path that is not
    there and for one whose parent this process may not search. A listing of
    the PARENT can, because a listing that comes back is itself proof the
    parent was readable, and the name either appears in it or does not. So the
    walk up happens only when the directory below refused, and it stops at the
    directory the compiler was just read out of.

    Args:
        bin_dir: The directory holding the resolved compiler.

    Returns:
        The entries, or which absence this is.
    """
    var lib_root = bin_dir + "/../lib"
    var listed = _list_sorted(lib_root + "/mojo")
    if listed:
        return _LibListing(True, False, listed.value().copy())
    var parent = _list_sorted(lib_root)
    if parent:
        return _LibListing(
            False, not _names_contain(parent.value(), "mojo"), List[String]()
        )
    var grandparent = _list_sorted(bin_dir + "/..")
    if grandparent:
        return _LibListing(
            False,
            not _names_contain(grandparent.value(), "lib"),
            List[String](),
        )
    # Not even the toolchain's own prefix would list. Nothing here is provable,
    # and an unprovable input is a disabled cache.
    return _LibListing(False, False, List[String]())


def _toolchain_lib_entries(
    lib_dir: String, names: List[String]
) -> Optional[List[_LibEntry]]:
    """Characterize every entry of the toolchain library directory, no-follow.

    Args:
        lib_dir: The directory the names came from.
        names: Its entries in byte order, from `_toolchain_lib_listing`.

    Returns:
        One record per name, in the same order, or `None` when any entry could
        not be characterized — which the caller turns into a disabled cache,
        because an entry it cannot describe is a toolchain input the key cannot
        represent.
    """
    var out = List[_LibEntry]()
    for entry in names:
        var name = String(entry)
        var info: _LibEntry
        try:
            var st = lstat(lib_dir + "/" + name)
            info = _LibEntry(name^, Int(st.st_mode) & S_IFMT, Int(st.st_size))
        except:
            return None
        out.append(info^)
    return Optional(out^)


def _toolchain_lib_content(
    lib_dir: String, entries: List[_LibEntry]
) -> Optional[String]:
    """The digest of every REGULAR file in the toolchain library directory.

    Every regular file, not the two extensions the compiler's own packages
    happen to use: what ships beside those packages is as much a part of the
    toolchain as they are, and an extension list is a guess that goes stale the
    next time the toolchain ships something new. Non-regular entries contribute
    nothing here — the caller frames each entry's name and type separately, so
    their presence is keyed without anything following a link.

    Computed at most once per process, on the same argument as
    `_toolchain_identity`: one library directory serves every session in a
    process, and the aggregate test binary drives many sessions back to back.
    The memo hits only when the directory path AND the total byte count both
    match, and the byte counts come from an `lstat` per entry that the caller
    already needed.

    Args:
        lib_dir: The directory, absolute.
        entries: Its characterized entries, in byte order.

    Returns:
        The 64-hex digest, or `None` when a regular file could not be read.
    """
    var total = 0
    for entry in entries:
        if entry.kind == S_IFREG:
            total += entry.size
    try:
        var slot = _TOOLCHAIN_LIB_MEMO.get_or_create_ptr()
        if slot[].matches(lib_dir, total):
            return Optional(slot[].sha_hex())
    except:
        pass
    var kb = KeyBuilder()
    var read_bytes = 0
    for entry in entries:
        if entry.kind != S_IFREG:
            continue
        var name = String(entry.name)
        var data: List[UInt8]
        try:
            data = read_regular_file_bytes(lib_dir + "/" + name, _BIN_CAP)
        except:
            return None
        read_bytes += len(data)
        kb.feed_file(TAG_TOOLCHAIN_LIB, name, len(data), sha256_hex(data))
    var digest = kb^.digest_full()
    # Memoized against what was actually READ, never against what `lstat` said:
    # if a file changed length between the two, the digest and the byte count
    # have to describe the same bytes or the next lookup would hit on a
    # mismatch it cannot see.
    var memo = _ToolchainMemo.of(lib_dir, read_bytes, digest)
    if memo:
        try:
            _TOOLCHAIN_LIB_MEMO.get_or_create_ptr()[] = memo.value().copy()
        except:
            pass
    return Optional(digest^)


def collect_env_base(
    mut runtime: ExecRuntime, config: RunnerConfig, root: String
) -> CacheContext:
    """Build the session's key base from the toolchain, environment, and args.

    Called once, BEFORE the precompile loop, because everything it covers is
    fixed for the whole session: which compiler will run, what it reports as its
    version, which libraries ship beside it, the two environment variables that
    move its module cache, where the run is rooted, and how it was told to
    build. Frames land in the order the module docstring pins.

    Three checks run first, before anything is hashed or spawned, because they
    can only ever produce a disabled context and all three are cheap: a tag
    namespace that cannot be framed, an unrecognized build argument, and a
    compiler spelling that will not resolve. Skipping the 141 MB compiler digest
    on those paths is an optimization only — a disabled context's `base` is
    never finalized and never keyed.

    Args:
        runtime: An OPEN exec runtime; one `<compiler> --version` child is run
            on it under a 5 s deadline. Ownership is not taken.
        config: The run's config; `mojo_path` and `build_args` are read.
        root: The invocation root, canonicalized into the key.

    Returns:
        An enabled context whose `base` carries frames 1-7, or a disabled one
        whose `disable_reason` names what could not be established. Never
        raises: every filesystem and process failure becomes a disabled
        context, because the safe answer to "I cannot tell" is always "do not
        use the cache", and a caller forced to handle an error would have to
        invent that answer itself.

    Examples:

    ```mojo
    from mtest.session.store import collect_env_base, finalize_includes

    var ctx = collect_env_base(runtime, config, root)
    # ... precompile loop widens `includes` ...
    finalize_includes(ctx, root, includes)
    ```
    """
    # --- Fail-closed pre-checks: no digest, no spawn. -----------------------
    # Both use `disable`, never `CacheContext.disabled`: the latter presets
    # `warned` and belongs to `--no-cache` alone, where silence is what the user
    # asked for. A cache turned off by something in the environment is a fact
    # the user did not choose and cannot see any other way, so it has to reach
    # the session's one `cache-off` warning.
    var ctx = CacheContext()
    # Cheapest of the three and first: a namespace that cannot be framed makes
    # every key it would produce untrustworthy, so nothing below is worth
    # reading.
    if refuse_unsafe_tags(ctx, cache_key_tags()):
        return ctx^
    var rows = classify_build_args(config.build_args)
    for row in rows:
        if row.kind == ARG_UNKNOWN:
            # An unrecognized flag may change what gets built in a way no frame
            # here can see. Hashing the rest would produce a confident key for
            # an unknown build.
            ctx.disable("unrecognized build argument '" + row.value + "'")
            return ctx^
    # A spelling containing `/` is taken verbatim against a working directory
    # rather than PATH-searched, and the two processes involved do not share
    # one: the build child `chdir`s to `root` before `execve`, while resolution
    # here runs in mtest's own. `./tools/mojo` therefore names one file in the
    # key and executes another whenever the two differ, and even the cold
    # artifact is filed under the wrong compiler. Anchoring a relative spelling
    # to `root` makes the identity the one that will actually run. A bare
    # spelling is PATH-searched by both and needs no anchoring; an absolute one
    # is already unambiguous.
    var spelling = String(config.mojo_path)
    if "/" in spelling and not spelling.startswith("/"):
        spelling = root + "/" + spelling
    var resolved: Optional[String]
    try:
        resolved = resolve_executable(spelling)
    except:
        resolved = None
    if not resolved:
        # Keying on an unresolved spelling would name a compiler that may not be
        # the one the supervisor spawns.
        ctx.disable("cannot resolve the compiler '" + config.mojo_path + "'")
        return ctx^
    var compiler = resolved.value()

    # --- Frame 2: toolchain identity. ---------------------------------------
    var identity = _toolchain_identity(compiler)
    if not identity:
        ctx.disable("cannot read the compiler at '" + compiler + "'")
        return ctx^
    var toolchain = identity.value().copy()
    ctx.base.feed_file(
        TAG_TOOLCHAIN, compiler, toolchain.size, toolchain.sha_hex
    )

    # --- Frame 3: toolchain version. ----------------------------------------
    # The digest above already pins the executable; the banner additionally
    # pins what that executable *says* it is, which is what moves when a
    # toolchain ships a differently configured build of the same binary.
    var version_argv: List[String] = [compiler, "--version"]
    var version: ProcessResult
    try:
        version = run_supervised(
            runtime,
            ProcessSpec.command(version_argv^, _VERSION_DEADLINE_MS),
        )
    except:
        ctx.disable("could not run '" + compiler + " --version'")
        return ctx^
    if (
        not version.termination.is_exited()
        or version.termination.value != 0
        or version.stdout_truncated
    ):
        ctx.disable("'" + compiler + " --version' did not report cleanly")
        return ctx^
    # Fed as raw bytes: the banner is not this module's to decode, and a
    # toolchain that emits something that is not UTF-8 must still be keyed.
    ctx.base.feed(TAG_TOOLCHAIN_VERSION, version.stdout_bytes)

    # --- Frame 4: toolchain libraries. --------------------------------------
    var bin_dir = dirname(compiler)
    var lib_dir = bin_dir + "/../lib/mojo"
    # `_toolchain_lib_listing`, never `isdir`: `isdir` folds "not there" and
    # "cannot be read" into one False, and those two answers lead in opposite
    # directions here.
    var listing = _toolchain_lib_listing(bin_dir)
    if not listing.readable:
        if not listing.absent:
            ctx.disable(
                "cannot list the toolchain libraries at '" + lib_dir + "'"
            )
            return ctx^
        # A layout this module does not recognize is not an error: the compiler
        # digest still identifies the toolchain. The absence is recorded so a
        # later layout change cannot silently match a key built without it.
        ctx.base.feed_str(TAG_TOOLCHAIN_LIB_COUNT, _ABSENT_MARK)
    else:
        var entries = _toolchain_lib_entries(lib_dir, listing.names)
        if not entries:
            ctx.disable(
                "cannot characterize the toolchain libraries at '"
                + lib_dir
                + "'"
            )
            return ctx^
        var rows = entries.value().copy()
        # Every entry, not only the ones whose names end in a package
        # extension. Names and types are framed here and cost no read, so an
        # entry appearing, vanishing, or turning into a link moves the key; the
        # single content frame below covers the bytes of the regular ones and
        # is computed once per process.
        ctx.base.feed_str(TAG_TOOLCHAIN_LIB_COUNT, String(len(rows)))
        for row in rows:
            ctx.base.feed_str(
                TAG_TOOLCHAIN_LIB, String(row.kind) + ":" + row.name
            )
        var content = _toolchain_lib_content(lib_dir, rows)
        if not content:
            ctx.disable(
                "cannot read the toolchain libraries at '" + lib_dir + "'"
            )
            return ctx^
        ctx.base.feed_str(TAG_TOOLCHAIN_LIB_CONTENT, content.value())

    # --- Frame 5: environment. ----------------------------------------------
    # Each of these moves where the toolchain reads or writes something of its
    # own, so two runs that differ only here are not the same build: the first
    # three relocate the compiler's module cache and derived data, and the
    # fourth selects the NVIDIA assembler a GPU build invokes. `PATH` is
    # deliberately NOT among them — see the cache's non-goals in
    # `docs/cli-contract.md` for what that leaves uncovered and why keying it
    # would cost every hit for no gain.
    _feed_optional(ctx.base, TAG_ENV_MODULAR_HOME, _env_value("MODULAR_HOME"))
    _feed_optional(
        ctx.base, TAG_ENV_MODULAR_CACHE_DIR, _env_value("MODULAR_CACHE_DIR")
    )
    _feed_optional(
        ctx.base,
        TAG_ENV_MODULAR_DERIVED_PATH,
        _env_value("MODULAR_DERIVED_PATH"),
    )
    _feed_optional(
        ctx.base,
        TAG_ENV_MODULAR_NVPTX_COMPILER_PATH,
        _env_value("MODULAR_NVPTX_COMPILER_PATH"),
    )
    _feed_optional(
        ctx.base, TAG_ENV_XDG_CACHE_HOME, _env_value("XDG_CACHE_HOME")
    )

    # --- Frame 6: canonical root. -------------------------------------------
    var canonical_root: String
    try:
        canonical_root = realpath(root)
    except:
        ctx.disable("cannot canonicalize the run root '" + root + "'")
        return ctx^
    ctx.base.feed_str(TAG_ROOT, canonical_root)

    # --- Frame 7: classified build arguments, in command-line order. --------
    for row in rows:
        if row.kind == ARG_FLAG:
            ctx.base.feed_str(TAG_ARG, row.value)
        elif row.kind == ARG_INCLUDE_DIR:
            # The spelling is framed here so the argument's POSITION is keyed,
            # and the directory is recorded so `finalize_includes` walks its
            # contents. `-Ifoo` and `-I foo` normalize to one frame because
            # they are one instruction to the compiler.
            ctx.base.feed_str(TAG_ARG, "-I " + row.value)
            ctx.extra_walk_dirs.append(String(row.value))
        else:
            var arg_bytes: List[UInt8]
            try:
                arg_bytes = read_regular_file_bytes(
                    _absolute(root, row.value), _BIN_CAP
                )
            except:
                # `-Xlinker` accepts linker options as well as paths. A token
                # this cache cannot digest leaves its build effect unknown.
                ctx.disable(
                    "cache cannot characterize -Xlinker argument '"
                    + row.value
                    + "'"
                )
                return ctx^
            ctx.base.feed_file(
                TAG_ARG_FILE, row.value, len(arg_bytes), sha256_hex(arg_bytes)
            )
    return ctx^


def finalize_includes(
    mut ctx: CacheContext, root: String, includes: List[String]
):
    """Fork `base` into `prefix` and absorb every include root's contents.

    Called once, AFTER the precompile loop, because that loop widens the include
    set: a step's output directory becomes an include root for everything built
    later, so the set is not known until the loop has run. Configured roots come
    first in the order given, then the `-I` directories recorded out of the
    build arguments — the same order the compiler receives them.

    A walk that fails disables the cache; nothing here raises. Frames already
    fed into `prefix` at that point are simply abandoned, since a disabled
    context's `prefix` is never keyed.

    The walk also READS every source it frames, recording the modules those
    sources import into `ctx.include_imports`. That record is what closes the
    last way an omitted test file could enter a compile unseen: a library under
    `-I` that bare-imports a name matching a discovered test file makes that file
    a build input, and neither the entry file's own scan nor its directory's walk
    can see one hop out through an include root. `_source_dir_entry` matches its
    omitted names against the record and walks the directory whole when they
    meet. A source whose imports cannot be read at all sets
    `ctx.include_unscannable`, which withdraws every omission in the session.

    Args:
        ctx: The session context; `prefix` is written, the include-import record
            is filled, and the cache may be disabled.
        root: The invocation root each include root resolves against.
        includes: The include roots, in the order the compiler gets them.

    Examples:

    ```mojo
    from mtest.session.store import collect_env_base, finalize_includes

    var ctx = collect_env_base(runtime, config, root)
    finalize_includes(ctx, root, config.include_paths)
    ```
    """
    ctx.prefix = ctx.base.copy()
    if not ctx.enabled:
        return
    var dirs = includes.copy()
    for extra in ctx.extra_walk_dirs:
        dirs.append(String(extra))
    var scan = _SourceDirScan.collector()
    for entry in dirs:
        var dir = String(entry)
        ctx.prefix.feed_str(TAG_INCLUDE, dir)
        # A session include root's contents are sampled once per session, so
        # their window is the whole run and no publication can re-check them;
        # the records this walk offers have nothing to be compared against.
        var unwitnessed = List[_StatWitness]()
        var outcome = _walk_include_root_scanned(
            root, dir, ctx.prefix, "", scan, unwitnessed
        )
        if not outcome.ok:
            # The walk's own words, not a generic "unreadable": a symlinked
            # package and an unreadable file are different things to fix.
            ctx.disable("include root '" + dir + "': " + outcome.reason)
            return
    ctx.include_imports = scan.imports.copy()
    ctx.include_unscannable = scan.unscannable
