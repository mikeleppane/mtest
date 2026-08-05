#!/usr/bin/env python3
"""Point a checkout at a newer Mojo toolchain than the one it pins.

The compatibility canary exists to answer "would this repository still work on
the next toolchain?", and it can only ask that question by making the tree
solve for something other than what it committed. Two tracked files stand in
the way, and this module owns both rewrites:

- `pixi.toml` pins `mojo ==<version>,<2`. Installing under that spec resolves
  the pinned toolchain no matter what has been released since, so relaxing the
  operator to `>` is not an optimisation — it is the only reason the probe can
  ever see a candidate. It must therefore happen *before* the install, and a
  canary that installed first would report "nothing newer" every day forever
  while looking perfectly healthy.
- `recipe/recipe.yaml` pins the compiler three times (the isolated build
  environment, the host link inputs, and the package's run dependency). A
  packaging probe that left those at the committed version would build and
  install with the *pinned* compiler and report a candidate as packageable on
  evidence about a different toolchain entirely, so all three move together or
  none does.

Both rewrites edit tracked files in place. That is safe on a throwaway CI
checkout and destructive in a contributor's, so both refuse to run unless the
environment says it is a hosted run or an operator has explicitly asked for the
override. The permission is read from the environment rather than passed in
because it is a property of where this process is running, not of what any one
call wants.
"""

from __future__ import annotations

from dataclasses import dataclass
import os
import re
import subprocess
from typing import TYPE_CHECKING

from scripts.gen_transcripts import MOJO_VERSION_RE


if TYPE_CHECKING:
    from pathlib import Path


# GitHub sets this to "true" in every hosted step. Its absence means a
# developer's checkout, where rewriting tracked files would destroy work.
CI_ENV_VAR = "GITHUB_ACTIONS"
CI_ENV_VALUE = "true"
# The deliberate escape hatch, set by `scripts.canary.run --force`. Named in
# the environment so it survives into any child that repeats a rewrite.
FORCE_ENV_VAR = "MTEST_CANARY_FORCE"
FORCE_ENV_VALUE = "1"

STABLE_LANE = "stable"
NIGHTLY_LANE = "nightly"
LANES = (STABLE_LANE, NIGHTLY_LANE)

# Modular publishes prereleases to their own channel; the stable lane must never
# see them, which is why the channel is added per lane rather than pinned into
# the manifest. Verified against the live index: this channel serves `mojo` and
# `mojo-compiler` for both gated subdirs, and is where the only versions newer
# than the current pin are published today.
NIGHTLY_CHANNEL = "https://conda.modular.com/max-nightly/"

# The e2e scenarios that require `mtest doctor` to report a HEALTHY toolchain.
# They legitimately fail once the toolchain moves — `doctor` compiles the pinned
# identity in and refuses anything else — and they are the only e2e failures the
# probe tolerates.
#
# Named one by one rather than matched by a `doctor-` prefix. Five of the seven
# doctor scenarios do not depend on the installed toolchain at all: two assert
# `FAIL toolchain: dependency config unavailable`, reached before any toolchain
# is probed; one points `MTEST_MOJO` at fake executables and asserts the
# identity compiled into the sources; one asserts a state failure while
# admitting any status on the toolchain line; and one asserts exit 2 from a
# deliberately slow fake probe. Under the prefix, a candidate that miscompiled
# the state probe failed `doctor-unwritable-state`, was tolerated, and closed
# the lane's issue with `PASS`.
TOLERATED_E2E_SCENARIOS = frozenset({"doctor-healthy", "doctor-config-free"})

