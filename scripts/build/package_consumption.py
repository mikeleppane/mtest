#!/usr/bin/env python3
"""The packaged-artifact consumption GATE.

`recipe/recipe.yaml` builds mtest into a LOCAL conda channel with a
`mojo-compiler ==1.0.0b2` run dependency (see `pixi run package-build`). That
proves the recipe *solves*; it does not prove the artifact it produces is
actually consumable by someone who only has the package, not this repo's dev
toolchain. This script is that proof, run in six ordered stages:

  1. Build the package into a LOCAL channel (`pixi run package-build`,
     unmodified -- this script reuses that exact task rather than duplicating
     its command). No network beyond the solve; nothing is uploaded. The stage
     returns the ONE artifact it produced, identified by version, build string,
     subdir, and SHA-256.
  2. Install that exact artifact into a FRESH scratch pixi env, solving from
     the LOCAL channel plus the modular + conda-forge channels (needed to
     resolve the declared run dependencies). The matchspec is constrained to
     the produced version AND build string, and the installed
     `conda-meta/mtest-<version>-<build>.json` record is then compared against
     the built artifact's SHA-256 and subdir: a same-version package pulled
     from a remote channel fails here. Also confirms the solve pulled
     `mojo-compiler ==1.0.0b2`, then compiles the installed assertion source at
     `-O0` and `-O3` with that exact compiler.
  3. LOADER-CLEAN PROBE FIRST, on the INSTALLED binary: run `mtest --version`
     and `mtest --help` with THIS PROCESS's own child environment scrubbed --
     the dev pixi env absent from PATH, this platform's loader-path variables
     empty. This is us scrubbing our own env for our own artifact, not the
     forbidden child-process env scrub inside the product. The raw dev build
     (`build/mtest`) is NOT loader-clean this way: it needs the Mojo runtime
     libraries, which the dev pixi env supplies but a scrubbed env does not.
     The INSTALLED package must be loader-clean via the declared Mojo runtime
     dependency. The same scrubbed probe parses a present config before an
     expected discovery refusal. A loader failure here is a recipe
     run-dependency gap, not a retry-able flake -- this script stops and
     reports it.
  4. Toolchain-threaded dogfood run: three focused executable probes, run
     through the INSTALLED binary (never `build/mtest`). Unlike stage 3, this
     stage does NOT scrub the environment -- the probes' compiler children need
     `mojo` on PATH. Reuses dogfood's exact-membership gate, parameterized onto
     the installed binary.
  5. Known-failing fixture run through the INSTALLED binary. A green dogfood
     run only proves the package can report success; this stage proves it
     reports FAILURE truthfully -- exact exit 1, exactly one FAIL verdict row
     naming the fixture, no PASS verdict row, and a summary carrying the
     fixture's one failure with nothing left unrun.
  6. Tarball fallback smoke-run: build the SAME recipe in the classic tar-bz2
     package format into its own local channel, install it into a second
     scratch env (again pinned to that build's exact build string and verified
     against its recorded SHA-256), run `--version`, and repeat the installed
     assertion-source proof.

Both gated platforms run this identical gate: the subdir, the loader-inspection
command, and the loader environment variables come from one immutable
descriptor resolved for the host (`package_platform`), never from a constant.

The scratch envs live under build/ (gitignored); nothing here uploads,
publishes, or authenticates anywhere. `mojo run` never appears -- every binary
is BUILT then EXECUTED directly.

Usage:  pixi run package-check
        python -m scripts.build.package_consumption
"""

from __future__ import annotations

import configparser
from dataclasses import dataclass
import difflib
import glob
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys

from scripts.harness import dogfood, watchdog


REPO_ROOT = Path(__file__).resolve().parents[2]
PIXI_TOML = REPO_ROOT / "pixi.toml"
RECIPE_PATH = REPO_ROOT / "recipe" / "recipe.yaml"

# Where `pixi run package-build` (invoked unmodified by stage 1) writes the
# primary `.conda` local channel -- must match that task's `--output-dir` in
# pixi.toml exactly, since stage 2 solves against it.
CONDA_CHANNEL_DIR = REPO_ROOT / "build" / "conda-channel"
# This script's own local channel for the tar-bz2 fallback form (stage 6) --
# kept separate from CONDA_CHANNEL_DIR so the two package formats never mix in
# one repodata.
TARBALL_CHANNEL_DIR = REPO_ROOT / "build" / "conda-channel-tarball"
# Root for every scratch pixi env this script creates. Wiped and recreated
# fresh on every run so a stale prior install can never masquerade as today's
# proof.
SCRATCH_ROOT = REPO_ROOT / "build" / "package-check"
CONDA_ENV_DIR = SCRATCH_ROOT / "conda-env"
TARBALL_ENV_DIR = SCRATCH_ROOT / "tarball-env"
LOADER_PROBE_CWD = SCRATCH_ROOT / "loader-probe-cwd"

MODULAR_CHANNEL = "https://conda.modular.com/max/"
CONDA_FORGE_CHANNEL = "conda-forge"

# The known-failing fixture stage 5 drives through the installed binary. It is
# an e2e fixture with a declared, manifest-pinned outcome (verdict FAIL, exit
# class 1, two passing and one failing test); scripts/checks/layout.py fails the
# cheap harness gate if that declaration and these constants ever disagree.
FAILING_FIXTURE = "e2e/suite/test_failing.mojo"
FAILING_FIXTURE_PASSED = 2
FAILING_FIXTURE_FAILED = 1


class PackageCheckError(RuntimeError):
    """A stage failed and the gate must stop -- never papered over."""


@dataclass(frozen=True)
class PackagePlatform:
    """One gated build-and-consume target's platform-specific vocabulary.

    Attributes:
        subdir: The conda subdir the recipe builds into and the scratch
            manifests solve for (for example `linux-64`).
        loader_command: The argv prefix that lists a binary's dynamic library
            dependencies, used for stage-3 diagnostics.
        loader_env_names: The dynamic-loader search-path environment variables
            the loader-clean probe must present as empty.
    """

    subdir: str
    loader_command: tuple[str, ...]
    loader_env_names: tuple[str, ...]


# The exact `(sys.platform, platform.machine())` pairs this gate supports. Both
# are blocking CI lanes; anything else is an unproven target and must stop the
# gate rather than silently borrow another platform's answers.
SUPPORTED_PLATFORMS: dict[tuple[str, str], PackagePlatform] = {
    ("linux", "x86_64"): PackagePlatform(
        subdir="linux-64",
        loader_command=("ldd",),
        loader_env_names=("LD_LIBRARY_PATH",),
    ),
    ("darwin", "arm64"): PackagePlatform(
        subdir="osx-arm64",
        loader_command=("otool", "-L"),
        loader_env_names=("DYLD_LIBRARY_PATH",),
    ),
}


def package_platform(sys_platform: str, machine: str) -> PackagePlatform:
    """Resolve the immutable platform descriptor for one host.

    Args:
        sys_platform: A `sys.platform` value, for example `linux` or `darwin`.
        machine: A `platform.machine()` value, for example `x86_64` or `arm64`.

    Returns:
        The descriptor registered for that exact pair.

    Raises:
        PackageCheckError: The pair is not a gated packaging target.
    """
    descriptor = SUPPORTED_PLATFORMS.get((sys_platform, machine))
    if descriptor is None:
        supported = sorted(SUPPORTED_PLATFORMS)
        raise PackageCheckError(
            f"unsupported packaging host {sys_platform!r}/{machine!r}: this gate "
            f"builds and consumes only {supported}"
        )
    return descriptor


def host_platform() -> PackagePlatform:
    """Resolve the descriptor for the host this process is running on.

    Returns:
        The descriptor for `sys.platform` and `platform.machine()`.

    Raises:
        PackageCheckError: This host is not a gated packaging target.
    """
    return package_platform(sys.platform, platform.machine())


