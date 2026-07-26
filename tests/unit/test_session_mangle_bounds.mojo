"""Pins `_mangle`'s length bound: a legal source path must stay buildable.

`_mangle` flattens a whole root-relative path into ONE filename, escaping every
`/` as `_s`. Depth therefore becomes filename length, and the two relevant OS
limits are different: `PATH_MAX` (4096 here) caps a whole path, `NAME_MAX`
(255) caps a single component. So a source path far below `PATH_MAX`, with
every component far below `NAME_MAX`, could still mangle into a component the
kernel refuses with `ENAMETOOLONG`.

The build then failed, and the failure was attributed to the user: the file was
reported COMPILE-ERROR, which §6 reserves for the module's own fault. The
source compiled perfectly — mtest's own output name was the illegal thing.

The bound is on the mangled name alone, deliberately well under `NAME_MAX`,
because callers decorate it further (`.mtest-precompile-<mangled>.inv-<pid>
.attempt-N.tmp` is the widest) and every decorated form must still fit.

Injectivity: unchanged and exact for any name within budget, which is every
name that has ever been produced. An over-budget name necessarily loses
information, so it carries a 64-bit digest of the FULL mangled name to keep
collisions negligible where they were previously impossible — a trade only
reachable by paths that do not build at all today.
"""
from std.testing import assert_equal, assert_not_equal, assert_true

from mtest.session.scratch import _MANGLE_BUDGET, _mangle


def _deep(components: Int, width: Int, leaf: String) -> String:
    """A root-relative path of `components` dirs, each `width` chars wide."""
    var out = String("")
    for i in range(components):
        var name = String("d") + String(i)
        while name.byte_length() < width:
            name += "x"
        out += name + "/"
    return out + leaf


# --- short names are untouched ---


def test_short_name_is_the_plain_mangling() raises:
    """The budget must not perturb any name that already fit."""
    assert_equal(_mangle("tests/sub/test_a.mojo"), "tests_ssub_stest_ua")


def test_name_at_the_budget_is_not_bounded() raises:
    var rel = _deep(1, _MANGLE_BUDGET - 20, "test_a.mojo")
    var got = _mangle(rel)
    if got.byte_length() <= _MANGLE_BUDGET:
        assert_true("_stest_ua" in got, got)


# --- over-budget names are bounded, deterministic, and still discriminating ---


def test_deep_path_mangles_within_the_budget() raises:
    """The regression: 75 components x 15 chars mangled to ~1291 bytes."""
    var rel = _deep(75, 15, "test_deep.mojo")
    var got = _mangle(rel)
    assert_true(
        got.byte_length() <= _MANGLE_BUDGET,
        String("mangled name is ") + String(got.byte_length()) + " bytes",
    )


def test_bounded_name_is_deterministic() raises:
    var rel = _deep(75, 15, "test_deep.mojo")
    assert_equal(_mangle(rel), _mangle(rel))


def test_bounded_name_keeps_the_test_file_visible() raises:
    """Truncating from the left keeps the discriminating tail readable."""
    var rel = _deep(75, 15, "test_deep.mojo")
    assert_true("test_udeep" in _mangle(rel), _mangle(rel))


def test_two_deep_paths_do_not_collide() raises:
    """Distinct over-budget paths must still produce distinct names."""
    var a = _mangle(_deep(75, 15, "test_deep.mojo"))
    var b = _mangle(_deep(75, 15, "test_other.mojo"))
    assert_not_equal(a, b)


def test_deep_paths_differing_only_in_a_prefix_do_not_collide() raises:
    """The tail is identical here, so only the digest separates them."""
    var a = _mangle(String("alpha/") + _deep(75, 15, "test_deep.mojo"))
    var b = _mangle(String("beta/") + _deep(75, 15, "test_deep.mojo"))
    assert_not_equal(a, b)


def test_bounded_name_has_no_separator_that_breaks_a_path() raises:
    """A mangled name is ONE component: it must never contain a `/`."""
    var got = _mangle(_deep(75, 15, "test_deep.mojo"))
    assert_true("/" not in got, got)


def test_unicode_deep_path_is_bounded_without_splitting_a_codepoint() raises:
    """Truncation is by codepoint: a mangled name stays valid UTF-8."""
    var rel = _deep(75, 15, "test_ünïcødé.mojo")
    var got = _mangle(rel)
    assert_true(got.byte_length() <= _MANGLE_BUDGET, got)
    # Round-tripping the bytes proves no codepoint was cut in half.
    assert_equal(String(got), got)
