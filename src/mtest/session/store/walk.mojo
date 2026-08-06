"""Walking the trees a key covers, and witnessing that they held still.

Layer 4 (`session`), inside `store`. A walk turns a directory into key frames:
which entries a build could read, in byte order, each as a file frame. What it
skips is as much of the contract as what it digests — dot entries, and a
directory's own test files, so editing one test does not rebuild its
neighbours.

Beside the walk sits the stat witness. A key describes inputs that were read
before the compiler ran; publication has to ask whether any of them moved
underneath it, and a record of identity and change times per input is what lets
it answer. A directory's own record stands for its membership, so a file
appearing beside a source is caught the same way an edited source is.
"""
from std.os import lstat, stat
from std.os.path import dirname, isdir, islink, realpath

from mtest.cache import KeyBuilder, scan_imports, sha256_hex
from mtest.discover import is_discovered_test_name
from mtest.platform import (
    S_IFDIR,
    S_IFLNK,
    path_kind,
    read_regular_file_bytes,
)
from mtest.session.store.support import (
    _WALK_FILE_CAP,
    _absolute,
    _list_sorted,
)
from mtest.session.store.tags import TAG_WALK_FILE


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


@fieldwise_init
struct _StatWitness(Copyable, Movable):
    """One keyed input's filesystem identity and change times at key time.

    Captured beside the read that keyed the input, compared again at
    publication. Never part of the key: content decides what a build IS, while
    these decide whether the tree HELD STILL while the compiler read it.
    Userspace can restore bytes and backdate an mtime, but `ctime` only moves
    forward, so an edit and its undo across the build window move at least one
    field even though both content samples agree.

    `follow` records which stat the capture used, so the re-check repeats
    exactly it. An entry's own no-follow identity catches a name replaced or
    repointed; a link's followed target catches the bytes behind a name that
    never moved; a directory's record catches an entry that came and went,
    leaving no file to compare.
    """

    var path: String
    """The absolute path to re-stat.

    Walk-relative names cannot be re-resolved from the invocation root, so the
    capture site supplies the full path it actually read.
    """

    var label: String
    """The user-facing name, carried into any refusal message."""

    var follow: Bool
    """True when the capture followed symlinks (`stat`); False for the entry's
    own identity (`lstat`)."""

    var dev: Int
    """The device the entry lived on."""

    var ino: Int
    """The entry's inode number; a replaced name lands on a different one."""

    var size: Int
    """The entry's size in bytes."""

    var mtime_sec: Int
    """Whole seconds of the last content modification."""

    var mtime_subsec: Int
    """Sub-second part of the last content modification."""

    var ctime_sec: Int
    """Whole seconds of the last metadata change."""

    var ctime_subsec: Int
    """Sub-second part of the last metadata change."""


def _witness_of(
    path: String, label: String, follow: Bool
) raises -> _StatWitness:
    """Capture one witness record for `path`.

    Args:
        path: The absolute path to stat.
        label: The user-facing name carried into any refusal message.
        follow: Whether to follow symlinks (`stat`) or record the entry's own
            identity (`lstat`).

    Returns:
        The record.

    Raises:
        Error: If the path cannot be stat'd.
    """
    var st = stat(path) if follow else lstat(path)
    return _StatWitness(
        String(path),
        String(label),
        follow,
        Int(st.st_dev),
        Int(st.st_ino),
        Int(st.st_size),
        Int(st.st_mtimespec.tv_sec),
        Int(st.st_mtimespec.tv_subsec),
        Int(st.st_ctimespec.tv_sec),
        Int(st.st_ctimespec.tv_subsec),
    )


