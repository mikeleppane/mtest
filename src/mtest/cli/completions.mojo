"""Shell completion scripts, rendered from the two command-line spec tables.

`mtest completions SHELL` writes a script for `bash`, `zsh`, or `fish` to
stdout. Nothing here restates a command-line fact: the spellings, their help
text, their value placeholders, their closed choice lists, and which heads
accept them all come from `flag_specs()`, and the head vocabulary — including
which leading tokens accept no flag at all — comes from `subcommand_specs()`. A
head's own row carries the state a script enters after its token, so a flag or
a subcommand added to a table is served by all three scripts without touching
this module, which is the only arrangement in which a completion script cannot
quietly drift from the parser it describes.

Head resolution mirrors `parse_args` exactly, and that is the subtle part. The
parser recognizes a subcommand **only as the leading token**, so `mtest -q
doctor` is a run carrying a `doctor` path operand; a script that scanned the
words for the first non-flag token would complete it as the doctor subcommand
and lie. The leading token therefore decides the head, and one refinement turns
it into the *effective* head: a `run` whose words already carry
`--collect-only` is a collection, so the flags that mode refuses — `-x`,
`--gate`, `--json` — are withdrawn and `--format` is offered. `config` is
pending until its mandatory `show` arrives, and completes exactly that token
until then, because `mtest config` alone is a usage error.

Value completion is keyed on `command:flag` rather than on the flag alone, so
`mtest doctor --report-style <TAB>` offers nothing: the pair never existed. Per
kind: a closed list becomes its words, a `PATH` becomes filesystem completion,
and `OTHER` deliberately offers nothing, because a kind that cannot express
what is legal must not guess. One value the tables cannot express is `--json`'s
bare `-` for stdout; its row says why the kind stays `PATH`, and this module
does not invent a kind for it.

A `PREFIX_CHOICE` is the one kind whose completion cannot be the same shape in
all three shells, because reaching the path after the separator means
completing a word without ending it. bash and zsh can, so both offer the
prefix first and the path second — and both need help to do it. bash splits
`COMP_WORDS` at every `COMP_WORDBREAKS` character, and that set contains `:`,
so `--report md:pl` reaches a completion function as `prev=:` and no value arm
would fire twice; the pieces that were adjacent in `COMP_LINE` are therefore
re-joined, and the candidates are trimmed back to what readline will actually
replace. That array is readline's own rather than a fresh split of the line,
because it is the quote-aware one: re-splitting on whitespace would complete a
backslash-escaped `my rep` from its `rep` alone, overwriting the text already
typed with a candidate computed from the wrong half of it.
zsh's `compset -P` does the same job in one builtin. fish needs neither,
because a `complete -a` rule supplies whole words: one function assembles the
`PREFIX:PATH` candidate from `commandline -ct`, and fish leaves a completed
prefix or directory without a trailing space on its own, so the same two steps
work there without a second rule.

**Escaping is two-level where the shell expands twice.** These scripts are
`eval`'d into an interactive shell, and three of the positions a table value
lands in are re-expanded *after* the script's own quotes are removed:
`compgen -W` expands every word of its list, fish's `complete -a` expands its
argument list when a completion is generated, and zsh's `_arguments` action
words are parsed by the completion system. A single level of quoting is
therefore not a barrier — `compgen -W "\\$(id)"` still runs `id`, because the
script's double quotes only deliver `$(id)` to `compgen`, which then expands
it. Every such value is escaped for the re-expansion first
(`_compgen_word`, `_fish_expansion_word`, `_zsh_action_word`, each of which
backslashes everything outside a small alphanumeric-and-punctuation set) and
only then for the literal quoting the script source needs. Positions that are
expanded once — a bash `case` pattern, a zsh bracketed description, a fish
`-d` description, a value interpolated into a generated function body — get
the single level that position actually needs. **No table value reaches script
text without passing an escaper**, including the head tokens that end up as
`case` labels, and that rule is what the whole module is for.

Every file completion additionally rides a quoted read loop, because an
unquoted `COMPREPLY=($(compgen -f …))` word-splits a filename containing a
space.
"""
from mtest.cli.flag_spec import (
    FlagId,
    FlagSpec,
    Subcommand,
    ValueKind,
    flag_specs,
    subcommand_specs,
)


def completion_shells() -> List[String]:
    """The shells `mtest completions` renders a script for.

    The parser validates its operand against this list, the renderer dispatches
    on it, and each script offers it after the `completions` head token, so the
    accepted vocabulary, the served vocabulary, and the completed vocabulary
    are one list rather than three that agree today.

    Returns:
        A freshly allocated list of shell names, in the order they are
        documented.
    """
    return ["bash", "zsh", "fish"]


def render_completions(shell: String) raises -> String:
    """Render the completion script for one shell.

    Args:
        shell: One of `completion_shells()`.

    Returns:
        The freshly allocated script text, ending in a newline.

    Raises:
        Error: A `cli:`-prefixed usage error naming a shell this build does not
            render. The parser refuses the same value first; this refusal is
            what keeps the promise for a direct library call.

    Examples:

    ```mojo
    from mtest.cli import render_completions

    print(render_completions("bash"))
    ```
    """
    if shell == "bash":
        return render_bash_completions()
    if shell == "zsh":
        return render_zsh_completions()
    if shell == "fish":
        return render_fish_completions()
    raise Error(
        "cli: 'completions' wants one of "
        + _joined(completion_shells())
        + ", got '"
        + shell
        + "' (see mtest --help)"
    )


