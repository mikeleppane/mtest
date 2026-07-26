"""Read-only environment-diagnosis E2E scenarios."""

from __future__ import annotations

import os
from pathlib import Path
import signal
import sys
import tempfile

from scripts.e2e.assertions import expect, expect_exit
from scripts.e2e.runner import E2ERunner, Run, ScenarioContext


CHECK_NAMES = [
    "version",
    "platform",
    "root",
    "exec",
    "toolchain",
    "config",
    "config-semantics",
    "state",
    "temp",
    "report-destinations",
]


def _runner(context: ScenarioContext, root: Path) -> E2ERunner:
    """Build a guarded runner rooted at one transient project."""
    return E2ERunner(
        repo_root=root,
        mtest=context.runner.mtest,
        default_timeout=context.runner.default_timeout,
        short_timeout=context.runner.short_timeout,
    )


def _expect_checks(run: Run) -> list[str]:
    """Assert one physical line for every fixed doctor check, in order."""
    expect(run.stderr == "", f"doctor wrote stderr:\n{run.stderr}")
    lines = run.stdout.splitlines()
    expect(
        len(lines) == len(CHECK_NAMES),
        f"doctor rendered {len(lines)} lines, expected 10:\n{run.stdout}",
    )
    for line, name in zip(lines, CHECK_NAMES, strict=True):
        prefixes = (
            "PASS " + name + ": ",
            "WARN " + name + ": ",
            "FAIL " + name + ": ",
        )
        expect(
            line.startswith(prefixes),
            f"doctor check order/status malformed at {name!r}: {line!r}",
        )
    return lines


def _write_identity_probe(path: Path, identity: str) -> None:
    """Write one executable that prints a chosen version identity."""
    path.write_text(
        f"#!{sys.executable}\n"
        "import sys\n"
        f"sys.stdout.write({identity!r} + '\\n')\n",
        encoding="utf-8",
    )
    path.chmod(0o700)


def s_healthy(context: ScenarioContext) -> str:
    """A config-free healthy environment passes every fixed check."""
    with tempfile.TemporaryDirectory(prefix="mtest-doctor-healthy-") as raw:
        root = Path(raw)
        run = _runner(context, root).run_mtest(
            ["doctor", "--no-config", "--color", "never"]
        )
        expect_exit(run, 0)
        lines = _expect_checks(run)
        expect(
            lines[1].startswith(("PASS platform: ", "WARN platform: "))
            and all(
                line.startswith("PASS ")
                for index, line in enumerate(lines)
                if index != 1
            ),
            f"healthy doctor emitted an unexpected status:\n{run.stdout}",
        )
        expect(
            not (root / ".mtest-cache").exists(),
            "healthy doctor left its state probe directory behind",
        )
    return "10 ordered healthy lines; no state probe artifact"


def s_malformed_config(context: ScenarioContext) -> str:
    """Malformed config fails its check while later checks still run."""
    with tempfile.TemporaryDirectory(prefix="mtest-doctor-malformed-") as raw:
        root = Path(raw)
        (root / "mtest.toml").write_text(
            '[run]\nworkers = "not-a-worker-count"\n',
            encoding="utf-8",
        )
        run = _runner(context, root).run_mtest(
            ["doctor", "--color", "never"]
        )
        expect_exit(run, 1)
        lines = _expect_checks(run)
        expect(
            lines[4] == "FAIL toolchain: dependency config unavailable",
            run.stdout,
        )
        expect(lines[5].startswith("FAIL config: "), run.stdout)
        expect(lines[7].startswith("PASS state: "), run.stdout)
        expect(lines[8].startswith("PASS temp: "), run.stdout)
    return "malformed config failed; state and temp checks continued"


def s_missing_explicit_config(context: ScenarioContext) -> str:
    """A missing explicit config is a check failure, never usage exit four."""
    with tempfile.TemporaryDirectory(prefix="mtest-doctor-missing-config-") as raw:
        root = Path(raw)
        run = _runner(context, root).run_mtest(
            [
                "doctor",
                "--config",
                "absent.toml",
                "--color",
                "never",
            ]
        )
        expect_exit(run, 1)
        lines = _expect_checks(run)
        expect(
            lines[4] == "FAIL toolchain: dependency config unavailable",
            run.stdout,
        )
        expect(
            lines[5]
            == "FAIL config: absent.toml: configuration file does not exist",
            run.stdout,
        )
        expect(lines[8].startswith("PASS temp: "), run.stdout)
    return "missing --config exited 1 and continued, not usage exit 4"


