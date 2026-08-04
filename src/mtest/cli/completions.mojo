"""Shell completion scripts, rendered from the two command-line spec tables.

`mtest completions SHELL` writes a script for `bash`, `zsh`, or `fish` to
stdout. Nothing here restates a command-line fact: the spellings, their help
text, their value placeholders, their closed choice lists, and which heads
accept them all come from `flag_specs()`, and the head vocabulary comes from
`subcommand_specs()`. A flag added to the table is offered by all three scripts
without touching this module, which is the only arrangement in which a
completion script cannot quietly drift from the parser it describes.

Head resolution mirrors `parse_args` exactly, and that is the subtle part. The
parser recognizes a subcommand **only as the leading token**, so `mtest -q
doctor` is a run carrying a `doctor` path operand; a script that scanned the
words for the first non-flag token would complete it as the doctor subcommand
and lie. The leading token therefore decides the head, and one refinement turns
it into the *effective* head: a `run` whose argv already carries
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

These scripts are `eval`'d into an interactive shell, so every value that
reaches one is escaped for the position it lands in — a bash double-quoted
word, a bash `case` pattern, a zsh bracketed description, a zsh
colon-delimited field, or a fish single-quoted string — and every file
completion rides a quoted read loop, because an unquoted
`COMPREPLY=($(compgen -f …))` word-splits a filename containing a space.
"""
from mtest.cli.flag_spec import (
    FlagSpec,
    Subcommand,
    ValueKind,
    flag_specs,
    subcommand_specs,
)


def completion_shells() -> List[String]:
    """The shells `mtest completions` renders a script for.

    The parser validates its operand against this list and the renderer
    dispatches on it, so the accepted vocabulary and the served vocabulary are
    the same list rather than two that agree today.

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


def _joined(values: List[String]) -> String:
    """Join `values` with single spaces.

    Args:
        values: The words to join. Not mutated.

    Returns:
        The freshly allocated joined text, empty for an empty list.
    """
    var out = String("")
    for value in values:
        if out.byte_length() != 0:
            out += " "
        out += String(value)
    return out^


def _flags_for(subcommand: Int) -> String:
    """Every spelling whose applicability mask includes `subcommand`.

    Args:
        subcommand: One of the `Subcommand` bit constants.

    Returns:
        The freshly allocated space-separated word list, in table order.
    """
    var words = List[String]()
    for spec in flag_specs():
        if (spec.applicability & subcommand) != 0:
            words.append(spec.spelling.copy())
    return _joined(words)


def _subcommand_words() -> String:
    """The head tokens, as the space-separated word list scripts offer."""
    var words = List[String]()
    for spec in subcommand_specs():
        words.append(spec.token.copy())
    return _joined(words)


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


def _bash_word(value: String) -> String:
    """Escape `value` for the inside of a bash double-quoted string.

    The four bytes that keep their meaning between double quotes are the ones
    escaped: a backslash, a double quote, a dollar sign, and a backtick. Every
    other byte is already literal there.

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