# --- the two tables, projected -------------------------------------------- #


def _joined_with(values: List[String], separator: String) -> String:
    """Join `values` with `separator`.

    Args:
        values: The words to join. Not mutated.
        separator: The text placed between adjacent words.

    Returns:
        The freshly allocated joined text, empty for an empty list.
    """
    var out = String("")
    for value in values:
        if out.byte_length() != 0:
            out += separator
        out += String(value)
    return out^


def _joined(values: List[String]) -> String:
    """Join `values` with single spaces.

    Args:
        values: The words to join. Not mutated.

    Returns:
        The freshly allocated joined text, empty for an empty list.
    """
    return _joined_with(values, " ")


def _head_bits() -> List[Int]:
    """Every flag-accepting head, as its applicability bit, in help order.

    Returns:
        A freshly allocated list of the nonzero `head_bit` values in
        `subcommand_specs()` order, which is the order help renders the rows.
        A row with no flag grammar carries a zero bit and is skipped.
    """
    var bits = List[Int]()
    for spec in subcommand_specs():
        if spec.head_bit != 0:
            bits.append(spec.head_bit)
    return bits^


def _head_name(subcommand: Int) -> String:
    """The name the generated scripts give one applicability bit.

    Args:
        subcommand: One of the `Subcommand` bit constants.

    Returns:
        The freshly allocated script-side head name, taken from the row that
        selects that bit; `run` for a bit no row claims, which is what the
        parser's default subcommand means.
    """
    for spec in subcommand_specs():
        if spec.head_bit != 0 and spec.head_bit == subcommand:
            return spec.completion_state.copy()
    return String("run")


def _head_state(token: String) -> String:
    """The completion state one leading token selects.

    This is the token-to-head mapping `parse_args` performs, read off the row
    rather than restated beside it. The two rows that make the mapping look
    like prose are still rows: `config` names a two-token subcommand and
    carries the state its second token resolves to, and `new`, `init`, `help`,
    and `version` carry an empty state because no flag grammar follows them. An
    empty state — and a token no row holds — is `none`, which is what makes a
    subcommand added to `subcommand_specs()` offer nothing after its head token
    rather than silently inheriting the run grammar.

    Args:
        token: A leading token from `subcommand_specs()`.

    Returns:
        The freshly allocated script-side state name.
    """
    for spec in subcommand_specs():
        if spec.token == token and spec.completion_state.byte_length() != 0:
            return spec.completion_state.copy()
    return String("none")


def _none_tokens() -> List[String]:
    """Every head token after which nothing is offered, in table order."""
    var tokens = List[String]()
    for spec in subcommand_specs():
        if spec.completion_state.byte_length() == 0:
            tokens.append(spec.token.copy())
    return tokens^


def _spelling_of(flag_id: Int) -> String:
    """The first spelling the flag table gives one flag identity.

    Args:
        flag_id: One of the `FlagId` integer constants.

    Returns:
        The freshly allocated spelling, or empty text for an identity with no
        row. `test_cli_completions` pins the one identity this module resolves,
        so the empty case is unreachable through the shipped table.
    """
    for spec in flag_specs():
        if spec.id == flag_id:
            return spec.spelling.copy()
    return String("")


def _flag_words_for(subcommand: Int) -> List[String]:
    """Every spelling whose applicability mask includes `subcommand`.

    Args:
        subcommand: One of the `Subcommand` bit constants.

    Returns:
        A freshly allocated list of spellings, in table order.
    """
    var words = List[String]()
    for spec in flag_specs():
        if (spec.applicability & subcommand) != 0:
            words.append(spec.spelling.copy())
    return words^


def _flags_for(subcommand: Int) -> String:
    """The space-separated spellings one head accepts, in table order."""
    return _joined(_flag_words_for(subcommand))


def _subcommand_word_list() -> List[String]:
    """The head tokens, in help order."""
    var words = List[String]()
    for spec in subcommand_specs():
        words.append(spec.token.copy())
    return words^


def _subcommand_words() -> String:
    """The head tokens, as the space-separated word list scripts offer."""
    return _joined(_subcommand_word_list())


def _config_description() -> String:
    """The `config` row's own help text, reused by the pending-head rule.

    Returns:
        The freshly allocated description, or empty text if the row is gone.
    """
    for spec in subcommand_specs():
        if spec.token == "config":
            return spec.description.copy()
    return String("")


def _completes_a_value(spec: FlagSpec) -> Bool:
    """Whether this spelling's value has something worth offering.

    Args:
        spec: The flag row to judge. Not mutated.

    Returns:
        True when the row takes a value whose kind can name what is legal.
        `OTHER` is excluded on purpose: a glob, an integer, or a build argument
        has no candidate set, and offering filenames for one would be a guess
        the table never made.
    """
    if spec.arity == 0:
        return False
    return spec.value_kind != ValueKind.OTHER


