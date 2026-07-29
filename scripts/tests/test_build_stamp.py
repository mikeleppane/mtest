#!/usr/bin/env python3
"""Layer 2 of the build-artifact cache: stamp mtest's OWN precompile stage.

`scripts/build/production_build.sh`'s `stage_precompile` runs `mojo precompile`
twice (the vendored TOML parser, then `src/mtest`) to produce
`build/toml.mojopkg` and `build/mtest.mojopkg`. `mojo precompile` is NOT
byte-reproducible on this toolchain: two identical inputs measured at
`43fcef41...` and `eb81d1f7...` on this branch. A naive re-run therefore
rewrites both packages with different bytes on every `pixi run build`, changed
or not. This module pins the `in:`/`out:` stamp that lets a second, unchanged
run skip the stage.

Every scenario copies exactly the subset the stage reads (`scripts/build`,
`src/mtest`, `vendor/mojo-toml`) into a throwaway `tempfile.mkdtemp` sandbox
and runs `production_build.sh` THERE, never against this checkout's `build/`.
`test_source_order_permutation_stable` additionally `source`s the script so it
can call the digest/stamp helpers directly, skipping the stage dispatch at the
bottom of the file.

`test_double_build_leaves_identical_package_bytes` is the nondeterminism proof
and is RED before the stamp exists. It goes green once the second run SKIPS
the stage; the compiler itself is still nondeterministic.

`test_toolchain_change_forces_rebuild` pins toolchain identity: the input
digest also covers `mojo --version` and `pixi.lock`'s bytes, so a toolchain
swap invalidates a stamp no tracked source file's content would otherwise
touch.
"""

from __future__ import annotations

import contextlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
from typing import TYPE_CHECKING
import unittest


if TYPE_CHECKING:
    from collections.abc import Iterator


REPO = Path(__file__).resolve().parents[2]
"""This repository's root, derived from this file's own nested location."""

STAGE_SCRIPT_REL = "scripts/build/production_build.sh"
"""The script under test, relative to a sandbox root (mirrors the real tree)."""

SANDBOX_TREE_DIRS = ("scripts/build", "src/mtest", "vendor/mojo-toml")
"""Every directory `stage_precompile` reads."""

SANDBOX_TREE_FILES = ("pixi.lock",)
"""Every standalone file `stage_precompile` reads: the lockfile that pins the
toolchain, fed into the input digest alongside `mojo --version`."""

RUN_TIMEOUT_SECONDS = 300
"""Ceiling on one `production_build.sh precompile` invocation, sized well above
a cold run. A timeout is a FAIL, never a skip."""

SKIP_LINE = "precompile stage skipped"
"""The console line `stage_precompile` prints when a valid stamp skips the
stage. Pinned so a wording change in the script fails here too."""

BYPASS_NOTICE = "no sha256sum or shasum on PATH"
"""Substring of the notice `stage_precompile` prints when neither digest tool
is available and it builds unconditionally instead of stamping."""


def require_mojo() -> None:
    """Fail closed unless a real `mojo` is on PATH.

    Raises:
        AssertionError: If `mojo` cannot be found. Every scenario except
            `test_source_order_permutation_stable` runs a real precompile, so
            these need the pixi environment activated.
    """
    if shutil.which("mojo") is None:
        raise AssertionError(
            "`mojo` is not on PATH -- these scenarios run the real "
            "precompile stage; run them under `pixi run build-stamp-check`"
        )


def sandbox_tree() -> Path:
    """A throwaway copy of exactly what `stage_precompile` reads.

    Returns:
        The sandbox root. The caller owns cleanup (`shutil.rmtree`); nothing
        under this function ever touches the real repository's `build/`.
    """
    root = Path(tempfile.mkdtemp(prefix="mtest-build-stamp-"))
    for rel in SANDBOX_TREE_DIRS:
        shutil.copytree(REPO / rel, root / rel)
    for rel in SANDBOX_TREE_FILES:
        shutil.copy2(REPO / rel, root / rel)
    return root


