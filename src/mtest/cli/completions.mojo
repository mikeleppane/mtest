"""Shell completion scripts, rendered from the two command-line spec tables.

`mtest completions SHELL` writes a script for `bash`, `zsh`, or `fish` to
stdout. Nothing here restates a command-line fact: the spellings, their help
text, their value placeholders, their closed choice lists, and which heads
accept them all come from `flag_specs()`, and the head vocabulary — including
which leading tokens accept no flag at all — comes from `subcommand_specs()`. A
flag added to the table is offered by all three scripts without touching this
module, which is the only arrangement in which a completion script cannot
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
a `PREFIX_CHOICE` becomes its prefixes and then a path after the separator, and
`OTHER` deliberately offers nothing, because a kind that cannot express what is
legal must not guess. One value the tables cannot express is `--json`'s bare
`-` for stdout; its row says why the kind stays `PATH`, and this module does
not invent a kind for it.

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
`-d` description — get the single level that position actually needs.

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
    """Every flag-accepting head, as its applicability bit, in help order."""
    return [
        Subcommand.RUN,
        Subcommand.COLLECT,
        Subcommand.CONFIG_SHOW,
        Subcommand.DOCTOR,
        Subcommand.DEBUG,
    ]


def _head_name(subcommand: Int) -> String:
    """The name the generated scripts give one applicability bit.

    Args:
        subcommand: One of the `Subcommand` bit constants.

    Returns:
        The freshly allocated script-side head name; `run` for anything the
        scripts do not name separately, which is what the parser's default
        subcommand means.
    """
    if subcommand == Subcommand.COLLECT:
        return "collect"
    if subcommand == Subcommand.CONFIG_SHOW:
        return "config-show"
    if subcommand == Subcommand.DOCTOR:
        return "doctor"
    if subcommand == Subcommand.DEBUG:
        return "debug"
    return "run"


def _head_state(token: String) -> String:
    """The completion state one leading token selects.

    This is the token-to-head mapping `parse_args` performs, and it is prose
    rather than a table field: `config` names a two-token subcommand, and
    `new`, `init`, `help`, and `version` have no flag table for a bit to
    describe. Everything not named here therefore falls to `none`, which is
    what makes a subcommand added to `subcommand_specs()` offer nothing after
    its head token rather than silently inheriting the run grammar.

    Args:
        token: A leading token from `subcommand_specs()`.

    Returns:
        The freshly allocated script-side state name.
    """
    if token == "run":
        return "run"
    if token == "collect":
        return "collect"
    if token == "config":
        return "config-show"
    if token == "doctor":
        return "doctor"
    if token == "debug":
        return "debug"
    if token == "completions":
        return "completions"
    return "none"


def _none_tokens() -> List[String]:
    """Every head token after which nothing is offered, in table order."""
    var tokens = List[String]()
    for spec in subcommand_specs():
        if _head_state(spec.token) == "none":
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
    script += "_mtest_complete() {\n"
    script += "  local cur prev cmd word\n"
    script += '  cur="${COMP_WORDS[COMP_CWORD]}"\n'
    script += '  prev="${COMP_WORDS[COMP_CWORD-1]}"\n'
    script += '  cmd="run"\n'
    script += '  case "${COMP_WORDS[1]-}" in\n'
    for head in _subcommand_word_list():
        var state = _head_state(head)
        if state == "none":
            continue
        if head == "config":
            # The sole two-token subcommand: pending until `show` arrives.
            script += "    config)\n"
            script += '      if [ "${COMP_WORDS[2]-}" = "show" ]; then\n'
            script += '        cmd="config-show"\n'
            script += "      else\n"
            script += '        cmd="config-pending"\n'
            script += "      fi ;;\n"
            continue
        script += "    " + head + ') cmd="' + state + '" ;;\n'
    script += "    " + _joined_with(_none_tokens(), "|") + ') cmd="none" ;;\n'
    script += "  esac\n"
    # The effective head: a run carrying --collect-only is a collection, so it
    # gains --format and loses every flag that mode refuses.
    script += '  if [ "$cmd" = "run" ]; then\n'
    script += '    for word in "${COMP_WORDS[@]}"; do\n'
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
            # Without `nospace` a unique prefix is completed with a trailing
            # space, and the path after the separator becomes unreachable.
            script += "      compopt -o nospace\n"
            script += '      if [[ "$cur" == *:* ]]; then\n'
            script += '        local pfx="${cur%%:*}:" rest="${cur#*:}"\n'
            script += (
                '        _mtest_reply < <(compgen -P "$pfx" -f -- "$rest")\n'
            )
            script += "      else\n"
            script += (
                '        COMPREPLY=($(compgen -W "'
                + _compgen_wordlist(spec.choices)
                + '" -- "$cur"))\n'
            )
            script += "      fi\n"
        else:
            script += (
                '      COMPREPLY=($(compgen -W "'
                + _compgen_wordlist(spec.choices)
                + '" -- "$cur"))\n'
            )
        script += "      return ;;\n"
    script += "  esac\n"
    script += '  if [ "$COMP_CWORD" -eq 1 ]; then\n'
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
        var words = List[String]()
        for choice in spec.choices:
            words.append(_zsh_action_word(choice))
        if spec.value_kind == ValueKind.PATH:
            body += "_files"
        elif spec.value_kind == ValueKind.PREFIX_CHOICE:
            # `compadd -S ''` is zsh's `nospace`: the path after the separator
            # is only reachable while the prefix carries no trailing space.
            body += '{compadd -S "" -- ' + _joined(words) + "}"
        elif len(words) != 0:
            body += "(" + _joined(words) + ")"
    return _zsh_quoted(body)


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
    script += "_mtest() {\n"
    script += "  local cmd\n"
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
            script += "    config)\n"
            script += '      if [[ "${words[3]-}" == show ]]; then\n'
            script += "        cmd=config-show\n"
            script += "      else\n"
            script += "        cmd=config-pending\n"
            script += "      fi ;;\n"
            continue
        script += "    " + head + ") cmd=" + state + " ;;\n"
    script += "    " + _joined_with(_none_tokens(), "|") + ") cmd=none ;;\n"
    script += "  esac\n"
    script += "  if [[ $cmd == run ]] &&"
    script += (
        " (( ${words[(I)" + _spelling_of(FlagId.COLLECT_ONLY) + "]} )); then\n"
    )
    script += "    cmd=collect\n"
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
        return " -r -a " + _fish_argument_list(spec.choices)
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
            script += "            case config\n"
            script += (
                '                if set -q parts[3]; and test "$parts[3]"'
                " = show\n"
            )
            script += "                    set head config-show\n"
            script += "                else\n"
            script += "                    set head config-pending\n"
            script += "                end\n"
            continue
        script += "            case " + head + "\n"
        script += "                set head " + state + "\n"
    script += "            case " + _joined(_none_tokens()) + "\n"
    script += "                set head none\n"
    script += "        end\n"
    script += "    end\n"
    script += (
        '    if test "$head" = run; and contains -- '
        + _spelling_of(FlagId.COLLECT_ONLY)
        + " $parts\n"
    )
    script += "        set head collect\n"
    script += "    end\n"
    script += "    echo $head\n"
    script += "end\n"
    script += "function __mtest_head_is\n"
    script += '    test (__mtest_head) = "$argv[1]"\n'
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