# --- escaping: one helper per position a table value can land in ---------- #


def _needs_no_escape(code: Int) -> Bool:
    """Whether one codepoint is inert in every shell word position.

    Args:
        code: The codepoint value to classify.

    Returns:
        True for ASCII alphanumerics and the punctuation that no shell in this
        module's three treats specially inside a word. Everything else — a
        space, a glob metacharacter, a quote, an expansion sigil, a control
        byte, and every non-ASCII codepoint — is escaped rather than reasoned
        about, because the cost of an unnecessary backslash is nothing and the
        cost of a missing one is command execution.
    """
    if code >= 48 and code <= 57:
        return True
    if code >= 65 and code <= 90:
        return True
    if code >= 97 and code <= 122:
        return True
    # _ . , : / @ = + -
    return (
        code == 95
        or code == 46
        or code == 44
        or code == 58
        or code == 47
        or code == 64
        or code == 61
        or code == 43
        or code == 45
    )


def _backslash_escaped(value: String, escape_colon: Bool) -> String:
    """Backslash every codepoint of `value` that is not inert in a word.

    Args:
        value: The text to escape. Not mutated.
        escape_colon: Whether the colon must be escaped too, which the zsh
            action position needs and no other does.

    Returns:
        The freshly allocated escaped text.
    """
    var out = String("")
    for cp in value.codepoints():
        var code = Int(cp)
        if not _needs_no_escape(code) or (escape_colon and code == 58):
            out += "\\"
        out += String(cp)
    return out^


def _bash_word(value: String) -> String:
    """Escape `value` for the inside of a bash double-quoted string.

    This is the *literal* level only: the four bytes that keep their meaning
    between double quotes are escaped, and nothing else. It is the whole job
    for a `case` pattern, which bash expands once; a `compgen -W` list is
    expanded a second time and needs `_compgen_wordlist` instead.

    Args:
        value: The text to embed. Not mutated.

    Returns:
        The freshly allocated escaped text.

    Examples:

    ```mojo
    from mtest.cli.completions import _bash_word

    print(_bash_word("$(id)"))  # \\$(id)
    ```
    """
    var out = String("")
    for cp in value.codepoints():
        var code = Int(cp)
        if code == 92 or code == 34 or code == 36 or code == 96:
            out += "\\"
        out += String(cp)
    return out^


def _bash_pattern(value: String) -> String:
    """Render `value` as one literal bash `case` alternative.

    A `case` pattern is a glob, so an unquoted alternative would turn a `*`,
    `?`, or `[` in a spelling into a wildcard. Quoting the whole alternative
    makes every byte literal.

    Args:
        value: The exact text the alternative must match. Not mutated.

    Returns:
        The freshly allocated quoted pattern.
    """
    return '"' + _bash_word(value) + '"'


def _compgen_word(value: String) -> String:
    """Escape one word for `compgen -W`'s own re-expansion of its list.

    `compgen -W` splits its list on IFS and then **expands** each word, so a
    `$`, a backtick, or a glob character that survives the script's quoting is
    still live at completion time. Backslashing it here is what makes it a
    candidate rather than a command.

    Args:
        value: The candidate value. Not mutated.

    Returns:
        The freshly allocated escaped word.
    """
    return _backslash_escaped(value, False)


def _compgen_wordlist(values: List[String]) -> String:
    """The full `-W "…"` argument text for a candidate list.

    Each word is escaped for `compgen`'s re-expansion first and the joined
    result is then escaped for the double quotes it sits inside, so the two
    unquoting passes the shell performs leave exactly the original words.

    Args:
        values: The candidate values. Not mutated.

    Returns:
        The freshly allocated text to place between the double quotes.
    """
    var escaped = List[String]()
    for value in values:
        escaped.append(_compgen_word(value))
    return _bash_word(_joined(escaped))


def _zsh_description(text: String) -> String:
    """Escape `text` for a zsh `_arguments` bracketed description.

    A description is displayed rather than expanded, so this is the single
    level that position needs.

    Args:
        text: The description to embed. Not mutated.

    Returns:
        The freshly allocated text, with the bracket pair and the backslash
        escaped so a description can never close its own bracket early.
    """
    var out = String("")
    for cp in text.codepoints():
        var code = Int(cp)
        if code == 92 or code == 91 or code == 93:
            out += "\\"
        out += String(cp)
    return out^


def _zsh_message(text: String) -> String:
    """Escape `text` for a colon-delimited zsh `_arguments` field.

    Args:
        text: The field text to embed. Not mutated.

    Returns:
        The freshly allocated text, with the colon and the backslash escaped so
        a value placeholder like `FORMAT:PATH` cannot end the field early.
    """
    var out = String("")
    for cp in text.codepoints():
        var code = Int(cp)
        if code == 92 or code == 58:
            out += "\\"
        out += String(cp)
    return out^


def _zsh_action_word(text: String) -> String:
    """Escape `text` for one word of a zsh completion action.

    The completion system parses an action's words after zsh has removed the
    spec's own quotes, so this is the re-expansion level: everything outside
    the inert set is backslashed, and the colon on top of it, because a colon
    separates an action word from its description.

    Args:
        text: The candidate value to embed. Not mutated.

    Returns:
        The freshly allocated escaped word.
    """
    return _backslash_escaped(text, True)


