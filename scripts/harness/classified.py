#!/usr/bin/env python3
"""Generate, build, and directly run the classified Mojo test inventory."""

from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import dataclass
import math
import os
from pathlib import Path
import secrets
import shutil
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
DEBUG_SYMBOLS_ENV = "MTEST_TEST_DEBUG_SYMBOLS"
SYMBOLIZER_ENV = "LLVM_SYMBOLIZER_PATH"
SYMBOLIZER_NAME = "llvm-symbolizer"
INTERNAL_ERROR_EXIT_CODE = 70
MODULE_MARKER_PREFIX = aggregate.MODULE_MARKER_PREFIX
MARKER_NONCE_BYTES = 8

Supervisor = Callable[..., watchdog.Termination]


@dataclass(frozen=True)
class StepResult:
    """One classified pipeline step and its structured termination."""

    source: str
    step: str
    termination: watchdog.Termination
    last_module: str | None = None
    """The classified module the step had started when it ended, if known."""


def _marker_prefix() -> str:
    """Mint the per-run introducer the aggregate prints its markers behind.

    The aggregate's stdout is shared with every test body in the run, so any
    line shaped like a marker is otherwise as authoritative as the generated
    one: a crashing test that printed ``==> tests/unit/test_innocent.mojo``
    immediately before aborting had the crash attributed to a module that was
    never running. The marker is only trustworthy if the child cannot write
    it, so the introducer carries a nonce minted after the test sources were
    read and never written anywhere a test can reach.

    Returns:
        An unguessable introducer of the form ``"==> <nonce> "``.
    """
    return f"{MODULE_MARKER_PREFIX}{secrets.token_hex(MARKER_NONCE_BYTES)} "


def _last_module(output: str, marker_prefix: str) -> str | None:
    """Return the path in the last complete aggregate module marker.

    Args:
        output: Retained aggregate stdout text. A trailing fragment with no
            newline is an incomplete marker and never contributes.
        marker_prefix: The per-run introducer from `_marker_prefix`. Only a
            line carrying this exact prefix is a marker; the retention that
            produced `output` filters on it too, so a forged line is dropped
            before it reaches here as well as rejected here.

    Returns:
        The module path from the last complete marker line, or None when the
        text carries no complete module marker.
    """
    last: str | None = None
    for line in output.split("\n")[:-1]:
        if not line.startswith(marker_prefix):
            continue
        candidate = line[len(marker_prefix) :].rstrip()
        if candidate.startswith("tests/") and candidate.endswith(".mojo"):
            last = candidate
    return last


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


def _debug_symbols_requested(environment: dict[str, str]) -> bool:
    """Read the opt-in line-table request for the aggregate test binary.

    Args:
        environment: The harness process environment to read.

    Returns:
        Whether the aggregate is built with line tables. Absent or ``"0"`` keeps
        the default symbol-free build; only ``"1"`` enables them.

    Raises:
        ValueError: If the variable is set to anything but ``"0"`` or ``"1"``,
            so a typo cannot silently drop the request.
    """
    raw = environment.get(DEBUG_SYMBOLS_ENV)
    if raw is None or raw == "":
        return False
    if raw not in ("0", "1"):
        raise ValueError(f"{DEBUG_SYMBOLS_ENV} must be '0' or '1': {raw!r}")
    return raw == "1"