def _witness_entry(
    path: String,
    label: String,
    is_link: Bool,
    mut witnesses: List[_StatWitness],
) raises:
    """Record an input's own identity, plus its target's when it is a link.

    Both are needed and neither implies the other. A link repointed and
    repointed back leaves its target's stat untouched, so the followed sample
    alone would agree with the key; a target edited and edited back through a
    stable link leaves the link's own inode untouched, so the no-follow sample
    alone would agree.

    Only the OUTER name and its final target are recorded. A chain of links
    passing through intermediate names does not record those names, so an
    intermediate one repointed and repointed back is not seen; that limit is
    stated with the others in the contract.

    Args:
        path: The absolute path that was, or is about to be, read.
        label: The user-facing name for both records.
        is_link: Whether `path` is itself a symlink. Passed in rather than
            asked for, because every caller has already characterized the entry
            and a second query would both cost a syscall and let the entry
            change kind between the two.
        witnesses: The list both records are appended to.

    Raises:
        Error: If either stat fails.
    """
    witnesses.append(_witness_of(path, label, False))
    if is_link:
        witnesses.append(_witness_of(path, label, True))


def _witness_dir(
    path: String, label: String, mut witnesses: List[_StatWitness]
) raises:
    """Record a walked directory's membership, and its name when that is a link.

    The membership record is followed, because what it stands for is the set of
    entries the walk read and that set lives at the target. A walk root that IS
    a link needs its own identity as well, for the reason any linked entry does:
    the link can be repointed and repointed back around a compile while both
    targets hold still.

    Args:
        path: The absolute directory, about to be listed.
        label: The user-facing name for the records.
        witnesses: The list the records are appended to.

    Raises:
        Error: If the directory cannot be stat'd.
    """
    witnesses.append(_witness_of(path, label, True))
    if islink(path):
        witnesses.append(_witness_of(path, label, False))


def _first_moved_witness(records: List[_StatWitness]) -> String:
    """The label of the first record that no longer matches the tree, if any.

    Two passes, an entry's OWN identity before any followed record. Both
    passes refuse, so the order decides only what the refusal is called — and
    a no-follow record names a FILE the user can go and look at, while a
    followed one may be a directory whose membership moved and can say no more
    than "something in here". Naming `tests/helper.mojo` rather than `tests`
    is the whole difference for whoever reads the warning.

    A record that cannot be re-stat'd at all counts as moved: an input this
    publication cannot characterize is one it cannot vouch for.

    Args:
        records: The key's witness records.

    Returns:
        The moved input's label, or an empty string when every record
        reproduced exactly.
    """
    for followed in range(2):
        for i in range(len(records)):
            var before = records[i].copy()
            if before.follow != (followed == 1):
                continue
            var moved: Bool
            try:
                moved = _witness_moved(
                    before,
                    _witness_of(before.path, before.label, before.follow),
                )
            except:
                moved = True
            if moved:
                return String(before.label)
    return String("")


def _witness_moved(before: _StatWitness, now: _StatWitness) -> Bool:
    """Whether any identity or change-time field differs.

    Args:
        before: The record taken when the input was keyed.
        now: The record taken at publication, by the same stat flavor.

    Returns:
        True if the input cannot be the one the key describes.
    """
    return (
        before.dev != now.dev
        or before.ino != now.ino
        or before.size != now.size
        or before.mtime_sec != now.mtime_sec
        or before.mtime_subsec != now.mtime_subsec
        or before.ctime_sec != now.ctime_sec
        or before.ctime_subsec != now.ctime_subsec
    )


def _witness_label(label_root: String, rel: String) -> String:
    """The user-facing name of a walked entry, relative to the invocation root.

    A walk names its entries relative to the directory being walked, which is
    the right spelling for a walk's own diagnostics and the wrong one for a
    refusal a user has to act on: several include roots can each hold a
    `helper.mojo`. Prefixing the walk root's spelling names exactly one file.

    Args:
        label_root: The walk root's spelling, or empty when the walk root is
            the invocation root itself.
        rel: The entry's path relative to the walk root.

    Returns:
        The composed name.
    """
    return String(rel) if label_root == "" else label_root + "/" + rel