@dataclass(frozen=True)
class BuiltArtifact:
    """The single package artifact one build stage produced.

    Attributes:
        path: Absolute path to the artifact inside the local channel.
        version: The package version the artifact carries.
        build_string: The build string the artifact carries.
        sha256: The artifact file's SHA-256, hex-encoded.
        subdir: The channel subdir the artifact was written into.
    """

    path: Path
    version: str
    build_string: str
    sha256: str
    subdir: str


# Artifacts stage 4 needs from THIS repo checkout (not from the isolated
# rattler-build sandbox): the precompiled package the probes import against,
# and the test-variant native object linked into each probe build -- the exact
# pair scripts/harness/dogfood.py uses for `pixi run dogfood-check`.
MOJOPKG_INCLUDE_DIR = REPO_ROOT / "build"
NATIVE_TEST_OBJECT = REPO_ROOT / "build" / "native" / "mtest_exec_native_test.o"

PIXI_VERSION_RE = re.compile(r'(?m)^version = "([^"]*)"')

BUILD_TIMEOUT = 600.0
INSTALL_TIMEOUT = 300.0
PROBE_TIMEOUT = 30.0
SMOKE_TIMEOUT = 60.0
# The fixture stage compiles one file through the installed binary. Generous for
# the same reason dogfood's ceiling is: a hosted runner may have a cold Mojo
# compiler cache, and the limit exists only to catch a genuine hang.
FIXTURE_TIMEOUT = 300.0

# `PASS e2e/...`-shaped verdict rows: a token at column zero, then the file the
# verdict belongs to. Captured child output is indented, so it can never be
# mistaken for a verdict mtest itself reported.
VERDICT_ROW_RE = re.compile(
    r"^(?P<token>PASS|FAIL|CRASH|TIMEOUT|COMPILE-ERROR|NO-TESTS)\s+(?P<path>\S+)",
    re.MULTILINE,
)
# The console summary band, as pinned by scripts/e2e/assertions.py.
SUMMARY_RE = re.compile(
    r"^=====\s+(?P<passed>\d+) passed,\s+(?P<failed>\d+) failed,\s+"
    r"(?P<skipped>\d+) skipped"
    r"[^(]*\((?P<excluded>\d+) excluded,\s+(?P<not_run>\d+) not run",
    re.MULTILINE,
)

INSTALLED_ASSERTION_FILES = {
    Path("mtest/__init__.mojo"),
    Path("mtest/assertions/__init__.mojo"),
    Path("mtest/assertions/_display.mojo"),
    Path("mtest/assertions/_mapping.mojo"),
    Path("mtest/assertions/_sequence.mojo"),
    Path("mtest/assertions/_text.mojo"),
}
INSTALLED_ASSERTION_DIRECTORIES = {
    Path("."),
    Path("mtest"),
    Path("mtest/assertions"),
}
ASSERTION_PROBE_SOURCE = """\
from mtest.assertions import assert_equal


def main() raises:
    assert_equal(1, 1)
    assert_equal([1, 2], [1, 2])
    assert_equal({"key": 1}, {"key": 1})
    var detail = String("")
    try:
        assert_equal("left", "right")
    except error:
        detail = String(error)
    if "text differs at scalar 0" not in detail:
        raise Error("installed assertion diagnostic was not selected")
"""
PRIVATE_IMPORT_PROBE_SOURCE = """\
from mtest.session import run_session


def main():
    pass
"""
PRIVATE_HELPER_PROBE_SOURCE = """\
from mtest.assertions import BoundedWriter


def main():
    _ = BoundedWriter(16)
"""
ASSERTION_EXAMPLE = REPO_ROOT / "examples" / "assertions" / "test_diagnostics.mojo"
ASSERTION_README_SECTION = "## Assertion diagnostics\n"
ASSERTION_MOJO_FENCE = "```mojo\n"
ASSERTION_CONSOLE_FENCE = "```console\n"


# The exact roster of stages one full gate run must perform, in order. The
# closing summary is DERIVED from what actually ran (see `completed_stages`),
# never assembled from this roster: a gate that skips a proof while printing
# that the proof happened is worse than one that omits it honestly.
GATE_STAGE_IDS = (
    "build",
    "install",
    "loader-clean",
    "assertion-source",
    "assertion-example",
    "dogfood",
    "failing-fixture",
    "tarball-assertion-source",
    "tarball-assertion-example",
    "tarball",
)

# The probes stage 3 must run on the installed binary, in order. Its closing
# line is derived from these and checked against them, for the same reason.
LOADER_PROBE_FLAGS = ("--version", "--help", "--config")
ASSERTION_OPTIMIZATIONS = (("-O0", "o0"), ("-O3", "o3"))

# Pixi 0.72.0 installs the legacy tar-bz2 artifact into its disposable prefix
# with the prefix's group-write policy (664 files and 775 directories), while
# the .conda artifact retains the recipe's 644/755 modes. Both non-world-
# writable forms are accepted so the gate validates installed bytes instead of
# rewriting installer-owned modes before compilation.
PRIMARY_ASSERTION_FILE_MODES = (0o644,)
TARBALL_ASSERTION_FILE_MODES = (0o644, 0o664)

_COMPLETED_STAGES: list[str] = []


def reset_completed_stages() -> None:
    """Forget every recorded stage, so one process can run the gate twice."""
    _COMPLETED_STAGES.clear()


def record_completed_stage(stage_id: str) -> None:
    """Record that one stage reached its end without stopping the gate.

    Args:
        stage_id: A member of `GATE_STAGE_IDS`.

    Raises:
        PackageCheckError: The id is not a known stage, or already recorded.
    """
    if stage_id not in GATE_STAGE_IDS:
        raise PackageCheckError(f"unknown gate stage {stage_id!r}")
    if stage_id in _COMPLETED_STAGES:
        raise PackageCheckError(f"gate stage {stage_id!r} completed twice")
    _COMPLETED_STAGES.append(stage_id)


def completed_stages() -> tuple[str, ...]:
    """Return the stages this process has completed, in completion order."""
    return tuple(_COMPLETED_STAGES)


def verify_every_stage_ran() -> None:
    """Refuse to report success unless every rostered stage actually ran.

    A deleted stage call site would otherwise leave the gate exiting 0 while its
    closing banner still claimed the missing proof.

    Raises:
        PackageCheckError: A rostered stage did not run, or stages ran out of
            their declared order.
    """
    if completed_stages() != GATE_STAGE_IDS:
        missing = [stage for stage in GATE_STAGE_IDS if stage not in _COMPLETED_STAGES]
        raise PackageCheckError(
            "the gate did not perform every stage it reports: ran "
            f"{list(completed_stages())}, expected {list(GATE_STAGE_IDS)}"
            + (f", missing {missing}" if missing else " in that order")
        )


def verify_assertion_optimization_roster(performed: tuple[str, ...]) -> None:
    """Refuse to summarize assertion compiles that skipped an optimization."""
    expected = tuple(optimization for optimization, _suffix in ASSERTION_OPTIMIZATIONS)
    if performed != expected:
        missing = [item for item in expected if item not in performed]
        raise PackageCheckError(
            "assertion optimization roster mismatch: "
            f"ran {list(performed)}, expected {list(expected)}, missing {missing}"
        )


def assertion_compile_command(
    env_prefix: Path,
    source: Path,
    output: Path,
    optimization: str,
) -> list[str]:
    """Build one probe with absolute installed compiler and source paths."""
    return [
        str((env_prefix / "bin" / "mojo").resolve()),
        "build",
        optimization,
        "-I",
        str((env_prefix / "share" / "mtest" / "assertions-src").resolve()),
        str(source.resolve()),
        "-o",
        str(output.resolve()),
    ]


