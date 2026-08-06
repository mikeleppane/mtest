"""Precompile-step stamps: keying a step, and skipping one that still holds.

Layer 4 (`session`), inside `store`, above `artifact`.

A precompile step is not a test file and its stamp is not a generation. It
produces ONE artifact the user named (`-o`), which stays exactly where it was
promoted to; the cache neither moves it nor owns it. So there is nothing to
stage and nothing to publish — only a STAMP saying "an output with this digest
at this path was produced for this key", which is the whole of what lets the
next run skip the compile.

Two properties are specific to this shape and neither has an analogue in
`artifact`.

**The key comes from `ctx.base`, never from `ctx.prefix`.** `prefix` is `base`
plus every include walk, and a step's own output directory BECOMES an include
root the moment the step succeeds. Keying a step on the walk its own output
takes part in is circular: the first run's key would describe a tree without the
package and the second run's key a tree with it, so the stamp could never be
hit. Forking `base` and walking this step's inputs explicitly is what breaks
that.

**A step is skipped only if its OUTPUT still matches.** A generation's binary
lives inside a directory the cache owns and nothing outside it writes; a
precompile output sits in the user's tree, where a later `mojo build`, a `rm`,
or a half-finished editor save can reach it. So the probe re-digests the
artifact every time rather than trusting that a stamp implies its output.

**Stamps do NOT go through `artifact`'s probe and publish, and should not.**
The two pairs look alike from a distance. They are not alike where it counts.

`store_probe` takes a generation DIRECTORY the cache owns: it lists it, reads a
`meta` beside a `bin` inside it, checks that binary is a regular file, checks it
can be spawned, digests it, and hands back a path to run plus the recorded argv
and build duration. Every failure discards the whole directory, and an
unreadable one goes through the tombstone quarantine. `precompile_probe` takes a
single stamp FILE and an artifact that lives outside the cache entirely: it has
no directory to list, no binary to spawn, no argv or duration to return — only a
Bool — and a failure discards one file. Four of the seven checks have no
subject here, and the one that matters most, re-digesting an artifact the cache
does not own, has no counterpart there.

`store_publish` commits by renaming a STAGED DIRECTORY the compiler wrote into,
then allocates a recency record and reaps the source's older generations down to
the retained count. A stamp has no staging directory (the step's output was
already promoted where the user asked for it), no recency order, and no
retention set beyond "one live stamp per step" — `_reap_stamps` keeps exactly
one, unconditionally.

What genuinely overlaps is already shared and is imported rather than copied:
`MetaFile` renders and parses both records, so one strict parser guards both;
`FileKey` names both; `read_bounded_regular_file` under `_META_CAP` reads both;
`sha256_hex` compares both digests. The residue is "write a small record and
rename it into place", and the tree has three of those with three different
error policies — `_write_meta` writes into staging that a later directory rename
commits, `ensure_cache_root` raises and undoes its own `mkdir` on a failed
write, and `precompile_publish` gives up silently because a missing stamp costs
one recompile. A shared writer would need a policy knob per caller, which is
more indirection than the four lines it removes. So: keep them separate.
"""
from std.os import listdir, lstat
from std.os.path import isdir, islink

from mtest.cache import KeyBuilder, MetaFile, generation_name, sha256_hex
from mtest.platform import (
    S_IFLNK,
    close_checked_fd,
    create_unique_temp,
    fsync_path,
    path_kind,
    read_bounded_regular_file,
    read_regular_file_bytes,
    rename_path,
    write_all_fd,
)
from mtest.session.scratch import _ensure_dir, _mangle
from mtest.session.store.artifact import FileKey, _source_dir
from mtest.session.store.context import CacheContext
from mtest.session.store.filesystem import (
    STORE_DIR,
    _META_CAP,
    _TMP_PREFIX,
    _discard,
    _ensure_store,
    _settle_own_directories,
)
from mtest.session.store.support import (
    _BIN_CAP,
    _WALK_FILE_CAP,
    _absolute,
)
from mtest.session.store.tags import (
    TAG_INCLUDE,
    TAG_PRECOMPILE_INCLUDE_ABSENT,
    TAG_PRECOMPILE_OUT,
    TAG_PRECOMPILE_PRIOR,
    TAG_PRECOMPILE_SRC,
    TAG_PRECOMPILE_SRC_DIR,
    TAG_PRECOMPILE_STEP,
)
from mtest.session.store.walk import (
    _SourceDirScan,
    _StatWitness,
    _first_moved_witness,
    _walk_include_root_scanned,
    _witness_entry,
)


