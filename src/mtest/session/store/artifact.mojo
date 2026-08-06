"""Per-file keys and the store protocol: stage, probe, publish, retain.

Layer 4 (`session`), inside `store`. The protocol that decides whether a stored
binary may be run, and how a fresh one becomes stored.

`file_key` forks `ctx.prefix` and appends the test file's own frames — a walk of
the directory it sits in, then the file itself — which name the generation
`<mangled>_h<digest32>` under `STORE_DIR`. The directory is there because the
compiler resolves a bare import against the source file's own directory, so a
helper beside a test is a build input no `-I` frame covers; the walk is memoized
per directory, so a suite sharing one directory pays for it once, and it omits
the directory's own test files so that editing one test does not rebuild its
neighbours.

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

Two of the store's TEST-ONLY fault names are read here. `before-fsync` abandons
a publication before the durability flush, leaving a staging directory that was
never flushed; `before-rename` abandons it after the flush and before the commit
rename, so the generation is fully durable and simply never committed. Both take
the ordinary `PUB_FAILED` path — the staged binary stays alive and the session
keeps running it — so the seam introduces no state and no control flow the
protocol does not already have. `published-absent` moves a just-committed
generation aside before the caller executes it, pinning the driver contract for
the otherwise unavoidable pathname gap in a concurrent quarantine.
`scripts/tests/test_cache_protocol.py` drives the two publication windows and
asserts the property they exist to demonstrate: an interrupted publication
leaves no generation a later run could probe.
"""
from std.os import listdir, lstat, mkdir, unlink
from std.os.path import dirname, islink
from std.time import perf_counter_ns

