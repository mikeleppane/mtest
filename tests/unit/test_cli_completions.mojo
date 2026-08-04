"""`mtest completions SHELL`: the grammar, and the three rendered scripts.

Two properties matter here and they pull in opposite directions. A script must
offer everything the parser accepts under the active command and nothing it
refuses, which is a bijection against `flag_specs()` and its applicability
mask; and a script is `eval`'d into someone's interactive shell, so every byte
that reaches it has to be inert in the position it lands in. The first is
checked by embedding the very strings the renderers build their word lists
from, the second by handing the escapers text no table contains today.
"""
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mtest.cli import (
    Subcommand,
    ValueKind,
    completion_shells,
    flag_specs,
    parse_args,
    render_completions,
    subcommand_specs,
)
from mtest.cli.completions import (
    _bash_word,
    _cmd_scoped_patterns,
    _fish_flag_token,
    _fish_quoted,
    _flags_for,
    _subcommand_words,
    _zsh_action_word,
    _zsh_description,
    _zsh_message,
    _zsh_specs_for,
    render_bash_completions,
    render_fish_completions,
    render_zsh_completions,
)


# --- helpers ---------------------------------------------------------------


def _has_word(list: String, word: String) -> Bool:
    """Whether `word` is a whole space-separated member of `list`."""
    for candidate in list.split(" "):
        if String(candidate) == word:
            return True
    return False


def _lines_containing(text: String, needle: String) -> List[String]:
    """Every line of `text` that contains `needle`, in order."""
    var found = List[String]()
    for line_slice in text.split("\n"):
        var line = String(line_slice)
        if needle in line:
            found.append(line^)
    return found^


def _head_bits() -> List[Int]:
    """Every flag-accepting head, as its applicability bit."""
    return [
        Subcommand.RUN,
        Subcommand.COLLECT,
        Subcommand.CONFIG_SHOW,
        Subcommand.DOCTOR,
        Subcommand.DEBUG,
    ]


def _all_scripts() raises -> List[String]:
    """The three rendered scripts, in `completion_shells()` order."""
    var scripts = List[String]()
    for shell in completion_shells():
        scripts.append(render_completions(shell))
    return scripts^


# --- the grammar -----------------------------------------------------------


def test_completions_renders_a_script_for_every_shell_it_names() raises:
    for shell in completion_shells():
        var argv: List[String] = ["completions", shell]
        var result = parse_args(argv)
        assert_true(
            result.is_completions(), "not a completions result: " + shell
        )
        assert_equal(result.shell, shell)


def test_completion_shells_are_exactly_bash_zsh_fish() raises:
    var shells = completion_shells()
    assert_equal(len(shells), 3)
    assert_equal(shells[0], "bash")
    assert_equal(shells[1], "zsh")
    assert_equal(shells[2], "fish")


def test_completions_without_a_shell_is_a_usage_error() raises:
    var argv: List[String] = ["completions"]
    var message = String("")
    try:
        _ = parse_args(argv)
    except e:
        message = String(e)
    assert_true("bash" in message, "unhelpful refusal: " + message)
    assert_true(message.startswith("cli: "), "not a usage error: " + message)


def test_completions_unknown_shell_is_a_usage_error() raises:
    var argv: List[String] = ["completions", "tcsh"]
    var message = String("")
    try:
        _ = parse_args(argv)
    except e:
        message = String(e)
    assert_true("tcsh" in message, "refusal hides the value: " + message)
    assert_true(message.startswith("cli: "), "not a usage error: " + message)


def test_completions_refuses_a_second_operand() raises:
    var argv: List[String] = ["completions", "bash", "zsh"]
    var refused = False
    try:
        _ = parse_args(argv)
    except:
        refused = True
    assert_true(refused, "a second shell operand was accepted")


def test_completions_accepts_both_help_spellings() raises:
    for spelling in ["-h", "--help"]:
        var argv: List[String] = ["completions", spelling]
        assert_true(parse_args(argv).is_help(), "help drift: " + spelling)


