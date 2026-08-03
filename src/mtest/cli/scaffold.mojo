"""`mtest new` and `mtest init`: write source, and never overwrite source.

Part of the cli layer. The first test file in a project is the one a reader has
to get exactly right from memory, and two of its parts are not guessable: the
import resolves only under the full `std.testing` name, and without the
`main()` that hands the tests to `TestSuite` the file builds into a program
that runs nothing. `render_test_file` is that file, and it compiles and passes
as written. `run_init` writes it beside the two other files a project needs to
exist before any of this is useful — a configuration and an ignore entry — and,
when asked, the workflow that runs the suite on GitHub.

Every artifact goes through one no-replace publication, so re-running either
command can only ever report what is already there. `.gitignore` is the sole
exception and the sole edit to a file this repository did not write: its new
content is what was read followed by the added lines, so replacing it is
correct, and the window between that read and the replacement is a lost update
if something else writes the file inside it. That is accepted rather than
solved. This is a bootstrap command a person runs once, by hand, in a directory
they are looking at.

That file is handled as bytes and read with git's own rules rather than a
substring search, because both shortcuts are wrong in the direction that
matters: git accepts a `.gitignore` that is not valid UTF-8, and a `!`
negation after a positive pattern means the directory is tracked after all.
Reporting "already ignored" in either case would leave a project whose build
cache git still tracks, which is precisely what this artifact exists to
prevent.

Nothing here prints or exits. Both entry points report lines and a code, so the
composition root stays the only place that decides where a line goes and what
the process exits with.
"""
from std.memory import Span
from std.os import makedirs, remove
from std.os.path import basename, dirname

from mtest.config import escape_control_characters, safe_path_label
from mtest.discover import is_discovered_test_name
from mtest.platform import (
    PathFacts,
    close_checked_fd,
    create_unique_temp,
    default_file_mode,
    observe_path,
    process_id,
    publish_new_file,
    read_regular_file_bytes,
    rename_path,
    set_permissions,
    write_all_bytes_fd,
)


comptime _EXIT_IO_FAILURE = 3
"""The runner's own machinery failed: the scaffold could not be written."""

comptime _EXIT_REFUSED = 4
"""The request was refused before anything was created."""

comptime _CACHE_IGNORE = ".mtest-cache"
"""The one path `init` asks a project's `.gitignore` to keep untracked."""

comptime _GITIGNORE_BLOCK = (
    "# mtest's build cache and last-run state\n.mtest-cache/\n"
)
"""What `init` writes when `.gitignore` does not already ignore the cache."""

comptime _GITIGNORE_MAX_BYTES = 1 << 20
"""The largest `.gitignore` this rewrites. A file past it is refused rather
than truncated: the replacement writes back what was read, so a bounded read of
an unbounded file would silently delete the tail."""


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


def render_mtest_toml() -> String:
    """The project configuration `mtest init` writes.

    One key, and the one worth having: with `[run] paths` set, `mtest` with no
    operands runs the suite instead of walking the whole checkout.

    Returns:
        The freshly allocated file bytes, newline-terminated.

    Examples:

    ```mojo
    from mtest.cli.scaffold import render_mtest_toml

    print(render_mtest_toml())  # [run]\\npaths = ["tests"]
    ```
    """
    return String('[run]\npaths = ["tests"]\n')


