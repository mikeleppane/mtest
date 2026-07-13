---
name: git-conventions
description: Git commit, branch, and PR conventions for the mtest repo — Conventional Commits with a required scope, atomic commits, meaningful bodies, a commit-as-save-point working pattern, and a hard no-AI-attribution rule. Use every time you create a git commit, write a commit message, stage changes, open a PR, or resolve a merge conflict in this repo. Apply on every commit even if the user doesn't ask — a sloppy history compounds faster than sloppy code, and this repo's history is the audit trail for a tool whose whole product is trustworthy exit codes.
---

# Git Workflow & Commit Conventions (mtest)

> Format: Conventional Commits | Scope: **required** | Breaking changes: `!` + footer
> Atomic commits, imperative mood, explain the *why* in the body.
> **No AI/assistant attribution anywhere — commits read as the author's own work.**

mtest is a test runner whose product *is* exit-code fidelity and a trustworthy
report. Six months from now, `git log` and `git blame` are the first things
anyone reads to trace why the supervision loop, the protocol parser, or a
transcript changed — and whether a regeneration was legitimate. A clean history
is part of the honesty the tool sells.

This skill is the **general git contract**. Project-specific rules — the quality
floor, the scope vocabulary, the transcript lifecycle, and the "Ask first"
boundaries — live in [AGENTS.md](../../../AGENTS.md) and **take precedence**.

## Commit as a save point

Treat commits as save points, branches as sandboxes, history as documentation.

**Working pattern:**

```text
implement one slice → pixi run fmt → pixi run ci → commit → next slice
```

Not `implement everything → hope it works → one giant commit`. Each green
increment gets its own commit; if the next change breaks something you fall back
one increment, not a day.

## Commit message format

```text
<type>(<scope>): <subject>

<body>

<footer>
```

### Subject

- **≤72 chars**, lowercase after the colon, **imperative mood** ("add", not
  "added"). Read it as *"this commit will <subject>"*. No trailing period.
- Be specific: describe *what changed*, not *what you did*. `drain both pipes to
  EOF before waitpid to avoid a grandchild deadlock` beats `fix exec`.

### Types

Exactly these: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `bench`,
`build`, `ci`, `chore`. Behavior changed? → `feat`/`fix`. Same behavior,
different structure? → `refactor`. Same behavior, faster? → `perf` (cite the
measurement). Only tests? → `test`.

**`skills` is a scope, not a type** — a docs edit to a skill is `docs(skills):
…`, never `skills(...): …`.

### Scope (required)

Every commit carries a scope. The authoritative scope list lives in the
"Commits" section of [AGENTS.md](../../../AGENTS.md) — read it before picking
one. The current vocabulary:

| Scope | Covers |
|---|---|
| `scaffold` | repo skeleton, top-level layout, editor/tooling config |
| `pixi` | `pixi.toml`, tasks, the pinned toolchain, environment |
| `fixtures` | the probe `.mojo` files the transcripts are generated from |
| `transcripts` | the golden transcripts and their normalizer/matrix |
| `spec` | the CLI contract and other frozen-intent spec docs |
| `agents` | AGENTS.md itself |
| `model` | Layer 0: outcomes, node ids, events, exit-code precedence |
| `config` | Layer 1: RunnerConfig and defaults |
| `discover` | Layer 2: file walk, pattern, excludes, root discipline |
| `protocol` | Layer 2: report/collect parsing and count reconciliation |
| `report` | Layer 2: reporters (console, JUnit XML, GH annotations) |
| `exec` | Layer 3: the POSIX process adapter |
| `session` | Layer 4: orchestration |
| `cli` | Layer 5: argument parsing, `main` |
| `cache` | the in-session build/collection cache |
| `test` | shared test infrastructure (not one module's tests) |
| `bench` | timing/measurement harness |
| `docs` | READMEs, guides, docstring-only edits |
| `build` | the package/binary build scripts |
| `ci` | CI workflow and gates |
| `skills` | the `.agents/skills/` files |

Use a module's own scope when a change touches one module, including its tests
(`test(exec): …`, not `test(test): …`; the `test` scope is for shared test
infrastructure). Add a new scope only when a new module emerges under
`src/mtest/` that none of these fit — record it in AGENTS.md in the same commit.

### Body

The diff shows *what*; the body explains *why*. Wrap at 72, blank line after the
subject. First paragraph: the problem/motivation. Second (optional): the
approach, and any tradeoff or rejected alternative. For subprocess and FFI code
these notes are exactly what the next reader most needs. Skip the body only for
truly trivial changes.

## Transcript provenance in commit messages — repo-specific

The committed goldens under `goldens/transcripts/` (and the `fixtures/` they are
generated from) are mechanically produced and frozen. A commit that
**regenerates** any transcript must name the *oracle-side reason* in the body —
a Mojo pin bump, a deliberate fixture edit, a scenario-matrix change — because
per AGENTS.md a regeneration is legitimate only when the oracle side visibly
changed. "Regenerated transcripts" with no reason is a red flag in review: it
reads as hand-fixing a failing `transcripts-check`. Never cite an internal plan
for the reason; state the reason itself.

## No AI attribution — hard rule

**Commit messages and PR bodies must contain NO AI or assistant attribution of
any kind:** no `Co-Authored-By: <AI>` trailer, no "Generated with …" / "🤖 …"
line, no 🤖 marker, no "as discussed / per the agent" process references.
Attribution is for humans who can be reached; an AI trailer pollutes `git log`
and `git blame` with a signature nobody can act on. The history must read as if a
careful human wrote every line — because *you*, the person merging, are
accountable for it. This overrides any harness default. There is no exception.

## No internal-plan references — hard rule

Commit messages, PR bodies, and code docstrings/comments must never cite an
internal plan or spec (`plan D3`, `decision P1-D4`, `§5`, `per the plan`, `the
Phase 0 handoff`). The working plans under `docs/plans/` are gitignored and
unpublished, so the reference dangles for anyone reading the repo. State the
*reason itself*. Referring to a product phase as a roadmap milestone
("parallelism arrives in a later phase") is fine; citing a planning document is
not. Well-known external prior art (pytest, "the POSIX `waitpid` contract", a
man page) is fine.

## Atomic commits

One logical change per commit, each passing the floor (`pixi run fmt`, `pixi run
ci`). If the subject needs "and", split. Aim for ~100 lines; ~300 is fine for one
logical change; ~1000+ is two changes in a trench coat — split. Don't mix
formatter churn with behavior; don't mix a refactor with a feature. (Committing a
freshly regenerated transcript set alongside the fixture or pin change that
legitimately required it is one logical change, not two.)