def test_completions_refuses_every_other_flag() raises:
    var argv: List[String] = ["completions", "bash", "-q"]
    var message = String("")
    try:
        _ = parse_args(argv)
    except e:
        message = String(e)
    assert_true("'-q'" in message, "refusal does not name the flag: " + message)


def test_completions_is_a_subcommand_only_as_the_leading_token() raises:
    """`mtest -q completions` is a run with a `completions` path operand."""
    var argv: List[String] = ["-q", "completions"]
    var result = parse_args(argv)
    assert_true(result.is_run(), "a trailing 'completions' took over the parse")
    assert_equal(len(result.config.paths), 1)
    assert_equal(result.config.paths[0], "completions")


def test_render_completions_refuses_a_shell_it_does_not_render() raises:
    var refused = False
    try:
        _ = render_completions("tcsh")
    except:
        refused = True
    assert_true(refused, "an unrenderable shell produced a script")


def test_completions_has_a_subcommand_row() raises:
    var found = False
    for spec in subcommand_specs():
        if spec.token == "completions":
            found = True
            assert_equal(spec.label_args, "SHELL")
    assert_true(found, "no Subcommands row for 'completions'")


# --- bijection: every spelling and every head reaches every script ---------


def test_every_script_is_nonempty_and_ends_in_a_newline() raises:
    for script in _all_scripts():
        assert_true(script.byte_length() > 0, "empty completion script")
        assert_true(script.endswith("\n"), "script does not end in a newline")


def test_bash_script_carries_its_frame() raises:
    var script = render_bash_completions()
    assert_true(script.startswith("_mtest_reply() {\n"))
    assert_true("complete -F _mtest_complete mtest\n" in script)


def test_zsh_script_carries_its_frame() raises:
    var script = render_zsh_completions()
    assert_true(script.startswith("#compdef mtest\n"))
    assert_true("compdef _mtest mtest" in script)


def test_fish_script_carries_its_frame() raises:
    var script = render_fish_completions()
    assert_true("complete -c mtest" in script)
    assert_true("function __mtest_head" in script)


def test_bash_embeds_every_command_scoped_flag_list() raises:
    var script = render_bash_completions()
    for bit in _head_bits():
        var words = _flags_for(bit)
        assert_true(words.byte_length() > 0, "empty flag list for a head")
        assert_true('-W "' + words in script, "flag list drift: " + words)


def test_every_spelling_is_offered_under_every_head_that_accepts_it() raises:
    var bits = _head_bits()
    var lists = List[String]()
    for bit in bits:
        lists.append(_flags_for(bit))
    for spec in flag_specs():
        for i in range(len(bits)):
            var offered = _has_word(lists[i], spec.spelling)
            assert_equal(
                offered,
                (spec.applicability & bits[i]) != 0,
                "offering drift: " + spec.spelling,
            )


def test_a_run_only_flag_is_absent_from_every_other_head_list() raises:
    """Negative scoping, against the very segments the script embeds."""
    for spelling in ["--retries", "--json", "--durations", "-s"]:
        assert_true(
            _has_word(_flags_for(Subcommand.RUN), spelling),
            "run list lost a run flag: " + spelling,
        )
        for bit in [Subcommand.COLLECT, Subcommand.DOCTOR, Subcommand.DEBUG]:
            assert_false(
                _has_word(_flags_for(bit), spelling),
                "run-only flag leaked into another head: " + spelling,
            )


def test_format_is_offered_under_collect_and_nowhere_else() raises:
    assert_true(_has_word(_flags_for(Subcommand.COLLECT), "--format"))
    assert_false(_has_word(_flags_for(Subcommand.RUN), "--format"))
    assert_false(_has_word(_flags_for(Subcommand.DOCTOR), "--format"))


def test_every_subcommand_token_is_offered_at_the_head_position() raises:
    var words = _subcommand_words()
    for spec in subcommand_specs():
        assert_true(
            _has_word(words, spec.token),
            "head token missing: " + spec.token,
        )
    assert_true('-W "' + words in render_bash_completions())