def render_github_workflow() -> String:
    """The GitHub Actions workflow `mtest init --ci github` writes.

    Byte-identical to the first YAML block of `docs/ci.md`, which the contract
    gate extracts and compares at check time so the page stays the one place
    the workflow is written down. Every third-party action is pinned to a
    commit rather than a tag, because a tag can be moved onto different code.

    Returns:
        The freshly allocated file bytes, newline-terminated.

    Examples:

    ```mojo
    from mtest.cli.scaffold import render_github_workflow

    print(render_github_workflow())
    ```
    """
    return String(
        "name: Tests\n",
        "\n",
        "on: [push, pull_request]\n",
        "\n",
        "permissions:\n",
        "  contents: read\n",
        "\n",
        "jobs:\n",
        "  test:\n",
        "    runs-on: ubuntu-24.04\n",
        "    timeout-minutes: 30\n",
        "    steps:\n",
        (
            "      - uses: actions/checkout@"
            "3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"
        ),
        "        with:\n",
        "          persist-credentials: false\n",
        "\n",
        (
            "      - uses: prefix-dev/setup-pixi@"
            "a09b6247153796b190642a2b53fac4241043cf6f # v0.10.0\n"
        ),
        "        with:\n",
        "          locked: true\n",
        "\n",
        "      - run: >-\n",
        "          pixi run mtest tests\n",
        "          --gh-annotations auto\n",
        "          --junit-xml build/test-results.xml\n",
        "\n",
        (
            "      - uses: actions/upload-artifact@"
            "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1\n"
        ),
        "        if: always()\n",
        "        with:\n",
        "          name: test-results\n",
        "          path: build/test-results.xml\n",
    )


def _gitignore_pattern(line: Span[UInt8, _]) -> String:
    """One `.gitignore` line reduced to the path it names, or empty.

    Git's own reading, byte for byte: trailing spaces and tabs are stripped (an
    escaped trailing space is not, and is out of scope here), a `\r` from a
    CRLF file goes with them, and leading whitespace is NOT stripped — it is
    part of the pattern, so `  .mtest-cache/` names a directory whose name
    begins with two spaces and ignores nothing.

    Args:
        line: One line's bytes, without its terminator.

    Returns:
        The pattern with a leading and a trailing `/` removed, so every
        spelling of the same directory compares equal; empty for a blank line
        or a comment. The bytes are ASCII-compared, so a line holding
        non-UTF-8 simply fails to match rather than failing to be read.
    """
    var end = len(line)
    while end > 0 and (
        line[end - 1] == 0x20 or line[end - 1] == 0x09 or line[end - 1] == 0x0D
    ):
        end -= 1
    if end == 0 or line[0] == 0x23:
        return String("")
    var text = String("")
    for index in range(end):
        text += String(chr(Int(line[index])))
    return String(String(text.removesuffix("/")).removeprefix("/"))


def _ignores_the_cache(existing: List[UInt8]) -> Bool:
    """Whether `existing` leaves the build-cache directory untracked.

    Git's last-matching-pattern rule, not a first-hit scan: a `!` negation
    after a positive pattern puts the directory back, and answering "already
    ignored" there would leave a project whose cache git still tracks.

    Args:
        existing: The current `.gitignore` bytes. Not mutated.

    Returns:
        True when the last pattern matching `.mtest-cache/` is a positive one.
    """
    var ignored = False
    var start = 0
    var index = 0
    while index <= len(existing):
        if index == len(existing) or existing[index] == 0x0A:
            var line = Span(existing)[start:index]
            var negated = len(line) > 0 and line[0] == 0x21
            var pattern = _gitignore_pattern(line[1:] if negated else line)
            if pattern == _CACHE_IGNORE:
                ignored = not negated
            start = index + 1
        index += 1
    return ignored


def _file_bytes(text: String) -> List[UInt8]:
    """Copy `text`'s encoded bytes into an owned list, verbatim."""
    var out = List[UInt8]()
    for byte in text.as_bytes():
        out.append(byte)
    return out^