def assertion_probe_environment(
    env_prefix: Path,
    target: PackagePlatform | None = None,
) -> dict[str, str]:
    """Return a compiler environment isolated onto one installed prefix."""
    prefix = env_prefix.resolve()
    selected = target or host_platform()
    environment = {
        "PATH": "/usr/bin:/bin",
        "HOME": os.environ.get("HOME", "/tmp"),
        "MODULAR_HOME": str(prefix / "share" / "max"),
    }
    environment.update(dict.fromkeys(selected.loader_env_names, str(prefix / "lib")))
    return environment


def validate_assertion_install(
    env_prefix: Path,
    *,
    allow_installer_group_write: bool = False,
) -> Path:
    """Require the exact public source files, safe modes, and compiler provenance."""
    prefix = env_prefix.resolve()
    source_root = prefix / "share" / "mtest" / "assertions-src"
    for relative in (
        Path("."),
        Path("share"),
        Path("share/mtest"),
        Path("share/mtest/assertions-src"),
    ):
        component = prefix / relative
        try:
            component_mode = component.lstat().st_mode
        except FileNotFoundError as exc:
            raise PackageCheckError(
                f"installed assertion path component is missing: {relative}"
            ) from exc
        if stat.S_ISLNK(component_mode) or not stat.S_ISDIR(component_mode):
            raise PackageCheckError(
                "installed assertion path component must be a real directory: "
                f"{relative}"
            )
        _require_safe_assertion_directory(
            component,
            relative,
            allow_installer_group_write=(
                allow_installer_group_write
                or relative == Path(".")
                or relative == Path("share")
            ),
        )
    entries = list(source_root.rglob("*"))
    symbolic_links = [
        path.relative_to(source_root) for path in entries if path.is_symlink()
    ]
    if symbolic_links:
        raise PackageCheckError(
            f"installed assertion source contains a symbolic link: "
            f"{sorted(symbolic_links)}"
        )
    actual_entries = {path.relative_to(source_root) for path in entries}
    expected_entries = INSTALLED_ASSERTION_FILES | (
        INSTALLED_ASSERTION_DIRECTORIES - {Path(".")}
    )
    if actual_entries != expected_entries:
        raise PackageCheckError(
            "installed assertion entry set differs: "
            f"missing={sorted(expected_entries - actual_entries)}, "
            f"extra={sorted(actual_entries - expected_entries)}"
        )
    actual_files = {
        path.relative_to(source_root)
        for path in entries
        if stat.S_ISREG(path.lstat().st_mode)
    }
    if actual_files != INSTALLED_ASSERTION_FILES:
        raise PackageCheckError(
            "installed assertion file set differs: "
            f"missing={sorted(INSTALLED_ASSERTION_FILES - actual_files)}, "
            f"extra={sorted(actual_files - INSTALLED_ASSERTION_FILES)}"
        )
    for relative in sorted(INSTALLED_ASSERTION_FILES):
        source = source_root / relative
        source_mode = source.lstat().st_mode
        if not stat.S_ISREG(source_mode):
            raise PackageCheckError(
                f"installed assertion source must be a regular file: {relative}"
            )
        mode = stat.S_IMODE(source_mode)
        allowed_modes = (
            TARBALL_ASSERTION_FILE_MODES
            if allow_installer_group_write
            else PRIMARY_ASSERTION_FILE_MODES
        )
        if mode not in allowed_modes:
            requirement = (
                "mode 644 or installer-normalized 664"
                if allow_installer_group_write
                else "exact mode 644"
            )
            raise PackageCheckError(
                f"installed assertion source must have {requirement}: "
                f"{relative} has {mode:o}"
            )
        checkout_source = REPO_ROOT / "assertions-src" / relative
        if source.read_bytes() != checkout_source.read_bytes():
            raise PackageCheckError(
                f"installed assertion source bytes differ: {relative}"
            )
    for relative in sorted(INSTALLED_ASSERTION_DIRECTORIES):
        directory = source_root / relative
        _require_safe_assertion_directory(
            directory,
            Path("share/mtest/assertions-src") / relative,
            allow_installer_group_write=allow_installer_group_write,
        )
    if list(source_root.rglob("*.mojopkg")):
        raise PackageCheckError("installed assertion source contains a mojopkg")

    mojo = prefix / "bin" / "mojo"
    if not mojo.is_file() or not os.access(mojo, os.X_OK):
        raise PackageCheckError(f"installed compiler is missing: {mojo}")
    config = prefix / "share" / "max" / "modular.cfg"
    if not config.is_file():
        raise PackageCheckError(f"installed modular.cfg is missing: {config}")
    _validate_modular_config(config, prefix)
    return source_root


def _validate_modular_config(config: Path, prefix: Path) -> None:
    """Require unique, exact compiler-root assignments in installed config."""
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    try:
        with config.open(encoding="utf-8") as stream:
            parser.read_file(stream)
    except (configparser.Error, UnicodeError) as exc:
        raise PackageCheckError(
            f"installed modular.cfg is invalid or contains a duplicate: {exc}"
        ) from exc
    expected = {
        ("max", "package_root"): str(prefix),
        ("mojo-max", "package_root"): str(prefix),
        ("mojo-max", "driver_path"): str(prefix / "bin" / "mojo"),
        ("mojo-max", "import_path"): str(prefix / "lib" / "mojo"),
    }
    mismatches: list[str] = []
    for (section, option), expected_value in expected.items():
        observed = parser.get(section, option, raw=True, fallback=None)
        if observed != expected_value:
            mismatches.append(
                f"[{section}] {option}: expected {expected_value!r}, got {observed!r}"
            )
    if mismatches:
        raise PackageCheckError(
            "installed modular.cfg does not name its own prefix exactly: "
            + "; ".join(mismatches)
        )


def _require_safe_assertion_directory(
    directory: Path,
    relative: Path,
    *,
    allow_installer_group_write: bool,
) -> None:
    """Require one installed source path to resist unintended replacement."""
    mode = stat.S_IMODE(directory.stat().st_mode)
    if mode & 0o002 or mode & 0o555 != 0o555 or mode & 0o7000:
        raise PackageCheckError(
            "installed assertion directory must be traversable and not "
            "world-writable or carry special bits: "
            f"{relative} has {mode:o}"
        )
    if mode & 0o020 and not allow_installer_group_write:
        raise PackageCheckError(
            "installed assertion directory must not be group-writable in the "
            f"primary package: {relative} has {mode:o}"
        )


def require_missing_runner_module(diagnostic: str) -> None:
    """Require the semantic rejection for the runner-private module."""
    if "error: unable to locate module 'session'" not in diagnostic:
        raise PackageCheckError(
            "private runner import failed for the wrong reason: " + diagnostic
        )


def require_missing_facade_export(diagnostic: str, helper: str) -> None:
    """Require the semantic rejection for one package-facade helper."""
    expected = f"package 'assertions' does not contain '{helper}'"
    if expected not in diagnostic:
        raise PackageCheckError(
            f"{helper} facade probe failed for the wrong reason: " + diagnostic
        )


def require_warning_free_assertion_compile(
    transcript: str,
    label: str,
    optimization: str,
) -> None:
    """Reject warnings from an installed assertion-source consumer compile."""
    if "warning:" in transcript:
        raise PackageCheckError(
            f"{label} assertion compiler warning at {optimization}: {transcript}"
        )


def _run_assertion_process(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: float,
) -> subprocess.CompletedProcess[str]:
    """Run one package assertion probe with bounded process-group supervision."""
    captured = watchdog.run_captured_command(
        command,
        source=command[0] if command else "<empty>",
        step="package assertion probe",
        timeout_seconds=timeout,
        cwd=cwd,
        env=env,
    )
    termination = captured.termination
    if isinstance(termination, watchdog.Exited):
        return subprocess.CompletedProcess(
            command,
            termination.code,
            captured.stdout,
            captured.stderr,
        )
    if isinstance(termination, watchdog.Signaled):
        return subprocess.CompletedProcess(
            command,
            -termination.signo,
            captured.stdout,
            captured.stderr,
        )
    rendered = " ".join(command)
    if isinstance(termination, watchdog.TimedOut):
        raise PackageCheckError(
            f"assertion process exceeded {timeout} seconds: {rendered}"
        )
    if isinstance(termination, watchdog.Cancelled):
        raise PackageCheckError(
            f"assertion process cancelled by signal {termination.signo}: {rendered}"
        )
    raise PackageCheckError(
        f"assertion process supervision failed: {termination.detail}: {rendered}"
    )


