"""The build-artifact cache: what its key covers, when it switches itself off,
and the protocol that reads and writes the store.

Layer 4 (`session`). This module is where the persistent build cache touches the
world: it opens files, lists directories, canonicalizes paths, and spawns one
child, all through the Layer 0 `platform` boundary and the Layer 3 `exec`
supervisor. The framing it feeds — `KeyBuilder`, `Sha256`, the build-arg
grammar — is Layer 2 (`mtest.cache`) and stays pure; no read is ever pushed down
into it.

Two properties carry everything here.

**Fail closed.** A cache that is merely OFF costs a rebuild. A cache that is ON
when it should not be serves a stale binary and reports a green run that never
happened. So every question this module cannot answer resolves to
`ctx.disable(reason)`: an unrecognized build flag, a compiler that will not
resolve, a file that will not read, a directory that will not list. `disable` is
idempotent and the FIRST reason wins, because the first cause is the one the
user can act on; a later symptom would bury it.

**Frame order is the wire contract.** `KeyBuilder` frames each contribution as
tag bytes, one `0x00`, an eight-byte little-endian length, then the payload, so
the stream is self-delimiting and no payload can forge a boundary. What framing
does NOT do is make order irrelevant: two runs that feed the same facts in a
different order digest differently and lose every hit. The order below is
therefore fixed, and changing it invalidates every stored key:

1. `KEY_FORMAT_TAG` — an empty-payload frame `KeyBuilder.__init__` writes.
2. Toolchain identity — the resolved compiler's canonical path, size, and
   content digest.
3. Toolchain version — the raw bytes of `<compiler> --version` on stdout.
4. Toolchain libraries — a count frame (or the absence marker), then one file
   frame per `*.mojoc` / `*.mojopkg` in `<compiler dir>/../lib/mojo`, sorted.
5. Environment — `MODULAR_HOME` then `MODULAR_CACHE_DIR`, each as a
   present-or-absent frame.
6. The canonical invocation root.
7. The classified build arguments, in command-line order.

Frames 1-7 land in `ctx.base`, which is complete before the precompile loop
runs. `finalize_includes` then forks `base` into `ctx.prefix` and appends, per
include root in order and then per `-I` recorded out of the build arguments, an
`include` frame followed by that root's walked contents. `prefix` is what a
per-file key forks from, which is why `Sha256.copy()` forking a partially fed
hasher is load-bearing: the shared prefix is absorbed once per session, not once
per file.

**The tag namespace.** `KeyBuilder.feed` does not validate its tag, and
`feed_file` derives `tag + ".size"` and `tag + ".sha"` frames from the base tag
it is given. A tag holding a `0x00` byte would therefore forge a frame boundary,
and a base tag literally spelled `something.size` would collide with another
tag's derived frames — either way two different builds key alike and a stale
binary is served. The complete namespace is the `TAG_*` block below, and
`cache_key_tags` returns exactly it: anyone adding a tag adds it in that one
place, and `test_tag_namespace_is_frame_safe` re-checks the whole set.

**The store protocol.** `file_key` forks `prefix` and appends one `source`
frame, which names the generation `<mangled>_h<digest32>` under `STORE_DIR`.
`store_build_target` claims a private staging directory the compiler writes its
`-o` straight into, so publication is one `rename(2)` of a directory rather than
a copy — there is no half-published generation for a reader to observe, and the
bytes that were digested are the bytes that get committed. `store_probe` decides
whether a stored generation may be RUN, and is the one function here where a
mistake reports a green test run that never happened; every one of its questions
resolves toward `PROBE_MISS`, and a failed check deletes the generation so the
same corruption cannot be re-read next time. `store_publish` promotes a staged
build, guarding first that the source has not changed underneath the compile,
and re-probing in full — key AND binary digest — before adopting a generation
that won a rename race, because adopting an unvalidated winner is how a single
corrupt generation spreads to every process that loses to it.

Deletion inside the store goes through `remove_tree_no_follow`, which refuses a
symlinked root and unlinks child symlinks rather than descending them. The cache
deletes only what it owns, and it proves ownership with the `CACHEDIR.TAG`
marker written at `CACHE_ROOT_DIR` — above the store, because `--cache-clear`
deletes the whole owned directory and that is what must be proven mtest's.
"""
from std.ffi import _Global
from std.os import getenv, listdir, lstat, mkdir, rmdir, stat, unlink
from std.os.path import dirname, exists, isdir, realpath
from std.time import perf_counter_ns

from mtest.cache import (
    ARG_FILE_CANDIDATE,
    ARG_FLAG,
    ARG_INCLUDE_DIR,
    ARG_UNKNOWN,
    KEY_FORMAT_TAG,
    KeyBuilder,
    MetaFile,
    classify_build_args,
    generation_name,
    sha256_hex,
)
from mtest.config import RunnerConfig
from mtest.exec import ExecRuntime, ProcessResult, ProcessSpec, run_supervised
from mtest.platform import (
    close_checked_fd,
    create_unique_temp,
    fsync_path,
    process_id,
    read_bounded_regular_file,
    read_regular_file_bytes,
    rename_path,
    resolve_executable,
    write_all_fd,
)
from mtest.session.scratch import _ensure_dir, _mangle


comptime STORE_DIR = ".mtest-cache/build-v1"
"""The store's root, relative to the invocation root.

Dot-prefixed, which is what keeps `walk_include_root` out of it: an include root
of `.` would otherwise hash the cache's own contents into the key that decides
what the cache serves, and no run could ever hit twice.
"""

comptime _WALK_FILE_CAP = 64 * 1024 * 1024
"""Largest source or package file an include walk will digest, in bytes."""

comptime _BIN_CAP = 512 * 1024 * 1024
"""Largest binary the cache will digest, in bytes — compiler, library, or
artifact."""

comptime _VERSION_DEADLINE_MS = 5000
"""Deadline for the one `<compiler> --version` spawn, in milliseconds."""


# --- The tag namespace. THE one place. ---------------------------------------
#
# Every tag this module feeds is declared here. No tag may contain a `0x00`
# byte or end in `.size` or `.sha` (see the module docstring for why), and no
# two may be equal. `cache_key_tags` returns this set and the suite checks it.

comptime TAG_TOOLCHAIN = "toolchain"
"""The resolved compiler, as a file frame (adds `.size` and `.sha`)."""

comptime TAG_TOOLCHAIN_VERSION = "toolchain-version"
"""The raw stdout bytes of `<compiler> --version`."""

comptime TAG_TOOLCHAIN_LIB_COUNT = "toolchain-lib-count"
"""How many toolchain libraries were digested, or `absent` for no library
directory at all."""

comptime TAG_TOOLCHAIN_LIB = "toolchain-lib"
"""One toolchain library, as a file frame (adds `.size` and `.sha`)."""

comptime TAG_ENV_MODULAR_HOME = "env-MODULAR_HOME"
"""`MODULAR_HOME`, present-or-absent."""

comptime TAG_ENV_MODULAR_CACHE_DIR = "env-MODULAR_CACHE_DIR"
"""`MODULAR_CACHE_DIR`, present-or-absent."""

comptime TAG_ROOT = "root"
"""The canonicalized invocation root."""

comptime TAG_ARG = "arg"
"""One classified build argument that hashes verbatim."""

comptime TAG_ARG_FILE = "argfile"
"""One build argument naming a file, as a file frame (adds `.size` and
`.sha`)."""

comptime TAG_INCLUDE = "include"
"""One include root, named as configured, before its walk."""

comptime TAG_WALK_FILE = "walkfile"
"""One file an include walk found, as a file frame (adds `.size` and `.sha`).
Its path is relative to the walked root, so the same tree keys alike wherever
it is checked out."""

comptime TAG_SOURCE = "source"
"""The test file being keyed, as a file frame (adds `.size` and `.sha`). The one
frame `file_key` appends to the shared prefix, and therefore the only thing that
distinguishes two files of one session."""

comptime TAG_PRECOMPILE_STEP = "precompile-step"
"""One configured precompile step's source, named as configured, before its
walked closure. `precompile_key`'s only, and the frame that separates a step's
inputs from the include roots framed after them."""

comptime TAG_PRECOMPILE_OUT = "precompile-out"
"""One precompile step's output path, named as the compiler's `-o` receives it.

The spelling alone, never the contents: the output is what the step PRODUCES, so
digesting it would key the step on its own result.
"""

comptime TAG_PRECOMPILE_SRC = "precompile-src"
"""A precompile step's source when it is a single file, as a file frame (adds
`.size` and `.sha`). A directory source contributes `walkfile` frames instead."""

comptime TAG_PRECOMPILE_PRIOR = "precompile-prior"
"""One earlier step's promoted output, as a file frame (adds `.size` and
`.sha`).

Earlier steps run first and their packages are on this step's include path, so
they are inputs to it. They are framed explicitly rather than left to the include
walk, because the walk covers a directory and a prior output can be excluded from
one — or sit somewhere the walk never reaches.
"""

comptime TAG_PRECOMPILE_INCLUDE_ABSENT = "precompile-include-absent"
"""One include root that did not exist yet when the step was keyed.

`precompile_key`'s only, and the frame that keeps a cold tree from switching the
whole cache off. A configured `-I build` is ordinarily created BY a precompile
step, so on a first run the directory genuinely is not there when the step is
keyed — and "not there" is a fact about the build, not a failure to read one.

It is a positive frame rather than silence because absent and present-but-empty
must not key alike: if the directory later exists with contents, the walk emits
`walkfile` frames where this run emitted this one, so the key differs and the
next run takes a MISS rather than a stale hit.
"""


