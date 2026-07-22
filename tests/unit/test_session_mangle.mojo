"""Pins `_mangle`'s injectivity: no two distinct root-relative paths collide.

The build-artifact binary name is the runner's trust boundary — if two
distinct source files ever mangled to the same `build/bin/` name, one binary
would silently overwrite the other and the runner could execute the WRONG
test's binary under the RIGHT test's name. A naive `/`->`__` replacement is
NOT injective (`a/b.mojo` and the literal file `a__b.mojo` both mangle to
`a__b`); these tests pin the escaping scheme (`_`->`_u`, `/`->`_s`) that
closes that hole, reached through the same private-helper seam
`test_exec_interrupt.mojo` uses for `mtest.exec.signals`.
"""
from std.testing import assert_equal, assert_true

from mtest.session.scratch import _mangle


def test_mangle_normal_path_is_sensible() raises:
    assert_equal(_mangle("tests/sub/test_a.mojo"), "tests_ssub_stest_ua")
    assert_equal(_mangle("test_a.mojo"), "test_ua")


def test_mangle_distinguishes_separator_from_literal_underscore() raises:
    # a/b.mojo vs the literal file a__b.mojo: the naive `/`->`__` scheme
    # collided these; the escaping scheme must not.
    assert_true(_mangle("a/b.mojo") != _mangle("a__b.mojo"))


def test_mangle_distinguishes_adversarial_pairs() raises:
    assert_true(_mangle("a_b/c.mojo") != _mangle("a/b_c.mojo"))
    assert_true(_mangle("a/b/c.mojo") != _mangle("a__b__c.mojo"))
    assert_true(_mangle("x_/y.mojo") != _mangle("x/_y.mojo"))