# What `contract-check-strict` looks like when the only thing wrong is that the
# toolchain moved, as (check name, the whole detail that check reports).
#
# `mtest doctor` compiles the pinned toolchain identity in and reports
# `FAIL toolchain` for any other, which makes it exit 1 — correct product
# behaviour, and the reason the canary needs this list at all. Three contract
# checks invoke `mtest doctor` expecting the 0 a healthy environment gives, so
# on any candidate whatsoever the strict gate failed, the probe called the
# sources incompatible, and no candidate could ever be reported as passing. A
# canary that is permanently red says exactly as little as one that is
# permanently green: every day reads the same, and the day a candidate really
# breaks the sources is indistinguishable from the rest.
#
# Nothing else in that gate is affected. The two `doctor: --report*` checks are
# parser refusals that return before any diagnosis runs, and the
# unwritable-descriptor check expects the 3 that an undelivered report produces
# whatever the diagnosis said.
#
# The detail is part of the key, not decoration. The first check drives ten
# different commands and reports one clause per misbehaving command, so a
# tolerance keyed on the check name alone would have hidden a candidate's
# broken `EPIPE` handling in `run` or `collect` inside a tolerated line.
TOLERATED_CONTRACT_FAILURES: tuple[tuple[str, str], ...] = (
    (
        "pipe: every direct-output command survives a closed stdout",
        "doctor: exit 1, want 0",
    ),
    ("served: doctor --no-cache accepted, inert (not exit 4)", "exit 1, want 0"),
    ("served: doctor --cache-clear accepted, inert (not exit 4)", "exit 1, want 0"),
)

# How the probe asks which toolchain the install produced. Everything the probe
# spawns goes through pixi, which is the only tool the runner provisions ahead
# of it: the workspace environment is created by the probe's own install, after
# the pin has been relaxed, so nothing from it is on PATH before that. The
# manifest's `mojo-version` task is the repository's existing spelling of this
# question and is reused rather than restated.
RESOLVE_ARGV = ("pixi", "run", "mojo-version")

# The workspace's mojo dependency, in both the committed spelling and the
# relaxed one this module writes. One pattern reads both so the pin can be
# looked up whether or not the relaxation has already happened.
_WORKSPACE_SPEC = re.compile(
    r'^mojo = "(?P<spec>(?P<operator>==|>)(?P<version>[^",]+),<2)"$', re.MULTILINE
)

# The workspace's channel list, and the entries inside it.
_CHANNELS = re.compile(r"^channels = \[(?P<items>[^\]]*)\]$", re.MULTILINE)
_CHANNEL_ENTRY = re.compile(r'"([^"]*)"')

# The three compiler pins, as (requirements section, package name). `mojo` is
# the driver that runs on the build machine; `mojo-compiler` owns the runtime
# closure the produced binary loads, and is named twice because the link inputs
# and the run dependency are separate declarations.
_RECIPE_SLOTS = (
    ("build", "mojo"),
    ("host", "mojo-compiler"),
    ("run", "mojo-compiler"),
)

# A sibling key inside `requirements:`, which bounds one section. Comment lines
# are indented the same way and must not end a section, so the pattern requires
# a key rather than merely a non-blank line.
_REQUIREMENTS_KEY = re.compile(r"^  [A-Za-z_][\w-]*:", re.MULTILINE)


class ToolchainError(RuntimeError):
    """A rewrite could not be made, or was not permitted."""


@dataclass(frozen=True)
class ResolvedToolchain:
    """The toolchain an install actually produced.

    Attributes:
        version: The version string `mojo --version` reports.
        commit: The build commit hash from the same line.
    """

    version: str
    commit: str


def mutation_permitted() -> bool:
    """Report whether this process may rewrite tracked files.

    Each variable is compared against its exact documented value rather than
    tested for presence. `GITHUB_ACTIONS=false` is the spelling a step uses to
    say it is *not* hosted, and `MTEST_CANARY_FORCE=0` is how an operator turns
    the override off; reading either as "set, therefore permitted" would make
    both of them authorization to rewrite a contributor's tracked files.

    Returns:
        True on a hosted run, or when the force override is set.
    """
    return (
        os.environ.get(CI_ENV_VAR) == CI_ENV_VALUE
        or os.environ.get(FORCE_ENV_VAR) == FORCE_ENV_VALUE
    )


def _require_mutation_permission(action: str) -> None:
    """Refuse a tracked-file rewrite outside CI.

    Args:
        action: What the caller was about to do, quoted back to the operator.

    Raises:
        ToolchainError: Neither the CI marker nor the force override is set.
    """
    if not mutation_permitted():
        raise ToolchainError(
            f"refusing to {action}: {CI_ENV_VAR} is not {CI_ENV_VALUE!r}, so this "
            f"looks like a working checkout rather than a throwaway CI one. Set "
            f"{FORCE_ENV_VAR}={FORCE_ENV_VALUE} (or pass --force) to override."
        )