from mtest.cache import (
    KeyBuilder,
    MetaFile,
    generation_name,
    scan_imports,
    sha256_hex,
)
from mtest.platform import (
    S_IFDIR,
    S_IFLNK,
    S_IFMT,
    S_IFREG,
    close_checked_fd,
    create_unique_temp,
    fsync_path,
    is_executable_file,
    path_kind,
    process_id,
    read_bounded_regular_file,
    read_regular_file_bytes,
    rename_path,
)
from mtest.session.scratch import _mangle
from mtest.session.store.context import CacheContext, _SourceDirMemo
from mtest.session.store.filesystem import (
    STORE_DIR,
    STORE_FAULT_ENV,
    _BIN_NAME,
    _META_CAP,
    _META_NAME,
    _TMP_ATTEMPTS,
    _TMP_PREFIX,
    _discard,
    _discard_unreadable_generation,
    _ensure_store,
    _settle_own_directories,
)
from mtest.session.store.support import (
    _BIN_CAP,
    _WALK_FILE_CAP,
    _absolute,
    _env_value,
    _list_sorted,
)
from mtest.session.store.tags import (
    TAG_SOURCE,
    TAG_SOURCE_DIR,
    TAG_SOURCE_DIR_WALK,
)
from mtest.session.store.walk import (
    WalkOutcome,
    _SourceDirScan,
    _StatWitness,
    _append_witnesses,
    _first_moved_witness,
    _names_contain,
    _walk_include_root_scanned,
    _walk_source_dir,
    _witness_entry,
    walk_include_root,
)


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

    var input_witnesses: List[_StatWitness]
    """Every keyed input's filesystem identity and change times at key time.

    NOT part of the key, and deliberately: the key says what a build IS, and
    two runs over the same bytes must agree on it however their inodes and
    timestamps differ. These say whether the tree held still while the compiler
    read it, which is a question only publication asks. They ride here because
    this is the one value that already travels from keying to every publication
    site.
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
    var witnesses = List[_StatWitness]()
    var outcome = _walk_source_dir(root, dir, kb, scan, witnesses)
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
            witnesses^,
            List[_StatWitness](),
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
    var scan = _SourceDirScan.inert()
    var witnesses = List[_StatWitness]()
    var outcome = _walk_include_root_scanned(root, dir, kb, "", scan, witnesses)
    if not outcome.ok:
        ctx.disable("test directory '" + dir + "': " + outcome.reason)
        return None
    var digest = kb^.digest_full()
    ctx.source_dirs[index].full_digest = String(digest)
    ctx.source_dirs[index].full_witnesses = witnesses^
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
    _settle_own_directories(root)
    var witnesses = List[_StatWitness]()
    # Captured before the read, so nothing that happens after this point can
    # pass itself off as the state the key describes. A capture that fails is a
    # source that cannot be characterized, which is the same `None` an
    # unreadable one produces.
    var src_abs = _absolute(root, rel)
    try:
        _witness_entry(src_abs, rel, islink(src_abs), witnesses)
    except:
        return None
    var data: List[UInt8]
    try:
        data = read_regular_file_bytes(src_abs, _WALK_FILE_CAP)
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
        _append_witnesses(witnesses, ctx.source_dirs[index].full_witnesses)
    else:
        walk_digest = String(ctx.source_dirs[index].digest)
        _append_witnesses(witnesses, ctx.source_dirs[index].witnesses)
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
            witnesses^,
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
    - still keyed by the `.tmp-` prefix alone in `_sibling_generations`, which
      tests that prefix BEFORE the mangled-name prefix, so this source's own
      live staging directory never enters the ranking and is skipped rather
      than deleted out from under a concurrent process compiling into it.

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
    MISS. A hit has proven all seven of:

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
        kind = path_kind(gen_abs)
    except:
        # Absent, or in a directory this process cannot search. Either way
        # there is nothing here to trust and nothing to delete.
        return _probe_miss()
    if kind == S_IFLNK:
        return _probe_miss()
    if kind != S_IFDIR:
        # A plain file (or a device, or a socket) where a generation belongs is
        # not a generation, and it occupies the name the next publish needs.
        _discard(gen_abs)
        return _probe_miss()

    # Check 1 above established that this path is a real directory. A failed
    # listing therefore means unreadable rather than absent — the same
    # distinction `_toolchain_lib_listing` preserves for key inputs. Do this
    # before trying `meta`: an unreadable generation cannot be recursively
    # removed, so simply treating its unreadable record as a normal miss would
    # leave the final name occupied and make every later publish fail.
    if not _list_sorted(gen_abs):
        _discard_unreadable_generation(
            gen_abs, root + "/" + STORE_DIR, key.gen_name
        )
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
    # No-follow: `is_executable_file` and `isfile` both follow, and the one
    # path in this function that gets EXECUTED is exactly the one that must not
    # be allowed to leave the store.
    var bin_abs = gen_abs + "/" + _BIN_NAME
    var bin_kind: Int
    try:
        bin_kind = path_kind(bin_abs)
    except:
        _discard(gen_abs)
        return _probe_miss()
    if bin_kind != S_IFREG:
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


comptime _FAULT_BEFORE_FSYNC = "before-fsync"
"""Abandon the publication before the durability flush."""

comptime _FAULT_BEFORE_RENAME = "before-rename"
"""Abandon the publication after the flush and before the commit rename."""


comptime _FAULT_PUBLISHED_ABSENT = "published-absent"
"""Hide a newly committed generation before its caller executes it."""


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


def _fault_hide_published_generation(final_abs: String, store_abs: String):
    """Move a committed generation to inert litter for the driver fault seam.

    Args:
        final_abs: The newly committed generation directory.
        store_abs: Its containing store directory.
    """
    var hidden = String("")
    try:
        var temp = create_unique_temp(
            store_abs + "/" + _TMP_PREFIX + "published-absent.XXXXXX"
        )
        hidden = temp.path.copy()
        close_checked_fd(temp.fd)
        unlink(hidden)
        rename_path(final_abs, hidden)
    except:
        if hidden != "":
            _discard(hidden)


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


comptime _RETAIN_GENERATIONS = 2
"""Live generations kept per source.

One made the ordinary alternation — switching a file between two states, which
is what a branch switch and back does — recompile in both directions forever.
Two make it hit from the second cycle on while an editing loop stays bounded.
Not configurable: the number is a property of the alternation it exists to
serve, not a preference."""

comptime _SEQ_NAME = "seq"
"""The recency record inside a generation.

