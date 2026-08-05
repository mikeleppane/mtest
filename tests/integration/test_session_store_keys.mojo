"""What a per-file key covers, and the import scan that decides its reach.

Covers `mtest.session.store.artifact`'s key-derivation half: which of a test
file's neighbours are build inputs its key has to describe, which are not, and
what the key does when a source cannot be scanned at all. The store protocol
that consumes those keys is in `test_session_store_artifact`.

Every case here keys a stub or nothing at all: none reads the pinned toolchain,
so none populates the process-lifetime toolchain memos.
"""
from std.os import symlink
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from mtest.cache import ImportScan, scan_imports
from mtest.session.store.artifact import file_key
from mtest.session.store.context import CacheContext, finalize_includes

from cache_fixtures import write_bytes
from session_fixtures import SRC_PASS, write_file
from tmptree import temp_root


def _keyed(root: String, rel: String) raises -> String:
    """The full key one file gets under a fresh context.

    A fresh context per call is the point: the per-directory walk is memoized,
    so reusing one would answer the second call from the first call's reading of
    a directory that has since changed.

    Args:
        root: The invocation root.
        rel: The test file's root-relative path.

    Returns:
        The 64-hex key.

    Raises:
        Error: If the file could not be keyed at all.
    """
    var ctx = CacheContext()
    var key = file_key(ctx, root, rel)
    if not key:
        raise Error("test: file_key failed for '" + rel + "'")
    return String(key.value().digest_full)


def test_file_key_covers_a_helper_beside_the_source() raises:
    """A module in the source's own directory is a build input, and is keyed.

    `mojo build tests/test_x.mojo` resolves a bare `from helper import ...` out
    of `tests/`, with no `-I` involved. A key blind to that directory serves a
    binary compiled against the previous helper.
    """
    var root = temp_root()
    write_file(root, "tests/helper.mojo", "# helper v1\n")
    write_file(root, "tests/test_x.mojo", SRC_PASS)
    var before = _keyed(root, "tests/test_x.mojo")
    write_file(root, "tests/helper.mojo", "# helper v2\n")
    assert_not_equal(
        before,
        _keyed(root, "tests/test_x.mojo"),
        "the helper the compiler can reach changed, so the key must move",
    )


def test_file_key_ignores_a_test_sibling_nothing_imports() raises:
    """A discovered test file beside the source is left out of its key.

    Each such file is an entry point already keyed by its own source frame, so
    folding it into its neighbours would make one edit rebuild the whole
    directory — the cost that would make the cache worthless for the
    edit-one-file loop it exists to speed up.
    """
    var root = temp_root()
    write_file(root, "tests/helper.mojo", "# helper\n")
    write_file(root, "tests/test_x.mojo", SRC_PASS)
    write_file(root, "tests/test_y.mojo", SRC_PASS)
    var before = _keyed(root, "tests/test_x.mojo")
    write_file(root, "tests/test_y.mojo", "# a different suite entirely\n")
    assert_equal(
        before,
        _keyed(root, "tests/test_x.mojo"),
        "a neighbour nothing imports cannot change this file's build",
    )


def test_file_key_covers_a_test_sibling_the_source_imports() raises:
    """Omitting test siblings is abandoned for a source that imports one."""
    var root = temp_root()
    write_file(root, "tests/test_y.mojo", "# neighbour v1\n")
    write_file(root, "tests/test_x.mojo", "from test_y import thing\n")
    var before = _keyed(root, "tests/test_x.mojo")
    write_file(root, "tests/test_y.mojo", "# neighbour v2\n")
    assert_not_equal(
        before,
        _keyed(root, "tests/test_x.mojo"),
        "the source imports the neighbour, so the neighbour is an input",
    )