def cache_key_tags() -> List[String]:
    """Every tag the cache key uses, including the one `KeyBuilder` feeds itself.

    Exposed so the suite can re-check the whole namespace for frame safety
    rather than trusting a comment. A new tag belongs in the `TAG_*` block above
    and in this list; there is no third place to look.

    Returns:
        The complete tag set, in declaration order. Derived `.size` / `.sha`
        frames are not listed: they are `feed_file`'s, not a call site's.

    Examples:

    ```mojo
    from mtest.session.store import cache_key_tags

    for tag in cache_key_tags():
        pass  # assert it carries no NUL and ends in neither .size nor .sha
    ```
    """
    var tags: List[String] = [
        String(KEY_FORMAT_TAG),
        String(TAG_TOOLCHAIN),
        String(TAG_TOOLCHAIN_VERSION),
        String(TAG_TOOLCHAIN_LIB_COUNT),
        String(TAG_TOOLCHAIN_LIB),
        String(TAG_ENV_MODULAR_HOME),
        String(TAG_ENV_MODULAR_CACHE_DIR),
        String(TAG_ROOT),
        String(TAG_ARG),
        String(TAG_ARG_FILE),
        String(TAG_INCLUDE),
        String(TAG_WALK_FILE),
        String(TAG_SOURCE),
        String(TAG_PRECOMPILE_STEP),
        String(TAG_PRECOMPILE_OUT),
        String(TAG_PRECOMPILE_SRC),
        String(TAG_PRECOMPILE_PRIOR),
        String(TAG_PRECOMPILE_INCLUDE_ABSENT),
    ]
    return tags^


comptime _ABSENT_MARK = "absent"
"""The `toolchain-lib-count` payload when there is no library directory.

Disjoint from every real count, which is decimal digits, so "no directory" and
"a directory holding N libraries" can never render alike.
"""

comptime _MARK_ABSENT = UInt8(0)
"""Leading payload byte of a present-or-absent frame for an unset value."""

comptime _MARK_PRESENT = UInt8(1)
"""Leading payload byte of a present-or-absent frame for a set value."""

comptime _UNSET_PROBE_A = "\x01mtest-cache-env-probe-a"
"""One of two sentinels that tell an unset variable from an empty one."""

comptime _UNSET_PROBE_B = "\x01mtest-cache-env-probe-b"
"""The second sentinel; see `_env_value`."""


def _env_value(name: String) -> Optional[String]:
    """The environment variable `name`, or nothing when it is not set at all.

    `getenv` folds "unset" into its default, so one call cannot tell an absent
    variable from one set to the empty string — and for a cache key those are
    different facts about the environment the compiler ran in. Two probes with
    different defaults settle it without a foreign call: if the variable is set
    both probes return its value, and at most one of them can equal its own
    sentinel, so even a variable literally spelling one sentinel is reported
    correctly. Only a genuinely unset variable returns each default in turn.

    Args:
        name: The variable to read.

    Returns:
        Its value, the empty string included, or `None` when it is unset.
    """
    var first = getenv(name, _UNSET_PROBE_A)
    if first != _UNSET_PROBE_A:
        return Optional(first^)
    var second = getenv(name, _UNSET_PROBE_B)
    if second != _UNSET_PROBE_B:
        return Optional(second^)
    return None


def _feed_optional(mut kb: KeyBuilder, tag: String, value: Optional[String]):
    """Feed one present-or-absent frame.

    The payload leads with a marker byte, so an unset variable and one set to
    the empty string produce different payloads. The frame's length prefix
    already delimits, so the marker cannot be confused with value bytes.

    Args:
        kb: The builder to feed.
        tag: The contribution's name.
        value: The value, or `None` for "not set at all".
    """
    var payload = List[UInt8]()
    if value:
        payload.append(_MARK_PRESENT)
        var text = value.value()
        for b in text.as_bytes():
            payload.append(b)
    else:
        payload.append(_MARK_ABSENT)
    kb.feed(tag, payload)


def _absolute(root: String, path: String) -> String:
    """Resolve `path` against `root` unless it is already absolute.

    Args:
        root: The invocation root, itself absolute.
        path: An absolute path, or one relative to `root`.

    Returns:
        An absolute path. Not canonicalized: the spelling is what the compiler
        is given, and `realpath` is applied only where the key wants identity
        rather than spelling.
    """
    if path.startswith("/"):
        return String(path)
    return root + "/" + path


def _bytewise_less(a: String, b: String) -> Bool:
    """Whether `a` sorts before `b` by raw byte order.

    Paths are UTF-8 and byte order equals codepoint order there, so this is a
    correct, locale-free, dependency-free total order — and the order is part
    of the wire contract, which is why it is pinned here rather than delegated
    to a comparison whose semantics could change under the runner.

    Args:
        a: The left name.
        b: The right name.

    Returns:
        True iff `a` precedes `b`.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var an = len(ab)
    var bn = len(bb)
    var n = an if an < bn else bn
    for i in range(n):
        if ab[i] != bb[i]:
            return ab[i] < bb[i]
    return an < bn


def _sort_bytewise(mut names: List[String]):
    """Sort `names` in place into byte order (insertion sort).

    One directory's entries at a time, so an O(n^2) insertion sort is free and
    trivially deterministic. `listdir` returns filesystem order, which differs
    between machines and even between runs; without this the key would too.

    Args:
        names: The entry names, reordered in place.
    """
    for i in range(1, len(names)):
        var j = i
        while j > 0 and _bytewise_less(names[j], names[j - 1]):
            names.swap_elements(j, j - 1)
            j -= 1


def _is_source_name(name: String) -> Bool:
    """Whether `name` is a file `-I` on its directory would make available.

    Args:
        name: One directory entry's bare name.

    Returns:
        True for `*.mojo`, `*.🔥`, `*.mojopkg`, and `*.mojoc`. Anything else —
        a README, a lockfile, an editor swapfile — cannot change what the
        compiler produces and is deliberately left out, so unrelated churn in
        an include root does not evict the whole cache.
    """
    if name.endswith(".mojo") or name.endswith(".🔥"):
        return True
    return name.endswith(".mojopkg") or name.endswith(".mojoc")


@fieldwise_init
struct WalkOutcome(Copyable, Movable):
    """Whether an include walk covered its root, and if not, why not.

    A bare `False` was not enough once a symlinked package became its own
    disable condition rather than a generic read failure: the user has to be
    told which link to replace, and `cannot read the include root 'src'` does
    not say that.
    """

    var ok: Bool
    """True iff every reachable input was framed."""

    var reason: String
    """Why the walk could not cover its root; empty when `ok`."""

    @staticmethod
    def success() -> WalkOutcome:
        """A walk that covered everything.

        Returns:
            An outcome with `ok` set and no reason.
        """
        return WalkOutcome(True, String(""))

    @staticmethod
    def failure(reason: String) -> WalkOutcome:
        """A walk that did not cover everything.

        Args:
            reason: What could not be covered, in words a user can act on.

        Returns:
            An outcome with `ok` clear, carrying `reason`.
        """
        return WalkOutcome(False, reason)


comptime _S_IFMT = 0xF000
"""File-type mask over `st_mode`; POSIX fixes it on Linux and Darwin alike."""

comptime _S_IFDIR = 0x4000
"""`S_IFDIR`: the `st_mode` file-type value for a directory."""

comptime _S_IFLNK = 0xA000
"""`S_IFLNK`: the `st_mode` file-type value for a symbolic link."""


def _list_sorted(abs_dir: String) -> Optional[List[String]]:
    """The entries of `abs_dir` in byte order, or nothing if it cannot be read.

    `listdir` raises on failure — unlike `isdir` / `isfile`, which fold every
    error into `False` — so this is the one directory query in the module that
    can tell "empty" from "unreadable". Every place the walk needs to
    characterize a directory goes through it for exactly that reason.

    Args:
        abs_dir: The directory to read, absolute.

    Returns:
        The sorted entry names, or `None` when the directory could not be
        listed at all.
    """
    var names = List[String]()
    try:
        for entry in listdir(abs_dir):
            names.append(String(entry))
    except:
        return None
    _sort_bytewise(names)
    return Optional(names^)


def _has_init(names: List[String]) -> Bool:
    """Whether a directory listing contains an `__init__`, making it a package.

    Reads the listing rather than asking `isfile` twice: `isfile` cannot tell a
    missing `__init__.mojo` from one it was not permitted to stat, and those two
    answers must lead to opposite decisions.

    Args:
        names: One directory's entry names.

    Returns:
        True iff `__init__.mojo` or `__init__.🔥` is among them.
    """
    for name in names:
        if name == "__init__.mojo" or name == "__init__.🔥":
            return True
    return False


def _walk_into(
    abs_dir: String,
    rel_prefix: String,
    var names: List[String],
    mut kb: KeyBuilder,
    exclude_abs: String,
) -> WalkOutcome:
    """Feed one directory's contributions, recursing into package subdirectories.

    Args:
        abs_dir: The directory to read, absolute.
        rel_prefix: The path of `abs_dir` relative to the walked include root;
            empty at the top. Frames name files by this prefix, never by an
            absolute path, so the same tree keys alike in any checkout.
        names: `abs_dir`'s entries, already sorted — passed in because the
            caller had to list the directory to decide it was a package, and
            listing it twice would invite a mid-walk race between the two.
        kb: The builder to feed.
        exclude_abs: One absolute path to skip wherever met, or empty for none.

    Returns:
        A successful outcome once every reachable input is framed, or a failure
        naming the first thing this walk could not account for. Never raises: a
        half-read tree must not become a key.
    """
    for entry in names:
        var name = String(entry)
        # Dot entries are the runner's own scratch (`.mtest-cache`), the VCS
        # directory, and editor droppings. The compiler does not import them.
        if name.startswith("."):
            continue
        var full = abs_dir + "/" + name
        if exclude_abs != "" and full == exclude_abs:
            continue
        var rel = name if rel_prefix == "" else rel_prefix + "/" + name

        # `lstat` raises where `isdir` / `islink` answer False, which is the
        # whole point of using it: this name came out of a directory listing, so
        # it existed a moment ago. If it cannot be stat'd now it either vanished
        # mid-walk or sits under a directory this process may read but not
        # search (mode 0644) — and in that second case EVERY entry would answer
        # "not a directory, not a source file" and the walk would silently frame
        # nothing. A tree the walk cannot characterize must not key as an empty
        # one.
        var kind: Int
        try:
            kind = Int(lstat(full).st_mode) & _S_IFMT
        except:
            return WalkOutcome.failure(
                "cannot inspect '" + rel + "' (in '" + abs_dir + "')"
            )
        var is_link = kind == _S_IFLNK
        # For a link, the type that matters is the target's. A dangling link
        # answers False here and falls through to the file path below, where a
        # source-named one fails the read (correctly) and anything else is
        # ignored (also correctly — the compiler would not have read it either).
        var is_dir = kind == _S_IFDIR or (is_link and isdir(full))

        if is_dir:
            var listing = _list_sorted(full)
            if not listing:
                return WalkOutcome.failure(
                    "cannot read the directory '" + rel + "'"
                )
            var sub = listing.value().copy()
            # Without an `__init__`, `-I` on the parent does not reach inside,
            # so the contents cannot change the build and must not change the
            # key. That holds for a symlinked directory too, which is why the
            # package test comes first.
            if not _has_init(sub):
                continue
            if is_link:
                # A symlinked PACKAGE is imported by the compiler but cannot be
                # walked: descending it risks a cycle no lexical normalization
                # detects. Skipping it silently was the stale-hit hole — editing
                # the link's target would leave the key untouched and serve the
                # previous binary on a green run. So the cache goes off and says
                # which link to replace.
                return WalkOutcome.failure(
                    "package '"
                    + rel
                    + "' is reached through a directory symlink, which the"
                    " cache cannot walk safely"
                )
            var inner = _walk_into(full, rel, sub^, kb, exclude_abs)
            if not inner.ok:
                return inner^
            continue

        if not _is_source_name(name):
            continue
        var data: List[UInt8]
        try:
            data = read_regular_file_bytes(full, _WALK_FILE_CAP)
        except:
            # Over the cap, unreadable, or a dangling symlink. Each is a fact
            # about the build input this key cannot represent, so the walk
            # fails and the cache goes off rather than keying on a guess.
            return WalkOutcome.failure("cannot read the file '" + rel + "'")
        kb.feed_file(TAG_WALK_FILE, rel, len(data), sha256_hex(data))
    return WalkOutcome.success()


def walk_include_root(
    root: String, dir: String, mut kb: KeyBuilder, exclude: String
) -> WalkOutcome:
    """Feed everything `-I dir` makes visible to the compiler, in a fixed order.

    The walk mirrors what the import resolver can actually reach: every
    top-level `*.mojo` / `*.🔥` / `*.mojopkg` / `*.mojoc`, plus the same rule
    applied recursively inside each subdirectory that carries an `__init__`.
    Dot-prefixed entries are skipped, entries are visited in byte order, and
    each file contributes its path (relative to `dir`), its size, and its
    content digest.

    Symlinks are resolved by what the compiler would do with them. A symlinked
    directory that is NOT a package contributes nothing, because `-I` does not
    reach inside it either. A symlinked directory that IS a package fails the
    walk: the compiler imports it, so its contents belong in the key, but
    descending a link can close a cycle. Off is the only honest answer, and the
    reason names the link.

    Args:
        root: The invocation root; `dir` and `exclude` resolve against it.
        dir: The include root, as configured — absolute, or relative to `root`.
        kb: The builder to feed.
        exclude: One path to skip wherever the walk meets it, relative to `root`
            (an absolute path also works). Empty means nothing is excluded. A
            precompile step passes its own output here, so the key that decides
            whether the step runs does not depend on what the step produces.

    Returns:
        A successful outcome on a complete walk, or a failure carrying a reason
        — `dir` is not a readable directory, an entry could not be stat'd, a
        subdirectory could not be listed, a file could not be read, or a package
        hides behind a symlink. The caller's only correct response to a failure
        is to disable the cache, since a partial walk is a key that does not
        cover its inputs. Never raises.

    Examples:

    ```mojo
    from mtest.cache import KeyBuilder
    from mtest.session.store import walk_include_root

    var kb = KeyBuilder()
    var outcome = walk_include_root("/repo", "src", kb, "")
    if not outcome.ok:
        pass  # disable the cache, quoting `outcome.reason`
    ```
    """
    var abs_dir = _absolute(root, dir)
    var listing = _list_sorted(abs_dir)
    if not listing:
        return WalkOutcome.failure("'" + dir + "' is not a readable directory")
    var exclude_abs = String("") if exclude == "" else _absolute(root, exclude)
    return _walk_into(abs_dir, "", listing.value().copy(), kb, exclude_abs)


struct CacheContext(Movable):
    """The session's cache state: the key so far, the counters, and the off
    switch.

    One per session, threaded `mut` through every path that can build. It is
    Movable and not Copyable on purpose: two contexts would mean two sets of
    counters and two independent off switches, and the counter invariant
    (`built_files + cached_files == first-attempt compile admissions`) only
    holds for a single owner.

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

    var built_files: Int
    """First-attempt compile admissions, compile failures included."""

    var cached_files: Int
    """Cache-hit admissions."""

    def __init__(out self):
        """Start an enabled context with empty builders and zeroed counters."""
        self.enabled = True
        self.disable_reason = String("")
        self.warned = False
        self.base = KeyBuilder()
        self.prefix = KeyBuilder()
        self.extra_walk_dirs = List[String]()
        self.built_files = 0
        self.cached_files = 0

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