Canonical nonnegative decimal, at most `_SEQ_MAX_DIGITS` of them, exactly one
trailing newline. Written into staging before the rename so a visible
generation always carries one, and corrected after the rename when a sibling
is at least as new, so sequence order tracks VISIBILITY order. Every deviation
from the format reads as 0 — oldest, first out — which is the compatibility
rule for generations written before the record existed and the damage rule in
one. Never a `meta` line: that parser is strict, and no cache hit ever reads
this file, which is what keeps the record invisible to every binary that
predates it."""

comptime _SEQ_CAP = 32
"""Largest recency record this store will read, in bytes. Anything above it is
not a record this store wrote, and is not read at all."""

comptime _SEQ_MAX_DIGITS = 15
"""Most digits a recency record may carry.

Fifteen keeps `max + 1` far inside `Int` and keeps damage convergent: a
damaged-but-parseable large value is still read by ALLOCATION, so the next
publication allocates above it and the damaged generation stops being newest.
"""

comptime _SEQ_MAX = 999999999999999
"""The `_SEQ_MAX_DIGITS`-digit maximum a recency record can express.

Allocation and correction saturate here rather than write a sixteen-digit
record, which this module's own parser would read as 0. Reaching it needs a
planted record — publication increments by one, so a store would have to
publish a thousand million million generations of one source to arrive here on
its own — and the whole cost is rebuilds, never a wrong binary served.

The cost is worth stating in full, because it is broader than the planted
generation itself. Once ANY generation of a source carries this value, every
later generation of that source saturates here too, so the records all tie and
ranking falls back to comparing names: retention then keeps the generation just
published and the greatest-named sibling rather than the two newest. It stays
bounded at `_RETAIN_GENERATIONS` — `_own_ranks_above` is what guarantees that —
and the planted generation is retained for as long as it sits there."""


def _read_seq(path: String) -> Int:
    """Read a generation's recency record, or 0 for anything that is not one.

    Args:
        path: The record's path.

    Returns:
        The recorded value, or 0 — "oldest" — for every deviation from the
        format: absent, unreadable, not a regular file, over `_SEQ_CAP` bytes,
        empty, signed, zero-padded, not decimal, not terminated by exactly one
        newline, or longer than `_SEQ_MAX_DIGITS`. Total by construction: a
        caller ranking generations must be handed a number, never an error it
        would have to turn into a policy decision of its own.
    """
    var kind: Int
    var size: Int
    try:
        var info = lstat(path)
        kind = Int(info.st_mode) & S_IFMT
        size = Int(info.st_size)
    except:
        return 0
    if kind != S_IFREG or size > _SEQ_CAP:
        return 0
    var data: List[UInt8]
    try:
        data = read_regular_file_bytes(path, _SEQ_CAP)
    except:
        return 0
    var digits = len(data) - 1
    if digits < 1 or digits > _SEQ_MAX_DIGITS:
        return 0
    if data[digits] != UInt8(ord("\n")):
        return 0
    # Canonical: one representation per value, so two writers that agree on a
    # number cannot disagree about which record is newer.
    if digits > 1 and data[0] == UInt8(ord("0")):
        return 0
    var value = 0
    for i in range(digits):
        var b = data[i]
        if b < UInt8(ord("0")) or b > UInt8(ord("9")):
            return 0
        value = value * 10 + (Int(b) - ord("0"))
    return value


def _write_seq(path: String, value: Int) raises:
    """Write a recency record in the one format `_read_seq` accepts.

    Args:
        path: The record's path.
        value: The sequence to record; at most `_SEQ_MAX`.

    Raises:
        Error: If the file cannot be created or written.
    """
    with open(path, "w") as f:
        f.write(String(value) + "\n")


comptime _SEQ_TMP_NAME = "seq-next"
"""Where a corrected recency record is written before it replaces `seq`.

