"""Path-helper invariants for `exec`, and the difference between the two.

`canonicalize` resolves symlinks (`realpath`): it answers "which file is this,
really". `lexical_source_path` does NOT: it folds `.`/`..` textually and leaves
every symlink component standing.

The distinction is load-bearing. `mojo build` bakes the path it was HANDED into
the child's report location lines, resolving a relative path against its cwd but
never resolving a symlink. So the identity key the report parser matches on is
the lexical path — matching on the resolved one disqualifies a conforming report
whenever the source is a symlink, which reads as MALFORMED-SUITE and blames the
user's module for the runner's own mismatch. For a path with no symlink
component the two agree, which is why this only ever surfaced through a link.
"""
from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from mtest.exec import canonicalize, lexical_source_path, source_identity_key

from tmptree import temp_root, touch, link_dir, remove_tree


def test_existing_file_is_absolute_and_canonical() raises:
    var p = canonicalize("tests/fixtures/protocol/passing.mojo")
    assert_true(p.startswith("/"), p)
    assert_true(p.endswith("/tests/fixtures/protocol/passing.mojo"), p)
    assert_false("/./" in p, p)
    assert_false("/../" in p, p)


def test_symlink_resolves_to_target_canonical() raises:
    var root = temp_root()
    touch(root, "real/file.mojo")
    link_dir(root, "real/file.mojo", "link.mojo")
    var via_link = canonicalize(root + "/link.mojo")
    var via_real = canonicalize(root + "/real/file.mojo")
    assert_equal(via_link, via_real)
    assert_true(via_link.endswith("/real/file.mojo"), via_link)
    remove_tree(root)


def test_nonexistent_path_raises_naming_the_path() raises:
    with assert_raises(contains="/no/such/mtest/xyz123"):
        _ = canonicalize("/no/such/mtest/xyz123")


# --- lexical_source_path: the report-identity key ---


def test_lexical_source_path_keeps_the_symlink_component() raises:
    """The key must name the link, because that is what the child reports."""
    var root = temp_root()
    touch(root, "real/file.mojo")
    link_dir(root, "real/file.mojo", "link.mojo")
    var lexical = lexical_source_path(root + "/link.mojo")
    assert_true(lexical.endswith("/link.mojo"), lexical)
    assert_false(lexical.endswith("/real/file.mojo"), lexical)
    # The contrast that defines this helper: canonicalize resolves it away.
    assert_false(lexical == canonicalize(root + "/link.mojo"), lexical)
    remove_tree(root)


def test_lexical_source_path_agrees_with_canonicalize_without_links() raises:
    """No symlink component means no behavior change for ordinary files.

    The root is canonicalized FIRST so the premise actually holds: on macOS the
    temp root is handed out under `/var`, which is itself a symlink to
    `/private/var`, so composing from the raw root would compare a path that
    does contain a link and fail on the platform difference rather than on the
    behavior under test.
    """
    var root = temp_root()
    touch(root, "sub/test_a.mojo")
    var link_free_root = canonicalize(root)
    assert_equal(
        lexical_source_path(link_free_root + "/sub/test_a.mojo"),
        canonicalize(link_free_root + "/sub/test_a.mojo"),
    )
    remove_tree(root)


def test_lexical_source_path_folds_dot_segments() raises:
    assert_equal(
        lexical_source_path("/a/./b/../c/test_x.mojo"), "/a/c/test_x.mojo"
    )


def test_lexical_source_path_strips_duplicate_slashes() raises:
    assert_equal(lexical_source_path("/a//b///test_x.mojo"), "/a/b/test_x.mojo")


def test_lexical_source_path_needs_no_existing_file() raises:
    """Pure text: unlike canonicalize it never touches the filesystem."""
    assert_equal(
        lexical_source_path("/no/such/mtest/xyz123.mojo"),
        "/no/such/mtest/xyz123.mojo",
    )


# --- source_identity_key: the two halves, composed ---


def test_source_identity_key_resolves_the_root_but_not_the_operand() raises:
    """`mojo build` treats the two halves of what it is handed differently.

    It resolves a relative argument against `getcwd(3)`, which always reports
    the PHYSICAL directory, so the root half must be canonical; it never
    resolves a symlink in the argument itself, so the relative half must stay
    lexical. Reproducing the key means reproducing both.
    """
    var outer = temp_root()
    touch(outer, "real/tests/test_a.mojo")
    link_dir(outer, "real", "link")
    link_dir(outer, "real/tests/test_a.mojo", "real/tests/test_link.mojo")
    var physical = canonicalize(outer)

    # Root half RESOLVED: entering through the link names the real directory,
    # which is the only thing the child will ever say.
    assert_equal(
        source_identity_key(outer + "/link", "tests/test_a.mojo"),
        physical + "/real/tests/test_a.mojo",
    )
    # Operand half NOT resolved: the linked file keeps its own name rather than
    # collapsing onto its target.
    assert_equal(
        source_identity_key(outer + "/link", "tests/test_link.mojo"),
        physical + "/real/tests/test_link.mojo",
    )
    remove_tree(outer)


def test_source_identity_key_is_stable_across_equivalent_roots() raises:
    """The link and the real directory are one root, so they key identically."""
    var outer = temp_root()
    touch(outer, "real/tests/test_a.mojo")
    link_dir(outer, "real", "link")
    assert_equal(
        source_identity_key(outer + "/link", "tests/test_a.mojo"),
        source_identity_key(outer + "/real", "tests/test_a.mojo"),
    )
    remove_tree(outer)