def run_stage(
    sandbox: Path, stage: str = "precompile", env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    """Execute `production_build.sh <stage>` for real, inside `sandbox`.

    Args:
        sandbox: A tree produced by `sandbox_tree`.
        stage: The stage argument to pass; Layer 2 only stamps `precompile`.
        env: The child's environment, or `None` to inherit this process's.

    Returns:
        The completed subprocess, with stdout/stderr captured as text.
    """
    return subprocess.run(
        ["bash", STAGE_SCRIPT_REL, stage],
        cwd=sandbox,
        env=env if env is not None else os.environ.copy(),
        capture_output=True,
        text=True,
        timeout=RUN_TIMEOUT_SECONDS,
        check=False,
    )


def source_call(sandbox: Path, snippet: str) -> subprocess.CompletedProcess[str]:
    """`source production_build.sh` in a throwaway bash, then run `snippet`.

    Sourcing skips the stage-dispatch case statement at the bottom of the
    script, so `snippet` can call the digest/stamp helpers directly without
    triggering a real build.

    Args:
        sandbox: A tree produced by `sandbox_tree`.
        snippet: Shell code to run after sourcing, sharing the sourced
            script's functions and the `build/` cwd.

    Returns:
        The completed subprocess, with stdout/stderr captured as text.
    """
    script = (
        f'set -euo pipefail\ncd "{sandbox}"\nsource {STAGE_SCRIPT_REL}\n{snippet}\n'
    )
    return subprocess.run(
        ["bash", "-c", script],
        env=os.environ.copy(),
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )


def fabricate_valid_state(sandbox: Path, mojo_version: str | None = None) -> None:
    """Write placeholder outputs and a stamp that is genuinely valid for them.

    Writes arbitrary bytes to `build/toml.mojopkg` and `build/mtest.mojopkg`
    without invoking `mojo`, then writes the stamp through the script's own
    `_precompile_input_digest` / `_precompile_write_stamp`. Every digest is
    real; only the compile is fabricated, which lets the rebuild scenarios
    start from a known-valid stamp without paying for a compile.

    Args:
        sandbox: A tree produced by `sandbox_tree`.
        mojo_version: The toolchain-identity string to feed the digest with.
            Defaults to invoking the real `mojo --version`; pass a literal to
            avoid requiring `mojo` on PATH, as
            `test_source_order_permutation_stable` does.

    Raises:
        AssertionError: If the sourced helper calls fail.
    """
    build = sandbox / "build"
    build.mkdir(exist_ok=True)
    (build / "toml.mojopkg").write_bytes(b"placeholder-toml-package\n")
    (build / "mtest.mojopkg").write_bytes(b"placeholder-mtest-package\n")
    version_stmt = (
        f"mojo_version={shlex.quote(mojo_version)}"
        if mojo_version is not None
        else 'mojo_version="$(mojo --version 2>&1)"'
    )
    result = source_call(
        sandbox,
        "_resolve_digest_cmd\n"
        f"{version_stmt}\n"
        'digest="$(_precompile_input_digest "$mojo_version")"\n'
        '_precompile_write_stamp "$PRECOMPILE_STAMP" "$digest"\n',
    )
    if result.returncode != 0:
        raise AssertionError(result.stdout + result.stderr)


def stamp_head_line(sandbox: Path, mojo_version: str | None = None) -> str:
    """Fabricate placeholder outputs, write a stamp, and return its head line.

    Args:
        sandbox: A tree produced by `sandbox_tree`.
        mojo_version: Forwarded to `fabricate_valid_state`.

    Returns:
        The stamp file's first line (`in:<input digest>`).
    """
    fabricate_valid_state(sandbox, mojo_version=mojo_version)
    stamp = sandbox / "build" / ".precompile.stamp"
    return stamp.read_text(encoding="utf-8").splitlines()[0]


def copy_files_reordered(src: Path, dst: Path) -> None:
    """Copy every file under `src` into `dst`, writing them in REVERSE sorted order.

    Args:
        src: The source directory tree to copy.
        dst: The destination root (parents created as needed).
    """
    files = sorted((p for p in src.rglob("*") if p.is_file()), reverse=True)
    for path in files:
        target = dst / path.relative_to(src)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)


@contextlib.contextmanager
def path_hiding(excluded: frozenset[str]) -> Iterator[str]:
    """A PATH value with the named executables hidden, everything else intact.

    Only the PATH directories containing one of `excluded` are rebuilt into a
    throwaway shim directory, symlinking every OTHER entry through by its real
    absolute path. That hides the requested tools even when they share a
    directory with tools the stage needs, leaving the rest of PATH untouched.

    Args:
        excluded: Executable basenames to hide from the yielded PATH.

    Yields:
        A PATH string suitable for a subprocess `env`.
    """
    dirs = os.environ.get("PATH", "").split(os.pathsep)
    shim_for: dict[str, str] = {}
    rebuilt: list[str] = []
    try:
        for directory in dirs:
            try:
                entries = set(os.listdir(directory))
            except OSError:
                rebuilt.append(directory)
                continue
            if not entries & excluded:
                rebuilt.append(directory)
                continue
            if directory not in shim_for:
                shim = tempfile.mkdtemp(prefix="mtest-path-shim-")
                for name in entries - excluded:
                    with contextlib.suppress(OSError):
                        os.symlink(
                            os.path.join(directory, name), os.path.join(shim, name)
                        )
                shim_for[directory] = shim
            rebuilt.append(shim_for[directory])
        yield os.pathsep.join(rebuilt)
    finally:
        for shim in shim_for.values():
            shutil.rmtree(shim, ignore_errors=True)