def stage_assertion_source_probe(
    env_prefix: Path,
    label: str,
    *,
    completion_id: str | None = None,
) -> None:
    """Compile and run public-source probes from one installed package form."""
    _banner(f"installed assertion source probe -- {label}")
    source_root = validate_assertion_install(
        env_prefix,
        allow_installer_group_write=label == "tarball",
    )
    probe_root = SCRATCH_ROOT / f"assertion-probe-{label}"
    if probe_root.exists():
        shutil.rmtree(probe_root)
    probe_root.mkdir(parents=True)
    positive = probe_root / "consumer.mojo"
    negative = probe_root / "private_import.mojo"
    private_helper = probe_root / "private_helper.mojo"
    positive.write_text(ASSERTION_PROBE_SOURCE, encoding="utf-8")
    negative.write_text(PRIVATE_IMPORT_PROBE_SOURCE, encoding="utf-8")
    private_helper.write_text(PRIVATE_HELPER_PROBE_SOURCE, encoding="utf-8")
    environment = assertion_probe_environment(env_prefix)
    checkout_source = str((REPO_ROOT / "assertions-src").resolve())

    performed_optimizations: list[str] = []
    for optimization, suffix in ASSERTION_OPTIMIZATIONS:
        binary = probe_root / f"consumer-{suffix}"
        command = assertion_compile_command(
            env_prefix,
            positive,
            binary,
            optimization,
        )
        if checkout_source in " ".join(command):
            raise PackageCheckError(
                "installed assertion compile command leaked checkout source"
            )
        build = _run_assertion_process(
            command,
            cwd=probe_root,
            env=environment,
            timeout=SMOKE_TIMEOUT,
        )
        transcript = build.stdout + build.stderr
        if checkout_source in transcript:
            raise PackageCheckError(
                "installed assertion compiler output leaked checkout source"
            )
        if build.returncode != 0 or not binary.is_file():
            raise PackageCheckError(
                f"{label} assertion probe compile failed at {optimization}: "
                f"{transcript}"
            )
        require_warning_free_assertion_compile(
            transcript,
            label,
            optimization,
        )
        run = _run_assertion_process(
            [str(binary)],
            cwd=probe_root,
            env=environment,
            timeout=SMOKE_TIMEOUT,
        )
        if run.returncode != 0:
            raise PackageCheckError(
                f"{label} assertion probe exited {run.returncode} at "
                f"{optimization}: {run.stdout}{run.stderr}"
            )
        performed_optimizations.append(optimization)
    verify_assertion_optimization_roster(tuple(performed_optimizations))

    negative_binary = probe_root / "private-import"
    negative_command = assertion_compile_command(
        env_prefix,
        negative,
        negative_binary,
        "-O0",
    )
    rejected = _run_assertion_process(
        negative_command,
        cwd=probe_root,
        env=environment,
        timeout=SMOKE_TIMEOUT,
    )
    rejection = rejected.stdout + rejected.stderr
    if rejected.returncode == 0 or negative_binary.exists():
        raise PackageCheckError(
            f"{label} public source unexpectedly exposed mtest.session"
        )
    require_missing_runner_module(rejection)
    if checkout_source in rejection:
        raise PackageCheckError(
            "installed assertion negative probe leaked checkout source"
        )

    helper_binary = probe_root / "private-helper"
    helper_rejected = _run_assertion_process(
        assertion_compile_command(
            env_prefix,
            private_helper,
            helper_binary,
            "-O0",
        ),
        cwd=probe_root,
        env=environment,
        timeout=SMOKE_TIMEOUT,
    )
    helper_rejection = helper_rejected.stdout + helper_rejected.stderr
    if helper_rejected.returncode == 0 or helper_binary.exists():
        raise PackageCheckError(
            f"{label} public source unexpectedly exposed BoundedWriter"
        )
    require_missing_facade_export(helper_rejection, "BoundedWriter")
    if checkout_source in helper_rejection:
        raise PackageCheckError(
            "installed assertion helper probe leaked checkout source"
        )
    print(
        f"package-check: OK -- {label} installed {len(INSTALLED_ASSERTION_FILES)} "
        f"source files at {source_root}, compiled at "
        f"{'/'.join(performed_optimizations)}, and kept "
        "runner imports and helper facade exports unavailable",
        flush=True,
    )
    if completion_id is not None:
        record_completed_stage(completion_id)


def _readme_assertion_fence(
    contents: str,
    fence: str,
    label: str,
) -> str:
    if contents.count(ASSERTION_README_SECTION) != 1:
        raise PackageCheckError(
            "README must contain exactly one assertion-diagnostics section"
        )
    section_start = contents.index(ASSERTION_README_SECTION) + len(
        ASSERTION_README_SECTION
    )
    section_end = contents.find("\n## ", section_start)
    if section_end == -1:
        section_end = len(contents)
    section = contents[section_start:section_end]
    if section.count(fence) != 1:
        raise PackageCheckError(
            f"assertion-diagnostics section must contain exactly one {label} fence"
        )
    block_start = section.index(fence) + len(fence)
    block_end = section.find("\n```", block_start)
    if block_end == -1:
        raise PackageCheckError(f"assertion-diagnostics {label} fence is not closed")
    return section[block_start : block_end + 1]


def readme_assertion_example_block(contents: str) -> str:
    """Extract the sole console fence from the assertion-diagnostics section."""
    return _readme_assertion_fence(
        contents,
        ASSERTION_CONSOLE_FENCE,
        "console",
    )


def readme_assertion_source_block(contents: str) -> str:
    """Extract the sole Mojo fence from the assertion-diagnostics section."""
    return _readme_assertion_fence(
        contents,
        ASSERTION_MOJO_FENCE,
        "Mojo",
    )


def normalize_assertion_example(
    output: str,
    prefix: Path,
    repo_root: Path,
) -> str:
    """Normalize only installed paths and nondeterministic elapsed times."""
    normalized = output.replace(str(prefix.resolve()), "<PREFIX>").replace(
        str(repo_root.resolve()),
        "<REPO>",
    )
    return _normalize_assertion_times(normalized)


def _normalize_assertion_times(output: str) -> str:
    normalized = re.sub(
        r"(?m)^(FAIL\s+.+?)\s+\d+(?:\.\d+)?s$",
        r"\1  <TIME>",
        output,
    )
    normalized = re.sub(
        r"(?m)(^===== .+ in )\d+(?:\.\d+)?s( =====$)",
        r"\1<TIME>\2",
        normalized,
    )
    normalized = re.sub(
        r"(?m)^(\s+\|\s+(?:PASS|FAIL) \[ )\d+(?:\.\d+)?( \] .+)$",
        r"\1<TIME>\2",
        normalized,
    )
    normalized = re.sub(
        r"(?m)^(\s+\| Summary \[ )\d+(?:\.\d+)?( \] .+)$",
        r"\1<TIME>\2",
        normalized,
    )
    for unstable_line in (
        "    | Unhandled exception caught during execution: ",
        "    | Running 2 tests for <REPO>/examples/assertions/test_diagnostics.mojo ",
        "    | Summary [ <TIME> ] 2 tests run: 1 passed , 1 failed , 0 skipped ",
        "    | Test suite' <REPO>/examples/assertions/test_diagnostics.mojo 'failed! ",
        "    | ",
    ):
        normalized = normalized.replace(
            unstable_line + "\n",
            unstable_line.rstrip() + "\n",
        )
    return normalized


