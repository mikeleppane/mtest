#!/usr/bin/env python3
"""Validate exact repository harness layout and invocation policy."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib

from scripts.build import package_consumption
from scripts.e2e import __main__ as e2e_main
from scripts.harness import dogfood, selfhost


REPO_ROOT = Path(__file__).resolve().parents[2]

BUILD_SOURCE_PATHS = (
    Path("scripts/build/__init__.py"),
    Path("scripts/build/mojo_package.sh"),
    Path("scripts/build/native.py"),
    Path("scripts/build/native_strict_flags.txt"),
    Path("scripts/build/package_consumption.py"),
    Path("scripts/build/production_build.sh"),
    Path("scripts/build/production_profiles.txt"),
    Path("scripts/build/profiles.py"),
)
COMPANION_ROOT = Path("companions/assertions")
COMPANION_SOURCE_ROOT = COMPANION_ROOT / "src"
VENDORED_TOML_PATHS = {
    Path("vendor/mojo-toml/CHECKSUMS.json"),
    Path("vendor/mojo-toml/LICENSE"),
    Path("vendor/mojo-toml/README.md"),
    Path("vendor/mojo-toml/toml/__init__.mojo"),
    Path("vendor/mojo-toml/toml/lexer.mojo"),
    Path("vendor/mojo-toml/toml/parser.mojo"),
}
VENDORED_TOML_RELEASE = "346b7ad723c034f7696723f4846203d47ef86951"
VENDORED_TOML_MAIN = "c3262adea2d314748716991f99d0276f4a0b5e79"
VENDORED_TOML_UPSTREAM_SHA256 = {
    "LICENSE": "f091af39a05aa9864f099a672495096e97ce62e962f03fa90324da83061dab43",
    "src/toml/__init__.mojo": (
        "2c95e4cac433f0639125be700472001963ac319324f397465e309cdde97764e7"
    ),
    "src/toml/lexer.mojo": (
        "408f420337d6a5b2d74c5f04f44f638ae6317333b833ba3a8ff92664cf811b16"
    ),
    "src/toml/parser.mojo": (
        "5b49c67071f99bdf6096c5ec4745037ca043061a7fcbdcfb20a86ee127067a4a"
    ),
}
VENDORED_TOML_LOCAL_CHECKSUM_PATHS = {
    "LICENSE",
    "toml/__init__.mojo",
    "toml/lexer.mojo",
    "toml/parser.mojo",
}
CLASSIFIED_ROOTS = selfhost.DEFAULT_ROOTS
"""The classified suite roots, taken from the runner rather than restated.

`scripts/harness/selfhost.py` is what `pixi run test` executes, so these are the
directories whose contents run. Borrowing the runner's own list makes a drift
impossible rather than merely detectable.
"""
CLASSIFIED_TEST_GLOB = selfhost.TEST_FILE_GLOB
"""The runner's test-file glob, borrowed for the same reason as the roots.

A Mojo file under a classified root that this pattern does not match never runs,
which is the property `check_classified_mojo_inventory` exists to catch. It has
to test the runner's real pattern rather than a copy.
"""
FORBIDDEN_CLASSIFIED_PACKAGE_MARKERS = {
    Path("tests/unit/__init__.mojo"),
    Path("tests/integration/__init__.mojo"),
}
"""Package markers that must never reappear under the classified roots.

Every module beneath `tests/unit` and `tests/integration` declares `main()`,
which mtest's classified runner requires. Mojo 1.0.0b2 refuses to
`mojo precompile` a package containing such a module (`error: 'main()' is not
supported within packages`), so re-adding either child marker would break
`mojo precompile tests/` the moment the compiler recurses into it.
`tests/__init__.mojo` stays so `tests/` remains a nameable package; only its two
children must stay marker-free. See
`check_classified_roots_are_not_precompilable_packages`.
"""
PLATFORM_TARGET_KEYS = {"dependencies", "tasks"}
"""What a `[target.<platform>]` table in `pixi.toml` may contain.

Bounded so a new kind of platform-scoped table cannot appear without this check
naming it. Anything outside this set is an override shape nothing in this
repository has reasoned about.
"""

PLATFORM_TASK_OVERRIDES = {"ci-memory"}
"""The ONLY task any platform table may override.

A `[target.<platform>.tasks]` entry silently REPLACES the base task of the same
name. Pixi prints no warning, and every other view of the floor (`pixi run ci`,
`harness-check`, the hosted matrix) names lanes by task name, so the replacement
never shows up. Adding the three words

    asan-check = "true"

under `[target.linux-64.tasks]` leaves `pixi run asan-check` exiting 0 having run
`/bin/true`, with the hosted "ASan + LSan" required check still green.
Reproduced on this checkout.