@contextlib.contextmanager
def toolchain_reporting(version_line: str) -> Iterator[str]:
    """A PATH whose `mojo --version` reports `version_line`, otherwise real.

    Simulates a toolchain upgrade without one: a shim shadows `mojo` first on
    PATH and fakes only `--version`, while every other argv `exec`s the genuine
    compiler, so the stage still builds for real under this PATH.

    Args:
        version_line: The literal line the shim's `mojo --version` prints.

    Yields:
        A PATH string suitable for a subprocess `env`.

    Raises:
        AssertionError: If no real `mojo` is on PATH to build the shim
            against.
    """
    real_mojo = shutil.which("mojo")
    if real_mojo is None:
        raise AssertionError(
            "`mojo` is not on PATH -- required to build the version shim"
        )
    shim_dir = tempfile.mkdtemp(prefix="mtest-mojo-shim-")
    shim_path = Path(shim_dir) / "mojo"
    shim_path.write_text(
        "#!/usr/bin/env bash\n"
        'if [[ "$1" == "--version" ]]; then\n'
        f"  printf '%s\\n' {shlex.quote(version_line)}\n"
        "  exit 0\n"
        "fi\n"
        f'exec {shlex.quote(real_mojo)} "$@"\n',
        encoding="utf-8",
    )
    shim_path.chmod(0o755)
    try:
        yield f"{shim_dir}{os.pathsep}{os.environ.get('PATH', '')}"
    finally:
        shutil.rmtree(shim_dir, ignore_errors=True)