def _zsh_action_words(values: List[String]) -> List[String]:
    """Escape every candidate of a zsh completion action.

    Args:
        values: The candidate values. Not mutated.

    Returns:
        A freshly allocated list of escaped words.
    """
    var escaped = List[String]()
    for value in values:
        escaped.append(_zsh_action_word(value))
    return escaped^


def _zsh_quoted(text: String) -> String:
    """Wrap `text` in zsh single quotes, escaping any quote it contains.

    Args:
        text: The text to quote. Not mutated.

    Returns:
        The freshly allocated single-quoted text.
    """
    var out = String("'")
    for cp in text.codepoints():
        if Int(cp) == 39:
            out += "'\\''"
        else:
            out += String(cp)
    return out + "'"


def _fish_quoted(text: String) -> String:
    """Wrap `text` in fish single quotes.

    A fish single-quoted string honors exactly two escapes, so exactly two
    bytes are escaped. This is the literal level; a `complete -a` list is
    expanded again afterwards and goes through `_fish_argument_list`.

    Args:
        text: The text to quote. Not mutated.

    Returns:
        The freshly allocated single-quoted text.
    """
    var out = String("'")
    for cp in text.codepoints():
        var code = Int(cp)
        if code == 92 or code == 39:
            out += "\\"
        out += String(cp)
    return out + "'"


def _fish_expansion_word(value: String) -> String:
    """Escape one word for fish's expansion of a `complete -a` list.

    Fish evaluates that list when a completion is generated — which is what
    lets `-a '(commandline -ct)'` work — so a parenthesis reaching it unescaped
    is a command substitution.

    Args:
        value: The candidate value. Not mutated.

    Returns:
        The freshly allocated escaped word.
    """
    return _backslash_escaped(value, False)


def _fish_argument_list(values: List[String]) -> String:
    """The full, quoted `-a` argument for a candidate list.

    Args:
        values: The candidate values. Not mutated.

    Returns:
        The freshly allocated single-quoted list, each word escaped for the
        expansion fish performs after the quotes come off.
    """
    var escaped = List[String]()
    for value in values:
        escaped.append(_fish_expansion_word(value))
    return _fish_quoted(_joined(escaped))


def _fish_flag_token(spelling: String) -> String:
    """Render one spelling as the fish `complete` flag option that names it.

    Args:
        spelling: The exact flag spelling, `-x` or `--exclude` shaped.

    Returns:
        The freshly allocated `-s X` or `-l name` option text.
    """
    if spelling.startswith("--"):
        return "-l " + String(spelling[byte = 2 : spelling.byte_length()])
    return "-s " + String(spelling[byte = 1 : spelling.byte_length()])


# --- bash ----------------------------------------------------------------- #


def _bash_word_break_class() -> String:
    """The word-break characters whose replacement region readline leaves empty.

    bash's default `COMP_WORDBREAKS` is `"'><=;|&(:` plus whitespace. With the
    cursor straight after one of these, `COMP_WORDS` still reports it as the
    current word while readline inserts rather than replaces, so a trim that
    subtracted it would leave it on the front of every candidate.

    The two quote characters are deliberately absent, and the exclusion is
    load-bearing rather than an oversight: readline keeps and dequotes a quote
    instead of discarding it, so its replacement region there is *not* empty.
    Measured against a real bash — with `"` in this set, `--report md:"` and a
    single match completes to `--report md:"md:onlyone.md"`, a second copy of
    the prefix; without it, to `--report md:"onlyone.md"`.

    Returns:
        The freshly allocated body of a bracket expression, safe to place
        between `[` and `]` in a bash pattern.
    """
    return ":=><;|&("


def _cmd_scoped_patterns(spec: FlagSpec) -> String:
    """The `cmd:prev` alternation that offers one flag's value.

    Every alternative pairs a head with the spelling, so a value arm can never
    fire under a command whose grammar refuses the flag.

    Args:
        spec: The flag row to scope. Not mutated.

    Returns:
        The freshly allocated alternation, or empty text for a row with no
        value worth completing.
    """
    if not _completes_a_value(spec):
        return String("")
    var alternatives = List[String]()
    for bit in _head_bits():
        if (spec.applicability & bit) == 0:
            continue
        alternatives.append(
            _bash_pattern(_head_name(bit) + ":" + spec.spelling)
        )
    return _joined_with(alternatives, "|")


