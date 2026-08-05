"""The cache root, its deletion-authorization marker, and no-follow deletion.

Layer 4 (`session`), inside `store`. Where the cache's directories come from
and how they go away.

`ensure_cache_root` writes the `CACHEDIR.TAG` marker on EVERY path that CREATES
the directory, including the one that only wants somewhere to keep last-run
state, and on no other path: a directory that was already there was made by
somebody else, and marking it would manufacture deletion authority for a
directory this invocation did not create. The whole marker text matters because
`CACHEDIR.TAG` is a shared convention and its presence says nothing about who
owns the directory. `clear_cache_root` deletes the whole cache root only when
that whole text matches.

Deletion goes through `remove_tree_no_follow`, which refuses a symlinked root
and unlinks child symlinks rather than descending them. The per-call I/O it is
built from is Layer 0's; the policy above it — what may be deleted, and the
tombstone dance that keeps an unreadable generation from being stranded — is
this module's.

The store fault seam this module reads is TEST ONLY. `MTEST_STORE_FAULT` comes
in through the same accessor `MODULAR_HOME` goes through, and what it reads
never reaches a `KeyBuilder`: it is not a key input, not a config field, and not
part of the tag namespace. Absent or empty — the only shape any real invocation
has — means no effect at all, and so does any value outside the five names the
store recognizes. `unreadable-replacement` moves the test-prepared replacement
into the final name after unreadable detection and before quarantine, pinning
that the atomic move reconciles the object it actually moved.
`unreadable-tombstone-lstat` faults identity inspection after that move, so the
helper has to restore rather than strand its only generation under a tombstone.
`unreadable-prepare-failure` faults Darwin's permission preparation, pinning
that quarantine still gets its own authoritative attempt.
"""
from std.os import listdir, lstat, mkdir, rmdir, unlink

from mtest.platform import (
    S_IFDIR,
    S_IFLNK,
    S_IFMT,
    S_IFREG,
    close_checked_fd,
    create_unique_temp,
    path_kind,
    prepare_directory_for_rename,
    read_bounded_regular_file,
    rename_path,
    write_all_fd,
)
from mtest.session.scratch import _ensure_dir
from mtest.session.store.support import _env_value, _list_sorted


comptime STORE_DIR = ".mtest-cache/build-v1"
"""The store's root, relative to the invocation root.

Dot-prefixed, which is what keeps `walk_include_root` out of it: an include root
of `.` would otherwise hash the cache's own contents into the key that decides
what the cache serves, and no run could ever hit twice.
"""

comptime CACHE_ROOT_DIR = ".mtest-cache"
"""The whole cache directory, relative to the invocation root.

`STORE_DIR` lives inside it, and so does the last-run reselection state, which
is why the deletion-authorization marker sits HERE rather than beside the
generations: `--cache-clear` deletes this directory, so the marker has to
authorize deleting this whole tree.
"""

comptime CACHEDIR_TAG_REL = ".mtest-cache/CACHEDIR.TAG"
"""The deletion-authorization marker, relative to the invocation root.

Spelled out rather than composed from `CACHE_ROOT_DIR`, because the pinned
toolchain's `comptime` bindings are literals; the two must agree, and
`test_marker_written_at_mtest_cache_root` checks the path that ships.
"""

