# Run reports

A JUnit file is for a CI system and an NDJSON stream is for a program.
`--report FORMAT:PATH` writes the same run for a person: one self-contained
document, `md` for a pull-request comment or a job summary, `html` for an
artifact a browser opens with no network access at all. Both are assembled
from the runner's own typed events, exactly as the JUnit report is, never from
a parse of the console text.

## Writing one

The flag is repeatable once per format, so a single run composes both
documents. A second destination for a format already given is a usage error
rather than a silent last-wins:

```console
$ pixi run bash -c 'build/mtest e2e/suite --report md:build/report.md --report html:build/report.html'
[...the run's usual console output, unchanged by the two reports, then:...]
$ echo $?
1
```

The console is unchanged: a report is written beside it, never instead of it,
and the exit code stays the run's own — the `1` above is the failing suite,
not the reports.

## What the document says

It opens with its title, the version and the platform, then one line naming
which of its paths are relative to the run root — the ones it composes itself,
including a failure detail's `At` line, but not the captured output or the
`build:` command it reproduces as they were produced. The run's facts follow:
the wall time, the test and file counts, and each of builds, flaky files,
workers, shuffle seed, shard, interrupt and drift that applied. Then a summary
table, one row per file:

```markdown
| Path | Outcome | Duration (s) | Passed | Failed | Skipped | Attempts |
| --- | --- | --- | --- | --- | --- | --- |
| e2e/suite/nested/test_nested.mojo | PASS | 0.017 | 1 | 0 | 0 | 1 |
| e2e/suite/test_compile_error.mojo | COMPILE_ERROR | 0.000 | 0 | 0 | 0 | 1 |
| e2e/suite/test_crashing.mojo | CRASH | 1.117 | 0 | 0 | 0 | 1 |
| e2e/suite/test_failing.mojo | FAIL | 0.027 | 2 | 1 | 0 | 1 |
| e2e/suite/test_noisy.mojo | PASS | 0.038 | 3 | 0 | 0 | 1 |
| e2e/suite/test_passing.mojo | PASS | 0.031 | 3 | 0 | 0 | 1 |
| e2e/suite/test_zero.mojo | PASS | 0.027 | 0 | 0 | 0 | 1 |
```

Below the table, a section per file that needs a second look carries the
failed tests with their detail, the captured streams, the build command, and
the reproduce and debug commands for that file. The compiler bakes an absolute
path into a backtrace; the report rewrites that line against the run root, so
it reads the same from any checkout:

````markdown
## `e2e/suite/test_failing.mojo` — FAIL

### FAIL `e2e/suite/test_failing.mojo::test_second_fails`

```
At e2e/suite/test_failing.mojo:14:17: AssertionError: `left == right` comparison failed:
   left: 1
  right: 2
```
````

A `Not run` list names every selected file that never ran and why, and the
document closes with a flat machine index: one line per row that needs action,
each already a command to paste back:

```markdown
## Machine index

- `e2e/suite/test_compile_error.mojo` — COMPILE_ERROR
- `e2e/suite/test_crashing.mojo` — CRASH
- `e2e/suite/test_failing.mojo::test_second_fails` — FAIL
```

## How much detail

`--report-style STYLE` chooses how much of that a document carries. Under
`concise`, the default, every file earns a summary row and only a file that
needs a second look earns a section; under `full`, every file earns both. The
flag is inert without a `--report` destination: supplying it alone is accepted
and changes nothing.

## Destinations, and the two ways they fail

There is no `-` stdout form. A document is assembled in a unique temp in the
target directory and renamed onto `PATH` at the end, so nothing at `PATH` is
touched until the rename and a prior report survives a failed run. That temp
is created at session start, before anything is built, which is what proves
the directory writable early; the parent directory itself must already exist.

Every active file destination — `--json PATH`, `--junit-xml PATH`, and both
`--report` paths — must name a different file, compared by resolved identity
rather than by spelling, so `out.md` and `./out.md` are the one destination
they are. Two of them naming one file is a usage error caught before the run
(exit `4`), because otherwise which writer's work survived would depend on
finalization order.

A report that was requested and could not be published — a destination that
cannot be prepared at session start, or a document that cannot be written,
closed, or renamed at the end — is an error in its own right, so it escalates
even a green run to exit `3`. The two sinks are independent: a Markdown
failure never stops the HTML document from publishing, and neither ever
replaces the report at the other's target.

[§15.5 of the command-line contract](cli-contract.md#155-run-report-report-formatpath-report-style-style)
is the normative specification: the grammar, the document's parts, and every
one of those refusals. The blocks on this page are mirrored byte for byte from
the [Run reports section of the
README](https://github.com/mikeleppane/mtest#run-reports), which is where they
are written down.