def test_file_key_ignores_a_test_sibling_only_a_neighbour_imports() raises:
    """One test file importing another does not cost the rest their precision.

    A keyed file's own imports speak for that file alone. `test_b` reaching
    `test_c` means `test_b` keys over the whole directory; it says nothing about
    what `test_a` compiles against, so `test_a` keeps the omission and an edit
    to `test_c` leaves it in the store.

    This is the difference between scanning the file being keyed and escalating
    the whole directory. Escalating here would be sound but pointless, and its
    cost is real: `test_helpers.mojo` beside `test_session.mojo` is an everyday
    layout, and one such pair would put every unrelated test in the directory
    back on the unomitted walk for good.
    """
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", "from test_c import thing\n")
    write_file(root, "tests/test_c.mojo", "# neighbour v1\n")
    var before = _keyed(root, "tests/test_a.mojo")
    write_file(root, "tests/test_c.mojo", "# neighbour v2\n")
    assert_equal(
        before,
        _keyed(root, "tests/test_a.mojo"),
        "only the file that imported the neighbour keys over it",
    )
    # ...and the file that DID import it moved, or the omission would be a hole
    # rather than a precision choice.
    var b_before = _keyed(root, "tests/test_b.mojo")
    write_file(root, "tests/test_c.mojo", "# neighbour v3\n")
    assert_not_equal(
        b_before,
        _keyed(root, "tests/test_b.mojo"),
        "the importer must key over the neighbour it named",
    )


def test_file_key_covers_an_unreadable_test_sibling_its_importer_names() raises:
    """An omitted sibling is covered by the name that reaches it, not by itself.

    Omitted files are never scanned, and they never need to be: the match runs
    on the IMPORTER's side, against the directory's omitted names. So a sibling
    whose own bytes could not be scanned at all — here an embedded NUL, the
    plainest "this is not source text" — still invalidates the file that names
    it, because nothing about the sibling was ever consulted to decide that.
    """
    var root = temp_root()
    write_bytes(
        root,
        "tests/test_y.mojo",
        [UInt8(35), UInt8(0), UInt8(118), UInt8(49), UInt8(10)],
    )
    write_file(root, "tests/test_x.mojo", "from test_y import thing\n")
    var before = _keyed(root, "tests/test_x.mojo")
    write_bytes(
        root,
        "tests/test_y.mojo",
        [UInt8(35), UInt8(0), UInt8(118), UInt8(50), UInt8(10)],
    )
    assert_not_equal(
        before,
        _keyed(root, "tests/test_x.mojo"),
        "the importer named it, so it is an input whatever its bytes are",
    )


def test_file_key_covers_a_test_sibling_a_helper_imports() raises:
    """The same proof runs one hop out, over the helpers the walk does frame.

    A helper that imports a test file puts that file back on the compiler's
    path for everything importing the helper, so the omission is unsafe for the
    whole directory even though no test file names the neighbour itself.
    """
    var root = temp_root()
    write_file(root, "tests/test_y.mojo", "# neighbour v1\n")
    write_file(root, "tests/helper.mojo", "from test_y import thing\n")
    write_file(root, "tests/test_x.mojo", SRC_PASS)
    var before = _keyed(root, "tests/test_x.mojo")
    write_file(root, "tests/test_y.mojo", "# neighbour v2\n")
    assert_not_equal(
        before,
        _keyed(root, "tests/test_x.mojo"),
        "a helper reaches the neighbour, so the neighbour is an input here too",
    )


def test_file_key_covers_the_directory_when_a_source_cannot_be_scanned() raises:
    """A file whose imports cannot be read proves nothing, so nothing is
    omitted.

    The embedded NUL is the plainest case: those bytes are not source text, so
    the scanner refuses to say what they import rather than reporting that they
    import nothing. Refusing has to cost a wider key, never a narrower one.
    """
    var root = temp_root()
    write_file(root, "tests/test_y.mojo", "# neighbour v1\n")
    write_bytes(
        root,
        "tests/helper.mojo",
        [UInt8(35), UInt8(0), UInt8(35), UInt8(10)],
    )
    write_file(root, "tests/test_x.mojo", SRC_PASS)
    var before = _keyed(root, "tests/test_x.mojo")
    write_file(root, "tests/test_y.mojo", "# neighbour v2\n")
    assert_not_equal(
        before,
        _keyed(root, "tests/test_x.mojo"),
        "an unscannable helper cannot license leaving the neighbour out",
    )