Inside the generation, so the replacement is one `rename(2)` within a single
directory. Rewriting `seq` in place would truncate it first, and a concurrent
reaper reading that window gets 0 — which is exactly the value a stale listing
already holds for a record it could not read, so re-reading it would CONFIRM
the stale ranking rather than refute it, and the identity guard would wave
through a deletion it exists to stop. Only the process that published a
generation ever corrects it, so this name has exactly one writer."""


def _replace_seq(gen_abs: String, value: Int) raises:
    """Put `value` in a published generation's record, atomically.

    A reader sees the old record or the new one, never a partial write, which
    the in-place rewrite this replaced could not promise. The rename also
    REPLACES whatever occupies the record's name rather than writing through
    it, so a symlink planted at `seq` between the rename and this correction is
    overwritten instead of followed.

    Args:
        gen_abs: The generation directory, absolute.
        value: The corrected sequence.

    Raises:
        Error: If the record cannot be written, flushed, or renamed into place.
    """
    var tmp_abs = gen_abs + "/" + _SEQ_TMP_NAME
    _write_seq(tmp_abs, value)
    fsync_path(tmp_abs)
    rename_path(tmp_abs, gen_abs + "/" + _SEQ_NAME)


@fieldwise_init
struct _GenRecord(Copyable, Movable):
    """One generation of a source, as a single listing saw it."""

    var name: String
    """The generation directory's name inside the store."""

    var seq: Int
    """Its recency record, as `_read_seq` parsed it."""

    var ino: Int
    """Its directory's inode number, from a no-follow `lstat`. Generation names
    are deterministic, so the name alone cannot tell one publication's
    directory from a later one's at the same name."""


def _sibling_generations(root: String, key: FileKey) -> List[_GenRecord]:
    """Every OTHER generation of this source, with its recency and identity.

    A sibling has to look like something this store wrote, which is three
    things and not one: the mangled source name, the `_h` separator that no
    mangled name can contain, and then exactly the 32 hex digits
    `generation_name` puts there. Matching the first two alone would collect
    any directory somebody else parked in the store under a name that merely
    starts like one of this source's builds. Staging directories are skipped by
    name as well: one of them may belong to a concurrent process that is
    compiling into it right now.

    Args:
        root: The invocation root.
        key: The key whose siblings are wanted; its own generation is excluded.

    Returns:
        One record per match, in listing order. An entry that vanished between
        the listing and its `lstat` contributes nothing — there is neither
        anything to rank nor anything to delete. Never raises: an unreadable
        store yields no records, and the caller keeps whatever it has.
    """
    var out = List[_GenRecord]()
    var prefix = _mangle(key.src_rel) + "_h"
    var store_abs = root + "/" + STORE_DIR
    var names = List[String]()
    try:
        for entry in listdir(store_abs):
            names.append(String(entry))
    except:
        return out^
    for entry in names:
        var name = String(entry)
        if name == key.gen_name or name.startswith(_TMP_PREFIX):
            continue
        if not name.startswith(prefix):
            continue
        if not _has_digest32_tail(name, prefix.byte_length()):
            continue
        var gen_abs = store_abs + "/" + name
        var ino: Int
        try:
            ino = Int(lstat(gen_abs).st_ino)
        except:
            continue
        var seq = _read_seq(gen_abs + "/" + _SEQ_NAME)
        out.append(_GenRecord(name.copy(), seq, ino))
    return out^


def _ranks_above(a: _GenRecord, b: _GenRecord) -> Bool:
    """Whether `a` is newer than `b` in the store's recency order.

    Args:
        a: The candidate.
        b: The generation it is compared against.

    Returns:
        True iff `a` carries the higher record, or the same record and the
        greater name. Names are unique within one listing, so this is a TOTAL
        order and "the top `_RETAIN_GENERATIONS`" is never ambiguous — two
        generations that predate the record both read 0 and are still ranked
        against each other deterministically.
    """
    if a.seq != b.seq:
        return a.seq > b.seq
    return a.name > b.name


def _own_ranks_above(own: _GenRecord, other: _GenRecord) -> Bool:
    """Whether the generation just published outranks `other`.

    The same order as `_ranks_above` except that a TIE goes to `own`. Records
    tie only where the order has saturated at `_SEQ_MAX` or where a correction
    could not be written, and in both cases `own` is the generation that just
    became visible, so it IS the newer of the two. Ranking it by name there
    instead would let a publication whose name happens to sort low rank itself
    out of the top `_RETAIN_GENERATIONS` while still refusing to delete itself,
    which leaves the source one generation over the target permanently rather
    than until the next publication.

    Args:
        own: The generation just published.
        other: A sibling it is compared against.

    Returns:
        True iff `own` carries the higher record, or the same one.
    """
    if own.seq != other.seq:
        return own.seq > other.seq
    return True


