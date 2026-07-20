# Console ANSI captures

Committed, human-facing pictures of what the `mtest` console actually looks like
for representative runs. Each `*.ansi` file is the **raw byte stream** the binary
wrote to a real pseudo-terminal — ANSI color escapes included. View one with a
pager that interprets escapes:

```sh
less -R notes/console-captures/pass-pty.ansi
cat notes/console-captures/fail-pty.ansi        # a colour-capable terminal renders it
```

These are **documentation, not oracle fixtures.** Nothing in CI reads them, so an
incidental byte (a wall-clock time, a temp-dir name in a child's own echoed
output) never freezes a gate. They are here so a reviewer can see the design
language without standing up a terminal.

## What each capture shows

| File | Invocation (under a PTY) | Shows |
|------|--------------------------|-------|
| `pass-pty.ansi` | `mtest .` on an all-passing suite | Green `PASS` verdict line and green summary band — `--color auto` resolves ON because stdout is a TTY. |
| `fail-pty.ansi` | `mtest .` on a suite with one failing file | Red `FAIL` / green `PASS` verdict lines, the framed per-test failure section (verbatim assertion detail, root-relative `At` pointer, copy-pasteable `reproduce:` line), the file-scoped captured-output block, and the red summary band. |
| `fail-verbose-pty.ansi` | `mtest -v .` | Adds the per-file `build:` argv line and the `-v` per-test rows under each verdict line. |
| `fail-quiet-pty.ansi` | `mtest -q .` | `-q` suppresses the passing verdict line; the failing verdict, its section, and the summary still print. |
| `fail-nocolor-pty.ansi` | `mtest .` with `NO_COLOR=1`, still on a PTY | Proves `--color auto` honours `NO_COLOR` even on a terminal: the byte stream carries **zero** escape sequences while the layout is identical. |

The verdict tokens (`PASS`, `FAIL`, …) carry the meaning on their own; colour is
redundant reinforcement, never the sole signal — contrast `fail-pty.ansi` with
`fail-nocolor-pty.ansi`, which differ only in the escape bytes.

## Regenerating

```sh
pixi run build-bin                       # produce build/mtest
pixi run python -m scripts.pty_capture   # runs under the pixi env so `mojo` is on PATH
```

The harness (`scripts/pty_capture.py`) drives the built binary against tiny
throwaway suites it writes itself, over a real PTY, and rewrites the `*.ansi`
files here. The suite lives in a throwaway temp directory whose real path varies
per run and per machine, so the harness rewrites that ephemeral root to the
stable placeholder `<suite-root>` in every capture BEFORE writing — no
machine-specific or sandbox path is ever committed. Wall-clock timings still
reflect the generating run; that residual variance is expected and is exactly
why these are documentation, not wired into any check.

## Optional: PNG screenshots

Turning a capture into a PNG for a docs page is a maintainer's call, not part of
this repo's automation. Any terminal-to-image tool works, e.g. render a capture
in a terminal and screenshot it, or pipe it through a converter that understands
ANSI. This script only produces the text captures above.
