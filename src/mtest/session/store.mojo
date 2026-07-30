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
4. Toolchain libraries — a count frame (or the absence marker), then one
   name-and-type frame per entry of `<compiler dir>/../lib/mojo` in byte order,
   then one frame holding the digest of every regular file among them.
5. Environment — `MODULAR_HOME`, `MODULAR_CACHE_DIR`, `MODULAR_DERIVED_PATH`,
   `MODULAR_NVPTX_COMPILER_PATH`, `XDG_CACHE_HOME`, each as a present-or-absent
   frame, in that order.
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

**The store protocol.** `file_key` forks `prefix` and appends the test file's
own frames — a walk of the directory it sits in, then the file itself — which
name the generation `<mangled>_h<digest32>` under `STORE_DIR`. The directory is
there because the compiler resolves a bare import against the source file's own
directory, so a helper beside a test is a build input no `-I` frame covers; the
walk is memoized per directory, so a suite sharing one directory pays for it
once, and it omits the directory's own test files so that editing one test does
not rebuild its neighbours.
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
`ensure_cache_root` writes that marker on EVERY path that CREATES the directory,
including the one that only wants somewhere to keep last-run state, and on no
other path: a directory that was already there was made by somebody else, and
marking it would manufacture the very proof the deletion demands. The proof is
the marker's whole text, since `CACHEDIR.TAG` is a shared convention and a
marker somebody else wrote says nothing about who owns the directory.

**The publication fault seam — TEST ONLY.** `store_publish` reads the
environment variable `MTEST_STORE_FAULT` exactly ONCE per call, through the same
`_env_value` accessor `MODULAR_HOME` goes through, and what it reads never
reaches a `KeyBuilder`: the seam is not a key input, not a config field, and not
part of the tag namespace. Absent or empty — the only shape any real invocation
has — means no effect at all, and so does any value outside the two names below.