def _witnessable_dir(abs_dir: String, exclude_abs: String) -> Bool:
    """Whether a walked directory's own times can stand for its membership.

    A walk is given a path to exclude when that path is something the build
    PRODUCES rather than reads — a precompile step's output — and the step
    writes it into a directory the same walk covers. That directory's
    membership therefore changes while the step runs, by design, and recording
    its times would withhold every stamp the ordinary `-I build` shape can
    earn. Its FILES are still recorded, so an input inside it is still covered;
    only the membership claim is dropped, and only for the one directory the
    output lands in.

    Args:
        abs_dir: The directory about to be recorded, absolute.
        exclude_abs: The walk's excluded path, absolute, or empty for none.

    Returns:
        False only for the directory the excluded path sits directly inside.
    """
    if exclude_abs == "":
        return True
    var holder = dirname(exclude_abs)
    if holder == abs_dir:
        return False
    # The two spellings can name one directory. `_absolute` deliberately does
    # not canonicalize — the `-I` spelling is part of the key and `-I build`
    # and `-I ./build` are different keys on purpose — so `<root>/./build` and
    # `<root>/build` compare unequal while being the same place. Getting that
    # wrong costs a stamp on EVERY run, since the step rewrites its output
    # there each time, so the question is put to the filesystem rather than to
    # the strings whenever they disagree.
    try:
        if realpath(holder) == realpath(abs_dir):
            return False
    except:
        pass
    return True


def _append_witnesses(mut dst: List[_StatWitness], src: List[_StatWitness]):
    """Copy every record of `src` onto the end of `dst`.

    Args:
        dst: The list to grow.
        src: The records to copy; a memoized directory walk's list is reused by
            every file in that directory, so it is copied rather than moved.
    """
    for i in range(len(src)):
        dst.append(src[i].copy())


def _walk_into(
    abs_dir: String,
    rel_prefix: String,
    label_root: String,
    var names: List[String],
    mut kb: KeyBuilder,
    exclude_abs: String,
    mut scan: _SourceDirScan,
    at_top: Bool,
    mut witnesses: List[_StatWitness],
) -> WalkOutcome:
    """Feed one directory's contributions, recursing into package subdirectories.

    Args:
        abs_dir: The directory to read, absolute.
        rel_prefix: The path of `abs_dir` relative to the walked include root;
            empty at the top. Frames name files by this prefix, never by an
            absolute path, so the same tree keys alike in any checkout.
        label_root: The walk root's own spelling relative to the invocation
            root, or empty when they are the same directory. Used only to name
            witness records for a human; it never reaches a frame.
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
        witnesses: Grown with one record per framed file — two when the entry
            is a symlink — and one per package directory descended into. The
            records never reach `kb`; publication compares them against the
            tree to decide whether it held still while the compiler read it.

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

        # `path_kind` raises where `isdir` / `islink` answer False, which is
        # the whole point of using it: this name came out of a directory
        # listing, so it existed a moment ago. If it cannot be characterized now
        # it either vanished mid-walk or sits under a directory this process may
        # read but not search (mode 0644) — and in that second case EVERY entry
        # would answer "not a directory, not a source file" and the walk would
        # silently frame nothing. A tree the walk cannot characterize must not
        # key as an empty one.
        var kind: Int
        try:
            kind = path_kind(full)
        except:
            return WalkOutcome.failure(
                "cannot inspect '" + rel + "' (in '" + abs_dir + "')"
            )
        var is_link = kind == S_IFLNK
        # For a link, the type that matters is the target's. A dangling link
        # answers False here and falls through to the file path below, where a
        # source-named one fails the read (correctly) and anything else is
        # ignored (also correctly — the compiler would not have read it either).
        var is_dir = kind == S_IFDIR or (is_link and isdir(full))

        if is_dir:
            # Captured BEFORE the listing, and kept only if this directory
            # turns out to be one the walk descends. A directory's own times
            # are the only evidence of an entry that came and went, and a
            # create-and-remove finishing between the listing and the capture
            # would leave those times already settled — so the capture has to
            # precede the read it covers, even at the price of one stat on a
            # directory that is then skipped.
            var dir_record: Optional[_StatWitness] = None
            if _witnessable_dir(full, exclude_abs):
                try:
                    dir_record = Optional(
                        _witness_of(full, _witness_label(label_root, rel), True)
                    )
                except:
                    return WalkOutcome.failure(
                        "cannot read the directory '" + rel + "'"
                    )
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
            if dir_record:
                witnesses.append(dir_record.value().copy())
            var inner = _walk_into(
                full,
                rel,
                label_root,
                sub^,
                kb,
                exclude_abs,
                scan,
                False,
                witnesses,
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
        # Before the read, not after it: a capture taken afterwards would let an
        # edit that landed between the read and the capture masquerade as the
        # state the key describes. `_walk_into` never raises, so a capture that
        # fails becomes a walk failure — and it becomes the same one an
        # unreadable file produces, because everything that defeats the capture
        # (a vanished entry, a dangling link) defeats the read as well.
        try:
            _witness_entry(
                full, _witness_label(label_root, rel), is_link, witnesses
            )
        except:
            return WalkOutcome.failure("cannot read the file '" + rel + "'")
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
    from mtest.session.store.walk import walk_include_root

    var kb = KeyBuilder()
    var outcome = walk_include_root("/repo", "src", kb, "")
    if not outcome.ok:
        pass  # disable the cache, quoting `outcome.reason`
    ```
    """
    var scan = _SourceDirScan.inert()
    var witnesses = List[_StatWitness]()
    return _walk_include_root_scanned(root, dir, kb, exclude, scan, witnesses)