def render_bash_completions() -> String:
    """Render the bash completion function over the two spec tables.

    Head resolution mirrors `parse_args` (the leading token, then the
    `--collect-only` refinement); value arms are keyed on `cmd:prev` so
    completion never offers a value for a flag the active command refuses; and
    every file completion rides a quoted read loop.

    Returns:
        The freshly allocated script text, ending in a newline.
    """
    var script = String("_mtest_reply() {\n")
    script += "  local _mtest_line\n"
    script += "  COMPREPLY=()\n"
    script += "  while IFS= read -r _mtest_line; do\n"
    script += '    COMPREPLY+=("$_mtest_line")\n'
    script += "  done\n"
    script += "}\n"
    # COMP_WORDS is split at every COMP_WORDBREAKS character, and that set
    # contains `:` — `--report md:pl` arrives as five words, so `prev` is `:`
    # and no value arm could ever fire a second time. Only the pieces that
    # were *adjacent* in COMP_LINE are re-joined, which is why the line is
    # consumed alongside the array rather than re-split: `-k a: b` is three
    # words and `md:pl` is one, and nothing but the whitespace between them
    # tells the two apart. readline's own array is kept because it is the
    # quote-aware one — each element is a raw slice of the line, so a
    # backslash-escaped space or a quoted path survives, and readline does not
    # split at a `:` inside quotes in the first place.
    script += "_mtest_words() {\n"
    script += '  local rest="$COMP_LINE" piece last i\n'
    script += "  lwords=()\n"
    script += "  index=0\n"
    script += "  for ((i = 0; i < ${#COMP_WORDS[@]}; i++)); do\n"
    script += '    piece="${COMP_WORDS[i]}"\n'
    script += "    last=${#lwords[@]}\n"
    script += '    if [ "$i" -gt 0 ] && [ "$last" -gt 0 ] &&'
    script += ' [[ "$rest" != [[:space:]]* ]]; then\n'
    script += '      lwords[last-1]+="$piece"\n'
    script += '      [ "$i" -eq "$COMP_CWORD" ] && index=$(( last - 1 ))\n'
    script += "    else\n"
    script += '      rest="${rest#"${rest%%[![:space:]]*}"}"\n'
    script += '      lwords+=("$piece")\n'
    script += '      [ "$i" -eq "$COMP_CWORD" ] && index=$last\n'
    script += "    fi\n"
    script += '    rest="${rest#"$piece"}"\n'
    script += "  done\n"
    script += "}\n"
    # A candidate is the whole logical word, so whatever readline is going to
    # keep on the line has to come off the front of every candidate. That is
    # the difference between the logical word and readline's own, which is
    # exact in both directions: an unsplit word leaves nothing to trim, so a
    # quoted `"md:my rep` is completed whole, while a split `md:pl` leaves
    # `md:` that would otherwise be inserted after the `md:` already typed.
    #
    # The exception is a cursor sitting straight after a word-break character.
    # `COMP_WORDS` still reports that character as the current word, but
    # readline's replacement region there is EMPTY — it inserts rather than
    # replaces — so subtracting it would leave one on the front of every
    # candidate. Nothing survives on the line, so the whole logical word comes
    # off.
    script += "_mtest_trim_to_replaced() {\n"
    script += '  local replaced="$2" keep i\n'
    script += (
        '  [ -z "${replaced//['
        + _bash_word_break_class()
        + ']/}" ] && replaced=""\n'
    )
    script += '  keep="${1%"$replaced"}"\n'
    script += '  [ -z "$keep" ] && return\n'
    script += "  for ((i = 0; i < ${#COMPREPLY[@]}; i++)); do\n"
    script += '    COMPREPLY[i]="${COMPREPLY[i]#"$keep"}"\n'
    script += "  done\n"
    script += "}\n"
    script += "_mtest_complete() {\n"
    script += "  local cur prev cmd word index\n"
    script += "  local -a lwords\n"
    script += "  _mtest_words\n"
    script += '  cur="${lwords[index]-}"\n'
    script += '  prev=""\n'
    script += '  [ "$index" -gt 0 ] && prev="${lwords[index-1]-}"\n'
    script += '  cmd="run"\n'
    script += '  case "${lwords[1]-}" in\n'
    for head in _subcommand_word_list():
        var state = _head_state(head)
        if state == "none":
            continue
        if head == "config":
            # The sole two-token subcommand: pending until `show` arrives.
            # The resolved state is still the row's, only the waiting one is
            # this script's own.
            script += "    " + _bash_pattern(head) + ")\n"
            script += '      if [ "${lwords[2]-}" = "show" ]; then\n'
            script += '        cmd="' + _bash_word(state) + '"\n'
            script += "      else\n"
            script += '        cmd="config-pending"\n'
            script += "      fi ;;\n"
            continue
        script += (
            "    "
            + _bash_pattern(head)
            + ') cmd="'
            + _bash_word(state)
            + '" ;;\n'
        )
    var none_patterns = List[String]()
    for token in _none_tokens():
        none_patterns.append(_bash_pattern(token))
    script += "    " + _joined_with(none_patterns, "|") + ') cmd="none" ;;\n'
    script += "  esac\n"
    # The effective head: a run carrying --collect-only is a collection, so it
    # gains --format and loses every flag that mode refuses.
    script += '  if [ "$cmd" = "run" ]; then\n'
    script += '    for word in "${lwords[@]}"; do\n'
    script += (
        '      if [ "$word" = "'
        + _bash_word(_spelling_of(FlagId.COLLECT_ONLY))
        + '" ]; then\n'
    )
    script += '        cmd="collect"\n'
    script += "        break\n"
    script += "      fi\n"
    script += "    done\n"
    script += "  fi\n"
    script += '  case "$cmd:$prev" in\n'
    for spec in flag_specs():
        var arms = _cmd_scoped_patterns(spec)
        if arms.byte_length() == 0:
            continue
        script += "    " + arms + ")\n"
        if spec.value_kind == ValueKind.PATH:
            script += "      compopt -o filenames\n"
            script += '      _mtest_reply < <(compgen -f -- "$cur")\n'
        elif spec.value_kind == ValueKind.PREFIX_CHOICE:
            script += '      if [[ "$cur" == *:* ]]; then\n'
            script += '        local pfx="${cur%%:*}:" rest="${cur#*:}"\n'
            # Whether readline split this word decides what survives the trim
            # below, and a candidate that keeps its prefix is not a filename:
            # asking bash to requote one as a filename escapes the quote a
            # user typed and corrupts the word.
            script += (
                '        if [ "$cur" = "${COMP_WORDS[COMP_CWORD]}" ]; then\n'
            )
            script += "          compopt -o nospace\n"
            script += "        else\n"
            script += "          compopt -o filenames\n"
            script += "        fi\n"
            script += (
                '        _mtest_reply < <(compgen -P "$pfx" -f -- "$rest")\n'
            )
            script += "      else\n"
            # Only the prefix list takes `nospace`: a completed prefix has to
            # stay open for the path after it, while a completed path is a
            # finished word and wants its space like any other.
            script += "        compopt -o nospace\n"
            script += (
                '        COMPREPLY=($(compgen -W "'
                + _compgen_wordlist(spec.choices)
                + '" -- "$cur"))\n'
            )
            script += "      fi\n"
            script += (
                '      _mtest_trim_to_replaced "$cur"'
                ' "${COMP_WORDS[COMP_CWORD]}"\n'
            )
        else:
            script += (
                '      COMPREPLY=($(compgen -W "'
                + _compgen_wordlist(spec.choices)
                + '" -- "$cur"))\n'
            )
        script += "      return ;;\n"
    script += "  esac\n"
    script += '  if [ "$index" -eq 1 ]; then\n'
    var head_words = _subcommand_word_list()
    head_words.extend(_flag_words_for(Subcommand.RUN))
    script += (
        '    _mtest_reply < <(compgen -W "'
        + _compgen_wordlist(head_words)
        + '" -f -- "$cur")\n'
    )
    script += "    return\n"
    script += "  fi\n"
    script += '  case "$cmd" in\n'
    for bit in _head_bits():
        var files = " -f" if bit != Subcommand.DOCTOR else ""
        script += (
            "    "
            + _head_name(bit)
            + ') _mtest_reply < <(compgen -W "'
            + _compgen_wordlist(_flag_words_for(bit))
            + '"'
            + files
            + ' -- "$cur") ;;\n'
        )
    script += '    config-pending) COMPREPLY=($(compgen -W "show"'
    script += ' -- "$cur")) ;;\n'
    script += (
        '    completions) COMPREPLY=($(compgen -W "'
        + _compgen_wordlist(completion_shells())
        + '" -- "$cur")) ;;\n'
    )
    script += "    none) COMPREPLY=() ;;\n"
    script += "  esac\n"
    script += "}\n"
    script += "complete -F _mtest_complete mtest\n"
    return script^