def gitignore_update(
    existing: List[UInt8], present: Bool
) -> Optional[List[UInt8]]:
    """The bytes `.gitignore` should hold, or nothing when it is already right.

    Bytes rather than text on purpose. Git accepts a `.gitignore` that is not
    valid UTF-8, so decoding one in order to write it back would turn a legal
    file into a failed bootstrap; the existing bytes are carried through
    untouched and only ASCII is ever compared.

    Args:
        existing: The current file's bytes, or empty when there is no file.
            Not mutated.
        present: Whether a `.gitignore` exists at all.

    Returns:
        The complete new content — always the existing bytes followed by the
        added ones, so writing it back can only add — or `None` when the cache
        is already ignored and the file must be left alone. Allocates the
        returned bytes.

    Examples:

    ```mojo
    from mtest.cli.scaffold import gitignore_update

    var current: List[UInt8] = [ord("a"), 0x0A]
    print(len(gitignore_update(current, True).value()))
    ```
    """
    if not present:
        return Optional(_file_bytes(_GITIGNORE_BLOCK))
    if _ignores_the_cache(existing):
        return None
    var updated = existing.copy()
    # Without this the entry would be glued onto an unterminated last pattern,
    # silently changing what that pattern matches.
    if len(updated) > 0 and updated[len(updated) - 1] != 0x0A:
        updated.append(0x0A)
    updated.extend(_file_bytes(_GITIGNORE_BLOCK))
    return Optional(updated^)


@fieldwise_init
struct ScaffoldReport(Copyable, Movable):
    """What one scaffolding command produced: lines, and the code to exit."""

    var lines: List[String]
    """One line per artifact, plus whatever refused or failed.

    `mtest new` fills exactly one. `mtest init` fills one per artifact, then
    the next steps that make the project it just wrote usable."""

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


@fieldwise_init
struct _Published(Copyable, Movable):
    """What one no-replace publication did, and why it failed if it did."""

    var created: Bool
    """Whether the file was created. False both for an occupied destination
    and for a failure, which `failure` tells apart."""

    var failure: String
    """The diagnostic line, or empty when nothing failed."""


def _publish_file(
    absolute: String, label: String, content: List[UInt8]
) -> _Published:
    """Write `content` at `absolute`, never replacing what is already there.

    The file is written to a temporary name in the destination's own directory
    and published with a link, so an occupied destination is refused by the
    filesystem itself rather than by a check a concurrent creation could slip
    past.

    Args:
        absolute: The absolute path to create, with its parents made as needed.
        label: The escaped path the diagnostic names. Not used to open
            anything.
        content: The file's complete bytes, written verbatim.

    Returns:
        Whether the file was created, and the diagnostic line when the
        publication failed outright. Allocates the transient temporary path.
    """
    var directory = String(dirname(absolute))
    var temp = String("")
    var owned_fd = -1
    try:
        makedirs(directory, exist_ok=True)
        # The temporary shares the destination's directory so the publishing
        # link cannot straddle filesystems, and it is hidden so a walk
        # interrupted between the write and the link never collects a
        # half-written file.
        var created = create_unique_temp(
            directory + "/.mtest-new." + String(process_id()) + ".XXXXXX"
        )
        temp = created.path.copy()
        owned_fd = created.fd
        write_all_bytes_fd(owned_fd, Span(content))
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
            return _Published(False, String(""))
    except e:
        _discard(owned_fd, temp)
        # The cause is escaped too. It carries paths this function did not
        # compose — the temporary's, and whatever the platform layer quoted —
        # so leaving it raw would defeat the escaping applied to `label`.
        return _Published(
            False,
            "scaffold: could not create '"
            + label
            + "': "
            + safe_path_label(String(e)),
        )
    return _Published(True, String(""))


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
    var published = _publish_file(
        absolute, label, _file_bytes(render_test_file(_stem(name)))
    )
    if published.failure != "":
        return _report(published.failure, _EXIT_IO_FAILURE)
    if not published.created:
        return _report(
            "scaffold: refusing to overwrite " + label, _EXIT_REFUSED
        )
    # Escaped, so a path carrying control bytes cannot write them to the
    # terminal — but NOT the bounded label: this line's format is frozen, and
    # a long path truncated to `created dddd...` would name a file that does
    # not exist.
    return _report("created " + escape_control_characters(target), 0)


