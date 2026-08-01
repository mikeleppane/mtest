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

Nothing yet.

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