def s_missing_toolchain(context: ScenarioContext) -> str:
    """An unresolvable configured mojo executable fails only toolchain."""
    with tempfile.TemporaryDirectory(prefix="mtest-doctor-missing-mojo-") as raw:
        root = Path(raw)
        missing = root / "does-not-exist-mojo"
        run = _runner(context, root).run_mtest(
            ["doctor", "--no-config", "--color", "never"],
            env_overrides={"MTEST_MOJO": os.fspath(missing)},
        )
        expect_exit(run, 1)
        lines = _expect_checks(run)
        expect(lines[4].startswith("FAIL toolchain: "), run.stdout)
        expect(lines[5] == "PASS config: none", run.stdout)
        expect(lines[9] == "PASS report-destinations: none", run.stdout)

        fake = root / "fake-version"
        _write_identity_probe(fake, "compatible compiler")
        fake_run = _runner(context, root).run_mtest(
            ["doctor", "--no-config", "--color", "never"],
            env_overrides={"MTEST_MOJO": os.fspath(fake)},
        )
        expect_exit(fake_run, 1)
        fake_lines = _expect_checks(fake_run)
        expect(
            fake_lines[4].startswith(
                "FAIL toolchain: "
            )
            and "expected Mojo 1.0.0b2" in fake_lines[4],
            fake_run.stdout,
        )

        wrong = root / "wrong-version"
        _write_identity_probe(wrong, "Mojo 1.0.0b1 (deadbeef)")
        wrong_run = _runner(context, root).run_mtest(
            ["doctor", "--no-config", "--color", "never"],
            env_overrides={"MTEST_MOJO": os.fspath(wrong)},
        )
        expect_exit(wrong_run, 1)
        wrong_lines = _expect_checks(wrong_run)
        expect(
            wrong_lines[4].startswith(
                "FAIL toolchain: "
            )
            and "expected Mojo 1.0.0b2" in wrong_lines[4],
            wrong_run.stdout,
        )

        wrong_revision = root / "wrong-revision"
        _write_identity_probe(
            wrong_revision, "Mojo 1.0.0b2 (deadbeef)"
        )
        wrong_revision_run = _runner(context, root).run_mtest(
            ["doctor", "--no-config", "--color", "never"],
            env_overrides={"MTEST_MOJO": os.fspath(wrong_revision)},
        )
        expect_exit(wrong_revision_run, 1)
        wrong_revision_lines = _expect_checks(wrong_revision_run)
        expect(
            wrong_revision_lines[4].startswith(
                "FAIL toolchain: "
            )
            and "expected Mojo 1.0.0b2 (2cf4d08a)"
            in wrong_revision_lines[4],
            wrong_revision_run.stdout,
        )
    return (
        "missing, fake, wrong-version, and wrong-revision toolchains"
        " failed honestly"
    )


def s_unwritable_state(context: ScenarioContext) -> str:
    """An unwritable cache directory fails state without mutating its state."""
    with tempfile.TemporaryDirectory(prefix="mtest-doctor-state-") as raw:
        root = Path(raw)
        cache = root / ".mtest-cache"
        cache.mkdir()
        sentinel = cache / "lastrun"
        sentinel_bytes = b"mtest-lastrun v1\nfile\ttests/do-not-touch.mojo\n"
        sentinel.write_bytes(sentinel_bytes)
        cache.chmod(0o500)
        try:
            run = _runner(context, root).run_mtest(
                ["doctor", "--no-config", "--color", "never"]
            )
        finally:
            cache.chmod(0o700)
        expect_exit(run, 1)
        lines = _expect_checks(run)
        expect(
            lines[7].startswith("FAIL state: "),
            run.stdout,
        )
        expect(lines[8].startswith("PASS temp: "), run.stdout)
        expect(
            sentinel.read_bytes() == sentinel_bytes,
            "doctor modified the unusable state sentinel",
        )
    return "unwritable state failed and its sentinel stayed byte-identical"


def s_interrupt_toolchain(context: ScenarioContext) -> str:
    """An interrupt during the bounded version probe cleans up and exits two."""
    with tempfile.TemporaryDirectory(prefix="mtest-doctor-interrupt-") as raw:
        root = Path(raw)
        slow = root / "slow-version"
        slow.write_text(
            f"#!{sys.executable}\n"
            "import time\n"
            "time.sleep(300)\n",
            encoding="utf-8",
        )
        slow.chmod(0o700)
        runner = _runner(context, root)
        run, _pgid = runner.run_mtest_signaled(
            ["doctor", "--no-config", "--color", "never"],
            signal_number=signal.SIGINT,
            delay=2.0,
            timeout=10.0,
            env_overrides={"MTEST_MOJO": os.fspath(slow)},
        )
        expect_exit(run, 2)
        lines = _expect_checks(run)
        expect(lines[4].startswith("FAIL toolchain: "), run.stdout)
        expect(
            not list(root.glob(".mtest-doctor*")),
            "interrupted doctor left a root probe artifact",
        )
    return "SIGINT during version probe cleaned up and exited 2"


def s_config_free_without_python(context: ScenarioContext) -> str:
    """Absent config discovery avoids the native parser under bad PYTHONHOME."""
    with tempfile.TemporaryDirectory(prefix="mtest-doctor-config-free-") as raw:
        root = Path(raw)
        state = root / ".mtest-cache"
        state.mkdir()
        (state / "lastrun").write_text(
            "mtest-lastrun v1\nfile\ttests/test_old_failure.mojo\n",
            encoding="utf-8",
        )
        expect(not (root / "mtest.toml").exists(), "fixture has a config file")
        run = _runner(context, root).run_mtest(
            ["doctor", "--color", "never"],
            env_overrides={"MTEST_MOJO": "", "PYTHONHOME": "/nonexistent"},
        )
        expect_exit(run, 0)
        lines = _expect_checks(run)
        expect(lines[5] == "PASS config: none", run.stdout)
        expect(lines[7].startswith("PASS state: "), run.stdout)
        expect(
            not (root / "mtest.toml").exists(),
            "config-free doctor created a config file",
        )
    return "absent discovery stayed parser-lazy with valid v1 state"