def _walk_include_root_scanned(
    root: String,
    dir: String,
    mut kb: KeyBuilder,
    exclude: String,
    mut scan: _SourceDirScan,
    mut witnesses: List[_StatWitness],
) -> WalkOutcome:
    """`walk_include_root`, with the walk's scan and witnesses handed back.

    Args:
        root: The invocation root; `dir` and `exclude` resolve against it.
        dir: The include root, as configured.
        kb: The builder to feed.
        exclude: One path to skip wherever the walk meets it, or empty.
        scan: Inert to frame the root and learn nothing, collecting to record
            what its sources import.
        witnesses: Grown with this walk's stat records; see `_StatWitness`.
            Callers with nothing to publish pass a list they discard.

    Returns:
        Exactly what `walk_include_root` returns. Never raises.
    """
    var abs_dir = _absolute(root, dir)
    var exclude_abs = String("") if exclude == "" else _absolute(root, exclude)
    # The walk root's own record, taken before its listing for the reason every
    # directory record is taken before one.
    if _witnessable_dir(abs_dir, exclude_abs):
        try:
            _witness_dir(abs_dir, dir, witnesses)
        except:
            return WalkOutcome.failure(
                "'" + dir + "' is not a readable directory"
            )
    var listing = _list_sorted(abs_dir)
    if not listing:
        return WalkOutcome.failure("'" + dir + "' is not a readable directory")
    var label_root = String("") if dir == "." else String(dir)
    return _walk_into(
        abs_dir,
        "",
        label_root,
        listing.value().copy(),
        kb,
        exclude_abs,
        scan,
        True,
        witnesses,
    )


def _walk_source_dir(
    root: String,
    dir: String,
    mut kb: KeyBuilder,
    mut scan: _SourceDirScan,
    mut witnesses: List[_StatWitness],
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
        witnesses: Grown with this walk's stat records; see `_StatWitness`.

    Returns:
        The same outcomes `walk_include_root` returns, for the same reasons.
        Never raises.
    """
    var abs_dir = _absolute(root, dir)
    try:
        _witness_dir(abs_dir, dir, witnesses)
    except:
        return WalkOutcome.failure("'" + dir + "' is not a readable directory")
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
    var label_root = String("") if dir == "." else String(dir)
    return _walk_into(
        abs_dir,
        "",
        label_root,
        names^,
        kb,
        String(""),
        scan,
        True,
        witnesses,
    )
