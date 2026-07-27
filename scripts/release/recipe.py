#!/usr/bin/env python3
"""Render, attest, verify, and stage the modular-community recipe."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import shutil
import stat
import sys
from typing import NoReturn


REPO_ROOT = Path(__file__).resolve().parents[2]
VERSION_RE = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
DIGEST_RE = re.compile(r"[0-9a-f]{64}\Z")
TOKEN_RE = re.compile(rb"@@MTEST_[A-Z0-9_]+@@")
TOKENS = {
    b"@@MTEST_VERSION@@",
    b"@@MTEST_SOURCE_REV@@",
    b"@@MTEST_BUILD_NUMBER@@",
}
RECIPE_FILES = ("recipe.yaml", "test_smoke.mojo")


@dataclass(frozen=True)
class RenderRequest:
    """Values substituted into the reviewed community recipe template."""

    version: str
    source_rev: str
    build_number: int


@dataclass(frozen=True, order=True)
class ManifestEntry:
    """One canonical relative path and its content digest."""

    path: str
    sha256: str


def _validate_request(request: RenderRequest) -> None:
    if VERSION_RE.fullmatch(request.version) is None:
        raise ValueError(f"invalid version: {request.version!r}")
    if SHA_RE.fullmatch(request.source_rev) is None:
        raise ValueError(f"invalid source revision: {request.source_rev!r}")
    build_number: object = request.build_number
    if (
        isinstance(build_number, bool)
        or not isinstance(build_number, int)
        or build_number < 0
    ):
        raise ValueError(f"invalid build number: {build_number!r}")


def render_recipe(template: bytes, request: RenderRequest) -> bytes:
    """Render each closed-vocabulary token exactly once."""
    _validate_request(request)
    found = TOKEN_RE.findall(template)
    if set(found) != TOKENS or any(found.count(token) != 1 for token in TOKENS):
        raise ValueError(
            "recipe token membership/count mismatch: "
            f"expected={sorted(TOKENS)}, actual={sorted(found)}"
        )
    replacements = {
        b"@@MTEST_VERSION@@": request.version.encode("ascii"),
        b"@@MTEST_SOURCE_REV@@": request.source_rev.encode("ascii"),
        b"@@MTEST_BUILD_NUMBER@@": str(request.build_number).encode("ascii"),
    }
    rendered = template
    for token, value in replacements.items():
        rendered = rendered.replace(token, value)
    if TOKEN_RE.search(rendered) is not None:
        raise ValueError("rendered recipe contains an unresolved token")
    return rendered.rstrip(b"\r\n") + b"\n"


def _regular_file(path: Path) -> bool:
    return stat.S_ISREG(path.stat(follow_symlinks=False).st_mode)


def build_manifest(root: Path) -> tuple[ManifestEntry, ...]:
    """Hash the exact two-file rendered recipe tree."""
    if not root.is_dir() or root.is_symlink():
        raise ValueError(f"recipe root is not a regular directory: {root}")
    children = tuple(root.iterdir())
    actual = {path.name for path in children}
    if actual != set(RECIPE_FILES):
        raise ValueError(
            "recipe root must contain exactly "
            f"{list(RECIPE_FILES)!r}; actual={sorted(actual)!r}"
        )
    entries: list[ManifestEntry] = []
    for path in children:
        if path.is_symlink() or not _regular_file(path):
            raise ValueError(f"recipe entry must be a regular non-link file: {path}")
        entries.append(
            ManifestEntry(
                path=path.name,
                sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
            )
        )
    return tuple(sorted(entries, key=lambda item: item.path.encode("utf-8")))


def manifest_bytes(entries: tuple[ManifestEntry, ...]) -> bytes:
    """Encode manifest entries as canonical JSON."""
    return (
        json.dumps(
            [{"path": item.path, "sha256": item.sha256} for item in entries],
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        + b"\n"
    )


def directory_digest(entries: tuple[ManifestEntry, ...]) -> str:
    """Hash the exact canonical manifest bytes."""
    return hashlib.sha256(manifest_bytes(entries)).hexdigest()


def write_manifest(path: Path, entries: tuple[ManifestEntry, ...]) -> str:
    """Write one canonical manifest and return its digest."""
    encoded = manifest_bytes(entries)
    path.write_bytes(encoded)
    return hashlib.sha256(encoded).hexdigest()


def _parse_manifest(encoded: bytes) -> tuple[ManifestEntry, ...]:
    try:
        document = json.loads(encoded)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid manifest JSON: {exc}") from exc
    if not isinstance(document, list):
        raise ValueError("manifest root must be a list")
    entries: list[ManifestEntry] = []
    for item in document:
        if not isinstance(item, dict) or set(item) != {"path", "sha256"}:
            raise ValueError("manifest entries require exactly path and sha256")
        path = item["path"]
        digest = item["sha256"]
        if (
            not isinstance(path, str)
            or path not in RECIPE_FILES
            or Path(path).is_absolute()
            or "/" in path
            or "\\" in path
            or ".." in Path(path).parts
        ):
            raise ValueError(f"invalid manifest path: {path!r}")
        if not isinstance(digest, str) or DIGEST_RE.fullmatch(digest) is None:
            raise ValueError(f"invalid manifest digest for {path!r}")
        entries.append(ManifestEntry(path=path, sha256=digest))
    result = tuple(entries)
    if result != tuple(sorted(result, key=lambda item: item.path.encode("utf-8"))):
        raise ValueError("manifest entries are not byte-sorted")
    if {item.path for item in result} != set(RECIPE_FILES):
        raise ValueError("manifest file membership mismatch")
    if len(result) != len(RECIPE_FILES):
        raise ValueError("manifest contains duplicate paths")
    if manifest_bytes(result) != encoded:
        raise ValueError("manifest is not canonical JSON")
    return result


def verify_manifest(root: Path, manifest: bytes, expected_digest: str) -> None:
    """Verify manifest bytes, caller digest, and rendered directory bytes."""
    if DIGEST_RE.fullmatch(expected_digest) is None:
        raise ValueError(f"invalid expected manifest digest: {expected_digest!r}")
    actual_digest = hashlib.sha256(manifest).hexdigest()
    if actual_digest != expected_digest:
        raise ValueError(
            "manifest digest mismatch: "
            f"expected={expected_digest}, actual={actual_digest}"
        )
    expected_entries = _parse_manifest(manifest)
    actual_entries = build_manifest(root)
    if actual_entries != expected_entries:
        raise ValueError(
            "rendered recipe differs from manifest: "
            f"expected={expected_entries!r}, actual={actual_entries!r}"
        )


def stage_recipe(source: Path, destination: Path) -> None:
    """Replace an upstream checkout's recipe roster with the rendered mtest recipe."""
    build_manifest(source)
    if destination.is_symlink() or not destination.is_dir():
        raise ValueError(f"upstream checkout is not a regular directory: {destination}")
    checkout = destination.resolve(strict=True)
    recipes = destination / "recipes"
    if recipes.is_symlink():
        raise ValueError("upstream recipes boundary must not be a link")
    if recipes.exists():
        resolved_recipes = recipes.resolve(strict=True)
        if resolved_recipes.parent != checkout:
            raise ValueError("upstream recipes boundary escapes the checkout")
        if not resolved_recipes.is_dir():
            raise ValueError("upstream recipes boundary is not a directory")
        shutil.rmtree(resolved_recipes)
    recipes.mkdir()
    target = recipes / "mtest"
    target.mkdir()
    for name in RECIPE_FILES:
        shutil.copy2(source / name, target / name, follow_symlinks=False)