def workspace_pin(repo: Path) -> str:
    """Read the Mojo version the workspace manifest names.

    Args:
        repo: A checkout root holding `pixi.toml`.

    Returns:
        The version in the manifest's mojo spec, whether that spec is still the
        committed `==<version>,<2` or has already been relaxed to `><version>`.

    Raises:
        ToolchainError: The manifest does not hold exactly one mojo spec.
        OSError: `pixi.toml` cannot be read.
    """
    text = (repo / "pixi.toml").read_text(encoding="utf-8")
    return _sole_workspace_spec(text).group("version")


def _sole_workspace_spec(text: str) -> re.Match[str]:
    """Locate the manifest's one and only mojo dependency spec.

    Args:
        text: The contents of `pixi.toml`.

    Returns:
        The match, whose groups are the comparison operator and the version.

    Raises:
        ToolchainError: There is not exactly one such spec. Two would leave the
            resolved toolchain ambiguous, and none means the manifest's shape
            moved out from under this module.
    """
    matches = list(_WORKSPACE_SPEC.finditer(text))
    if len(matches) != 1:
        raise ToolchainError(
            f"pixi.toml names {len(matches)} mojo specs; exactly one is required "
            "to say which toolchain this checkout resolves"
        )
    return matches[0]


def relaxed_spec(pin: str) -> str:
    """Render the version spec admitting every toolchain newer than the pin.

    The upper bound is kept: this project probes the next release of the line
    it targets, not the next major, whose incompatibilities would be a
    different question with a different answer.

    Args:
        pin: The pinned version.

    Returns:
        A conda version spec, for example `>1.0.0b2,<2`.
    """
    return f">{pin},<2"


def candidate_matchspec(pin: str) -> str:
    """Render the package match a candidate toolchain has to satisfy.

    Args:
        pin: The pinned version.

    Returns:
        A conda matchspec naming the package and the relaxed version spec.
    """
    return f"mojo {relaxed_spec(pin)}"


def floor_matchspec(pin: str) -> str:
    """Render the control question a working channel must always answer.

    This is `candidate_matchspec` with its lower bound made inclusive, and
    nothing else: the same package, the same version literal, the same upper
    bound, the same grammar. That makes it a control worth running. It admits
    the pinned version itself, which the channels must carry for this
    repository to build at all, so a channel that can answer questions of this
    shape answers it with at least one record.

    Args:
        pin: The pinned version.

    Returns:
        A conda matchspec, for example `mojo >=1.0.0b2,<2`.
    """
    return f"mojo >={pin},<2"


def _sole_channel_list(text: str) -> re.Match[str]:
    """Locate the manifest's one and only channel list.

    Args:
        text: The contents of `pixi.toml`.

    Returns:
        The match, whose `items` group spans the quoted entries.

    Raises:
        ToolchainError: There is not exactly one channel list.
    """
    matches = list(_CHANNELS.finditer(text))
    if len(matches) != 1:
        raise ToolchainError(
            f"pixi.toml names {len(matches)} channel lists; exactly one is "
            "required to say where a toolchain would come from"
        )
    return matches[0]


def workspace_channels(repo: Path) -> tuple[str, ...]:
    """Read the channels the workspace manifest resolves against.

    Args:
        repo: A checkout root holding `pixi.toml`.

    Returns:
        The channel names or URLs, in manifest order.

    Raises:
        ToolchainError: The manifest does not hold exactly one channel list.
        OSError: `pixi.toml` cannot be read.
    """
    text = (repo / "pixi.toml").read_text(encoding="utf-8")
    return tuple(_CHANNEL_ENTRY.findall(_sole_channel_list(text).group("items")))


