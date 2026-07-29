#!/usr/bin/env python3
"""Adversarial protocol scenarios for the build-artifact cache, from outside.

Every other cache test in this repository runs inside one process: the Mojo
suites call `store_probe`, `store_publish`, and `clear_cache_root` directly,
one call at a time. Three properties are invisible from there.

- Concurrency. The publication protocol is about two processes racing for one
  generation directory. A single-process test can simulate the losing branch
  but cannot witness the race, so the scenarios here spawn real `build/mtest`
  processes into one shared store and assert what the store looks like after.
- Faults in a window no fake compiler can reach. The two windows worth
  faulting, before the durability flush and between the flush and the commit
  rename, are inside mtest's own process after the compiler child has exited.
  `src/mtest/session/store.mojo` therefore carries a test-only seam,
  `MTEST_STORE_FAULT`, which these scenarios drive from the environment; see
  that module's docstring for what each value abandons.
- The wiring in `src/main.mojo`. `_resolution_defaults` and the
  `--cache-clear` branch are private defs in the executable target, and
  nothing under `tests/` can import `main.mojo`. A regression that drops
  `defaults.no_cache` or `defaults.cache_clear` from the resolution projection
  turns those flags into no-ops that every other gate still reports green;
  `NoCacheTests` and `CacheClearTests` are what goes red.

These are pinning tests. Every scenario except the two fault ones landed after
the behavior it describes and passed on first run. The fault scenarios are the
genuine red step: the seam did not exist until they demanded it.

Each scenario drives a throwaway project of its own (`tempfile.mkdtemp`, torn
down after) and reads the run's `--json` NDJSON stream rather than the console.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import ClassVar, override
import unittest


REPO = Path(__file__).resolve().parents[2]
MTEST = REPO / "build" / "mtest"

RUN_TIMEOUT_SECONDS = 300
"""Ceiling on one `mtest` invocation. A timeout is a FAIL, never a skip.

Sized well above a cold run of one file, because a false timeout on a loaded
host reads exactly like the deadlock these concurrency scenarios look for.
"""

CACHE_ROOT_REL = ".mtest-cache"
"""The whole directory mtest owns, mirroring `store.mojo`'s `CACHE_ROOT_DIR`."""

STORE_REL = ".mtest-cache/build-v1"
"""The generation store, mirroring `store.mojo`'s `STORE_DIR`."""

TAG_REL = ".mtest-cache/CACHEDIR.TAG"
"""The ownership marker, mirroring `store.mojo`'s `CACHEDIR_TAG_REL`."""

STAGING_PREFIX = ".tmp-"
"""Leading component of a staging directory, mirroring `store.mojo`."""

TEST_SOURCE = """\
from std.testing import assert_equal, TestSuite


def test_{name}() raises:
    assert_equal(1, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
"""

HELPER_SOURCE = """\
def helper_value() -> Int:
    return {value}
"""
"""A module sitting BESIDE the test files, imported by bare name.

No `-I` reaches it: the compiler resolves a bare import against the source
file's own directory, which is the ordinary way neighbouring suites share
fixtures and a search path the key has to cover on its own.
"""

READS_HELPER_SOURCE = """\
from helper import helper_value
from std.testing import assert_equal, TestSuite


def test_reads_helper() raises:
    assert_equal(helper_value(), 7)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
"""
"""A suite whose verdict is decided by the helper next to it.

The assertion is what makes a stale hit visible: a suite that merely imported
the helper would pass either way, so the edit has to be able to flip the exit
code.
"""

FIXTURE_SUITE_SOURCE = """\
from std.testing import assert_true, TestSuite


def make_fixture() -> Int:
    return {value}


def test_helpers_own() raises:
    assert_true(True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
"""
"""A file that is BOTH a discovered test file and its neighbours' fixtures.

`test_helpers.mojo` matches the discovery glob, so it is omitted from the
directory walk that keys its neighbours, while staying importable from every
one of them. Together those are the shape a stale hit comes from.
"""

READS_FIXTURE_SOURCE = """\
from test_helpers import make_fixture
from std.testing import assert_equal, TestSuite


def test_session_uses_the_fixture() raises:
    assert_equal(make_fixture(), 7)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
"""
"""A suite whose verdict is decided by a fixture file named like a test file."""

TRIPWIRE_SOURCE = """\
from std.os.path import exists
from std.testing import assert_false, TestSuite


def test_tripwire() raises:
    assert_false(exists("tripped"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
"""
"""A suite whose verdict flips on a file at the invocation root.

The key covers the directory a test file sits in and every `-I` root, never
the working directory, so creating the sentinel turns a passing warm run into
a failing one without moving a single key. That makes an early stop observable
over a store where every file hits.
"""

STATELESS_CONFIG = "[run]\nstate = false\n"
"""A project file that turns last-run persistence off.

`.mtest-cache/lastrun` lives inside the directory `--cache-clear` deletes, so a
scenario that wants to observe the *cleared* directory has to stop the same
invocation's session from writing the state file straight back into it.
"""


def require_environment() -> None:
    """Fail closed unless the binary under test and a real compiler both exist.

    Raises:
        AssertionError: If `build/mtest` is missing, or `mojo` is not on PATH.
            Both are supplied by the `cache-protocol-check` task's `build-bin`
            dependency and by running under `pixi run`.
    """
    if not MTEST.is_file():
        raise AssertionError(
            f"{MTEST} is missing — run `pixi run cache-protocol-check`, whose "
            "`build-bin` dependency produces the binary these scenarios drive"
        )
    if shutil.which("mojo") is None:
        raise AssertionError(
            "`mojo` is not on PATH — these scenarios spawn real per-file "
            "builds, so run them under `pixi run`"
        )


def child_environment(fault: str = "") -> dict[str, str]:
    """The environment every spawned `mtest` inherits.

    `MTEST_MOJO` is scrubbed so a contributor's stray override cannot build the
    scaffold with a different toolchain than the one the key was formed over,
    and `MTEST_STORE_FAULT` is scrubbed so an ambient value cannot make a
    non-fault scenario silently exercise the seam.

    Args:
        fault: The `MTEST_STORE_FAULT` value to set, or the empty string to
            leave the variable unset entirely.

    Returns:
        A complete environment dictionary for `subprocess`.
    """
    env = dict(os.environ)
    env.pop("MTEST_MOJO", None)
    env.pop("MTEST_STORE_FAULT", None)
    if fault:
        env["MTEST_STORE_FAULT"] = fault
    return env


