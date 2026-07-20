#!/usr/bin/env python3
"""The packaged-artifact consumption GATE.

`recipe/recipe.yaml` builds mtest into a LOCAL conda channel with a
`mojo-compiler ==1.0.0b2` run dependency (see `pixi run package-build`). That
proves the recipe *solves*; it does not prove the artifact it produces is
actually consumable by someone who only has the package, not this repo's dev
toolchain. This script is that proof, run in five ordered stages:

  1. Build the package into a LOCAL channel (`pixi run package-build`,
     unmodified -- this script reuses that exact task rather than duplicating
     its command). No network beyond the solve; nothing is uploaded.
  2. Install the built `.conda` into a FRESH scratch pixi env, solving from the
     LOCAL channel plus the modular + conda-forge channels (needed to resolve
     the `mojo-compiler` run dependency). Confirms the solve actually pulled
     `mojo-compiler ==1.0.0b2`.
  3. LOADER-CLEAN PROBE FIRST, on the INSTALLED binary: run `mtest --version`
     and `mtest --help` with THIS PROCESS's own child environment scrubbed --
     the dev pixi env absent from PATH, LD_LIBRARY_PATH empty. This is us
     scrubbing our own env for our own artifact, not the forbidden
     child-process env scrub inside the product. The raw dev build
     (`build/mtest`) is NOT loader-clean this way: it needs
     `libKGENCompilerRTShared.so` from the Mojo runtime, which the dev pixi env
     supplies but a scrubbed env does not. The INSTALLED package must be
     loader-clean purely via the `mojo-compiler` run dependency.
     A soname failure here is a recipe run-dependency gap, not a retry-able
     flake -- this script stops and reports it.
  4. Toolchain-threaded dogfood run: three focused executable probes, run
     through the INSTALLED binary (never `build/mtest`). Unlike stage 3, this
     stage does NOT scrub the environment -- the probes' compiler children need
     `mojo` on PATH. Reuses self_host_check's exact-membership gate,
     parameterized onto the installed binary.
  5. Tarball fallback smoke-run: build the SAME recipe in the classic tar-bz2
     package format into its own local channel, install it into a second
     scratch env, and run `--version` -- proving the fallback distribution
     form is installable and runnable too, not just the primary `.conda` form.

The scratch envs live under build/ (gitignored); nothing here uploads,
publishes, or authenticates anywhere. `mojo run` never appears -- every binary
is BUILT then EXECUTED directly.

Usage:  pixi run package-check
        python -m scripts.package_check
"""

from __future__ import annotations

import glob
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from scripts import self_host_check

REPO_ROOT = Path(__file__).resolve().parent.parent
PIXI_TOML = REPO_ROOT / "pixi.toml"
RECIPE_PATH = REPO_ROOT / "recipe" / "recipe.yaml"

# Where `pixi run package-build` (invoked unmodified by stage 1) writes the
# primary `.conda` local channel -- must match that task's `--output-dir` in
# pixi.toml exactly, since stage 2 solves against it.
CONDA_CHANNEL_DIR = REPO_ROOT / "build" / "conda-channel"
# This script's own local channel for the tar-bz2 fallback form (stage 5) --
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

# linux-64 is the one gated platform (pixi.toml, recipe.yaml): the only
# platform a CI runner here builds or executes.
GATE_PLATFORM = "linux-64"
MODULAR_CHANNEL = "https://conda.modular.com/max/"
CONDA_FORGE_CHANNEL = "conda-forge"

# Artifacts stage 4 needs from THIS repo checkout (not from the isolated
# rattler-build sandbox): the precompiled package the probes import against,
# and the test-variant native object linked into each probe build -- the exact
# pair scripts/self_host_check.py uses for `pixi run test`.
MOJOPKG_INCLUDE_DIR = REPO_ROOT / "build"
NATIVE_TEST_OBJECT = REPO_ROOT / "build" / "native" / "mtest_exec_native_test.o"

PIXI_VERSION_RE = re.compile(r'(?m)^version = "([^"]*)"')

BUILD_TIMEOUT = 600.0
INSTALL_TIMEOUT = 300.0
PROBE_TIMEOUT = 30.0
SMOKE_TIMEOUT = 60.0