`ci-memory` is the one legitimate member: on linux-64 it is replaced by a
dependency edge onto the two memory lanes, and the base command
(`scripts/checks/memory/host_support.py`) fails closed if that override is ever
LOST. This check covers the other direction, an override that is ever GAINED.
"""

DIRECT_SCRIPT_COMMAND_RE = re.compile(
    # An interpreter word, optionally path-qualified and version-suffixed, its
    # options, and then a repository-relative `.py` operand instead of `-m`.
    # `-m scripts.checks.layout` cannot match, since the operand after the
    # options has to end in `.py` and a dotted module name does not.
    #
    # The raw-text pass is quote-blind on purpose: 4.3% of this repository's
    # tracked lines (5368 of 124139, measured) cannot be lexed as a shell
    # command because prose uses an unpaired apostrophe. The word pass below
    # returns nothing for those lines.
    r"(?<![\w./-])(?:[\w./-]*/)?python[0-9.]*"
    r"(?:\s+-\S+)*"
    r"\s+(?:\./)?(scripts/[\w./-]+\.py)"
)

PYTHON_EXECUTABLE_RE = re.compile(r"python(?:\d+(?:\.\d+)*)?")
"""An interpreter basename, with or without a version suffix."""

PYTHON_EXECUTABLE_ALIASES = {"sys.executable"}
"""Source spellings that name the running interpreter without naming `python`.

`subprocess.run([sys.executable, "scripts/<name>.py"])` is the argv form of the
same defect, and the form Python tooling writes. Without this the word pass
reads `sys.executable` as an ordinary word and walks past the operand behind it.
"""

DIRECT_SCRIPT_RE = re.compile(r"scripts/[A-Za-z0-9_./-]+\.py")
"""A repository-relative Python script operand, once punctuation is stripped."""

OPTION_TAKES_VALUE = {"-W", "-X", "--check-hash-based-pycs"}
"""Interpreter options whose value is a separate word, not a script operand.

