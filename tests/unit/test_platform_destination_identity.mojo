"""The comparison key two output destinations are declared to collide on.

`realpath(3)` fails on a final component that does not exist yet, and a report
destination normally does not: it is about to be created. The key is therefore
the resolved PARENT joined with the literal basename, which makes two spellings
of one file — `out.md` and `./out.md`, or a parent reached through `..` or a
symlink — compare equal, while two genuinely different files never do.

One alias no spelling can settle is case: `Run.out` and `run.out` are two files
on ext4 and one file on APFS. So the volume is asked, by probing the directory
a destination will be written into, and the key is folded only where the answer
was yes. These tests build that ground truth from the standard library rather
than from the function under test, so they assert the same property on a
case-sensitive and a case-insensitive host alike.
"""
from std.os import listdir, mkdir, remove, symlink
from std.os.path import exists, realpath
from std.pathlib import cwd
from std.testing import (
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
    TestSuite,
)

from mtest.platform import (
    case_folded_identity,
    destination_identity,
    directory_ignores_case,
)

from tmptree import remove_tree, temp_root


def test_a_bare_filename_resolves_against_the_working_directory() raises:
    """An empty `dirname` is the working directory, not the filesystem root."""
    assert_equal(destination_identity("out.md"), String(cwd()) + "/out.md")


def test_dot_slash_is_the_same_destination_as_the_bare_name() raises:
    """The alias the run path must refuse: two spellings of one file."""
    assert_equal(
        destination_identity("out.md"), destination_identity("./out.md")
    )


def test_two_different_names_in_one_directory_stay_distinct() raises:
    assert_not_equal(
        destination_identity("out.md"), destination_identity("other.md")
    )


def test_a_redundant_parent_segment_folds_away() raises:
    """`realpath` normalizes the parent, so `tests/../out.md` is `out.md`."""
    assert_equal(
        destination_identity("./tests/../out.md"), String(cwd()) + "/out.md"
    )


def test_a_relative_parent_resolves_to_its_absolute_form() raises:
    assert_equal(
        destination_identity("tests/out.md"), String(cwd()) + "/tests/out.md"
    )


def test_a_canonical_absolute_parent_keeps_the_basename_verbatim() raises:
    """A parent that resolves to itself is left alone, and the basename after
    it is appended byte for byte.

    The canonical parent is BUILT rather than named. A literal such as
    `/tmp/out.md` states a property of one platform's filesystem layout instead
    of one of this function's: `/tmp` is a real directory on Linux and a symlink
    to `/private/tmp` on macOS, where resolving it is the correct behavior and
    the literal is simply wrong.
    """
    var root = temp_root()
    try:
        var canonical = realpath(root)
        # The precondition this test needs, asserted rather than assumed:
        # `canonical` has no symlink left in it for `destination_identity` to
        # resolve, so anything it changes is a change this test can attribute.
        assert_equal(canonical, realpath(canonical))
        assert_equal(
            destination_identity(canonical + "/out.md"), canonical + "/out.md"
        )
    finally:
        remove_tree(root)


def test_a_symlinked_parent_resolves_to_what_it_points_at() raises:
    """The other half, which a canonical parent cannot show: two spellings of
    one directory produce one key.

    This is the property macOS's `/tmp` -> `/private/tmp` link was demonstrating
    by accident, asserted here on a link this test owns, so it holds on every
    platform rather than on whichever one ships a symlinked `/tmp`.
    """
    var root = temp_root()
    try:
        var canonical = realpath(root)
        mkdir(canonical + "/real", 0o700)
        symlink(canonical + "/real", canonical + "/link")
        assert_equal(
            destination_identity(canonical + "/link/out.md"),
            canonical + "/real/out.md",
        )
        assert_equal(
            destination_identity(canonical + "/link/out.md"),
            destination_identity(canonical + "/real/out.md"),
        )
    finally:
        remove_tree(root)


def test_an_unresolvable_parent_falls_back_to_the_lexical_form() raises:
    """A missing parent is exit 4 on the run path, so the key only has to be
    total and stable here, never canonical.

    The literal is safe on every platform precisely because the path does not
    resolve: there is no component for `realpath` to rewrite, so the lexical
    fallback is the whole answer.
    """
    assert_equal(
        destination_identity("/no/such/dir/out.md"), "/no/such/dir/out.md"
    )


def _write(path: String, text: String) raises:
    with open(path, "w") as destination:
        destination.write(text)


def _observed_ignores_case(root: String) raises -> Bool:
    """Ground truth, built from the standard library rather than from the
    function under test: create one lowercase name and ask whether its
    uppercase spelling resolves to something."""
    var lowered = root + "/casecheck"
    _write(lowered, "x")
    var seen = exists(root + "/CASECHECK")
    remove(lowered)
    return seen


def test_case_folded_identity_lowers_every_cased_code_point() raises:
    assert_equal(case_folded_identity("/A/Run.OUT"), "/a/run.out")
    assert_equal(case_folded_identity("/a/r-2_3.md"), "/a/r-2_3.md")
    # Not an ASCII-only fold: the case-insensitive volumes this exists for
    # (APFS, HFS+) fold beyond ASCII too.
    assert_equal(case_folded_identity("/a/CAFÉ.md"), "/a/café.md")


def test_case_folded_identity_is_idempotent() raises:
    var once = case_folded_identity("/A/Run.out")
    assert_equal(case_folded_identity(once), once)


def test_two_case_flipped_spellings_share_one_folded_key() raises:
    """The pair that publishes twice onto one file on a case-insensitive
    volume: the exact keys differ, the folded keys must not.

    Both assertions are relations between two keys from the same parent, so
    whatever that parent resolves to cancels out and no filesystem layout is
    assumed.
    """
    var upper = destination_identity("/tmp/Run.out")
    var lower = destination_identity("/tmp/run.out")
    assert_not_equal(upper, lower)
    assert_equal(case_folded_identity(upper), case_folded_identity(lower))


def test_the_case_verdict_matches_an_independently_observed_alias() raises:
    """The probe must agree with what the filesystem actually does, on
    whichever filesystem this test runs — case-sensitive or not."""
    var root = temp_root()
    try:
        assert_equal(directory_ignores_case(root), _observed_ignores_case(root))
    finally:
        remove_tree(root)


def test_the_case_probe_leaves_the_directory_as_it_found_it() raises:
    """It runs against a caller's OUTPUT directory, so a stray probe file
    would be a visible artifact of asking the question."""
    var root = temp_root()
    try:
        _write(root + "/keep", "x")
        assert_equal(len(listdir(root)), 1)
        _ = directory_ignores_case(root)
        _ = directory_ignores_case(root)
        assert_equal(len(listdir(root)), 1)
        assert_true(exists(root + "/keep"))
    finally:
        remove_tree(root)


def test_the_case_probe_is_total_on_a_directory_it_cannot_write() raises:
    """Never raises and never guesses: an unusable directory answers with the
    case-sensitive verdict, which folds nothing and refuses nothing."""
    assert_false(directory_ignores_case("/no/such/directory"))
    var root = temp_root()
    try:
        assert_false(directory_ignores_case(root + "/missing"))
    finally:
        remove_tree(root)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