# --- zsh ------------------------------------------------------------------ #


def _zsh_spec(spec: FlagSpec) -> String:
    """One `_arguments` specification for one spelling.

    Args:
        spec: The flag row to render. Not mutated.

    Returns:
        The freshly allocated, single-quoted specification.
    """
    var body = String("*") if spec.repeatable else String("")
    body += spec.spelling + "[" + _zsh_description(spec.help) + "]"
    if spec.arity == 1:
        body += ":" + _zsh_message(spec.value_name) + ":"
        if spec.value_kind == ValueKind.PATH:
            body += "_files"
        elif spec.value_kind == ValueKind.PREFIX_CHOICE:
            # A bare function name, the form `_files` itself uses. The inline
            # `{…}` alternative is evaluated by `_arguments` as shell code —
            # the one position in this module where an escaping slip would be
            # command execution rather than a wrong candidate — and it also
            # cannot hold this action at all: `_arguments` splits a spec on
            # every unescaped colon, and a prefix action is made of colons.
            body += _zsh_helper_name(spec.spelling)
        elif len(spec.choices) != 0:
            body += "(" + _joined(_zsh_action_words(spec.choices)) + ")"
    return _zsh_quoted(body)


def _zsh_helper_name(spelling: String) -> String:
    """The zsh completion function generated for one prefix-choice spelling.

    Args:
        spelling: The flag spelling the helper serves.

    Returns:
        A freshly allocated identifier: every codepoint outside `[A-Za-z0-9]`
        becomes an underscore, so any spelling yields a name zsh can define.
    """
    var out = String("_mtest_prefix")
    for cp in spelling.codepoints():
        var code = Int(cp)
        if (
            (code >= 48 and code <= 57)
            or (code >= 65 and code <= 90)
            or (code >= 97 and code <= 122)
        ):
            out += String(cp)
        else:
            out += "_"
    return out^


