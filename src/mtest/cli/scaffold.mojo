"""`mtest new`: create one runnable test file, and never overwrite one.

Part of the cli layer. The first test file in a project is the one a reader has
to get exactly right from memory, and two of its parts are not guessable: the
import resolves only under the full `std.testing` name, and without the
`main()` that hands the tests to `TestSuite` the file builds into a program
that runs nothing. `render_test_file` is that file, and it compiles and passes
as written.

Nothing here prints or exits. `run_new` reports lines and a code, so the
composition root stays the only place that decides where a line goes and what
the process exits with.
"""
from std.os import makedirs, remove
from std.os.path import basename, dirname

from mtest.config import escape_control_characters, safe_path_label
from mtest.discover import is_discovered_test_name
from mtest.platform import (
    close_checked_fd,
    create_unique_temp,
    default_file_mode,
    process_id,
    publish_new_file,
    set_permissions,
    write_all_fd,
)


comptime _EXIT_IO_FAILURE = 3
"""The runner's own machinery failed: the scaffold could not be written."""

comptime _EXIT_REFUSED = 4
"""The request was refused before anything was created."""


def mojo_string_literal_body(value: String) -> String:
    """Escape `value` so it can be pasted inside a Mojo string literal.

    The scaffolded file interpolates a name the user chose into a docstring,
    and a filename may legally contain the two bytes that would end that
    literal early: a quote, and a backslash that would escape whatever follows
    it. Both are escaped here, along with every control character, so the
    result is one line of source that always closes the literal it was pasted
    into. Escaping every quote is also what makes the closing `\\"\\"\\"` of a
    triple-quoted literal unrepresentable.

    Args:
        value: The text to embed. Not mutated.

    Returns:
        The freshly allocated escaped text, safe between any pair of Mojo
        string quotes.

    Examples:

    ```mojo
    from mtest.cli.scaffold import mojo_string_literal_body

    print(mojo_string_literal_body('a"b'))  # a\\"b
    ```
    """
    var escaped = String("")
    comptime HEX = "0123456789abcdef"
    for cp in value.codepoints():
        var code = Int(cp)
        if code == 92:
            escaped += "\\\\"
        elif code == 34:
            escaped += '\\"'
        elif code == 10:
            escaped += "\\n"
        elif code == 13:
            escaped += "\\r"
        elif code == 9:
            escaped += "\\t"
        elif (code >= 0 and code < 32) or code == 127:
            escaped += "\\x"
            escaped += String(HEX[byte=code // 16])
            escaped += String(HEX[byte=code % 16])
        else:
            escaped += String(cp)
    return escaped^


def render_test_file(stem: String) -> String:
    """The complete source of one scaffolded test file.

    Args:
        stem: The subject the file tests, taken from its own basename. It is
            escaped for the docstring it lands in, so any legal filename
            produces a file that still compiles.

    Returns:
        The freshly allocated file bytes, newline-terminated.

    Examples:

    ```mojo
    from mtest.cli.scaffold import render_test_file

    print(render_test_file("math"))
    ```
    """
    return String(
        '"""Tests for ',
        mojo_string_literal_body(stem),
        '."""\n',
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


@fieldwise_init
struct ScaffoldReport(Copyable, Movable):
    """What one `mtest new` produced: lines to print and the code to exit."""

    var lines: List[String]
    """The one line describing what was created, refused, or failed."""

    var code: Int
    """Zero on success, four for a refusal, three for an I/O failure."""


def _report(line: String, code: Int) -> ScaffoldReport:
    """One line and its code, the shape every outcome takes.

    Args:
        line: The single line describing the outcome.
        code: The code `main` exits with.

    Returns:
        A freshly allocated report carrying exactly that line.
    """
    return ScaffoldReport([line], code)


def _stem(name: String) -> String:
    """The subject a test file's basename names.

    Args:
        name: A basename a directory walk would collect.

    Returns:
        The name with the `test_` prefix and `.mojo` suffix removed.
    """
    return String(String(name.removesuffix(".mojo")).removeprefix("test_"))


def _discard(fd: Int, temp: String):
    """Release a still-owned descriptor and temporary file, best effort.

    Args:
        fd: A descriptor this scaffold still owns, or a negative value when it
            owns none.
        temp: A temporary file this scaffold still owns, or an empty string.
    """
    if fd >= 0:
        try:
            close_checked_fd(fd)
        except:
            pass
    if temp != "":
        try:
            remove(temp)
        except:
            pass


def run_new(root: String, target: String) -> ScaffoldReport:
    """Scaffold one runnable test file at `target`, never replacing a file.

    Refuses a path carrying `::`, a path that is not Mojo source, and a
    basename no directory walk would collect — each of them a file the runner
    could not find or could not address afterwards, which is a trap rather
    than a head start. The file is written to a temporary name in the target's
    own directory and then published with a link, so an existing target is
    refused by the filesystem itself rather than by a check a concurrent
    creation could slip past.

    Args:
        root: The invocation root a relative `target` is resolved from.
        target: The path to create, as the caller spelled it.

    Returns:
        One line and the code to exit with: zero and `created <target>` on
        success, four for a refusal, three for an I/O failure. Allocates the
        rendered file and the transient temporary path.

    Examples:

    ```mojo
    from mtest.cli.scaffold import run_new

    var report = run_new("/tmp/project", "tests/test_math.mojo")
    print(report.lines[0], report.code)
    ```
    """
    var label = safe_path_label(target)
    # Refused before the suffix and basename rules, because this one is about
    # the path itself: `::` separates a path from a test name everywhere else
    # in the CLI, so a file created here under such a name is one mtest could
    # never be pointed at again.
    if target.find("::") != -1:
        return _report(
            "scaffold: '"
            + label
            + "' contains '::', which separates a path from a test name; mtest"
            " could not address the file it names",
            _EXIT_REFUSED,
        )
    if not target.endswith(".mojo"):
        return _report(
            "scaffold: '" + label + "' does not end in '.mojo'",
            _EXIT_REFUSED,
        )
    var name = String(basename(target))
    if not is_discovered_test_name(name):
        return _report(
            "scaffold: '"
            + label
            + "' would never be discovered; a directory walk collects"
            " test_*.mojo",
            _EXIT_REFUSED,
        )

    var absolute = target if target.startswith("/") else root + "/" + target
    var directory = String(dirname(absolute))
    var temp = String("")
    var owned_fd = -1
    try:
        makedirs(directory, exist_ok=True)
        # The temporary shares the target's directory so the publishing link
        # cannot straddle filesystems, and it is hidden so a walk interrupted
        # between the write and the link never collects a half-written file.
        var created = create_unique_temp(
            directory + "/.mtest-new." + String(process_id()) + ".XXXXXX"
        )
        temp = created.path.copy()
        owned_fd = created.fd
        write_all_fd(owned_fd, render_test_file(_stem(name)))
        # `close(2)` may release the descriptor even when it reports an error,
        # so ownership moves out of the cleanup path before the checked close.
        var closing_fd = owned_fd
        owned_fd = -1
        close_checked_fd(closing_fd)
        # Before publishing, not after: the link makes both names one inode,
        # so the mode set here is the one the published file appears with,
        # with no window in which it is readable only by its owner. The
        # temporary arrives as `mkstemp`'s 0600, which is right for a
        # temporary and wrong for source somebody is about to edit and commit
        # — they get what any editor would have given them instead.
        set_permissions(temp, default_file_mode())
        if not publish_new_file(temp, absolute):
            _discard(-1, temp)
            return _report(
                "scaffold: refusing to overwrite " + label, _EXIT_REFUSED
            )
    except e:
        _discard(owned_fd, temp)
        # The cause is escaped too. It carries paths this function did not
        # compose — the temporary's, and whatever the platform layer quoted —
        # so leaving it raw would defeat the escaping applied to `label` two
        # lines above.
        return _report(
            "scaffold: could not create '"
            + label
            + "': "
            + safe_path_label(String(e)),
            _EXIT_IO_FAILURE,
        )
    # Escaped, so a path carrying control bytes cannot write them to the
    # terminal — but NOT the bounded label: this line's format is frozen, and
    # a long path truncated to `created dddd...` would name a file that does
    # not exist.
    return _report("created " + escape_control_characters(target), 0)