def test_zsh_scopes_its_specs_per_head() raises:
    var script = render_zsh_completions()
    for bit in _head_bits():
        var specs = _zsh_specs_for(bit)
        assert_true(specs.byte_length() > 0, "empty zsh spec block")
        assert_true(specs in script, "zsh spec block drift")
    assert_true("--retries[" in _zsh_specs_for(Subcommand.RUN))
    assert_false("--retries[" in _zsh_specs_for(Subcommand.DOCTOR))
    assert_false("--retries[" in _zsh_specs_for(Subcommand.COLLECT))


def test_zsh_names_every_spelling_once_per_accepting_head() raises:
    var bits = _head_bits()
    var blocks = List[String]()
    for bit in bits:
        blocks.append(_zsh_specs_for(bit))
    for spec in flag_specs():
        var needle = "'" + spec.spelling + "["
        if spec.repeatable:
            needle = "'*" + spec.spelling + "["
        for i in range(len(bits)):
            var accepted = (spec.applicability & bits[i]) != 0
            assert_equal(
                needle in blocks[i],
                accepted,
                "zsh spec scoping drift: " + spec.spelling,
            )


def test_fish_conditions_every_flag_line_on_an_accepting_head() raises:
    var script = render_fish_completions()
    for spec in flag_specs():
        var token = _fish_flag_token(spec.spelling)
        var lines = _lines_containing(script, " " + token + " ")
        assert_true(len(lines) > 0, "fish completion missing: " + spec.spelling)
        for line in lines:
            var scoped = False
            for bit in _head_bits():
                if (spec.applicability & bit) == 0:
                    continue
                if "__mtest_head_is " + _head_name(bit) in line:
                    scoped = True
            assert_true(
                scoped,
                "fish line offers a flag to a head that refuses it: " + line,
            )


def _head_name(bit: Int) -> String:
    """The script-side name of one applicability bit."""
    if bit == Subcommand.COLLECT:
        return "collect"
    if bit == Subcommand.CONFIG_SHOW:
        return "config-show"
    if bit == Subcommand.DOCTOR:
        return "doctor"
    if bit == Subcommand.DEBUG:
        return "debug"
    return "run"


# --- head resolution: the leading token, then the effective head -----------


def test_bash_resolves_the_head_from_the_leading_token_only() raises:
    var script = render_bash_completions()
    assert_true('case "${COMP_WORDS[1]-}" in' in script)
    assert_true('doctor) cmd="doctor" ;;' in script)
    assert_true("completions|help|init|new|version) " in script)


def test_bash_refines_a_run_head_to_collect_under_collect_only() raises:
    var script = render_bash_completions()
    var position = script.find('if [ "$cmd" = "run" ]; then')
    assert_true(position != -1, "no effective-head refinement")
    assert_true('"$word" = "--collect-only"' in script)


def test_every_script_refines_the_head_under_collect_only() raises:
    for script in _all_scripts():
        assert_true("--collect-only" in script, "no effective-head refinement")


def test_config_pending_completes_exactly_the_show_token() raises:
    var script = render_bash_completions()
    assert_true('config-pending) COMPREPLY=($(compgen -W "show"' in script)
    var zsh = render_zsh_completions()
    assert_true("config-pending" in zsh)


def test_value_arms_are_keyed_on_command_and_flag() raises:
    var script = render_bash_completions()
    assert_true('"run:--report-style"' in script)
    assert_false("doctor:--report-style" in script)
    assert_true('"doctor:--color"' in script)
    assert_true('"collect:--format"' in script)
    assert_false("run:--format" in script)


def test_arity_zero_and_open_value_flags_get_no_value_arm() raises:
    for spec in flag_specs():
        var arms = _cmd_scoped_patterns(spec)
        if spec.arity == 0 or spec.value_kind == ValueKind.OTHER:
            assert_equal(arms, "", "value arm for " + spec.spelling)
        else:
            assert_true(arms != "", "no value arm for " + spec.spelling)