class PackageCheckError(RuntimeError):
    """A stage failed and the gate must stop -- never papered over."""


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
    """Run `argv`, letting stdout/stderr pass straight through to ours (so the
    transcript is visible live), with a hard wall-clock ceiling.

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


def stage_build_local_channel() -> Path:
    """Stage 1: build the recipe into the LOCAL channel via the unmodified
    `package-build` pixi task. Wipes any prior channel dir first so this run's
    artifact can never be mistaken for a stale one.
    """
    _banner("stage 1/5 -- build the package into a LOCAL channel")
    if CONDA_CHANNEL_DIR.exists():
        shutil.rmtree(CONDA_CHANNEL_DIR)

    code = _run_streamed(["pixi", "run", "package-build"], cwd=REPO_ROOT, timeout=BUILD_TIMEOUT)
    if code != 0:
        raise PackageCheckError(f"`pixi run package-build` exited {code}")

    version = repo_version()
    matches = sorted(
        glob.glob(str(CONDA_CHANNEL_DIR / "linux-64" / f"mtest-{version}-*.conda"))
    )
    if not matches:
        raise PackageCheckError(
            f"no mtest-{version}-*.conda artifact under "
            f"{CONDA_CHANNEL_DIR / 'linux-64'} after package-build"
        )
    artifact = Path(matches[0])
    print(f"package-check: built {artifact.relative_to(REPO_ROOT)}", flush=True)
    return artifact


def _write_scratch_manifest(env_dir: Path, channel_dir: Path, version: str) -> Path:
    """Write a throwaway pixi workspace manifest solving `mtest ==<version>`
    from `channel_dir` (a local conda channel produced by rattler-build) plus
    the modular + conda-forge channels for the `mojo-compiler` run dep.
    """
    env_dir.mkdir(parents=True, exist_ok=True)
    manifest = env_dir / "pixi.toml"
    manifest.write_text(
        "[workspace]\n"
        f'name = "{env_dir.name}"\n'
        'version = "0.0.0"\n'
        "channels = [\n"
        f'  "file://{channel_dir}",\n'
        f'  "{MODULAR_CHANNEL}",\n'
        f'  "{CONDA_FORGE_CHANNEL}",\n'
        "]\n"
        f'platforms = ["{GATE_PLATFORM}"]\n'
        "\n"
        "[dependencies]\n"
        f'mtest = "=={version}"\n',
        encoding="utf-8",
    )
    return manifest


def stage_install_from_local_channel() -> Path:
    """Stage 2: install the just-built package into a FRESH scratch pixi env
    solving from CONDA_CHANNEL_DIR (+ modular/conda-forge), then confirm the
    solve actually pulled `mojo-compiler ==1.0.0b2` as a run dependency.

    Returns the absolute path to the installed `mtest` binary.
    """
    _banner("stage 2/5 -- install into a fresh scratch env from the LOCAL channel")
    if SCRATCH_ROOT.exists():
        shutil.rmtree(SCRATCH_ROOT)

    version = repo_version()
    manifest = _write_scratch_manifest(CONDA_ENV_DIR, CONDA_CHANNEL_DIR, version)

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

    conda_meta = sorted((env_prefix / "conda-meta").glob("mojo-compiler-1.0.0b2-*.json"))
    if not conda_meta:
        raise PackageCheckError(
            "install did NOT pull mojo-compiler ==1.0.0b2 as a run dependency -- "
            f"no mojo-compiler-1.0.0b2-*.json under {env_prefix / 'conda-meta'}; "
            "this is a recipe run-dependency gap"
        )
    print(
        f"package-check: installed {mtest_bin.relative_to(REPO_ROOT)}; "
        f"run dep confirmed: {conda_meta[0].name}",
        flush=True,
    )
    return mtest_bin


def stage_loader_clean_probe(mtest_bin: Path) -> None:
    """Stage 3: run the INSTALLED binary's `--version` and `--help` with our
    own child environment scrubbed clean of the dev pixi env (PATH) and any
    LD_LIBRARY_PATH.

    This is us scrubbing OUR OWN subprocess environment to probe OUR OWN
    artifact -- not the forbidden child-env scrub inside the product itself.
    If the binary can only load with the dev toolchain on PATH, the recipe's
    `mojo-compiler` run dependency is not actually sufficient, and that is a
    packaging gap this script must stop and report, not paper over.
    """
    _banner("stage 3/5 -- LOADER-CLEAN PROBE on the installed binary")
    LOADER_PROBE_CWD.mkdir(parents=True, exist_ok=True)

    scrubbed_env = {
        "PATH": "/usr/bin:/bin",
        "HOME": os.environ.get("HOME", "/root"),
        "LD_LIBRARY_PATH": "",
    }

    ldd = subprocess.run(
        ["ldd", str(mtest_bin)],
        cwd=LOADER_PROBE_CWD,
        env=scrubbed_env,
        capture_output=True,
        text=True,
        timeout=PROBE_TIMEOUT,
    )
    print("$ ldd <installed mtest> (scrubbed env)", flush=True)
    print(ldd.stdout, end="", flush=True)
    if ldd.stderr:
        print(ldd.stderr, end="", file=sys.stderr, flush=True)

    version = repo_version()
    expected_version_line = f"mtest {version}"

    for flag, expect_substring in (
        ("--version", expected_version_line),
        ("--help", "usage: mtest"),
    ):
        print(f"$ env -i PATH=/usr/bin:/bin LD_LIBRARY_PATH= <installed mtest> {flag}", flush=True)
        result = subprocess.run(
            [str(mtest_bin), flag],
            cwd=LOADER_PROBE_CWD,
            env=scrubbed_env,
            capture_output=True,
            text=True,
            timeout=PROBE_TIMEOUT,
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

    print(
        "package-check: OK -- installed mtest --version/--help both ran clean "
        "with the dev pixi env absent from PATH and LD_LIBRARY_PATH empty",
        flush=True,
    )


def stage_suite_run_with_installed_binary(mtest_bin: Path) -> None:
    """Stage 4: run focused dogfood probes through the INSTALLED binary.

    The environment is fully inherited (unlike stage 3) so probe compiler
    children can resolve `mojo` on PATH.

    Reuses self_host_check's dogfood-and-verify-completeness gate, which
    itself defaults to build/mtest for `pixi run test` -- here it is
    parameterized onto the installed binary instead.
    """
    _banner("stage 4/5 -- toolchain-threaded suite run with the INSTALLED binary")
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

    code = self_host_check.verify(
        str(mtest_bin),
        str(NATIVE_TEST_OBJECT),
    )
    if code != 0:
        raise PackageCheckError(
            "the installed binary did not drive the dogfood probes green "
            "(see self_host_check output above)"
        )


def stage_tarball_fallback_smoke() -> None:
    """Stage 5: build the SAME recipe in the classic tar-bz2 package format
    into its own local channel, install it into a second scratch env, and run
    `--version` -- the fallback distribution form must work too.
    """
    _banner("stage 5/5 -- tarball fallback smoke-run")
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
    matches = sorted(
        glob.glob(str(TARBALL_CHANNEL_DIR / "linux-64" / f"mtest-{version}-*.tar.bz2"))
    )
    if not matches:
        raise PackageCheckError(
            f"no mtest-{version}-*.tar.bz2 artifact under "
            f"{TARBALL_CHANNEL_DIR / 'linux-64'} after the tar-bz2 build"
        )
    artifact = Path(matches[0])
    print(f"package-check: built tarball form {artifact.relative_to(REPO_ROOT)}", flush=True)

    manifest = _write_scratch_manifest(TARBALL_ENV_DIR, TARBALL_CHANNEL_DIR, version)
    code = _run_streamed(
        ["pixi", "install", "--manifest-path", str(manifest)],
        cwd=TARBALL_ENV_DIR,
        timeout=INSTALL_TIMEOUT,
    )
    if code != 0:
        raise PackageCheckError(f"`pixi install` (tarball-env) exited {code}")

    mtest_bin = TARBALL_ENV_DIR / ".pixi" / "envs" / "default" / "bin" / "mtest"
    if not mtest_bin.is_file():
        raise PackageCheckError(f"tarball-installed env has no bin/mtest at {mtest_bin}")

    print(f"$ {mtest_bin} --version (tarball-installed, full inherited env)", flush=True)
    result = subprocess.run(
        [str(mtest_bin), "--version"],
        cwd=TARBALL_ENV_DIR,
        capture_output=True,
        text=True,
        timeout=SMOKE_TIMEOUT,
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

    print(
        "package-check: OK -- tar-bz2 fallback form installed and ran "
        f"{expected!r} cleanly",
        flush=True,
    )


def main() -> int:
    try:
        stage_build_local_channel()
        mtest_bin = stage_install_from_local_channel()
        stage_loader_clean_probe(mtest_bin)
        stage_suite_run_with_installed_binary(mtest_bin)
        stage_tarball_fallback_smoke()
    except PackageCheckError as exc:
        print(f"FATAL: package-check: {exc}", file=sys.stderr)
        return 1

    print(
        "\npackage-check: OK -- built, installed from the local channel "
        "(mojo-compiler run dep confirmed), loader-clean on the installed "
        "binary, installed binary passed the focused dogfood probes, and the "
        "tar-bz2 fallback form installed and ran cleanly. Nothing uploaded "
        "or published.",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