`python -X dev scripts/<name>.py` has to skip `dev` to reach the operand, and
`python -W ignore ...` likewise. Treating the value as the operand would stop
the walk one word early and miss the finding.
"""


def _reraise_walk_error(error: OSError) -> None:
    """Refuse to read an unreadable classified subtree as an empty one.

    `os.walk` swallows a directory-listing failure by default and yields
    nothing for that subtree, which would let an unreadable directory hide an
    unexecuted Mojo file behind a green gate.

    Args:
        error: The listing failure `os.walk` would otherwise have discarded.

    Raises:
        OSError: Always, re-raising `error` unchanged.
    """
    raise error


def classified_mojo_universe(root: Path) -> tuple[set[Path], set[Path]]:
    """Return regular and symlinked Mojo paths beneath both classified roots.

    Walks every directory entry under `tests/unit` and `tests/integration`
    without following directory symlinks. A regular file joins the Mojo
    universe when `.mojo` appears anywhere in its suffixes, so a misnamed
    `helper.mojo` and a parked `test_probe.mojo.disabled` are both visible to
    the caller rather than invisible to a `test_*.mojo` glob. A classified root
    that is itself a symlink is reported rather than walked through.

    Args:
        root: The repository root the classified suite directories live under.

    Returns:
        A pair of root-relative path sets: every regular Mojo-like file, and
        every symlinked entry regardless of its target or suffix.

    Raises:
        OSError: A directory beneath a classified root could not be listed. An
            unreadable subtree is a failure, never an empty one.
    """
    regular: set[Path] = set()
    symlinked: set[Path] = set()
    for classified_root in CLASSIFIED_ROOTS:
        absolute = root / classified_root
        if absolute.is_symlink():
            # `os.walk` always walks its top argument and `is_dir` follows the
            # link, so a relocated root has to be rejected before the walk.
            symlinked.add(classified_root)
            continue
        if not absolute.is_dir():
            continue
        for directory, dirnames, filenames in os.walk(
            absolute, onerror=_reraise_walk_error, followlinks=False
        ):
            current = Path(directory)
            retained: list[str] = []
            for name in dirnames:
                if (current / name).is_symlink():
                    symlinked.add((current / name).relative_to(root))
                else:
                    retained.append(name)
            dirnames[:] = retained
            for name in filenames:
                path = current / name
                relative = path.relative_to(root)
                if path.is_symlink():
                    symlinked.add(relative)
                elif ".mojo" in relative.suffixes:
                    regular.add(relative)
    return regular, symlinked


def check_classified_mojo_inventory(root: Path) -> None:
    """Require every Mojo file under a classified root to be one the runner runs.

    Nothing here is declared. The expectation comes from disk and from the
    runner's own glob (`CLASSIFIED_TEST_GLOB`), so adding a test file costs zero
    edits, which is why the committed `CLASSIFIED_PATHS`/`CLASSIFIED_TEST_COUNT`
    ledgers are gone.

    What that recovers from disk is the class of files that never reach the
    runner at all, which no oracle can reconcile:

    - a symlinked entry, which discovery refuses to follow;
    - a file parked as `.mojo.disabled`, or otherwise named so the glob skips
      it;
    - a misnamed Mojo module (`session_shard_test.mojo`, `helper.mojo`) that
      looks like a suite to a reader and is invisible to the runner.

    It is fail-closed on emptiness: a classified root holding no test file is a
    finding rather than a vacuous pass.

    What it cannot recover is removal. A committed path list and test count were
    the only artifacts that went red when a test file or function was DELETED
    from source. A bad merge dropping `tests/unit/test_x.mojo`, or a `test_foo`
    renamed to `foo`, now leaves disk, oracle and every gate in agreement, so
    long as the file keeps at least one test. That is the price of the
    zero-ledger-edits rule; the two properties are mutually exclusive.
    `scripts/harness/selfhost.py`'s module docstring states the same limit for
    its own oracle.

    Args:
        root: The repository root the classified suite directories live under.

    Raises:
        AssertionError: A symlink sits under a classified root, a Mojo file
            there is named so the runner would skip it, or a classified root
            holds no test file at all.
        OSError: A directory beneath a classified root could not be listed.
    """
    regular, symlinked = classified_mojo_universe(root)
    if symlinked:
        raise AssertionError(
            "symlinked classified path: "
            f"{sorted(path.as_posix() for path in symlinked)}"
        )
    discovered = {path for path in regular if path.match(CLASSIFIED_TEST_GLOB)}
    skipped = regular - discovered
    if skipped:
        raise AssertionError(
            "classified Mojo file the runner's "
            f"{CLASSIFIED_TEST_GLOB} discovery would silently skip: "
            f"{sorted(path.as_posix() for path in skipped)}"
        )
    for classified_root in CLASSIFIED_ROOTS:
        if not any(path.parent == classified_root for path in discovered):
            raise AssertionError(
                f"classified root holds no {CLASSIFIED_TEST_GLOB} test file: "
                f"{classified_root.as_posix()}"
            )


def check_classified_roots_are_not_precompilable_packages(
    repo_root: Path = REPO_ROOT,
) -> None:
    """Guard against packaging a classified root that still declares `main()`.

    Cheapest check first: a structural pre-check names the exact marker that
    reappeared without needing `mojo` on PATH. Only once that passes does this
    pay for a real `mojo precompile tests/`, which tests the property itself
    rather than a proxy. That invocation stays cheap because marker-free
    classified roots mean the compiler never recurses into either as a package
    and only compiles the one-line `tests/__init__.mojo`. See
    `FORBIDDEN_CLASSIFIED_PACKAGE_MARKERS`.

    Args:
        repo_root: Repository root `tests/` lives under.

    Raises:
        AssertionError: A forbidden package marker exists, `mojo` is not on
            PATH, or a real `mojo precompile tests/` invocation fails.
    """
    _require_nonempty(
        "forbidden classified package marker",
        FORBIDDEN_CLASSIFIED_PACKAGE_MARKERS,
    )
    present = sorted(
        path.as_posix()
        for path in FORBIDDEN_CLASSIFIED_PACKAGE_MARKERS
        if (repo_root / path).is_file()
    )
    if present:
        raise AssertionError(
            "package marker reintroduced over a main()-declaring classified "
            "root; mojo precompile tests/ will fail with \"'main()' is not "
            f'supported within packages": {present}'
        )
    mojo = shutil.which("mojo")
    if mojo is None:
        raise AssertionError("mojo is not available on PATH")
    with tempfile.TemporaryDirectory(prefix="mtest-precompile-guard-") as raw_tmp:
        output = Path(raw_tmp) / "tests.mojopkg"
        completed = subprocess.run(
            [mojo, "precompile", "-o", str(output), "tests/"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    if completed.returncode != 0:
        raise AssertionError(
            "mojo precompile tests/ failed "
            f"(rc={completed.returncode}): {completed.stderr.strip()[-2000:]}"
        )


def check_suite_layout() -> None:
    """Every classified module and support module has its documented home."""
    _require_nonempty("classified root", CLASSIFIED_ROOTS)
    check_classified_mojo_inventory(REPO_ROOT)
    tests_dir = REPO_ROOT / "tests"
    stray = {
        path.relative_to(REPO_ROOT)
        for path in tests_dir.rglob(CLASSIFIED_TEST_GLOB)
        if path.is_file() and path.parent.relative_to(REPO_ROOT) not in CLASSIFIED_ROOTS
    }
    if stray:
        raise AssertionError(
            "tests/ contains a test module outside unit/integration: "
            f"{sorted(str(path) for path in stray)}"
        )
    if not (tests_dir / "__init__.mojo").is_file():
        raise AssertionError(f"tests package marker missing: {tests_dir}")
    try:
        dogfood.dogfood_test_files(REPO_ROOT)
    except RuntimeError as exc:
        raise AssertionError(str(exc)) from exc


def check_e2e_layout() -> None:
    """Known-outcome CLI inputs stay outside self-host discovery."""
    pixi_manifest = tomllib.loads((REPO_ROOT / "pixi.toml").read_text(encoding="utf-8"))
    e2e_command = pixi_manifest.get("tasks", {}).get("e2e", {}).get("cmd")
    if e2e_command != "python -m scripts.e2e":
        raise AssertionError(
            "the sole E2E task command must be `python -m scripts.e2e`"
        )

    e2e_root = REPO_ROOT / "e2e"
    manifest_path = e2e_root / "manifest.json"
    if not manifest_path.is_file():
        raise AssertionError("e2e/manifest.json is missing")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("e2e_root") != "e2e":
        raise AssertionError("e2e manifest does not declare e2e_root=e2e")
    rows = set(manifest["tests"])
    discovered = {
        path.relative_to(REPO_ROOT).as_posix() for path in e2e_root.rglob("test_*.mojo")
    }
    if rows != discovered:
        raise AssertionError(
            "e2e manifest/discovery mismatch: "
            f"missing={sorted(discovered - rows)}, stale={sorted(rows - discovered)}, "
            f"rows={len(rows)}"
        )
    # Derived rather than a restated roster: registering a scenario is a
    # one-line addition to `SCENARIOS` with its owning module on the same line.
    # What a diff does not show is a name colliding with an existing one, where
    # the banner counts both while a reader assumes one name means one scenario,
    # or a registry that lost every entry and went vacuously green.
    scenario_names = tuple(name for name, _function in e2e_main.SCENARIOS)
    if not scenario_names:
        raise AssertionError("the E2E scenario registry is empty")
    if len(set(scenario_names)) != len(scenario_names):
        duplicates = sorted(
            {name for name in scenario_names if scenario_names.count(name) > 1}
        )
        raise AssertionError(f"duplicate E2E scenario names: {duplicates}")
    referenced = {
        *rows,
        *manifest.get("non_discovered", {}).keys(),
        *manifest.get("support_files", {}).keys(),
    }
    if any(not path.startswith("e2e/") for path in referenced):
        raise AssertionError("e2e manifest retains a path outside e2e/")


def check_platform_task_overrides(repo_root: Path = REPO_ROOT) -> None:
    """No platform table may silently replace a base task's command.

    A policy over an OPEN set rather than a mirror of the manifest: no task's
    command is restated here and adding a task costs no edit. What it bounds is
    the one construct that changes what a named gate RUNS without changing what
    anything calls it. See `PLATFORM_TASK_OVERRIDES` for the three-word attack.

    Four properties, each of which the attack has to defeat:

    - a `[target.<platform>]` table carries only known keys, so a new override
      construct cannot arrive unread;
    - an override names a task in `PLATFORM_TASK_OVERRIDES`, so a lane cannot
      be substituted for one platform;
    - an override is dependency-only (a table with `depends-on` and no `cmd`),
      so even a permitted entry cannot swap in a different command;
    - every allowlisted name still exists in the base `[tasks]` table, so a
      rename leaves a stale allowlist entry loud instead of vacuous.

    Args:
        repo_root: Repository root holding `pixi.toml`.

    Raises:
        AssertionError: The manifest is unreadable, the allowlist went empty
            or stale, a target table grew an unexpected key, or a platform
            override names a task outside the allowlist or carries a command.
    """
    _require_nonempty("platform task override", PLATFORM_TASK_OVERRIDES)
    _require_nonempty("platform target key", PLATFORM_TARGET_KEYS)
    manifest = tomllib.loads((repo_root / "pixi.toml").read_text(encoding="utf-8"))
    base_tasks = manifest.get("tasks")
    if not isinstance(base_tasks, dict):
        raise AssertionError("pixi.toml has no [tasks] table")
    stale = sorted(PLATFORM_TASK_OVERRIDES - set(base_tasks))
    if stale:
        raise AssertionError(
            "platform-override allowlist names a task that no longer exists in "
            f"the base [tasks] table: {stale}; a stale entry permits an "
            "override of something nothing else runs"
        )
    targets = manifest.get("target", {})
    if not isinstance(targets, dict):
        raise AssertionError("pixi.toml [target] is not a table")
    for name, table in sorted(targets.items()):
        if not isinstance(table, dict):
            raise AssertionError(f"[target.{name}] is not a table")
        unexpected = sorted(set(table) - PLATFORM_TARGET_KEYS)
        if unexpected:
            raise AssertionError(
                f"[target.{name}] carries unexpected keys {unexpected}; only "
                f"{sorted(PLATFORM_TARGET_KEYS)} are reasoned about here"
            )
        overrides = table.get("tasks", {})
        if not isinstance(overrides, dict):
            raise AssertionError(f"[target.{name}.tasks] is not a table")
        outside = sorted(set(overrides) - PLATFORM_TASK_OVERRIDES)
        if outside:
            raise AssertionError(
                f"[target.{name}.tasks] overrides {outside}, which is outside "
                f"the bounded set {sorted(PLATFORM_TASK_OVERRIDES)}; a platform "
                "override REPLACES the base command with no warning from pixi, "
                "so the lane keeps its name in `pixi run ci` and in the hosted "
                "matrix while running something else entirely"
            )
        for task_name, definition in sorted(overrides.items()):
            if not isinstance(definition, dict) or "depends-on" not in definition:
                raise AssertionError(
                    f"[target.{name}.tasks] entry {task_name!r} is not a "
                    "dependency-only override; a platform override may only "
                    "add a `depends-on` edge, never supply a command, because "
                    "the command it replaces is the one every other view of "
                    f"the floor believes is running: {definition!r}"
                )
            if "cmd" in definition:
                raise AssertionError(
                    f"[target.{name}.tasks] entry {task_name!r} supplies a "
                    "`cmd`, which replaces the base command for that platform "
                    f"alone: {definition!r}"
                )


def _shell_words(text: str) -> list[str]:
    """Split one command-like line, including commands inside quoted fields."""
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        lexer.commenters = ""
        words = list(lexer)
    except ValueError:
        return []
    expanded: list[str] = []
    for word in words:
        if any(character.isspace() for character in word):
            expanded.extend(_shell_words(word))
        else:
            expanded.append(word)
    return expanded


def _normalized_shell_word(word: str) -> str:
    """Strip presentation punctuation without changing command path content.

    A word lifted out of an argv literal arrives wearing the list's syntax:
    `[sys.executable,`, `"scripts/<name>.py"]`, `` `python ``. None of that is
    part of the command, and all of it would defeat an exact match.

    Args:
        word: One lexed word.

    Returns:
        The word with surrounding quoting, bracketing and separator
        punctuation removed.
    """
    return word.strip("`'\"[]{}(),:")


