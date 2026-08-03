"""Tests for the pure collect-stream NDJSON serializer.

Exact-output assertions over `collect_stream_header`, `collect_node_line`, and
`collect_finished_line`: the frozen header line, the per-line field mapping,
and escaping of a hostile node id, path, and name — `path` in particular is
attacker-influenced, coming straight off the discovery walk.
"""
from std.testing import assert_equal, TestSuite

from mtest.cli.parser import MTEST_VERSION
from mtest.report.collect_stream import (
    collect_finished_line,
    collect_node_line,
    collect_stream_header,
)


# --- Stream header ------------------------------------------------------


def test_collect_header_exact() raises:
    var want = (
        '{"event":"collect","version":1,"generator":"mtest '
        + MTEST_VERSION
        + '"}'
    )
    assert_equal(collect_stream_header(MTEST_VERSION), want)


def test_collect_header_escapes_version() raises:
    assert_equal(
        collect_stream_header('1.0"\\x'),
        '{"event":"collect","version":1,"generator":"mtest 1.0\\"\\\\x"}',
    )


# --- Node line ------------------------------------------------------------


def test_node_line_exact() raises:
    assert_equal(
        collect_node_line(
            "tests/test_a.mojo::test_x", "tests/test_a.mojo", "test_x"
        ),
        '{"event":"node","node_id":"tests/test_a.mojo::test_x"'
        + ',"path":"tests/test_a.mojo","name":"test_x"}',
    )


def test_node_line_hostile_fields_exact() raises:
    # The same hostile content in ALL THREE fields, pinned as a full-string
    # equality: a substring check alone can't catch a duplicated key, a stray
    # comma, or a mangled field order, and `path` in particular is the one
    # attacker-influenced field (straight off the discovery walk) — it must
    # not be the one field that skips escaping.
    var raw = (
        '"'  # quote
        + "\\"  # backslash
        + "\n"  # newline
        + "\t"  # tab
        + chr(1)  # a C0 control character
        + "é"  # non-ASCII
        + "}"  # a literal close-brace, to prove structure survives
    )
    var escaped = (
        '\\"'  # escaped quote
        + "\\\\"  # escaped backslash
        + "\\n"  # escaped newline
        + "\\t"  # escaped tab
        + "\\u0001"  # escaped C0 control character
        + "é"  # non-ASCII passes through
        + "}"  # passes through
    )
    assert_equal(
        collect_node_line(raw, raw, raw),
        '{"event":"node","node_id":"'
        + escaped
        + '","path":"'
        + escaped
        + '","name":"'
        + escaped
        + '"}',
    )


# --- Terminal line ----------------------------------------------------------


def test_terminal_line_exact() raises:
    assert_equal(
        collect_finished_line(3, 1),
        '{"event":"collect_finished","nodes":3,"exit_code":1}',
    )


def test_terminal_line_empty_collection_exact() raises:
    # The empty-collection terminal: what a discovery walk that matches
    # nothing emits. Nothing else pins this shape.
    assert_equal(
        collect_finished_line(0, 0),
        '{"event":"collect_finished","nodes":0,"exit_code":0}',
    )


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
