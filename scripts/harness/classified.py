#!/usr/bin/env python3
"""Generate, build, and directly run the classified Mojo test inventory."""

from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import dataclass
import math
import os
from pathlib import Path
import signal
import sys

from scripts.harness import aggregate
from scripts.harness import watchdog


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ROOTS = (Path("tests/unit"), Path("tests/integration"))
AGGREGATE_SOURCE = Path("build/tests/aggregate_main.mojo")
AGGREGATE_BINARY = Path("build/tests/aggregate")
NATIVE_TEST_OBJECT = Path("build/native/mtest_exec_native_test.o")
TIMEOUT_ENV = "MTEST_TEST_ALL_TIMEOUT_SECONDS"
INTERNAL_ERROR_EXIT_CODE = 70

Supervisor = Callable[..., watchdog.Termination]


@dataclass(frozen=True)
class StepResult:
    """One classified pipeline step and its structured termination."""

    source: str
    step: str
    termination: watchdog.Termination


def _normalized_roots(repo_root: Path, paths: Sequence[str]) -> list[Path]:
    """Return narrow repository-relative classified roots or raise ``ValueError``."""
    raw_roots = list(paths) if paths else [str(path) for path in DEFAULT_ROOTS]
    normalized: list[Path] = []
    for original in raw_roots:
        root = original
        while root.startswith("./"):
            root = root[2:]
        root = root.rstrip("/")
        candidate = Path(root)
        if (
            not root
            or candidate.is_absolute()
            or ".." in candidate.parts
        ):
            raise ValueError(f"unsafe suite root: {root or '<empty>'}")
        if candidate != Path("tests") and candidate.parts[:1] != ("tests",):
            raise ValueError(f"suite root must be tests/ or below: {root}")
        absolute = repo_root / candidate
        if not absolute.exists() or absolute.is_symlink():
            raise ValueError(
                f"suite root is not a real file or directory: {root}"
            )
        normalized.append(candidate)
    return normalized


def _timeout_seconds(environment: dict[str, str]) -> float:
    """Read the retained classified build/run deadline override."""
    raw = environment.get(TIMEOUT_ENV)
    if raw is None:
        return watchdog.DEFAULT_TIMEOUT_SECONDS
    try:
        timeout_seconds = float(raw)
    except ValueError as exc:
        raise ValueError(f"{TIMEOUT_ENV} must be a number: {raw!r}") from exc
    if not math.isfinite(timeout_seconds) or not (
        0 < timeout_seconds <= watchdog.DEFAULT_TIMEOUT_SECONDS
    ):
        raise ValueError(
            f"{TIMEOUT_ENV} must be finite and between 0 and "
            f"{watchdog.DEFAULT_TIMEOUT_SECONDS:g} seconds: {raw!r}"
        )
    return timeout_seconds


def _sentinel_for(source: str, step: str) -> Path:
    """Return the independent deadline sentinel for one pipeline step."""
    stem = {
        "aggregate suite": "aggregate",
        "native adapter": "native",
        "package": "package",
    }.get(source, source.replace(" ", "-"))
    return Path("build/tests") / f"{stem}.{step}-deadline"


def _run_step(
    command: Sequence[str],
    *,
    repo_root: Path,
    source: str,
    step: str,
    timeout_seconds: float,
    supervisor: Supervisor,
) -> StepResult:
    """Supervise one step and independently reconcile its deadline sentinel."""
    sentinel = repo_root / _sentinel_for(source, step)
    try:
        sentinel.parent.mkdir(parents=True, exist_ok=True)
        sentinel.unlink(missing_ok=True)
        sentinel.touch()
    except OSError as exc:
        return StepResult(
            source,
            step,
            watchdog.HarnessError(f"could not create deadline sentinel: {exc}"),
        )
    try:
        termination = supervisor(
            command,
            source=source,
            step=step,
            timeout_seconds=timeout_seconds,
            deadline_sentinel=sentinel,
            cwd=repo_root,
        )
    except Exception as exc:
        try:
            sentinel.unlink(missing_ok=True)
        except OSError as cleanup_exc:
            return StepResult(
                source,
                step,
                watchdog.HarnessError(
                    f"supervisor raised {exc}; sentinel cleanup failed: {cleanup_exc}"
                ),
            )
        return StepResult(
            source,
            step,
            watchdog.HarnessError(f"supervisor raised: {exc}"),
        )
    termination = watchdog.validate_deadline_proof(termination, sentinel)
    return StepResult(source, step, termination)


