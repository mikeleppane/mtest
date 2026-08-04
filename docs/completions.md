# Shell completion

`mtest completions bash|zsh|fish` prints a completion script for one shell to
stdout and stops. No configuration is read, no toolchain is resolved, and no
file is written: where the script goes is your decision, and the answer differs
per shell.

## Installing it

In bash, source it into the shell you are in, or write it into the directory
`bash-completion` loads from on demand, where the file is named after the
command it completes:

```console
$ eval "$(mtest completions bash)"
$ mtest completions bash > ~/.local/share/bash-completion/completions/mtest
```

The zsh script begins with `#compdef mtest`, which makes it an autoloadable
completion function rather than something to source: it belongs in a directory
on `$fpath` under the name `_mtest`, and that directory has to be on `$fpath`
before `compinit` runs.

```console
$ mkdir -p ~/.zsh/completions
$ mtest completions zsh > ~/.zsh/completions/_mtest
```

```zsh
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit && compinit
```

`eval "$(mtest completions zsh)"` also works, for the shell you are in, but
only after `compinit` has run: sourced rather than autoloaded, the script
registers itself with `compdef`, which does not exist before then.

Fish loads a completion file by the command it names, so one redirect into its
completions directory is the whole installation:

```console
$ mtest completions fish > ~/.config/fish/completions/mtest.fish
```

Each script is rendered from the binary's own flag and subcommand tables, so a
script cannot offer a flag the binary that printed it refuses — and an
installed copy does not learn a new flag on its own. Regenerate it after
upgrading mtest.

## Which command is being completed

The script scopes what it offers to the command on the line, and resolves that
command the way the parser resolves it: from the leading word alone, because
that is the only position a subcommand is recognized in. `mtest -q doctor
<TAB>` is therefore completed as a *run* carrying `doctor` as a path operand,
which is what that command line would do if you executed it. One refinement
follows the parser too — a run whose words already contain `--collect-only` is
a collection, so it gains `--format` and loses the flags that mode refuses.

`config` is the one two-token subcommand: `mtest config <TAB>` offers exactly
`show`, because `mtest config` alone is a usage error. `new`, `init`, `help`,
and `version` offer nothing at all, and `doctor` offers its own flags and no
paths, because it takes no path operands.

## Which flags and values

Within a command you are offered only the flags that command accepts, and a
value only under a command that accepts the flag taking it: `mtest doctor
--report-style <TAB>` offers doctor's flags rather than `concise` and `full`,
because `doctor --report-style` is a usage error. Values follow their kind. A
closed set completes to its members, a path completes against the filesystem,
`--report FORMAT:PATH` completes the format prefix first and then a path after
the separator, and a value nothing can enumerate — a glob, an integer, a build
argument — completes to nothing rather than to a guess. `-I` sits in that last
group rather than with the paths: it refuses a Mojo source file, so completing
one would offer a value this build exits 4 on.

Which candidates a shell shows for a given prefix is a convenience rather than
part of the frozen contract; what is fixed is the grammar, the exit codes, and
that no script offers a flag, subcommand, or value this build refuses.

[§30 of the command-line
contract](cli-contract.md#30-shell-completion-mtest-completions-shell) is the
normative specification: the grammar, the exit codes, and what the three
scripts do and do not promise. The blocks on this page are mirrored byte for
byte from the [Shell completion section of the
README](https://github.com/mikeleppane/mtest#shell-completion), which is where
they are written down.