def _is_python_executable(word: str) -> bool:
    """Return whether a shell word names a Python interpreter.

    Args:
        word: One lexed word, still carrying its punctuation.

    Returns:
        True for `python`, a versioned or path-qualified spelling of it, or
        one of `PYTHON_EXECUTABLE_ALIASES`.
    """
    normalized = _normalized_shell_word(word)
    if normalized in PYTHON_EXECUTABLE_ALIASES:
        return True
    return PYTHON_EXECUTABLE_RE.fullmatch(Path(normalized).name.lower()) is not None


def _is_direct_script(word: str) -> bool:
    """Return whether a shell word is a repository-relative Python script.

    Args:
        word: One lexed word, still carrying its punctuation.

    Returns:
        True when the word is a `scripts/...py` operand.
    """
    normalized = _normalized_shell_word(word).removeprefix("./")
    return DIRECT_SCRIPT_RE.fullmatch(normalized) is not None


def _argv_direct_scripts(words: list[str]) -> list[str]:
    """Return every script operand handed to an interpreter in one word list.

    Walks from each interpreter word through its options to the first operand,
    which is where a script path and a `-m` module name are distinguishable:
    `-m` and `-c` end the walk (those are the correct forms), a value-taking
    option consumes the word after it, and anything else that is not an option
    is the operand.

    Args:
        words: One line's lexed words, in order.

    Returns:
        The `scripts/...py` operands found, in the order they appear.
    """
    found: list[str] = []
    for interpreter_index, word in enumerate(words):
        if not _is_python_executable(word):
            continue
        index = interpreter_index + 1
        while index < len(words):
            candidate = _normalized_shell_word(words[index])
            if candidate in {";", "&&", "||", "|", "(", ")"} or candidate in {
                "-m",
                "-c",
            }:
                break
            if candidate.startswith("-"):
                index += 2 if candidate in OPTION_TAKES_VALUE else 1
                continue
            if _is_direct_script(words[index]):
                found.append(candidate.removeprefix("./"))
            break
    return found


