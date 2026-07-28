"""`CacheContext`: what the build-artifact cache key covers, and when the cache
switches itself off.

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
"""
from std.os import getenv, listdir
from std.os.path import dirname, isdir, isfile, islink, realpath

from mtest.cache import (
    ARG_FILE_CANDIDATE,
    ARG_FLAG,
    ARG_INCLUDE_DIR,
    ARG_UNKNOWN,
    KEY_FORMAT_TAG,
    KeyBuilder,
    classify_build_args,
    sha256_hex,
)
from mtest.config import RunnerConfig
from mtest.exec import ExecRuntime, ProcessResult, ProcessSpec, run_supervised
from mtest.platform import read_regular_file_bytes, resolve_executable


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


def _is_package_dir(abs_dir: String) -> Bool:
    """Whether `abs_dir` carries an `__init__`, making it an importable package.

    Args:
        abs_dir: The directory's absolute path.

    Returns:
        True iff it holds `__init__.mojo` or `__init__.🔥`. A query that cannot
        answer — an unreadable parent, a vanished entry — reads as False, which
        keeps the walk out of a directory it cannot characterize.
    """
    return isfile(abs_dir + "/__init__.mojo") or isfile(abs_dir + "/__init__.🔥")


def _walk_into(
    abs_dir: String, rel_prefix: String, mut kb: KeyBuilder, exclude_abs: String
) -> Bool:
    """Feed one directory's contributions, recursing into package subdirectories.

    Args:
        abs_dir: The directory to read, absolute.
        rel_prefix: The path of `abs_dir` relative to the walked include root;
            empty at the top. Frames name files by this prefix, never by an
            absolute path, so the same tree keys alike in any checkout.
        kb: The builder to feed.
        exclude_abs: One absolute path to skip wherever met, or empty for none.

    Returns:
        True on a complete walk; False if anything at all could not be read.
        Never raises: a half-read tree must not become a key, so every
        filesystem failure is turned into a False return instead.
    """
    var names = List[String]()
    try:
        for entry in listdir(abs_dir):
            names.append(String(entry))
    except:
        return False
    _sort_bytewise(names)

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

        if isdir(full):
            # The link check comes BEFORE the recursion, and before the package
            # test: a symlinked directory can close a cycle that no lexical
            # normalization detects, and the walk would never terminate.
            if islink(full):
                continue
            # Without an `__init__`, `-I` on the parent does not reach inside,
            # so the contents cannot change the build and must not change the
            # key.
            if not _is_package_dir(full):
                continue
            if not _walk_into(full, rel, kb, exclude_abs):
                return False
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
            return False
        kb.feed_file(TAG_WALK_FILE, rel, len(data), sha256_hex(data))
    return True


def walk_include_root(
    root: String, dir: String, mut kb: KeyBuilder, exclude: String
) -> Bool:
    """Feed everything `-I dir` makes visible to the compiler, in a fixed order.

    The walk mirrors what the import resolver can actually reach: every
    top-level `*.mojo` / `*.🔥` / `*.mojopkg` / `*.mojoc`, plus the same rule
    applied recursively inside each subdirectory that carries an `__init__`.
    Dot-prefixed entries and symlinked directories are skipped, entries are
    visited in byte order, and each file contributes its path (relative to
    `dir`), its size, and its content digest.

    Args:
        root: The invocation root; `dir` and `exclude` resolve against it.
        dir: The include root, as configured — absolute, or relative to `root`.
        kb: The builder to feed.
        exclude: One path to skip wherever the walk meets it, relative to `root`
            (an absolute path also works). Empty means nothing is excluded. A
            precompile step passes its own output here, so the key that decides
            whether the step runs does not depend on what the step produces.

    Returns:
        True on a complete walk. False if `dir` is not a directory, or if any
        listing or read failed — the caller's only correct response is to
        disable the cache, since a partial walk is a key that does not cover
        its inputs. Never raises.

    Examples:

    ```mojo
    from mtest.cache import KeyBuilder
    from mtest.session.store import walk_include_root

    var kb = KeyBuilder()
    if not walk_include_root("/repo", "src", kb, ""):
        pass  # disable the cache; the key would not cover `src`
    ```
    """
    var abs_dir = _absolute(root, dir)
    if not isdir(abs_dir):
        return False
    var exclude_abs = String("") if exclude == "" else _absolute(root, exclude)
    return _walk_into(abs_dir, "", kb, exclude_abs)


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
    var rows = classify_build_args(config.build_args)
    for row in rows:
        if row.kind == ARG_UNKNOWN:
            # An unrecognized flag may change what gets built in a way no frame
            # here can see. Hashing the rest would produce a confident key for
            # an unknown build.
            return CacheContext.disabled(
                "unrecognized build argument '" + row.value + "'"
            )
    var resolved: Optional[String]
    try:
        resolved = resolve_executable(config.mojo_path)
    except:
        resolved = None
    if not resolved:
        # Keying on an unresolved spelling would name a compiler that may not be
        # the one the supervisor spawns.
        return CacheContext.disabled(
            "cannot resolve the compiler '" + config.mojo_path + "'"
        )
    var compiler = resolved.value()

    var ctx = CacheContext()

    # --- Frame 2: toolchain identity. ---------------------------------------
    var compiler_bytes: List[UInt8]
    try:
        compiler_bytes = read_regular_file_bytes(compiler, _BIN_CAP)
    except:
        ctx.disable("cannot read the compiler at '" + compiler + "'")
        return ctx^
    ctx.base.feed_file(
        TAG_TOOLCHAIN,
        compiler,
        len(compiler_bytes),
        sha256_hex(compiler_bytes),
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
        if not walk_include_root(root, dir, ctx.prefix, ""):
            ctx.disable("cannot read the include root '" + dir + "'")
            return
