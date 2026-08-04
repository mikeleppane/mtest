"""`mtest completions SHELL`: the grammar, and the three rendered scripts.

Two properties matter here and they pull in opposite directions. A script must
offer everything the parser accepts under the active command and nothing it
refuses, which is a bijection against `flag_specs()` and its applicability
mask; and a script is `eval`'d into someone's interactive shell, so every byte
that reaches it has to be inert in the position it lands in. The first is
checked by embedding the very strings the renderers build their word lists
from, the second by handing the escapers text no table contains today.

Inertness is *modelled*, not asserted. Three of the positions a table value
lands in are expanded twice — the script's own quotes come off, and then
`compgen -W` or fish's `complete -a` expands what is left — so this module
carries small models of both passes (`_bash_double_quote_removal`,
`_fish_single_quote_removal`, `_backslash_removal`, `_live_metacharacters`) and
drives a hostile value through them, asserting both that nothing live survives
into the second pass and that the word arrives byte-identical. Asserting that
one level of escaping "looks right" is what let a defective barrier read as a
working one.

The `ValueKind` vocabulary is closed and gets its own guard, because the three
shells share no syntax for a value: each kind's rendering is stated once per
shell here, and a kind that reaches a `flag_specs()` row without those three
statements raises out of the suite rather than reaching a shell as a flag that
offers nothing.
"""
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mtest.cli import (
    FlagId,
    FlagSpec,
    Subcommand,
    ValueKind,
    completion_shells,
    flag_specs,
    parse_args,
    render_completions,
    subcommand_specs,
)
from mtest.cli.completions import (
    _bash_pattern,
    _bash_word,
    _bash_word_break_class,
    _completions_state,
    _fish_head_condition,
    _cmd_scoped_patterns,
    _compgen_wordlist,
    _fish_argument_list,
    _fish_expansion_word,
    _fish_flag_token,
    _fish_quoted,
    _flag_words_for,
    _flags_for,
    _head_state,
    _none_tokens,
    _spelling_of,
    _subcommand_words,
    _zsh_action_word,
    _zsh_description,
    _zsh_helper_name,
    _zsh_message,
    _zsh_quoted,
    _zsh_spec,
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


def _all_scripts() raises -> List[String]:
    """The three rendered scripts, in `completion_shells()` order."""
    var scripts = List[String]()
    for shell in completion_shells():
        scripts.append(render_completions(shell))
    return scripts^


def _hostile_values() -> List[String]:
    """Values no spec table holds today, each live in some shell position."""
    return [
        "$(touch OWNED)",
        "`touch OWNED`",
        "${IFS}",
        'a"b',
        "a'b",
        "a\\b",
        "a;touch OWNED",
        "a b",
        "a|b",
        "*",
        "a&b",
        "$HOME",
    ]


def _config_row_description() raises -> String:
    """The `config` Subcommands row's own help text, read from the table."""
    for spec in subcommand_specs():
        if spec.token == "config":
            return spec.description.copy()
    raise Error("the subcommand table has no 'config' row")


# --- models of the shell passes a value has to survive ---------------------


def _bash_double_quote_removal(source: String) -> String:
    """What bash hands a builtin after removing one level of double quoting.

    Inside double quotes a backslash keeps its meaning only before another
    backslash, a double quote, a dollar sign, or a backtick; anywhere else it
    is an ordinary character that survives.

    Args:
        source: The text as it appears between the script's double quotes.

    Returns:
        The freshly allocated argument text the builtin receives.
    """
    var out = String("")
    var pending = False
    for cp in source.codepoints():
        var code = Int(cp)
        if pending:
            if not (code == 92 or code == 34 or code == 36 or code == 96):
                out += "\\"
            out += String(cp)
            pending = False
            continue
        if code == 92:
            pending = True
            continue
        out += String(cp)
    if pending:
        out += "\\"
    return out^


def _fish_single_quote_removal(source: String) -> String:
    """What fish stores after removing one level of single quoting.

    Fish honors exactly two escapes inside single quotes; every other
    backslash is literal and survives into the expansion that follows.

    Args:
        source: The complete single-quoted literal, quotes included.

    Returns:
        The freshly allocated stored text.
    """
    var body = String(source[byte = 1 : source.byte_length() - 1])
    var out = String("")
    var pending = False
    for cp in body.codepoints():
        var code = Int(cp)
        if pending:
            if not (code == 92 or code == 39):
                out += "\\"
            out += String(cp)
            pending = False
            continue
        if code == 92:
            pending = True
            continue
        out += String(cp)
    if pending:
        out += "\\"
    return out^


def _backslash_removal(word: String) -> String:
    """What a word expansion leaves once its own backslashes are consumed."""
    var out = String("")
    var pending = False
    for cp in word.codepoints():
        if pending:
            out += String(cp)
            pending = False
            continue
        if Int(cp) == 92:
            pending = True
            continue
        out += String(cp)
    if pending:
        out += "\\"
    return out^


def _zsh_single_quote_removal(source: String) raises -> String:
    """What zsh stores after removing one level of single quoting.

    Nothing is escapable inside zsh single quotes: the only way to carry a
    quote is to close, escape one outside, and reopen, which is the `'\\''`
    sequence `_zsh_quoted` emits.

    Args:
        source: The complete single-quoted literal, quotes included.

    Returns:
        The freshly allocated stored text.

    Raises:
        Error: If `source` is not one well-formed single-quoted literal, which
            is itself the failure a hostile value would cause.
    """
    var body = String(source[byte = 1 : source.byte_length() - 1])
    var out = String("")
    var i = 0
    while i < body.byte_length():
        var rest = String(body[byte = i : body.byte_length()])
        if rest.startswith("'\\''"):
            out += "'"
            i += 4
            continue
        if rest.startswith("'"):
            raise Error("the quote closes early at byte " + String(i))
        out += String(body[byte = i : i + 1])
        i += 1
    return out^


def _live_inside_double_quotes(text: String) -> String:
    """Every codepoint of `text` that keeps its meaning between double quotes.

    Four bytes do, and no others: a `$` and a backtick still expand, a `"`
    still closes the string, and a backslash still escapes. A glob character
    or a semicolon is inert here, which is why the broader
    `_live_metacharacters` would be the wrong instrument for this position.

    Args:
        text: The text as it appears between the script's double quotes.

    Returns:
        The freshly allocated live codepoints, in order.
    """
    var live = String("")
    var pending = False
    for cp in text.codepoints():
        var code = Int(cp)
        if pending:
            pending = False
            continue
        if code == 92:
            pending = True
            continue
        if code == 36 or code == 96 or code == 34:
            live += String(cp)
    return live^


def _live_metacharacters(text: String) -> String:
    """Every expansion-triggering codepoint of `text` no backslash protects."""
    var live = String("")
    var pending = False
    for cp in text.codepoints():
        var code = Int(cp)
        if pending:
            pending = False
            continue
        if code == 92:
            pending = True
            continue
        if (
            code == 36
            or code == 96
            or code == 40
            or code == 41
            or code == 34
            or code == 39
            or code == 59
            or code == 38
            or code == 124
            or code == 60
            or code == 62
            or code == 42
            or code == 63
            or code == 91
            or code == 126
            or code == 123
            or code == 125
        ):
            live += String(cp)
    return live^


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
        var words = _compgen_wordlist(_flag_words_for(bit))
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


# --- head resolution: the leading token, then the effective head -----------


def test_the_head_state_table_names_every_leading_token() raises:
    """No token may fall to `none` by accident of a missing branch."""
    assert_equal(_head_state("run"), "run")
    assert_equal(_head_state("collect"), "collect")
    assert_equal(_head_state("config"), "config-show")
    assert_equal(_head_state("doctor"), "doctor")
    assert_equal(_head_state("debug"), "debug")
    assert_equal(_head_state("completions"), "completions")
    assert_equal(_head_state("new"), "none")
    assert_equal(_head_state("init"), "none")
    assert_equal(_head_state("help"), "none")
    assert_equal(_head_state("version"), "none")


def test_every_flag_accepting_head_has_a_state_and_a_bit() raises:
    """The two head fields, checked against each other row by row.

    They are separate fields because they genuinely differ, and `completions`
    is where: no flag grammar, so no bit, but a closed shell vocabulary to
    complete after the token. Every *other* resolved head owns a bit, and that
    bit's script-side name is the row's own state, which is what lets the
    per-head flag lists and the head-resolution branches key on one table.
    """
    var divergent = 0
    for spec in subcommand_specs():
        var state = _head_state(spec.token)
        if spec.head_bit == 0:
            if spec.token == "completions":
                divergent += 1
                assert_equal(
                    state,
                    "completions",
                    "the one bitless head with a state of its own lost it",
                )
            else:
                assert_equal(
                    state,
                    "none",
                    "a head with no flag grammar resolves to a head: "
                    + spec.token,
                )
            continue
        assert_true(
            state != "none",
            "a flag-accepting head offers nothing: " + spec.token,
        )
        assert_equal(
            _head_name(spec.head_bit),
            state,
            "the bit and the state disagree: " + spec.token,
        )
    assert_equal(
        divergent, 1, "the row the two fields exist to express is gone"
    )


def test_the_offers_nothing_group_is_exactly_these_four_heads() raises:
    """Transcribed rather than derived, so a rename cannot rewrite both sides.
    """
    var expected: List[String] = ["new", "init", "help", "version"]
    var actual = _none_tokens()
    assert_equal(len(actual), len(expected), "the none group changed size")
    for i in range(len(expected)):
        assert_equal(actual[i], expected[i], "none group drift")


def test_every_head_token_is_resolved_by_every_script() raises:
    """The generalized guard: a new subcommand cannot inherit the run grammar.

    Every token of `subcommand_specs()` must appear in each script's own
    head-resolution block — as its own branch when it resolves to a head, and
    in the `none` group when it does not. A subcommand added to the table
    without a branch here lands in `none` and offers nothing, which is the safe
    answer; a subcommand added without reaching the block at all would keep
    `run`'s flags, which is the wrong one.
    """
    var bash = render_bash_completions()
    var zsh = render_zsh_completions()
    var fish = render_fish_completions()
    var none_tokens = _none_tokens()
    var bash_none = String("")
    var zsh_none = String("")
    var fish_none = String("")
    for token in none_tokens:
        if bash_none.byte_length() != 0:
            bash_none += "|"
            zsh_none += "|"
            fish_none += " "
        bash_none += '"' + String(token) + '"'
        zsh_none += "'" + String(token) + "'"
        fish_none += "'" + String(token) + "'"
    assert_true(len(none_tokens) > 0, "no flag-less head token at all")
    assert_true("    " + bash_none + ') cmd="none" ;;\n' in bash)
    assert_true("    " + zsh_none + ") cmd=none ;;\n" in zsh)
    assert_true(
        "            case " + fish_none + "\n                set head none\n"
        in fish
    )
    for spec in subcommand_specs():
        var token = spec.token.copy()
        var state = _head_state(token)
        if state == "none":
            assert_true(
                _has_word(fish_none, "'" + token + "'"),
                "flag-less head not in the none group: " + token,
            )
            continue
        if token == "config":
            # The sole two-token subcommand keeps its own pending branch.
            assert_true('    "config")\n' in bash, "bash lost config")
            assert_true("    'config')\n" in zsh, "zsh lost config")
            assert_true(
                "            case 'config'\n" in fish, "fish lost config"
            )
            continue
        assert_true(
            '    "' + token + '") cmd="' + state + '" ;;\n' in bash,
            "bash does not resolve the head token: " + token,
        )
        assert_true(
            "    '" + token + "') cmd='" + state + "' ;;\n" in zsh,
            "zsh does not resolve the head token: " + token,
        )
        assert_true(
            "            case '"
            + token
            + "'\n                set head '"
            + state
            + "'"
            in fish,
            "fish does not resolve the head token: " + token,
        )


def test_bash_resolves_the_head_from_the_leading_token_only() raises:
    var script = render_bash_completions()
    assert_true('case "${lwords[1]-}" in' in script)
    assert_true('"doctor") cmd="doctor" ;;' in script)


def test_bash_rejoins_the_words_readline_split_at_a_colon() raises:
    """`COMP_WORDBREAKS` contains `:`, so `COMP_WORDS` cannot carry `md:path`.

    Driven for real, `--report md:` reaches a completion function as
    `cur=[:] prev=[md]` and `--report md:pl` as `cur=[pl] prev=[:]`: the value
    arm is keyed on `cmd:prev`, so it never fires a second time and the path
    after the separator is unreachable. Only the pieces that were adjacent in
    `COMP_LINE` are re-joined — `-k a: b` is three words and `md:pl` is one,
    and nothing but the whitespace between them distinguishes the two.
    """
    var script = render_bash_completions()
    assert_true("_mtest_words() {" in script)
    assert_true('local rest="$COMP_LINE" piece last i' in script)
    assert_true('[[ "$rest" != [[:space:]]* ]]; then' in script)
    assert_true('lwords[last-1]+="$piece"' in script)
    assert_true('rest="${rest#"$piece"}"' in script)


def test_bash_keeps_readlines_own_quote_aware_word_array() raises:
    """Re-splitting the line would complete the wrong file and eat typed text.

    `COMP_WORDS` elements are raw slices of the command line, so a
    backslash-escaped space or an opening quote is still part of the word;
    readline does not even split at a `:` inside quotes. A whitespace re-split
    of `COMP_LINE` loses that, and since readline still replaces the whole
    word, `mtest my\\ rep<TAB>` completes `rep` and overwrites `my\\ rep`
    with the result.
    """
    var script = render_bash_completions()
    assert_true('piece="${COMP_WORDS[i]}"' in script)
    assert_true('[ "$i" -eq "$COMP_CWORD" ]' in script)
    assert_false(
        "COMP_LINE:0:COMP_POINT" in script,
        (
            "a byte-offset slice of the line is back; it also mixes byte and"
            " character offsets in a multibyte locale"
        ),
    )
    assert_false(
        "read -r -a lwords" in script,
        "the line is being re-split instead of the array re-joined",
    )


def test_bash_trims_only_what_readline_will_not_replace() raises:
    """The trim is the difference between the logical word and readline's.

    An unsplit word leaves nothing to trim, which is what lets a quoted
    `"md:my rep` be completed whole; a split `md:pl` leaves `md:`, which would
    otherwise be inserted after the `md:` already on the line.
    """
    var script = render_bash_completions()
    assert_true("_mtest_trim_to_replaced() {" in script)
    assert_true('local replaced="$2" keep i' in script)
    assert_true('keep="${1%"$replaced"}"' in script)
    assert_true(
        '_mtest_trim_to_replaced "$cur" "${COMP_WORDS[COMP_CWORD]}"' in script,
        "the prefix arm does not trim against readline's own word",
    )


def test_bash_blanks_the_trim_when_readline_replaces_nothing() raises:
    """Which characters empty the replacement region, not how the line reads.

    A cursor straight after a word-break character has an EMPTY replacement
    region — readline inserts rather than replaces — so the whole logical word
    has to come off, or that character is left on the front of every candidate
    and `--report md:<TAB>` yields `md:\\:tail.md`.

    The two quotes are excluded on purpose, and that exclusion is the
    load-bearing half: readline keeps and dequotes a quote, so its region is
    not empty there, and blanking the trim inserts a second copy of the
    prefix. Both halves are driven at buffer level against a real bash, which
    is the only thing that can see this class of defect — the candidates are
    right and the insertion is wrong, so no candidate-list assertion reaches
    it.
    """
    var class_body = _bash_word_break_class()
    for breaking in [":", "=", ">", "<", ";", "|", "&", "("]:
        assert_true(
            breaking in class_body,
            "a word-break character readline empties is unhandled: " + breaking,
        )
    for quoting in ['"', "'"]:
        assert_false(
            quoting in class_body,
            "readline does not empty its region after a quote, so blanking"
            " the trim there duplicates the prefix: "
            + quoting,
        )
    var script = render_bash_completions()
    assert_true(
        "${replaced//[" + class_body + "]/}" in script,
        "the discriminator does not test the set it declares",
    )
    assert_true(
        'replaced=""' in script,
        "nothing blanks the replacement when readline replaces nothing",
    )


def test_the_collect_only_spelling_comes_from_the_flag_table() raises:
    assert_equal(_spelling_of(FlagId.COLLECT_ONLY), "--collect-only")


def test_bash_refines_a_run_head_to_collect_under_collect_only() raises:
    """Deleting the refinement must fail this test, not merely change it."""
    var block = String('  if [ "$cmd" = "run" ]; then\n')
    block += '    for word in "${lwords[@]}"; do\n'
    block += (
        '      if [ "$word" = "'
        + _spelling_of(FlagId.COLLECT_ONLY)
        + '" ]; then\n'
    )
    block += '        cmd="collect"\n'
    block += "        break\n"
    block += "      fi\n"
    block += "    done\n"
    block += "  fi\n"
    assert_true(
        block in render_bash_completions(),
        "the bash effective-head refinement is gone",
    )


def test_zsh_refines_a_run_head_to_collect_under_collect_only() raises:
    """The two state names are quoted, which is how they are table values.

    Written as literals with their quotes rather than assembled from
    `_head_name`, so a renderer that went back to pasting the name in raw
    fails here instead of agreeing with itself.
    """
    var block = String("  if [[ $cmd == 'run' ]]; then\n")
    block += "    for word in $words; do\n"
    block += "      if [[ $word == '"
    block += _spelling_of(FlagId.COLLECT_ONLY)
    block += "' ]]; then\n"
    block += "        cmd='collect'\n"
    block += "        break\n"
    block += "      fi\n"
    block += "    done\n"
    block += "  fi\n"
    assert_true(
        block in render_zsh_completions(),
        "the zsh effective-head refinement is gone",
    )


def test_fish_refines_a_run_head_to_collect_under_collect_only() raises:
    var block = String("    if test \"$head\" = 'run'; and contains -- ")
    block += "'" + _spelling_of(FlagId.COLLECT_ONLY) + "'"
    block += " $parts\n        set head 'collect'\n    end\n"
    assert_true(
        block in render_fish_completions(),
        "the fish effective-head refinement is gone",
    )


def test_the_refined_head_gains_format_and_withdraws_the_run_only_flags() raises:
    """What the refinement is *for*: the collect grammar, in all three shells.
    """
    var collect = _flags_for(Subcommand.COLLECT)
    assert_true(_has_word(collect, "--format"), "collect lost --format")
    for withdrawn in ["-x", "--exitfirst", "--gate", "--json"]:
        assert_false(
            _has_word(collect, withdrawn),
            "collect still offers a run-only flag: " + withdrawn,
        )
    assert_true(
        '-W "' + _compgen_wordlist(_flag_words_for(Subcommand.COLLECT))
        in render_bash_completions(),
        "the bash collect arm does not embed the collect list",
    )
    var zsh_collect = _zsh_specs_for(Subcommand.COLLECT)
    assert_true("'--format[" in zsh_collect, "zsh collect lost --format")
    for withdrawn in ["'-x[", "'--gate[", "'--json["]:
        assert_false(
            withdrawn in zsh_collect,
            "zsh collect still offers a run-only flag: " + withdrawn,
        )
    var fish = render_fish_completions()
    assert_true(
        "'__mtest_head_is collect' -l 'format'" in fish,
        "fish collect lost --format",
    )
    for withdrawn in ["-s 'x' ", "-l 'gate' ", "-l 'json' "]:
        assert_false(
            "'__mtest_head_is collect' " + withdrawn in fish,
            "fish collect still offers a run-only flag: " + withdrawn,
        )


def test_config_pending_completes_exactly_the_show_token() raises:
    assert_true(
        '    config-pending) COMPREPLY=($(compgen -W "show" -- "$cur")) ;;\n'
        in render_bash_completions(),
        "the bash config-pending arm drifted",
    )
    assert_true(
        "    config-pending) _values 'subcommand' 'show' ;;\n"
        in render_zsh_completions(),
        "the zsh config-pending arm drifted",
    )
    assert_true(
        "complete -c mtest -n '__mtest_head_is config-pending' -f -a 'show' -d "
        + _fish_quoted(_config_row_description())
        + "\n"
        in render_fish_completions(),
        "the fish config-pending rule drifted",
    )


def test_the_completions_head_completes_its_own_shell_operand() raises:
    assert_true(
        '    "completions") COMPREPLY=($(compgen -W "'
        + _compgen_wordlist(completion_shells())
        + '" -- "$cur")) ;;\n'
        in render_bash_completions(),
        "the bash completions arm drifted",
    )
    var shells = String("")
    for shell in completion_shells():
        if shells.byte_length() != 0:
            shells += " "
        shells += "'" + _zsh_action_word(shell) + "'"
    assert_true(
        "    'completions') _values 'shell' " + shells + " ;;\n"
        in render_zsh_completions(),
        "the zsh completions arm drifted",
    )
    assert_true(
        "complete -c mtest -n '__mtest_head_is completions' -f -a "
        + _fish_argument_list(completion_shells())
        + "\n"
        in render_fish_completions(),
        "the fish completions rule drifted",
    )


def test_value_arms_are_keyed_on_command_and_flag() raises:
    var script = render_bash_completions()
    assert_true('"run:--report-style"' in script)
    assert_false("doctor:--report-style" in script)
    assert_true('"doctor:--color"' in script)
    assert_true('"collect:--format"' in script)
    assert_false("run:--format" in script)


def test_only_arity_zero_flags_get_no_value_arm() raises:
    """A value position always gets an arm, even when it offers nothing.

    An `OTHER` row without one falls through to the head arm and completes
    every flag and every file, which is the guess the kind exists to refuse —
    so "offers nothing" has to be something the script says, not something it
    omits.
    """
    for spec in flag_specs():
        var arms = _cmd_scoped_patterns(spec)
        if spec.arity == 0:
            assert_equal(arms, "", "value arm for " + spec.spelling)
        else:
            assert_true(arms != "", "no value arm for " + spec.spelling)


def test_an_open_value_completes_nothing_rather_than_falling_through() raises:
    """The `OTHER` arm, asserted in all three shells at once.

    bash offers an empty reply, zsh an empty action, and fish `-x` with no
    `-a`. bash is the one that had to be added: the other two get the promise
    from a syntax that requires the action to be written out.
    """
    var bash = render_bash_completions()
    var fish = render_fish_completions()
    var seen = 0
    for spec in flag_specs():
        if spec.arity == 0 or spec.value_kind != ValueKind.OTHER:
            continue
        seen += 1
        assert_true(
            "    "
            + _cmd_scoped_patterns(spec)
            + ")\n      COMPREPLY=()\n      return ;;\n"
            in bash,
            "bash falls through for " + spec.spelling,
        )
        assert_true(
            _zsh_spec(spec).endswith(":'"),
            "zsh offers a candidate for " + spec.spelling,
        )
        assert_true(
            " " + _fish_flag_token(spec.spelling) + " -x -d " in fish,
            "fish offers a candidate for " + spec.spelling,
        )
    assert_true(seen >= 10, "the open-value rows vanished from the table")


def test_every_closed_choice_reaches_every_script() raises:
    """Each script carries the choice in its own encoding, never a third one."""
    var bash = render_bash_completions()
    var zsh = render_zsh_completions()
    var fish = render_fish_completions()
    for spec in flag_specs():
        for choice in spec.choices:
            var word = String(choice)
            assert_true(word in bash, "bash lost a choice: " + spec.spelling)
            # A prefix choice reaches zsh through a generated function body,
            # which is ordinary shell code and takes shell quoting; every
            # other choice is an action word and takes action escaping.
            var in_zsh = _zsh_action_word(word)
            if spec.value_kind == ValueKind.PREFIX_CHOICE:
                in_zsh = _zsh_quoted(word)
            assert_true(in_zsh in zsh, "zsh lost a choice: " + spec.spelling)
            assert_true(word in fish, "fish lost a choice: " + spec.spelling)


def test_the_prefix_choice_arm_completes_a_path_after_its_prefix() raises:
    var script = render_bash_completions()
    assert_true('if [[ "$cur" == *:* ]]; then' in script)
    assert_true('compgen -P "$pfx" -f -- "$rest"' in script)


def test_the_prefix_choice_arm_leaves_no_trailing_space() raises:
    """A prefix completed with a space cannot be continued into a path.

    `nospace` belongs to the prefix list alone: a completed path is a finished
    word and wants its space like every other candidate, so applying it to the
    whole arm would have traded one annoyance for another.
    """
    var bash = render_bash_completions()
    var arm = String('      if [[ "$cur" == *:* ]]; then\n')
    arm += '        local pfx="${cur%%:*}:" rest="${cur#*:}"\n'
    arm += '        if [ "$cur" = "${COMP_WORDS[COMP_CWORD]}" ]; then\n'
    arm += "          compopt -o nospace\n"
    arm += "        else\n"
    arm += "          compopt -o filenames\n"
    arm += "        fi\n"
    arm += '        _mtest_reply < <(compgen -P "$pfx" -f -- "$rest")\n'
    arm += "      else\n"
    arm += "        compopt -o nospace\n"
    assert_true(arm in bash, "the bash prefix arm drifted")
    assert_true(
        "compadd -S '' --" in render_zsh_completions(),
        "the zsh prefix helper lost its empty suffix",
    )


def test_the_prefix_choice_arm_completes_a_path_in_every_shell() raises:
    """The second stage: a path under the prefix, once the separator is typed.

    Each shell reaches it differently. bash re-derives the logical word and
    prefixes the candidates with `compgen -P`, then trims what readline will
    not replace. zsh moves the typed prefix aside with `compset -P` and hands
    the remainder to `_files`. fish has no per-rule `nospace`, so it cannot
    offer a prefix that stays open and assembles the whole `PREFIX:PATH`
    candidate in one step instead.
    """
    var bash = render_bash_completions()
    assert_true('compgen -P "$pfx" -f -- "$rest"' in bash)
    assert_true("_mtest_trim_to_replaced() {" in bash)
    var zsh = render_zsh_completions()
    assert_true(
        "_mtest_prefix__report() {\n" in zsh,
        "the zsh prefix helper is gone",
    )
    assert_true("    compset -P '*:'\n    _files\n" in zsh)
    assert_true(":_mtest_prefix__report'" in zsh, "no spec reaches the helper")
    var fish = render_fish_completions()
    assert_true("function __mtest_prefixed_path" in fish)
    assert_true(
        "-a '(__mtest_prefixed_path md: html:)'" in fish,
        "the fish report rule does not call the candidate assembler",
    )


def test_every_file_completion_declares_filename_semantics() raises:
    """`-o filenames` is what makes readline escape and mark a completed path.

    It carries two effects a path candidate cannot do without: a directory
    ends in a slash instead of a terminating space, and a name holding a
    shell-special character is re-quoted for the line. Without it readline
    inserts the match verbatim, so completing `my\\ rep` yields the two words
    `my report.md` and completing `re` yields `reports ` — a path the shell
    then cannot open.

    Every arm whose `compgen` carries `-f` takes it, including the ones that
    also offer flag words. Mixing costs nothing: readline asks the filesystem
    about each candidate, and `--color` is neither a directory nor in need of
    quoting, so it is completed exactly as it was without the option.
    """
    var lines = render_bash_completions().split("\n")
    var found = 0
    for i in range(len(lines)):
        var line = String(lines[i])
        if "compgen " not in line or "-f " not in line:
            continue
        found += 1
        if "compgen -P " in line:
            # The prefix arm chooses between filename semantics and `nospace`
            # on whether readline split the word; its own test pins the shape.
            continue
        assert_true(
            "compopt -o filenames" in line
            or (i > 0 and "compopt -o filenames" in String(lines[i - 1])),
            "a file completion without filename semantics: " + line,
        )
    assert_true(found >= 2, "no file completion found at all")


def test_the_doctor_arm_offers_no_path_and_so_no_filename_semantics() raises:
    """The one head that takes no operand is the one arm without either.

    `doctor` accepts no path at all, so its arm carries neither `-f` nor the
    filename marking — which is what keeps the assertion above honest: an
    unconditional `compopt` would satisfy it without proving anything.
    """
    var bash = render_bash_completions()
    var doctor = String("")
    for line in bash.split("\n"):
        if String(line).startswith('    "doctor") '):
            doctor = String(line)
    assert_true(doctor != "", "the bash doctor arm is gone")
    assert_false("-f " in doctor, "doctor completes a path: " + doctor)
    assert_false("compopt" in doctor, "doctor marks filenames: " + doctor)
    # fish states the same fact as a rule of its own, and zsh by the absence
    # of an operand action, so all three are pinned here rather than one.
    assert_true(
        "complete -c mtest -n '__mtest_head_is doctor' -f\n"
        in render_fish_completions(),
        "the fish doctor rule no longer suppresses files",
    )
    var zsh_doctor = String("")
    for line in render_zsh_completions().split("\n"):
        if String(line).startswith("    'doctor') "):
            zsh_doctor = String(line)
    assert_true(zsh_doctor != "", "the zsh doctor arm is gone")
    assert_false(
        "'*:" in zsh_doctor, "zsh doctor takes an operand: " + zsh_doctor
    )


# --- value kinds: a closed set, and three syntaxes for each ----------------


def _kind_roster() -> List[ValueKind]:
    """Every `ValueKind` this module carries a rendering expectation for.

    Transcribed rather than derived, because nothing can enumerate a struct's
    `comptime` members: what catches a new kind is the three helpers below,
    each of which refuses a kind it has no arm for, so a kind that reaches a
    `flag_specs()` row reds this module instead of completing nothing.
    """
    return [
        ValueKind.NONE,
        ValueKind.PATH,
        ValueKind.CHOICE,
        ValueKind.CHOICE_OR_OTHER,
        ValueKind.PREFIX_CHOICE,
        ValueKind.OTHER,
    ]


def _spaced(values: List[String]) -> String:
    """`values` joined with single spaces."""
    var out = String("")
    for value in values:
        if out.byte_length() != 0:
            out += " "
        out += String(value)
    return out^


def _bash_value_arm(spec: FlagSpec) raises -> String:
    """The bash body one row's value kind renders under its `cmd:prev` arm.

    Args:
        spec: The flag row to describe. Not mutated.

    Returns:
        The freshly allocated arm body, or empty text for a kind that gets no
        arm at all.

    Raises:
        Error: For a `ValueKind` this module has no bash arm for.
    """
    if spec.value_kind == ValueKind.NONE:
        return String("")
    if spec.value_kind == ValueKind.OTHER:
        return String("      COMPREPLY=()\n")
    if spec.value_kind == ValueKind.PATH:
        return (
            "      compopt -o filenames\n"
            + '      _mtest_reply < <(compgen -f -- "$cur")\n'
        )
    if spec.value_kind == ValueKind.PREFIX_CHOICE:
        return (
            '      if [[ "$cur" == *:* ]]; then\n'
            + '        local pfx="${cur%%:*}:" rest="${cur#*:}"\n'
            + '        if [ "$cur" = "${COMP_WORDS[COMP_CWORD]}" ]; then\n'
            + "          compopt -o nospace\n"
            + "        else\n"
            + "          compopt -o filenames\n"
            + "        fi\n"
            + '        _mtest_reply < <(compgen -P "$pfx" -f -- "$rest")\n'
            + "      else\n"
            + "        compopt -o nospace\n"
            + '        COMPREPLY=($(compgen -W "'
            + _compgen_wordlist(spec.choices)
            + '" -- "$cur"))\n'
            + "      fi\n"
            + '      _mtest_trim_to_replaced "$cur"'
            + ' "${COMP_WORDS[COMP_CWORD]}"\n'
        )
    if (
        spec.value_kind == ValueKind.CHOICE
        or spec.value_kind == ValueKind.CHOICE_OR_OTHER
    ):
        return (
            '      COMPREPLY=($(compgen -W "'
            + _compgen_wordlist(spec.choices)
            + '" -- "$cur"))\n'
        )
    raise Error("no bash arm for value kind " + String(spec.value_kind.code))


def _zsh_value_action(spec: FlagSpec) raises -> String:
    """The action one row's value kind gives its zsh `_arguments` spec.

    Args:
        spec: The flag row to describe. Not mutated.

    Returns:
        The freshly allocated text that follows the value message, empty for an
        arity-zero flag, which has no message and no action at all.

    Raises:
        Error: For a `ValueKind` this module has no zsh action for.
    """
    if spec.value_kind == ValueKind.NONE:
        return String("")
    if spec.value_kind == ValueKind.OTHER:
        return String(":")
    if spec.value_kind == ValueKind.PATH:
        return String(":_files")
    if spec.value_kind == ValueKind.PREFIX_CHOICE:
        return ":" + _zsh_helper_name(spec.spelling)
    if (
        spec.value_kind == ValueKind.CHOICE
        or spec.value_kind == ValueKind.CHOICE_OR_OTHER
    ):
        var words = List[String]()
        for choice in spec.choices:
            words.append(_zsh_action_word(choice))
        return ":(" + _spaced(words) + ")"
    raise Error("no zsh action for value kind " + String(spec.value_kind.code))


def _fish_value_syntax(spec: FlagSpec) raises -> String:
    """The `complete` options one row's value kind renders for fish.

    Args:
        spec: The flag row to describe. Not mutated.

    Returns:
        The freshly allocated option text, empty for an arity-zero flag.

    Raises:
        Error: For a `ValueKind` this module has no fish options for.
    """
    if spec.value_kind == ValueKind.NONE:
        return String("")
    if spec.value_kind == ValueKind.PATH:
        return String(" -r")
    if spec.value_kind == ValueKind.OTHER:
        return String(" -x")
    if spec.value_kind == ValueKind.PREFIX_CHOICE:
        var words = List[String]()
        for choice in spec.choices:
            words.append(_fish_expansion_word(choice))
        return " -x -a " + _fish_quoted(
            "(__mtest_prefixed_path " + _spaced(words) + ")"
        )
    if (
        spec.value_kind == ValueKind.CHOICE
        or spec.value_kind == ValueKind.CHOICE_OR_OTHER
    ):
        return " -x -a " + _fish_argument_list(spec.choices)
    raise Error(
        "no fish options for value kind " + String(spec.value_kind.code)
    )


def test_every_value_kind_reaches_all_three_scripts() raises:
    """A kind with no rendering must red here, not complete nothing in a shell.

    The three shells share no syntax for a value, so a new `ValueKind` is
    inherently three edits — a bash arm body, a zsh action, and a fish option
    string — and the three helpers above are where each one lands. A kind put
    on a `flag_specs()` row without them raises out of this test rather than
    reaching a user's shell as a flag that offers nothing.
    """
    var bash = render_bash_completions()
    var zsh = render_zsh_completions()
    var fish = render_fish_completions()
    for spec in flag_specs():
        var arm = _bash_value_arm(spec)
        var patterns = _cmd_scoped_patterns(spec)
        if arm.byte_length() == 0:
            assert_equal(patterns, "", "bash value arm for " + spec.spelling)
        else:
            assert_true(
                "    " + patterns + ")\n" + arm in bash,
                "bash does not render the value of " + spec.spelling,
            )
        # Assembled from the row rather than read back off `_zsh_spec`, so
        # both assertions are evidence about the renderer instead of about
        # themselves: the first pins the specification's shape, the second
        # proves that exact text reaches the script.
        var body = String("*") if spec.repeatable else String("")
        body += spec.spelling + "[" + _zsh_description(spec.help) + "]"
        if spec.arity == 1:
            body += ":" + _zsh_message(spec.value_name)
        var specification = _zsh_quoted(body + _zsh_value_action(spec))
        assert_equal(
            _zsh_spec(spec),
            specification,
            "the zsh specification of " + spec.spelling + " drifted",
        )
        assert_true(
            specification in zsh,
            "zsh does not render the value of " + spec.spelling,
        )
        assert_true(
            _fish_flag_token(spec.spelling) + _fish_value_syntax(spec) + " -d "
            in fish,
            "fish does not render the value of " + spec.spelling,
        )


def test_every_known_value_kind_is_declared_by_some_flag_row() raises:
    """A kind no row declares is a kind the test above never exercises."""
    for kind in _kind_roster():
        var declared = False
        for spec in flag_specs():
            if spec.value_kind == kind:
                declared = True
        assert_true(
            declared, "no flag row declares value kind " + String(kind.code)
        )


# --- shell safety ----------------------------------------------------------


def test_file_completions_never_word_split_on_a_filename() raises:
    var script = render_bash_completions()
    for line in _lines_containing(script, "-f -- "):
        assert_true(
            "_mtest_reply < <(" in line,
            "file completion outside the quoted read loop: " + line,
        )
    assert_false("COMPREPLY=($(compgen -f" in script)


def test_a_hostile_head_name_cannot_break_out_of_a_bash_case_label() raises:
    """The `case "$cmd" in` labels, which used to take the name raw.

    A raw label is a glob in an unquoted position: a `*` matches every head, a
    space splits the pattern, and a `$` is expanded when `case` matches.
    """
    for hostile in _hostile_values():
        var pattern = _bash_pattern(hostile)
        assert_true(pattern.startswith('"'), "unquoted label: " + pattern)
        assert_true(pattern.endswith('"'), "unquoted label: " + pattern)
        var body = String(pattern[byte = 1 : pattern.byte_length() - 1])
        assert_equal(
            _live_inside_double_quotes(body),
            "",
            "the label stays live for: " + hostile,
        )
        assert_equal(
            _bash_double_quote_removal(body),
            hostile,
            "the label no longer matches its own head: " + hostile,
        )


def test_a_hostile_head_name_cannot_break_out_of_a_zsh_case_label() raises:
    for hostile in _hostile_values():
        assert_equal(
            _zsh_single_quote_removal(_zsh_quoted(hostile)),
            hostile,
            "the zsh label no longer matches its own head: " + hostile,
        )


def test_a_hostile_head_name_cannot_run_from_a_fish_condition() raises:
    """The sharpest position in the module, because fish evaluates it.

    `complete -n '…'` takes a *command*, run when a completion is generated,
    so this position needs both levels: the name is escaped as one literal
    word of that command and the command is then single-quoted. Both are
    asserted — that nothing expandable reaches the evaluation, and that the
    word the condition tests is still the head's own name.
    """
    for hostile in _hostile_values():
        var condition = _fish_head_condition(hostile)
        var stored = _fish_single_quote_removal(condition)
        assert_equal(
            _live_metacharacters(stored),
            "",
            "a live metacharacter reaches fish's evaluation for: " + hostile,
        )
        assert_equal(
            _backslash_removal(stored),
            "__mtest_head_is " + hostile,
            "the fish condition tests the wrong head for: " + hostile,
        )


def test_every_head_name_reaches_each_script_through_its_escaper() raises:
    """Routing, asserted against the rendered text rather than the helpers.

    Every head name is a table value, and until this test the module escaped
    it where it was *assigned* and pasted it raw where it was *matched*. The
    two forms are identical for today's `[a-z-]+` states, so nothing but an
    exact-shape assertion can tell them apart.
    """
    var bash = render_bash_completions()
    var zsh = render_zsh_completions()
    var fish = render_fish_completions()
    for bit in _head_bits():
        var name = _head_name(bit)
        assert_true(
            "    " + _bash_pattern(name) + ") " in bash,
            "the bash head arm of " + name + " is not a quoted label",
        )
        assert_true(
            "    " + _zsh_quoted(name) + ") _arguments" in zsh,
            "the zsh head arm of " + name + " is not a quoted label",
        )
        assert_true(
            " -n " + _fish_head_condition(name) + " " in fish,
            "the fish rules of " + name + " do not quote the condition",
        )
    for state in [_completions_state(), String("config-pending"), "none"]:
        assert_true(
            " -n " + _fish_head_condition(state) + " " in fish,
            "the fish " + state + " rule does not quote its condition",
        )


def test_no_table_value_can_carry_a_shell_metacharacter() raises:
    """The other half of the guarantee: the escapers, and then the tables.

    Escaping is what makes a hostile value inert; this is what keeps one off
    the tables in the first place, so the two failures a reader has to
    imagine — a spelling and a head state — cannot both be reached by one
    careless row. Widen the set here deliberately, with the positions above
    re-read, or not at all.
    """
    var names = List[String]()
    for spec in subcommand_specs():
        names.append(spec.token.copy())
        names.append(spec.completion_state.copy())
    for spec in flag_specs():
        names.append(spec.spelling.copy())
    for name in names:
        for cp in String(name).codepoints():
            var code = Int(cp)
            var inert = (
                (code >= 97 and code <= 122)
                or (code >= 65 and code <= 90)
                or (code >= 48 and code <= 57)
                or code == 45
                or code == 95
            )
            assert_true(
                inert,
                "a table value carries a shell-significant codepoint: " + name,
            )


def test_bash_words_are_literal_inside_double_quotes() raises:
    """The literal level only; `compgen -W` needs the second one below."""
    assert_equal(_bash_word("--color"), "--color")
    assert_equal(_bash_word('a"b'), 'a\\"b')
    assert_equal(_bash_word("a$b"), "a\\$b")
    assert_equal(_bash_word("a`b"), "a\\`b")
    assert_equal(_bash_word("a\\b"), "a\\\\b")
    assert_equal(_bash_word("$(id)"), "\\$(id)")


def test_a_hostile_word_survives_compgen_re_expansion_unchanged() raises:
    """The barrier `compgen -W` actually needs, modelled pass by pass.

    Bash removes the script's double quotes and hands the result to `compgen`,
    which splits the list and then **expands** each word. A single level of
    quoting therefore delivers a live `$(…)` to the second pass. Both
    properties are asserted: nothing expandable survives into that pass, and
    the word that comes out the far side is the one the table put in.
    """
    for hostile in _hostile_values():
        var emitted = _compgen_wordlist([hostile.copy()])
        var handed = _bash_double_quote_removal(emitted)
        assert_equal(
            _live_metacharacters(handed),
            "",
            "live metacharacter reaches compgen for: " + hostile,
        )
        assert_equal(
            _backslash_removal(handed),
            hostile,
            "compgen would not yield the word verbatim: " + hostile,
        )


def test_a_hostile_word_survives_fish_argument_expansion_unchanged() raises:
    """`complete -a` is expanded when a completion runs, so it needs two too."""
    for hostile in _hostile_values():
        var emitted = _fish_argument_list([hostile.copy()])
        var stored = _fish_single_quote_removal(emitted)
        assert_equal(
            _live_metacharacters(stored),
            "",
            "live metacharacter reaches fish expansion for: " + hostile,
        )
        assert_equal(
            _backslash_removal(stored),
            hostile,
            "fish would not yield the word verbatim: " + hostile,
        )


def test_a_hostile_word_is_inert_in_a_zsh_action() raises:
    """The `_arguments` action list is parsed after zsh removes the quotes."""
    for hostile in _hostile_values():
        var escaped = _zsh_action_word(hostile)
        assert_equal(
            _live_metacharacters(escaped),
            "",
            "live metacharacter reaches the zsh action for: " + hostile,
        )
        assert_equal(
            _backslash_removal(escaped),
            hostile,
            "zsh would not yield the action word verbatim: " + hostile,
        )


def test_a_multi_word_list_keeps_its_separators_unescaped() raises:
    """The escaping may not swallow the spaces that separate the candidates."""
    var emitted = _compgen_wordlist(["auto", "always", "never"])
    assert_equal(emitted, "auto always never")
    assert_equal(_fish_argument_list(["md:", "html:"]), "'md: html:'")


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
    """And quote the name: a `complete` line is ordinary fish source."""
    assert_equal(_fish_flag_token("-x"), "-s 'x'")
    assert_equal(_fish_flag_token("-I"), "-s 'I'")
    assert_equal(_fish_flag_token("--color"), "-l 'color'")
    assert_equal(_fish_flag_token("--x;touch owned;#"), "-l 'x;touch owned;#'")


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