def stage_assertion_example(
    env_prefix: Path,
    mtest_bin: Path,
    *,
    allow_installer_group_write: bool = False,
    completion_id: str | None = None,
) -> None:
    """Run the committed diagnostic example through the installed artifact."""
    _banner("installed assertion README example")
    prefix = env_prefix.resolve()
    source_root = validate_assertion_install(
        prefix,
        allow_installer_group_write=allow_installer_group_write,
    )
    environment = assertion_probe_environment(prefix)
    environment["PATH"] = str(prefix / "bin") + ":/usr/bin:/bin"
    command = [
        str(mtest_bin.resolve()),
        "--show-output",
        "failures",
        "-I",
        str(source_root),
        str(ASSERTION_EXAMPLE.parent.relative_to(REPO_ROOT)),
    ]
    result = _run_assertion_process(
        command,
        cwd=REPO_ROOT,
        env=environment,
        timeout=SMOKE_TIMEOUT,
    )
    if result.returncode != 1 or result.stderr:
        raise PackageCheckError(
            "installed assertion example did not produce one ordinary failure: "
            f"exit={result.returncode}, stdout={result.stdout!r}, "
            f"stderr={result.stderr!r}"
        )
    required = (
        "1 passed, 1 failed, 0 skipped",
        "text differs at scalar 6",
        "actual: U+0062 'b'",
        "expected: U+0042 'B'",
        "reason: configuration text changed",
    )
    missing = [text for text in required if text not in result.stdout]
    if missing:
        raise PackageCheckError(
            f"installed assertion example output is incomplete: {missing}"
        )
    normalized = normalize_assertion_example(result.stdout, prefix, REPO_ROOT)
    readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
    documented_source = readme_assertion_source_block(readme)
    example_source = ASSERTION_EXAMPLE.read_text(encoding="utf-8")
    if documented_source != example_source:
        diff = "".join(
            difflib.unified_diff(
                documented_source.splitlines(keepends=True),
                example_source.splitlines(keepends=True),
                fromfile="README.md assertion Mojo fence",
                tofile=str(ASSERTION_EXAMPLE.relative_to(REPO_ROOT)),
            )
        )
        raise PackageCheckError(
            "README assertion source differs from the executed example:\n" + diff
        )
    documented = readme_assertion_example_block(readme)
    actual = (
        "$ mtest --show-output failures -I "
        "<PREFIX>/share/mtest/assertions-src examples/assertions\n" + normalized
    )
    normalized_documented = _normalize_assertion_times(documented)
    if normalized_documented != actual:
        diff = "".join(
            difflib.unified_diff(
                normalized_documented.splitlines(keepends=True),
                actual.splitlines(keepends=True),
                fromfile="README.md assertion console fence",
                tofile="installed assertion example",
            )
        )
        raise PackageCheckError(
            "README assertion example differs from installed output:\n" + diff
        )
    capture = SCRATCH_ROOT / "assertion-example-output.txt"
    capture.write_text(actual, encoding="utf-8")
    print(actual, end="", flush=True)
    print(
        f"package-check: captured normalized README output at {capture}",
        flush=True,
    )
    if completion_id is not None:
        record_completed_stage(completion_id)


def _banner(label: str) -> None:
    print(f"\n==> package-check: {label}", flush=True)


def repo_version() -> str:
    """The workspace `version` field from pixi.toml (e.g. "0.4.0").

    `pixi run version-check` is the drift oracle between this field and
    MTEST_VERSION; this function just reads the current value to build the
    scratch envs' `mtest ==<version>` matchspec.
    """
    text = PIXI_TOML.read_text(encoding="utf-8")
    match = PIXI_VERSION_RE.search(text)
    if match is None:
        raise PackageCheckError(f'could not find `version = "..."` in {PIXI_TOML}')
    return match.group(1)


def _run_streamed(
    argv: list[str], *, cwd: Path, timeout: float, env: dict[str, str] | None = None
) -> int:
    """Run `argv` with stdout/stderr passed straight through to ours.

    Passing the streams through keeps the transcript visible live. The run is
    held to a hard wall-clock ceiling.

    `env=None` means inherit this process's own environment unchanged --
    stages 1, 2, 4, and 5 rely on that to keep `mojo`/`rattler-build`/`pixi` on
    PATH. Only the stage-3 loader-clean probe passes an explicit, scrubbed env.
    """
    print(f"$ {' '.join(argv)}", flush=True)
    try:
        proc = subprocess.run(argv, cwd=cwd, timeout=timeout, env=env, check=False)
    except FileNotFoundError as exc:
        raise PackageCheckError(f"`{argv[0]}` not found on PATH: {exc}") from exc
    except subprocess.TimeoutExpired as exc:
        raise PackageCheckError(
            f"`{' '.join(argv)}` did not finish within {timeout:.0f}s"
        ) from exc
    return proc.returncode


def _sha256(path: Path) -> str:
    """Return the hex-encoded SHA-256 of one file.

    Args:
        path: The file to digest.

    Returns:
        The lowercase hex digest.
    """
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def sole_built_artifact(
    channel_dir: Path, version: str, target: PackagePlatform, suffix: str
) -> BuiltArtifact:
    """Identify the ONE artifact a build stage just wrote into a local channel.

    The channel directory is wiped before every build, so more than one match
    means the build produced an ambiguity the later stages could silently
    resolve the wrong way.

    Args:
        channel_dir: Local channel root the build wrote into.
        version: Package version the artifact must carry.
        target: Descriptor whose subdir names the channel subdirectory.
        suffix: Package-format suffix, for example `.conda` or `.tar.bz2`.

    Returns:
        The artifact's identity, including its SHA-256.

    Raises:
        PackageCheckError: No artifact matched, or more than one did.
    """
    subdir_path = channel_dir / target.subdir
    pattern = f"mtest-{version}-*{suffix}"
    matches = sorted(glob.glob(str(subdir_path / pattern)))
    if len(matches) != 1:
        raise PackageCheckError(
            f"expected exactly one {pattern} artifact under {subdir_path}, "
            f"found {len(matches)}: {matches}"
        )
    path = Path(matches[0])
    build_string = path.name[len(f"mtest-{version}-") : -len(suffix)]
    if not build_string:
        raise PackageCheckError(f"could not read a build string from {path.name}")
    return BuiltArtifact(
        path=path,
        version=version,
        build_string=build_string,
        sha256=_sha256(path),
        subdir=target.subdir,
    )


def stage_build_local_channel(target: PackagePlatform | None = None) -> BuiltArtifact:
    """Stage 1: build the recipe into the LOCAL channel.

    Goes through the unmodified `package-build` pixi task, and wipes any prior
    channel dir first so this run's artifact can never be mistaken for a stale
    one.

    Args:
        target: Platform descriptor to build for; the host's when omitted.

    Returns:
        The identity of the single artifact the build produced.

    Raises:
        PackageCheckError: The build failed or produced no unique artifact.
    """
    resolved = host_platform() if target is None else target
    _banner(f"stage 1/6 -- build the package into a LOCAL channel ({resolved.subdir})")
    if CONDA_CHANNEL_DIR.exists():
        shutil.rmtree(CONDA_CHANNEL_DIR)

    code = _run_streamed(
        ["pixi", "run", "package-build"], cwd=REPO_ROOT, timeout=BUILD_TIMEOUT
    )
    if code != 0:
        raise PackageCheckError(f"`pixi run package-build` exited {code}")

    artifact = sole_built_artifact(
        CONDA_CHANNEL_DIR, repo_version(), resolved, ".conda"
    )
    print(
        f"package-check: built {artifact.path.relative_to(REPO_ROOT)} "
        f"(build {artifact.build_string}, sha256 {artifact.sha256})",
        flush=True,
    )
    record_completed_stage("build")
    return artifact