def _discard_ranked_out(store_abs: String, record: _GenRecord):
    """Delete a ranked-out generation unless it is no longer the one ranked.

    Generation names are deterministic, so between the listing that ranked this
    record out and this deletion another run can publish a NEW generation at
    the same name. Deleting that costs the other run a rebuild of work it had
    already finished. Re-reading the directory's inode and its recency record
    immediately before the removal, and skipping the deletion when either
    moved, is what spares a freshly republished generation from a stale
    listing.

    What this protects is a generation REPUBLISHED under the same name, which
    is the case a deterministic naming scheme makes likely. It does not protect
    a generation that has not changed yet: one sitting between its own rename
    and its own correction still carries the number it allocated, so a rival
    ranking it out sees an inode and a record that both match, and deletes it.
    Nothing here takes a lock, and the window between these checks and the
    removal beneath them stays open too. The worst a lost race costs is one
    rebuild — the publisher's `PUB_OK` names a path that has just gone, the run
    fails to spawn it, and the session rebuilds the file with a warning rather
    than failing. Never a wrong binary.

    Args:
        store_abs: The store directory, absolute.
        record: The generation as the ranking listing saw it.
    """
    var gen_abs = store_abs + "/" + record.name
    var ino: Int
    try:
        ino = Int(lstat(gen_abs).st_ino)
    except:
        # Gone already, or unreachable. Either way there is nothing here that
        # this reaper is entitled to remove.
        return
    if ino != record.ino:
        return
    if _read_seq(gen_abs + "/" + _SEQ_NAME) != record.seq:
        return
    _discard(gen_abs)


def _correct_visibility_seq(root: String, key: FileKey):
    """Rank this generation above every sibling visible to it right now.

    A publisher allocates its recency record before it stages, and can rename
    long afterwards, so the record it allocated describes the store as it was
    BEFORE its own generation existed. Ranking on that alone would let a late
    publisher call itself the oldest generation of its source and, keeping the
    newest few, delete a generation that finished ahead of it. Re-listing after
    the rename and rewriting the record above the highest sibling is what
    dissolves that: a publisher is always ranked above everything it can see
    when it corrects, so it never evicts a rival on the strength of a number it
    chose before that rival existed.

    **What this orders, exactly.** Publications end up ordered by when they
    CORRECTED, which is not the same as when they became visible: two
    publishers that rename in one order can correct in the other, and then the
    one that became visible first outranks the one that became visible second.
    Nothing is lost while both are retained; the cost surfaces one publication
    later, when the lower-ranked of the two is reaped even though it was the
    newer to appear. That is one rebuild if someone returns to its state, and
    it is the price of having no lock. Ordering by rename time instead would
    take one, because the record has to be inside the directory the rename
    commits and so cannot be written any earlier.

    The rewrite goes through `_replace_seq`, so a concurrent reader sees the
    old record or the new one and never a partial write. It runs exactly once,
    with no re-check loop, so a store under continuous publication cannot
    livelock here.

    Args:
        root: The invocation root.
        key: The key whose generation has just been renamed into place.
    """
    var gen_abs = root + "/" + key.gen_dir
    var mine = _read_seq(gen_abs + "/" + _SEQ_NAME)
    var highest = 0
    for record in _sibling_generations(root, key):
        if record.seq > highest:
            highest = record.seq
    if highest < mine:
        return
    var corrected = highest + 1
    if corrected > _SEQ_MAX:
        corrected = _SEQ_MAX
    try:
        _replace_seq(gen_abs, corrected)
    except:
        # Best-effort: the generation is published and valid either way, and an
        # uncorrected record risks only this generation ageing out early. Clear
        # the staging name so a failed correction leaves no residue inside a
        # generation a later run will list.
        _discard(gen_abs + "/" + _SEQ_TMP_NAME)


