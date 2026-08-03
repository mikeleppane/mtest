"""Bootstrapping a project, and the one file `init` is allowed to edit.

Three invariants carry this module. Every artifact goes through the same
no-replace publication `mtest new` uses, so a second `init` is an all-skip that
still succeeds. `.gitignore` is the exception and is therefore the only place a
lost update is possible at all, which is why its three-way decision is tested
as a pure function before any file is involved. And the refusals — an unknown
`--ci` value, a `.gitignore` that is not a regular file — are decided before
the first artifact is created, so a refused `init` leaves the directory exactly
as it found it.
"""
from std.os import listdir, makedirs, mkdir, stat, symlink
from std.memory import Span
from std.os.path import dirname, exists
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)

from mtest.cli import parse_args
from mtest.platform import (
    PathFacts,
    close_checked_fd,
    create_unique_temp,
    read_regular_file_bytes,
    rename_path,
    set_permissions,
    write_all_bytes_fd,
)
from mtest.cli.scaffold import (
    _ensure_cache_ignored,
    gitignore_update,
    render_github_workflow,
    render_mtest_toml,
    render_test_file,
    run_init,
)

from tmptree import remove_tree, temp_root


def _read(path: String) raises -> String:
    with open(path, "r") as source:
        return source.read()


def _write(path: String, text: String) raises:
    with open(path, "w") as destination:
        destination.write(text)


def _joined(lines: List[String]) -> String:
    var out = String("")
    for line in lines:
        out += line + "\n"
    return out^


comptime _NEXT_LINES = String(
    "next: pixi init .\n",
    "next: pixi workspace channel add https://conda.modular.com/max/\n",
    (
        "next: pixi workspace channel add"
        " https://repo.prefix.dev/modular-community\n"
    ),
    "next: pixi add mtest\n",
    "next: mtest\n",
)

comptime _COMMIT_LINE = (
    "next: commit pixi.toml and pixi.lock, which the workflow installs from\n"
)
"""Emitted under `--ci github` alone: only the workflow installs from a lock."""