def candidate_channels(repo: Path, lane: str) -> tuple[str, ...]:
    """List the channels a lane may draw a candidate toolchain from.

    These are the channels the search is asked about and, after
    `relax_workspace_pin`, the ones the install resolves against — one
    derivation, so the probe cannot screen against a different index than the
    solver later reads.

    Args:
        repo: A checkout root holding `pixi.toml`.
        lane: `stable` or `nightly`.

    Returns:
        The workspace's own channels, with the nightly channel ahead of them on
        the nightly lane.

    Raises:
        ToolchainError: The lane is unknown, or the manifest does not hold
            exactly one channel list.
        OSError: `pixi.toml` cannot be read.
    """
    if lane not in LANES:
        raise ToolchainError(f"unknown canary lane {lane!r}; expected one of {LANES}")
    channels = workspace_channels(repo)
    if lane == NIGHTLY_LANE:
        return (NIGHTLY_CHANNEL, *channels)
    return channels


def relax_workspace_pin(repo: Path, lane: str) -> None:
    """Let the workspace resolve any toolchain newer than the pinned one.

    Rewrites the manifest's `mojo ==<pin>,<2` to `mojo ><pin>,<2`, and for the
    nightly lane prepends Modular's nightly channel so the solver can see
    prereleases at all. Callers must do this BEFORE installing: an install
    under the committed spec resolves the pinned toolchain and leaves the probe
    with nothing to say.

    Args:
        repo: The checkout to rewrite, which must be disposable.
        lane: `stable` or `nightly`.

    Raises:
        ToolchainError: The rewrite is not permitted here, the lane is unknown,
            the manifest does not hold exactly one mojo spec, that spec has
            already been relaxed, or the nightly channel is already present.
        OSError: `pixi.toml` cannot be read or written.
    """
    _require_mutation_permission("relax pixi.toml's mojo pin")
    if lane not in LANES:
        raise ToolchainError(f"unknown canary lane {lane!r}; expected one of {LANES}")

    path = repo / "pixi.toml"
    text = path.read_text(encoding="utf-8")
    spec = _sole_workspace_spec(text)
    if spec.group("operator") != "==":
        raise ToolchainError(
            f"pixi.toml's mojo spec is already relaxed to {spec.group(0)!r}; "
            "rewriting it again would say nothing about the pinned version"
        )
    # Written through the same renderer the candidate search asks with, so the
    # question the probe screened for and the one the solver is handed cannot
    # drift apart.
    relaxed = relaxed_spec(spec.group("version"))
    text = f"{text[: spec.start('spec')]}{relaxed}{text[spec.end('spec') :]}"
    if lane == NIGHTLY_LANE:
        text = _prepend_nightly_channel(text)
    path.write_text(text, encoding="utf-8")


def _prepend_nightly_channel(text: str) -> str:
    """Put Modular's nightly channel ahead of the workspace's own channels.

    Args:
        text: The contents of `pixi.toml`, with the pin already relaxed.

    Returns:
        The same manifest with the nightly channel first in the channel list.

    Raises:
        ToolchainError: The channel is already listed, or the manifest does not
            hold exactly one channel list to prepend to.
    """
    if NIGHTLY_CHANNEL in text:
        raise ToolchainError(
            f"pixi.toml already lists {NIGHTLY_CHANNEL}; this checkout has been "
            "rewritten once already"
        )
    items = _sole_channel_list(text).start("items")
    return f'{text[:items]}"{NIGHTLY_CHANNEL}", {text[items:]}'


def resolved_toolchain(repo: Path) -> ResolvedToolchain:
    """Ask the installed toolchain which version it actually is.

    Run this only AFTER the install. The toolchain is reached *through* pixi
    rather than as a bare `mojo`, because the probe deliberately runs on the
    runner's own interpreter with nothing provisioned but the pixi binary: the
    workspace environment must not exist until `relax_workspace_pin` has
    rewritten the spec, so there is no prefix on PATH to find `mojo` in. Going
    through the manifest's own `mojo-version` task also keeps one spelling of
    "which toolchain is this" in the repository instead of two.

    The checkout is a parameter rather than the process's working directory
    because pixi answers for the manifest it finds there. Asked from anywhere
    else, this reports a toolchain the probe never installed — and the probed
    checkout is chosen by `--repo`, so the two are routinely different.

    Args:
        repo: The checkout whose environment was just installed.

    Returns:
        The version and build commit the toolchain reports.

    Raises:
        ToolchainError: The task printed something this repository's transcript
            generator could not parse either, which means no toolchain identity
            can be recorded for the probe.
        subprocess.CalledProcessError: The task failed to run.
    """
    out = subprocess.run(
        list(RESOLVE_ARGV), cwd=repo, check=True, capture_output=True, text=True
    ).stdout.strip()
    match = MOJO_VERSION_RE.search(out)
    if match is None:
        raise ToolchainError(f"cannot parse mojo version from: {out!r}")
    return ResolvedToolchain(match.group(1), match.group(2))