comptime PRECOMPILE_SUBDIR = "precompile"
"""The stamp directory, inside `STORE_DIR`.

A sibling of the generations rather than a name among them: a generation is a
DIRECTORY holding `bin`, `meta`, and `seq`, a stamp is a single file, and
`_reap_siblings` walks `STORE_DIR` ranking and deleting by mangled-name prefix.
Keeping the two namespaces apart means neither reaper can ever reach the
other's records.
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
    from mtest.session.store.stamps import precompile_stamp_rel

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
    mut witnesses: List[_StatWitness],
) -> Bool:
    """Frame every earlier step's promoted output, in step order.

    Args:
        ctx: The session context; disabled when an output cannot be read.
        root: The invocation root the outputs resolve against.
        src: The step being keyed, named in any disable reason.
        prior_outputs: The earlier steps' output paths, in the order the steps
            were configured.
        kb: The builder to feed.
        witnesses: Grown with one record per prior output, taken before its
            read; see `_StatWitness`.

    Returns:
        True once every prior output is framed; False when one could not be
        read, in which case the cache is already off.
    """
    for entry in prior_outputs:
        var prior = String(entry)
        var prior_abs = _absolute(root, prior)
        var data: List[UInt8]
        try:
            _witness_entry(prior_abs, prior, islink(prior_abs), witnesses)
            data = read_regular_file_bytes(prior_abs, _BIN_CAP)
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
    _settle_own_directories(root)
    var kb = ctx.base.copy()
    var witnesses = List[_StatWitness]()
    var scan = _SourceDirScan.inert()
    kb.feed_str(TAG_PRECOMPILE_STEP, src)
    kb.feed_str(TAG_PRECOMPILE_OUT, out_path)

    # --- The source's closure. ----------------------------------------------
    # `mojo precompile` takes either a single file or a package directory, and
    # the two cover different input sets: one file's bytes, or everything `-I`
    # on that directory would make visible.
    var src_sha = String("")
    if isdir(_absolute(root, src)):
        var walked = _walk_include_root_scanned(
            root, src, kb, out_path, scan, witnesses
        )
        if not walked.ok:
            # The walk's own words: a symlinked package and an unreadable file
            # are different things for the user to fix.
            ctx.disable("precompile step '" + src + "': " + walked.reason)
            return None
    else:
        var src_abs = _absolute(root, src)
        var data: List[UInt8]
        try:
            # Before the read, as everywhere: the walk of the file's own
            # directory below records it a second time, but that walk runs after
            # this read and so cannot vouch for the bytes this read took.
            _witness_entry(src_abs, src, islink(src_abs), witnesses)
            data = read_regular_file_bytes(src_abs, _WALK_FILE_CAP)
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
        var beside = _walk_include_root_scanned(
            root, src_dir, kb, out_path, scan, witnesses
        )
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
        var walked = _walk_include_root_scanned(
            root, dir, kb, out_path, scan, witnesses
        )
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
    if not _feed_prior_outputs(ctx, root, src, prior_outputs, kb, witnesses):
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
    # source to re-digest. The directory fields are inert for the same reason.
    # `input_witnesses` is NOT: `precompile_publish` re-checks it before
    # stamping, because a step's inputs move in the same window a test file's
    # do and a stamp outlives the session that wrote it.
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
            witnesses^,
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
        kind = path_kind(stamp_abs)
    except:
        # Absent, or in a directory this process cannot search. Either way there
        # is nothing here to trust and nothing to delete.
        return False
    if kind == S_IFLNK:
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
    discipline the deletion-authorization marker and every generation use.

    Nothing is recorded when one of the step's inputs moved while the step ran.
    A stamp records the pre-build key and digests only the OUTPUT, so an input
    edited during the step and restored afterwards would match that stamp
    forever and every dependent binary would be compiled against the stale
    package. The identity and change times captured when the step was keyed are
    re-checked here first, and a moved — or no longer stattable — input leaves
    the step unstamped, so the next session runs it again.

    Superseded stamps for this same source are reaped first, so an editing loop
    leaves one stamp per step rather than one per edit.

    Best-effort throughout, and deliberately: a stamp that cannot be written
    costs one recompile on the next run, while failing a session over it would
    be exactly the "cache condition fails an otherwise green run" the design
    forbids. A withheld stamp is silent for the same reason — there is nothing
    for a user to act on in a step that will simply run again. Never raises.

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
    # First, and before the output is read: the step's output may well be
    # correct, but what cannot be claimed is that it was produced from the
    # inputs this key names. A handful of stats settles that, and there is no
    # reason to digest a package the answer is about to discard.
    if _first_moved_witness(key.input_witnesses) != "":
        return
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
