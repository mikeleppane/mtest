#!/usr/bin/env python3
"""Build and verify the production-shaped Mojo ``tomllib`` interop probe.

This maintainer tool exercises a built probe in either the repository's pixi
environment or a fresh package-consumption scratch prefix.  It fails closed on
interop, eager libpython mapping, or no-config interpreter initialization, then
reports first-launch and subsequent-launch startup measurements without imposing
a timing threshold.

Usage:
    pixi run python -m scripts.maintenance.tomllib_spike --environment pixi
    pixi run python -m scripts.maintenance.tomllib_spike --environment package
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import shlex
import statistics
import subprocess
import sys
import tempfile
import time

from scripts.build import package_consumption


REPO_ROOT = Path(__file__).resolve().parents[2]
PROBE_SOURCE = REPO_ROOT / "scripts" / "maintenance" / "tomllib_spike_probe.mojo"
BRIDGE_SOURCE = REPO_ROOT / "scripts" / "maintenance" / "tomllib_spike_bridge.mojo"
PACKAGE_PROBE_BUILD = package_consumption.SCRATCH_ROOT / "tomllib-spike-build" / "probe"
PACKAGE_PROBE_INSTALL_NAME = "mtest-tomllib-spike"

BUILD_TIMEOUT = 300.0
PROBE_TIMEOUT = 30.0
DEFAULT_WARM_RUNS = 5
EXPECTED_CONFIG_STDOUT = "tomllib_timeout=37\n"


class SpikeError(RuntimeError):
    """A required interop property failed and the spike must stop."""


@dataclass(frozen=True)
class ProbeEnvironment:
    """One built probe plus the exact environment used to execute it."""

    label: str
    binary: Path
    env: dict[str, str]


@dataclass(frozen=True)
class StartupMeasurements:
    """First config launch and subsequent config-launch median in seconds."""

    cold_seconds: float
    warm_median_seconds: float
    warm_runs: int


def _display_command(argv: list[str], env_overrides: dict[str, str] | None) -> None:
    """Print one shell-readable command without executing through a shell."""
    prefix = ""
    if env_overrides:
        prefix = " ".join(
            f"{key}={shlex.quote(value)}"
            for key, value in sorted(env_overrides.items())
        )
        prefix += " "
    print(f"$ {prefix}{shlex.join(argv)}", flush=True)


def _run(
    argv: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    env_overrides: dict[str, str] | None = None,
    timeout: float,
) -> subprocess.CompletedProcess[str]:
    """Run one command directly, capture both streams, and show its evidence."""
    _display_command(argv, env_overrides)
    result, _ = _execute(
        argv,
        cwd=cwd,
        env=env,
        env_overrides=env_overrides,
        timeout=timeout,
    )
    _show_result(result)
    return result


def _execute(
    argv: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    env_overrides: dict[str, str] | None = None,
    timeout: float,
) -> tuple[subprocess.CompletedProcess[str], float]:
    """Execute one command and time only the direct subprocess call."""
    child_env = dict(env)
    if env_overrides:
        child_env.update(env_overrides)
    try:
        started = time.perf_counter()
        result = subprocess.run(
            argv,
            cwd=cwd,
            env=child_env,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        elapsed = time.perf_counter() - started
    except FileNotFoundError as exc:
        raise SpikeError(f"could not execute {argv[0]!r}: {exc}") from exc
    except subprocess.TimeoutExpired as exc:
        raise SpikeError(
            f"{shlex.join(argv)} exceeded the {timeout:.0f}s deadline"
        ) from exc

    return result, elapsed


def _show_result(result: subprocess.CompletedProcess[str]) -> None:
    """Print captured command evidence outside any measured interval."""
    if result.stdout:
        print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr, flush=True)
    print(f"exit={result.returncode}", flush=True)


def _require_sources() -> None:
    """Fail explicitly when either committed Mojo source is absent."""
    missing = [path for path in (BRIDGE_SOURCE, PROBE_SOURCE) if not path.is_file()]
    if missing:
        rendered = ", ".join(str(path.relative_to(REPO_ROOT)) for path in missing)
        raise SpikeError(f"missing probe source: {rendered}")


def _build(
    argv_prefix: list[str],
    output: Path,
    *,
    env: dict[str, str],
) -> None:
    """Build the probe binary directly; never route through ``mojo run``."""
    output.parent.mkdir(parents=True, exist_ok=True)
    result = _run(
        [
            *argv_prefix,
            "mojo",
            "build",
            str(PROBE_SOURCE),
            "-o",
            str(output),
        ],
        cwd=REPO_ROOT,
        env=env,
        timeout=BUILD_TIMEOUT,
    )
    if result.returncode != 0:
        raise SpikeError(f"probe build exited {result.returncode}")
    if not output.is_file():
        raise SpikeError(f"probe build exited 0 but did not create {output}")


def _pixi_probe(temp_root: Path) -> ProbeEnvironment:
    """Build a temporary probe with the active repository pixi toolchain."""
    binary = temp_root / "pixi" / "mtest-tomllib-spike"
    env = dict(os.environ)
    _build([], binary, env=env)
    return ProbeEnvironment("pixi", binary, env)


def _package_probe() -> ProbeEnvironment:
    """Build and install a probe in package-check's fresh scratch prefix."""
    if not sys.platform.startswith("linux"):
        raise SpikeError(
            "the package-consumption scratch contract is gated only on linux-64"
        )

    try:
        artifact = package_consumption.stage_build_local_channel()
        mtest_binary = package_consumption.stage_install_from_local_channel(artifact)
    except package_consumption.PackageCheckError as exc:
        raise SpikeError(f"package setup failed: {exc}") from exc
    prefix = mtest_binary.parent.parent
    manifest = package_consumption.CONDA_ENV_DIR / "pixi.toml"

    _build(
        ["pixi", "run", "--manifest-path", str(manifest)],
        PACKAGE_PROBE_BUILD,
        env=dict(os.environ),
    )

    installed = prefix / "bin" / PACKAGE_PROBE_INSTALL_NAME
    installed.parent.mkdir(parents=True, exist_ok=True)
    install_result = _run(
        [
            "install",
            "-m",
            "755",
            str(PACKAGE_PROBE_BUILD),
            str(installed),
        ],
        cwd=REPO_ROOT,
        env=dict(os.environ),
        timeout=PROBE_TIMEOUT,
    )
    if install_result.returncode != 0:
        raise SpikeError(f"probe installation exited {install_result.returncode}")
    if not installed.is_file():
        raise SpikeError(f"probe installation exited 0 but did not create {installed}")

    # Match package-check's loader-clean contract: the repository pixi prefix is
    # absent from PATH and LD_LIBRARY_PATH contributes no accidental soname.
    scrubbed_env = {
        "PATH": "/usr/bin:/bin",
        "HOME": os.environ.get("HOME", "/tmp"),
        "LD_LIBRARY_PATH": "",
    }
    return ProbeEnvironment("package", installed, scrubbed_env)