def which_in_env(env: dict[str, str], *names: str) -> str:
    """Report which of `names` resolve to an executable under `env`'s PATH.

    Args:
        env: The environment to resolve PATH lookups against.
        names: Executable basenames to probe.

    Returns:
        The combined stdout of `command -v` for each name (empty lines for
        names that do not resolve).
    """
    probe = "\n".join(f"command -v {name} || true" for name in names)
    result = subprocess.run(
        ["bash", "-c", probe],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    return result.stdout


class BuildStampTests(unittest.TestCase):
    """Scenarios pinning the precompile stage's stamp against its inputs."""

    def test_double_build_leaves_identical_package_bytes(self) -> None:
        """Two back-to-back builds must leave `build/mtest.mojopkg` untouched.

        Package output is not byte-reproducible, so the only way the bytes
        can match across two builds is if the second run skipped entirely.
        """
        require_mojo()
        sandbox = sandbox_tree()
        try:
            first = run_stage(sandbox)
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            first_bytes = (sandbox / "build/mtest.mojopkg").read_bytes()

            second = run_stage(sandbox)
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            self.assertIn(SKIP_LINE, second.stdout)
            second_bytes = (sandbox / "build/mtest.mojopkg").read_bytes()

            self.assertEqual(
                first_bytes,
                second_bytes,
                "two builds produced different package bytes -- the stamp "
                "should have skipped the second, unchanged run entirely",
            )
        finally:
            shutil.rmtree(sandbox, ignore_errors=True)

    def test_deleted_output_forces_rebuild(self) -> None:
        """A missing expected output must force a real rebuild, never a skip."""
        require_mojo()
        sandbox = sandbox_tree()
        try:
            fabricate_valid_state(sandbox)
            sanity = run_stage(sandbox)
            self.assertIn(
                SKIP_LINE,
                sanity.stdout,
                "fabricated stamp was not accepted as valid -- fixture bug",
            )

            (sandbox / "build/mtest.mojopkg").unlink()
            rebuild = run_stage(sandbox)
            self.assertEqual(rebuild.returncode, 0, rebuild.stdout + rebuild.stderr)
            self.assertNotIn(SKIP_LINE, rebuild.stdout)
            self.assertIn("precompiling src/mtest", rebuild.stdout)
            self.assertTrue((sandbox / "build/mtest.mojopkg").is_file())
        finally:
            shutil.rmtree(sandbox, ignore_errors=True)

    def test_unknown_out_row_forces_rebuild(self) -> None:
        """An extra, unrecognized `out:` row must invalidate the whole stamp."""
        require_mojo()
        sandbox = sandbox_tree()
        try:
            fabricate_valid_state(sandbox)
            sanity = run_stage(sandbox)
            self.assertIn(
                SKIP_LINE,
                sanity.stdout,
                "fabricated stamp was not accepted as valid -- fixture bug",
            )

            stamp = sandbox / "build/.precompile.stamp"
            with stamp.open("a", encoding="utf-8") as handle:
                handle.write("out:build/bogus.mojopkg deadbeef\n")

            rebuild = run_stage(sandbox)
            self.assertEqual(rebuild.returncode, 0, rebuild.stdout + rebuild.stderr)
            self.assertNotIn(SKIP_LINE, rebuild.stdout)
            self.assertIn("precompiling src/mtest", rebuild.stdout)
        finally:
            shutil.rmtree(sandbox, ignore_errors=True)

    def test_source_order_permutation_stable(self) -> None:
        """The stamp's head line must not depend on filesystem creation order."""
        forward = sandbox_tree()
        reordered = Path(tempfile.mkdtemp(prefix="mtest-build-stamp-"))
        try:
            shutil.copytree(REPO / "scripts/build", reordered / "scripts/build")
            copy_files_reordered(REPO / "src/mtest", reordered / "src/mtest")
            copy_files_reordered(
                REPO / "vendor/mojo-toml", reordered / "vendor/mojo-toml"
            )
            shutil.copy2(REPO / "pixi.lock", reordered / "pixi.lock")

            # A fixed literal keeps this scenario about file-creation-order
            # stability and off `mojo` on PATH.
            fixed_version = "Mojo 0.0.0-test-source-order (fixed)"
            head_forward = stamp_head_line(forward, mojo_version=fixed_version)
            head_reordered = stamp_head_line(reordered, mojo_version=fixed_version)

            self.assertTrue(head_forward.startswith("in:"))
            self.assertEqual(head_forward, head_reordered)
        finally:
            shutil.rmtree(forward, ignore_errors=True)
            shutil.rmtree(reordered, ignore_errors=True)

    def test_toolchain_change_forces_rebuild(self) -> None:
        """A different `mojo --version` must invalidate the stamp.

        Everything except the observed toolchain identity is byte-identical
        between the two runs. Without the toolchain in the digest, an upgraded
        `mojo` reports a stamp match and `pixi run build` ships a `.mojopkg`
        compiled by the OLD compiler.
        """
        require_mojo()
        sandbox = sandbox_tree()
        try:
            with toolchain_reporting("Mojo 1.0.0b2-shim (first)") as first_path:
                env = os.environ.copy()
                env["PATH"] = first_path
                first = run_stage(sandbox, env=env)
                self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
                self.assertTrue((sandbox / "build/.precompile.stamp").is_file())

            with toolchain_reporting("Mojo 9.9.9-shim (upgraded)") as second_path:
                env = os.environ.copy()
                env["PATH"] = second_path
                rebuild = run_stage(sandbox, env=env)
                self.assertEqual(rebuild.returncode, 0, rebuild.stdout + rebuild.stderr)
                self.assertNotIn(SKIP_LINE, rebuild.stdout)
                self.assertIn("precompiling src/mtest", rebuild.stdout)
        finally:
            shutil.rmtree(sandbox, ignore_errors=True)

    def test_shasum_only_path(self) -> None:
        """Hiding `sha256sum` while leaving real `shasum` present must still stamp.

        Exercises on Linux the branch the macOS lane depends on, since macOS
        ships no `sha256sum`.
        """
        require_mojo()
        sandbox = sandbox_tree()
        try:
            with path_hiding(frozenset({"sha256sum"})) as path_value:
                env = os.environ.copy()
                env["PATH"] = path_value

                resolved = which_in_env(env, "sha256sum", "shasum")
                self.assertNotIn("sha256sum", resolved)
                self.assertIn("shasum", resolved)

                first = run_stage(sandbox, env=env)
                self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
                self.assertTrue((sandbox / "build/mtest.mojopkg").is_file())
                self.assertTrue((sandbox / "build/.precompile.stamp").is_file())

                second = run_stage(sandbox, env=env)
                self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
                self.assertIn(SKIP_LINE, second.stdout)
        finally:
            shutil.rmtree(sandbox, ignore_errors=True)

    def test_no_digest_tool_bypasses(self) -> None:
        """Hiding both digest tools must still build and exit 0.

        The stage must print the bypass notice and must not write a stamp.
        """
        require_mojo()
        sandbox = sandbox_tree()
        try:
            with path_hiding(frozenset({"sha256sum", "shasum"})) as path_value:
                env = os.environ.copy()
                env["PATH"] = path_value

                resolved = which_in_env(env, "sha256sum", "shasum")
                self.assertEqual(resolved.strip(), "")

                result = run_stage(sandbox, env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                combined = result.stdout + result.stderr
                self.assertIn(BYPASS_NOTICE, combined)
                self.assertTrue((sandbox / "build/mtest.mojopkg").is_file())
                self.assertFalse((sandbox / "build/.precompile.stamp").exists())
        finally:
            shutil.rmtree(sandbox, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