def _fail(message: str) -> NoReturn:
    raise ValueError(message)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    render = commands.add_parser("render")
    render.add_argument("--version", required=True)
    render.add_argument("--source-rev", required=True)
    render.add_argument("--build-number", required=True)
    render.add_argument("--output", type=Path, required=True)

    verify = commands.add_parser("verify-manifest")
    verify.add_argument("--root", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--expected-digest", required=True)

    stage = commands.add_parser("stage")
    stage.add_argument("--source", type=Path, required=True)
    stage.add_argument("--upstream-checkout", type=Path, required=True)
    return parser


def _parse_build_number(raw: str) -> int:
    if re.fullmatch(r"(?:0|[1-9][0-9]*)", raw) is None:
        _fail(f"invalid build number: {raw!r}")
    return int(raw)


def main(argv: list[str] | None = None) -> int:
    """Run a recipe rendering, verification, or staging command."""
    args = _parser().parse_args(argv)
    try:
        if args.command == "render":
            output: Path = args.output
            if output.exists():
                if output.is_symlink() or not output.is_dir() or any(output.iterdir()):
                    _fail(f"render output must be an empty regular directory: {output}")
            else:
                output.mkdir(parents=True)
            request = RenderRequest(
                version=args.version,
                source_rev=args.source_rev,
                build_number=_parse_build_number(args.build_number),
            )
            template = REPO_ROOT / "recipe" / "community" / "recipe.yaml.in"
            smoke = REPO_ROOT / "recipe" / "community" / "test_smoke.mojo"
            (output / "recipe.yaml").write_bytes(
                render_recipe(template.read_bytes(), request)
            )
            shutil.copy2(smoke, output / "test_smoke.mojo")
            entries = build_manifest(output)
            manifest_path = output.parent.parent / "manifest.json"
            digest = write_manifest(manifest_path, entries)
            print(digest)
        elif args.command == "verify-manifest":
            verify_manifest(
                args.root,
                args.manifest.read_bytes(),
                args.expected_digest,
            )
        elif args.command == "stage":
            stage_recipe(args.source, args.upstream_checkout)
        else:
            _fail(f"unknown command: {args.command!r}")
    except (OSError, ValueError) as exc:
        print(f"community-recipe: FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