def _zsh_prefix_helpers() -> String:
    """The completion function each prefix-choice spelling dispatches to.

    A generated function body is ordinary shell code, so every value
    interpolated into one carries `_zsh_quoted` rather than the action-word
    escaping a `(…)` candidate list would take.

    Returns:
        The freshly allocated function definitions, in table order.
    """
    var out = String("")
    for spec in flag_specs():
        if spec.value_kind != ValueKind.PREFIX_CHOICE:
            continue
        var quoted = List[String]()
        for choice in spec.choices:
            quoted.append(_zsh_quoted(choice))
        out += _zsh_helper_name(spec.spelling) + "() {\n"
        out += "  if [[ $PREFIX == *:* ]]; then\n"
        # `compset -P` moves the typed prefix out of the way so `_files`
        # completes the path after the separator.
        out += "    compset -P '*:'\n"
        out += "    _files\n"
        out += "  else\n"
        # `-S ''` is zsh's `nospace`: a prefix completed with a trailing space
        # could never be continued into the path that follows it.
        out += "    compadd -S '' -- " + _joined(quoted) + "\n"
        out += "  fi\n"
        out += "}\n"
    return out^


def _zsh_specs_for(subcommand: Int) -> String:
    """Every `_arguments` specification one head accepts, space separated.

    Args:
        subcommand: One of the `Subcommand` bit constants.

    Returns:
        The freshly allocated specification list, in table order.
    """
    var out = String("")
    for spec in flag_specs():
        if (spec.applicability & subcommand) == 0:
            continue
        if out.byte_length() != 0:
            out += " "
        out += _zsh_spec(spec)
    return out^


def render_zsh_completions() -> String:
    """Render the zsh completion function over the two spec tables.

    The head is resolved from `words[2]` alone and then refined by
    `--collect-only`, exactly as the bash script does and exactly as
    `parse_args` reads it; each head dispatches to its own `_arguments` call,
    so a spelling a command refuses is never a specification that command sees.

    Returns:
        The freshly allocated script text, ending in a newline.
    """
    var script = String("#compdef mtest\n")
    script += _zsh_prefix_helpers()
    script += "_mtest() {\n"
    script += "  local cmd word\n"
    script += "  local -a heads\n"
    var heads = List[String]()
    for spec in subcommand_specs():
        heads.append(
            _zsh_quoted(
                _zsh_message(spec.token) + ":" + _zsh_message(spec.description)
            )
        )
    script += "  heads=(" + _joined(heads) + ")\n"
    script += "  cmd=run\n"
    script += '  case "${words[2]-}" in\n'
    for head in _subcommand_word_list():
        var state = _head_state(head)
        if state == "none":
            continue
        if head == "config":
            script += "    " + _zsh_quoted(head) + ")\n"
            script += '      if [[ "${words[3]-}" == show ]]; then\n'
            script += "        cmd=" + _zsh_quoted(state) + "\n"
            script += "      else\n"
            script += "        cmd='config-pending'\n"
            script += "      fi ;;\n"
            continue
        script += (
            "    " + _zsh_quoted(head) + ") cmd=" + _zsh_quoted(state) + " ;;\n"
        )
    var none_patterns = List[String]()
    for token in _none_tokens():
        none_patterns.append(_zsh_quoted(token))
    script += "    " + _joined_with(none_patterns, "|") + ") cmd=none ;;\n"
    script += "  esac\n"
    # A literal comparison rather than a `${words[(I)…]}` subscript, which
    # would read the spelling as a pattern.
    script += "  if [[ $cmd == run ]]; then\n"
    script += "    for word in $words; do\n"
    script += (
        "      if [[ $word == "
        + _zsh_quoted(_spelling_of(FlagId.COLLECT_ONLY))
        + " ]]; then\n"
    )
    script += "        cmd=collect\n"
    script += "        break\n"
    script += "      fi\n"
    script += "    done\n"
    script += "  fi\n"
    script += "  if (( CURRENT == 2 )); then\n"
    script += "    _describe -t commands 'mtest subcommand' heads\n"
    script += "  fi\n"
    script += "  case $cmd in\n"
    for bit in _head_bits():
        var operand = String("")
        if bit == Subcommand.DEBUG:
            operand = " '*:node id:_files'"
        elif bit != Subcommand.DOCTOR:
            operand = " '*:path:_files'"
        script += (
            "    "
            + _head_name(bit)
            + ") _arguments -S : "
            + _zsh_specs_for(bit)
            + operand
            + " ;;\n"
        )
    script += "    config-pending) _values 'subcommand' 'show' ;;\n"
    var shells = List[String]()
    for shell in completion_shells():
        shells.append(_zsh_quoted(_zsh_action_word(shell)))
    script += "    completions) _values 'shell' " + _joined(shells) + " ;;\n"
    script += "    none) return 1 ;;\n"
    script += "  esac\n"
    script += "}\n"
    # Sourced through `eval`, the function has to be registered; autoloaded
    # from `fpath` under its `#compdef` tag, it has to be called instead.
    script += 'if [ "${funcstack[1]-}" = "_mtest" ]; then\n'
    script += '  _mtest "$@"\n'
    script += "else\n"
    script += "  compdef _mtest mtest\n"
    script += "fi\n"
    return script^


# --- fish ----------------------------------------------------------------- #