def _expected_maps_stdout() -> str:
    """Return the target-specific no-config mapping report."""
    if sys.platform.startswith("linux"):
        return "libpython_mapped=false\n"
    # mypy narrows `sys.platform` to the checking host (linux here) and calls
    # this dead. It is the live branch on Darwin, so it stays.
    return "libpython_mapped=unsupported\n"  # type: ignore[unreachable]


def _require_success(
    result: subprocess.CompletedProcess[str],
    *,
    expected_stdout: str,
    operation: str,
) -> None:
    """Require exact exit and stream bytes for a probe operation."""
    if result.returncode != 0:
        raise SpikeError(f"{operation} exited {result.returncode}")
    if result.stdout != expected_stdout:
        raise SpikeError(
            f"{operation} stdout mismatch: expected {expected_stdout!r}, "
            f"got {result.stdout!r}"
        )
    if result.stderr:
        raise SpikeError(f"{operation} wrote unexpected stderr: {result.stderr!r}")


def _timed_config_run(probe: ProbeEnvironment) -> float:
    """Run one config-present probe launch and return elapsed wall seconds."""
    argv = [str(probe.binary), "--config"]
    _display_command(argv, None)
    result, elapsed = _execute(
        argv,
        cwd=REPO_ROOT,
        env=probe.env,
        timeout=PROBE_TIMEOUT,
    )
    _show_result(result)
    _require_success(
        result,
        expected_stdout=EXPECTED_CONFIG_STDOUT,
        operation=f"{probe.label} config-present probe",
    )
    return elapsed


