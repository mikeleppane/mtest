"""Scaffolding one runnable test file, and the never-overwrite promise.

Two invariants carry this module. The template is pinned byte-for-byte,
because it is the one thing a reader runs unchanged and a drifted import line
or a lost blank line makes it uncompilable. And publication must refuse an
existing destination while leaving its bytes exactly as they were: the refusal
is a property of `link(2)`, not of a check that a concurrent creation could
slip past, so the surviving content is what the assertion is really about.
"""
from std.os import listdir, mkdir, remove, stat
from std.os.path import exists
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)

from mtest.cli import parse_args
from mtest.cli.scaffold import (
    mojo_string_literal_body,
    render_test_file,
    run_new,
)
from mtest.platform import (
    close_checked_fd,
    create_unique_temp,
    publish_new_file,
    write_all_fd,
)

from tmptree import remove_tree, temp_root


def _read(path: String) raises -> String:
    with open(path, "r") as source:
        return source.read()


def _write(path: String, text: String) raises:
    with open(path, "w") as destination:
        destination.write(text)


def _temp_holding(directory: String, text: String) raises -> String:
    """Create one closed temporary file carrying `text` in `directory`."""
    var created = create_unique_temp(directory + "/publish.XXXXXX")
    var path = created.path.copy()
    write_all_fd(created.fd, text)
    close_checked_fd(created.fd)
    return path^


def test_template_bytes_are_exact() raises:
    var expected = String(
        '"""Tests for math."""\n',
        "\n",
        "from std.testing import assert_equal, TestSuite\n",
        "\n",
        "\n",
        "def test_example() raises:\n",
        "    assert_equal(2 + 2, 4)\n",
        "\n",
        "\n",
        "def main() raises:\n",
        "    TestSuite.discover_tests[__functions_in_module()]().run()\n",
    )
    assert_equal(render_test_file("math"), expected)


def test_literal_encoder_closes_every_quote_and_backslash() raises:
    # The two bytes that end a Mojo string literal early, plus the control
    # characters that would split the line the literal sits on.
    assert_equal(mojo_string_literal_body('a"b'), 'a\\"b')
    assert_equal(mojo_string_literal_body('"""'), '\\"\\"\\"')
    assert_equal(mojo_string_literal_body("trail\\"), "trail\\\\")
    assert_equal(mojo_string_literal_body("a\nb\tc\rd"), "a\\nb\\tc\\rd")
    assert_equal(mojo_string_literal_body("bell\x07"), "bell\\x07")
    assert_equal(mojo_string_literal_body("plain-ä"), "plain-ä")


def test_template_closes_its_docstring_for_a_hostile_stem() raises:
    # `test_""".mojo` is a legal filename a walk would collect, so the
    # scaffolded file has to survive it: unescaped, the stem ends the
    # docstring three characters early and the file does not compile.
    var rendered = render_test_file('"""')
    assert_true(rendered.startswith('"""Tests for \\"\\"\\"."""\n'))
    assert_true("from std.testing import" in rendered)
    var backslash = render_test_file("trail\\")
    assert_true(backslash.startswith('"""Tests for trail\\\\."""\n'))


def test_publish_creates_a_missing_destination() raises:
    var root = temp_root()
    try:
        var temp = _temp_holding(root, "published")
        var destination = root + "/created.txt"
        assert_true(publish_new_file(temp, destination))
        assert_equal(_read(destination), "published")
        assert_false(exists(temp))
    finally:
        remove_tree(root)


def test_publish_refuses_an_existing_destination_and_keeps_its_bytes() raises:
    var root = temp_root()
    try:
        var destination = root + "/occupied.txt"
        _write(destination, "the bytes that must survive")
        var temp = _temp_holding(root, "the bytes that must never land")

        assert_false(publish_new_file(temp, destination))

        assert_equal(_read(destination), "the bytes that must survive")
        # The refused temporary stays the caller's to remove, so the failure
        # path owns exactly one cleanup and never guesses at another's.
        assert_true(exists(temp))
        assert_equal(_read(temp), "the bytes that must never land")
    finally:
        remove_tree(root)


def test_publish_reports_a_real_failure_rather_than_a_refusal() raises:
    var root = temp_root()
    try:
        var temp = _temp_holding(root, "never published")
        with assert_raises(contains="platform: link failed"):
            _ = publish_new_file(temp, root + "/missing/deep.txt")
    finally:
        remove_tree(root)


def test_new_scaffolds_a_runnable_discoverable_file() raises:
    var root = temp_root()
    try:
        var report = run_new(root, "tests/test_math.mojo")
        assert_equal(report.code, 0)
        assert_equal(len(report.lines), 1)
        assert_equal(report.lines[0], "created tests/test_math.mojo")
        assert_equal(
            _read(root + "/tests/test_math.mojo"), render_test_file("math")
        )
        # Nothing but the scaffolded file survives the publication.
        assert_equal(len(listdir(root + "/tests")), 1)
    finally:
        remove_tree(root)


def test_new_gives_the_file_the_mode_an_editor_would() raises:
    var root = temp_root()
    try:
        var report = run_new(root, "tests/test_mode.mojo")
        assert_equal(report.code, 0)
        # `mkstemp` hands back 0600, which is right for a temporary and wrong
        # for source about to be edited and committed; the published file must
        # carry the mode this process's umask gives an ordinary new file.
        #
        # The oracle is the kernel, reached through a different syscall:
        # `mkdir` asks for 0777 and comes back with the umask already applied,
        # and masking that down to the file bits is what an `open(2)` asking
        # for 0666 would have produced. Neither `default_file_mode()` — the
        # very call the scaffold uses, which would agree with any answer it
        # gives — nor a hard-coded 0644, which is only true under one umask.
        mkdir(root + "/probe", 0o777)
        var expected = (Int(stat(root + "/probe").st_mode) & 0o777) & 0o666
        var mode = Int(stat(root + "/tests/test_mode.mojo").st_mode) & 0o777
        assert_equal(mode, expected)
    finally:
        remove_tree(root)