def _keyed_with_includes(
    root: String, rel: String, includes: List[String]
) raises -> String:
    """The full key one file gets under a context carrying include roots.

    Args:
        root: The invocation root.
        rel: The test file's root-relative path.
        includes: The include roots the session would pass as `-I`.

    Returns:
        The 64-hex key.

    Raises:
        Error: If the file could not be keyed at all.
    """
    var ctx = CacheContext()
    finalize_includes(ctx, root, includes)
    var key = file_key(ctx, root, rel)
    if not key:
        raise Error("test: file_key failed for '" + rel + "'")
    return String(key.value().digest_full)


def test_file_key_covers_a_test_sibling_an_include_root_module_imports() raises:
    """The omission proof reaches through the include roots too.

    `-I support` frames `libhelper.mojo`'s bytes, but not what those bytes
    IMPORT. `test_peer.mojo` is a discovered test file, so the walk of the test
    directory leaves it out — and the entry file never names it, so nothing on
    the keyed file's own side escalates either. Without reading the include
    root's sources, editing `test_peer.mojo` would move no keyed region at all
    and `test_main.mojo` could serve a binary compiled against the old one.
    """
    var root = temp_root()
    write_file(root, "tests/test_main.mojo", "from libhelper import thing\n")
    write_file(root, "tests/test_peer.mojo", "# neighbour v1\n")
    write_file(root, "support/libhelper.mojo", "from test_peer import thing\n")
    var includes: List[String] = [String("support")]

    var before = _keyed_with_includes(root, "tests/test_main.mojo", includes)
    write_file(root, "tests/test_peer.mojo", "# neighbour v2\n")
    assert_not_equal(
        before,
        _keyed_with_includes(root, "tests/test_main.mojo", includes),
        (
            "a module under an include root reaches the omitted neighbour, so"
            " the neighbour is an input"
        ),
    )


def test_an_include_root_import_leaves_unrelated_directories_precise() raises:
    """Escalation follows the NAME, so it stops at the directories that omit it.

    The include root names `test_peer`, which only `tests/` leaves out. A
    directory with no such name keeps the omission and its ordinary one-file
    edit-and-rerun loop: widening every directory in the session because one
    library imported one test module would trade the whole feature for the
    proof.
    """
    var root = temp_root()
    write_file(root, "tests/test_main.mojo", SRC_PASS)
    write_file(root, "tests/test_peer.mojo", "# neighbour v1\n")
    write_file(root, "other/test_alpha.mojo", SRC_PASS)
    write_file(root, "other/test_beta.mojo", "# unrelated v1\n")
    write_file(root, "support/libhelper.mojo", "from test_peer import thing\n")
    var includes: List[String] = [String("support")]

    var before = _keyed_with_includes(root, "other/test_alpha.mojo", includes)
    write_file(root, "other/test_beta.mojo", "# unrelated v2\n")
    assert_equal(
        before,
        _keyed_with_includes(root, "other/test_alpha.mojo", includes),
        "a directory the include root never names keeps its precise key",
    )


