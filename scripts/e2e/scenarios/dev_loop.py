"""Developer-loop scenarios: the controls used while hunting a flaky suite.

`--shuffle` is the first of them. Its claim is about the relationship between
two whole runs, so nothing inside one process can settle it: only a second run
of the same command shows that a seed reproduces an order, and only a third run
under a different seed shows that the order was ever randomized at all.

The comparison is deliberately made over the `--json` stream's ordered
`file_started` projection rather than over console bytes. The console carries
the run's wall clock and its build-cache counters, which the contract excludes
from byte identity, so two console outputs of the identical run differ for
reasons that have nothing to do with ordering.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from scripts.e2e.assertions import expect, expect_exit, stream_files


if TYPE_CHECKING:
    from scripts.e2e.runner import ScenarioContext


SUITE = "e2e/suite"
"""The committed known-outcome tree. Seven run files is enough that two seeds
drawing the same permutation would be a coincidence worth investigating rather
than an ordinary collision."""


def _order(context: ScenarioContext, seed: str) -> tuple[str, ...]:
    """The ordered `file_started` paths of one seeded shuffled run of SUITE.

    Args:
        context: The scenario context whose runner drives the binary.
        seed: The `--seed` value to run under.

    Returns:
        The run files in the order the stream announced them.

    Raises:
        ScenarioError: If the run did not exit with the suite's known failing
            verdict, since a run that died early carries no ordering fact.
    """
    run = context.runner.run_mtest(
        [
            SUITE,
            "--shuffle",
            "--seed",
            seed,
            "--json",
            "-",
            "--gh-annotations",
            "off",
        ]
    )
    # The suite carries failing members, so 1 is its ordinary verdict, and it
    # must not move because the order did.
    expect_exit(run, 1)
    return stream_files(run.stdout).started


ALTERNATIVES = ("9", "2", "3")
"""Seeds tried in turn until one draws a different order from the reference.

Fixing a single alternative would make the scenario fail whenever that
particular pair happens to draw the same permutation, which a change to the
suite's file set could cause at any time. Only every alternative agreeing is
evidence that nothing was randomized. They are tried lazily, so the ordinary
run costs one extra session, not three.
"""


def s_shuffle_seed_reproduces(context: ScenarioContext) -> str:
    """A seed replays its file order, and a different seed draws another one.

    Both halves are needed. Two same-seed runs agreeing is also what a
    `--shuffle` that never moved a file produces, so the different-seed run is
    what proves the randomization is real. Comparing the two orders' sets before
    their sequences separates "the order changed" from "a different set of files
    ran", which would be a far more serious defect with the same symptom.
    """
    first = _order(context, "7")
    again = _order(context, "7")

    expect(
        len(first) >= 3,
        f"too few files ran to carry an order at all: {first}",
    )
    expect(
        first == again,
        f"one seed drew two different orders:\n  {first}\n  {again}",
    )

    reordered_by = ""
    for seed in ALTERNATIVES:
        other = _order(context, seed)
        expect(
            sorted(first) == sorted(other),
            f"seed {seed} ran a different SET of files, not a different order:"
            f"\n  {sorted(first)}\n  {sorted(other)}",
        )
        if other != first:
            reordered_by = seed
            break
    expect(
        bool(reordered_by),
        f"no seed in {ALTERNATIVES} reordered {first}, so nothing was randomized",
    )
    return (
        f"seed 7 replayed {len(first)} files in order; "
        f"seed {reordered_by} reordered them"
    )