def _build_commands() -> tuple[tuple[str, list[str]], ...]:
    """Return the exact one-package, one-native, one-aggregate build pipeline."""
    aggregate_source = str(AGGREGATE_SOURCE)
    aggregate_binary = str(AGGREGATE_BINARY)
    return (
        ("package", ["bash", "scripts/build/mojo_package.sh"]),
        ("native adapter", [sys.executable, "-m", "scripts.build.native"]),
        (
            "aggregate suite",
            [
                "mojo",
                "build",
                "--no-optimization",
                "-I",
                ".",
                "-I",
                "build",
                "-I",
                "tests/support",
                "-Xlinker",
                str(NATIVE_TEST_OBJECT),
                aggregate_source,
                "-o",
                aggregate_binary,
            ],
        ),
    )


def run_pipeline(
    roots: list[Path],
    *,
    repo_root: Path = REPO_ROOT,
    environment: dict[str, str] | None = None,
    supervisor: Supervisor = watchdog.run_command,
) -> StepResult:
    """Generate and run one aggregate through the complete classified pipeline."""
    aggregate_source = repo_root / AGGREGATE_SOURCE
    modules = aggregate.write_entrypoint(repo_root, aggregate_source, roots)
    print(
        f"aggregate-tests: generated {AGGREGATE_SOURCE} for {len(modules)} "
        f"module(s), {sum(len(module.test_functions) for module in modules)} test(s)",
        flush=True,
    )

    timeout_seconds = _timeout_seconds(
        dict(os.environ) if environment is None else environment
    )
    for source, command in _build_commands():
        if source == "aggregate suite":
            print(
                f"==> building aggregate test binary -> {AGGREGATE_BINARY}",
                flush=True,
            )
        step_timeout = (
            timeout_seconds
            if source == "aggregate suite"
            else watchdog.DEFAULT_TIMEOUT_SECONDS
        )
        result = _run_step(
            command,
            repo_root=repo_root,
            source=source,
            step="build",
            timeout_seconds=step_timeout,
            supervisor=supervisor,
        )
        if result.termination != watchdog.Exited(0):
            return result

    print("==> running aggregate test binary", flush=True)
    return _run_step(
        [str(repo_root / AGGREGATE_BINARY)],
        repo_root=repo_root,
        source="aggregate suite",
        step="run",
        timeout_seconds=timeout_seconds,
        supervisor=supervisor,
    )


def _raise_signal(signo: int) -> int:
    """Restore and re-raise one signal from the classified harness process."""
    if signo not in (signal.SIGKILL, signal.SIGSTOP):
        signal.signal(signo, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signo})
    os.kill(os.getpid(), signo)
    return 128 + signo


def _exit_for_result(result: StepResult) -> int:
    """Map one structured pipeline result to the classified command contract."""
    termination = result.termination
    label = f"{result.source} ({result.step}"
    if isinstance(termination, watchdog.Exited):
        if termination.code == 0:
            print("All aggregate test modules passed.")
            return 0
        print(
            f"FAILED: {label} exit {termination.code})",
            file=sys.stderr,
        )
        return 1
    if isinstance(termination, watchdog.TimedOut):
        timed_out_source = (
            "aggregate" if result.source == "aggregate suite" else result.source
        )
        print(
            f"FATAL: classified: stopping after timed-out {timed_out_source} "
            f"{result.step}",
            file=sys.stderr,
        )
        return watchdog.TIMEOUT_EXIT_CODE
    if isinstance(termination, watchdog.HarnessError):
        print(
            f"FATAL: classified: watchdog/internal failure during "
            f"{result.source} {result.step}: {termination.detail}",
            file=sys.stderr,
        )
        return INTERNAL_ERROR_EXIT_CODE
    if isinstance(termination, watchdog.Signaled):
        print(
            f"CRASHED: {label} signal {termination.signo})",
            file=sys.stderr,
            flush=True,
        )
        return _raise_signal(termination.signo)
    return _raise_signal(termination.signo)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the requested classified roots and preserve truthful termination."""
    paths = list(sys.argv[1:] if argv is None else argv)
    try:
        roots = _normalized_roots(REPO_ROOT, paths)
        result = run_pipeline(roots)
    except (OSError, ValueError) as exc:
        print(f"FATAL: classified: {exc}", file=sys.stderr)
        return 2
    return _exit_for_result(result)


if __name__ == "__main__":
    raise SystemExit(main())