def direct_script_invocations(repo_root: Path = REPO_ROOT) -> tuple[str, ...]:
    """Return every by-path Python script command written into a tracked file.

    The scanned set is whatever `git ls-files` reports, so a new document,
    workflow or shell script is covered the moment it is tracked, and untracked
    notes or a linked worktree cannot make this read one file set locally and a
    different one on CI.

    Each line is read twice, because neither pass covers the other:

    - the raw-text pass (`DIRECT_SCRIPT_COMMAND_RE`) sees the prose form,
      `python -u scripts/<name>.py`, on any line, including the 4.3% of tracked
      lines that are not lexable as a command because prose spells an unpaired
      apostrophe;
    - the word pass (`_argv_direct_scripts`) sees the argv form, where quotes
      and a comma separate the interpreter from the operand:
      `subprocess.run([sys.executable, "scripts/<name>.py"])`. That is the form
      Python tooling writes, and the one that is really executed rather than
      copied by a reader.

    `python -m scripts.probe` matches neither pass: `-m` ends the word walk, and
    a dotted module name does not end in `.py`.

    Every example above spells the operand `scripts/<name>.py` deliberately.
    Written literally it would be a finding against this file, as the scan
    demonstrated by reporting all six of them on its first run.

    Args:
        repo_root: Repository root whose tracked files are scanned.

    Returns:
        One `path:line: operand` finding per invocation, in `git ls-files`
        order, deduplicated within a line so a form both passes recognise is
        reported once.

    Raises:
        AssertionError: `git ls-files` failed, or reported nothing to scan.
    """
    listed = subprocess.run(
        ["git", "-C", str(repo_root), "ls-files", "-z"],
        check=False,
        text=True,
        capture_output=True,
    )
    if listed.returncode != 0:
        raise AssertionError(
            f"could not list tracked files to scan: {listed.stderr.strip()}"
        )
    tracked = [name for name in listed.stdout.split("\0") if name]
    if not tracked:
        raise AssertionError("git reported no tracked file to scan")
    findings: list[str] = []
    for name in tracked:
        try:
            contents = (repo_root / name).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            # A binary asset, or a path in the index with no work-tree file.
            # Neither can carry a command line a reader would copy, and a
            # missing work-tree file is already someone else's loud failure.
            continue
        for number, line in enumerate(contents.splitlines(), start=1):
            operands = [
                match.group(1) for match in DIRECT_SCRIPT_COMMAND_RE.finditer(line)
            ]
            operands.extend(_argv_direct_scripts(_shell_words(line)))
            seen: set[str] = set()
            for operand in operands:
                if operand in seen:
                    continue
                seen.add(operand)
                findings.append(f"{name}:{number}: {operand}")
    return tuple(findings)