def verify_probe(probe: ProbeEnvironment, *, warm_runs: int) -> StartupMeasurements:
    """Verify laziness and interop, then measure cold and warm startup."""
    expected_maps = _expected_maps_stdout()

    no_config = _run(
        [str(probe.binary), "--no-config"],
        cwd=REPO_ROOT,
        env=probe.env,
        timeout=PROBE_TIMEOUT,
    )
    _require_success(
        no_config,
        expected_stdout=expected_maps,
        operation=f"{probe.label} live no-config maps probe",
    )

    sabotaged = _run(
        [str(probe.binary), "--no-config"],
        cwd=REPO_ROOT,
        env=probe.env,
        env_overrides={"PYTHONHOME": "/nonexistent"},
        timeout=PROBE_TIMEOUT,
    )
    _require_success(
        sabotaged,
        expected_stdout=expected_maps,
        operation=f"{probe.label} PYTHONHOME no-config probe",
    )

    # The first config-present process after build is the cold observation.
    cold = _timed_config_run(probe)
    warm_samples = [_timed_config_run(probe) for _ in range(warm_runs)]
    measurements = StartupMeasurements(
        cold_seconds=cold,
        warm_median_seconds=statistics.median(warm_samples),
        warm_runs=warm_runs,
    )
    print(
        "tomllib-spike: "
        f"environment={probe.label} "
        f"cold_first_config_seconds={measurements.cold_seconds:.6f} "
        f"warm_config_median_seconds={measurements.warm_median_seconds:.6f} "
        f"warm_runs={measurements.warm_runs}",
        flush=True,
    )
    return measurements


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse the target environment and warm-launch sample count."""
    parser = argparse.ArgumentParser(
        prog="tomllib-spike",
        description="Build and verify the Mojo stdlib-tomllib interop probe.",
    )
    parser.add_argument(
        "--environment",
        choices=("pixi", "package"),
        required=True,
        help="build/run in the dev pixi env or package-check scratch env",
    )
    parser.add_argument(
        "--warm-runs",
        type=int,
        default=DEFAULT_WARM_RUNS,
        help=(
            "subsequent launches used for the warm median "
            f"(default {DEFAULT_WARM_RUNS})"
        ),
    )
    args = parser.parse_args(argv)
    if args.warm_runs < 1:
        parser.error("--warm-runs must be at least 1")
    return args


def main(argv: list[str] | None = None) -> int:
    """Build the requested probe, verify every property, and report timings."""
    args = parse_args(argv)
    try:
        _require_sources()
        if args.environment == "package":
            probe = _package_probe()
            verify_probe(probe, warm_runs=args.warm_runs)
        else:
            with tempfile.TemporaryDirectory(prefix="mtest-tomllib-spike-") as root:
                probe = _pixi_probe(Path(root))
                verify_probe(probe, warm_runs=args.warm_runs)
    except SpikeError as exc:
        print(f"FATAL: tomllib-spike: {exc}", file=sys.stderr)
        return 1

    print(f"tomllib-spike: PASS environment={args.environment}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