def _zsh_description(text: String) -> String:
    """Escape `text` for a zsh `_arguments` bracketed description.

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
    """Escape `text` for one word of a zsh `(...)` completion action.

    Args:
        text: The candidate value to embed. Not mutated.

    Returns:
        The freshly allocated text, with the backslash, the colon, the
        parenthesis pair, and the space escaped so one word stays one word.
    """
    var out = String("")
    for cp in text.codepoints():
        var code = Int(cp)
        if code == 92 or code == 58 or code == 40 or code == 41 or code == 32:
            out += "\\"
        out += String(cp)
    return out^


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
    bytes are escaped.

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
    var out = String("")
    for bit in _head_bits():
        if (spec.applicability & bit) == 0:
            continue
        if out.byte_length() != 0:
            out += "|"
        out += _bash_pattern(_head_name(bit) + ":" + spec.spelling)
    return out^


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
    script += '    collect) cmd="collect" ;;\n'
    script += "    config)\n"
    script += '      if [ "${COMP_WORDS[2]-}" = "show" ]; then\n'
    script += '        cmd="config-show"\n'
    script += "      else\n"
    script += '        cmd="config-pending"\n'
    script += "      fi ;;\n"
    script += '    doctor) cmd="doctor" ;;\n'
    script += '    debug) cmd="debug" ;;\n'
    script += '    completions|help|init|new|version) cmd="none" ;;\n'
    script += "  esac\n"
    # The effective head: a run carrying --collect-only is a collection, so it
    # gains --format and loses every flag that mode refuses.
    script += '  if [ "$cmd" = "run" ]; then\n'
    script += '    for word in "${COMP_WORDS[@]}"; do\n'
    script += '      if [ "$word" = "--collect-only" ]; then\n'
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
            script += '      _mtest_reply < <(compgen -f -- "$cur")\n'
        elif spec.value_kind == ValueKind.PREFIX_CHOICE:
            script += '      if [[ "$cur" == *:* ]]; then\n'
            script += '        local pfx="${cur%%:*}:" rest="${cur#*:}"\n'
            script += (
                '        _mtest_reply < <(compgen -P "$pfx" -f -- "$rest")\n'
            )
            script += "      else\n"
            script += (
                '        COMPREPLY=($(compgen -W "'
                + _bash_word(_joined(spec.choices))
                + '" -- "$cur"))\n'
            )
            script += "      fi\n"
        else:
            script += (
                '      COMPREPLY=($(compgen -W "'
                + _bash_word(_joined(spec.choices))
                + '" -- "$cur"))\n'
            )
        script += "      return ;;\n"
    script += "  esac\n"
    script += '  if [ "$COMP_CWORD" -eq 1 ]; then\n'
    script += (
        '    _mtest_reply < <(compgen -W "'
        + _bash_word(_subcommand_words() + " " + _flags_for(Subcommand.RUN))
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
            + _bash_word(_flags_for(bit))
            + '"'
            + files
            + ' -- "$cur") ;;\n'
        )
    script += '    config-pending) COMPREPLY=($(compgen -W "show"'
    script += ' -- "$cur")) ;;\n'
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
        elif len(spec.choices) != 0:
            var words = List[String]()
            for choice in spec.choices:
                words.append(_zsh_action_word(choice))
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
    script += "    collect) cmd=collect ;;\n"
    script += "    config)\n"
    script += '      if [[ "${words[3]-}" == show ]]; then\n'
    script += "        cmd=config-show\n"
    script += "      else\n"
    script += "        cmd=config-pending\n"
    script += "      fi ;;\n"
    script += "    doctor) cmd=doctor ;;\n"
    script += "    debug) cmd=debug ;;\n"
    script += "    completions|help|init|new|version) cmd=none ;;\n"
    script += "  esac\n"
    script += "  if [[ $cmd == run ]] &&"
    script += " (( ${words[(I)--collect-only]} )); then\n"
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
    var choices = _joined(spec.choices)
    if spec.value_kind == ValueKind.PATH:
        return " -r"
    if spec.value_kind == ValueKind.PREFIX_CHOICE:
        return " -r -a " + _fish_quoted(choices)
    if choices.byte_length() == 0:
        return " -x"
    return " -x -a " + _fish_quoted(choices)


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
    script += "            case collect\n"
    script += "                set head collect\n"
    script += "            case config\n"
    script += (
        '                if set -q parts[3]; and test "$parts[3]" = show\n'
    )
    script += "                    set head config-show\n"
    script += "                else\n"
    script += "                    set head config-pending\n"
    script += "                end\n"
    script += "            case doctor\n"
    script += "                set head doctor\n"
    script += "            case debug\n"
    script += "                set head debug\n"
    script += "            case completions help init new version\n"
    script += "                set head none\n"
    script += "        end\n"
    script += "    end\n"
    script += (
        '    if test "$head" = run; and contains -- --collect-only $parts\n'
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
            + _fish_quoted(spec.token)
            + " -d "
            + _fish_quoted(spec.description)
            + "\n"
        )
    script += (
        "complete -c mtest -n '__mtest_head_is config-pending' -f -a 'show'"
        " -d 'Show resolved configuration.'\n"
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
