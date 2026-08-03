"""The comparison key two output destinations are declared to collide on.

`realpath(3)` fails on a final component that does not exist yet, and a report
destination normally does not: it is about to be created. The key is therefore
the resolved PARENT joined with the literal basename, which makes two spellings
of one file — `out.md` and `./out.md`, or a parent reached through `..` or a
symlink — compare equal, while two genuinely different files never do.
"""
from std.pathlib import cwd
from std.testing import assert_equal, assert_not_equal, TestSuite

from mtest.platform import destination_identity


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


def test_an_absolute_path_keeps_its_basename_verbatim() raises:
    assert_equal(destination_identity("/tmp/out.md"), "/tmp/out.md")


def test_an_unresolvable_parent_falls_back_to_the_lexical_form() raises:
    """A missing parent is exit 4 on the run path, so the key only has to be
    total and stable here, never canonical."""
    assert_equal(
        destination_identity("/no/such/dir/out.md"), "/no/such/dir/out.md"
    )


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