def _bytes(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    for byte in text.as_bytes():
        out.append(byte)
    return out^


def _write_bytes(path: String, data: List[UInt8]) raises:
    """Write `data` at `path` verbatim; `open` has no binary mode here."""
    var created = create_unique_temp(String(dirname(path)) + "/probe.XXXXXX")
    write_all_bytes_fd(created.fd, Span(data))
    close_checked_fd(created.fd)
    rename_path(created.path, path)


def _text(data: List[UInt8]) -> String:
    var out = String("")
    for byte in data:
        out += String(chr(Int(byte)))
    return out^


def test_mtest_toml_bytes_are_exact() raises:
    assert_equal(render_mtest_toml(), '[run]\npaths = ["tests"]\n')


def test_workflow_pins_every_action_to_a_commit() raises:
    # Byte parity with `docs/ci.md` is asserted by the contract gate, which
    # extracts the fence at check time. What matters here is the property that
    # makes the rendered workflow safe to paste: no floating tag anywhere.
    var rendered = render_github_workflow()
    assert_true(rendered.startswith("name: Tests\n"))
    assert_true(rendered.endswith("path: build/test-results.xml\n"))
    assert_true("pixi run mtest tests" in rendered)
    for line in rendered.splitlines():
        var text = String(line)
        if "uses:" in text:
            var reference = String(text.split("@", 1)[1])
            var digest = String(reference.split(" ", 1)[0])
            assert_equal(digest.byte_length(), 40, "not a commit sha: " + text)


def test_gitignore_update_writes_a_whole_file_when_absent() raises:
    var written = gitignore_update(List[UInt8](), False)
    assert_true(Bool(written))
    assert_true(_text(written.value()).endswith(".mtest-cache/\n"))
    assert_true(_text(written.value()).startswith("#"))


def test_gitignore_update_leaves_an_existing_entry_alone() raises:
    assert_false(
        Bool(gitignore_update(_bytes("build/\n.mtest-cache/\n"), True))
    )
    # The other spellings of the same ignore, all of which already do the job:
    # appending a fourth would be noise in someone else's file. Trailing
    # whitespace goes with them, because git strips it from a pattern.
    assert_false(Bool(gitignore_update(_bytes(".mtest-cache\n"), True)))
    assert_false(Bool(gitignore_update(_bytes("/.mtest-cache/\n"), True)))
    assert_false(Bool(gitignore_update(_bytes(".mtest-cache/  \n"), True)))
    assert_false(Bool(gitignore_update(_bytes(".mtest-cache/\r\n"), True)))


def test_gitignore_update_treats_leading_whitespace_as_git_does() raises:
    # `git check-ignore --no-index .mtest-cache/probe` exits 1 against this
    # file: leading whitespace is part of the pattern, so the line names a
    # directory whose name starts with two spaces and ignores nothing.
    var indented = gitignore_update(_bytes("  .mtest-cache/\n"), True)
    assert_true(Bool(indented))
    assert_true(_text(indented.value()).endswith(".mtest-cache/\n"))


def test_gitignore_update_ignores_a_comment() raises:
    # A commented-out entry ignores nothing.
    assert_true(Bool(gitignore_update(_bytes("# .mtest-cache/\n"), True)))


def test_gitignore_update_follows_the_last_matching_pattern() raises:
    # Git's rule, not a first-hit scan: a later negation puts the directory
    # back, so a run reporting `skipped` there would leave a project whose
    # cache git still tracks.
    assert_true(Bool(gitignore_update(_bytes("!.mtest-cache/\n"), True)))
    assert_true(
        Bool(gitignore_update(_bytes(".mtest-cache/\n!.mtest-cache/\n"), True))
    )
    # ... and a positive pattern after the negation wins in turn.
    assert_false(
        Bool(gitignore_update(_bytes("!.mtest-cache/\n.mtest-cache/\n"), True))
    )


def test_gitignore_update_preserves_the_original_bytes() raises:
    var updated = gitignore_update(_bytes("build/\n*.mojopkg\n"), True)
    assert_true(Bool(updated))
    assert_true(_text(updated.value()).startswith("build/\n*.mojopkg\n"))
    assert_true(_text(updated.value()).endswith(".mtest-cache/\n"))


def test_gitignore_update_carries_bytes_that_are_not_utf8() raises:
    # Git accepts a `.gitignore` that is not valid UTF-8, so decoding one in
    # order to write it back would turn a legal file into a failed bootstrap.
    var existing: List[UInt8] = [UInt8(ord("m")), UInt8(0xFF), UInt8(0x0A)]
    var updated = gitignore_update(existing, True)
    assert_true(Bool(updated))
    assert_equal(updated.value()[0], UInt8(ord("m")))
    assert_equal(updated.value()[1], UInt8(0xFF))
    assert_equal(updated.value()[2], UInt8(0x0A))


def test_gitignore_update_terminates_an_unterminated_last_line() raises:
    # Without the newline the entry would be glued onto the last pattern and
    # would silently change what that pattern matches.
    var updated = gitignore_update(_bytes("build/"), True)
    assert_true(Bool(updated))
    assert_true(_text(updated.value()).startswith("build/\n"))
    assert_true(_text(updated.value()).endswith(".mtest-cache/\n"))


def test_init_creates_every_artifact_and_names_the_next_steps() raises:
    var root = temp_root()
    try:
        var report = run_init(root, "")
        assert_equal(report.code, 0)
        assert_equal(
            _joined(report.lines),
            String(
                "created tests/test_example.mojo\n",
                "created mtest.toml\n",
                "created .gitignore\n",
                _NEXT_LINES,
            ),
        )
        assert_equal(
            _read(root + "/tests/test_example.mojo"),
            render_test_file("example"),
        )
        assert_equal(_read(root + "/mtest.toml"), render_mtest_toml())
        assert_true(".mtest-cache/" in _read(root + "/.gitignore"))
        # Without `--ci` no workflow is written at all.
        assert_false(exists(root + "/.github"))
    finally:
        remove_tree(root)


def test_init_is_idempotent() raises:
    var root = temp_root()
    try:
        _ = run_init(root, "github")
        var second = run_init(root, "github")
        assert_equal(second.code, 0)
        assert_equal(
            _joined(second.lines),
            String(
                "skipped tests/test_example.mojo (exists)\n",
                "skipped mtest.toml (exists)\n",
                "skipped .github/workflows/test.yml (exists)\n",
                "skipped .gitignore (exists)\n",
                _NEXT_LINES,
                _COMMIT_LINE,
            ),
        )
    finally:
        remove_tree(root)


def test_init_ci_github_writes_the_documented_workflow() raises:
    var root = temp_root()
    try:
        var report = run_init(root, "github")
        assert_equal(report.code, 0)
        assert_equal(
            _joined(report.lines),
            String(
                "created tests/test_example.mojo\n",
                "created mtest.toml\n",
                "created .github/workflows/test.yml\n",
                "created .gitignore\n",
                _NEXT_LINES,
                _COMMIT_LINE,
            ),
        )
        assert_equal(
            _read(root + "/.github/workflows/test.yml"),
            render_github_workflow(),
        )
    finally:
        remove_tree(root)


def test_init_refuses_an_unknown_ci_provider() raises:
    var root = temp_root()
    try:
        var report = run_init(root, "gitlab")
        assert_equal(report.code, 4)
        assert_equal(len(report.lines), 1)
        assert_true("'--ci' wants 'github', got 'gitlab'" in report.lines[0])
        # Refused before the first artifact, so nothing was created.
        assert_equal(len(listdir(root)), 0)
    finally:
        remove_tree(root)


def test_init_never_replaces_a_hand_written_artifact() raises:
    var root = temp_root()
    try:
        makedirs(root + "/tests")
        _write(root + "/tests/test_example.mojo", "# mine, and irreplaceable\n")
        var report = run_init(root, "")
        assert_equal(report.code, 0)
        assert_equal(
            report.lines[0], "skipped tests/test_example.mojo (exists)"
        )
        assert_equal(
            _read(root + "/tests/test_example.mojo"),
            "# mine, and irreplaceable\n",
        )
    finally:
        remove_tree(root)


def test_init_appends_to_an_existing_gitignore() raises:
    var root = temp_root()
    try:
        _write(root + "/.gitignore", "build/\n")
        var report = run_init(root, "")
        assert_equal(report.code, 0)
        assert_equal(report.lines[2], "updated .gitignore")
        var written = _read(root + "/.gitignore")
        assert_true(written.startswith("build/\n"))
        assert_true(written.endswith(".mtest-cache/\n"))
    finally:
        remove_tree(root)


def test_init_leaves_a_gitignore_that_already_ignores_the_cache() raises:
    var root = temp_root()
    try:
        _write(root + "/.gitignore", "build/\n.mtest-cache/\n")
        var report = run_init(root, "")
        assert_equal(report.code, 0)
        assert_equal(report.lines[2], "skipped .gitignore (exists)")
        assert_equal(_read(root + "/.gitignore"), "build/\n.mtest-cache/\n")
    finally:
        remove_tree(root)


def test_init_preserves_the_gitignore_permission_bits() raises:
    var root = temp_root()
    try:
        _write(root + "/.gitignore", "build/\n")
        set_permissions(root + "/.gitignore", 0o600)
        var report = run_init(root, "")
        assert_equal(report.code, 0)
        assert_equal(report.lines[2], "updated .gitignore")
        # The rewrite goes through a temporary, which `mkstemp` creates 0600
        # and every other file would be given the umask-derived mode. Neither
        # is the user's answer, so the file's own bits are put back.
        var mode = Int(stat(root + "/.gitignore").st_mode) & 0o777
        assert_equal(mode, 0o600)
    finally:
        remove_tree(root)


def test_init_reports_an_unusable_parent_as_an_io_failure() raises:
    var root = temp_root()
    try:
        # A regular file where the first artifact needs a directory: not a
        # refusal the user can retype their way out of, so it is code 3, and
        # the run stops at the artifact that failed.
        _write(root + "/tests", "not a directory")
        var report = run_init(root, "")
        assert_equal(report.code, 3)
        assert_equal(len(report.lines), 1)
        assert_true(
            report.lines[0].startswith(
                "scaffold: could not create 'tests/test_example.mojo': "
            ),
            "not the create-failure line: " + report.lines[0],
        )
        assert_false(exists(root + "/mtest.toml"))
    finally:
        remove_tree(root)


def test_init_keeps_a_gitignore_that_is_not_valid_utf8() raises:
    var root = temp_root()
    try:
        # Git accepts these bytes, and this file already ignores the cache, so
        # the only correct answer is to leave it exactly alone.
        _write_bytes(
            root + "/.gitignore",
            _bytes("mine:") + [UInt8(0xFF)] + _bytes("\n.mtest-cache/\n"),
        )
        var report = run_init(root, "")
        assert_equal(report.code, 0)
        assert_equal(report.lines[2], "skipped .gitignore (exists)")
    finally:
        remove_tree(root)


def test_init_appends_to_a_gitignore_that_is_not_valid_utf8() raises:
    var root = temp_root()
    try:
        _write_bytes(
            root + "/.gitignore", _bytes("mine:") + [UInt8(0xFF), UInt8(0x0A)]
        )
        var report = run_init(root, "")
        assert_equal(report.code, 0)
        assert_equal(report.lines[2], "updated .gitignore")
        var written = read_regular_file_bytes(root + "/.gitignore", 1 << 20)
        assert_equal(written[5], UInt8(0xFF))
        assert_true(_text(written).endswith(".mtest-cache/\n"))
    finally:
        remove_tree(root)


def test_init_refuses_a_directory_where_an_artifact_goes() raises:
    var root = temp_root()
    try:
        makedirs(root + "/.github/workflows/test.yml")
        var report = run_init(root, "github")
        assert_equal(report.code, 4)
        assert_equal(len(report.lines), 1)
        assert_true(".github/workflows/test.yml" in report.lines[0])
        # A directory in the way is a refusal, not a skip: reporting `skipped`
        # would claim a workflow exists that does not.
        assert_false(exists(root + "/mtest.toml"))
    finally:
        remove_tree(root)


def test_init_refuses_a_symlinked_gitignore_before_creating_anything() raises:
    var root = temp_root()
    try:
        _write(root + "/real-ignore", "build/\n")
        symlink(root + "/real-ignore", root + "/.gitignore")
        var report = run_init(root, "")
        assert_equal(report.code, 4)
        assert_equal(len(report.lines), 1)
        assert_true(".gitignore" in report.lines[0])
        # `init` replaces this one file, so following a link would write
        # through it. Refused, and refused before any artifact exists.
        assert_false(exists(root + "/mtest.toml"))
        assert_false(exists(root + "/tests"))
        assert_equal(_read(root + "/real-ignore"), "build/\n")
    finally:
        remove_tree(root)


def test_init_refuses_a_gitignore_that_is_not_a_regular_file() raises:
    var root = temp_root()
    try:
        mkdir(root + "/.gitignore", 0o700)
        var report = run_init(root, "")
        assert_equal(report.code, 4)
        assert_equal(len(report.lines), 1)
        assert_true(".gitignore" in report.lines[0])
        assert_false(exists(root + "/mtest.toml"))
    finally:
        remove_tree(root)


def test_a_raced_gitignore_still_gains_the_entry() raises:
    # The one state the public entry point cannot be steered into on purpose:
    # `.gitignore` did not exist when `init` observed the directory and does
    # exist by the time it publishes. The publication refuses, correctly — and
    # the file that won the race still has to end up carrying the entry, so
    # reporting `skipped` there would leave a project whose cache git tracks.
    var root = temp_root()
    try:
        _write(root + "/.gitignore", "CONCURRENT\n")
        var absent = PathFacts(False, False, 0)
        assert_equal(
            _ensure_cache_ignored(root + "/.gitignore", absent),
            "updated .gitignore",
        )
        var written = _read(root + "/.gitignore")
        assert_true(written.startswith("CONCURRENT\n"))
        assert_true(written.endswith(".mtest-cache/\n"))
    finally:
        remove_tree(root)


def test_a_raced_gitignore_that_is_not_a_file_is_an_io_failure() raises:
    var root = temp_root()
    try:
        mkdir(root + "/.gitignore", 0o700)
        var absent = PathFacts(False, False, 0)
        with assert_raises(contains="not a regular file"):
            _ = _ensure_cache_ignored(root + "/.gitignore", absent)
    finally:
        remove_tree(root)


def test_init_parses_without_a_ci_provider() raises:
    var result = parse_args(["init"])
    assert_true(result.is_init())
    assert_equal(result.ci, "")


def test_init_parses_both_ci_spellings() raises:
    var spaced = parse_args(["init", "--ci", "github"])
    assert_true(spaced.is_init())
    assert_equal(spaced.ci, "github")
    var inline = parse_args(["init", "--ci=github"])
    assert_true(inline.is_init())
    assert_equal(inline.ci, "github")


def test_init_refuses_an_operand() raises:
    with assert_raises(contains="'init' takes no PATH"):
        _ = parse_args(["init", "tests"])


def test_init_refuses_every_other_flag() raises:
    with assert_raises(contains="cannot be combined with 'init'"):
        _ = parse_args(["init", "-q"])
    with assert_raises(contains="cannot be combined with 'init'"):
        _ = parse_args(["init", "--no-config"])


def test_init_ci_requires_a_value() raises:
    with assert_raises(contains="'--ci' requires"):
        _ = parse_args(["init", "--ci"])
    with assert_raises(contains="'--ci' requires"):
        _ = parse_args(["init", "--ci="])


def test_init_help_is_the_help_directive() raises:
    var result = parse_args(["init", "--help"])
    assert_true(result.is_help())


def test_ci_is_not_a_run_flag() raises:
    # Deliberately absent from the global flag table: a `--ci` row there would
    # make `mtest --ci github tests` parse as a run whose value nothing reads.
    with assert_raises(contains="--ci"):
        _ = parse_args(["--ci", "github", "tests"])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
