---
name: bumping-mojo
description: Use when moving the Mojo pin in pixi.toml, after the human approved the bump. The ordered steps, and the gate that proves each one.
---

# Bumping the Mojo pin

A bump moves the oracle. mtest's verdicts rest on what the toolchain does, so
each premise below has a gate that goes red when the new compiler breaks it.
Done means every gate in steps 3-8 is green and `git grep -F <old pin>` finds
only CHANGELOG history.

## Steps

1. **Read the range.** Read the Mojo changelog from the old pin to the new one.
   Note every change to `TestSuite`, `mojo build`, `mojo precompile`, packages,
   and `UnsafePointer`/`external_call` spellings.
2. **Move the pin.** Edit `mojo` in `pixi.toml`, then `pixi install` and
   `pixi run mojo-version`.
3. **Restatements.** `pixi run version-check` holds the docs, recipes, and
   changelog against the pin. Four code restatements are listed in the
   `scripts/checks/version.py` docstring; update each. Then
   `git grep -F <old pin>` and update each hit outside CHANGELOG history.
4. **Syntax.** `pixi run build-bin`; fix breaks with the global `mojo-syntax`
   skill. `pixi run safety-check` fails on an `unsafe_*` spelling no candidate
   family matches: add the new spelling to `_CANDIDATES`.
5. **Transcripts.** `pixi run transcripts` regenerates the snapshots and runs
   every module that parses them. Read `git diff tests/snapshots/protocol` as
   the protocol changelog. Commit it alone, naming the pin in the body.
6. **Toolchain premises.** Each has a gate. A red one indicts the new compiler
   first:

   | Premise | Gate |
   | --- | --- |
   | Passing report on stdout, failing report on stderr | `transcripts` diff, `pixi run e2e` |
   | The compile cache keys on content, so builds pass `-D MTEST_SOURCE` | `pixi run cache-protocol-check` |
   | Which directories are importable (namespace packages) | `cache-protocol-check`: `test_editing_a_namespace_package_helper_rebuilds` |
   | `--precompile` writes `.mojoc` | `pixi run contract-check-strict` |
   | `share/max/modular.cfg` shape | `python -m scripts.tests.test_package_consumption`: `test_accepts_the_pinned_toolchain_config` |
   | Runtime's still-reachable allocations | `pixi run valgrind-check` |

   On a Valgrind baseline change, re-pin `EXPECTED_REACHABLE` in
   `scripts/checks/memory/valgrind.py` and its fixture in
   `scripts/tests/test_valgrind.py` only if every new record sits in the Mojo
   runtime.
7. **Full floor.** `pixi run test`, `assertions-check`, `dogfood-check`,
   `build-stamp-check`, `ci-memory`, `package-check`, and the macOS
   cross-compile in AGENTS.md.
8. **Changelog.** Under Unreleased, record each user-visible effect. Record a
   toolchain bug mtest works around under Known issues, with its upstream issue.
