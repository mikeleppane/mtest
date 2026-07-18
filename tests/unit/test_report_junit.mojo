"""Tests for the pure JUnit renderer (Layer 2).

Fast, in-process assertions over the renderer's structure and invariants: the
decimal-seconds `time` formatter, the dotted classname, the frozen node-id sort
key (verbatim for a `::`-bearing name, composed for a bracket sentinel), the
head+tail text bound, the recomputed suite counts, the frozen node-id row order,
the one-outcome-sentinel-per-suite invariant asserted DIRECTLY, and the exact
element shapes of every sentinel-matrix cell (build / attempts file-level /
attempts flaky / attempts per-test / non-retried per-test / not-run / suite
capture). The junit-10 schema + arithmetic oracle (`scripts/junit_check.py`) is
run over the REAL rendered output of these same cells by the
`scripts/junit_render_check.py` CI gate; here the shapes and counts are pinned
directly so a regression names itself.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.report.junit import (
    JunitCase,
    JunitPrimary,
    JunitRerun,
    JunitSuite,
    RenderedSuite,
    assemble,
    bounded_text_from_bytes,
    dotted_classname,
    format_seconds,
    node_sort_key,
    render_suite,
)


# --- Builders ---------------------------------------------------------------


def _blank_primary() -> JunitPrimary:
    return JunitPrimary("", "", "", "")


def _no_reruns() -> List[JunitRerun]:
    return List[JunitRerun]()


def _pass_case(name: String, cn: String) -> JunitCase:
    return JunitCase(name, cn, False, _blank_primary(), _no_reruns())


def _primary_case(
    name: String,
    cn: String,
    element: String,
    msg: String,
    typ: String,
    body: String,
) -> JunitCase:
    return JunitCase(
        name, cn, True, JunitPrimary(element, msg, typ, body), _no_reruns()
    )


def _sentinel(
    name: String,
    cn: String,
    has_primary: Bool,
    primary: JunitPrimary,
    var reruns: List[JunitRerun],
) -> JunitCase:
    return JunitCase(name, cn, has_primary, primary.copy(), reruns^)


def _count_occurrences(haystack: String, needle: String) -> Int:
    return len(haystack.split(needle)) - 1


def _fill(value: UInt8, n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(value)
    return out^


# --- format_seconds ---------------------------------------------------------


def test_format_seconds_three_decimals() raises:
    assert_equal(format_seconds(0.043), "0.043")
    assert_equal(format_seconds(0.21), "0.210")
    assert_equal(format_seconds(1.5), "1.500")
    assert_equal(format_seconds(0.0), "0.000")


def test_format_seconds_pads_and_rounds() raises:
    assert_equal(format_seconds(0.0005), "0.001")  # 0.5ms rounds up
    assert_equal(format_seconds(2.0), "2.000")


def test_format_seconds_clamps_negative() raises:
    assert_equal(format_seconds(-3.0), "0.000")


def test_format_seconds_no_exponent_on_large() raises:
    var s = format_seconds(1234.5)
    assert_false("e" in s)
    assert_false("E" in s)
    assert_equal(s, "1234.500")


# --- classname / node id ----------------------------------------------------


def test_dotted_classname() raises:
    assert_equal(
        dotted_classname("e2e/suite/test_failing.mojo"),
        "e2e.suite.test_failing",
    )
    assert_equal(dotted_classname("top.mojo"), "top")


def test_node_sort_key_verbatim_when_double_colon() raises:
    assert_equal(
        node_sort_key("e2e/x.mojo", "e2e/x.mojo::test_a"), "e2e/x.mojo::test_a"
    )


def test_node_sort_key_composed_for_sentinel() raises:
    assert_equal(node_sort_key("e2e/x.mojo", "[build]"), "e2e/x.mojo::[build]")
    assert_equal(
        node_sort_key("e2e/x.mojo", "[not-run]"), "e2e/x.mojo::[not-run]"
    )


# --- bounded text -----------------------------------------------------------


def test_bounded_text_head_tail() raises:
    var data = List[UInt8]()
    data += _fill(0x61, 65536)  # 'a' head
    data += _fill(0x5A, 8)  # 'Z' dropped middle
    data += _fill(0x62, 65536)  # 'b' tail
    var text = bounded_text_from_bytes(data)
    assert_true("a…b" in text)
    assert_false("Z" in text)


def test_bounded_text_small_passthrough() raises:
    var data = List[UInt8]()
    for b in String("hi & <there>").as_bytes():
        data.append(b)
    assert_equal(bounded_text_from_bytes(data), "hi & <there>")


# --- render_suite: counts, sort, single sentinel ----------------------------


def test_render_suite_counts_and_sort_order() raises:
    var cn = dotted_classname("a/x.mojo")
    var cases = List[JunitCase]()
    # Deliberately out of node-id order; the renderer must sort.
    cases.append(_pass_case("a/x.mojo::test_ok", cn))
    cases.append(
        _primary_case(
            "[build]", cn, "error", "killed by signal 11", "Crash", "signal 11"
        )
    )
    var suite = JunitSuite("a/x.mojo", 0.043, cases^, "", "")
    var r = render_suite(suite)
    assert_equal(r.tests, 2)
    assert_equal(r.errors, 1)
    assert_equal(r.failures, 0)
    assert_equal(r.skipped, 0)
    assert_equal(r.suite_key, "a/x.mojo")
    # '[' (0x5B) sorts before 't' (0x74): the sentinel row is emitted first.
    var i_build = r.body.find("[build]")
    var i_ok = r.body.find("test_ok")
    assert_true(i_build >= 0 and i_ok >= 0)
    assert_true(i_build < i_ok)
    assert_true('time="0.043"' in r.body)
    # Exactly one outcome sentinel, by construction.
    assert_equal(_count_occurrences(r.body, 'name="[build]"'), 1)
    assert_equal(_count_occurrences(r.body, 'name="[attempts]"'), 0)


def test_render_suite_flaky_row_counts_as_passing() raises:
    var cn = dotted_classname("b/y.mojo")
    var reruns = List[JunitRerun]()
    reruns.append(
        JunitRerun(
            "flakyFailure", "boom", "AssertionError", "at line 9", "out", "err"
        )
    )
    var cases = List[JunitCase]()
    cases.append(_sentinel("[attempts]", cn, False, _blank_primary(), reruns^))
    cases.append(_pass_case("b/y.mojo::test_recovered", cn))
    var suite = JunitSuite("b/y.mojo", 0.21, cases^, "", "")
    var r = render_suite(suite)
    assert_equal(r.tests, 2)
    assert_equal(r.failures, 0)  # flakyFailure is NOT a failure
    assert_equal(r.errors, 0)
    assert_true('type="AssertionError"' in r.body)  # type is required
    assert_true("<flakyFailure" in r.body)


def test_render_primary_self_closes_empty_body_skipped() raises:
    var cn = dotted_classname("b/y.mojo")
    var cases = List[JunitCase]()
    cases.append(
        _primary_case("b/y.mojo::test_skip", cn, "skipped", "", "", "")
    )
    var suite = JunitSuite("b/y.mojo", 0.0, cases^, "", "")
    var r = render_suite(suite)
    assert_equal(r.skipped, 1)
    assert_true("<skipped/>" in r.body)


# --- assemble: root shape ---------------------------------------------------


def test_assemble_root_has_no_skipped_attribute() raises:
    var cn = dotted_classname("b/y.mojo")
    var cases = List[JunitCase]()
    cases.append(
        _primary_case("b/y.mojo::test_skip", cn, "skipped", "skip", "", "")
    )
    var frags = List[RenderedSuite]()
    frags.append(render_suite(JunitSuite("b/y.mojo", 0.0, cases^, "", "")))
    var doc = assemble("mtest", frags)
    assert_true("<testsuites " in doc)
    assert_true('<?xml version="1.0" encoding="UTF-8"?>' in doc)
    # The root line (before the first suite) carries no `skipped`.
    var root_line = doc.split("<testsuite ")[0]
    assert_false('skipped="' in root_line)


def test_assemble_root_sums_and_sorts_suites() raises:
    var frags = List[RenderedSuite]()
    frags.append(
        RenderedSuite("m/b.mojo", '<testsuite name="m/b.mojo"/>', 2, 1, 0, 0)
    )
    frags.append(
        RenderedSuite("a/a.mojo", '<testsuite name="a/a.mojo"/>', 3, 0, 2, 1)
    )
    var doc = assemble("mtest", frags)
    assert_true('tests="5"' in doc)
    assert_true('failures="1"' in doc)
    assert_true('errors="2"' in doc)
    # a/a.mojo sorts before m/b.mojo.
    assert_true(doc.find("a/a.mojo") < doc.find("m/b.mojo"))


# --- Sentinel-matrix cell SHAPES (pure renderer) ----------------------------


def test_cell1_build_shape() raises:
    var cn = dotted_classname("e2e/c1.mojo")
    var cases = List[JunitCase]()
    cases.append(
        _primary_case(
            "[build]", cn, "error", "killed by signal 11", "Crash", "signal 11"
        )
    )
    cases.append(_pass_case("e2e/c1.mojo::test_survivor", cn))
    var r = render_suite(JunitSuite("e2e/c1.mojo", 0.05, cases^, "", ""))
    assert_equal(r.errors, 1)
    assert_equal(_count_occurrences(r.body, 'name="[build]"'), 1)
    assert_true("<error " in r.body)


def test_cell2_attempts_filelevel_initial_primary_shape() raises:
    var cn = dotted_classname("e2e/c2.mojo")
    var reruns = List[JunitRerun]()
    reruns.append(
        JunitRerun(
            "rerunError", "killed by signal 11", "Crash", "attempt 2", "", ""
        )
    )
    reruns.append(
        JunitRerun(
            "rerunError",
            "killed by signal 11",
            "Crash",
            "attempt 3 final",
            "",
            "",
        )
    )
    var cases = List[JunitCase]()
    cases.append(
        _sentinel(
            "[attempts]",
            cn,
            True,
            JunitPrimary("error", "killed by signal 11", "Crash", "attempt 1"),
            reruns^,
        )
    )
    var r = render_suite(JunitSuite("e2e/c2.mojo", 0.30, cases^, "", ""))
    assert_equal(r.errors, 1)  # only the primary counts; reruns do not
    assert_equal(r.tests, 1)
    # First attempt is the primary; both later attempts are reruns after it.
    var i_primary = r.body.find("<error")
    var i_rerun = r.body.find("<rerunError")
    assert_true(i_primary >= 0 and i_rerun >= 0 and i_primary < i_rerun)
    assert_equal(_count_occurrences(r.body, "<rerunError"), 2)
    assert_equal(_count_occurrences(r.body, 'name="[attempts]"'), 1)
    assert_equal(_count_occurrences(r.body, 'name="[build]"'), 0)


def test_cell3_flaky_chronology_shape() raises:
    var cn = dotted_classname("e2e/c3.mojo")
    var reruns = List[JunitRerun]()
    reruns.append(
        JunitRerun(
            "flakyFailure", "transient", "AssertionError", "attempt 1", "o", "e"
        )
    )
    reruns.append(
        JunitRerun(
            "flakyFailure", "transient", "AssertionError", "attempt 2", "", ""
        )
    )
    var cases = List[JunitCase]()
    cases.append(_sentinel("[attempts]", cn, False, _blank_primary(), reruns^))
    cases.append(_pass_case("e2e/c3.mojo::test_recovered", cn))
    var r = render_suite(JunitSuite("e2e/c3.mojo", 0.21, cases^, "", ""))
    assert_equal(r.failures, 0)
    assert_equal(r.errors, 0)
    assert_equal(r.tests, 2)
    var i_a1 = r.body.find("attempt 1")
    var i_a2 = r.body.find("attempt 2")
    assert_true(i_a1 >= 0 and i_a2 >= 0 and i_a1 < i_a2)  # attempt order
    assert_equal(_count_occurrences(r.body, "<flakyFailure"), 2)


def test_cell4_attempts_pertest_shape() raises:
    var cn = dotted_classname("e2e/c4.mojo")
    var reruns = List[JunitRerun]()
    reruns.append(
        JunitRerun(
            "rerunFailure", "assertion", "AssertionError", "prior", "", ""
        )
    )
    var cases = List[JunitCase]()
    cases.append(_sentinel("[attempts]", cn, False, _blank_primary(), reruns^))
    cases.append(
        _primary_case(
            "e2e/c4.mojo::test_still_fails",
            cn,
            "failure",
            "left != right",
            "AssertionError",
            "at line 14",
        )
    )
    var r = render_suite(JunitSuite("e2e/c4.mojo", 0.40, cases^, "", ""))
    assert_equal(r.failures, 1)  # the per-test row, not the sentinel
    assert_equal(r.tests, 2)
    assert_true("<rerunFailure" in r.body)
    assert_equal(_count_occurrences(r.body, 'name="[attempts]"'), 1)


def test_cell5_pertest_no_sentinel_shape() raises:
    var cn = dotted_classname("e2e/c5.mojo")
    var cases = List[JunitCase]()
    cases.append(_pass_case("e2e/c5.mojo::test_a", cn))
    cases.append(
        _primary_case(
            "e2e/c5.mojo::test_b",
            cn,
            "failure",
            "left != right",
            "AssertionError",
            "at line 3",
        )
    )
    var r = render_suite(JunitSuite("e2e/c5.mojo", 0.02, cases^, "", ""))
    assert_equal(r.failures, 1)
    assert_equal(_count_occurrences(r.body, 'name="[build]"'), 0)
    assert_equal(_count_occurrences(r.body, 'name="[attempts]"'), 0)


def test_cell6_not_run_shape() raises:
    var cn = dotted_classname("e2e/c6.mojo")
    var cases = List[JunitCase]()
    cases.append(
        _primary_case(
            "[not-run]",
            cn,
            "skipped",
            "not run: precompile failed (build)",
            "",
            "",
        )
    )
    var r = render_suite(JunitSuite("e2e/c6.mojo", 0.0, cases^, "", ""))
    assert_equal(r.skipped, 1)
    assert_equal(r.tests, 1)
    assert_true("not run: precompile failed (build)" in r.body)


def test_suite_level_capture_shape() raises:
    var cn = dotted_classname("e2e/cap.mojo")
    var cases = List[JunitCase]()
    cases.append(_pass_case("e2e/cap.mojo::test_ok", cn))
    var r = render_suite(
        JunitSuite(
            "e2e/cap.mojo",
            0.01,
            cases^,
            "captured <stdout> & more",
            "captured stderr",
        )
    )
    assert_true("<system-out>" in r.body)
    assert_true("<system-err>" in r.body)
    assert_true("captured &lt;stdout&gt; &amp; more" in r.body)  # escaped


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