def _replace_file(path: String, content: List[UInt8], mode: Int) raises:
    """Replace `path` with `content` in one indivisible step.

    The counterpart to `_publish_file`, and the only place this module writes
    over something it did not create. `rename(2)` is what makes the swap
    all-or-nothing: a reader of `path` sees either the whole old file or the
    whole new one, never a truncated middle, and an interrupted run leaves the
    original intact.

    Args:
        path: The existing file to replace.
        content: The complete new bytes, which callers derive from what they
            read out of `path`. Written verbatim, never decoded.
        mode: The permission bits to give the replacement, so a file the user
            had restricted does not come back world-readable.

    Raises:
        Error: If the temporary could not be created, written, closed,
            re-permissioned, or renamed. The temporary is removed on every one
            of those paths, and `path` is left exactly as it was.
    """
    var temp = String("")
    var owned_fd = -1
    try:
        var created = create_unique_temp(
            String(dirname(path))
            + "/.mtest-init."
            + String(process_id())
            + ".XXXXXX"
        )
        temp = created.path.copy()
        owned_fd = created.fd
        write_all_bytes_fd(owned_fd, Span(content))
        var closing_fd = owned_fd
        owned_fd = -1
        close_checked_fd(closing_fd)
        set_permissions(temp, mode)
        rename_path(temp, path)
    except e:
        _discard(owned_fd, temp)
        raise e^


def _artifact_line(relative: String, created: Bool) -> String:
    """The status line for one artifact `init` published or found in place."""
    if created:
        return "created " + relative
    return "skipped " + relative + " (exists)"


def _unusable_name(relative: String, facts: PathFacts) -> String:
    """The refusal for an artifact name taken by something unwritable.

    Args:
        relative: The artifact's path as the report names it.
        facts: What that name was observed to be.

    Returns:
        The refusal line, or empty when the name is free or already holds an
        ordinary file this may publish onto or rewrite.
    """
    if not facts.present or facts.is_regular:
        return String("")
    return (
        "scaffold: refusing to write '"
        + relative
        + "': the name is taken by a symlink or something that is not a"
        " regular file"
    )


def _ensure_cache_ignored(path: String, observed: PathFacts) raises -> String:
    """Make sure `.gitignore` leaves the build cache untracked, and say how.

    The one artifact that may be edited rather than only created, so it is the
    one whose "already there" answer is not the filesystem's to give: a
    `.gitignore` that exists without the entry still has to gain it.

    Args:
        path: The `.gitignore` to create or amend.
        observed: What `path` was before the artifacts were published. A
            publication that finds the name taken re-observes it rather than
            trusting this, because the file may have appeared in between and a
            file that appeared still has to end up carrying the entry.

    Returns:
        The status line: `created`, `updated`, or `skipped` — and `skipped`
        means the cache is genuinely ignored, never merely that a file exists.

    Raises:
        Error: If the file could not be created, read, or replaced, if it is
            larger than the rewrite ceiling, or if the name is taken by
            something that is not a regular file.
    """
    var facts = observed.copy()
    if not facts.present:
        var fresh = _publish_file(
            path, ".gitignore", gitignore_update(List[UInt8](), False).value()
        )
        if fresh.failure != "":
            raise Error(fresh.failure)
        if fresh.created:
            return String("created .gitignore")
        # Something created `.gitignore` between the observation and the
        # publication. The link refused, correctly — and the winner still has
        # to carry the entry, so the update path takes over from here.
        facts = observe_path(path)
        if not facts.present or not facts.is_regular:
            raise Error("'.gitignore' is not a regular file")
    # Raises on a file past the ceiling rather than handing back a truncated
    # prefix, which is what makes writing the result back safe.
    var existing = read_regular_file_bytes(path, _GITIGNORE_MAX_BYTES)
    var updated = gitignore_update(existing, True)
    if not updated:
        return String("skipped .gitignore (exists)")
    _replace_file(path, updated.value(), facts.mode)
    return String("updated .gitignore")


