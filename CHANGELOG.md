# Changelog

Every released version of mtest, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the versioning
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) scoped to
the command-line contract, so the surfaces frozen in
[docs/cli-contract.md](docs/cli-contract.md) §20 are what the major version
protects.

Every entry names the Mojo toolchain its release was built against. mtest links
the Mojo runtime and parses `TestSuite`'s printed report, so a release supports
exactly one toolchain and there is no compatibility range; see the support
matrix under [Installation](README.md#installation).

## 1.1.0 — 2026-08-06

Additive throughout: every 1.0.0 invocation that had a defined meaning still
means what it meant. What is new is four subcommands, six flags, a
documentation site, and a composite GitHub Action. What is not additive sits
under Changed and Fixed: two argument vectors that had no defined meaning are
refused before a run now, and three defects an installed 1.0.0 still carries.

### Toolchain

- Mojo `1.0.0b2`, unchanged from 1.0.0. The conda package declares
  `mojo-compiler ==1.0.0b2` as its sole run dependency. A weekday canary now
  probes newer toolchains and records what each would break;
  [docs/compatibility.md](docs/compatibility.md) states what its results do and
  do not say about support.

### Platforms

- `linux-64` and `osx-arm64`. The package is built from source once per
  platform; there is no `noarch` artifact.

### Published

- Not yet. This subsection is filled in once **Community Verify** installs the
  release from the public channels, per
  [docs/releasing.md](docs/releasing.md).

### Command-line contract

- Growth is additive within 1.x, which is what §20 states rather than a freeze
  for the release series. Every subcommand 1.0.0 served keeps its name,
  grammar, and meaning; the bare subcommand *vocabulary* is the one declared
  exception, so reserving a new leading token is permitted.
- New STABLE surfaces, each recorded in §20: the `new`, `init`, `debug`, and
  `completions` subcommands; `collect --format json` at collect-stream
  `version` 1, growing additively under the same rule as the `--json` run
  stream; and the `--report`, `--report-style`, `--shuffle`, `--seed`, and
  `--fail-on-flaky` flags.

### Added

- `--report FORMAT:PATH`, writing a self-contained Markdown or HTML run report
  ([§15.5](docs/cli-contract.md), [docs/reports.md](docs/reports.md)). Both
  formats may be requested at once, `--report-style` chooses between the
  concise and the full document, and the HTML one embeds its own styling so it
  needs no network. A destination is prepared before the run and published by
  rename, so a run either delivers every artifact it was asked for or exits
  nonzero saying which it could not.
- `mtest completions bash|zsh|fish`, writing a completion script to stdout
  ([§30](docs/cli-contract.md),
  [docs/completions.md](docs/completions.md)). Every fact in the script — the
  subcommand vocabulary, each flag spelling, its description, its value
  placeholder, and its closed value set — is rendered from the same tables the
  parser uses, so a script cannot offer a flag or value this build refuses.
  Nothing changes for a user who never runs the subcommand, other than that a
  directory named `completions` is now shadowed by it at the leading position,
  which is the documented policy for every head token (§3).
  - Known limit, deferred deliberately: in a directory holding one named after
    a head token — `config/` and `run/` are ordinary project directories —
    completing that token can insert `run/` rather than the bare token, which
    is a run with a path operand rather than the subcommand. Which candidates
    a shell shows is INFORMAL (§20), and the fix changes what the mixed
    subcommand-and-path arm offers, so it is being taken on its own.
- `mtest new` and `mtest init`, writing source for the first time
  ([§29](docs/cli-contract.md)). `new` writes one test file; `init` writes the
  whole starting project — a test, an `mtest.toml`, a `.gitignore` entry, and
  optionally a CI workflow. Neither ever replaces a file that is already
  there, and each artifact is published or refused on its own, so a partial
  run says which artifacts it wrote. The scaffolded workflow is held
  byte-identical to the first YAML block of
  [the continuous-integration page](docs/ci.md), third-party action pins
  included, so a pin that moves in the documentation moves in the scaffold.
- `mtest debug path::test`, handing the terminal to one test
  ([§28](docs/cli-contract.md)). It prepares that test exactly as a run would,
  prints the `build:` and `run:` commands it used, then replaces itself with
  the test binary and gets out of the way: no capture pipe, no summary, no
  mtest verdict, and the test's own exit status is the process's.
- `collect --format json`, serving the `collect` listing as a versioned NDJSON
  stream ([§16](docs/cli-contract.md); normatively
  [docs/collect-stream.md](docs/collect-stream.md)). Held at collect-stream
  `version` 1 and growing only additively, on the same rule as the `--json`
  run stream. `--format lines` is the default and prints exactly what 1.0.0
  printed.
- `--shuffle` and `--seed N`, for the suite that only passes in one order
  ([§17](docs/cli-contract.md), §18). `--shuffle` randomizes run-file order
  and prints the seed it drew; `--seed N` replays it, and one seed names one
  permutation of one file list byte-identically on every platform, so a
  printed seed reproduces the order that produced a failure. Gate files keep
  their listed order, and every other surface — the console summary, the
  reporters, the `collect` listing — stays node-id sorted. `--seed` without
  `--shuffle` is a usage error (exit 4), and so is `--shuffle` beside
  `--lf`/`--ff`, which choose a conflicting order. Command line only; it is
  never read from `mtest.toml`.
- `--fail-on-flaky`, turning a FLAKY-only session's `0` into a `1`
  ([§13](docs/cli-contract.md), §9) for a pipeline that will not tolerate a
  pass that needed retries. Its position in the exit precedence is part of the
  contract; the JUnit document stays green beside the process that exits 1.
- A composite GitHub Action at the repository root. `uses: mikeleppane/mtest@v1`
  with `paths` and `args` replaces writing the invocation out; `args` is
  appended verbatim, so every flag stays reachable and none is promoted to an
  input of its own. The action runs mtest and nothing else — the calling
  workflow still installs the locked environment. `v1` is a major-version
  alias; pin a commit instead to adopt each release deliberately.
- A documentation site under `docs/`, built with mkdocs and published to
  GitHub Pages at <https://mikeleppane.github.io/mtest/>. It carries a landing
  page, a getting-started path, a continuous-integration page, and pages for
  run reports and shell completion, and navigates to the command-line
  contract, the two JSON stream references, the toolchain-compatibility page,
  and the release runbook. The README stays the reference; the site's commands
  and outputs are mirrored from it rather than retyped.

### Changed

- `--json` and `--junit-xml` naming the same destination is now a pre-run
  usage error (exit 4) rather than a run. The rule governs every active file
  destination, so it applies to argument vectors carrying no `--report` flag;
  on a case-insensitive volume it also refuses `Out.json` against `out.json`
  ([§15.2](docs/cli-contract.md), §15.4, §15.5).
- Under `doctor`, `--no-cache` and `--cache-clear` are documented as accepted
  and inert rather than as usage errors, which is what the parser has always
  done. §4's own policy exists so one flag set can be handed to every
  subcommand in CI; the contract text disagreed with it (§4, §9).
- The README now opens with installation and a first passing run before the
  rationale, and states the ten-error/ten-warning per-step cap that GitHub
  applies to inline annotations where the flag is introduced rather than only
  under its limitations.
- The binary's usage block lists `collect`, which it had left out.

### Fixed

- The build cache could serve a stale binary. A contribution's tag was fed
  into the key without a length prefix, so the frame was not injective over
  the pair: two different build inputs could produce the same SHA-256, and the
  store could then answer with a binary it had never built for that source — a
  green run that never happened. Tags are length-prefixed now. Every cache key
  changes value on upgrade, which is a miss rather than a correctness event:
  the file rebuilds, publishes under the new name, and the generations written
  under the old framing are reaped by the per-source retention window.
- A `test_*.mojo` file whose path contains `::` was collected and run even
  though no operand could ever address it, because an operand splits at its
  first separator — so the file became a node id whose path was the text
  before the `::`, and the refusal quoted a path the caller never typed. §5
  has always said `::` in a path is unsupported; discovery now enforces it,
  skipping such a file with a `skipped-unaddressable` warning and still
  descending the directory holding it. An operand carrying `::` in its file
  part gets an accurate refusal, still exit 4, quoting the operand as typed.
- Every command that wrote straight to a descriptor — `help`, `version`,
  `config show`, `doctor`, `new`, `init`, and `collect --format json` — died
  at signal 13 (`141` at the shell, a status in no documented exit domain)
  when stdout was a pipe whose reader had closed. Those writes now run under a
  single SIGPIPE guard and report an undelivered write inside their own exit
  domain, with `new` and `init` reporting artifacts they had already created.

## 1.0.0 — 2026-07-31

First stable release, tagged `v1.0.0`.

### Toolchain

- Mojo `1.0.0b2`. The conda package declares `mojo-compiler ==1.0.0b2` as its
  sole run dependency.

### Platforms

- `linux-64` and `osx-arm64`. The package is built from source once per
  platform; there is no `noarch` artifact.

### Published

- `modular-community` (`https://repo.prefix.dev/modular-community`), build
  number 0: `mtest-1.0.0-hb0f4dca_0.conda` for linux-64 and
  `mtest-1.0.0-h60d57d3_0.conda` for osx-arm64. Installing additionally
  resolves `https://conda.modular.com/max/` for the run dependency and
  `conda-forge` for everything underneath. Licensed MIT.

### Command-line contract

- `docs/cli-contract.md` §20 is frozen for the 1.x series: the subcommands
  (`run`, `collect`, `config show`, `doctor`, `version`, `help`), flag names
  and semantics, exit codes, the node-id grammar, `mtest.toml` key names and
  semantics, `--lf`/`--ff` semantics, the JUnit mapping, the annotation shapes,
  the `--json` event stream at schema version 1, the `collect` format, and the
  test-module contract.

### Added

- The complete feature set is listed under [Features](README.md#features).
  This entry records what identifies the release rather than restating it, so
  the two cannot drift.