def test_every_closed_choice_reaches_every_script() raises:
    """Each script carries the choice in its own encoding, never a third one."""
    var bash = render_bash_completions()
    var zsh = render_zsh_completions()
    var fish = render_fish_completions()
    for spec in flag_specs():
        for choice in spec.choices:
            var word = String(choice)
            assert_true(word in bash, "bash lost a choice: " + spec.spelling)
            assert_true(
                _zsh_action_word(word) in zsh,
                "zsh lost a choice: " + spec.spelling,
            )
            assert_true(word in fish, "fish lost a choice: " + spec.spelling)


def test_the_prefix_choice_arm_completes_a_path_after_its_prefix() raises:
    var script = render_bash_completions()
    assert_true('if [[ "$cur" == *:* ]]; then' in script)
    assert_true('compgen -P "$pfx" -f -- "$rest"' in script)


# --- shell safety ----------------------------------------------------------


def test_file_completions_never_word_split_on_a_filename() raises:
    var script = render_bash_completions()
    for line in _lines_containing(script, "-f -- "):
        assert_true(
            "_mtest_reply < <(" in line,
            "file completion outside the quoted read loop: " + line,
        )
    assert_false("COMPREPLY=($(compgen -f" in script)


def test_bash_words_are_inert_inside_double_quotes() raises:
    assert_equal(_bash_word("--color"), "--color")
    assert_equal(_bash_word('a"b'), 'a\\"b')
    assert_equal(_bash_word("a$b"), "a\\$b")
    assert_equal(_bash_word("a`b"), "a\\`b")
    assert_equal(_bash_word("a\\b"), "a\\\\b")
    assert_equal(_bash_word("$(id)"), "\\$(id)")


def test_bash_case_patterns_are_literal() raises:
    """A spelling carrying a glob metacharacter may not become a pattern."""
    var script = render_bash_completions()
    for line in _lines_containing(script, ":--color"):
        assert_true('"run:--color"' in line, "unquoted case pattern: " + line)


def test_zsh_description_text_cannot_close_its_bracket() raises:
    assert_equal(_zsh_description("plain text"), "plain text")
    assert_equal(_zsh_description("a]b"), "a\\]b")
    assert_equal(_zsh_description("a[b"), "a\\[b")
    assert_equal(_zsh_description("a\\b"), "a\\\\b")


def test_zsh_message_and_action_fields_cannot_end_early() raises:
    assert_equal(_zsh_message("FORMAT:PATH"), "FORMAT\\:PATH")
    assert_equal(_zsh_message("a\\b"), "a\\\\b")
    assert_equal(_zsh_action_word("md:"), "md\\:")
    assert_equal(_zsh_action_word("a b"), "a\\ b")
    assert_equal(_zsh_action_word("a)b"), "a\\)b")
    assert_equal(_zsh_action_word("a(b"), "a\\(b")


def test_every_zsh_spec_is_single_quoted_safely() raises:
    assert_equal(_zsh_specs_for(Subcommand.RUN).find("'\\''"), -1)
    var script = render_zsh_completions()
    for line in _lines_containing(script, "_arguments"):
        var quotes = 0
        for cp in line.codepoints():
            if Int(cp) == 39:
                quotes += 1
        assert_equal(quotes % 2, 0, "unbalanced quoting: " + line)


def test_fish_quoting_escapes_the_two_bytes_that_matter() raises:
    assert_equal(_fish_quoted("plain"), "'plain'")
    assert_equal(_fish_quoted("a'b"), "'a\\'b'")
    assert_equal(_fish_quoted("a\\b"), "'a\\\\b'")


def test_fish_flag_tokens_split_short_from_long() raises:
    assert_equal(_fish_flag_token("-x"), "-s x")
    assert_equal(_fish_flag_token("-I"), "-s I")
    assert_equal(_fish_flag_token("--color"), "-l color")


def test_no_script_carries_an_unquoted_command_substitution() raises:
    """Nothing a table contributes may reach the shell as a command."""
    for script in _all_scripts():
        assert_false("$(id)" in script)
        assert_false("`id`" in script)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