def test_an_unscannable_include_root_source_widens_every_omission() raises:
    """A source under `-I` whose imports cannot be read could name anything.

    The scan is what licenses leaving a directory's test files out, so a
    library the scanner refuses to read withdraws that licence everywhere —
    the same direction every other refusal takes, and for the same reason.
    """
    var root = temp_root()
    write_file(root, "tests/test_main.mojo", SRC_PASS)
    write_file(root, "tests/test_peer.mojo", "# neighbour v1\n")
    write_bytes(
        root,
        "support/libhelper.mojo",
        [UInt8(35), UInt8(0), UInt8(35), UInt8(10)],
    )
    var includes: List[String] = [String("support")]

    var before = _keyed_with_includes(root, "tests/test_main.mojo", includes)
    write_file(root, "tests/test_peer.mojo", "# neighbour v2\n")
    assert_not_equal(
        before,
        _keyed_with_includes(root, "tests/test_main.mojo", includes),
        "an unreadable library cannot license leaving a neighbour out",
    )


def test_a_test_directory_that_cannot_be_walked_disables_the_cache() raises:
    """A directory the walk cannot characterize takes the cache off with it.

    Same posture as an include root behind a symlinked package: the directory is
    a search path, its contents are build inputs, and a key that cannot cover
    them must not be written. The reason names the directory so the message is
    something to act on rather than a bare refusal.
    """
    var root = temp_root()
    write_file(root, "elsewhere/__init__.mojo", "# a package\n")
    write_file(root, "tests/test_x.mojo", SRC_PASS)
    symlink(root + "/elsewhere", root + "/tests/pkg")
    var ctx = CacheContext()
    assert_false(
        Bool(file_key(ctx, root, "tests/test_x.mojo")),
        "an uncharacterizable directory has no key",
    )
    assert_false(ctx.enabled, "and it must switch the cache off")
    assert_true(
        "test directory 'tests'" in ctx.disable_reason,
        "the reason must name the directory: " + ctx.disable_reason,
    )
    assert_true(
        "directory symlink" in ctx.disable_reason,
        "and what about it could not be walked: " + ctx.disable_reason,
    )


def _scanned(text: String) -> ImportScan:
    """Scan a source given as text.

    Args:
        text: The source.

    Returns:
        The scan of its bytes.
    """
    var data = List[UInt8]()
    for b in text.as_bytes():
        data.append(b)
    return scan_imports(data)


def test_import_scanning_reads_the_forms_a_key_depends_on() raises:
    """The shapes the scanner understands, and the ones it refuses to guess at.

    Every refusal costs a wider key and never a narrower one, so this pins the
    direction as much as the cases: `parsed` False must never be reachable by
    something that would let a build input out of the key.
    """
    var plain = _scanned("from helper import value\n")
    assert_true(plain.parsed)
    assert_equal(len(plain.modules), 1)
    assert_equal(plain.modules[0], "helper")

    var dotted = _scanned("import pkg.mod as m, other\n")
    assert_true(dotted.parsed)
    assert_equal(len(dotted.modules), 2)
    assert_equal(dotted.modules[0], "pkg")
    assert_equal(dotted.modules[1], "other")

    # A docstring and a comment are erased before the line is read, so prose
    # about importing is not an import — nor a reason to refuse.
    var prose = _scanned(
        '"""One layer never imports another.\nAnd from a to b."""\n'
        "# from x import y\n"
        "from real import thing\n"
    )
    assert_true(prose.parsed)
    assert_equal(len(prose.modules), 1)
    assert_equal(prose.modules[0], "real")

    # An import hiding after a statement separator: understood well enough to
    # know it is there, not well enough to say what it names.
    assert_false(_scanned("x = 1; import y\n").parsed)
    # The same separator, on the far side of a `from` statement. What follows
    # `import` on a `from` line ordinarily names symbols and is not examined, so
    # this is the one place a second statement could pass unread.
    assert_false(_scanned("from helper import value; import peer\n").parsed)
    assert_false(_scanned("from a import b; from c import d\n").parsed)
    # A second statement that cannot name a module keeps the precise key.
    var trailing = _scanned("from helper import value; x = 1\n")
    assert_true(trailing.parsed)
    assert_equal(len(trailing.modules), 1)
    assert_equal(trailing.modules[0], "helper")
    # A form this scanner does not model.
    assert_false(_scanned("from . import sibling\n").parsed)
    # A statement continued onto the next line.
    assert_false(_scanned("import a, \\\n    b\n").parsed)
    # A literal left open, so the file does not lex at all.
    assert_false(_scanned('var s = "open\n').parsed)