def test_new_success_line_carries_the_whole_path() raises:
    var root = temp_root()
    try:
        var directory = String("")
        for _ in range(250):
            directory += "d"
        var target = directory + "/test_long.mojo"
        var report = run_new(root, target)
        assert_equal(report.code, 0)
        # A bounded diagnostic label would have truncated this to 240
        # codepoints and named a file that does not exist.
        assert_equal(report.lines[0], "created " + target)
        assert_true(exists(root + "/" + target))
    finally:
        remove_tree(root)


def test_new_refuses_a_node_id_shaped_path() raises:
    var root = temp_root()
    try:
        var report = run_new(root, "tests/test_colon::name.mojo")
        assert_equal(report.code, 4)
        assert_equal(len(report.lines), 1)
        assert_true("contains '::'" in report.lines[0])
        # Refused before any filesystem mutation, so not even the parent
        # directory of a file mtest could never address again is created.
        assert_false(exists(root + "/tests"))
    finally:
        remove_tree(root)


def test_new_refuses_a_path_that_is_not_mojo_source() raises:
    var root = temp_root()
    try:
        var report = run_new(root, "tests/test_math.txt")
        assert_equal(report.code, 4)
        assert_equal(len(report.lines), 1)
        assert_true("does not end in '.mojo'" in report.lines[0])
        assert_false(exists(root + "/tests"))
    finally:
        remove_tree(root)


def test_new_refuses_a_basename_no_walk_would_collect() raises:
    var root = temp_root()
    try:
        var report = run_new(root, "tests/helper.mojo")
        assert_equal(report.code, 4)
        assert_equal(len(report.lines), 1)
        assert_true("test_*.mojo" in report.lines[0])
        assert_false(exists(root + "/tests"))
    finally:
        remove_tree(root)


def test_new_refuses_to_overwrite_an_existing_target() raises:
    var root = temp_root()
    try:
        var first = run_new(root, "test_once.mojo")
        assert_equal(first.code, 0)
        _write(root + "/test_once.mojo", "hand-written, and irreplaceable")

        var second = run_new(root, "test_once.mojo")
        assert_equal(second.code, 4)
        assert_equal(
            second.lines[0], "scaffold: refusing to overwrite test_once.mojo"
        )
        assert_equal(
            _read(root + "/test_once.mojo"), "hand-written, and irreplaceable"
        )
        # The refused temporary is removed, so a refusal leaves no litter.
        assert_equal(len(listdir(root)), 1)
    finally:
        remove_tree(root)


def test_new_creates_missing_parent_directories() raises:
    var root = temp_root()
    try:
        var report = run_new(root, "tests/deep/nested/test_leaf.mojo")
        assert_equal(report.code, 0)
        assert_equal(
            _read(root + "/tests/deep/nested/test_leaf.mojo"),
            render_test_file("leaf"),
        )
    finally:
        remove_tree(root)


def test_new_reports_an_unusable_parent_as_an_io_failure() raises:
    var root = temp_root()
    try:
        # A regular file where the scaffold needs a directory: not a refusal
        # the user can retype their way out of, so it is an I/O failure.
        _write(root + "/tests", "not a directory")
        var report = run_new(root, "tests/test_blocked.mojo")
        assert_equal(report.code, 3)
        assert_equal(len(report.lines), 1)
        # `"scaffold: " in ...` would be true of every reachable outcome, so
        # the line is pinned whole. It is composed here rather than forwarded
        # from the standard library, whose own error for this case is two
        # lines long and names the path twice — escaped, that put a literal
        # `\n` mid-sentence and truncated the second copy mid-path.
        assert_equal(
            report.lines[0],
            (
                "scaffold: could not create 'tests/test_blocked.mojo':"
                " 'tests' is not a directory"
            ),
        )
        assert_false(exists(root + "/tests/test_blocked.mojo"))
    finally:
        remove_tree(root)


def test_io_failure_escapes_the_cause_it_quotes() raises:
    var root = temp_root()
    try:
        # The cause carries paths this layer did not compose, so a control
        # byte in the target must not reach the terminal through it either.
        _write(root + "/tests", "not a directory")
        var report = run_new(root, "tests/test_esc\x1b[31m.mojo")
        assert_equal(report.code, 3)
        assert_false("\x1b" in report.lines[0])
        assert_true("\\x1b" in report.lines[0])
        # One line, and the whole target still named: the escaped form of a
        # newline is what the forwarded standard-library cause used to smuggle
        # into the middle of this diagnostic.
        assert_false("\\n" in report.lines[0])
        assert_false("..." in report.lines[0])
    finally:
        remove_tree(root)


def test_new_parses_as_exactly_one_operand() raises:
    var result = parse_args(["new", "tests/test_thing.mojo"])
    assert_true(result.is_new())
    assert_equal(result.operand, "tests/test_thing.mojo")


def test_new_without_an_operand_is_a_usage_error() raises:
    with assert_raises(contains="'new' wants exactly one PATH"):
        _ = parse_args(["new"])


def test_new_with_two_operands_is_a_usage_error() raises:
    with assert_raises(contains="'new' wants exactly one PATH"):
        _ = parse_args(["new", "test_a.mojo", "test_b.mojo"])


def test_new_refuses_every_flag_but_help() raises:
    with assert_raises(contains="cannot be combined with 'new'"):
        _ = parse_args(["new", "-q", "test_a.mojo"])


def test_new_help_is_the_help_directive() raises:
    var result = parse_args(["new", "--help"])
    assert_true(result.is_help())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