comptime CACHEDIR_TAG_SIGNATURE = "Signature: 8a477f597d28d172789f06886806bc55"
"""The first line every `CACHEDIR.TAG` carries, per the cachedir convention.

Backup and archiving tools recognize this exact byte string and skip the
directory holding it — which is correct for a build cache, and a free side
effect of the marker that authorizes `--cache-clear` deletion.
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
        The standard signature line, then two comment lines naming the cache
        creator and the convention as the reference.
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
    there. Every directory mtest makes carries the marker that authorizes its
    `--cache-clear` deletion.

    The converse is what makes that authorization meaningful, and it is why the
    `mkdir` here is exclusive rather than an "ensure it exists". A `.mtest-cache`
    that was ALREADY THERE was made by something else — an older mtest, another
    tool, or the user — and marking it would hand `clear_cache_root` deletion
    authority this process invented, one invocation after that same function
    refused to delete the directory for want of it. So an existing directory is
    used as-is and left unmarked, and `--cache-clear` keeps refusing it until the
    user removes it themselves.

    The marker is written to a unique temporary file in its own directory and
    renamed onto its final name, so a concurrent run can never observe a
    half-written tag — and `--cache-clear`, whose entire safety argument rests on
    the marker's contents, can never be defeated by a torn write. A directory
    whose marker cannot be written is removed again rather than left behind
    unmarked, since no later run can authorize `--cache-clear` deletion there.

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
            "session: could not write the cache deletion-authorization marker"
            " at '"
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


def _settle_own_directories(root: String):
    """Create the directories this run writes into, before anything is keyed.

    A walked directory's record stands for its membership, and mtest writes
    into the tree as it works: `.mtest-cache` is created under the invocation
    root at the first staging, which is AFTER the keys that record the
    directory holding it. For a test file sitting at the invocation root that
    directory is the walked one, so on a cold tree the run's own first write
    looks exactly like a file appearing beside the source, and every
    publication after it is refused — the whole session under the pool, since
    every file is keyed before the first staging. Creating the directory up
    front is what stops a run from witnessing itself.

    Nothing here can change a key: the cache root is dot-prefixed, and every
    walk skips dot entries.

    Best-effort. A directory that cannot be created here fails again where it
    is actually needed, with the diagnostic that belongs to that site.

    Args:
        root: The invocation root.
    """
    try:
        _ensure_store(root)
    except:
        pass


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
        # No-follow, because `isdir` follows a link: a symlink-to-directory
        # would be recursed into and the TARGET's contents deleted.
        var kind = path_kind(child)
        if kind == S_IFDIR:
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
    # swapped for a symlink between this `path_kind` and the `listdir` below
    # not be caught. Closing that needs `openat`/`unlinkat` walking descriptors,
    # which the pinned `std.os` does not expose and which would cost this module
    # three more foreign declarations. The window is inside a directory mtest
    # created and owns, and the no-follow checks still make every step refuse
    # what it can see; this is a narrowing, not a proof.
    var kind = path_kind(path)
    if kind == S_IFLNK:
        raise Error(
            "session: refusing to remove '"
            + path
            + "': it is a symlink, and the cache deletes only what it owns"
        )
    if kind != S_IFDIR:
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


comptime STORE_FAULT_ENV = "MTEST_STORE_FAULT"
"""The test-only store fault seam's environment variable."""

comptime _FAULT_UNREADABLE_REPLACEMENT = "unreadable-replacement"
"""Move the test-prepared replacement between detection and quarantine."""


comptime _FAULT_UNREADABLE_TOMBSTONE_LSTAT = "unreadable-tombstone-lstat"
"""Fail the post-move identity read after the original reaches its tombstone."""


comptime _FAULT_UNREADABLE_PREPARE_FAILURE = "unreadable-prepare-failure"
"""Fail permission preparation before the quarantine rename."""


def _restore_tombstone(tombstone_path: String, gen_abs: String):
    """Put a moved generation back unless a newer nonempty one occupies it.

    Directory `rename(2)` refuses to replace a nonempty target, so a publisher
    that filled `gen_abs` after quarantine claimed the original is never
    overwritten. Failure leaves the tombstone as inert store-owned litter,
    which is safer than deleting a binary another process may have begun to
    execute.

    Args:
        tombstone_path: The private pathname holding the moved generation.
        gen_abs: Its public generation pathname.
    """
    try:
        rename_path(tombstone_path, gen_abs)
    except:
        pass