It exists because the two publication windows worth faulting are inside mtest's
own process, AFTER the compiler child has exited, so no fake compiler can reach
them. `before-fsync` abandons the publication before step 4, leaving a staging
directory that was never flushed; `before-rename` abandons it after step 4 and
before step 5, so the generation is fully durable and simply never committed.
Both take the ordinary `PUB_FAILED` path — the staged binary stays alive and the
session keeps running it — so the seam introduces no state and no control flow
the protocol does not already have. `scripts/tests/test_cache_protocol.py` drives
both windows and asserts the property they exist to demonstrate: an interrupted
publication leaves no generation a later run could probe.
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
    scan_imports,
    sha256_hex,
)
from mtest.config import RunnerConfig
from mtest.discover import is_discovered_test_name
from mtest.exec import ExecRuntime, ProcessResult, ProcessSpec, run_supervised
from mtest.platform import (
    close_checked_fd,
    create_unique_temp,
    fsync_path,
    is_executable_file,
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
"""How many entries the toolchain library directory holds, or `absent` for no
library directory at all."""

comptime TAG_TOOLCHAIN_LIB = "toolchain-lib"
"""One entry of the toolchain library directory, as `<st_mode type>:<name>`.

The type leads and is decimal digits terminated by the `:`, so a name can never
be read as part of it — an entry that turns from a regular file into a symlink
moves this frame even under an unchanged name. Every entry gets one, whatever
its type, so an added or removed entry moves the key without anything being
read.
"""

comptime TAG_TOOLCHAIN_LIB_CONTENT = "toolchain-lib-content"
"""The digest of every REGULAR file in that directory, folded in whole.

One frame rather than a file frame per library, because the digest is computed
once per process and reused: the directory is the same for every session in a
process, and reading it again per session would buy nothing. The sub-digest is
built from a file frame per regular entry, in the same byte order the entry
frames above use.
"""

comptime TAG_ENV_MODULAR_HOME = "env-MODULAR_HOME"
"""`MODULAR_HOME`, present-or-absent."""

comptime TAG_ENV_MODULAR_CACHE_DIR = "env-MODULAR_CACHE_DIR"
"""`MODULAR_CACHE_DIR`, present-or-absent."""

comptime TAG_ENV_MODULAR_DERIVED_PATH = "env-MODULAR_DERIVED_PATH"
"""`MODULAR_DERIVED_PATH`, present-or-absent."""

comptime TAG_ENV_MODULAR_NVPTX_COMPILER_PATH = "env-MODULAR_NVPTX_COMPILER_PATH"
"""`MODULAR_NVPTX_COMPILER_PATH`, present-or-absent."""

comptime TAG_ENV_XDG_CACHE_HOME = "env-XDG_CACHE_HOME"
"""`XDG_CACHE_HOME`, present-or-absent."""

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
"""The test file being keyed, as a file frame (adds `.size` and `.sha`). What
distinguishes two files of one session that sit in the same directory."""

comptime TAG_SOURCE_DIR = "source-dir"
"""The directory the test file lives in, named relative to the invocation root.

The compiler resolves a bare `from helper import ...` against the SOURCE FILE'S
OWN DIRECTORY, with no `-I` involved, so that directory is a search path of
every build and what sits in it is a build input."""

comptime TAG_SOURCE_DIR_WALK = "source-dir-walk"
"""The digest of that directory's walk, folded in whole.

One frame rather than a `walkfile` frame per entry, because the walk is shared
by every test file in the directory and is therefore performed once for all of
them; its own digest is what gets forked into each file's key."""

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

comptime TAG_PRECOMPILE_SRC_DIR = "precompile-src-dir"
"""The directory a single-file precompile source sits in, before its walk.

The compiler resolves a bare import against the source file's own directory, so
a module beside `lib/pkg.mojo` is compiled into the package that step produces
just as surely as the named file is. A directory source needs no such frame:
its own walk already covers everything beside it.
"""

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
        String(TAG_TOOLCHAIN_LIB_CONTENT),
        String(TAG_ENV_MODULAR_HOME),
        String(TAG_ENV_MODULAR_CACHE_DIR),
        String(TAG_ENV_MODULAR_DERIVED_PATH),
        String(TAG_ENV_MODULAR_NVPTX_COMPILER_PATH),
        String(TAG_ENV_XDG_CACHE_HOME),
        String(TAG_ROOT),
        String(TAG_ARG),
        String(TAG_ARG_FILE),
        String(TAG_INCLUDE),
        String(TAG_WALK_FILE),
        String(TAG_SOURCE),
        String(TAG_SOURCE_DIR),
        String(TAG_SOURCE_DIR_WALK),
        String(TAG_PRECOMPILE_STEP),
        String(TAG_PRECOMPILE_OUT),
        String(TAG_PRECOMPILE_SRC),
        String(TAG_PRECOMPILE_SRC_DIR),
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


def _is_scannable_name(name: String) -> Bool:
    """Whether `name` is Mojo source text whose imports can be read.

    Args:
        name: One directory entry's bare name.

    Returns:
        True for `*.mojo` and `*.🔥`. A `*.mojopkg` or `*.mojoc` is excluded and
        needs no scan: its imports were bound when it was compiled and cannot
        late-resolve to a source file sitting beside a test.
    """
    return name.endswith(".mojo") or name.endswith(".🔥")


def _module_name(name: String) -> String:
    """The name a source file in the search path is imported by.

    Args:
        name: One directory entry's bare name.

    Returns:
        The name with its final extension removed, which is the spelling a bare
        `import` uses. A name with no extension comes back unchanged.
    """
    var bytes = name.as_bytes()
    var cut = len(bytes)
    for i in range(len(bytes)):
        if bytes[i] == UInt8(ord(".")):
            cut = i
    var out = List[UInt8]()
    for i in range(cut):
        out.append(bytes[i])
    # SAFETY: `unsafe_from_utf8` requires `out` to be well-formed UTF-8. `name`
    # is a `String`, so it already is, and `cut` is either its length or the
    # index of a literal ASCII `.` (0x2E). A byte below 0x80 never appears
    # inside a multi-byte sequence, so cutting at that `.` cannot split one and
    # the prefix `[0, cut)` is well-formed on its own.
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def _names_contain(names: List[String], needle: String) -> Bool:
    """Whether `needle` equals any element of `names`.

    Args:
        names: The names to search, a handful at most.
        needle: The name to look for.

    Returns:
        True iff some element compares equal.
    """
    for name in names:
        if name == needle:
            return True
    return False


@fieldwise_init
struct _SourceDirScan(Copyable, Movable):
    """What a test file's own directory walk omits, and whether it may.

    The compiler resolves a bare import against the source file's own directory,
    so that directory is a search path of every build and its contents are build
    inputs. Walking it whole would be correct and useless: every test file in it
    is a search-path entry too, so one edit would move every neighbour's key and
    the single-file edit-and-rerun loop would rebuild the whole directory.

    So the walk omits exactly the entries mtest would DISCOVER as test files.
    Each of those is an independent entry point already keyed by its own source
    frame, and the omission is safe precisely while nothing the compiler reads
    imports one of them. That is proved rather than assumed, by two scans that
    together cover the whole proof and are stated here because neither is
    sufficient alone:

    - `file_key` scans the file BEING KEYED against `skip_modules`, so a test
      file that imports a test sibling — `from test_helpers import ...`, an
      everyday shape — abandons the omission for itself.
    - this walk scans every source it FRAMES, so a helper that imports a test
      sibling abandons it for the whole directory, one hop out.

    Between them no omitted file can enter a compile unnoticed. Walk the chain
    of imports from the keyed file: whichever omitted file the compiler reaches
    first was named by the keyed file itself or by a non-omitted one, since
    everything earlier in the chain is by definition not omitted — and both of
    those are scanned. So an omitted file is reachable only from a directory
    that has already set `needs_full`, and scanning the omitted files as well
    would add nothing but would cost precision: one test file importing another
    would drag every unrelated test in the directory onto the unomitted walk.

    The chain leaves the directory through an `-I` root, so a third scan closes
    it there. `finalize_includes` walks the include roots in COLLECTING mode,
    recording every module name their sources import; `_source_dir_entry` then
    escalates a directory whose omitted names appear in that record. A library
    that bare-imports `test_peer` therefore widens the directory holding
    `test_peer.mojo` and no other, which is what keeps the escalation from
    spreading to directories the include roots never name.
    """

    var active: Bool
    """Whether this is a test file's own directory rather than an `-I` root."""

    var skip_modules: List[String]
    """Module names of the discovered test files this walk omits."""

    var needs_full: Bool
    """True once a FRAMED source imports an omitted name or could not be read
    for its imports; the omission is then unsafe for every file here.

    A keyed file that names an omitted sibling does not set this: it abandons
    the omission for itself alone, in `file_key`, leaving its neighbours precise.
    """

    var collecting: Bool
    """Whether this walk records what its sources import rather than omitting.

    Set for the include-root walk `finalize_includes` performs. A walk is either
    omitting-and-proving (`active`) or collecting, never both: an `-I` root omits
    nothing, and a test file's own directory is not something the include walk
    reaches.
    """

    var imports: List[String]
    """Every module name a COLLECTING walk's sources named, in walk order."""

    var unscannable: Bool
    """True once a COLLECTING walk met a source whose imports could not be read.

    Such a source could name anything, so the record below it is incomplete and
    every omission in the session loses its licence.
    """

    @staticmethod
    def inert() -> _SourceDirScan:
        """A scan that omits nothing and learns nothing: a plain `-I` walk.

        Returns:
            An inactive scan.
        """
        return _SourceDirScan(
            False, List[String](), False, False, List[String](), False
        )

    @staticmethod
    def collector() -> _SourceDirScan:
        """A scan that omits nothing and records what it reads.

        Returns:
            A collecting scan with an empty record.
        """
        return _SourceDirScan(
            False, List[String](), False, True, List[String](), False
        )


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

comptime _S_IFREG = 0x8000
"""`S_IFREG`: the `st_mode` file-type value for a regular file."""


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
    mut scan: _SourceDirScan,
    at_top: Bool,
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
        scan: Inert for an `-I` root. Active for a test file's own directory,
            where it omits the discovered test files and records whether that
            omission turned out to be safe.
        at_top: Whether this is the walked root itself rather than a package
            inside it. Only the root's own entries are omitted: a bare import
            resolves against the directory, not into the packages under it.

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
            var inner = _walk_into(
                full, rel, sub^, kb, exclude_abs, scan, False
            )
            if not inner.ok:
                return inner^
            continue

        if not _is_source_name(name):
            continue
        if scan.active and at_top and is_discovered_test_name(name):
            # An entry point of its own, already keyed by its own source frame.
            # Framing it here as well would make editing any one file in a
            # directory rebuild every test that lives beside it.
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
        var proving = scan.active and not scan.needs_full
        if (proving or scan.collecting) and _is_scannable_name(name):
            # The bytes are already in hand, so reading the imports costs no
            # read of its own. A file whose imports cannot be read proves
            # nothing at all, and both modes take that the conservative way.
            var found = scan_imports(data)
            if not found.parsed:
                if proving:
                    # A helper that cannot be read cannot license leaving this
                    # directory's test files out.
                    scan.needs_full = True
                if scan.collecting:
                    # A library that cannot be read could import any omitted
                    # name in the session, so no directory's omission survives.
                    scan.unscannable = True
            else:
                if proving:
                    # A helper that imports an omitted test file puts that file
                    # back in the compiler's path one hop out, so the omission
                    # is abandoned for this whole directory.
                    for module in found.modules:
                        if _names_contain(scan.skip_modules, module):
                            scan.needs_full = True
                            break
                if scan.collecting:
                    for module in found.modules:
                        scan.imports.append(String(module))
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
    var scan = _SourceDirScan.inert()
    return _walk_include_root_scanned(root, dir, kb, exclude, scan)


def _walk_include_root_scanned(
    root: String,
    dir: String,
    mut kb: KeyBuilder,
    exclude: String,
    mut scan: _SourceDirScan,
) -> WalkOutcome:
    """`walk_include_root`, with the walk's scan handed back to the caller.

    Args:
        root: The invocation root; `dir` and `exclude` resolve against it.
        dir: The include root, as configured.
        kb: The builder to feed.
        exclude: One path to skip wherever the walk meets it, or empty.
        scan: Inert to frame the root and learn nothing, collecting to record
            what its sources import.

    Returns:
        Exactly what `walk_include_root` returns. Never raises.
    """
    var abs_dir = _absolute(root, dir)
    var listing = _list_sorted(abs_dir)
    if not listing:
        return WalkOutcome.failure("'" + dir + "' is not a readable directory")
    var exclude_abs = String("") if exclude == "" else _absolute(root, exclude)
    return _walk_into(
        abs_dir, "", listing.value().copy(), kb, exclude_abs, scan, True
    )


def _walk_source_dir(
    root: String, dir: String, mut kb: KeyBuilder, mut scan: _SourceDirScan
) -> WalkOutcome:
    """Feed a test file's own directory, omitting the test files in it.

    The same walk `walk_include_root` performs, with one difference: the entries
    mtest would discover as test files are left out of the top level, and every
    source that IS framed is scanned to prove leaving them out was safe. See
    `_SourceDirScan` for why both halves are needed.

    Args:
        root: The invocation root `dir` resolves against.
        dir: The directory, relative to `root`; `.` names the root itself.
        kb: The builder to feed.
        scan: Overwritten with this directory's omissions and the verdict on
            them. Meaningful only when the walk succeeds.

    Returns:
        The same outcomes `walk_include_root` returns, for the same reasons.
        Never raises.
    """
    var abs_dir = _absolute(root, dir)
    var listing = _list_sorted(abs_dir)
    if not listing:
        return WalkOutcome.failure("'" + dir + "' is not a readable directory")
    var names = listing.value().copy()
    scan.active = True
    scan.needs_full = False
    scan.skip_modules = List[String]()
    for entry in names:
        var name = String(entry)
        if name.startswith("."):
            continue
        if _is_source_name(name) and is_discovered_test_name(name):
            scan.skip_modules.append(_module_name(name))
    return _walk_into(abs_dir, "", names^, kb, String(""), scan, True)


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
        self.include_imports = List[String]()
        self.include_unscannable = False
        self.source_dirs = List[_SourceDirMemo]()
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
            info = _LibEntry(name^, Int(st.st_mode) & _S_IFMT, Int(st.st_size))
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
        if entry.kind == _S_IFREG:
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
        if entry.kind != _S_IFREG:
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
        var outcome = _walk_include_root_scanned(
            root, dir, ctx.prefix, "", scan
        )
        if not outcome.ok:
            # The walk's own words, not a generic "unreadable": a symlinked
            # package and an unreadable file are different things to fix.
            ctx.disable("include root '" + dir + "': " + outcome.reason)
            return
    ctx.include_imports = scan.imports.copy()
    ctx.include_unscannable = scan.unscannable


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


def ensure_cache_root(root: String) raises:
    """Create `<root>/.mtest-cache`, marking it only if this call made it.

    EVERY creation of that directory goes through here, not just the store's.
    The last-run reselection state lives in it too and is written whether or not
    the cache is enabled, so a project that has only ever run with `--no-cache`
    still has the directory — and if the marker were tied to staging, that
    directory would be unmarked and `--cache-clear` would refuse to delete a
    tree mtest itself had just created, blaming an older mtest that was never
    there. Every directory mtest makes is one mtest can prove it owns.

    The converse is what makes that proof worth anything, and it is why the
    `mkdir` here is exclusive rather than an "ensure it exists". A `.mtest-cache`
    that was ALREADY THERE was made by something else — an older mtest, another
    tool, or the user — and marking it would hand `clear_cache_root` a proof of
    ownership this process invented, one invocation after that same function
    refused to delete the directory for want of it. So an existing directory is
    used as-is and left unmarked, and `--cache-clear` keeps refusing it until the
    user removes it themselves.

    The marker is written to a unique temporary file in its own directory and
    renamed onto its final name, so a concurrent run can never observe a
    half-written tag — and `--cache-clear`, whose entire safety argument rests on
    the marker's contents, can never be defeated by a torn write. A directory
    whose marker cannot be written is removed again rather than left behind
    unmarked, since an unmarked directory is one no later run can ever prove is
    mtest's.

    Args:
        root: The invocation root the cache directory hangs under.

    Raises:
        Error: If the directory cannot be created or the marker cannot be
            written. A caller that only wanted a place to put state turns that
            into its own persistence failure; the store turns it into "no
            staging target", which degrades to an uncached build.

    Examples:

    ```mojo
    from mtest.session.store import ensure_cache_root

    ensure_cache_root("/repo")  # /repo/.mtest-cache now carries CACHEDIR.TAG
    ```
    """
    var cache_root = root + "/" + CACHE_ROOT_DIR
    # `mkdir` rather than `_ensure_dir`, because "did this call create it?" is
    # the whole question and `makedirs(exist_ok=True)` cannot answer it. The
    # exclusive create is also the arbiter between two mtest processes over one
    # checkout: exactly one of them sees success and writes the marker, and the
    # loser falls through to `_ensure_dir`, which no-ops on the directory that
    # now exists and still raises on a parent that will not take one.
    var created = True
    try:
        mkdir(cache_root)
    except:
        created = False
    if not created:
        _ensure_dir(cache_root)
        return
    var tag = root + "/" + CACHEDIR_TAG_REL
    var temp = create_unique_temp(cache_root + "/CACHEDIR.TAG.XXXXXX")
    var wrote = True
    try:
        write_all_fd(temp.fd, _cachedir_tag_text())
    except:
        wrote = False
    # The descriptor is discharged exactly once whether or not the write
    # succeeded; a failed write leaves only an empty temporary file behind.
    close_checked_fd(temp.fd)
    if not wrote:
        # Undo the creation. Leaving an unmarked directory would poison the
        # path permanently: no later run creates it, so no later run marks it,
        # and `--cache-clear` would refuse it forever over one transient write
        # failure. Both removals are best-effort — if they fail the next run
        # simply finds the directory and treats it as somebody else's.
        _discard(temp.path)
        try:
            rmdir(cache_root)
        except:
            pass
        raise Error(
            "session: could not write the cache ownership marker at '"
            + tag
            + "'"
        )
    rename_path(temp.path, tag)


def _ensure_store(root: String) raises:
    """Create the store directory under a marked cache root.

    Args:
        root: The invocation root the store hangs under.

    Raises:
        Error: If the directories cannot be created or the marker cannot be
            written. The caller turns that into "no staging target", which
            degrades to an uncached build.
    """
    ensure_cache_root(root)
    _ensure_dir(root + "/" + STORE_DIR)


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


def _discard_unreadable_generation(gen_abs: String, store_abs: String):
    """Remove an unreadable generation, moving undeletable litter aside.

    A failed read invalidates the generation even when it was a transient
    `EACCES`: the store cannot validate an artifact it cannot read, and its
    established rule is to discard every failed validation before rebuilding.
    Normal deletion remains the first choice. If permission bits prevent that
    deletion, a unique inert `.tmp-` name releases the final generation name
    for the rebuilt artifact; the unreadable directory then remains only as
    cache litter that no probe, publisher, or reaper serves.

    Args:
        gen_abs: The unreadable generation's absolute path.
        store_abs: The containing store directory's absolute path.
    """
    _discard(gen_abs)
    var kind: Int
    try:
        kind = Int(lstat(gen_abs).st_mode) & _S_IFMT
    except:
        return
    if kind != _S_IFDIR:
        return
    try:
        var tombstone = create_unique_temp(
            store_abs + "/" + _TMP_PREFIX + "unreadable.XXXXXX"
        )
        close_checked_fd(tombstone.fd)
        unlink(tombstone.path)
        rename_path(gen_abs, tombstone.path)
    except:
        pass


def cache_rebuild_note(rel: String) -> String:
    """Why a validated cache hit is being compiled after all.

    The store deletes a source's older generations when it publishes a new one,
    so a second run over the same checkout — another terminal, another shard
    with different build arguments — can remove a generation this run has
    already validated and is about to execute. The reader's answer is to build
    the file, because a cache condition must never fail a run that would
    otherwise pass; this is the sentence that says so.

    Args:
        rel: The test file's root-relative path.

    Returns:
        One sentence, ready for a `cache-rebuild` warning.

    Examples:

    ```mojo
    from mtest.session.store import cache_rebuild_note

    var note = cache_rebuild_note("tests/test_a.mojo")
    ```
    """
    var note = String("the cached binary for '") + rel
    note += "' was gone before it could run, so the file is being rebuilt."
    note += " Another mtest run over this checkout publishing a different key"
    note += " for the same file removes that file's older entries."
    return note^


def _ownership_proof_failure(root: String) -> Optional[String]:
    """Why `<root>/.mtest-cache` is not provably mtest's, or nothing if it is.

    The proof is the whole marker file, not its presence and not its first line.
    `CACHEDIR.TAG` is a published convention: the signature line is a fixed byte
    string shared by every tool that marks a cache directory, and users are
    actively encouraged to drop one into any directory they want backup tools to
    skip. A marker that merely exists, or that merely carries the convention's
    signature, therefore says somebody marked this as a cache — not that mtest
    created it. Only the exact text `_cachedir_tag_text` writes says that.

    Args:
        root: The invocation root the cache directory hangs under.

    Returns:
        What failed and what to do about it, ready to finish a refusal, or
        `None` when the marker is a regular file holding exactly what mtest
        writes. Never raises: an unprovable directory is a refusal, not an
        error.

        The two shapes are different facts with one remedy. mtest writes the
        marker only when it creates the directory itself, and neither writes one
        into a directory it finds nor overwrites one that is already there —
        either would manufacture the proof this function exists to demand. So a
        missing marker and a foreign marker both mean the same thing: nothing a
        later run does can make this directory provably mtest's, and the way out
        is the user's own deletion.
    """
    var tag = root + "/" + CACHEDIR_TAG_REL
    var quoted = String("the ownership marker '") + CACHEDIR_TAG_REL + "' "
    var manual = String(" delete the directory yourself with 'rm -rf ")
    manual += CACHE_ROOT_DIR
    manual += "'"

    # `lstat`, never `isfile`: a symlink at the marker's path is not the marker
    # mtest wrote, however ordinary the file it points at may be, and `isfile`
    # would follow it and answer yes.
    var kind: Int
    try:
        kind = Int(lstat(tag).st_mode) & _S_IFMT
    except:
        var absent = quoted + "is missing. mtest writes that marker only when"
        absent += " it creates '"
        absent += CACHE_ROOT_DIR
        absent += "' itself and never into one it finds, so a directory left"
        absent += " by an older mtest or by another tool stays refused until"
        absent += " you"
        absent += manual
        return Optional[String](absent^)

    var foreign = String("")
    if kind != _S_IFREG:
        foreign = quoted + "is not a regular file"
    else:
        var text: String
        try:
            var opened = read_bounded_regular_file(tag, _META_CAP)
            if not opened.is_regular:
                text = String("")
                foreign = quoted + "is not a regular file"
            else:
                text = opened.text.copy()
        except:
            # Unreadable, over the cap, or not UTF-8. mtest's marker is a few
            # short ASCII lines, so none of those can describe one.
            text = String("")
            foreign = quoted + "could not be read"
        if foreign == "" and text != _cachedir_tag_text():
            foreign = quoted + "does not hold the text mtest writes into it"
    if foreign == "":
        return Optional[String](None)
    foreign += ". mtest writes that marker itself and never overwrites one it"
    foreign += " finds, so this directory stays refused until you"
    foreign += manual
    return Optional[String](foreign^)


def clear_cache_root(root: String) -> Optional[String]:
    """Delete `<root>/.mtest-cache` whole, but only where mtest can prove it
    owns it.

    `--cache-clear`'s entire implementation, and the one place in mtest that
    removes a directory the USER named rather than one mtest invented. Three
    guards stand between the flag and the removal, in this order:

    1. The path is characterized `lstat`-no-follow FIRST. A symlink is REFUSED,
       never removed and never followed — following it would delete whatever it
       points at, which is outside the tree mtest owns.
    2. The directory must hold the `CACHEDIR.TAG` marker mtest writes when it
       creates the directory — as a regular file, holding exactly the text mtest
       writes. Presence alone proves nothing: `CACHEDIR.TAG` is a published
       convention whose signature line every cache-marking tool writes, and
       users add one by hand to keep backups out, so a marker somebody else
       wrote would otherwise hand mtest deletion rights over their directory.
       There is deliberately no "but its contents look like ours" exception
       either: that heuristic is exactly how a directory somebody else created
       gets deleted. A checkout whose cache predates the marker therefore
       refuses ONCE, and the diagnostic says so and hands over the manual
       removal.
    3. Removal itself goes through `remove_tree_no_follow`, which unlinks child
       symlinks rather than descending them, so the blast radius stays inside
       the proven directory.

    An ABSENT cache root is success, not a diagnostic: there is nothing to
    clear, which is the ordinary shape of a first run. A root that cannot be
    characterized AT ALL — an unsearchable parent — is reported the same way,
    because `lstat` cannot separate the two through a Mojo `Error`. Both end
    with nothing deleted, which is the honest outcome either way; the run that
    follows is simply cold.

    Args:
        root: The invocation root the cache directory hangs under.

    Returns:
        Nothing when the directory was deleted or was already absent; otherwise
        a complete, framed diagnostic for main to print before exiting 4. Every
        refusal leaves the filesystem exactly as it found it. A removal that
        FAILS partway is not a refusal — it is the one outcome that leaves the
        disk changed, and its diagnostic says so.

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
    var unproven = _ownership_proof_failure(root)
    if unproven:
        var unmarked_note = String("cache-clear: ") + cache_root
        unmarked_note += ": refusing to delete a directory mtest cannot prove"
        unmarked_note += " it owns — " + unproven.value()
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

    Built by `file_key` from the session prefix plus the source's own frames, so
    two files of one session differ by those frames alone and two sessions over
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

    Required by the publication protocol:
    `store_publish` re-digests the SOURCE before publishing, and its signature
    carries no path to re-read. `gen_name` cannot supply one — mangling is
    lossy for an over-budget name — so the path travels with the key.
    """

    var src_sha: String
    """The source's content digest at key time, and the publication guard's
    reference: a build whose source moved underneath it must never publish."""

    var src_dir: String
    """The directory whose walk this key framed, relative to the invocation
    root.

    Carried for the same reason `src_rel` is: the publication guard re-walks it,
    and `gen_name` cannot supply the path back.
    """

    var dir_sha: String
    """The source directory's walk digest at key time.

    The guard's reference for every build input that is not the entry source. A
    helper beside the test is as much a build input as the test itself, and it
    can move inside the same window the entry source can.
    """

    var dir_full: Bool
    """Which of the two walks produced `dir_sha`.

    The omitting walk and the unomitted one give different digests over the same
    directory, so the guard has to repeat the one the key actually used.
    """


def _source_dir(rel: String) -> String:
    """The directory the compiler resolves `rel`'s bare imports against.

    Args:
        rel: A test file's root-relative path.

    Returns:
        The path's directory relative to the invocation root, or `.` for a file
        sitting at the root itself — the spelling the walk wants, since `.`
        names the root the same way `tests` names a subdirectory.
    """
    var dir = dirname(rel)
    return String(".") if dir == "" else dir^


def _source_dir_entry(mut ctx: CacheContext, root: String, dir: String) -> Int:
    """Walk `dir` once per session and remember the result.

    Every test file in one directory shares that walk, so a suite of forty files
    in one directory reads the directory's sources once rather than forty times.

    Args:
        ctx: The session context. The memo lands in it, and it is DISABLED when
            the directory cannot be characterized.
        root: The invocation root `dir` resolves against.
        dir: The directory, relative to `root`.

    Returns:
        The memo's index in `ctx.source_dirs`, or `-1` when the directory could
        not be walked — in which case the cache is already off, carrying the
        walk's own words about which link or file to fix. Never raises.
    """
    for i in range(len(ctx.source_dirs)):
        if ctx.source_dirs[i].dir == dir:
            return i
    var kb = KeyBuilder()
    var scan = _SourceDirScan.inert()
    var outcome = _walk_source_dir(root, dir, kb, scan)
    if not outcome.ok:
        ctx.disable("test directory '" + dir + "': " + outcome.reason)
        return -1
    # The third side of the omission proof. The walk above and `file_key`'s own
    # scan cover what this directory and the keyed file name; neither can see a
    # module under an `-I` root naming an omitted file from outside. Escalation
    # follows the NAME, so a library that imports `test_peer` widens the one
    # directory that omits `test_peer` and leaves every other directory precise —
    # unless no include-root source could be read at all, in which case the
    # record is incomplete and no omission here is licensed.
    var needs_full = scan.needs_full
    if not needs_full and len(scan.skip_modules) > 0:
        if ctx.include_unscannable:
            needs_full = True
        else:
            for module in ctx.include_imports:
                if _names_contain(scan.skip_modules, module):
                    needs_full = True
                    break
    ctx.source_dirs.append(
        _SourceDirMemo(
            String(dir),
            kb^.digest_full(),
            String(""),
            scan.skip_modules.copy(),
            needs_full,
        )
    )
    return len(ctx.source_dirs) - 1


def _source_dir_full_digest(
    mut ctx: CacheContext, root: String, index: Int
) -> Optional[String]:
    """The unomitted walk of a memoized directory, computed at most once.

    Args:
        ctx: The session context; the answer is memoized into it, and it is
            DISABLED when the walk fails.
        root: The invocation root the directory resolves against.
        index: The memo's index in `ctx.source_dirs`.

    Returns:
        The digest of the directory walked with nothing left out, or `None` when
        that walk failed — the omitting walk skipped exactly the files this one
        reads, so it can fail where the first succeeded. Never raises.
    """
    if ctx.source_dirs[index].full_digest != "":
        return Optional(String(ctx.source_dirs[index].full_digest))
    var dir = String(ctx.source_dirs[index].dir)
    var kb = KeyBuilder()
    var outcome = walk_include_root(root, dir, kb, "")
    if not outcome.ok:
        ctx.disable("test directory '" + dir + "': " + outcome.reason)
        return None
    var digest = kb^.digest_full()
    ctx.source_dirs[index].full_digest = String(digest)
    return Optional(digest^)


def file_key(
    mut ctx: CacheContext, root: String, rel: String
) -> Optional[FileKey]:
    """Fork the session prefix and key one test file.

    The prefix already covers the toolchain, the environment, the root, the
    build arguments, and every include root's contents; this appends the frames
    that distinguish this file from its neighbours. Forking rather than
    rebuilding is why `KeyBuilder` is copyable: the shared prefix is absorbed
    once per session, not once per file.

    Those frames are the file's own bytes AND a walk of the directory it sits
    in. The directory is not an accident of layout: the compiler resolves a bare
    `from helper import ...` against the source file's own directory, with no
    `-I` involved and nothing reported afterwards about what it read, so a
    helper beside a test is as much a build input as a file under an include
    root. Keying only the test file served a binary compiled against the
    previous helper and reported a green run over source that had changed.

    The directory walk leaves out the entries mtest would DISCOVER as test
    files, because each is an independent entry point already carrying its own
    source frame; folding them in would make one edit rebuild every test in the
    directory. That omission is proved safe rather than assumed, and the proof
    is deliberately two-sided. THIS file's imports are read here, so a test file
    naming an omitted neighbour keys over the whole directory — by itself,
    leaving its neighbours precise, since its own import says nothing about
    theirs. `_SourceDirScan` runs the matching scan over the files the walk
    FRAMES, where a match escalates the entire directory, because a helper
    naming an omitted neighbour puts that neighbour on the path of everything
    importing the helper. A source whose imports cannot be read at all takes the
    conservative branch on whichever side met it.

    The proof reaches out of the directory as well. `finalize_includes` reads
    every source it frames under an `-I` root and records what those sources
    import, and `_source_dir_entry` walks a directory whole when its omitted
    names appear in that record — so a library that bare-imports a name matching
    a test file in this directory puts that file back in the key, and a library
    whose imports cannot be read withdraws every omission in the session.

    A directory that is ALSO an `-I` root has its contents framed twice, once
    per search path it occupies. That is harmless duplication rather than a case
    to special-case away: a key with one frame too many only ever costs a
    rebuild.

    Args:
        ctx: The finalized session context. `prefix` is read, each directory's
            walk is memoized into it, and it is disabled if a directory cannot
            be characterized.
        root: The invocation root `rel` resolves against.
        rel: The test file's root-relative path.

    Returns:
        The key, or `None` when the source could not be read at all or its
        directory could not be walked. `None` is the caller's cue to treat the
        file as a per-file miss AND to disable the cache: a source that will not
        read is about to fail the build anyway, and a key that cannot cover its
        own inputs must not be written. A failed walk has already disabled the
        cache with a reason naming the directory, and `disable` keeps the first
        reason, so the caller's own generic message cannot bury it.

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
    var dir = _source_dir(rel)
    var index = _source_dir_entry(ctx, root, dir)
    if index < 0:
        return None
    var use_full = ctx.source_dirs[index].needs_full
    if not use_full:
        var found = scan_imports(data)
        if not found.parsed:
            use_full = True
        else:
            for module in found.modules:
                if _names_contain(ctx.source_dirs[index].skip_modules, module):
                    use_full = True
                    break
    var walk_digest: String
    if use_full:
        var full = _source_dir_full_digest(ctx, root, index)
        if not full:
            return None
        walk_digest = full.value()
    else:
        walk_digest = String(ctx.source_dirs[index].digest)
    var src_sha = sha256_hex(data)
    var kb = ctx.prefix.copy()
    kb.feed_str(TAG_SOURCE_DIR, dir)
    kb.feed_str(TAG_SOURCE_DIR_WALK, walk_digest)
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
            dir^,
            walk_digest^,
            use_full,
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

    The mangled source name leads, and it is not decoration. The compiler child
    writes here for the whole of a first-attempt build, and when publication
    fails the test child runs from here too — so for as long as either is alive
    its argv is `<this directory>/bin`. Anything identifying that child from
    outside the process — the release contract's SIGINT probe, a `ps` a human
    reads during a hang — has only that path to go on, and a name built from pid
    and clock alone put the source nowhere in it. A child that could not be
    named could not be found.

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
    MISS. A hit has proven all six of:

    1. The generation path is a real directory — characterized NO-FOLLOW and
       first, because everything after it reads through that path.
    2. `meta` is a regular file that parses completely.
    3. `meta.key_full` equals the WHOLE key, not just the 128 bits its name
       carries.
    4. `bin` is a real file inside the generation — characterized NO-FOLLOW
       too, and before anything reads or spawns it. The directory being genuine
       says nothing about what is in it: a `bin` linked out of the store would
       be executed, and would report whatever it liked, while `meta` recorded
       the digest of the link's target and every other check passed.
    5. `bin` can be executed by this process. It is asked before the digest
       because it is a single `access(2)` against a whole-file read, and because
       a generation that cannot be spawned is unusable however well its bytes
       verify — an archive restore, a container `COPY`, or a `chmod -R` over the
       checkout drops the mode bits while leaving the content untouched.
    6. `bin` is readable.
    7. `bin`'s content digest equals the digest `meta` recorded.

    Any failed check discards the generation, so a corruption cannot be re-read
    on the next probe and the next build republishes cleanly. A failed root
    listing is the unreadable case: ordinary deletion is attempted first, then
    an undeletable directory is moved to an inert temporary name so it cannot
    block publication. A transient `EACCES` gets the same treatment because an
    artifact the store cannot validate must never be served. The removal unlinks
    a child symlink rather than descending it, so refusing a linked `bin` never
    reaches whatever it pointed at. The one deliberate exception is a SYMLINK
    at the generation path itself: that is refused and left exactly where it
    is, because a link the cache did not create is not the cache's to delete.

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

    # `lstat` above established that this path is a real directory. A failed
    # listing therefore means unreadable rather than absent — the same
    # distinction `_toolchain_lib_listing` preserves for key inputs. Do this
    # before trying `meta`: an unreadable generation cannot be recursively
    # removed, so simply treating its unreadable record as a normal miss would
    # leave the final name occupied and make every later publish fail.
    if not _list_sorted(gen_abs):
        _discard_unreadable_generation(gen_abs, root + "/" + STORE_DIR)
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

    # --- Check 4: the binary is a real file inside this generation. ---------
    # `lstat`, never `is_executable_file` or `isfile`: both follow, and the one
    # path in this function that gets EXECUTED is exactly the one that must not
    # be allowed to leave the store.
    var bin_abs = gen_abs + "/" + _BIN_NAME
    var bin_kind: Int
    try:
        bin_kind = Int(lstat(bin_abs).st_mode) & _S_IFMT
    except:
        _discard(gen_abs)
        return _probe_miss()
    if bin_kind != _S_IFREG:
        _discard(gen_abs)
        return _probe_miss()

    # --- Check 5: the binary can actually be spawned. -----------------------
    var runnable: Bool
    try:
        runnable = is_executable_file(bin_abs)
    except:
        # The query itself failed, so executability is unknown — and unknown
        # resolves to unusable, the same way every other question here does.
        runnable = False
    if not runnable:
        # Deleted like any other corruption, which is what makes this
        # self-healing: a hit on an unspawnable binary would route the run to an
        # internal error and re-serve the same artifact on every later run.
        _discard(gen_abs)
        return _probe_miss()

    # --- Checks 6 and 7: the binary reads and is the one recorded. ----------
    var bin_bytes: List[UInt8]
    try:
        bin_bytes = read_regular_file_bytes(bin_abs, _BIN_CAP)
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


comptime STORE_FAULT_ENV = "MTEST_STORE_FAULT"
"""The test-only publication fault seam's environment variable.

Read once per `store_publish` call and never fed to a `KeyBuilder`. See the
module docstring's "The publication fault seam" note for why the seam exists
and what each recognized value abandons.
"""

comptime _FAULT_BEFORE_FSYNC = "before-fsync"
"""Abandon the publication before the durability flush."""

comptime _FAULT_BEFORE_RENAME = "before-rename"
"""Abandon the publication after the flush and before the commit rename."""


def _store_fault() -> String:
    """The publication fault requested for this call, or the empty string.

    Goes through `_env_value`, the accessor `MODULAR_HOME` already uses, so an
    unset variable and one set to the empty string reach the same inert answer
    without inventing a second convention for the same question.

    Returns:
        The variable's value verbatim, or the empty string when it is unset. An
        unrecognized value is returned as-is and acts as no fault at all — the
        seam must never grow a third, unreviewed window by typo.
    """
    var requested = _env_value(STORE_FAULT_ENV)
    if not requested:
        return String("")
    return String(requested.value())


def _fault_abandoned(
    target: StoreBuildTarget,
    argv: List[String],
    window: String,
    src_rel: String,
) -> PublishResult:
    """The `PUB_FAILED` result one fault window produces.

    Args:
        target: The staging target, whose binary the caller keeps running.
        argv: The command line the build ran, returned verbatim.
        window: The recognized `MTEST_STORE_FAULT` value that fired.
        src_rel: The source whose publication was abandoned.

    Returns:
        A `PUB_FAILED` result whose warning names the variable, the window, and
        the file, so a scenario can tell the two windows apart from outside.
    """
    return _publish_failed(
        target,
        argv,
        String(STORE_FAULT_ENV)
        + "="
        + window
        + ": test-only fault abandoned the publication of '"
        + src_rel
        + "'",
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


comptime _DIGEST32_LEN = 32
"""Hex digits `KeyBuilder.digest32` renders, and so how many follow `_h` in
every generation name this store writes."""


def _has_digest32_tail(name: String, start: Int) -> Bool:
    """Whether `name` from `start` onward is exactly a generation's key prefix.

    Args:
        name: A directory name inside the store.
        start: The index just past the `_h` separator.

    Returns:
        True iff exactly `_DIGEST32_LEN` bytes remain and every one of them is
        a lowercase hex digit — the only tail `generation_name` ever produces.
    """
    var bytes = name.as_bytes()
    if len(bytes) - start != _DIGEST32_LEN:
        return False
    for i in range(start, len(bytes)):
        var b = bytes[i]
        var is_digit = b >= UInt8(ord("0")) and b <= UInt8(ord("9"))
        var is_hex_letter = b >= UInt8(ord("a")) and b <= UInt8(ord("f"))
        if not is_digit and not is_hex_letter:
            return False
    return True


def _reap_siblings(root: String, key: FileKey):
    """Delete this source's other generations, keeping one live per file.

    An editing loop produces a new key per edit, and without this every one of
    them would keep its binary forever. A sibling has to look like something
    this store wrote, which is three things and not one: the mangled source
    name, the `_h` separator that no mangled name can contain, and then exactly
    the 32 hex digits `generation_name` puts there. Matching the first two
    alone would delete any directory somebody else parked in the store under a
    name that merely starts like one of this source's builds. Staging
    directories are skipped by name as well: one of them may belong to a
    concurrent process that is compiling into it right now.

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
        if not _has_digest32_tail(name, prefix.byte_length()):
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

    1. **The publication guard.** Re-digest the SOURCE and re-walk its
       DIRECTORY, and compare both to what the key was built from. An input
       edited while its compile was in flight produced a binary this key does
       not describe, and publishing it would serve those bytes to every later
       run whose key still names the old snapshot. The guard covers the whole
       directory the compiler resolves bare imports against, not the entry
       source alone, because a helper beside a test is as much a build input as
       the test. Nothing is published; the caller runs what it built.

       The cost is a second walk of one directory, and it is paid only on a
       miss, where a compile has already been paid for.

       **What this proves, exactly.** Two samples — one before the build, one
       after — detect an input that is DIFFERENT at publication. They cannot
       detect one that changed and changed back while the compiler was reading
       it: both samples agree, and the binary came from bytes neither of them
       saw. Closing that would take a snapshot the compiler reads from instead
       of the live tree; sampling more often only narrows it. So the honest
       claim is a persistent edit is caught and an edit-and-undo inside the
       compile window is not (§8.5.1).

       Nor does this re-prove the session-wide inputs: include-root contents
       and the toolchain are sampled once per session, so their window is the
       whole run rather than one compile.
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
    # The test-only fault seam, read ONCE so both windows below answer the same
    # question — a real fault strikes one publication, not a variable that could
    # change under it mid-call. Absent, empty, and unrecognized are all inert.
    # See the module docstring; nothing here reaches a key.
    var fault = _store_fault()
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
    # The entry source is only one of the file's inputs. Everything the compiler
    # resolves a bare import against sits beside it, was sampled when the key
    # was computed, and can move in exactly the window this guard exists to
    # close. Re-walking the directory is what proves the binary came from the
    # snapshot the key names rather than merely starting from the same file.
    var dir_kb = KeyBuilder()
    var dir_outcome: WalkOutcome
    if key.dir_full:
        dir_outcome = walk_include_root(root, key.src_dir, dir_kb, "")
    else:
        var scan = _SourceDirScan.inert()
        dir_outcome = _walk_source_dir(root, key.src_dir, dir_kb, scan)
    if not dir_outcome.ok:
        return _publish_failed(
            target,
            argv,
            "could not re-read the directory of '"
            + key.src_rel
            + "' after building it",
        )
    if dir_kb^.digest_full() != key.dir_sha:
        return _publish_failed(
            target, argv, "a source beside '" + key.src_rel + "' changed"
        )

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
    if fault == _FAULT_BEFORE_FSYNC:
        return _fault_abandoned(target, argv, _FAULT_BEFORE_FSYNC, key.src_rel)
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
    if fault == _FAULT_BEFORE_RENAME:
        return _fault_abandoned(target, argv, _FAULT_BEFORE_RENAME, key.src_rel)
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
    4. The source's closure. A directory source contributes an include walk of
       itself, as `walkfile` frames. A single-file source contributes its own
       `precompile-src` file frame, then a `precompile-src-dir` frame naming the
       directory it sits in and an include walk of that directory — the compiler
       resolves the file's bare imports there, so a module beside it is compiled
       into this step's package.
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
        # The named file's own directory, by the same walk a directory source
        # gets. A bare `from sibling import ...` in `lib/pkg.mojo` resolves
        # against `lib/`, with no `-I` involved, so the sibling is compiled into
        # this step's package and an edit to it has to move this step's key —
        # otherwise the stamp still validates, the compile is skipped, and every
        # test binary built against the stale package can hit as well.
        #
        # The walk omits nothing, unlike a test file's directory walk: a
        # precompile source is not one entry point among many that each carry
        # their own key, so there is no omission to make and none to prove safe.
        # `out_path` is excluded for the reason every walk here excludes it.
        var src_dir = _source_dir(src)
        kb.feed_str(TAG_PRECOMPILE_SRC_DIR, src_dir)
        var beside = walk_include_root(root, src_dir, kb, out_path)
        if not beside.ok:
            ctx.disable("precompile step '" + src + "': " + beside.reason)
            return None

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
    # publication guard to re-digest a source for. The directory fields are
    # inert for the same reason. `FileKey` is reused for the digests and the
    # name; the fields it carries for the generation protocol are unused here.
    return Optional(
        FileKey(
            digest32^,
            digest_full^,
            gen_name^,
            stamp_rel^,
            String(src),
            src_sha^,
            String(""),
            String(""),
            False,
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