def scaffold(names: tuple[str, ...]) -> Path:
    """Write a throwaway project holding one trivially-passing suite per name.

    The suites import nothing but the standard library, so a run needs no `-I`
    and no precompile step. That matters: `mojo precompile` is not
    byte-deterministic on this toolchain, so a scenario whose precompile step
    re-runs would move the session key prefix and see zero hits through no
    fault of the store.

    Args:
        names: The suite names; each becomes `tests/test_<name>.mojo` holding
            one `test_<name>` that always passes.

    Returns:
        The project root. The caller owns it and must remove it.
    """
    root = Path(tempfile.mkdtemp(prefix="mtest-cache-protocol-"))
    tests = root / "tests"
    tests.mkdir()
    for name in names:
        (tests / f"test_{name}.mojo").write_text(
            TEST_SOURCE.format(name=name), encoding="utf-8"
        )
    return root


def run_mtest(
    root: Path, argv: list[str], *, fault: str = ""
) -> subprocess.CompletedProcess[str]:
    """Run the binary under test inside one project, capturing both streams.

    Args:
        root: The project directory the run uses as its working directory.
        argv: Arguments passed after the binary path.
        fault: The `MTEST_STORE_FAULT` value for this run, or empty for none.

    Returns:
        The completed process, both streams decoded as text.
    """
    return subprocess.run(
        [str(MTEST), *argv],
        cwd=root,
        env=child_environment(fault),
        capture_output=True,
        text=True,
        timeout=RUN_TIMEOUT_SECONDS,
        check=False,
    )