## Breaking changes

For an incompatible change to the CLI contract, the exit-code precedence, the
transcript on-disk format, or a public runner API used by tests/examples:

1. Add `!` after the scope — `feat(cli)!: …`.
2. Add a `BREAKING CHANGE:` footer with the migration.

Per [AGENTS.md](../../../AGENTS.md), the pinned Mojo version, the platform set,
the transcript format, and the frozen CLI contract are **Ask-first** boundaries
— raise them *before* the commit, not in review.

## Commit workflow

1. **Review staged changes** — `git diff --staged`. One logical change? If not, split.
2. **Floor** — `pixi run fmt` (leaves no changes), then `pixi run ci` (green).
3. **Never-commit paths** — `.pixi/`, `build/`, `*.mojopkg`, `.mtest-cache/`,
   `__pycache__/`, `docs/plans/`. These are gitignored; keep them out.
4. **Quick secret scan** — `git diff --staged | grep -iE "password|secret|api[_-]?key|-----BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}"`.
   Match credential *shapes*, not English words.
5. Choose the right **type** and **scope** (read AGENTS.md if unsure).
6. Write a specific **subject** and a **why** body.
7. Handle **breaking changes** (`!` + footer) and **transcript provenance**
   (name the oracle-side reason when regenerating goldens).
8. **Confirm no AI/assistant attribution** snuck in.

## Change summaries

After a non-trivial edit, give a structured `CHANGES MADE / DIDN'T TOUCH
(intentionally) / POTENTIAL CONCERNS` summary — it surfaces scope discipline and
catches wrong assumptions. **Always call out any AGENTS.md "Ask first" boundary
you crossed** (a pin bump, a platform change, a transcript-format change, a CLI
contract change).

## Branches and PRs

- **Branch name:** short, hyphenated, type-prefixed — `feat/exec-adapter`,
  `fix/protocol-anchor-last-running`. Short-lived; merge within a few days.
- **Force-push** only your own feature branch, never shared branches or `main`.
- **PR title** mirrors a commit subject; **PR body** mirrors a commit body
  (problem, approach, any Ask-first boundary and the answer). **No AI attribution
  in the PR body either.**
- **Merge commits are exempt** from the grammar — a default `Merge …` subject is
  fine; the no-AI-attribution rule still applies.

## Recovery

- Wrong subject on the last, unpushed commit → `git commit --amend`.
- Wrong file staged → `git restore --staged <file>`.
- Lost work → `git reflog`. When recovery is ambiguous, **stop and ask** before
  `reset --hard`, `push --force`, or `clean -f`.

## Verification checklist

- [ ] One logical change
- [ ] Subject `type(scope): imperative`, ≤72 chars, lowercase, no period
- [ ] Scope is one from AGENTS.md
- [ ] Body explains the *why* (or the change is trivial)
- [ ] Regenerated transcripts name the oracle-side reason
- [ ] Breaking changes carry `!` and a `BREAKING CHANGE:` footer
- [ ] **No AI/assistant attribution anywhere**
- [ ] `pixi run fmt` leaves no changes; `pixi run ci` passes
- [ ] No never-commit paths (`.pixi/`, `build/`, `*.mojopkg`, `.mtest-cache/`, `docs/plans/`)