def _discard_unreadable_generation(
    gen_abs: String, store_abs: String, gen_name: String
):
    """Remove an unreadable generation without racing a replacement.

    A failed read invalidates the generation even when it was a transient
    `EACCES`: the store cannot validate an artifact it cannot read, and its
    established rule is to discard every failed validation before rebuilding.
    The generation's device/inode pair is captured before the unreadable list.
    The final pathname then moves atomically to a private name, and that moved
    directory's identity decides the result: the observed unreadable directory
    is discarded; a readable replacement that arrived meanwhile is restored.
    Restoring uses directory `rename(2)`, which refuses to replace a nonempty
    newer generation, so a later publisher remains runnable. An undeletable
    original remains inert `.tmp-` litter that no probe, publisher, or reaper
    serves.

    Args:
        gen_abs: The unreadable generation's absolute path.
        store_abs: The containing store directory's absolute path.
        gen_name: The generation's one-component name within `store_abs`.
    """
    var observed_dev: Int
    var observed_ino: Int
    var kind: Int
    try:
        var observed = lstat(gen_abs)
        observed_dev = Int(observed.st_dev)
        observed_ino = Int(observed.st_ino)
        kind = Int(observed.st_mode) & S_IFMT
    except:
        return
    if kind != S_IFDIR:
        return
    if _list_sorted(gen_abs):
        return

    var requested = _env_value(STORE_FAULT_ENV)
    # Darwin refuses to rename a write-disabled directory even within one
    # parent. The platform helper opens the canonical store as an anchor, then
    # identity-checks and changes the observed one-component generation without
    # following any path below that anchor. A preparation failure does not
    # suppress the rename: Linux needs no preparation, and Darwin's rename
    # remains the authoritative attempt.
    try:
        if requested and requested.value() == _FAULT_UNREADABLE_PREPARE_FAILURE:
            raise Error("test-only unreadable preparation fault")
        prepare_directory_for_rename(
            store_abs, gen_name, observed_dev, observed_ino
        )
    except:
        pass

    # This names one test-only interleaving: a peer has prepared a valid
    # generation in the store and publishes it after this helper observed the
    # unreadable directory. Production runs never set the fault, so no extra
    # filesystem mutation occurs outside the existing quarantine protocol.
    if requested and requested.value() == _FAULT_UNREADABLE_REPLACEMENT:
        try:
            rename_path(
                store_abs + "/" + _TMP_PREFIX + "unreadable-replacement",
                gen_abs,
            )
        except:
            pass

    var tombstone_path = String("")
    try:
        var tombstone = create_unique_temp(
            store_abs + "/" + _TMP_PREFIX + "unreadable.XXXXXX"
        )
        tombstone_path = tombstone.path.copy()
        close_checked_fd(tombstone.fd)
        unlink(tombstone_path)
        rename_path(gen_abs, tombstone_path)
    except:
        if tombstone_path != "":
            _discard(tombstone_path)
        return
    var moved_dev: Int
    var moved_ino: Int
    try:
        if requested and requested.value() == _FAULT_UNREADABLE_TOMBSTONE_LSTAT:
            raise Error("test-only tombstone identity fault")
        var moved = lstat(tombstone_path)
        moved_dev = Int(moved.st_dev)
        moved_ino = Int(moved.st_ino)
    except:
        # Moving the final path above created a temporary absence. If inspecting
        # the moved object fails, restoration is the only safe conservative
        # answer: leaving it private would make a cache cleanup turn into a
        # spawn-time ENOENT for another session. `_restore_tombstone` refuses to
        # overwrite a newer nonempty generation a publisher may have installed.
        _restore_tombstone(tombstone_path, gen_abs)
        return
    if moved_dev == observed_dev and moved_ino == observed_ino:
        _discard(tombstone_path)
        return
    if not _list_sorted(tombstone_path):
        _discard(tombstone_path)
        return
    # A valid replacement raced in after the unreadable observation. If another
    # publisher has already filled `gen_abs`, this directory-to-directory rename
    # fails because that generation contains `meta` and `bin`; retain this
    # private duplicate rather than overwrite a newer final generation.
    try:
        rename_path(tombstone_path, gen_abs)
    except:
        pass