def _reap_siblings(root: String, key: FileKey):
    """Keep this source's newest few generations and discard the rest.

    An editing loop produces a new key per edit, and without this every one of
    them would keep its binary forever. Keeping exactly one made the ordinary
    alternation — a file switched between two states and back — recompile in
    both directions, so `_RETAIN_GENERATIONS` of them survive, ranked by the
    recency record `_correct_visibility_seq` has just put in visibility order.

    Two properties are worth stating exactly.

    **The generation just published is never discarded here.** The caller is
    about to run the binary inside it. The correction above normally makes it
    the newest anyway; when a race means it is not, it is kept regardless and
    the store transiently holds one more than `_RETAIN_GENERATIONS`.

    **There is no lock.** Racing publishers are ordinary — different build
    arguments key differently against the same unchanged tree — so under a race
    the store may transiently hold more than `_RETAIN_GENERATIONS`, because
    every deletion whose victim changed identity is skipped. A race can also
    cost a rival one rebuild: the check-to-delete window is one, and a
    generation between its own rename and its own correction is another, since
    it is visible carrying only the number it allocated and nothing about it
    has changed for the guard to notice. What can never happen is a wrong
    binary served — the probe revalidates key and digest by pathname and reads
    no recency record — and no ranking can reach a generation this store did
    not write. Once publications quiesce, the next publication reaps to exactly
    the top `_RETAIN_GENERATIONS`.

    Args:
        root: The invocation root.
        key: The key just published; its own generation is kept.
    """
    var store_abs = root + "/" + STORE_DIR
    var records = _sibling_generations(root, key)
    var gen_abs = root + "/" + key.gen_dir
    var own_ino: Int
    try:
        own_ino = Int(lstat(gen_abs).st_ino)
    except:
        own_ino = 0
    var own = _GenRecord(
        String(key.gen_name), _read_seq(gen_abs + "/" + _SEQ_NAME), own_ino
    )
    # A few generations per source, so counting how many rank above each one
    # beats sorting: no comparator threading, and the survivors are named by
    # the same total order that decided them.
    for i in range(len(records)):
        var newer = 0
        if _own_ranks_above(own, records[i]):
            newer += 1
        for j in range(len(records)):
            if i != j and _ranks_above(records[j], records[i]):
                newer += 1
        if newer >= _RETAIN_GENERATIONS:
            _discard_ranked_out(store_abs, records[i])