def check_python_package_invocation(repo_root: Path = REPO_ROOT) -> None:
    """Documented script commands name a module, never a file path.

    A script actually executed by path fails loudly on its own: it cannot
    resolve `from scripts.checks import ...`. Prose is the gap this closes.
    A command written into a README, a comment or a workflow is never run, so
    nothing else in the repository ever contradicts it, and a contributor who
    copies it gets an import traceback instead of the check they asked for.

    Args:
        repo_root: Repository root to scan.

    Raises:
        AssertionError: The `scripts` package marker is gone, or a tracked
            file spells a script command as an interpreter plus a path.
    """
    if not (repo_root / "scripts" / "__init__.py").is_file():
        raise AssertionError("scripts package marker is missing")
    findings = direct_script_invocations(repo_root)
    if findings:
        raise AssertionError(
            f"script commands written as an interpreter plus a path, which "
            f"cannot resolve this repository's imports: {list(findings)}"
        )


def check_build_source_visibility(repo_root: Path = REPO_ROOT) -> None:
    """Require the build-tool package to be complete, visible, and tracked."""
    _require_nonempty("build source", BUILD_SOURCE_PATHS)
    build_dir = repo_root / "scripts" / "build"
    actual = (
        {path.relative_to(repo_root) for path in build_dir.iterdir() if path.is_file()}
        if build_dir.is_dir()
        else set()
    )
    expected = set(BUILD_SOURCE_PATHS)
    if actual != expected:
        raise AssertionError(
            "scripts/build source membership mismatch: "
            f"missing={sorted(expected - actual)}, extra={sorted(actual - expected)}"
        )

    operands = [path.as_posix() for path in BUILD_SOURCE_PATHS]
    ignored = subprocess.run(
        ["git", "-C", str(repo_root), "check-ignore", "--no-index", *operands],
        check=False,
        text=True,
        capture_output=True,
    )
    if ignored.returncode not in (0, 1):
        raise AssertionError(
            f"could not inspect scripts/build ignore status: {ignored.stderr.strip()}"
        )
    if ignored.returncode == 0:
        raise AssertionError(
            f"scripts/build source is ignored: {ignored.stdout.splitlines()}"
        )

    tracked = subprocess.run(
        [
            "git",
            "-C",
            str(repo_root),
            "ls-files",
            "--error-unmatch",
            "--",
            *operands,
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    if tracked.returncode != 0:
        raise AssertionError("scripts/build source is untracked")


def companion_source_files(repo_root: Path = REPO_ROOT) -> set[Path]:
    """Return the public assertion companion's source files, read from disk.

    Nothing is declared. Adding a module to the shipped companion has to cost
    an edit in `recipe/build.sh`, the install line the package needs, and in
    `scripts/release/public_verify.py`, which cannot derive; it must
    not additionally cost an edit here, or this check would be pinning a list
    to a list instead of pinning what ships to what exists.

    Args:
        repo_root: Repository root the companion tree lives under.

    Returns:
        Repository-relative paths of every regular file under the companion's
        source root.
    """
    root = repo_root / COMPANION_SOURCE_ROOT
    if not root.is_dir():
        return set()
    return {
        path.relative_to(repo_root)
        for path in root.rglob("*")
        if not path.is_symlink() and path.is_file()
    }


def check_assertion_companion_layout(repo_root: Path = REPO_ROOT) -> None:
    """The shipped public companion is exactly what the recipe installs.

    A companion source file added without its `install -m 644` line ships a
    broken package, and that is invisible until the full `package-check`
    build runs, so it is reconciled here from disk against the recipe and
    against the installed-membership constant the package and public-channel
    gates share. The source-only shipping model is pinned the same way:
    neither build entrypoint may `mojo precompile` the companion, and the
    recipe may not sweep it in with a recursive copy, because either would
    quietly ship compiled artifacts in place of readable source.

    Args:
        repo_root: Repository root holding `companions/`, the build scripts
            and the recipe.

    Raises:
        AssertionError: The companion tree holds a symlink or a non-regular
            file, holds no source at all, leaked into the private package,
            disagrees with the recipe's install lines or with the installed
            membership, or is precompiled or recursively copied by a build.
    """
    companions = repo_root / "companions"
    entries = sorted(companions.rglob("*")) if companions.is_dir() else []
    linked = [path.relative_to(repo_root) for path in entries if path.is_symlink()]
    if linked:
        raise AssertionError(f"assertion companion contains symlinks: {linked}")
    irregular = [
        path.relative_to(repo_root)
        for path in entries
        if not stat.S_ISDIR(path.lstat().st_mode)
        and not stat.S_ISREG(path.lstat().st_mode)
    ]
    if irregular:
        raise AssertionError(
            f"assertion companion entry is not a regular file: {irregular}"
        )

    sources = companion_source_files(repo_root)
    if not sources:
        # Fail closed. Every comparison below is an equality against this set,
        # so an empty one would make all of them vacuously true.
        raise AssertionError(
            f"the public assertion companion has no source file under "
            f"{COMPANION_SOURCE_ROOT.as_posix()}"
        )
    if (repo_root / "src" / "mtest" / "assertions").exists():
        raise AssertionError("assertion companion leaked into private src/mtest")

    packaged_sources = {
        COMPANION_SOURCE_ROOT / path
        for path in package_consumption.INSTALLED_ASSERTION_FILES
    }
    if packaged_sources != sources:
        raise AssertionError(
            "assertion package-check membership mismatch: "
            f"missing={sorted(sources - packaged_sources)}, "
            f"extra={sorted(packaged_sources - sources)}"
        )

    production = (repo_root / "scripts" / "build" / "production_build.sh").read_text(
        encoding="utf-8"
    )
    recipe = (repo_root / "recipe" / "build.sh").read_text(encoding="utf-8")
    for name, contents in (
        ("production build", production),
        ("recipe build", recipe),
    ):
        if re.search(r"mojo\s+precompile[^\n]*companions/assertions", contents):
            raise AssertionError(f"{name} precompiles the public assertion source")
    installed_sources = {
        Path(match)
        for match in re.findall(
            r"(?m)^\s*install -m 644 (companions/assertions/src/\S+)", recipe
        )
    }
    if installed_sources != sources:
        raise AssertionError(
            "assertion recipe install membership mismatch: "
            f"missing={sorted(sources - installed_sources)}, "
            f"extra={sorted(installed_sources - sources)}"
        )
    if _recipe_recursively_copies_assertion_source(recipe):
        raise AssertionError("assertion recipe uses a recursive source copy")


def _recipe_recursively_copies_assertion_source(recipe: str) -> bool:
    """Return whether a `cp` command recursively copies the public source."""
    for line in recipe.splitlines():
        words = _shell_words(line)
        if not words or words[0] != "cp":
            continue
        recursive = any(
            word == "--recursive"
            or (
                word.startswith("-")
                and not word.startswith("--")
                and "r" in word[1:].lower()
            )
            for word in words[1:]
        )
        source = any(
            word == "companions/assertions" or word.startswith("companions/assertions/")
            for word in words[1:]
        )
        if recursive and source:
            return True
    return False


def check_vendored_toml_layout(repo_root: Path = REPO_ROOT) -> None:
    """Pin the native TOML source and its offline production-build path."""
    _require_nonempty("vendored TOML source", VENDORED_TOML_PATHS)
    vendor_root = repo_root / "vendor" / "mojo-toml"
    actual = {
        path.relative_to(repo_root) for path in vendor_root.rglob("*") if path.is_file()
    }
    if actual != VENDORED_TOML_PATHS:
        raise AssertionError(
            "vendored TOML membership mismatch: "
            f"missing={sorted(VENDORED_TOML_PATHS - actual)}, "
            f"extra={sorted(actual - VENDORED_TOML_PATHS)}"
        )

    manifest_path = vendor_root / "CHECKSUMS.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_metadata = {
        "repository": "https://github.com/DataBooth/mojo-toml",
        "license": "Apache-2.0",
        "release": VENDORED_TOML_RELEASE,
        "main": VENDORED_TOML_MAIN,
        "release_sha256": VENDORED_TOML_UPSTREAM_SHA256,
        "main_sha256": VENDORED_TOML_UPSTREAM_SHA256,
    }
    expected_keys = {*expected_metadata, "local_sha256"}
    if set(manifest) != expected_keys:
        raise AssertionError(
            "vendored TOML manifest key mismatch: "
            f"expected={sorted(expected_keys)}, got={sorted(manifest)}"
        )
    for key, expected in expected_metadata.items():
        if manifest.get(key) != expected:
            raise AssertionError(
                f"vendored TOML provenance mismatch for {key}: "
                f"expected={expected!r}, got={manifest.get(key)!r}"
            )
    local = manifest.get("local_sha256")
    if not isinstance(local, dict) or set(local) != VENDORED_TOML_LOCAL_CHECKSUM_PATHS:
        raise AssertionError(
            "vendored TOML local checksum membership mismatch: "
            f"expected={sorted(VENDORED_TOML_LOCAL_CHECKSUM_PATHS)}, "
            f"got={sorted(local) if isinstance(local, dict) else local!r}"
        )
    for relative, expected in local.items():
        actual_digest = hashlib.sha256(
            (vendor_root / relative).read_bytes()
        ).hexdigest()
        if actual_digest != expected:
            raise AssertionError(
                f"vendored TOML local checksum mismatch for {relative}: "
                f"expected={expected}, got={actual_digest}"
            )

    build_source = (repo_root / "scripts" / "build" / "production_build.sh").read_text(
        encoding="utf-8"
    )
    expected_precompile_arrays = (
        (
            "PRECOMPILE_CMD_TOML",
            (
                "mojo",
                "precompile",
                "--Werror",
                "vendor/mojo-toml/toml",
                "-o",
                "build/toml.mojoc",
            ),
        ),
        (
            "PRECOMPILE_CMD_MTEST",
            (
                "mojo",
                "precompile",
                "--Werror",
                "-I",
                "build",
                "src/mtest",
                "-o",
                "build/mtest.mojoc",
            ),
        ),
    )
    for name, expected in expected_precompile_arrays:
        definitions = re.findall(
            rf"(?ms)^{re.escape(name)}=\(\s*(.*?)^\s*\)\s*$",
            build_source,
        )
        actual_command = (
            tuple(shlex.split(definitions[0])) if len(definitions) == 1 else ()
        )
        if actual_command != expected:
            raise AssertionError(
                "production build does not compile and link the vendored TOML "
                f"package with the required warning-free .mojoc arrays: "
                f"{name} expected={expected!r}, got={actual_command!r}"
            )
    expected_links = {
        ("Linux", "x86_64"): (
            "mojo",
            "build",
            "-I",
            "build",
            "src/main.mojo",
            "-o",
            "build/mtest",
            "-O3",
            "-g0",
            "--Werror",
            "--target-cpu",
            "x86-64",
            "-Xlinker",
            "build/native/mtest_exec_native.o",
            "-Xlinker",
            "-lm",
        ),
        ("Darwin", "arm64"): (
            "mojo",
            "build",
            "-I",
            "build",
            "src/main.mojo",
            "-o",
            "build/mtest",
            "-O3",
            "-g0",
            "--Werror",
            "--target-cpu",
            "apple-m1",
            "--target-triple",
            "arm64-apple-macosx14.0.0",
            "-Xlinker",
            "build/native/mtest_exec_native.o",
        ),
    }
    build_script = repo_root / "scripts" / "build" / "production_build.sh"
    render = r"""
set -euo pipefail
source "$1"
select_profile "$2" "$3"
build_link_command
printf '%s\n' "${LINK_CMD[@]}"
"""
    for (system, machine), expected in expected_links.items():
        completed = subprocess.run(
            [
                "bash",
                "-c",
                render,
                "layout-production-link",
                str(build_script),
                system,
                machine,
            ],
            cwd=repo_root,
            check=False,
            capture_output=True,
            text=True,
        )
        actual_link = tuple(completed.stdout.splitlines())
        if completed.returncode != 0 or actual_link != expected:
            diagnostic = completed.stderr.strip()
            raise AssertionError(
                f"production release link for {system}/{machine} differs: "
                f"expected={expected!r}, got={actual_link!r}, "
                f"stderr={diagnostic!r}"
            )
    # Exactly two precompiles, counted at the INVOCATION rather than wherever
    # the words appear: the script discusses `mojo precompile` in prose, and a
    # substring count would read those comments as build steps. Both spellings
    # the script has used are accepted, a bare command line and the
    # `NAME=(mojo precompile ...)` argv array, because the claim being made is
    # "exactly two packages get precompiled" rather than how the stage is
    # written. Anchoring to one spelling let this check silently count zero
    # after the arrays landed.
    precompiles = re.findall(
        r"(?m)^\s*(?:[A-Za-z_][A-Za-z0-9_]*=\()?mojo precompile\b", build_source
    )
    if len(precompiles) != 2:
        raise AssertionError(
            "production build must execute exactly two package precompiles, "
            f"found {len(precompiles)}"
        )
    if re.search(r"\b(curl|wget|git\s+(clone|fetch|pull))\b", build_source):
        raise AssertionError("production build fetches a dependency from the network")


def _require_nonempty(name: str, values: object) -> None:
    """Reject an accidentally disabled intended inventory."""
    if not values:
        raise AssertionError(f"{name} intended inventory is empty")


def check_package_fixture_contract(repo_root: Path = REPO_ROOT) -> None:
    """The package gate's failing fixture still has its declared outcome.

    `scripts/build/package_consumption.py` runs one fixed known-failing fixture
    through the INSTALLED binary and asserts an exact verdict and per-test
    arithmetic. Those expectations are only meaningful while the fixture itself
    still declares them, and the package gate costs a full package build to
    discover a drift. This pins the two together in the cheap harness gate.

    Args:
        repo_root: Repository root to read the fixture and E2E manifest from.

    Raises:
        AssertionError: The fixture is missing, is not a real file, or its
            declared outcome disagrees with what the package gate asserts.
    """
    relative = package_consumption.FAILING_FIXTURE
    fixture = repo_root / relative
    if not fixture.is_file() or fixture.is_symlink():
        raise AssertionError(
            f"the package gate's failing fixture is not a real file: {relative}"
        )
    manifest = json.loads(
        (repo_root / "e2e" / "manifest.json").read_text(encoding="utf-8")
    )
    row = manifest["tests"].get(relative)
    if row is None:
        raise AssertionError(
            f"the package gate's failing fixture is not declared in the E2E "
            f"manifest: {relative}"
        )
    declared = (
        row["verdict"],
        row["exit_class"],
        row["per_test"]["passed"],
        row["per_test"]["failed"],
    )
    expected = (
        "FAIL",
        1,
        package_consumption.FAILING_FIXTURE_PASSED,
        package_consumption.FAILING_FIXTURE_FAILED,
    )
    if declared != expected:
        raise AssertionError(
            "the package gate's failing fixture no longer declares the outcome "
            f"the gate asserts: declared={declared}, gate expects={expected}"
        )


def main() -> int:
    """Run every repository layout and command-policy check serially."""
    try:
        # Before check_suite_layout: a reintroduced marker also trips the
        # inventory's glob check, and this one names the exact file and the
        # exact compiler error it will cause.
        check_classified_roots_are_not_precompilable_packages()
        check_suite_layout()
        check_e2e_layout()
        check_platform_task_overrides()
        check_python_package_invocation()
        check_build_source_visibility()
        check_assertion_companion_layout()
        check_vendored_toml_layout()
        check_package_fixture_contract()
    except (AssertionError, OSError, subprocess.SubprocessError) as exc:
        print(f"layout-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print("layout-check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