def run_init(root: String, ci: String) -> ScaffoldReport:
    """Bootstrap a project in `root`: a first test, a config, an ignore entry.

    Creates `tests/test_example.mojo` and `mtest.toml`, adds
    `.github/workflows/test.yml` under `--ci github`, and makes sure
    `.gitignore` leaves the build cache untracked. Every one of those is
    published without replacing anything, so a second run is an all-skip that
    still succeeds and a file someone has already edited is never touched.

    `.gitignore` is the exception, because adding a line to a file means
    rewriting it. It is read as bytes, appended to, and renamed over; the
    content written back is the content read plus the new lines, so the
    replacement can only add. A concurrent writer inside that window loses its
    update. That is accepted: this is a bootstrap command a person runs once,
    by hand.

    Every refusal — an unknown `--ci` provider, and any artifact name already
    taken by something that is not a regular file — is decided before the
    first artifact exists, so a refused `init` leaves the directory exactly as
    it found it.

    Args:
        root: The invocation root every artifact is written under.
        ci: The provider to write a workflow for: `github`, or empty for none.

    Returns:
        One line per artifact and the code to exit with: zero with the next
        steps appended, four for a refusal, three for an I/O failure. Allocates
        the rendered artifacts and the report.

    Examples:

    ```mojo
    from mtest.cli.scaffold import run_init

    var report = run_init("/tmp/project", "github")
    print(report.lines[0], report.code)
    ```
    """
    if ci != "" and ci != "github":
        return _report(
            "scaffold: '--ci' wants 'github', got '"
            + safe_path_label(ci)
            + "'",
            _EXIT_REFUSED,
        )

    var relatives: List[String] = [
        String("tests/test_example.mojo"),
        String("mtest.toml"),
    ]
    var contents: List[String] = [
        render_test_file("example"),
        render_mtest_toml(),
    ]
    if ci == "github":
        relatives.append(String(".github/workflows/test.yml"))
        contents.append(render_github_workflow())

    # Observed before anything is created, so a name this cannot publish onto
    # or rewrite is a refusal against an untouched directory rather than a
    # half-bootstrapped project. A symlink counts as unusable and is refused
    # rather than followed: publishing or replacing through one would write
    # into whatever it points at. A directory sitting where an artifact goes
    # is the same answer for the same reason — reporting it as `skipped` would
    # claim a file exists that does not.
    var gitignore = root + "/.gitignore"
    var observed_ignore = observe_path(gitignore)
    var refusal = _unusable_name(".gitignore", observed_ignore)
    if refusal != "":
        return _report(refusal, _EXIT_REFUSED)
    for relative in relatives:
        var blocked = _unusable_name(
            relative, observe_path(root + "/" + relative)
        )
        if blocked != "":
            return _report(blocked, _EXIT_REFUSED)

    var lines = List[String]()
    for index in range(len(relatives)):
        var relative = relatives[index]
        var published = _publish_file(
            root + "/" + relative, relative, _file_bytes(contents[index])
        )
        if published.failure != "":
            lines.append(published.failure)
            return ScaffoldReport(lines^, _EXIT_IO_FAILURE)
        lines.append(_artifact_line(relative, published.created))

    try:
        lines.append(_ensure_cache_ignored(gitignore, observed_ignore))
    except e:
        lines.append(
            "scaffold: could not update '.gitignore': "
            + safe_path_label(String(e))
        )
        return ScaffoldReport(lines^, _EXIT_IO_FAILURE)

    # Not decoration. Every one of these is load-bearing: the workspace has to
    # exist before a channel can be added to it, the package has to be in the
    # workspace before `mtest` resolves at all, and the workflow just written
    # installs from the lock file, which only exists once `pixi add` has run.
    lines.append("next: pixi init .")
    lines.append(
        "next: pixi workspace channel add https://conda.modular.com/max/"
    )
    lines.append(
        "next: pixi workspace channel add"
        " https://repo.prefix.dev/modular-community"
    )
    lines.append("next: pixi add mtest")
    lines.append("next: mtest")
    if ci == "github":
        lines.append(
            "next: commit pixi.toml and pixi.lock, which the workflow installs"
            " from"
        )
    return ScaffoldReport(lines^, 0)