def run_concurrently(
    root: Path, argv_list: list[list[str]], *, fault: str = ""
) -> list[subprocess.CompletedProcess[str]]:
    """Spawn several `mtest` processes into one project and wait for them all.

    Every process is started before any is waited on, which is what puts two
    publications into the same window; waiting on the first before spawning the
    second would serialize exactly the race under test.

    Args:
        root: The shared project directory, and therefore the shared store.
        argv_list: One argument list per process, in spawn order.
        fault: The `MTEST_STORE_FAULT` value for every process, or empty.

    Returns:
        One completed process per entry of `argv_list`, in the same order.
    """
    env = child_environment(fault)
    processes = [
        subprocess.Popen(
            [str(MTEST), *argv],
            cwd=root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        for argv in argv_list
    ]
    completed: list[subprocess.CompletedProcess[str]] = []
    for process, argv in zip(processes, argv_list, strict=True):
        out, err = process.communicate(timeout=RUN_TIMEOUT_SECONDS)
        completed.append(
            subprocess.CompletedProcess(
                [str(MTEST), *argv], process.returncode, out, err
            )
        )
    return completed


def stream_records(path: Path) -> list[dict[str, object]]:
    """Read one run's NDJSON event stream.

    Args:
        path: The file the run was pointed at with `--json`.

    Returns:
        Every record in emission order.

    Raises:
        AssertionError: If the stream is missing, which means the run died
            before writing anything and no later assertion about it is honest.
    """
    if not path.is_file():
        raise AssertionError(f"the run wrote no machine event stream at {path}")
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def event(records: list[dict[str, object]], name: str) -> dict[str, object]:
    """The single record carrying one event name.

    Args:
        records: A stream as `stream_records` returned it.
        name: The `event` value to select.

    Returns:
        The one matching record.

    Raises:
        AssertionError: If the stream holds no such record, or more than one.
    """
    matches = [record for record in records if record.get("event") == name]
    if len(matches) != 1:
        raise AssertionError(
            f"expected exactly one {name!r} event, the stream holds {len(matches)}"
        )
    return matches[0]


def warnings_of(records: list[dict[str, object]], kind: str) -> list[str]:
    """Every warning of one kind, as its rendered pattern text.

    Args:
        records: A stream as `stream_records` returned it.
        kind: The `warning_kind` to select.

    Returns:
        The `warning_pattern` of each matching warning, in emission order.
    """
    return [
        str(record.get("warning_pattern", ""))
        for record in records
        if record.get("event") == "warning" and record.get("warning_kind") == kind
    ]


def counter(record: dict[str, object], name: str) -> int:
    """One integer field of a record, checked rather than assumed.

    Args:
        record: The record to read.
        name: The field name.

    Returns:
        The field's value.

    Raises:
        AssertionError: If the field is absent or is not an integer, which is a
            stream-contract break rather than a cache finding.
    """
    value = record.get(name)
    if not isinstance(value, int):
        raise AssertionError(f"{name!r} is {value!r}, not an integer")
    return value


def build_argv_of(record: dict[str, object]) -> list[str]:
    """The `build_argv` a `file_finished` record carries.

    Args:
        record: A `file_finished` record.

    Returns:
        The recorded command line, one token per element.

    Raises:
        AssertionError: If the field is missing, is not a list of strings, or
            was truncated, since a truncated line cannot be compared to a meta
            file.
    """
    if counter(record, "build_argv_omitted") != 0:
        raise AssertionError("build_argv was truncated; the comparison is void")
    tokens = record.get("build_argv")
    if not isinstance(tokens, list) or not all(
        isinstance(token, str) for token in tokens
    ):
        raise AssertionError(f"build_argv is {tokens!r}, not a list of strings")
    return [str(token) for token in tokens]


def counters(path: Path) -> tuple[int, int]:
    """One run's `(built_files, cached_files)` from its terminal event.

    Args:
        path: The file the run was pointed at with `--json`.

    Returns:
        The two build-cache counters the run finished with.
    """
    finished = event(stream_records(path), "session_finished")
    return counter(finished, "built_files"), counter(finished, "cached_files")


def generations(root: Path) -> list[str]:
    """Every published generation in one project's store, sorted.

    Staging directories are excluded: a `.tmp-` name is a live or abandoned
    build, never something a later run can probe, adopt, or publish.

    Args:
        root: The project root.

    Returns:
        The generation directory names, or an empty list when the store does
        not exist at all.
    """
    store = root / STORE_REL
    if not store.is_dir():
        return []
    return sorted(
        entry.name
        for entry in store.iterdir()
        if not entry.name.startswith(STAGING_PREFIX)
    )


def meta_argv(root: Path, generation: str) -> list[str]:
    """The command line one generation's `meta` record names.

    Args:
        root: The project root.
        generation: A generation directory name from `generations`.

    Returns:
        The decoded argv tokens, in order. Each `arg` line is hex-encoded so a
        token holding a newline cannot break the record's line structure.
    """
    text = (root / STORE_REL / generation / "meta").read_text(encoding="utf-8")
    return [
        bytes.fromhex(line.removeprefix("arg ")).decode("utf-8")
        for line in text.splitlines()
        if line.startswith("arg ")
    ]


def output_generation(argv: list[str]) -> str:
    """The generation directory a recorded command line writes its `-o` into.

    Args:
        argv: A build command line.

    Returns:
        The name of the directory holding the `-o` operand.

    Raises:
        AssertionError: If the command line carries no `-o` operand.
    """
    if "-o" not in argv:
        raise AssertionError(f"no -o operand in {argv!r}")
    return Path(argv[argv.index("-o") + 1]).parent.name


def identity(path: Path) -> tuple[int, int, int]:
    """A file's `(device, inode, mtime-ns)`, as an untouched-ness witness.

    Args:
        path: The file or directory to characterize.

    Returns:
        The triple. A rewritten-in-place or republished artifact moves at least
        one of the three; comparing content alone would miss a rewrite with
        identical bytes, which is exactly what a redundant republication is.
    """
    info = path.stat()
    return info.st_dev, info.st_ino, info.st_mtime_ns


def store_identities(root: Path) -> dict[str, tuple[int, int, int]]:
    """Every store artifact's identity, keyed by its path relative to the root.

    Args:
        root: The project root.

    Returns:
        One entry per generation directory and per file inside it.
    """
    out: dict[str, tuple[int, int, int]] = {}
    store = root / STORE_REL
    for entry in sorted(store.rglob("*")):
        out[str(entry.relative_to(root))] = identity(entry)
    out[STORE_REL] = identity(store)
    return out


class ProtocolScenario(unittest.TestCase):
    """One throwaway project per scenario, removed when the scenario ends."""

    file_names: ClassVar[tuple[str, ...]] = ("alpha",)

    @override
    def setUp(self) -> None:
        require_environment()
        self.root = scaffold(self.file_names)
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def run_ok(
        self, argv: list[str], *, fault: str = ""
    ) -> subprocess.CompletedProcess[str]:
        """Run `mtest` and require exit 0, reporting both streams if not."""
        completed = run_mtest(self.root, argv, fault=fault)
        self.assertEqual(
            completed.returncode,
            0,
            msg=f"argv={argv!r} stdout={completed.stdout!r} "
            f"stderr={completed.stderr!r}",
        )
        return completed

    def stream(self, name: str) -> list[dict[str, object]]:
        """One run's stream, by the `--json` filename it was given."""
        return stream_records(self.root / name)


class ConcurrencyTests(ProtocolScenario):
    """Two real mtest processes, one shared store, one publication window."""

    def test_concurrent_same_key_runs_both_pass(self) -> None:
        first, second = run_concurrently(
            self.root,
            [
                ["--json", "one.ndjson", "tests"],
                ["--json", "two.ndjson", "tests"],
            ],
        )

        self.assertEqual(
            (first.returncode, second.returncode),
            (0, 0),
            msg=f"one={first.stderr!r} two={second.stderr!r}",
        )
        # Same key, so the loser's rename lands on a directory that already
        # exists; it re-probes the winner in full and adopts it. Two survivors
        # would mean the generation name is not a function of the key alone.
        self.assertEqual(len(generations(self.root)), 1, msg=str(self.root))
        for name in ("one.ndjson", "two.ndjson"):
            built, cached = counters(self.root / name)
            # Which of the two is 1 depends on whether the second process
            # probed before the first published, which is a scheduling
            # question. What the protocol owes is that the file is admitted
            # exactly once, from exactly one source.
            self.assertEqual((name, built + cached), (name, 1))
            # ...and that BOTH sources were the cache. A loser that hit a
            # contended store and degraded to an uncached build would satisfy
            # the sum above with `built = 1`, so the sum alone cannot tell a
            # handled race from an abandoned one. Losing a rename must never
            # spend the session's cache.
            off = warnings_of(self.stream(name), "cache-off")
            self.assertEqual((name, off), (name, []))
        # The survivor is not merely present: it validates, key and binary
        # digest both, or this third run would rebuild instead of hitting.
        self.run_ok(["--json", "three.ndjson", "tests"])
        self.assertEqual(counters(self.root / "three.ndjson"), (0, 1))

    def test_concurrent_different_args_do_not_cross(self) -> None:
        low = ["--build-arg=-O0", "--json", "low.ndjson", "tests"]
        high = ["--build-arg=-O1", "--json", "high.ndjson", "tests"]

        first, second = run_concurrently(self.root, [low, high])

        self.assertEqual(
            (first.returncode, second.returncode),
            (0, 0),
            msg=f"low={first.stderr!r} high={second.stderr!r}",
        )
        low_gen = output_generation(
            build_argv_of(event(self.stream("low.ndjson"), "file_finished"))
        )
        high_gen = output_generation(
            build_argv_of(event(self.stream("high.ndjson"), "file_finished"))
        )
        # The build arguments are frame 7 of the key, so two runs that differ
        # only there must name different generations...
        self.assertNotEqual(low_gen, high_gen)
        # ...and neither may serve the other: a cache hit here would be a
        # binary built with the optimization level the run did not ask for.
        self.assertEqual(counters(self.root / "low.ndjson")[1], 0)
        self.assertEqual(counters(self.root / "high.ndjson")[1], 0)

        # Publishing reaps this source's superseded generations, so which of
        # the two survives a concurrent finish is a race. Settle each in turn
        # and read the record it left: whatever the race did, a generation's
        # `meta` must describe the build that produced it and no other.
        self.run_ok(low)
        self.assertIn(low_gen, generations(self.root))
        low_meta = meta_argv(self.root, low_gen)
        self.assertIn("-O0", low_meta)
        self.assertNotIn("-O1", low_meta)
        self.assertEqual(output_generation(low_meta), low_gen)

        self.run_ok(high)
        self.assertIn(high_gen, generations(self.root))
        high_meta = meta_argv(self.root, high_gen)
        self.assertIn("-O1", high_meta)
        self.assertNotIn("-O0", high_meta)
        self.assertEqual(output_generation(high_meta), high_gen)


class PublicationFaultTests(ProtocolScenario):
    """The two publication windows no fake compiler can reach.

    Both are inside `store_publish`, after the compiler child has exited, so
    they are driven through `store.mojo`'s test-only `MTEST_STORE_FAULT` seam.
    Staging into a private directory and committing with one `rename(2)` buys
    the same property for both: an interrupted publication leaves NO generation
    behind, partial or unvalidated, and the next ordinary run rebuilds and
    publishes cleanly.
    """

    def _assert_abandoned(self, window: str) -> None:
        """Drive one fault window and assert the store came out of it clean."""
        self.run_ok(["--json", "faulted.ndjson", "tests"], fault=window)

        # The build itself survives a failed publication: the session keeps
        # running the staged binary, so the run is green and the file is still
        # counted as built.
        self.assertEqual(counters(self.root / "faulted.ndjson"), (1, 0))
        published = warnings_of(self.stream("faulted.ndjson"), "cache-publish")
        self.assertEqual(len(published), 1, msg=f"warnings={published!r}")
        self.assertIn(f"MTEST_STORE_FAULT={window}", published[0])
        self.assertIn("tests/test_alpha.mojo", published[0])
        # Nothing publishable is left behind. Staging debris may remain, since
        # it carries the writing process's pid and no later run can adopt it,
        # but a generation a later run could probe must not exist.
        self.assertEqual(generations(self.root), [])
        self.assertTrue((self.root / TAG_REL).is_file(), msg="marker missing")

        # The store is not poisoned: the next ordinary run rebuilds...
        self.run_ok(["--json", "clean.ndjson", "tests"])
        self.assertEqual(counters(self.root / "clean.ndjson"), (1, 0))
        self.assertEqual(len(generations(self.root)), 1)
        # ...and what it published is a generation that validates.
        self.run_ok(["--json", "warm.ndjson", "tests"])
        self.assertEqual(counters(self.root / "warm.ndjson"), (0, 1))

    # The two cases below assert the SAME properties, because from outside the
    # process the two windows are the same event: both abandon the staging
    # directory before the one `rename(2)` that would publish anything. The
    # only difference is whether the durability flush had already run, and a
    # flush leaves no trace in a directory that is then discarded.
    #
    # What the pair still buys: each window is REACHED. A seam that stopped
    # honoring one of the two values would leave that case with a published
    # generation and no warning, and it goes red on its own.

    def test_fault_before_rename_leaves_no_generation(self) -> None:
        self._assert_abandoned("before-rename")

    def test_fault_before_fsync_same(self) -> None:
        self._assert_abandoned("before-fsync")

    def test_an_unrecognized_fault_value_is_inert(self) -> None:
        # The seam is test-only, so an unknown value must behave exactly like
        # an absent one rather than becoming a third, unreviewed window.
        self.run_ok(["--json", "odd.ndjson", "tests"], fault="before-nothing")

        self.assertEqual(counters(self.root / "odd.ndjson"), (1, 0))
        self.assertEqual(warnings_of(self.stream("odd.ndjson"), "cache-publish"), [])
        self.assertEqual(len(generations(self.root)), 1)


class UnrunnableGenerationTests(ProtocolScenario):
    """A stored binary whose mode bits were dropped, over real processes.

    Every other corruption changes a generation's bytes, so the digest check
    catches it and the store heals itself. This one changes only the
    permission, and the only way to tell it from a usable artifact is to ask
    whether it can be spawned. The symptom lives outside the store: the run
    reaches the supervisor, cannot execute the path it was handed, and reports
    an internal error on a suite that passes. The realistic sources are
    restores: a CI cache archive, a container image `COPY`, a `chmod -R` swept
    over a checkout.
    """

    def test_a_generation_that_cannot_be_executed_is_rebuilt(self) -> None:
        self.run_ok(["--json", "cold.ndjson", "tests"])
        (generation,) = generations(self.root)
        binary = self.root / STORE_REL / generation / "bin"
        self.assertEqual(counters(self.root / "cold.ndjson"), (1, 0))

        binary.chmod(0o600)

        # No cache condition may fail a run that would otherwise pass, so this
        # is a miss and a rebuild rather than an internal error over a suite
        # whose source never changed.
        completed = self.run_ok(["--json", "restored.ndjson", "tests"])
        self.assertNotIn("INTERNAL-ERROR", completed.stdout)
        self.assertEqual(counters(self.root / "restored.ndjson"), (1, 0))

        # And it heals: the rebuilt generation is served on the next run. A
        # probe that reported the unrunnable artifact as a hit would leave it in
        # place and fail every later run over the same store, forever.
        self.run_ok(["--json", "warm.ndjson", "tests"])
        self.assertEqual(counters(self.root / "warm.ndjson"), (0, 1))


class ToolchainIdentityTests(ProtocolScenario):
    """Frame 2 of the key: the compiler's own bytes, not merely its path."""

    def test_wrapper_content_changes_key(self) -> None:
        wrapper = self.root / "mojo-wrapper"
        real = shutil.which("mojo")
        self.assertIsNotNone(real)
        wrapper.write_text(
            f'#!/bin/sh\n# revision one\nexec "{real}" "$@"\n', encoding="utf-8"
        )
        wrapper.chmod(0o755)
        argv = ["--mojo", str(wrapper), "--json", "cold.ndjson", "tests"]

        self.run_ok(argv)
        self.assertEqual(counters(self.root / "cold.ndjson"), (1, 0))
        first_generation = generations(self.root)
        self.assertEqual(len(first_generation), 1)

        # Same wrapper, same bytes: a steady-state hit, which is what makes the
        # next assertion about a *changed* wrapper mean something.
        self.run_ok(["--mojo", str(wrapper), "--json", "warm.ndjson", "tests"])
        self.assertEqual(counters(self.root / "warm.ndjson"), (0, 1))
        self.assertEqual(generations(self.root), first_generation)

        # One byte-different wrapper at the SAME path invoking the SAME
        # compiler. Keying on the spelling alone would serve the stale binary
        # here; keying on the resolved executable's content does not.
        wrapper.write_text(
            f'#!/bin/sh\n# revision two\nexec "{real}" "$@"\n', encoding="utf-8"
        )
        wrapper.chmod(0o755)
        self.run_ok(["--mojo", str(wrapper), "--json", "moved.ndjson", "tests"])

        self.assertEqual(counters(self.root / "moved.ndjson"), (1, 0))
        second_generation = generations(self.root)
        self.assertEqual(len(second_generation), 1)
        self.assertNotEqual(second_generation, first_generation)


class IncludeRootTests(ProtocolScenario):
    """An include root the key cannot characterize turns the cache OFF."""

    file_names: ClassVar[tuple[str, ...]] = ("alpha", "beta")

    def test_fifo_in_include_root_disables_cache(self) -> None:
        include = self.root / "inc"
        include.mkdir()
        # A FIFO named like a source is the sharpest shape of "the walk cannot
        # digest this": the compiler would see the name, and the key cannot
        # represent the contents. Fail-closed means the whole cache goes off,
        # loudly, rather than keying a tree it only partly read.
        os.mkfifo(include / "mod.mojo")

        self.run_ok(["-I", "inc", "--json", "off.ndjson", "tests"])

        records = self.stream("off.ndjson")
        off = warnings_of(records, "cache-off")
        self.assertEqual(len(off), 1, msg=f"warnings={off!r}")
        self.assertIn("include root 'inc'", off[0])
        self.assertIn("mod.mojo", off[0])
        # Off means off: every selected file is built, and nothing at all is
        # served or staged.
        self.assertEqual(counters(self.root / "off.ndjson"), (2, 0))
        self.assertEqual(generations(self.root), [])
        self.assertFalse((self.root / STORE_REL).exists(), msg="store created")
        # The ownership marker is not part of "off". It belongs to the
        # `.mtest-cache` DIRECTORY, which this run created anyway for its
        # last-run state, and every directory mtest creates carries the proof
        # that it is mtest's, or `--cache-clear` would refuse to delete a tree
        # this same run had just made.
        self.assertTrue((self.root / TAG_REL).is_file(), msg="marker missing")


class SiblingSearchPathTests(ProtocolScenario):
    """A test file's own directory is a search path, so its contents are inputs.

    `mojo build tests/test_x.mojo` resolves a bare `from helper import ...`
    against `tests/`, with no `-I` involved and nothing reported afterwards
    about what it read. A key blind to that directory serves a binary compiled
    against the previous helper, so the run goes green over source that now
    fails.
    """

    def test_editing_a_helper_beside_the_test_rebuilds_and_reverses(self) -> None:
        tests = self.root / "tests"
        (tests / "helper.mojo").write_text(
            HELPER_SOURCE.format(value=7), encoding="utf-8"
        )
        (tests / "test_reader.mojo").write_text(READS_HELPER_SOURCE, encoding="utf-8")

        self.run_ok(["--json", "cold.ndjson", "tests"])
        self.assertEqual(counters(self.root / "cold.ndjson"), (2, 0))
        self.run_ok(["--json", "warm.ndjson", "tests"])
        self.assertEqual(counters(self.root / "warm.ndjson"), (0, 2))

        (tests / "helper.mojo").write_text(
            HELPER_SOURCE.format(value=999), encoding="utf-8"
        )
        edited = run_mtest(self.root, ["--json", "edited.ndjson", "tests"])

        # Both files rebuild, and deliberately so: the helper is reachable from
        # every test in the directory and `mojo build` reports no dependency
        # information, so mtest cannot know which of them actually read it.
        self.assertEqual(counters(self.root / "edited.ndjson"), (2, 0))
        # The verdict is the point. Exit 1 means the binary that ran was built
        # from the helper on disk; exit 0 would mean a green run over source
        # that fails.
        self.assertEqual(
            edited.returncode,
            1,
            msg=f"stdout={edited.stdout!r} stderr={edited.stderr!r}",
        )

    def test_a_fixture_file_named_like_a_test_is_still_keyed(self) -> None:
        # `test_helpers.mojo` and `test_common.mojo` are ordinary names for
        # shared fixture files, and both match the discovery glob, so both are
        # left out of their neighbours' keys. That is only safe because the
        # importer's own imports are read; being wrong here is a green run over
        # a fixture that no longer returns what the suite asserts.
        tests = self.root / "tests"
        (tests / "test_helpers.mojo").write_text(
            FIXTURE_SUITE_SOURCE.format(value=7), encoding="utf-8"
        )
        (tests / "test_session.mojo").write_text(READS_FIXTURE_SOURCE, encoding="utf-8")

        self.run_ok(["--json", "cold.ndjson", "tests"])
        self.run_ok(["--json", "warm.ndjson", "tests"])
        self.assertEqual(counters(self.root / "warm.ndjson"), (0, 3))

        (tests / "test_helpers.mojo").write_text(
            FIXTURE_SUITE_SOURCE.format(value=999), encoding="utf-8"
        )
        edited = run_mtest(self.root, ["--json", "edited.ndjson", "tests"])

        built, cached = counters(self.root / "edited.ndjson")
        # `test_session` named the fixture file, so it keys over the whole
        # directory and rebuilds with it. `test_alpha` named nothing there and
        # keeps its own key; losing that precision would rebuild every
        # unrelated suite whenever any fixture moved.
        self.assertEqual((built, cached), (2, 1))
        self.assertEqual(
            edited.returncode,
            1,
            msg=f"stdout={edited.stdout!r} stderr={edited.stderr!r}",
        )

    def test_editing_one_test_file_leaves_its_neighbour_cached(self) -> None:
        tests = self.root / "tests"
        # A helper makes the directory walk non-empty, so a pass here means the
        # test files really were left out of it rather than there being nothing
        # to leave out.
        (tests / "helper.mojo").write_text(
            HELPER_SOURCE.format(value=7), encoding="utf-8"
        )
        (tests / "test_beta.mojo").write_text(
            TEST_SOURCE.format(name="beta"), encoding="utf-8"
        )

        self.run_ok(["--json", "cold.ndjson", "tests"])
        self.assertEqual(counters(self.root / "cold.ndjson"), (2, 0))

        (tests / "test_alpha.mojo").write_text(
            TEST_SOURCE.format(name="alpha_renamed"), encoding="utf-8"
        )
        self.run_ok(["--json", "edited.ndjson", "tests"])

        # A test file beside another is an entry point of its own, already keyed
        # by its own source frame. Folding neighbours into each other would make
        # every one-line edit rebuild the whole directory.
        self.assertEqual(counters(self.root / "edited.ndjson"), (1, 1))


@unittest.skipUnless(
    sys.platform == "darwin",
    "case-insensitive path resolution is a macOS filesystem property",
)
class CaseFoldTests(ProtocolScenario):
    """One file reachable by two spellings must not make the cache flap.

    macOS volumes are case-insensitive by default, so `tests/test_alpha.mojo`
    and `tests/TEST_ALPHA.mojo` open the same inode while remaining two
    different strings. The key frames the test file by its root-relative path
    as given, and the artifact directory is named from that same path, so the
    two spellings are two keys over identical bytes.

    That is fine as long as they stay independent. The failure this guards is
    the alternating one: if either spelling's publication reaped or overwrote
    the other's artifact, a developer whose editor and build script disagreed
    about the case of one path would see every run rebuild what the previous
    run had just cached, with no warning.
    """

    def test_a_case_variant_operand_does_not_flap(self) -> None:
        lower = "tests/test_alpha.mojo"
        upper = "tests/TEST_ALPHA.mojo"
        if not (self.root / upper).is_file():
            self.skipTest(
                "this volume resolves paths case-sensitively, so the two "
                "spellings are genuinely two files and there is no alias to test"
            )

        self.run_ok(["--json", "cold.ndjson", lower])
        self.assertEqual(counters(self.root / "cold.ndjson"), (1, 0))
        self.run_ok(["--json", "warm.ndjson", lower])
        self.assertEqual(counters(self.root / "warm.ndjson"), (0, 1))

        # The other spelling may build or may hit, depending on how the key
        # frames the path; that is not what this pins.
        self.run_ok(["--json", "other-first.ndjson", upper])
        self.run_ok(["--json", "other-second.ndjson", upper])
        self.assertEqual(counters(self.root / "other-second.ndjson"), (0, 1))

        # The claim: the second spelling settling did not cost the first
        # spelling the artifact it had already published.
        self.run_ok(["--json", "back.ndjson", lower])
        self.assertEqual(
            counters(self.root / "back.ndjson"),
            (0, 1),
            msg=f"generations={generations(self.root)}",
        )
        # And the store did not grow past one live artifact per spelling: the
        # superseded-sibling sweep still runs, it just does not cross spellings.
        self.assertLessEqual(len(generations(self.root)), 2)


class NoCacheTests(ProtocolScenario):
    """`--no-cache` end to end, over a real command line.

    `RunnerConfig.no_cache` reaches the session only because
    `_resolution_defaults` in `src/main.mojo` carries it through resolution.
    That projection is a private def in the executable target, so no Mojo test
    can reach it; drop its one line and every other gate stays green while the
    flag silently stops working. These two scenarios are what goes red.
    """

    file_names: ClassVar[tuple[str, ...]] = ("alpha", "beta")

    def test_no_cache_leaves_no_store_directory(self) -> None:
        self.run_ok(["--no-cache", "--json", "off.ndjson", "tests"])

        # The gate sits before any staging, and staging is what creates the
        # store, so a run that asked for no cache leaves no store behind.
        self.assertFalse((self.root / STORE_REL).exists(), msg="store created")
        # The ownership marker is a different matter: it belongs to the
        # `.mtest-cache` DIRECTORY, which this run created anyway for its
        # last-run state. Every directory mtest creates carries the proof that
        # it is mtest's, or `--cache-clear` would refuse to delete a tree this
        # same run had just made.
        self.assertTrue((self.root / TAG_REL).is_file(), msg="marker missing")
        self.assertEqual(counters(self.root / "off.ndjson"), (2, 0))
        # And it says nothing about it: the user turned the cache off, so
        # reporting that back would be noise.
        self.assertEqual(warnings_of(self.stream("off.ndjson"), "cache-off"), [])

    def test_a_cache_directory_no_cache_left_behind_can_be_cleared(self) -> None:
        # `--no-cache` still writes `.mtest-cache/lastrun`, so it creates the
        # cache directory even though it creates no store. A directory mtest
        # just made must be one mtest can prove it owns, or `--cache-clear`
        # refuses it as somebody else's and exits 4: a usage error on an
        # ordinary sequence, blaming a mtest that was never here.
        self.run_ok(["--no-cache", "--json", "off.ndjson", "tests"])
        self.assertTrue((self.root / CACHE_ROOT_REL / "lastrun").is_file())
        self.assertFalse((self.root / STORE_REL).exists(), msg="store created")

        # State off for the clearing run only, so the session that follows the
        # deletion cannot write the directory straight back and make "deleted"
        # unobservable.
        (self.root / "mtest.toml").write_text(STATELESS_CONFIG, encoding="utf-8")
        completed = self.run_ok(["--cache-clear", "--no-cache", "tests"])

        self.assertEqual(completed.returncode, 0, msg=completed.stderr)
        self.assertFalse((self.root / CACHE_ROOT_REL).exists(), msg=completed.stderr)

    def test_no_cache_preserves_store_inodes(self) -> None:
        self.run_ok(["--json", "cold.ndjson", "tests"])
        self.run_ok(["--json", "warm.ndjson", "tests"])
        self.assertEqual(counters(self.root / "warm.ndjson"), (0, 2))
        before = store_identities(self.root)
        self.assertEqual(len(generations(self.root)), 2)

        self.run_ok(["--no-cache", "--json", "off.ndjson", "tests"])

        # Not one artifact was read, rewritten, republished, or reaped: same
        # inodes, same mtimes, same membership.
        self.assertEqual(store_identities(self.root), before)
        # And the counters agree with the filesystem: both files went to the
        # compiler even though a valid generation for each was sitting there.
        self.assertEqual(counters(self.root / "off.ndjson"), (2, 0))


class CollectOnlyTests(ProtocolScenario):
    """`--collect-only` reaches the store through the same seam a run does.

    Collect builds every discovered file and probes it for its test names,
    running no test body. It takes its own branch out of `src/main.mojo`, never
    reaching `run_session`, so it emits no event stream and no counters and the
    store itself is its only witness.

    A collect that neither probed nor published would still print the right
    listing and pass every other gate here, while making the listing cost a
    full cold compile of the suite every time an editor asked for it.
    """

    file_names: ClassVar[tuple[str, ...]] = ("alpha", "beta")

    def test_collect_only_publishes_and_then_serves(self) -> None:
        listing = self.run_ok(["--collect-only", "tests"])
        self.assertEqual(
            listing.stdout.splitlines(),
            [
                "tests/test_alpha.mojo::test_alpha",
                "tests/test_beta.mojo::test_beta",
            ],
        )
        # PUBLISHES: the store and its ownership marker exist only as a side
        # effect of staging a build into them, so a collect that built
        # invocation-private would leave neither.
        self.assertEqual(len(generations(self.root)), 2)
        self.assertTrue((self.root / TAG_REL).is_file(), msg="marker missing")
        before = store_identities(self.root)

        # PROBES: a second collect that missed would stage into the store and
        # publish again, moving at least one inode or mtime. Not one artifact
        # was rewritten, so both files came back off the disk.
        again = self.run_ok(["--collect-only", "tests"])
        self.assertEqual(again.stdout, listing.stdout)
        self.assertEqual(store_identities(self.root), before)

        # And what collect published is not a private dialect: an ordinary run
        # serves both files out of it without compiling anything.
        self.run_ok(["--json", "run.ndjson", "tests"])
        self.assertEqual(counters(self.root / "run.ndjson"), (0, 2))


class EarlyStopCounterTests(ProtocolScenario):
    """What the counters say when a batch stops before it reaches every file.

    `docs/json-stream.md` publishes `built_files + cached_files` as the run's
    first-attempt compile admissions and promises the sum is stable across runs
    over identical inputs. A file the scheduler never reaches is admitted to
    nothing, so it belongs in neither counter. The parallel pool is where that
    is easiest to get wrong, since it can learn a file's cache answer long
    before it decides whether to dispatch it.
    """

    file_names: ClassVar[tuple[str, ...]] = (
        "alpha",
        "beta",
        "gamma",
        "delta",
        "epsilon",
        "zeta",
        "eta",
        "theta",
    )

    def test_a_warm_pool_stopping_early_counts_only_what_it_dispatched(
        self,
    ) -> None:
        tripwire = self.root / "tests" / "test_alpha.mojo"
        tripwire.write_text(TRIPWIRE_SOURCE, encoding="utf-8")

        self.run_ok(["--json", "cold.ndjson", "-n", "2", "tests"])
        self.assertEqual(counters(self.root / "cold.ndjson"), (8, 0))

        # `test_alpha.mojo` sorts first, so `-x` latches on the first verdict
        # the batch produces and most of the suite is never dispatched.
        (self.root / "tripped").write_bytes(b"")

        completed = run_mtest(
            self.root, ["--json", "warm.ndjson", "-n", "2", "-x", "tests"]
        )
        self.assertEqual(completed.returncode, 1, msg=completed.stderr)

        records = self.stream("warm.ndjson")
        started = {
            str(record["path"])
            for record in records
            if record.get("event") == "file_started"
        }
        built, cached = counters(self.root / "warm.ndjson")
        self.assertLess(len(started), 8, msg=f"started={sorted(started)}")
        self.assertEqual(built, 0, msg="a warm store compiles nothing")
        # A file is announced exactly when it is dispatched, and it is admitted
        # exactly when it is dispatched, so the two counts are the same number
        # seen from two sides. A store answer taken earlier than the dispatch
        # shows up here as a cache count with no file behind it.
        self.assertEqual(cached, len(started), msg=f"started={sorted(started)}")


class CacheClearTests(ProtocolScenario):
    """`--cache-clear` end to end, over a real command line.

    The flag is `clear_cache_root` plus a short ordering in `src/main.mojo`:
    resolve first so a usage error never reaches a deletion, clear before the
    last-run state is read because that file lives inside the directory being
    deleted, and refuse as a configuration error with exit 4. Nothing under
    `tests/` can import `main.mojo`, so that ordering is covered here or by
    reading only.
    """

    file_names: ClassVar[tuple[str, ...]] = ("alpha", "beta")

    def _populate(self) -> None:
        """Fill the store, with last-run persistence off.

        `.mtest-cache/lastrun` is inside the directory `--cache-clear` deletes,
        so leaving state on would have the very same invocation write the
        directory back and make "absent" unobservable.
        """
        (self.root / "mtest.toml").write_text(STATELESS_CONFIG, encoding="utf-8")
        self.run_ok(["--json", "cold.ndjson", "tests"])
        self.assertEqual(len(generations(self.root)), 2)
        self.assertTrue((self.root / TAG_REL).is_file())

    def test_cache_clear_removes_the_owned_directory(self) -> None:
        self._populate()

        # Paired with `--no-cache` so the session that follows the deletion
        # cannot re-create what was just deleted. What is under test is the
        # deletion and its exit status, not what a later build writes.
        completed = self.run_ok(["--cache-clear", "--no-cache", "tests"])

        self.assertEqual(completed.returncode, 0)
        self.assertFalse((self.root / CACHE_ROOT_REL).exists(), msg=completed.stderr)

    def test_the_run_after_a_clear_rebuilds_everything(self) -> None:
        self._populate()
        self.run_ok(["--cache-clear", "--no-cache", "tests"])

        self.run_ok(["--json", "after.ndjson", "tests"])

        built, cached = counters(self.root / "after.ndjson")
        self.assertEqual(cached, 0)
        self.assertGreater(built, 0)
        self.assertEqual(len(generations(self.root)), 2)

    def test_a_bare_cache_clear_clears_and_then_runs_cold(self) -> None:
        # Every other clear scenario pairs the flag with something (`--no-cache`
        # to keep the deletion observable, `--lf` to reach the warning), so the
        # bare spelling a user reaches for is the one shape nothing drove. It is
        # also the shape whose halves look like each other's absence: the flag
        # clears the store and THEN runs the session, which fills it straight
        # back up, so a populated store afterwards is the expected end state of
        # both a working clear and one that did nothing at all.
        self._populate()
        before = store_identities(self.root)
        before_names = generations(self.root)

        self.run_ok(["--cache-clear", "--json", "after.ndjson", "tests"])

        # The deletion, witnessed by the run's own accounting: two valid
        # generations were sitting there and neither could be served.
        self.assertEqual(counters(self.root / "after.ndjson"), (2, 0))
        # The repopulation, witnessed by identity rather than by presence. Same
        # inputs mean the same keys, so the names come back identical, but every
        # generation is a directory created after the deletion, so none of them
        # can be the object that was there before.
        self.assertEqual(generations(self.root), before_names)
        after = store_identities(self.root)
        self.assertEqual(sorted(after), sorted(before), msg="store membership")
        for name in before_names:
            key = f"{STORE_REL}/{name}"
            self.assertNotEqual(after[key], before[key], msg=key)
        self.assertTrue((self.root / TAG_REL).is_file(), msg="marker missing")

    def test_an_unmarked_cache_directory_is_refused_intact(self) -> None:
        cache_root = self.root / CACHE_ROOT_REL
        cache_root.mkdir()
        stray = cache_root / "someone-elses.txt"
        stray.write_bytes(b"not mtest's\n")

        completed = run_mtest(self.root, ["--cache-clear", "tests"])

        # A pre-session configuration refusal, exit 4, with the diagnostic
        # naming both the missing proof of ownership and the manual way out.
        self.assertEqual(completed.returncode, 4, msg=completed.stderr)
        self.assertIn("CACHEDIR.TAG", completed.stderr)
        self.assertIn("rm -rf .mtest-cache", completed.stderr)
        # There is deliberately no "but its contents look like ours" escape
        # hatch, so the stray file is exactly as it was.
        self.assertEqual(stray.read_bytes(), b"not mtest's\n")

    def test_an_ordinary_run_does_not_adopt_a_directory_it_found(self) -> None:
        # The refusal above tells the reader to delete the directory
        # themselves. If an ordinary run wrote the marker into a directory it
        # merely found, that refusal would be one invocation deep: run mtest,
        # get the marker for free, and the next `--cache-clear` would delete
        # somebody else's tree with the proof mtest had just manufactured.
        cache_root = self.root / CACHE_ROOT_REL
        cache_root.mkdir()
        stray = cache_root / "keep-me.txt"
        stray.write_bytes(b"not mtest's\n")

        self.run_ok(["tests"])

        self.assertFalse(
            (self.root / TAG_REL).exists(),
            msg="an ordinary run marked a directory it did not create",
        )

        completed = run_mtest(self.root, ["--cache-clear", "tests"])

        self.assertEqual(completed.returncode, 4, msg=completed.stderr)
        self.assertIn("CACHEDIR.TAG", completed.stderr)
        self.assertEqual(stray.read_bytes(), b"not mtest's\n")

    def test_a_cachedir_tag_mtest_did_not_write_is_refused_intact(self) -> None:
        # The convention's real signature line, which is the point: `CACHEDIR.TAG`
        # is a published standard, and its documentation tells users and backup
        # tools to write exactly this into any directory they want skipped. A
        # guard satisfied by the signature would hand mtest `rm -rf` rights over
        # every directory that followed that advice.
        cache_root = self.root / CACHE_ROOT_REL
        cache_root.mkdir()
        (cache_root / "CACHEDIR.TAG").write_text(
            "Signature: 8a477f597d28d172789f06886806bc55\n", encoding="utf-8"
        )
        stray = cache_root / "someone-elses.txt"
        stray.write_bytes(b"not mtest's\n")

        completed = run_mtest(self.root, ["--cache-clear", "tests"])

        self.assertEqual(completed.returncode, 4, msg=completed.stderr)
        self.assertIn("CACHEDIR.TAG", completed.stderr)
        self.assertEqual(stray.read_bytes(), b"not mtest's\n")
        self.assertTrue((cache_root / "CACHEDIR.TAG").is_file())

    def test_a_symlinked_cache_directory_is_refused_unfollowed(self) -> None:
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        victim = elsewhere / "keep.txt"
        victim.write_bytes(b"outside the tree mtest owns\n")
        link = self.root / CACHE_ROOT_REL
        link.symlink_to(elsewhere, target_is_directory=True)

        completed = run_mtest(self.root, ["--cache-clear", "tests"])

        self.assertEqual(completed.returncode, 4, msg=completed.stderr)
        self.assertIn("refusing to delete a symlink", completed.stderr)
        # Neither removed nor followed: the link is still a link, and what it
        # points at is untouched.
        self.assertTrue(link.is_symlink())
        self.assertEqual(victim.read_bytes(), b"outside the tree mtest owns\n")

    def test_clearing_under_lf_warns_and_still_selects_everything(self) -> None:
        self.run_ok(["--json", "cold.ndjson", "tests"])
        self.assertTrue((self.root / CACHE_ROOT_REL / "lastrun").is_file())

        self.run_ok(["--cache-clear", "--lf", "--json", "lf.ndjson", "tests"])

        records = self.stream("lf.ndjson")
        cleared = warnings_of(records, "cache-clear")
        self.assertEqual(len(cleared), 1, msg=f"warnings={cleared!r}")
        self.assertIn("last-run state was just cleared", cleared[0])
        # The reselection flag survived the same command line that deleted what
        # it would have selected from, so the run falls back to everything.
        started = event(records, "session_started")
        self.assertEqual(counter(started, "selected_count"), 2)
        finished = [
            record for record in records if record.get("event") == "file_finished"
        ]
        self.assertEqual(len(finished), 2)

    def test_config_show_short_circuits_before_any_deletion(self) -> None:
        self.run_ok(["--json", "cold.ndjson", "tests"])
        before = generations(self.root)
        self.assertEqual(len(before), 2)

        completed = self.run_ok(["config", "show", "--cache-clear", "tests"])

        # `config show` resolves and prints; §27.1 fixes its exit domain and
        # states it performs no side effect. `--cache-clear` is a side effect,
        # so the ordering in main.mojo puts the config-show branch first.
        self.assertEqual(completed.returncode, 0)
        self.assertIn("[run]", completed.stdout)
        self.assertTrue((self.root / CACHE_ROOT_REL).is_dir())
        self.assertEqual(generations(self.root), before)


if __name__ == "__main__":
    unittest.main()
