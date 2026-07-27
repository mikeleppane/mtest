"""Tests for the Layer 1 config module: `RunnerConfig` defaults and the pure
mojo-path resolution helper.

`RunnerConfig` is data plus a couple of pure helpers — no parsing, no I/O. This
file asserts two things exhaustively: every field of a freshly-built config
sits at its contract default, and `resolve_mojo_path` implements the
flag > MTEST_MOJO env > "mojo" precedence for all four presence combinations.

It also holds the hostile-token quoting tables. `shell_quote` is the runner's
only quoting implementation and every reproduce line — the console's, and the
one `build_flags_string` composes — inherits its safe-character set, so the
three tables here pin one shell metacharacter set end to end. The expected
values are exact POSIX single-token strings compared as data: nothing here
executes a shell, because doing so would turn a quoting assertion into a
shell-behavior assertion and would run the very tokens the set neutralizes.
The newline and tab rows record today's raw representation, in which the quoted
token still carries a literal newline or tab and so still spans physical lines.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.cli import build_flags_string
from mtest.config import (
    AnnotationsMode,
    ColorWhen,
    Precompile,
    RunnerConfig,
    ShowOutput,
    Verbosity,
    annotations_resolved_on,
    resolve_mojo_path,
    shell_join,
    shell_quote,
)


def test_default_gh_annotations_is_auto() raises:
    var c = RunnerConfig.default()
    assert_true(c.gh_annotations == AnnotationsMode.AUTO)


def test_annotations_off_never_renders() raises:
    assert_false(annotations_resolved_on(AnnotationsMode.OFF, True))
    assert_false(annotations_resolved_on(AnnotationsMode.OFF, False))


def test_annotations_on_always_renders() raises:
    assert_true(annotations_resolved_on(AnnotationsMode.ON, True))
    assert_true(annotations_resolved_on(AnnotationsMode.ON, False))


def test_annotations_auto_follows_github_actions() raises:
    assert_true(annotations_resolved_on(AnnotationsMode.AUTO, True))
    assert_false(annotations_resolved_on(AnnotationsMode.AUTO, False))


def test_default_paths_is_empty() raises:
    var c = RunnerConfig.default()
    assert_equal(len(c.paths), 0)


def test_default_excludes_is_empty() raises:
    var c = RunnerConfig.default()
    assert_equal(len(c.excludes), 0)


def test_default_gates_is_empty() raises:
    var c = RunnerConfig.default()
    assert_equal(len(c.gates), 0)


def test_default_precompiles_is_empty() raises:
    var c = RunnerConfig.default()
    assert_equal(len(c.precompiles), 0)


def test_default_build_args_is_empty() raises:
    var c = RunnerConfig.default()
    assert_equal(len(c.build_args), 0)


def test_default_include_paths_is_empty() raises:
    var c = RunnerConfig.default()
    assert_equal(len(c.include_paths), 0)


def test_default_mojo_path_is_mojo() raises:
    var c = RunnerConfig.default()
    assert_equal(c.mojo_path, "mojo")


def test_default_timeout_secs_is_300() raises:
    var c = RunnerConfig.default()
    assert_equal(c.timeout_secs, 300)


def test_default_show_output_is_failures() raises:
    var c = RunnerConfig.default()
    assert_true(c.show_output == ShowOutput.FAILURES)


def test_default_verbosity_is_normal() raises:
    var c = RunnerConfig.default()
    assert_true(c.verbosity == Verbosity.NORMAL)


def test_default_color_is_auto() raises:
    var c = RunnerConfig.default()
    assert_true(c.color == ColorWhen.AUTO)


def test_default_exitfirst_is_false() raises:
    var c = RunnerConfig.default()
    assert_equal(c.exitfirst, False)


def test_precompile_holds_src_and_optional_out() raises:
    var with_out = Precompile(src="a.mojo", out=Optional[String]("a_out"))
    assert_equal(with_out.src, "a.mojo")
    assert_true(with_out.out)
    assert_equal(with_out.out.value(), "a_out")

    var without_out = Precompile(src="b.mojo", out=Optional[String](None))
    assert_equal(without_out.src, "b.mojo")
    assert_true(not without_out.out)


def test_resolve_mojo_path_flag_and_env_present_prefers_flag() raises:
    var got = resolve_mojo_path(
        Optional[String]("/flag/mojo"), Optional[String]("/env/mojo")
    )
    assert_equal(got, "/flag/mojo")


def test_resolve_mojo_path_flag_only() raises:
    var got = resolve_mojo_path(
        Optional[String]("/flag/mojo"), Optional[String](None)
    )
    assert_equal(got, "/flag/mojo")


def test_resolve_mojo_path_env_only() raises:
    var got = resolve_mojo_path(
        Optional[String](None), Optional[String]("/env/mojo")
    )
    assert_equal(got, "/env/mojo")


def test_resolve_mojo_path_neither_falls_back_to_mojo() raises:
    var got = resolve_mojo_path(Optional[String](None), Optional[String](None))
    assert_equal(got, "mojo")


def test_shell_quote_empty_becomes_two_single_quotes() raises:
    assert_equal(shell_quote(""), "''")


def test_shell_quote_safe_token_passes_through_unchanged() raises:
    assert_equal(shell_quote("tests/test_a.mojo"), "tests/test_a.mojo")


def test_shell_quote_space_containing_token_is_single_quoted() raises:
    assert_equal(shell_quote("my dir"), "'my dir'")


def test_shell_quote_embedded_single_quote_is_escaped() raises:
    assert_equal(shell_quote("it's"), "'it'\\''s'")


def test_shell_join_empty_list_is_empty_string() raises:
    assert_equal(shell_join(List[String]()), "")


def test_shell_join_quotes_each_token_and_space_joins() raises:
    var tokens: List[String] = ["mojo", "build", "-I", "my dir"]
    assert_equal(shell_join(tokens), "mojo build -I 'my dir'")


def _hostile_tokens() -> List[String]:
    """The hostile quoting corpus, in the fixed order the tables use.

    Returns:
        One token per shell hazard: word splitting, quote breakout, command
        substitution, parameter expansion, command separation, globbing,
        escaping, the three control characters a terminal reacts to, a
        multi-byte scalar, and the empty token.
    """
    return [
        "plain",
        "space here",
        "single'quote",
        "$(touch pwned)",
        "`cmd`",
        "$HOME",
        "semi;colon",
        "star*glob",
        "question?glob",
        "bracket[abc]",
        "back\\slash",
        "line\nbreak",
        "tab\tvalue",
        "escape-\x1b",
        "nul-\x00",
        "snowman-☃",
        "",
    ]


def _assert_quote(token: String, expected: String, label: String) raises:
    """Assert `shell_quote(token)` is byte-for-byte `expected`.

    The comparison is pure data. No shell is spawned, so a token carrying a
    command substitution can never run while being checked.

    Args:
        token: The raw token one table row feeds to the quoter.
        expected: The complete POSIX single-token string the row must produce.
        label: The row name, surfaced when the row drifts.

    Raises:
        Error: The quoted token differed from `expected`.
    """
    assert_equal(shell_quote(token), expected, label)


def test_shell_quote_neutralizes_every_hostile_token() raises:
    _assert_quote("plain", "plain", "safe token passes through")
    _assert_quote("space here", "'space here'", "word splitting")
    _assert_quote("single'quote", "'single'\\''quote'", "quote breakout")
    _assert_quote("$(touch pwned)", "'$(touch pwned)'", "command substitution")
    _assert_quote("`cmd`", "'`cmd`'", "backtick substitution")
    _assert_quote("$HOME", "'$HOME'", "parameter expansion")
    _assert_quote("semi;colon", "'semi;colon'", "command separator")
    _assert_quote("star*glob", "'star*glob'", "star glob")
    _assert_quote("question?glob", "'question?glob'", "question glob")
    _assert_quote("bracket[abc]", "'bracket[abc]'", "bracket glob")
    _assert_quote("back\\slash", "'back\\slash'", "backslash escape")
    # Single quotes are literal in POSIX sh, so the newline, tab, ESC and NUL
    # all survive verbatim inside the quoted token today. The console gains a
    # separate display-only neutralization later; this is the raw baseline.
    _assert_quote("line\nbreak", "'line\nbreak'", "literal newline")
    _assert_quote("tab\tvalue", "'tab\tvalue'", "literal tab")
    _assert_quote("escape-\x1b", "'escape-\x1b'", "literal ESC")
    _assert_quote("nul-\x00", "'nul-\x00'", "literal NUL")
    _assert_quote("snowman-☃", "'snowman-☃'", "multi-byte scalar")
    _assert_quote("", "''", "empty token")


def test_shell_join_renders_the_whole_hostile_corpus() raises:
    assert_equal(
        shell_join(_hostile_tokens()),
        (
            "plain 'space here' 'single'\\''quote' '$(touch pwned)' '`cmd`'"
            " '$HOME' 'semi;colon' 'star*glob' 'question?glob' 'bracket[abc]'"
            " 'back\\slash' 'line\nbreak' 'tab\tvalue' 'escape-\x1b'"
            " 'nul-\x00' 'snowman-☃' ''"
        ),
    )


def test_shell_join_keeps_a_hostile_token_a_single_argv_word() raises:
    # Each hostile token stays one word: the only unquoted spaces are the
    # separators the join itself introduces.
    var tokens: List[String] = ["mojo", "build", "$(touch pwned)", "a b", ""]
    assert_equal(shell_join(tokens), "mojo build '$(touch pwned)' 'a b' ''")


def test_build_flags_string_quotes_every_hostile_value() raises:
    # The same corpus `_hostile_tokens` holds, spread across the four flag kinds
    # in the fixed order `build_flags_string` emits them. Every token that needs
    # the shell is quoted and `plain` is not, so this row also pins that the
    # inverse-parser neither under- nor over-quotes. The remaining three tokens
    # — the control characters and the quote breakout — are the next test.
    var c = RunnerConfig.default()
    c.mojo_path = "$(touch pwned)"
    c.include_paths = [
        "plain",
        "space here",
        "star*glob",
        "question?glob",
        "bracket[abc]",
        "back\\slash",
    ]
    c.build_args = ["$HOME", "line\nbreak", "tab\tvalue", ""]
    c.precompiles = [
        Precompile(src="semi;colon", out=Optional[String]("`cmd`")),
        Precompile(src="snowman-☃", out=Optional[String](None)),
    ]
    assert_equal(
        build_flags_string(c),
        (
            "--mojo '$(touch pwned)' -I plain -I 'space here' -I 'star*glob'"
            " -I 'question?glob' -I 'bracket[abc]' -I 'back\\slash'"
            " --build-arg '$HOME' --build-arg 'line\nbreak'"
            " --build-arg 'tab\tvalue' --build-arg ''"
            " --precompile 'semi;colon:`cmd`' --precompile 'snowman-☃'"
        ),
    )


def test_build_flags_string_quotes_control_characters_verbatim() raises:
    var c = RunnerConfig.default()
    c.build_args = ["escape-\x1b", "nul-\x00", "single'quote"]
    assert_equal(
        build_flags_string(c),
        (
            "--build-arg 'escape-\x1b' --build-arg 'nul-\x00'"
            " --build-arg 'single'\\''quote'"
        ),
    )


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