def scratch_manifest_text(name: str, channel_dir: Path, artifact: BuiltArtifact) -> str:
    """Render a throwaway pixi manifest pinned to one exact built artifact.

    The dependency is constrained to the produced version AND build string, and
    the platform list to the subdir that artifact was built for, so the solver
    cannot satisfy the request with a same-version package from the modular or
    conda-forge channels listed after the local one.

    Args:
        name: Workspace name for the scratch manifest.
        channel_dir: Local conda channel produced by rattler-build.
        artifact: The artifact the scratch env must install.

    Returns:
        The manifest text.
    """
    return (
        "[workspace]\n"
        f'name = "{name}"\n'
        'version = "0.0.0"\n'
        "channels = [\n"
        f'  "file://{channel_dir}",\n'
        f'  "{MODULAR_CHANNEL}",\n'
        f'  "{CONDA_FORGE_CHANNEL}",\n'
        "]\n"
        f'platforms = ["{artifact.subdir}"]\n'
        "\n"
        "[dependencies]\n"
        f'mtest = {{ version = "=={artifact.version}", '
        f'build = "{artifact.build_string}" }}\n'
    )


def _write_scratch_manifest(
    env_dir: Path, channel_dir: Path, artifact: BuiltArtifact
) -> Path:
    """Write the scratch manifest for one env and return its path.

    Args:
        env_dir: Scratch workspace directory to create the manifest in.
        channel_dir: Local conda channel produced by rattler-build.
        artifact: The artifact the scratch env must install.

    Returns:
        The written manifest's path.
    """
    env_dir.mkdir(parents=True, exist_ok=True)
    manifest = env_dir / "pixi.toml"
    manifest.write_text(
        scratch_manifest_text(env_dir.name, channel_dir, artifact),
        encoding="utf-8",
    )
    return manifest


def verify_installed_artifact_identity(
    env_prefix: Path, artifact: BuiltArtifact
) -> None:
    """Prove the solver installed THIS run's artifact, not a same-version twin.

    conda records what it installed in `conda-meta/<name>-<version>-<build>.json`,
    including the SHA-256 of the package file it fetched. Comparing that against
    the artifact the build stage produced is what distinguishes "an mtest of the
    right version is installed" from "the package we just built is installed".

    Args:
        env_prefix: Installed environment prefix containing `conda-meta`.
        artifact: The artifact the build stage produced.

    Raises:
        PackageCheckError: No record for that exact version and build string
            exists, or its recorded SHA-256 or subdir names a different package.
    """
    record_name = f"mtest-{artifact.version}-{artifact.build_string}.json"
    record_path = env_prefix / "conda-meta" / record_name
    if not record_path.is_file():
        present = sorted(
            path.name for path in (env_prefix / "conda-meta").glob("mtest-*.json")
        )
        raise PackageCheckError(
            f"the installed env has no {record_name} record -- the solve did not "
            f"install the artifact this run built; mtest records present: {present}"
        )
    try:
        record = json.loads(record_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise PackageCheckError(f"could not read {record_path}: {exc}") from exc

    recorded_sha = record.get("sha256")
    if recorded_sha != artifact.sha256:
        raise PackageCheckError(
            f"installed artifact identity mismatch: {record_name} records "
            f"sha256={recorded_sha!r}, but this run built "
            f"{artifact.path.name} with sha256={artifact.sha256!r} -- a "
            "same-version package was solved from another channel"
        )
    recorded_subdir = record.get("subdir")
    if recorded_subdir != artifact.subdir:
        raise PackageCheckError(
            f"installed artifact subdir mismatch: {record_name} records "
            f"subdir={recorded_subdir!r}, but this run built for "
            f"{artifact.subdir!r}"
        )
    print(
        f"package-check: installed artifact identity confirmed -- {record_name} "
        f"records sha256={recorded_sha} subdir={recorded_subdir}",
        flush=True,
    )


def stage_install_from_local_channel(artifact: BuiltArtifact) -> Path:
    """Stage 2: install the just-built package into a FRESH scratch pixi env.

    Solves from CONDA_CHANNEL_DIR (+ modular/conda-forge), proves the installed
    package IS that artifact, and confirms the solve pulled
    `mojo-compiler ==1.0.0b2` as a run dependency.

    Args:
        artifact: The artifact stage 1 produced.

    Returns:
        The absolute path to the installed `mtest` binary.

    Raises:
        PackageCheckError: The install failed, installed a different package,
            or did not pull the declared run dependency.
    """
    _banner("stage 2/6 -- install into a fresh scratch env from the LOCAL channel")
    if SCRATCH_ROOT.exists():
        shutil.rmtree(SCRATCH_ROOT)

    manifest = _write_scratch_manifest(CONDA_ENV_DIR, CONDA_CHANNEL_DIR, artifact)

    code = _run_streamed(
        ["pixi", "install", "--manifest-path", str(manifest)],
        cwd=CONDA_ENV_DIR,
        timeout=INSTALL_TIMEOUT,
    )
    if code != 0:
        raise PackageCheckError(f"`pixi install` (conda-env) exited {code}")

    env_prefix = CONDA_ENV_DIR / ".pixi" / "envs" / "default"
    mtest_bin = env_prefix / "bin" / "mtest"
    if not mtest_bin.is_file():
        raise PackageCheckError(f"installed env has no bin/mtest at {mtest_bin}")

    verify_installed_artifact_identity(env_prefix, artifact)

    conda_meta = sorted(
        (env_prefix / "conda-meta").glob("mojo-compiler-1.0.0b2-*.json")
    )
    if not conda_meta:
        raise PackageCheckError(
            "install did NOT pull mojo-compiler ==1.0.0b2 as a run dependency -- "
            f"no mojo-compiler-1.0.0b2-*.json under {env_prefix / 'conda-meta'}; "
            "this is a recipe run-dependency gap"
        )
    print(
        f"package-check: installed {mtest_bin.relative_to(REPO_ROOT)}; "
        f"run dependency confirmed: {conda_meta[0].name}",
        flush=True,
    )
    record_completed_stage("install")
    return mtest_bin


def verify_loader_probe_roster(performed: tuple[str, ...]) -> None:
    """Refuse to summarize the loader-clean stage as more than it ran.

    Stage 3's closing line names several probes in one sentence, so it must be
    derived from the probes that actually executed rather than written as prose.

    Args:
        performed: The probe flags that ran, in execution order.

    Raises:
        PackageCheckError: A declared probe did not run, or ran out of order.
    """
    if performed != LOADER_PROBE_FLAGS:
        raise PackageCheckError(
            "the loader-clean stage did not run every probe it reports: ran "
            f"{list(performed)}, expected {list(LOADER_PROBE_FLAGS)}"
        )


def scrubbed_probe_env(target: PackagePlatform) -> dict[str, str]:
    """Build the loader-clean child environment for one platform.

    Only PATH, HOME, and that platform's loader search-path variables are
    present: PATH without the dev pixi env, and every loader variable empty.
    Anything absent from this mapping is absent from the child's environment,
    which is the point -- the installed binary must load from its own declared
    run dependencies alone.

    Args:
        target: The resolved platform descriptor.

    Returns:
        The exact environment mapping to hand the probe children.
    """
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": os.environ.get("HOME", "/root"),
    }
    env.update(dict.fromkeys(target.loader_env_names, ""))
    return env