def store_publish(
    root: String,
    key: FileKey,
    target: StoreBuildTarget,
    build_seconds: Float64,
    argv: List[String],
) -> PublishResult:
    """Promote a staged build into its generation, atomically or not at all.

    The protocol, in order:

    1. **The publication guard**, in two halves. First re-stat every input the
       key sampled — the entry source, the framed files beside it, each
       directory the walk descended, and both ends of every symlink among them
       — and compare each against the identity and change times captured when
       it was keyed. Then re-digest the SOURCE and re-walk its DIRECTORY and
       compare both to what the key was built from. An input that moved in
       either sense produced a binary this key does not describe, and
       publishing it would serve those bytes to every later run whose key still
       names the old snapshot. The guard covers the whole directory the compiler
       resolves bare imports against, not the entry source alone, because a
       helper beside a test is as much a build input as the test. Nothing is
       published; the caller runs what it built.

       The cost is one stat per input plus a second walk of one directory, and
       it is paid only on a miss, where a compile has already been paid for.

       **What this proves, exactly.** Content re-sampling alone detects an input
       that is DIFFERENT at publication and nothing else: an input edited and
       edited back while the compiler was reading it leaves both samples
       agreeing about bytes neither of them saw. The stat comparison is what
       closes that, and it closes it because the undo is itself a metadata
       event — userspace can restore bytes and backdate an mtime, but `ctime`
       only moves forward, and a name written afresh lands on a new inode. A
       file created beside the test and deleted again leaves no file to compare
       at all, which is why each walked directory contributes a record of its
       own: its times move on the membership change.

       What remains outside it: deliberate metadata restoration by a process
       running as this user, a mutate-and-restore that completes inside one
       filesystem timestamp tick without changing the size, and coarse-timestamp
       filesystems generally. The stability rule — build inputs hold still while
       a compiler invocation runs — is still the contract; this turns its
       accidental violations into refused publications (§8.5.1).

       Nor does this re-prove the session-wide inputs: include-root contents and
       the toolchain are sampled once per session, so their window is the whole
       run rather than one compile, and no publication can re-check them.
    2. Allocate this generation's place in its source's recency order, one
       above the highest record any sibling carries right now. Provisional,
       because a rival can become visible between here and the rename.
    3. Rewrite the recorded command line's `-o` to the FINAL generation path,
       so the reproduce line names something that exists after publication.
    4. Digest the staged binary and write `meta` and the recency record beside
       it, so a generation always carries its place in the order the moment it
       becomes visible.
    5. `fsync` the binary, both records, and the staging directory, so a
       machine crash cannot leave a committed directory entry pointing at bytes
       that never reached the disk.
    6. `rename(2)` the staging directory onto the generation path. One syscall,
       no half-published state, no window a concurrent reader can observe.
    7. On success, flush the store directory, correct the recency record above
       every sibling now visible — which is what makes the order a ranking of
       visibility rather than of allocation — and reap this source's
       generations down to the newest few.

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
    # The witness comes first. Content proves what the build read only if the
    # tree held still while it read it, and an input edited and edited back
    # leaves both content samples agreeing about bytes the compiler never saw.
    # Identity and change times cannot be restored from userspace, so comparing
    # them against their key-time values refuses that publication — and it is
    # the cheap check as well, so it runs before the re-read and the re-walk.
    var moved_input = _first_moved_witness(key.input_witnesses)
    if moved_input != "":
        return _publish_failed(
            target,
            argv,
            "'" + moved_input + "' changed while the build ran",
        )
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
    # This walk wants content only: the witness above already compared every
    # record this walk would take, against the values captured at key time
    # rather than against a second capture from the same moment.
    var unwitnessed = List[_StatWitness]()
    if key.dir_full:
        dir_outcome = walk_include_root(root, key.src_dir, dir_kb, "")
    else:
        var scan = _SourceDirScan.inert()
        dir_outcome = _walk_source_dir(
            root, key.src_dir, dir_kb, scan, unwitnessed
        )
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

    # --- Step 2: allocate this generation's place in the recency order. -----
    # One listing, taken before anything is staged into place, because the
    # record has to be inside the directory the rename commits and so cannot be
    # written after it. What this listing cannot see is a rival that renames
    # between here and Step 6; the correction after the rename is what answers
    # that, and it is why this value is only provisional.
    var provisional = 1
    for record in _sibling_generations(root, key):
        if record.seq >= provisional:
            provisional = record.seq + 1
    if provisional > _SEQ_MAX:
        provisional = _SEQ_MAX

    # --- Steps 3 and 4: digest the artifact and record it. ------------------
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
    # The recency record joins the generation before the rename, so a visible
    # generation always carries one. A staging write that fails refuses the
    # publication rather than committing a generation nothing can rank: an
    # unranked generation reads as the oldest there is and would be reaped
    # ahead of work that really is older, and the caller still runs the binary
    # it just built either way.
    try:
        _write_seq(tmp_abs + "/" + _SEQ_NAME, provisional)
    except:
        return _publish_failed(
            target,
            argv,
            "could not write the cache recency record for '"
            + key.src_rel
            + "'",
        )

    # --- Step 5: durability before the commit. ------------------------------
    if fault == _FAULT_BEFORE_FSYNC:
        return _fault_abandoned(target, argv, _FAULT_BEFORE_FSYNC, key.src_rel)
    try:
        fsync_path(bin_abs)
        fsync_path(tmp_abs + "/" + _META_NAME)
        fsync_path(tmp_abs + "/" + _SEQ_NAME)
        fsync_path(tmp_abs)
    except:
        return _publish_failed(
            target,
            argv,
            "could not flush the cache generation for '" + key.src_rel + "'",
        )

    # --- Step 6: the commit. ------------------------------------------------
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

    # --- Step 7: make the commit durable, correct the order, then reap. -----
    # Best-effort: the rename already succeeded, and refusing to report a
    # published generation because its parent directory would not flush would
    # cost a rebuild for no gain in safety.
    try:
        fsync_path(root + "/" + STORE_DIR)
    except:
        pass
    _correct_visibility_seq(root, key)
    _reap_siblings(root, key)
    if fault == _FAULT_PUBLISHED_ABSENT:
        _fault_hide_published_generation(
            root + "/" + key.gen_dir, root + "/" + STORE_DIR
        )
    return PublishResult(PUB_OK, final_bin_rel^, recorded^, String(""))