def _fish_value_options(spec: FlagSpec) -> String:
    """The `complete` options that describe one spelling's value.

    Args:
        spec: The flag row to render. Not mutated.

    Returns:
        The freshly allocated option text, empty for an arity-zero flag. `-r`
        requires a value and leaves fish's default file completion in place;
        `-x` requires one and suppresses files, which is what a closed list and
        an unguessable free value both want.
    """
    if spec.arity == 0:
        return String("")
    if spec.value_kind == ValueKind.PATH:
        return " -r"
    if spec.value_kind == ValueKind.PREFIX_CHOICE:
        # A `complete -a` rule supplies whole words, so the candidate is the
        # whole `PREFIX:PATH` and one rule covers both steps. The parentheses
        # stay live on purpose — this is a command substitution — so the
        # arguments inside them carry the expansion escaping.
        var escaped = List[String]()
        for choice in spec.choices:
            escaped.append(_fish_expansion_word(choice))
        return " -x -a " + _fish_quoted(
            "(__mtest_prefixed_path " + _joined(escaped) + ")"
        )
    if len(spec.choices) == 0:
        return " -x"
    return " -x -a " + _fish_argument_list(spec.choices)


def render_fish_completions() -> String:
    """Render the fish completion rules over the two spec tables.

    Fish has no per-invocation completion function, so the head resolution the
    other two scripts run inline becomes `__mtest_head`, and every rule is
    conditioned on it. The condition is what makes the rules command-scoped:
    a spelling gets one `complete` line per head whose mask accepts it, and
    none for a head that refuses it.

    Returns:
        The freshly allocated script text, ending in a newline.
    """
    var script = String("function __mtest_head\n")
    script += "    set -l parts (commandline -opc)\n"
    script += "    set -l head run\n"
    script += "    if set -q parts[2]\n"
    script += '        switch "$parts[2]"\n'
    for head in _subcommand_word_list():
        var state = _head_state(head)
        if state == "none":
            continue
        if head == "config":
            script += "            case " + _fish_quoted(head) + "\n"
            script += (
                '                if set -q parts[3]; and test "$parts[3]"'
                " = show\n"
            )
            script += (
                "                    set head " + _fish_quoted(state) + "\n"
            )
            script += "                else\n"
            script += "                    set head 'config-pending'\n"
            script += "                end\n"
            continue
        script += "            case " + _fish_quoted(head) + "\n"
        script += "                set head " + _fish_quoted(state) + "\n"
    var none_patterns = List[String]()
    for token in _none_tokens():
        none_patterns.append(_fish_quoted(token))
    script += "            case " + _joined(none_patterns) + "\n"
    script += "                set head none\n"
    script += "        end\n"
    script += "    end\n"
    script += (
        '    if test "$head" = run; and contains -- '
        + _fish_quoted(_spelling_of(FlagId.COLLECT_ONLY))
        + " $parts\n"
    )
    script += "        set head collect\n"
    script += "    end\n"
    script += "    echo $head\n"
    script += "end\n"
    script += "function __mtest_head_is\n"
    script += '    test (__mtest_head) = "$argv[1]"\n'
    script += "end\n"
    # One rule rather than two stages: a fish completion is a whole word, so
    # the candidate carries its prefix. Measured against a real fish, a
    # completed prefix (`md:`) and a completed directory (`md:reports/`) are
    # both left without a trailing space, so the word stays continuable and
    # the second step needs no rule of its own.
    script += "function __mtest_prefixed_path\n"
    script += "    set -l token (commandline -ct)\n"
    script += "    if not string match -q -- '*:*' $token\n"
    script += "        printf '%s\\n' $argv\n"
    script += "        return\n"
    script += "    end\n"
    script += "    set -l prefix (string replace -r ':.*' ':' -- $token)\n"
    script += "    set -l rest (string replace -r '^[^:]*:' '' -- $token)\n"
    script += "    for entry in (__fish_complete_path $rest)\n"
    script += "        set -l fields (string split -m1 \\t -- $entry)\n"
    script += "        printf '%s%s\\n' $prefix $fields[1]\n"
    script += "    end\n"
    script += "end\n"
    for spec in subcommand_specs():
        script += (
            "complete -c mtest -n '__fish_use_subcommand' -a "
            + _fish_argument_list([spec.token.copy()])
            + " -d "
            + _fish_quoted(spec.description)
            + "\n"
        )
    script += (
        "complete -c mtest -n '__mtest_head_is config-pending' -f -a 'show' -d "
        + _fish_quoted(_config_description())
        + "\n"
    )
    script += (
        "complete -c mtest -n '__mtest_head_is completions' -f -a "
        + _fish_argument_list(completion_shells())
        + "\n"
    )
    script += "complete -c mtest -n '__mtest_head_is doctor' -f\n"
    script += "complete -c mtest -n '__mtest_head_is none' -f\n"
    for spec in flag_specs():
        for bit in _head_bits():
            if (spec.applicability & bit) == 0:
                continue
            script += (
                "complete -c mtest -n '__mtest_head_is "
                + _head_name(bit)
                + "' "
                + _fish_flag_token(spec.spelling)
                + _fish_value_options(spec)
                + " -d "
                + _fish_quoted(spec.help)
                + "\n"
            )
    return script^