def stage_loader_clean_probe(mtest_bin: Path, target: PackagePlatform) -> None:
    """Stage 3: run the INSTALLED binary under a loader-clean child environment.

    Probes `--version` and `--help` with our own child environment scrubbed
    clean of the dev pixi env (PATH) and of this platform's loader search paths.

    This is us scrubbing OUR OWN subprocess environment to probe OUR OWN
    artifact -- not the forbidden child-env scrub inside the product itself.
    If the binary can only load with the dev toolchain on PATH, the recipe's
    declared runtime dependency set is not actually sufficient, and that is a
    packaging gap this script must stop and report, not paper over.

    Args:
        mtest_bin: The installed binary to probe.
        target: The resolved platform descriptor.

    Raises:
        PackageCheckError: The installed binary failed to load or run, or its
            output did not carry the expected version, help, or refusal.
    """
    _banner("stage 3/6 -- LOADER-CLEAN PROBE on the installed binary")
    LOADER_PROBE_CWD.mkdir(parents=True, exist_ok=True)

    scrubbed_env = scrubbed_probe_env(target)
    loader_argv = [*target.loader_command, str(mtest_bin)]
    print(
        f"$ {' '.join(target.loader_command)} <installed mtest> (scrubbed env)",
        flush=True,
    )
    try:
        loader = subprocess.run(
            loader_argv,
            cwd=LOADER_PROBE_CWD,
            env=scrubbed_env,
            capture_output=True,
            text=True,
            timeout=PROBE_TIMEOUT,
            check=False,
        )
    except FileNotFoundError as exc:
        # Diagnostics only: the executable probes below are the gate.
        print(f"(loader inspection unavailable: {exc})", flush=True)
    else:
        print(loader.stdout, end="", flush=True)
        if loader.stderr:
            print(loader.stderr, end="", file=sys.stderr, flush=True)

    version = repo_version()
    expected_version_line = f"mtest {version}"
    scrubbed_prefix = "env -i " + " ".join(
        f"{name}={value}" for name, value in scrubbed_env.items() if name != "HOME"
    )
    performed: list[str] = []

    for flag, expect_substring in (
        ("--version", expected_version_line),
        ("--help", "usage: mtest"),
    ):
        print(f"$ {scrubbed_prefix} <installed mtest> {flag}", flush=True)
        result = subprocess.run(
            [str(mtest_bin), flag],
            cwd=LOADER_PROBE_CWD,
            env=scrubbed_env,
            capture_output=True,
            text=True,
            timeout=PROBE_TIMEOUT,
            check=False,
        )
        print(result.stdout, end="", flush=True)
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr, flush=True)
        if result.returncode != 0:
            raise PackageCheckError(
                f"installed mtest {flag} exited {result.returncode} in a "
                "loader-clean (dev-toolchain-absent) environment -- this is a "
                "missing run-dependency soname, i.e. a recipe gap, not a "
                f"flake. stderr: {result.stderr.strip()!r}"
            )
        if expect_substring not in result.stdout:
            raise PackageCheckError(
                f"installed mtest {flag} exited 0 but its stdout did not "
                f"contain {expect_substring!r}: {result.stdout!r}"
            )
        performed.append(flag)

    config_path = LOADER_PROBE_CWD / "mtest.toml"
    config_path.write_text(
        '[run]\nstate = false\n[report]\ncolor = "never"\n',
        encoding="utf-8",
    )
    print(
        f"$ {scrubbed_prefix} <installed mtest> "
        "--config mtest.toml definitely-missing.mojo",
        flush=True,
    )
    configured = subprocess.run(
        [
            str(mtest_bin),
            "--config",
            "mtest.toml",
            "definitely-missing.mojo",
        ],
        cwd=LOADER_PROBE_CWD,
        env=scrubbed_env,
        capture_output=True,
        text=True,
        timeout=PROBE_TIMEOUT,
        check=False,
    )
    if configured.returncode != 4 or not configured.stderr.startswith("discover:"):
        raise PackageCheckError(
            "installed config-present invocation did not parse natively before "
            f"the expected discovery refusal: exit "
            f"{configured.returncode}, stdout={configured.stdout!r}, "
            f"stderr={configured.stderr!r}"
        )
    performed.append("--config")

    verify_loader_probe_roster(tuple(performed))
    print(
        f"package-check: OK -- installed mtest {', '.join(performed)} ran with "
        "the dev pixi env absent from PATH and "
        f"{', '.join(target.loader_env_names)} empty",
        flush=True,
    )
    record_completed_stage("loader-clean")


def stage_suite_run_with_installed_binary(mtest_bin: Path) -> None:
    """Stage 4: run focused dogfood probes through the INSTALLED binary.

    The environment is fully inherited (unlike stage 3) so probe compiler
    children can resolve `mojo` on PATH.

    Reuses dogfood's membership-and-completeness gate, which
    itself defaults to build/mtest for `pixi run dogfood-check` -- here it is
    parameterized onto the installed binary instead.

    Args:
        mtest_bin: The installed binary to drive the probes with.

    Raises:
        PackageCheckError: A build input is missing or the probes were not
            all selected and green.
    """
    _banner("stage 4/6 -- toolchain-threaded suite run with the INSTALLED binary")
    if not MOJOPKG_INCLUDE_DIR.joinpath("mtest.mojopkg").is_file():
        raise PackageCheckError(
            f"{MOJOPKG_INCLUDE_DIR / 'mtest.mojopkg'} missing -- run `pixi run build` "
            "(the package-check pixi task depends on it)"
        )
    if not NATIVE_TEST_OBJECT.is_file():
        raise PackageCheckError(
            f"{NATIVE_TEST_OBJECT} missing -- run `pixi run build-native` "
            "(the package-check pixi task depends on it)"
        )

    code = dogfood.verify(
        str(mtest_bin),
        str(NATIVE_TEST_OBJECT),
    )
    if code != 0:
        raise PackageCheckError(
            "the installed binary did not drive the dogfood probes green "
            "(see dogfood output above)"
        )
    record_completed_stage("dogfood")


def check_failing_fixture_consumption(
    returncode: int, stdout: str, version: str
) -> None:
    """Judge one installed-binary run against the known-failing fixture.

    Separated from the run itself so every rejection this gate must make can be
    exercised against a recorded transcript. Each guard names one property: the
    transcript came from this package's binary; the process exited exactly 1;
    the fixture got exactly one FAIL verdict row; no file was reported PASS; no
    other file was reported at all; the summary carries the fixture's one
    failure and its two passing tests; and nothing was left unrun.

    Args:
        returncode: Exit status the installed binary returned.
        stdout: Everything the installed binary wrote to stdout.
        version: The version the installed package must identify itself as.

    Raises:
        PackageCheckError: Any of those properties does not hold.
    """
    banner = stdout.splitlines()[0] if stdout else ""
    expected_banner = f"mtest {version} (mojo)"
    if banner != expected_banner:
        raise PackageCheckError(
            f"the failing-fixture run was not produced by the installed "
            f"{version} package: expected first line {expected_banner!r}, "
            f"got {banner!r}"
        )
    if returncode != 1:
        raise PackageCheckError(
            f"installed mtest exited {returncode} for {FAILING_FIXTURE}; a "
            "reported failure must exit exactly 1"
        )

    rows = [
        (match.group("token"), match.group("path"))
        for match in VERDICT_ROW_RE.finditer(stdout)
    ]
    # S105 exempt: a console-band verdict token, never a credential.
    pass_rows = [path for token, path in rows if token == "PASS"]  # noqa: S105
    if pass_rows:
        raise PackageCheckError(
            "installed mtest reported a PASS verdict row while consuming the "
            f"known-failing fixture: {pass_rows}"
        )
    # S105 exempt: a console-band verdict token, never a credential.
    fail_rows = [path for token, path in rows if token == "FAIL"]  # noqa: S105
    if fail_rows != [FAILING_FIXTURE]:
        raise PackageCheckError(
            f"installed mtest did not report exactly one FAIL row for "
            f"{FAILING_FIXTURE}: FAIL rows were {fail_rows}"
        )
    foreign_rows = [(token, path) for token, path in rows if path != FAILING_FIXTURE]
    if foreign_rows:
        raise PackageCheckError(
            f"installed mtest reported verdict rows for files other than "
            f"{FAILING_FIXTURE}: {foreign_rows}"
        )

    match = SUMMARY_RE.search(stdout)
    if match is None:
        raise PackageCheckError(
            "installed mtest printed no summary band while consuming "
            f"{FAILING_FIXTURE}: {stdout!r}"
        )
    failed = int(match.group("failed"))
    if failed != FAILING_FIXTURE_FAILED:
        raise PackageCheckError(
            f"installed mtest summarized {failed} failed for {FAILING_FIXTURE}; "
            f"the fixture has exactly {FAILING_FIXTURE_FAILED}"
        )
    passed = int(match.group("passed"))
    if passed != FAILING_FIXTURE_PASSED:
        raise PackageCheckError(
            f"installed mtest summarized {passed} passed for {FAILING_FIXTURE}; "
            f"the fixture's other {FAILING_FIXTURE_PASSED} tests must still be "
            "reported passing"
        )
    not_run = int(match.group("not_run"))
    if not_run != 0:
        raise PackageCheckError(
            f"installed mtest left {not_run} files not run while consuming "
            f"{FAILING_FIXTURE}; the failure evidence must come from a file "
            "that actually ran"
        )