def pin_recipe_to_candidate(repo: Path, resolved: ResolvedToolchain) -> None:
    """Retarget the package recipe's three compiler pins at a candidate.

    The build environment, the host link inputs, and the run dependency all
    name the same compiler at the same version, and the packaging probe is only
    evidence about the candidate if all three move. Each pin is located inside
    its own `requirements:` section and must be there exactly once.

    Args:
        repo: The checkout to rewrite, which must be disposable.
        resolved: The toolchain the install produced.

    Raises:
        ToolchainError: The rewrite is not permitted here, a section does not
            hold exactly one pin for its package, the three pins disagree
            (which is what a partially-rewritten recipe looks like), or they
            already name the candidate and there is nothing to retarget.
        OSError: `recipe/recipe.yaml` cannot be read or written.
    """
    _require_mutation_permission("retarget recipe/recipe.yaml's compiler pins")
    path = repo / "recipe" / "recipe.yaml"
    text = path.read_text(encoding="utf-8")
    start, end = _requirements_span(text)

    spans: list[tuple[int, int]] = []
    found: list[tuple[str, str]] = []
    for section, package in _RECIPE_SLOTS:
        section_start, section_end = _section_span(text, start, end, section)
        pattern = re.compile(rf"^    - {re.escape(package)} ==(\S+)$", re.MULTILINE)
        matches = list(pattern.finditer(text, section_start, section_end))
        if len(matches) != 1:
            raise ToolchainError(
                f"requirements.{section} names {len(matches)} `{package} ==` pins; "
                "exactly one is required to retarget the packaging probe"
            )
        spans.append((matches[0].start(1), matches[0].end(1)))
        found.append((f"{section}.{package}", matches[0].group(1)))

    versions = {version for _slot, version in found}
    if len(versions) != 1:
        raise ToolchainError(
            f"recipe compiler pins disagree ({found}); a packaging probe built "
            "against two compilers proves nothing about either"
        )
    current = versions.pop()
    if current == resolved.version:
        raise ToolchainError(
            f"recipe already pins {current}, so nothing distinguishes the "
            "candidate build from the committed one"
        )

    for span_start, span_end in reversed(spans):
        text = f"{text[:span_start]}{resolved.version}{text[span_end:]}"
    path.write_text(text, encoding="utf-8")


def _requirements_span(text: str) -> tuple[int, int]:
    """Bound the recipe's `requirements:` mapping.

    The recipe has a top-level `build:` key of its own, so the compiler pins
    can only be found relative to this block rather than by searching the whole
    document.

    Args:
        text: The contents of `recipe/recipe.yaml`.

    Returns:
        The half-open offset range covering the block's entries.

    Raises:
        ToolchainError: The document has no `requirements:` key.
    """
    header = re.search(r"^requirements:$", text, re.MULTILINE)
    if header is None:
        raise ToolchainError("recipe/recipe.yaml has no requirements block")
    start = header.end()
    tail = re.compile(r"^\S", re.MULTILINE).search(text, start)
    return start, tail.start() if tail is not None else len(text)


def _section_span(text: str, start: int, end: int, section: str) -> tuple[int, int]:
    """Bound one `requirements:` subsection.

    Args:
        text: The contents of `recipe/recipe.yaml`.
        start: Offset where the requirements block's entries begin.
        end: Offset where the requirements block ends.
        section: `build`, `host` or `run`.

    Returns:
        The half-open offset range covering that subsection's entries.

    Raises:
        ToolchainError: The subsection is absent.
    """
    header = re.compile(rf"^  {re.escape(section)}:$", re.MULTILINE).search(
        text, start, end
    )
    if header is None:
        raise ToolchainError(
            f"recipe/recipe.yaml has no requirements.{section} section"
        )
    section_start = header.end()
    sibling = _REQUIREMENTS_KEY.search(text, section_start, end)
    return section_start, sibling.start() if sibling else end
