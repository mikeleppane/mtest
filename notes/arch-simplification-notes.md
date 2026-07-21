# Architecture simplification — execution notes

Evidence log for the behavior-preserving refactor series on
`refactor/architecture-simplification`, branched from `main` at
`f8db432f208d90f99934bcc13982c3f519795c92`.

Baseline before any change: `pixi run ci` green on the untouched base —
e2e `59/59 scenarios passed`, dogfood `3 passed, 0 failed, 0 skipped`.

## Correcting doctrine that had drifted from the tree

`6b4a7d4` — `docs(agents): correct layer graph and exit-code drift from the tree`

Four statements in `AGENTS.md` no longer matched the tree:

- The Layer 2 graph omitted `select` and `cache`, though the root
  `src/mtest/__init__.mojo` docstring — the graph's own mirror — already listed
  both. Verified by real imports: `select` imports `mtest.model` only; `cache`
  imports nothing internal at all (only `std.collections`).
- The commit scope table had no `select` row despite `src/mtest/select/` being
  a package a commit can touch alone.
- Layer 5 credited `cli` with `main`, but `src/main.mojo` sits above the whole
  package as the composition root, outside `src/mtest/cli/`.
- The Layer 0 row credited `model` with "exit codes" when it decided only
  0, 1, and 5 — as `model/exit_code.mojo`'s own docstring already conceded.

Doctrine that contradicts the tree stops being consulted, so each line was
corrected to match its own tree. The FFI containment wording was deliberately
left alone; consolidating the platform boundary is separate work and would
have made that wording wrong twice.

Proof: `pixi run ci; echo "ci_exit=$?"` → `ci_exit=0`, e2e 59/59.

## Routing every exit-code decision through one resolver

`5e208cb`, `bcd95a5`, `e3a6acb`, `1dcb98d`, `50256b2`, then `bd4ecaa`, `89aed87`

The process exit code — the product's central contract — had **five** owners:
`model/exit_code.mojo` (the outcome mapping), `session`'s
`_resolve_terminal_code`, the JSON shell's `escalate_on_close_failure`,
`main`'s 18 hard-coded `exit(` sites, and a fifth hand-rolled precedence ladder
inside `run_collect` that duplicated the session's shape. Nothing tested the
policy as one total function, and upcoming pool work adds more paths to it.

All five now resolve through one pure, total `resolve_exit_code(TerminalFacts)`
in `model`. Reporters return delivery *facts* rather than transformed codes.
`main` names no exit code of its own except the usage error, which is refused
before any run exists and so has no facts to rank.

`escalate_on_close_failure` was retired as a duplicate, not a variant: with all
four control-flow facts false the resolver's base stage is the identity, so it
reduces to exactly that function's escalation, and the two agree for every
`Int` — not merely the five reachable codes.

Evidence:

- `pixi run ci; echo "ci_exit=$?"` → `ci_exit=0` on the exact tree of each
  commit in the series (59/59 e2e exact-exit scenarios each time).
- The `tests/unit/test_session_terminal.mojo` assertions were migrated into
  `tests/unit/test_model_exit_code.mojo` as a genuine superset: all 14
  `assert_equal` calls survive at identical literal arguments and expected
  codes, including both assertions pinning that an interrupt stands over a
  later write failure. The 10 assertions of the retired
  `test_escalate_on_close_failure_precedence` reappear verbatim against the
  resolver.
- `CLASSIFIED_TEST_COUNT` 913 → 914, recounted independently against the tree.
- An adversarial review of the full series attempted to refute the
  behavior-preservation claim by case analysis over all five owners and could
  not.

Known residual risk, recorded deliberately: `TerminalFacts.outcome_code` is
read two ways — normally the `exit_code_for` result, and on one path an
already-resolved code having the delivery precedence re-applied. That is what
lets one resolver absorb the retired escalation instead of reproducing it. It
is sound today because the sole caller using the second reading passes every
other fact false, and the base stage is the identity for any value when no
fact is set. The field docstring names the constraint; the type does not
enforce it. A future caller that set a control-flow fact alongside an
already-resolved 2 would get 3 where the old code gave 2.