def stage_failing_fixture_consumption(mtest_bin: Path, version: str) -> None:
    """Stage 5: drive the known-failing fixture through the INSTALLED binary.

    Stage 4 proves the package can report success. This stage proves it reports
    FAILURE truthfully, which is the half a consuming CI actually depends on.
    The environment is inherited (as in stage 4) so the fixture's compiler child
    can resolve `mojo`; project configuration is disabled so the verdict comes
    from the fixture alone.

    Args:
        mtest_bin: The installed binary to run.
        version: The version the installed package must identify itself as.

    Raises:
        PackageCheckError: The run did not produce truthful failure evidence.
    """
    _banner("stage 5/6 -- known-failing fixture through the INSTALLED binary")
    argv = [
        str(mtest_bin),
        "--no-config",
        "--color",
        "never",
        FAILING_FIXTURE,
    ]
    print(f"$ {' '.join(argv)}", flush=True)
    try:
        result = subprocess.run(
            argv,
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=FIXTURE_TIMEOUT,
            check=False,
        )
    except FileNotFoundError as exc:
        raise PackageCheckError(f"could not execute {mtest_bin}: {exc}") from exc
    except subprocess.TimeoutExpired as exc:
        raise PackageCheckError(
            f"installed mtest did not finish {FAILING_FIXTURE} within "
            f"{FIXTURE_TIMEOUT:.0f}s"
        ) from exc
    print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr, flush=True)

    check_failing_fixture_consumption(result.returncode, result.stdout, version)
    print(
        f"package-check: OK -- the installed binary failed {FAILING_FIXTURE} "
        "with exit 1, one FAIL row, and no PASS row",
        flush=True,
    )
    record_completed_stage("failing-fixture")


def stage_tarball_fallback_smoke(target: PackagePlatform | None = None) -> None:
    """Stage 6: smoke-run the classic tar-bz2 package format.

    Builds the SAME recipe into its own local channel, installs it into a second
    scratch env, runs `--version`, and repeats the source and README assertion
    proofs.

    Args:
        target: Platform descriptor to build for; the host's when omitted.

    Raises:
        PackageCheckError: The fallback form did not build, install, or run.
    """
    resolved = host_platform() if target is None else target
    _banner("stage 6/6 -- tarball fallback smoke-run")
    if TARBALL_CHANNEL_DIR.exists():
        shutil.rmtree(TARBALL_CHANNEL_DIR)

    argv = [
        "rattler-build",
        "build",
        "--recipe",
        str(RECIPE_PATH),
        "-c",
        MODULAR_CHANNEL,
        "-c",
        CONDA_FORGE_CHANNEL,
        "--output-dir",
        str(TARBALL_CHANNEL_DIR),
        "--package-format",
        "tar-bz2",
        "--test",
        "skip",
    ]
    code = _run_streamed(argv, cwd=REPO_ROOT, timeout=BUILD_TIMEOUT)
    if code != 0:
        raise PackageCheckError(f"tar-bz2 `rattler-build build` exited {code}")

    version = repo_version()
    artifact = sole_built_artifact(TARBALL_CHANNEL_DIR, version, resolved, ".tar.bz2")
    print(
        f"package-check: built tarball form {artifact.path.relative_to(REPO_ROOT)} "
        f"(build {artifact.build_string}, sha256 {artifact.sha256})",
        flush=True,
    )

    manifest = _write_scratch_manifest(TARBALL_ENV_DIR, TARBALL_CHANNEL_DIR, artifact)
    code = _run_streamed(
        ["pixi", "install", "--manifest-path", str(manifest)],
        cwd=TARBALL_ENV_DIR,
        timeout=INSTALL_TIMEOUT,
    )
    if code != 0:
        raise PackageCheckError(f"`pixi install` (tarball-env) exited {code}")

    env_prefix = TARBALL_ENV_DIR / ".pixi" / "envs" / "default"
    mtest_bin = env_prefix / "bin" / "mtest"
    if not mtest_bin.is_file():
        raise PackageCheckError(
            f"tarball-installed env has no bin/mtest at {mtest_bin}"
        )

    verify_installed_artifact_identity(env_prefix, artifact)

    print(
        f"$ {mtest_bin} --version (tarball-installed, full inherited env)", flush=True
    )
    result = subprocess.run(
        [str(mtest_bin), "--version"],
        cwd=TARBALL_ENV_DIR,
        capture_output=True,
        text=True,
        timeout=SMOKE_TIMEOUT,
        check=False,
    )
    print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr, flush=True)
    expected = f"mtest {version}"
    if result.returncode != 0 or expected not in result.stdout:
        raise PackageCheckError(
            f"tarball-installed mtest --version exited {result.returncode} "
            f"(expected 0 and {expected!r} in stdout): {result.stdout!r}"
        )

    stage_assertion_source_probe(
        mtest_bin.parents[1],
        "tarball",
        completion_id="tarball-assertion-source",
    )
    stage_assertion_example(
        mtest_bin.parents[1],
        mtest_bin,
        allow_installer_group_write=True,
        completion_id="tarball-assertion-example",
    )

    print(
        "package-check: OK -- tar-bz2 fallback form installed and ran "
        f"{expected!r} cleanly",
        flush=True,
    )
    record_completed_stage("tarball")


def main() -> int:
    """Run every stage of the packaged-artifact gate for this host.

    Returns:
        0 when every stage passed, 1 when any stage stopped the gate.
    """
    reset_completed_stages()
    try:
        target = host_platform()
        print(
            f"package-check: gating {target.subdir} "
            f"({sys.platform}/{platform.machine()})",
            flush=True,
        )
        artifact = stage_build_local_channel(target)
        mtest_bin = stage_install_from_local_channel(artifact)
        stage_loader_clean_probe(mtest_bin, target)
        stage_assertion_source_probe(
            mtest_bin.parents[1],
            "conda",
            completion_id="assertion-source",
        )
        stage_assertion_example(
            mtest_bin.parents[1],
            mtest_bin,
            completion_id="assertion-example",
        )
        stage_suite_run_with_installed_binary(mtest_bin)
        stage_failing_fixture_consumption(mtest_bin, artifact.version)
        stage_tarball_fallback_smoke(target)
        verify_every_stage_ran()
    except PackageCheckError as exc:
        print(f"FATAL: package-check: {exc}", file=sys.stderr)
        return 1

    print(
        f"\npackage-check: OK ({target.subdir}) -- built, installed from the "
        "local channel as the exact artifact this run produced (Mojo run "
        "dependency confirmed), loader-clean on the installed binary, "
        "both package forms compiled the isolated assertion source, installed "
        "binary passed the focused dogfood probes and reported the known-failing "
        "fixture as a failure, and the tar-bz2 fallback form installed and ran "
        "cleanly. Nothing uploaded or published.\n"
        f"package-check: stages performed: {list(completed_stages())}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
