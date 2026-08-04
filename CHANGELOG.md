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

## Unreleased

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
- A composite GitHub Action at the repository root. `uses: mikeleppane/mtest@v1`
  with `paths` and `args` replaces writing the invocation out; `args` is
  appended verbatim, so every flag stays reachable and none is promoted to an
  input of its own. The action runs mtest and nothing else — the calling
  workflow still installs the locked environment. `v1` is a major-version
  alias; pin a commit instead to adopt each release deliberately.
- A documentation site under `docs/`, built with mkdocs and published to
  GitHub Pages at <https://mikeleppane.github.io/mtest/>. It carries a landing
  page, a getting-started path, and a continuous-integration page, and
  navigates to the command-line contract, the JSON event stream, and the
  release runbook. The README stays the reference; the site's commands and
  outputs are mirrored from it rather than retyped.

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