def cache_rebuild_note(rel: String) -> String:
    """Why a stored binary is being compiled after all.

    A second run can replace or quarantine a generation after this run validates
    it, and the same race can reach an artifact this run just published. The
    reader's answer is to build the file, because a cache condition must never
    fail a run that would otherwise pass; this is the cause-neutral sentence
    that says so.

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
    var note = String("the stored binary for '") + rel
    note += "' could not be started, so the file is being rebuilt."
    note += " Another mtest run may have replaced or quarantined that"
    note += " generation."
    return note^


def _deletion_authorization_failure(root: String) -> Optional[String]:
    """Why `<root>/.mtest-cache` does not authorize `--cache-clear` deletion.

    Authorization is the whole marker file, not its presence and not its first
    line.
    `CACHEDIR.TAG` is a published convention: the signature line is a fixed byte
    string shared by every tool that marks a cache directory, and users are
    actively encouraged to drop one into any directory they want backup tools to
    skip. A marker that merely exists, or that merely carries the convention's
    signature, therefore says somebody marked this as a cache — not that mtest
    created it. Only the exact text `_cachedir_tag_text` writes authorizes this
    deletion.

    Args:
        root: The invocation root the cache directory hangs under.

    Returns:
        What failed and what to do about it, ready to finish a refusal, or
        `None` when the marker is a regular file holding exactly what mtest
        writes. Never raises: an unauthorized deletion is a refusal, not an
        error.

        The two shapes are different facts with one remedy. mtest writes the
        marker only when it creates the directory itself, and neither writes one
        into a directory it finds nor overwrites one that is already there —
        either would manufacture deletion authority this function exists to
        demand. So a
        missing marker and a foreign marker both mean the same thing: nothing a
        later run does can authorize deletion of this directory, and the way out
        is the user's own deletion.
    """
    var tag = root + "/" + CACHEDIR_TAG_REL
    var quoted = String("the deletion-authorization marker '")
    quoted += CACHEDIR_TAG_REL + "' "
    var manual = String(" delete the directory yourself with 'rm -rf ")
    manual += CACHE_ROOT_DIR
    manual += "'"

    # No-follow: a symlink at the marker's path is not the marker mtest wrote,
    # however ordinary the file it points at may be, and `isfile` would follow
    # it and answer yes.
    var kind: Int
    try:
        kind = path_kind(tag)
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
    if kind != S_IFREG:
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
    """Delete `<root>/.mtest-cache` whole when its marker authorizes deletion.

    `--cache-clear`'s entire implementation, and the one place in mtest that
    removes a directory the USER named rather than one mtest invented. Three
    guards stand between the flag and the removal, in this order:

    1. The path is characterized no-follow FIRST. A symlink is REFUSED,
       never removed and never followed — following it would delete whatever it
       points at, which is outside the named cache root.
    2. The directory must hold the `CACHEDIR.TAG` marker mtest writes when it
       creates the directory — as a regular file, holding exactly the text mtest
       writes. Presence alone proves nothing: `CACHEDIR.TAG` is a published
       convention whose signature line every cache-marking tool writes, and
       users add one by hand to keep backups out, so a marker somebody else
       wrote does not authorize deleting their directory.
       There is deliberately no "but its contents look like ours" exception
       either: that heuristic is exactly how a directory somebody else created
       gets deleted. A checkout whose cache predates the marker therefore
       refuses ONCE, and the diagnostic says so and hands over the manual
       removal.
    3. Removal itself goes through `remove_tree_no_follow`, which unlinks child
       symlinks rather than descending them, so the blast radius stays inside
       the authorized directory.

    An ABSENT cache root is success, not a diagnostic: there is nothing to
    clear, which is the ordinary shape of a first run. A root that cannot be
    characterized AT ALL — an unsearchable parent — is reported the same way,
    because `path_kind` cannot separate the two through a Mojo `Error`. Both
    end with nothing deleted, which is the honest outcome either way; the run
    that follows is simply cold.

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
    # No-follow: `islink`/`isdir` fold an unreadable path into False, and "not
    # a link" is precisely the answer that would let the removal proceed
    # straight through one.
    var kind: Int
    try:
        kind = path_kind(cache_root)
    except:
        # Absent, or a parent that cannot be searched. `path_kind` cannot
        # separate the two through a Mojo `Error`, and both resolve identically
        # here: nothing is deleted. Reporting the unreadable case as success
        # costs a cold run that was already going to be cold; guessing the other
        # way would fail runs over a cache directory that never existed.
        return Optional[String](None)
    if kind == S_IFLNK:
        var symlink_note = String("cache-clear: ") + cache_root
        symlink_note += ": refusing to delete a symlink"
        symlink_note += " — only a real cache directory carrying mtest's exact"
        symlink_note += " deletion-authorization marker may be deleted,"
        symlink_note += " and following this link would delete whatever it"
        symlink_note += " points at; remove or repoint the link yourself, then"
        symlink_note += " rerun"
        return Optional[String](symlink_note^)
    var authorization_failure = _deletion_authorization_failure(root)
    if authorization_failure:
        var unmarked_note = String("cache-clear: ") + cache_root
        unmarked_note += ": refusing to delete a directory mtest cannot prove"
        unmarked_note += " it owns — " + authorization_failure.value()
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