def _symbolizer_path() -> Path | None:
    """Return the pinned toolchain's symbolizer, or None when it is absent.

    Returns:
        The ``llvm-symbolizer`` shipped beside the resolved ``mojo`` binary. The
        Mojo runtime prints a crash backtrace as bare addresses unless it can
        find this tool, and it is not on `PATH` in either hosted lane.
    """
    mojo = shutil.which("mojo")
    if mojo is None:
        return None
    candidate = Path(mojo).resolve().parent / SYMBOLIZER_NAME
    return candidate if candidate.is_file() else None


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
    marker_prefix: str | None = None,
) -> StepResult:
    """Supervise one step and independently reconcile its deadline sentinel.

    Args:
        command: Direct executable argv for this step.
        repo_root: Repository root the sentinel and child are anchored at.
        source: Which pipeline artifact this step belongs to.
        step: Either ``build`` or ``run``.
        timeout_seconds: Wall-clock ceiling handed to the supervisor.
        supervisor: The watchdog entrypoint that runs the command.
        marker_prefix: When given, the step's stdout is teed through the
            supervisor so the last complete module marker survives the ending.

    Returns:
        The step's structured termination plus, when a marker prefix was
        requested, the last classified module the step had started.
    """
    retention = (
        None
        if marker_prefix is None
        else watchdog.MarkerRetention(marker_prefix)
    )
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
            marker_retention=retention,
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
    return StepResult(
        source,
        step,
        termination,
        None
        if retention is None
        else _last_module(retention.text, marker_prefix or ""),
    )


def _build_commands(
    *, debug_symbols: bool = False
) -> tuple[tuple[str, list[str]], ...]:
    """Return the exact one-package, one-native, one-aggregate build pipeline.

    Args:
        debug_symbols: Whether the aggregate carries line tables. Off by default
            because they cost roughly forty percent more build time and double
            the binary; a crash investigation turns them on to trade that for a
            backtrace naming files and lines.

    Returns:
        One command per build step, in dependency order.
    """
    aggregate_source = str(AGGREGATE_SOURCE)
    aggregate_binary = str(AGGREGATE_BINARY)
    symbol_flags = ["--debug-level=line-tables"] if debug_symbols else []
    return (
        ("package", ["bash", "scripts/build/mojo_package.sh"]),
        ("native adapter", [sys.executable, "-m", "scripts.build.native"]),
        (
            "aggregate suite",
            [
                "mojo",
                "build",
                "--no-optimization",
                *symbol_flags,
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
    marker_prefix = _marker_prefix()
    modules = aggregate.write_entrypoint(
        repo_root, aggregate_source, roots, marker_prefix
    )
    print(
        f"aggregate-tests: generated {AGGREGATE_SOURCE} for {len(modules)} "
        f"module(s), {sum(len(module.test_functions) for module in modules)} test(s)",
        flush=True,
    )

    resolved_environment = (
        dict(os.environ) if environment is None else environment
    )
    timeout_seconds = _timeout_seconds(resolved_environment)
    debug_symbols = _debug_symbols_requested(resolved_environment)
    for source, command in _build_commands(debug_symbols=debug_symbols):
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

    # The Mojo runtime resolves the symbolizer from the child's own environment,
    # and the supervisor hands the aggregate this process's environment
    # unchanged, so exporting the path here is what reaches the crashing binary.
    # An operator-supplied value always wins.
    symbolizer = _symbolizer_path()
    if symbolizer is not None:
        os.environ.setdefault(SYMBOLIZER_ENV, str(symbolizer))

    print("==> running aggregate test binary", flush=True)
    return _run_step(
        [str(repo_root / AGGREGATE_BINARY)],
        repo_root=repo_root,
        source="aggregate suite",
        step="run",
        timeout_seconds=timeout_seconds,
        supervisor=supervisor,
        marker_prefix=marker_prefix,
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
    # A failed aggregate is one binary covering the whole classified inventory,
    # so the ending alone says nothing about where it stopped. Name the last
    # module it announced whenever the run reached one.
    provenance = (
        "" if result.last_module is None else f"; last module: {result.last_module}"
    )
    if isinstance(termination, watchdog.Exited):
        if termination.code == 0:
            print("All aggregate test modules passed.")
            return 0
        print(
            f"FAILED: {label} exit {termination.code}){provenance}",
            file=sys.stderr,
        )
        return 1
    if isinstance(termination, watchdog.TimedOut):
        timed_out_source = (
            "aggregate" if result.source == "aggregate suite" else result.source
        )
        print(
            f"FATAL: classified: stopping after timed-out {timed_out_source} "
            f"{result.step}{provenance}",
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
            f"CRASHED: {label} signal {termination.signo}){provenance}",
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