@fieldwise_init
struct _ToolchainDigest(Copyable, Movable):
    """One compiler binary's identity: which file, how long, and its digest."""

    var path: String
    """The canonical path the digest was taken from; `""` means "nothing memoed
    yet"."""

    var size: Int
    """The number of bytes actually read and hashed."""

    var sha_hex: String
    """The 64-hex SHA-256 of those bytes."""


def _no_toolchain_digest() -> _ToolchainDigest:
    """The empty memo slot every process starts with.

    Returns:
        A record whose empty `path` matches no real compiler, so the first
        lookup always misses.
    """
    return _ToolchainDigest(String(""), 0, String(""))


comptime _TOOLCHAIN_MEMO = _Global[
    "mtest_store_toolchain_digest", _no_toolchain_digest
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
    # Every memo touch is wrapped: `get_or_create_ptr` is fallible, and a memo
    # that cannot be reached must cost a recomputation, never an answer. Both
    # `except` arms therefore fall through to the full read.
    try:
        var slot = _TOOLCHAIN_MEMO.get_or_create_ptr()
        if slot[].path == path and slot[].size == size:
            return Optional(slot[].copy())
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
    try:
        _TOOLCHAIN_MEMO.get_or_create_ptr()[] = fresh.copy()
    except:
        pass
    return Optional(fresh^)


def collect_env_base(
    mut runtime: ExecRuntime, config: RunnerConfig, root: String
) -> CacheContext:
    """Build the session's key base from the toolchain, environment, and args.

    Called once, BEFORE the precompile loop, because everything it covers is
    fixed for the whole session: which compiler will run, what it reports as its
    version, which libraries ship beside it, the two environment variables that
    move its module cache, where the run is rooted, and how it was told to
    build. Frames land in the order the module docstring pins.

    Two checks run first, before anything is hashed or spawned, because they can
    only ever produce a disabled context and both are cheap: an unrecognized
    build argument, and a compiler spelling that will not resolve. Skipping the
    141 MB compiler digest on those paths is an optimization only — a disabled
    context's `base` is never finalized and never keyed.

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
    var rows = classify_build_args(config.build_args)
    for row in rows:
        if row.kind == ARG_UNKNOWN:
            # An unrecognized flag may change what gets built in a way no frame
            # here can see. Hashing the rest would produce a confident key for
            # an unknown build.
            ctx.disable("unrecognized build argument '" + row.value + "'")
            return ctx^
    var resolved: Optional[String]
    try:
        resolved = resolve_executable(config.mojo_path)
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
    var lib_dir = dirname(compiler) + "/../lib/mojo"
    if not isdir(lib_dir):
        # A layout this module does not recognize is not an error: the compiler
        # digest still identifies the toolchain. The absence is recorded so a
        # later layout change cannot silently match a key built without it.
        ctx.base.feed_str(TAG_TOOLCHAIN_LIB_COUNT, _ABSENT_MARK)
    else:
        var libs = List[String]()
        try:
            for entry in listdir(lib_dir):
                var name = String(entry)
                if name.endswith(".mojoc") or name.endswith(".mojopkg"):
                    libs.append(name^)
        except:
            ctx.disable(
                "cannot list the toolchain libraries at '" + lib_dir + "'"
            )
            return ctx^
        _sort_bytewise(libs)
        ctx.base.feed_str(TAG_TOOLCHAIN_LIB_COUNT, String(len(libs)))
        for lib in libs:
            var lib_name = String(lib)
            var lib_bytes: List[UInt8]
            try:
                lib_bytes = read_regular_file_bytes(
                    lib_dir + "/" + lib_name, _BIN_CAP
                )
            except:
                ctx.disable(
                    "cannot read the toolchain library '" + lib_name + "'"
                )
                return ctx^
            ctx.base.feed_file(
                TAG_TOOLCHAIN_LIB,
                lib_name,
                len(lib_bytes),
                sha256_hex(lib_bytes),
            )

    # --- Frame 5: environment. ----------------------------------------------
    # Both variables relocate the compiler's own module cache, so two runs that
    # differ only here are not the same build.
    _feed_optional(ctx.base, TAG_ENV_MODULAR_HOME, _env_value("MODULAR_HOME"))
    _feed_optional(
        ctx.base, TAG_ENV_MODULAR_CACHE_DIR, _env_value("MODULAR_CACHE_DIR")
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
                # The grammar took this token for a file; it is not one this run
                # can read, so what it contributes to the build is unknown.
                ctx.disable(
                    "build argument '"
                    + row.value
                    + "' does not name a readable file"
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

    Args:
        ctx: The session context; `prefix` is written and the cache may be
            disabled.
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
    for entry in dirs:
        var dir = String(entry)
        ctx.prefix.feed_str(TAG_INCLUDE, dir)
        var outcome = walk_include_root(root, dir, ctx.prefix, "")
        if not outcome.ok:
            # The walk's own words, not a generic "unreadable": a symlinked
            # package and an unreadable file are different things to fix.
            ctx.disable("include root '" + dir + "': " + outcome.reason)
            return


# --- The owned store: layout and the ownership marker. -----------------------

comptime CACHE_ROOT_DIR = ".mtest-cache"
"""The whole directory mtest owns, relative to the invocation root.

`STORE_DIR` lives inside it, and so does the last-run reselection state, which
is why the ownership marker sits HERE rather than beside the generations:
`--cache-clear` deletes this directory, so this is the directory whose ownership
has to be provable before anything is removed.
"""

comptime CACHEDIR_TAG_REL = ".mtest-cache/CACHEDIR.TAG"
"""The ownership marker, relative to the invocation root.

Spelled out rather than composed from `CACHE_ROOT_DIR`, because the pinned
toolchain's `comptime` bindings are literals; the two must agree, and
`test_marker_written_at_mtest_cache_root` checks the path that ships.
"""

comptime CACHEDIR_TAG_SIGNATURE = "Signature: 8a477f597d28d172789f06886806bc55"
"""The first line every `CACHEDIR.TAG` carries, per the cachedir convention.

Backup and archiving tools recognize this exact byte string and skip the
directory holding it — which is correct for a build cache, and a free side
effect of the marker mtest needs anyway to prove the directory is its own.
"""

comptime _BIN_NAME = "bin"
"""The generation's binary, inside the generation directory."""

comptime _META_NAME = "meta"
"""The generation's validation record, inside the generation directory."""

comptime _META_CAP = 1024 * 1024
"""Largest `meta` file the store will read, in bytes.

Generous next to a record of four short lines plus one per argv token, and
bounded so a garbage file cannot be read into memory in full before
`MetaFile.parse` rejects it.
"""

comptime _TMP_PREFIX = ".tmp-"
"""Leading component of every staging directory's name.

Dot-prefixed so an include walk skips it, and distinct from any generation name,
which always contains `_h` after a mangled source name. The reaper keys on this
so it can never delete a concurrent process's live staging directory.

A staging name carries a mangled source name too (see `store_build_target`), so
the `_h` half of that distinction is what carries the whole weight: `_mangle`
escapes every literal `_` as `_u`, and this prefix adds only `-` and decimal
digits around it, so `_h` cannot occur anywhere in a staging name.
"""

comptime _TMP_ATTEMPTS = 16
"""How many staging-directory names one call may try before giving up."""


def _cachedir_tag_text() -> String:
    """The marker file's full contents.

    Returns:
        The standard signature line, then two comment lines naming mtest as the
        owner and the convention as the reference.
    """
    var out = String(CACHEDIR_TAG_SIGNATURE) + "\n"
    out += "# This file is a cache directory tag created by mtest.\n"
    out += "# For information about cache directory tags, see"
    out += " https://bford.info/cachedir/\n"
    return out^


def _ensure_store(root: String) raises:
    """Create the store directory and, once, the ownership marker above it.

    The marker is written to a unique temporary file in its own directory and
    renamed onto its final name, so a concurrent run can never observe a
    half-written tag — and `--cache-clear`, whose entire safety argument is "the
    marker is present", can never be defeated by a torn write.

    Args:
        root: The invocation root the store hangs under.

    Raises:
        Error: If the directories cannot be created or the marker cannot be
            written. The caller turns that into "no staging target", which
            degrades to an uncached build.
    """
    _ensure_dir(root + "/" + STORE_DIR)
    var tag = root + "/" + CACHEDIR_TAG_REL
    if exists(tag):
        return
    var created = create_unique_temp(
        root + "/" + CACHE_ROOT_DIR + "/CACHEDIR.TAG.XXXXXX"
    )
    var wrote = True
    try:
        write_all_fd(created.fd, _cachedir_tag_text())
    except:
        wrote = False
    # The descriptor is discharged exactly once whether or not the write
    # succeeded; a failed write leaves only an empty temporary file behind.
    close_checked_fd(created.fd)
    if not wrote:
        raise Error(
            "session: could not write the cache ownership marker at '"
            + tag
            + "'"
        )
    rename_path(created.path, tag)


# --- No-follow deletion. -----------------------------------------------------


def _remove_dir_contents_no_follow(dir: String) raises:
    """Empty `dir`, unlinking child symlinks instead of following them.

    Args:
        dir: A real directory, already characterized by the caller.

    Raises:
        Error: If any entry cannot be characterized or removed. Nothing is
            swallowed: a caller that wanted "delete it if you can" says so at
            its own call site.
    """
    for entry in listdir(dir):
        var child = dir + "/" + String(entry)
        # `lstat`, never `isdir`: `isdir` follows a link, so a
        # symlink-to-directory would be recursed into and the TARGET's contents
        # deleted. It also folds an unreadable entry into False, which would
        # make this unlink something it could not characterize.
        var kind = Int(lstat(child).st_mode) & _S_IFMT
        if kind == _S_IFDIR:
            _remove_dir_contents_no_follow(child)
            rmdir(child)
        else:
            # Symlinks included: `unlink` removes the LINK, never its target.
            unlink(child)


def remove_tree_no_follow(path: String) raises:
    """Delete `path` and everything under it without ever following a symlink.

    The store's remover, and deliberately not `scratch.mojo`'s `_discard_path`:
    that one swallows every failure and never `lstat`s its own root, so pointing
    it at a symlink planted where a generation belongs would delete the link's
    target instead. Here the root is characterized first and a symlinked root is
    REFUSED rather than removed — the link is not the cache's to delete, and
    deleting it would hide the fact that something else is writing into the
    store's namespace.

    Args:
        path: The generation directory, staging directory, or file to remove.
            It must exist: an absent path is a failure here, not a no-op, so a
            caller that means "remove it if it is there" checks first or ignores
            the error deliberately.

    Raises:
        Error: If `path` is itself a symlink, if it cannot be characterized, or
            if any part of the removal fails.

    Examples:

    ```mojo
    from mtest.session.store import remove_tree_no_follow

    try:
        remove_tree_no_follow("/repo/.mtest-cache/build-v1/tests_a_h0123")
    except:
        pass  # a generation that will not die is litter, not a failed run
    ```
    """
    # Known and accepted: every check here is by PATHNAME, so a directory
    # swapped for a symlink between this `lstat` and the `listdir` below would
    # not be caught. Closing that needs `openat`/`unlinkat` walking descriptors,
    # which the pinned `std.os` does not expose and which would cost this module
    # three more foreign declarations. The window is inside a directory mtest
    # created and owns, and the no-follow checks still make every step refuse
    # what it can see; this is a narrowing, not a proof.
    var kind = Int(lstat(path).st_mode) & _S_IFMT
    if kind == _S_IFLNK:
        raise Error(
            "session: refusing to remove '"
            + path
            + "': it is a symlink, and the cache deletes only what it owns"
        )
    if kind != _S_IFDIR:
        unlink(path)
        return
    _remove_dir_contents_no_follow(path)
    rmdir(path)


def _discard(path: String):
    """Remove `path` no-follow, ignoring failure.

    Every store caller of the remover is in this position: a generation that
    cannot be deleted is litter under a directory mtest owns, and failing a test
    run over it would be exactly the "cache condition fails an otherwise green
    run" the design forbids.

    Args:
        path: The path to remove; an absent one is silently fine.
    """
    try:
        remove_tree_no_follow(path)
    except:
        pass


def clear_cache_root(root: String) -> Optional[String]:
    """Delete `<root>/.mtest-cache` whole, but only where mtest can prove it
    owns it.

    `--cache-clear`'s entire implementation, and the one place in mtest that
    removes a directory the USER named rather than one mtest invented. Three
    guards stand between the flag and the removal, in this order:

    1. The path is characterized `lstat`-no-follow FIRST. A symlink is REFUSED,
       never removed and never followed — following it would delete whatever it
       points at, which is outside the tree mtest owns.
    2. The directory must hold the `CACHEDIR.TAG` marker mtest writes at store
       creation. There is deliberately no "but its contents look like ours"
       exception: that heuristic is exactly how a directory somebody else
       created gets deleted. A checkout whose cache predates the marker
       therefore refuses ONCE, and the diagnostic says so and hands over the
       manual removal.
    3. Removal itself goes through `remove_tree_no_follow`, which unlinks child
       symlinks rather than descending them, so the blast radius stays inside
       the proven directory.

    An ABSENT cache root is success, not a diagnostic: there is nothing to
    clear, which is the ordinary shape of a first run.

    Args:
        root: The invocation root the cache directory hangs under.

    Returns:
        Nothing when the directory was deleted or was already absent; otherwise
        a complete, framed diagnostic for main to print before exiting 4. Every
        refusal leaves the filesystem exactly as it found it.

    Examples:

    ```mojo
    from mtest.session.store import clear_cache_root

    var failure = clear_cache_root("/repo")
    if failure:
        print(failure.value())
    ```
    """
    var cache_root = root + "/" + CACHE_ROOT_DIR
    # `lstat`, never `islink`/`isdir`: those follow or fold an unreadable path
    # into False, and "not a link" is precisely the answer that would let the
    # removal proceed straight through one.
    var kind: Int
    try:
        kind = Int(lstat(cache_root).st_mode) & _S_IFMT
    except:
        # Absent, or a parent that cannot be searched. `lstat` cannot separate
        # the two through a Mojo `Error`, and both resolve identically here:
        # nothing is deleted. Reporting the unreadable case as success costs a
        # cold run that was already going to be cold; guessing the other way
        # would fail runs over a cache directory that never existed.
        return Optional[String](None)
    if kind == _S_IFLNK:
        var symlink_note = String("cache-clear: ") + cache_root
        symlink_note += ": refusing to delete a symlink"
        symlink_note += " — mtest deletes only the cache directory it created,"
        symlink_note += " and following this link would delete whatever it"
        symlink_note += " points at; remove or repoint the link yourself, then"
        symlink_note += " rerun"
        return Optional[String](symlink_note^)
    if not exists(root + "/" + CACHEDIR_TAG_REL):
        var unmarked_note = String("cache-clear: ") + cache_root
        unmarked_note += ": refusing to delete a directory mtest cannot prove"
        unmarked_note += " it owns — the ownership marker '"
        unmarked_note += CACHEDIR_TAG_REL
        unmarked_note += "' is missing. mtest writes that marker when it"
        unmarked_note += " creates the store, so a cache directory left by an"
        unmarked_note += " older mtest refuses exactly once: run mtest once"
        unmarked_note += " with the cache enabled to write the marker, or"
        unmarked_note += " delete the directory yourself with 'rm -rf "
        unmarked_note += CACHE_ROOT_DIR
        unmarked_note += "'"
        return Optional[String](unmarked_note^)
    try:
        remove_tree_no_follow(cache_root)
    except e:
        # The ONE refusal here that leaves the disk changed:
        # `_remove_dir_contents_no_follow` raises on the first entry it cannot
        # remove, so an unwritable generation — or a concurrent mtest writing
        # into the store — stops the walk with part of the cache already gone.
        # Every other refusal above ends with the tree untouched, so this text
        # has to admit the partial state and finish the job for the reader;
        # otherwise their next move is a guess about what is left.
        var failure_note = String("cache-clear: ") + cache_root
        failure_note += ": could not delete the cache directory: " + String(e)
        failure_note += ". Some entries may already have been removed, so the"
        failure_note += " cache is now in a partial state; complete the removal"
        failure_note += " with 'rm -rf "
        failure_note += CACHE_ROOT_DIR
        failure_note += "'"
        return Optional[String](failure_note^)
    return Optional[String](None)


# --- Per-file keys. ----------------------------------------------------------


@fieldwise_init
struct FileKey(Copyable, Movable):
    """Everything the store needs to name, validate, and publish one file's
    build.

    Built by `file_key` from the session prefix plus the source's own frame, so
    two files of one session differ by exactly one frame and two sessions over
    changed inputs differ by the prefix.
    """

    var digest32: String
    """The first 32 hex digits of the key; the generation name's suffix."""

    var digest_full: String
    """The whole 64-hex key, recorded in `meta` and re-checked on every hit.

    The name carries only half of it, so a 128-bit prefix collision would put a
    foreign build at exactly the right path. This is what a hit is actually
    compared against.
    """

    var gen_name: String
    """`<mangled source>_h<digest32>`, one path component."""

    var gen_dir: String
    """`STORE_DIR + "/" + gen_name`, relative to the invocation root."""

    var src_rel: String
    """The source's root-relative path.

    Not in the plan's field list, and required by the protocol it specifies:
    `store_publish` re-digests the SOURCE before publishing, and its signature
    carries no path to re-read. `gen_name` cannot supply one — mangling is
    lossy for an over-budget name — so the path travels with the key.
    """

    var src_sha: String
    """The source's content digest at key time, and the publication guard's
    reference: a build whose source moved underneath it must never publish."""


def file_key(ctx: CacheContext, root: String, rel: String) -> Optional[FileKey]:
    """Fork the session prefix and key one test file.

    The prefix already covers the toolchain, the environment, the root, the
    build arguments, and every include root's contents; this appends the one
    frame that distinguishes this file from its neighbours. Forking rather than
    rebuilding is why `KeyBuilder` is copyable: the shared prefix is absorbed
    once per session, not once per file.

    Args:
        ctx: The finalized session context; only `prefix` is read.
        root: The invocation root `rel` resolves against.
        rel: The test file's root-relative path.

    Returns:
        The key, or `None` when the source could not be read at all. `None` is
        the caller's cue to treat the file as a per-file miss AND to disable the
        cache: a source that will not read is about to fail the build anyway,
        and a key that cannot cover its own source must not be written.

    Examples:

    ```mojo
    from mtest.session.store import file_key, store_probe

    var key = file_key(ctx, root, "tests/test_a.mojo")
    if not key:
        ctx.disable("cannot read the test file 'tests/test_a.mojo'")
    ```
    """
    var data: List[UInt8]
    try:
        data = read_regular_file_bytes(_absolute(root, rel), _WALK_FILE_CAP)
    except:
        return None
    var src_sha = sha256_hex(data)
    var kb = ctx.prefix.copy()
    kb.feed_file(TAG_SOURCE, rel, len(data), src_sha)
    # Two finalizations of one state, not two different states: `digest32` is a
    # true prefix of `digest_full`, so the fork is only a way to read the same
    # digest at two lengths without slicing a `String`.
    var forked = kb.copy()
    var digest_full = forked^.digest_full()
    var digest32 = kb^.digest32()
    var gen_name = generation_name(_mangle(rel), digest32)
    var gen_dir = STORE_DIR + "/" + gen_name
    return Optional(
        FileKey(
            digest32^,
            digest_full^,
            gen_name^,
            gen_dir^,
            String(rel),
            src_sha^,
        )
    )


# --- Staging a build the compiler writes straight into. ----------------------


@fieldwise_init
struct StoreBuildTarget(Copyable, Movable):
    """Where a first-attempt compile writes, so publication is one rename.

    The compiler builds INTO the store's staging directory rather than into
    `build/bin`, which is what makes publication a single `rename(2)` of a
    directory rather than a copy: there is no window in which a generation
    exists half-written, and no second read of a binary that could differ from
    the one that was digested.
    """

    var out_rel: String
    """The `-o` value, relative to the invocation root: `<tmp dir>/bin`."""

    var tmp_dir_rel: String
    """The staging directory itself, relative to the invocation root."""

    def ok(self) -> Bool:
        """Whether the store actually staged a directory for this build.

        Returns:
            False when the store could not be created or no unique staging name
            could be claimed. The caller must then build the ordinary way, into
            `build/bin`, and skip publication entirely — an unusable store costs
            a rebuild, which is always the safe direction.
        """
        return self.out_rel != "" and self.tmp_dir_rel != ""


def store_build_target(root: String, mangled: String) -> StoreBuildTarget:
    """Create the store, its marker, and one private staging directory.

    The name is `.tmp-<mangled>-<pid>-<clock>-<attempt>`. The process id and the
    monotonic reading are what keep two mtest processes over one checkout —
    which `--shard` makes ordinary — off one staging directory, with `mkdir`'s
    exclusive create as the arbiter rather than the name's uniqueness alone.

    The mangled source name leads, and it is not decoration. A first-attempt
    cached build is COMPILED here and then RUN from here: publication is a
    rename that happens only after the file's verdict is settled, so for the
    whole time a test child is alive its argv is `<this directory>/bin`.
    Anything identifying that child from outside the process — the release
    contract's SIGINT probe, a `ps` a human reads during a hang — has only that
    path to go on, and a name built from pid and clock alone put the source
    nowhere in it. A child that could not be named could not be found.

    Every invariant `_TMP_PREFIX` claims survives the addition, and each is
    load-bearing somewhere else in this module:

    - still dot-prefixed, so `walk_include_root` skips it and the cache's own
      staged bytes never feed the key that decides what the cache serves;
    - still free of `_h`, since `_mangle` escapes literal `_` as `_u` and this
      name adds only `-` and decimal digits, so a staging directory can never be
      read as the generation `<mangled>_h<digest32>`;
    - still keyed by the `.tmp-` prefix alone in `_reap_siblings`, which tests
      that prefix BEFORE the mangled-name prefix, so this source's own live
      staging directory is skipped rather than deleted out from under a
      concurrent process compiling into it.

    Name length stays comfortable: the decoration around the mangled name is
    `.tmp-` plus three dash-separated decimal fields, about 37 bytes at the
    widest plausible pid and clock reading. `_MANGLE_BUDGET` is 150, so the
    component lands near 187 of a 255-byte `NAME_MAX`, and the widest decorated
    form in the tree remains the precompile temp directory's ~45 bytes that
    budget was chosen against.

    Args:
        root: The invocation root.
        mangled: The mangled source name this build produces, from `_mangle`.
            Carried into the directory name so the staged binary's own path
            identifies its source.

    Returns:
        A staging target, or one whose `ok()` is False when the store could not
        be prepared. Never raises: an unusable cache must cost a rebuild, never
        an error the caller has to turn into a cache-policy decision.

    Examples:

    ```mojo
    from mtest.session.scratch import _mangle
    from mtest.session.store import store_build_target

    var target = store_build_target(root, _mangle(rel))
    if target.ok():
        pass  # build with `-o target.out_rel`
    ```
    """
    try:
        _ensure_store(root)
    except:
        return StoreBuildTarget(String(""), String(""))
    var pid = String(process_id())
    for attempt in range(_TMP_ATTEMPTS):
        var rel = (
            STORE_DIR
            + "/"
            + _TMP_PREFIX
            + mangled
            + "-"
            + pid
            + "-"
            + String(perf_counter_ns())
            + "-"
            + String(attempt)
        )
        try:
            # Exclusive create: a collision raises rather than handing two
            # builds one directory, and 0o700 keeps the staged binary private
            # until it is published.
            mkdir(root + "/" + rel, 0o700)
        except:
            continue
        var out_rel = rel + "/" + _BIN_NAME
        return StoreBuildTarget(out_rel^, rel^)
    return StoreBuildTarget(String(""), String(""))


# --- Probing a generation. ---------------------------------------------------

comptime PROBE_HIT = 0
"""The generation exists, matches the key, and its binary matches its digest."""

comptime PROBE_MISS = 1
"""Nothing usable is stored for this key; the caller must build."""


@fieldwise_init
struct ProbeResult(Copyable, Movable):
    """What a probe found, and everything a hit lets the caller skip."""

    var kind: Int
    """`PROBE_HIT` or `PROBE_MISS`."""

    var bin_rel: String
    """The cached binary, relative to the invocation root; empty on a miss."""

    var build_seconds: Float64
    """What the original build cost, to microsecond resolution; 0 on a miss.

    Round-tripped through a fixed-point field, so it is equal to the published
    value only to that grid — never compare it for exact float equality.
    """

    var argv: List[String]
    """The original build command line, for the reproduce line; empty on a
    miss. Its `-o` names the generation, not the staging directory it was
    actually built in, so the line a user copies still points at a live
    path."""


def _probe_miss() -> ProbeResult:
    """The one miss value; every failed check returns exactly this."""
    return ProbeResult(PROBE_MISS, String(""), 0.0, List[String]())


def store_probe(root: String, key: FileKey) -> ProbeResult:
    """Decide whether a stored generation may be run instead of rebuilding.

    This is the function where a mistake serves a stale or corrupt binary and
    reports a green run that never happened, so every question resolves toward
    MISS. A hit has proven all five of:

    1. The generation path is a real directory — characterized NO-FOLLOW and
       first, because everything after it reads through that path.
    2. `meta` is a regular file that parses completely.
    3. `meta.key_full` equals the WHOLE key, not just the 128 bits its name
       carries.
    4. `bin` is a readable regular file.
    5. `bin`'s content digest equals the digest `meta` recorded.

    Any failed check deletes the generation, so a corruption cannot be re-read
    on the next probe and the next build republishes cleanly. The one deliberate
    exception is a SYMLINK at the generation path: that is refused and left
    exactly where it is, because a link the cache did not create is not the
    cache's to delete.

    Args:
        root: The invocation root.
        key: The file's key, from `file_key`.

    Returns:
        A hit carrying the binary's path, the original build duration, and the
        original argv, or a miss. Never raises: the caller must be handed a
        cache decision, not an error it would have to turn into one itself.

    Examples:

    ```mojo
    from mtest.session.store import PROBE_HIT, store_probe

    var hit = store_probe(root, key)
    if hit.kind == PROBE_HIT:
        pass  # run hit.bin_rel; do not compile
    ```
    """
    var gen_abs = root + "/" + key.gen_dir

    # --- Check 1: a real directory, characterized without following. --------
    var kind: Int
    try:
        kind = Int(lstat(gen_abs).st_mode) & _S_IFMT
    except:
        # Absent, or in a directory this process cannot search. Either way
        # there is nothing here to trust and nothing to delete.
        return _probe_miss()
    if kind == _S_IFLNK:
        return _probe_miss()
    if kind != _S_IFDIR:
        # A plain file (or a device, or a socket) where a generation belongs is
        # not a generation, and it occupies the name the next publish needs.
        _discard(gen_abs)
        return _probe_miss()

    # --- Checks 2 and 3: the record parses and names THIS key. --------------
    var meta_text: String
    try:
        var opened = read_bounded_regular_file(
            gen_abs + "/" + _META_NAME, _META_CAP
        )
        if not opened.is_regular:
            _discard(gen_abs)
            return _probe_miss()
        meta_text = opened.text.copy()
    except:
        # Missing, oversized, unreadable, or not UTF-8. `MetaFile.render` emits
        # only ASCII, so none of those can describe a record this store wrote.
        _discard(gen_abs)
        return _probe_miss()
    var parsed = MetaFile.parse(meta_text)
    if not parsed:
        _discard(gen_abs)
        return _probe_miss()
    var meta = parsed.value().copy()
    if meta.key_full != key.digest_full:
        _discard(gen_abs)
        return _probe_miss()

    # --- Checks 4 and 5: the binary is there and is the one recorded. -------
    var bin_bytes: List[UInt8]
    try:
        bin_bytes = read_regular_file_bytes(gen_abs + "/" + _BIN_NAME, _BIN_CAP)
    except:
        _discard(gen_abs)
        return _probe_miss()
    if sha256_hex(bin_bytes) != meta.bin_sha:
        _discard(gen_abs)
        return _probe_miss()

    return ProbeResult(
        PROBE_HIT,
        key.gen_dir + "/" + _BIN_NAME,
        meta.build_seconds,
        meta.argv.copy(),
    )


# --- Publishing a build. -----------------------------------------------------

comptime PUB_OK = 0
"""The staged build is now the generation for this key."""

comptime PUB_ADOPTED = 1
"""Another run published this key first, and its generation revalidated."""

comptime PUB_FAILED = 2
"""Nothing was published; the caller keeps running what it just built."""


@fieldwise_init
struct PublishResult(Copyable, Movable):
    """The outcome of one publication, and which binary the caller should run.
    """

    var kind: Int
    """`PUB_OK`, `PUB_ADOPTED`, or `PUB_FAILED`."""

    var bin_rel: String
    """The binary to run and to record, relative to the invocation root.

    The generation's binary on `PUB_OK` and on `PUB_ADOPTED`; the STAGED binary
    on `PUB_FAILED`, which still exists and is this session's artifact.
    """

    var argv: List[String]
    """The command line to RECORD, which is not the one that was run.

    The build genuinely ran with `-o <staging dir>/bin`, and that directory no
    longer exists after `PUB_OK` — so the caller's own argv names a dead path
    the moment publication succeeds, and on `PUB_ADOPTED` the live path belongs
    to a generation the caller has never seen. Rewriting it is therefore not
    something a caller can do for itself, which is why it travels back here
    rather than staying inside `meta`.

    `PUB_OK`: the caller's argv with its `-o` pointed at the new generation.
    `PUB_ADOPTED`: the ADOPTED generation's own recorded argv, straight out of
    its validated `meta` — the winner's reproduce line, for the winner's binary.
    `PUB_FAILED`: the caller's argv verbatim, since the staging path it names is
    exactly the binary that is still there and still going to run.

    So the rule has no exceptions: record `pub.argv`, run `pub.bin_rel`.
    """

    var warning: String
    """Why publication failed, in words a user can act on; empty otherwise."""


def _publish_failed(
    target: StoreBuildTarget, argv: List[String], warning: String
) -> PublishResult:
    """A failed publication that keeps the staged build alive.

    The staging directory is deliberately NOT removed: the caller is about to
    run the binary inside it, and it is the only copy this session has. Nothing
    removes it afterwards either — there is no session-end sweep, and a build
    seam must not invent one, because it cannot know when the last run of that
    binary has finished. What is left behind is inert: `.tmp-` names are skipped
    by the reaper and by every include walk, and they carry the writing
    process's pid, so no later run can adopt, probe, or publish one. It survives
    until `--cache-clear` (or any removal of the store) takes it, which is the
    accepted price of never deleting a binary that is still running.

    The command line is handed back untouched for the same reason as the
    directory — it names the staging binary, which is precisely what will run.

    Args:
        target: The staging target, whose binary the caller keeps using.
        argv: The command line the build ran, returned verbatim.
        warning: Why nothing was published.

    Returns:
        A `PUB_FAILED` result naming the staged binary and its live argv.
    """
    return PublishResult(
        PUB_FAILED, String(target.out_rel), argv.copy(), warning
    )


def _rewrite_output(
    argv: List[String], staged_out: String, final_out: String
) -> List[String]:
    """Point the recorded command line's `-o` at the published generation.

    The build genuinely ran with `-o <staging dir>/bin`, and that directory is
    gone the instant the rename succeeds. A reproduce line naming it would be a
    line no user can run, so the record names where the artifact actually ended
    up. Every build site in the tree emits `-o` and its path as two tokens; the
    staged path is matched as well, so a site that ever joins them still lands
    on a live path.

    Args:
        argv: The command line as it was run.
        staged_out: The staging `-o` value to replace.
        final_out: The published binary's root-relative path.

    Returns:
        A new command line, the same length, with the output path rewritten.
    """
    var out = List[String]()
    var previous_was_o = False
    for token in argv:
        var value = String(token)
        var is_o = value == "-o"
        if previous_was_o or (staged_out != "" and value == staged_out):
            out.append(String(final_out))
        else:
            out.append(value^)
        previous_was_o = is_o
    return out^


def _write_meta(path: String, text: String) raises:
    """Write the validation record into the staging directory.

    Args:
        path: The record's path.
        text: The rendered record.

    Raises:
        Error: If the file cannot be created or written.
    """
    with open(path, "w") as f:
        f.write(text)


def _reap_siblings(root: String, key: FileKey):
    """Delete this source's other generations, keeping one live per file.

    An editing loop produces a new key per edit, and without this every one of
    them would keep its binary forever. Siblings are recognized by the mangled
    source name plus the `_h` separator, which no mangled name can contain, so
    the match cannot reach another file's generations. Staging directories are
    skipped by name: one of them may belong to a concurrent process that is
    compiling into it right now.

    Args:
        root: The invocation root.
        key: The key just published; its own generation is kept.
    """
    var prefix = _mangle(key.src_rel) + "_h"
    var store_abs = root + "/" + STORE_DIR
    var names = List[String]()
    try:
        for entry in listdir(store_abs):
            names.append(String(entry))
    except:
        return
    for entry in names:
        var name = String(entry)
        if name == key.gen_name or name.startswith(_TMP_PREFIX):
            continue
        if not name.startswith(prefix):
            continue
        _discard(store_abs + "/" + name)


def store_publish(
    root: String,
    key: FileKey,
    target: StoreBuildTarget,
    build_seconds: Float64,
    argv: List[String],
) -> PublishResult:
    """Promote a staged build into its generation, atomically or not at all.

    The protocol, in order:

    1. **The publication guard.** Re-digest the SOURCE and compare it to the
       digest the key was built from. A file edited while its compile was in
       flight produced a binary this key does not describe, and publishing it
       would serve those bytes to every later run whose key still says the old
       source. Nothing is published; the caller runs what it built.
    2. Rewrite the recorded command line's `-o` to the FINAL generation path,
       so the reproduce line names something that exists after publication.
    3. Digest the staged binary and write `meta` beside it.
    4. `fsync` the binary, the record, and the staging directory, so a machine
       crash cannot leave a committed directory entry pointing at bytes that
       never reached the disk.
    5. `rename(2)` the staging directory onto the generation path. One syscall,
       no half-published state, no window a concurrent reader can observe.
    6. On success, flush the store directory and reap this source's superseded
       generations.

    A rename that fails with the target already present means another run got
    there first. That winner is then fully RE-PROBED — key match and binary
    digest both — before it is adopted, because adopting an unvalidated winner
    is precisely how one corrupt generation spreads to every process that loses
    a race against it. An invalid winner is deleted by the probe and this
    publication reports failure rather than pretending to have cached anything.

    Args:
        root: The invocation root.
        key: The file's key, from `file_key`.
        target: The staging target the build wrote into.
        build_seconds: The build's wall-clock duration, recorded for reporting.
        argv: The command line the build actually ran.

    Returns:
        `PUB_OK` naming the published binary, `PUB_ADOPTED` naming the winner's
        binary, or `PUB_FAILED` naming the STAGED binary — which still exists
        and which the caller must keep running this session. Every kind also
        carries the command line to RECORD, which the caller cannot derive
        itself once the staging directory is gone: run `bin_rel`, record
        `argv`, on all three. Never raises.

    Examples:

    ```mojo
    from mtest.session.store import PUB_FAILED, store_publish

    var pub = store_publish(root, key, target, 2.5, build_argv)
    if pub.kind == PUB_FAILED:
        pass  # warn once with pub.warning
    # every kind: run pub.bin_rel, record pub.argv
    ```
    """
    if not target.ok():
        return PublishResult(
            PUB_FAILED,
            String(""),
            argv.copy(),
            "the cache could not stage a directory for this build",
        )
    var tmp_abs = root + "/" + target.tmp_dir_rel
    var bin_abs = root + "/" + target.out_rel
    var final_bin_rel = key.gen_dir + "/" + _BIN_NAME

    # --- Step 1: the publication guard. -------------------------------------
    var fresh: List[UInt8]
    try:
        fresh = read_regular_file_bytes(
            _absolute(root, key.src_rel), _WALK_FILE_CAP
        )
    except:
        return _publish_failed(
            target,
            argv,
            "could not re-read the source '"
            + key.src_rel
            + "' after building it",
        )
    if sha256_hex(fresh) != key.src_sha:
        return _publish_failed(target, argv, "source changed during compile")

    # --- Steps 2 and 3: digest the artifact and record it. ------------------
    var bin_bytes: List[UInt8]
    try:
        bin_bytes = read_regular_file_bytes(bin_abs, _BIN_CAP)
    except:
        return _publish_failed(
            target,
            argv,
            "could not read the binary just built for '" + key.src_rel + "'",
        )
    # One rewritten command line, recorded in `meta` for a future hit AND
    # returned to this caller for its own registry: the caller cannot derive it
    # itself, because the staging path it knows is the one about to disappear.
    var recorded = _rewrite_output(argv, target.out_rel, final_bin_rel)
    var meta = MetaFile(
        key_full=String(key.digest_full),
        bin_sha=sha256_hex(bin_bytes),
        build_seconds=build_seconds,
        argv=recorded.copy(),
    )
    try:
        _write_meta(tmp_abs + "/" + _META_NAME, meta.render())
    except:
        return _publish_failed(
            target,
            argv,
            "could not write the cache record for '" + key.src_rel + "'",
        )

    # --- Step 4: durability before the commit. ------------------------------
    try:
        fsync_path(bin_abs)
        fsync_path(tmp_abs + "/" + _META_NAME)
        fsync_path(tmp_abs)
    except:
        return _publish_failed(
            target,
            argv,
            "could not flush the cache generation for '" + key.src_rel + "'",
        )

    # --- Step 5: the commit. ------------------------------------------------
    try:
        rename_path(tmp_abs, root + "/" + key.gen_dir)
    except:
        # Either another run published this key first — a directory rename onto
        # a non-empty directory fails — or something else went wrong. The probe
        # answers which, and it answers it by FULL validation, not by presence.
        var winner = store_probe(root, key)
        if winner.kind == PROBE_HIT:
            _discard(tmp_abs)
            # The WINNER's argv, not this run's: the binary the caller is about
            # to run is the winner's, and the only reproduce line that both
            # names a live path and describes those bytes is the one out of the
            # generation this run just validated.
            return PublishResult(
                PUB_ADOPTED,
                String(winner.bin_rel),
                winner.argv.copy(),
                String(""),
            )
        return _publish_failed(
            target,
            argv,
            "could not publish the cached build for '" + key.src_rel + "'",
        )

    # --- Step 6: make the commit durable, then reap. ------------------------
    # Best-effort: the rename already succeeded, and refusing to report a
    # published generation because its parent directory would not flush would
    # cost a rebuild for no gain in safety.
    try:
        fsync_path(root + "/" + STORE_DIR)
    except:
        pass
    _reap_siblings(root, key)
    return PublishResult(PUB_OK, final_bin_rel^, recorded^, String(""))


# --- Configured precompile steps. --------------------------------------------
#
# A precompile step is not a test file and its stamp is not a generation. It
# produces ONE artifact the user named (`-o`), which stays exactly where it was
# promoted to; the cache neither moves it nor owns it. So there is nothing to
# stage and nothing to publish — only a STAMP saying "an output with this digest
# at this path was produced for this key", which is the whole of what lets the
# next run skip the compile.
#
# Two properties are specific to this shape and neither has an analogue above.
#
# **The key comes from `ctx.base`, never from `ctx.prefix`.** `prefix` is `base`
# plus every include walk, and a step's own output directory BECOMES an include
# root the moment the step succeeds. Keying a step on the walk its own output
# takes part in is circular: the first run's key would describe a tree without
# the package and the second run's key a tree with it, so the stamp could never
# be hit. Forking `base` and walking this step's inputs explicitly is what breaks
# that.
#
# **A step is skipped only if its OUTPUT still matches.** A generation's binary
# lives inside a directory the cache owns and nothing outside it writes; a
# precompile output sits in the user's tree, where a later `mojo build`, a
# `rm`, or a half-finished editor save can reach it. So the probe re-digests the
# artifact every time rather than trusting that a stamp implies its output.

comptime PRECOMPILE_SUBDIR = "precompile"
"""The stamp directory, inside `STORE_DIR`.

A sibling of the generations rather than a name among them: a generation is a
DIRECTORY holding `bin` and `meta`, a stamp is a single file, and `_reap_siblings`
walks `STORE_DIR` deleting by mangled-name prefix. Keeping the two namespaces
apart means neither reaper can ever reach the other's records.
"""


def precompile_stamp_rel(gen_name: String) -> String:
    """The stamp's path for a step key, relative to the invocation root.

    The one place the layout is spelled: the probe reads this path, the publisher
    writes it, and `precompile_key` records it in the key it returns, so no two
    of them can drift.

    Args:
        gen_name: The step key's `gen_name`.

    Returns:
        `<STORE_DIR>/precompile/<gen_name>`.

    Examples:

    ```mojo
    from mtest.session.store import precompile_stamp_rel

    var rel = precompile_stamp_rel(key.gen_name)
    ```
    """
    return STORE_DIR + "/" + PRECOMPILE_SUBDIR + "/" + gen_name


def _feed_prior_outputs(
    mut ctx: CacheContext,
    root: String,
    src: String,
    prior_outputs: List[String],
    mut kb: KeyBuilder,
) -> Bool:
    """Frame every earlier step's promoted output, in step order.

    Args:
        ctx: The session context; disabled when an output cannot be read.
        root: The invocation root the outputs resolve against.
        src: The step being keyed, named in any disable reason.
        prior_outputs: The earlier steps' output paths, in the order the steps
            were configured.
        kb: The builder to feed.

    Returns:
        True once every prior output is framed; False when one could not be
        read, in which case the cache is already off.
    """
    for entry in prior_outputs:
        var prior = String(entry)
        var data: List[UInt8]
        try:
            data = read_regular_file_bytes(_absolute(root, prior), _BIN_CAP)
        except:
            # An earlier step's package is on this step's include path, so a
            # package that cannot be read is an input this key cannot cover.
            ctx.disable(
                "precompile step '"
                + src
                + "': cannot read the earlier step's output '"
                + prior
                + "'"
            )
            return False
        kb.feed_file(TAG_PRECOMPILE_PRIOR, prior, len(data), sha256_hex(data))
    return True


def precompile_key(
    mut ctx: CacheContext,
    root: String,
    src: String,
    includes: List[String],
    prior_outputs: List[String],
    out_path: String,
) -> Optional[FileKey]:
    """Key one configured precompile step from the session BASE.

    Frames, in this exact order — the order is the wire contract, and changing
    it invalidates every stamp:

    1. `ctx.base` — frames 1-7, complete before the precompile loop runs.
    2. `precompile-step`: the step's source, spelled as configured.
    3. `precompile-out`: the output path, spelled as the compiler's `-o` gets
       it. Its SPELLING only — the output is what this step produces.
    4. The source's closure: one `precompile-src` file frame for a single-file
       source, or an include walk of a directory source, which contributes
       `walkfile` frames.
    5. Each include root the step will be given, in order — the configured ones
       first, then the `-I` directories recorded out of the build arguments,
       which is the order the compiler receives them — each as an `include`
       frame followed by that root's walked contents, or by one
       `precompile-include-absent` frame when the root does not exist yet.
    6. Each earlier step's output, as a `precompile-prior` file frame.

    Every walk here excludes `out_path`. That is not an optimization: this
    step's own output ordinarily lands inside a directory the walk covers, and a
    key that digested it would describe the step's RESULT rather than its
    inputs — so the first run and the second would key differently and no stamp
    could ever be hit.

    An include root that does not exist yet is the OTHER thing this function
    treats differently from `finalize_includes`, and for the same reason: a
    configured `-I build` is ordinarily created by a precompile step, so it is
    genuinely absent at the moment the step is keyed on a cold tree. That is a
    fact about the build, framed as such, not a failure to characterize one —
    disabling on it would cost the whole session its cache on the first run of a
    legitimate config. A root that EXISTS but will not characterize still
    disables.

    Args:
        ctx: The session context. `base` is read, `extra_walk_dirs` is walked
            after `includes`, and the cache is DISABLED on any failure below.
        root: The invocation root every path resolves against.
        src: The step's source, as configured.
        includes: The include roots the step will be given, in order.
        prior_outputs: The outputs of every earlier step, in step order.
        out_path: This step's output path, from `precompile_out_path`. Passed
            to every walk as the excluded path, so it must be spelled the way
            the walk composes its own paths — root-relative, no `./`, no
            trailing slash — since the exclusion is an exact string match.

    Returns:
        The step's key, or `None` when any input could not be characterized.
        `None` is the caller's only signal to run the step UNCONDITIONALLY: a
        step whose inputs are not fully covered must never be skipped, and the
        cache is already off by the time it is returned. A context that is
        already off also yields `None`, without a second reason. Never raises.

    Examples:

    ```mojo
    from mtest.session.precompile import precompile_out_path
    from mtest.session.store import precompile_key, precompile_probe

    var out_path = precompile_out_path(pc.src, pc.out)
    var key = precompile_key(ctx, root, pc.src, includes, priors, out_path)
    if key and precompile_probe(root, key.value(), out_path):
        pass  # the step is unchanged: skip it, but still widen the includes
    ```
    """
    if not ctx.enabled:
        return None
    var kb = ctx.base.copy()
    kb.feed_str(TAG_PRECOMPILE_STEP, src)
    kb.feed_str(TAG_PRECOMPILE_OUT, out_path)

    # --- The source's closure. ----------------------------------------------
    # `mojo precompile` takes either a single file or a package directory, and
    # the two cover different input sets: one file's bytes, or everything `-I`
    # on that directory would make visible.
    var src_sha = String("")
    if isdir(_absolute(root, src)):
        var walked = walk_include_root(root, src, kb, out_path)
        if not walked.ok:
            # The walk's own words: a symlinked package and an unreadable file
            # are different things for the user to fix.
            ctx.disable("precompile step '" + src + "': " + walked.reason)
            return None
    else:
        var data: List[UInt8]
        try:
            data = read_regular_file_bytes(_absolute(root, src), _WALK_FILE_CAP)
        except:
            ctx.disable(
                "precompile step '"
                + src
                + "': cannot read the source '"
                + src
                + "'"
            )
            return None
        src_sha = sha256_hex(data)
        kb.feed_file(TAG_PRECOMPILE_SRC, src, len(data), src_sha)

    # --- The include roots, in the order the compiler receives them. --------
    var dirs = includes.copy()
    for extra in ctx.extra_walk_dirs:
        # A `-I` inside `--build-arg` reaches this step exactly like a
        # configured include root, so it reaches the key the same way.
        dirs.append(String(extra))
    for entry in dirs:
        var dir = String(entry)
        kb.feed_str(TAG_INCLUDE, dir)
        # An include root that is GENUINELY ABSENT is not a failure here, and
        # this is the one place in the module where that is true. The ordinary
        # `-I build` shape has a precompile step CREATE the include root, so on
        # a cold tree the directory does not exist yet at the moment the step is
        # keyed — `finalize_includes` walks the same root after the loop, when it
        # does. Disabling on it would take the whole session's cache down on the
        # first run of a perfectly legitimate config, which is the run that
        # decides whether the feature is ever trusted.
        #
        # `lstat` is what separates absent from unreadable: it raises where the
        # path is not there (or its parent cannot be searched) and succeeds for
        # everything that exists, symlinks included. Anything that EXISTS but
        # will not characterize still disables below — a file where a directory
        # belongs, an unlistable directory, a symlinked package — because that
        # is a build input this key cannot represent.
        var present = True
        try:
            _ = lstat(_absolute(root, dir))
        except:
            present = False
        if not present:
            kb.feed_str(TAG_PRECOMPILE_INCLUDE_ABSENT, dir)
            continue
        var walked = walk_include_root(root, dir, kb, out_path)
        if not walked.ok:
            ctx.disable(
                "precompile step '"
                + src
                + "': include root '"
                + dir
                + "': "
                + walked.reason
            )
            return None

    # --- Every earlier step's output. ---------------------------------------
    if not _feed_prior_outputs(ctx, root, src, prior_outputs, kb):
        return None

    # Two finalizations of one state: `digest32` is a true prefix of
    # `digest_full`, so the fork reads one digest at two lengths.
    var forked = kb.copy()
    var digest_full = forked^.digest_full()
    var digest32 = kb^.digest32()
    var gen_name = generation_name(_mangle(src), digest32)
    var stamp_rel = precompile_stamp_rel(gen_name)
    # `gen_dir` carries the STAMP's path rather than a generation directory, and
    # `src_sha` is empty for a directory source: neither field is read by the
    # stamp protocol, which never stages, never renames a build, and has no
    # publication guard to re-digest a source for. `FileKey` is reused for the
    # digests and the name; the fields it carries for the generation protocol
    # are inert here.
    return Optional(
        FileKey(
            digest32^,
            digest_full^,
            gen_name^,
            stamp_rel^,
            String(src),
            src_sha^,
        )
    )


def precompile_probe(root: String, key: FileKey, out_path: String) -> Bool:
    """Decide whether a configured precompile step may be skipped entirely.

    A skip is granted only when all five hold:

    0. The stamp path is not a SYMLINK — characterized no-follow and first,
       exactly as `store_probe` characterizes a generation directory. A link is
       refused and left untouched; it is not the cache's to delete.
    1. The stamp for this key is a readable regular file.
    2. It parses as a complete `MetaFile`.
    3. Its `key` line equals the WHOLE 64-hex key, not just the 128 bits the
       stamp's name carries.
    4. `out_path` reads back with exactly the digest the stamp recorded.

    The fourth is the one with no counterpart in `store_probe`: a generation's
    binary lives inside the directory the cache owns, but a precompile output
    lives in the user's tree, where a stray build, a `rm`, or an interrupted
    copy can reach it. A stamp is a claim ABOUT an artifact, never a substitute
    for it.

    Any failed check after the stamp has been read deletes the stamp, so a
    corrupt or superseded record cannot be re-read on the next probe and the
    step's next run republishes cleanly.

    Args:
        root: The invocation root.
        key: The step's key, from `precompile_key`.
        out_path: The step's output path, from `precompile_out_path`.

    Returns:
        True only if the step's output is already exactly what this key
        describes. Never raises: the caller must be handed a decision, not an
        error it would have to turn into one.

    Examples:

    ```mojo
    from mtest.session.store import precompile_probe

    if precompile_probe(root, key, out_path):
        pass  # skip the compile; the package on disk is the one this key names
    ```
    """
    var stamp_abs = root + "/" + precompile_stamp_rel(key.gen_name)

    # Characterized NO-FOLLOW and first, exactly as `store_probe` does at the
    # same structural position. A symlink is refused and LEFT WHERE IT IS: a
    # link the cache did not create is not the cache's to delete, and deleting
    # it would hide the fact that something else is writing into the store's
    # namespace. Re-digesting the output below means a followed link could not
    # serve stale bytes today, but the two probes must not disagree about
    # whether a symlink is acceptable here — that asymmetry is how a later
    # change lands on the wrong side of it.
    var kind: Int
    try:
        kind = Int(lstat(stamp_abs).st_mode) & _S_IFMT
    except:
        # Absent, or in a directory this process cannot search. Either way there
        # is nothing here to trust and nothing to delete.
        return False
    if kind == _S_IFLNK:
        return False

    var stamp_text: String
    try:
        var opened = read_bounded_regular_file(stamp_abs, _META_CAP)
        if not opened.is_regular:
            _discard(stamp_abs)
            return False
        stamp_text = opened.text.copy()
    except:
        # Absent is the ordinary cold case and there is nothing to delete;
        # oversized, unreadable, or non-UTF-8 cannot describe a record this
        # store wrote, and `_discard` tolerates a path that is not there.
        return False
    var parsed = MetaFile.parse(stamp_text)
    if not parsed:
        _discard(stamp_abs)
        return False
    var meta = parsed.value().copy()
    if meta.key_full != key.digest_full:
        _discard(stamp_abs)
        return False
    var out_bytes: List[UInt8]
    try:
        out_bytes = read_regular_file_bytes(_absolute(root, out_path), _BIN_CAP)
    except:
        # The artifact this stamp describes is gone, unreadable, or is not a
        # regular file. The stamp outlived its output and is worthless.
        _discard(stamp_abs)
        return False
    if sha256_hex(out_bytes) != meta.bin_sha:
        _discard(stamp_abs)
        return False
    return True


def _reap_stamps(root: String, key: FileKey):
    """Delete this step's superseded stamps, keeping one live per source.

    Every edit to a step's inputs produces a new key and therefore a new stamp
    name; without this, an editing loop would leave one file per edit behind
    forever. Siblings are recognized by the mangled source name plus the `_h`
    separator, which no mangled name can contain, so the match cannot reach
    another step's stamps.

    Args:
        root: The invocation root.
        key: The key about to be written; its own stamp is kept.
    """
    var prefix = _mangle(key.src_rel) + "_h"
    var stamp_dir = root + "/" + STORE_DIR + "/" + PRECOMPILE_SUBDIR
    var names = List[String]()
    try:
        for entry in listdir(stamp_dir):
            names.append(String(entry))
    except:
        return
    for entry in names:
        var name = String(entry)
        if name == key.gen_name or name.startswith(_TMP_PREFIX):
            continue
        if not name.startswith(prefix):
            continue
        _discard(stamp_dir + "/" + name)


def precompile_publish(root: String, key: FileKey, out_path: String):
    """Record that this step's output was produced for this key.

    Called after a step has RUN and promoted its package, so the next session
    over an unchanged tree can skip it. The record is written to a unique
    temporary file and renamed onto its name, so a concurrent probe reads either
    the old stamp or the new one and never a half-written record — the same
    discipline the ownership marker and every generation use.

    Superseded stamps for this same source are reaped first, so an editing loop
    leaves one stamp per step rather than one per edit.

    Best-effort throughout, and deliberately: a stamp that cannot be written
    costs one recompile on the next run, while failing a session over it would
    be exactly the "cache condition fails an otherwise green run" the design
    forbids. Never raises.

    Args:
        root: The invocation root.
        key: The step's key, from `precompile_key`.
        out_path: The step's output path, whose promoted bytes are digested
            into the record.

    Examples:

    ```mojo
    from mtest.session.store import precompile_publish

    precompile_publish(root, key, out_path)  # after the step succeeded
    ```
    """
    var stamp_dir = root + "/" + STORE_DIR + "/" + PRECOMPILE_SUBDIR
    try:
        _ensure_store(root)
        _ensure_dir(stamp_dir)
    except:
        return
    var out_bytes: List[UInt8]
    try:
        out_bytes = read_regular_file_bytes(_absolute(root, out_path), _BIN_CAP)
    except:
        # The step reported success but its package cannot be read back. There
        # is nothing honest to record, and the next run rebuilds.
        return
    _reap_stamps(root, key)
    # `build_seconds` and `argv` are the generation record's fields, not this
    # one's: a stamp gates a SKIP, and nothing reports or reproduces a step that
    # did not run. `MetaFile` is reused whole so one parser guards both records.
    var meta = MetaFile(
        key_full=String(key.digest_full),
        bin_sha=sha256_hex(out_bytes),
        build_seconds=0.0,
        argv=List[String](),
    )
    try:
        var created = create_unique_temp(
            stamp_dir + "/" + _TMP_PREFIX + "stamp.XXXXXX"
        )
        var wrote = True
        try:
            write_all_fd(created.fd, meta.render())
        except:
            wrote = False
        # Discharged exactly once whether or not the write succeeded.
        close_checked_fd(created.fd)
        if not wrote:
            _discard(created.path)
            return
        fsync_path(created.path)
        rename_path(
            created.path, root + "/" + precompile_stamp_rel(key.gen_name)
        )
    except:
        return