def test_import_scanning_refuses_bytes_that_are_not_utf8() raises:
    """A source that is not UTF-8 is refused instead of tokenized.

    Any byte at or above 0x80 counts as an identifier byte, so a Latin-1 module
    name or a half-written multi-byte sequence would otherwise be read as a
    token. The scanner exists to decide whether a key may be narrow, and a file
    whose bytes it cannot read is exactly the case where it may not be.
    """
    var latin1 = List[UInt8]()
    for b in "import caf".as_bytes():
        latin1.append(b)
    # 'é' as Latin-1: a lone continuation-range byte, never valid UTF-8.
    latin1.append(0xE9)
    latin1.append(UInt8(ord("\n")))
    assert_false(
        scan_imports(latin1).parsed,
        "a Latin-1 module name must refuse, not tokenize",
    )

    var truncated = List[UInt8]()
    for b in "import a".as_bytes():
        truncated.append(b)
    # A two-byte sequence whose continuation byte never arrived.
    truncated.append(0xC3)
    truncated.append(UInt8(ord("\n")))
    assert_false(
        scan_imports(truncated).parsed,
        "a truncated multi-byte sequence must refuse",
    )

    # The refusal is about malformed bytes, not about non-ASCII names: a module
    # name that IS valid UTF-8 still scans, and still reports its own spelling.
    var accented = _scanned("import café\n")
    assert_true(accented.parsed, "a valid UTF-8 module name still scans")
    assert_equal(len(accented.modules), 1)
    assert_equal(accented.modules[0], "café")


def test_import_scanning_reads_past_a_byte_order_mark() raises:
    """A source opening with a UTF-8 BOM still has its imports read.

    Every byte at or above 0x80 is an identifier byte, so the three bytes an
    editor writes to mark a file as UTF-8 glue themselves onto whatever token
    follows. `import helper` on the first line lexed as one token that is
    neither `import` nor `from`, matched no whole `import` token either, and the
    line came back understood with nothing found — the one answer this scanner
    may never give wrongly, since the caller then keys a file whose helper is
    not in the key.
    """
    var marked = List[UInt8]()
    marked.append(0xEF)
    marked.append(0xBB)
    marked.append(0xBF)
    for b in "import helper\n".as_bytes():
        marked.append(b)
    var scan = scan_imports(marked)
    assert_true(scan.parsed, "a marked source is ordinary UTF-8 and must scan")
    assert_equal(len(scan.modules), 1, "and its import must be reported")
    assert_equal(scan.modules[0], "helper")

    # The same on a `from` line, which takes the other branch of the dispatch.
    var from_marked = List[UInt8]()
    from_marked.append(0xEF)
    from_marked.append(0xBB)
    from_marked.append(0xBF)
    for b in "from helper import value\n".as_bytes():
        from_marked.append(b)
    var from_scan = scan_imports(from_marked)
    assert_true(from_scan.parsed)
    assert_equal(len(from_scan.modules), 1)
    assert_equal(from_scan.modules[0], "helper")

    # Only a LEADING mark is a mark. The same bytes in the middle of a file are
    # a zero-width no-break space inside an identifier, which is a token this
    # scanner cannot read as a keyword and must not read as ordinary code.
    var interior = List[UInt8]()
    for b in "x = 1\n".as_bytes():
        interior.append(b)
    interior.append(0xEF)
    interior.append(0xBB)
    interior.append(0xBF)
    for b in "import helper\n".as_bytes():
        interior.append(b)
    assert_false(
        scan_imports(interior).parsed,
        "an import glued to an invisible character is not understood",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
