"""Pins `_precompile_temp_path`: the per-attempt TEMP path a precompile builds to.

A precompile ATTEMPT never writes OUT. It writes a temp path derived from OUT and
renamed onto OUT only after the compiler exits 0, so a killed or crashed attempt
cannot damage a good package left by an earlier run. Six properties make that
hold, and all six are pinned here: the temp is NEVER equal to OUT (a promotion
that renamed a path onto itself would promote a corpse), every attempt gets a
DISTINCT temp (a retry must never inherit the killed attempt's half-written
bytes), every STEP gets a distinct temp (two steps — or two concurrent runs over
one root — must not unlink each other's temp dir mid-compile), every concurrent
INVOCATION gets a distinct temp (two mtest PROCESSES over one checkout must not
collide on a temp one's compiler is writing), the temp stays UNDER OUT's directory
(a rename is atomic only within one filesystem — across one it silently becomes a
copy), and it is NOT IN that directory: `-I <out-dir>` scans OUT's directory, and
the toolchain forces a package OUT path to keep its `.mojopkg`/`.mojoc` extension
(`mojo precompile -o x.tmp` is a hard error), so the ONLY place a still-unpromoted
package can hide from the include scan is a `.tmp` subdirectory of its own. Reached
through the same private-helper seam `test_session_mangle.mojo` uses.
"""
from std.os.path import basename, dirname
from std.testing import assert_equal, assert_false, assert_true

from mtest.session.session import _precompile_temp_path


def test_temp_path_is_derived_from_out_with_attempt_index() raises:
    assert_equal(
        _precompile_temp_path(
            "build/mathlib.mojopkg", "e2e/pkg/mathlib", 1, "7"
        ),
        (
            "build/.mtest-precompile-e2e_spkg_smathlib.inv-7.attempt-1.tmp/"
            "mathlib.mojopkg"
        ),
    )
    assert_equal(
        _precompile_temp_path(
            "build/mathlib.mojopkg", "e2e/pkg/mathlib", 2, "7"
        ),
        (
            "build/.mtest-precompile-e2e_spkg_smathlib.inv-7.attempt-2.tmp/"
            "mathlib.mojopkg"
        ),
    )


def test_temp_path_never_equals_out() raises:
    var out = String("build/mathlib.mojopkg")
    for k in range(1, 5):
        assert_false(
            _precompile_temp_path(out, "pkg/mathlib", k, "7") == out,
            "a temp path equal to OUT would promote a killed attempt",
        )


def test_each_attempt_gets_a_distinct_temp_path() raises:
    var out = String("build/mathlib.mojopkg")
    var seen = List[String]()
    for k in range(1, 5):
        var t = _precompile_temp_path(out, "pkg/mathlib", k, "7")
        for s in seen:
            assert_false(s == t, "two attempts shared a temp path: " + t)
        seen.append(t)


def test_each_step_gets_a_distinct_temp_path() raises:
    # Two steps sharing one temp DIRECTORY could unlink it under each other's
    # compiler (as could a second mtest run over the same root, or a stale dir
    # from a SIGKILLed one). The mangled source keys them apart, symmetrically
    # with the per-attempt quarantine dir.
    var a = _precompile_temp_path("build/lib.mojopkg", "pkg/one", 1, "7")
    var b = _precompile_temp_path("build/lib.mojopkg", "pkg/two", 1, "7")
    assert_false(a == b, "two distinct steps shared a temp path: " + a)
    assert_false(
        dirname(a) == dirname(b), "two distinct steps shared a temp directory"
    )


def test_each_invocation_gets_a_distinct_temp_path() raises:
    # Two concurrent mtest PROCESSES over one checkout key on the same source and
    # attempt; only the per-invocation nonce keeps their temp dirs apart, so one
    # process's compiler cannot have its temp renamed/removed under it.
    var a = _precompile_temp_path("build/lib.mojopkg", "pkg/one", 1, "111")
    var b = _precompile_temp_path("build/lib.mojopkg", "pkg/one", 1, "222")
    assert_false(a == b, "two concurrent invocations shared a temp path: " + a)
    assert_false(
        dirname(a) == dirname(b),
        "two concurrent invocations shared a temp directory",
    )


def test_temp_path_stays_under_the_out_directory() raises:
    # The rename must stay on one filesystem, or the promotion is a copy and no
    # longer atomic. A subdirectory of OUT's own directory guarantees it.
    var out = String("out/pkgs/mathlib.mojopkg")
    assert_equal(
        dirname(dirname(_precompile_temp_path(out, "pkg/mathlib", 1, "7"))),
        "out/pkgs",
    )
    # A bare OUT name resolves against the invocation root, so its temp does too.
    assert_equal(
        dirname(dirname(_precompile_temp_path("mathlib.mojopkg", "m", 1, "7"))),
        "",
    )


def test_temp_path_is_not_in_the_out_directory_itself() raises:
    # `-I <dir>` scans the OUT directory, and the toolchain forbids renaming the
    # package extension away, so an unpromoted attempt hides in a `.tmp` dir.
    var out = String("build/mathlib.mojopkg")
    var t = _precompile_temp_path(out, "pkg/mathlib", 1, "7")
    assert_false(dirname(t) == dirname(out))
    assert_true(dirname(t).endswith(".tmp"))
    # It keeps OUT's own basename, so the promotion is a pure rename.
    assert_equal(basename(t), basename(out))
