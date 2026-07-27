#!/usr/bin/env python3
"""Behavior tests for deterministic modular-community recipe preparation."""

from __future__ import annotations

from dataclasses import replace
import json
import os
from pathlib import Path
import tempfile
import unittest

from scripts.checks.community_recipe import check_recipe_drift
from scripts.release.recipe import (
    ManifestEntry,
    RenderRequest,
    build_manifest,
    directory_digest,
    manifest_bytes,
    render_recipe,
    stage_recipe,
    verify_manifest,
    write_manifest,
)


VALID_REQUEST = RenderRequest(
    version="0.6.0",
    source_rev="0123456789abcdef0123456789abcdef01234567",
    build_number=0,
)
VALID_TEMPLATE = (
    b"version: @@MTEST_VERSION@@\n"
    b"rev: @@MTEST_SOURCE_REV@@\n"
    b"number: @@MTEST_BUILD_NUMBER@@\n"
)


class RenderRecipeTests(unittest.TestCase):
    def test_render_replaces_each_review_token_once(self) -> None:
        rendered = render_recipe(VALID_TEMPLATE, VALID_REQUEST)
        self.assertEqual(
            rendered,
            b"version: 0.6.0\n"
            b"rev: 0123456789abcdef0123456789abcdef01234567\n"
            b"number: 0\n",
        )

    def test_render_normalizes_to_one_trailing_newline(self) -> None:
        rendered = render_recipe(VALID_TEMPLATE + b"\n\n", VALID_REQUEST)
        self.assertTrue(rendered.endswith(b"\n"))
        self.assertFalse(rendered.endswith(b"\n\n"))

    def test_render_rejects_invalid_versions(self) -> None:
        for version in (
            "v1.0.0",
            "1.0",
            "1.0.0-beta",
            "01.0.0",
            "1.00.0",
            "1.0.00",
            " 1.0.0",
            "1.0.0 ",
        ):
            with (
                self.subTest(version=version),
                self.assertRaisesRegex(ValueError, "version"),
            ):
                render_recipe(
                    VALID_TEMPLATE,
                    replace(VALID_REQUEST, version=version),
                )

    def test_render_rejects_invalid_source_revisions(self) -> None:
        for source_rev in (
            "0" * 39,
            "0" * 41,
            "A" * 40,
            "g" * 40,
            " " + "0" * 40,
            "0" * 40 + " ",
        ):
            with (
                self.subTest(source_rev=source_rev),
                self.assertRaisesRegex(ValueError, "source revision"),
            ):
                render_recipe(
                    VALID_TEMPLATE,
                    replace(VALID_REQUEST, source_rev=source_rev),
                )

    def test_render_rejects_non_integer_or_negative_build_numbers(self) -> None:
        for build_number in (-1, True, "+1", "-1", " 1", "1 ", "1.0"):
            with self.subTest(build_number=build_number):
                request = RenderRequest(
                    version=VALID_REQUEST.version,
                    source_rev=VALID_REQUEST.source_rev,
                    build_number=build_number,  # type: ignore[arg-type]
                )
                with self.assertRaisesRegex(ValueError, "build number"):
                    render_recipe(VALID_TEMPLATE, request)

    def test_render_rejects_missing_duplicate_and_unknown_tokens(self) -> None:
        mutations = {
            "missing": VALID_TEMPLATE.replace(
                b"number: @@MTEST_BUILD_NUMBER@@\n",
                b"",
            ),
            "duplicate": VALID_TEMPLATE + b"again: @@MTEST_SOURCE_REV@@\n",
            "unknown": VALID_TEMPLATE + b"unknown: @@MTEST_CHANNEL@@\n",
        }
        for name, template in mutations.items():
            with (
                self.subTest(name=name),
                self.assertRaisesRegex(ValueError, "token"),
            ):
                render_recipe(template, VALID_REQUEST)


class RecipeManifestTests(unittest.TestCase):
    def _recipe(self, root: Path) -> None:
        (root / "recipe.yaml").write_bytes(b"package: mtest\n")
        (root / "test_smoke.mojo").write_bytes(b"def main():\n    pass\n")

    def test_manifest_is_canonical_and_byte_sorted(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-recipe-manifest-") as raw_tmp:
            root = Path(raw_tmp)
            self._recipe(root)
            entries = build_manifest(root)

        self.assertEqual(
            entries,
            (
                ManifestEntry(
                    path="recipe.yaml",
                    sha256=(
                        "342e93d33b82413d0228a69c7c24393f"
                        "2241fa92c2a0161761117cc26a1e7f4b"
                    ),
                ),
                ManifestEntry(
                    path="test_smoke.mojo",
                    sha256=(
                        "cde0429ba5478089419b8a36797f7408"
                        "9554914623c732054e04dd6eb2e49afd"
                    ),
                ),
            ),
        )
        self.assertEqual(
            manifest_bytes(entries),
            (
                b'[{"path":"recipe.yaml","sha256":"342e93d33b82413d0228a69c7c24393f'
                b'2241fa92c2a0161761117cc26a1e7f4b"},{"path":"test_smoke.mojo",'
                b'"sha256":"cde0429ba5478089419b8a36797f74089554914623c732054e04'
                b'dd6eb2e49afd"}]\n'
            ),
        )

    def test_manifest_rejects_wrong_roster_and_non_regular_entries(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-recipe-manifest-") as raw_tmp:
            root = Path(raw_tmp)
            self._recipe(root)
            mutations = ("file", "directory", "link", "fifo")
            for kind in mutations:
                with self.subTest(kind=kind):
                    path = root / kind
                    if kind == "file":
                        path.write_text("extra", encoding="utf-8")
                    elif kind == "directory":
                        path.mkdir()
                    elif kind == "link":
                        path.symlink_to("recipe.yaml")
                    else:
                        os.mkfifo(path)
                    with self.assertRaisesRegex(ValueError, "exactly|regular|link"):
                        build_manifest(root)
                    for path in root.iterdir():
                        if path.name in {"recipe.yaml", "test_smoke.mojo"}:
                            continue
                        if path.is_dir():
                            path.rmdir()
                        else:
                            path.unlink()

    def test_manifest_write_and_verify_share_one_digest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-recipe-manifest-") as raw_tmp:
            base = Path(raw_tmp)
            root = base / "render"
            root.mkdir()
            self._recipe(root)
            entries = build_manifest(root)
            manifest_path = base / "manifest.json"
            digest = write_manifest(manifest_path, entries)

            self.assertEqual(digest, directory_digest(entries))
            verify_manifest(root, manifest_path.read_bytes(), digest)

    def test_manifest_verification_rejects_every_tamper_surface(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-recipe-manifest-") as raw_tmp:
            base = Path(raw_tmp)
            root = base / "render"
            root.mkdir()
            self._recipe(root)
            entries = build_manifest(root)
            original_manifest = manifest_bytes(entries)
            original_digest = directory_digest(entries)

            cases = {
                "byte": (
                    original_manifest.replace(b"recipe.yaml", b"recipe.xyaml"),
                    original_digest,
                ),
                "digest": (original_manifest, "0" * 64),
                "traversal": (
                    json.dumps(
                        [
                            {
                                "path": "../recipe.yaml",
                                "sha256": entries[0].sha256,
                            },
                            {
                                "path": "test_smoke.mojo",
                                "sha256": entries[1].sha256,
                            },
                        ],
                        separators=(",", ":"),
                        sort_keys=True,
                    ).encode()
                    + b"\n",
                    original_digest,
                ),
            }
            for name, (manifest, digest) in cases.items():
                with self.subTest(name=name), self.assertRaises(ValueError):
                    verify_manifest(root, manifest, digest)

            (root / "recipe.yaml").write_bytes(b"changed\n")
            with self.assertRaises(ValueError):
                verify_manifest(root, original_manifest, original_digest)


class StageRecipeTests(unittest.TestCase):
    def _source(self, root: Path) -> Path:
        source = root / "source"
        source.mkdir()
        (source / "recipe.yaml").write_text("package: mtest\n", encoding="utf-8")
        (source / "test_smoke.mojo").write_text(
            "def main():\n    pass\n",
            encoding="utf-8",
        )
        return source

    def test_stage_replaces_the_recipe_roster_with_only_mtest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-recipe-stage-") as raw_tmp:
            root = Path(raw_tmp)
            source = self._source(root)
            checkout = root / "upstream"
            old = checkout / "recipes" / "old-package"
            old.mkdir(parents=True)
            (old / "recipe.yaml").write_text("old\n", encoding="utf-8")

            stage_recipe(source, checkout)

            recipes = checkout / "recipes"
            self.assertEqual([path.name for path in recipes.iterdir()], ["mtest"])
            self.assertEqual(
                sorted(path.name for path in (recipes / "mtest").iterdir()),
                ["recipe.yaml", "test_smoke.mojo"],
            )
            self.assertEqual(
                (recipes / "mtest" / "recipe.yaml").read_bytes(),
                (source / "recipe.yaml").read_bytes(),
            )

    def test_stage_rejects_a_linked_destination_boundary(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-recipe-stage-") as raw_tmp:
            root = Path(raw_tmp)
            source = self._source(root)
            checkout = root / "upstream"
            outside = root / "outside"
            outside.mkdir()
            checkout.mkdir()
            (checkout / "recipes").symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(ValueError, "boundary|link"):
                stage_recipe(source, checkout)


class CommunityRecipeDriftTests(unittest.TestCase):
    def _sources(self, root: Path) -> tuple[Path, Path]:
        local = root / "recipe.yaml"
        community = root / "recipe.yaml.in"
        repository_root = Path(__file__).resolve().parents[2]
        local.write_bytes((repository_root / "recipe" / "recipe.yaml").read_bytes())
        community.write_bytes(
            (repository_root / "recipe" / "community" / "recipe.yaml.in").read_bytes()
        )
        return local, community

    def test_live_recipes_share_the_public_package_contract(self) -> None:
        root = Path(__file__).resolve().parents[2]
        check_recipe_drift(
            root / "recipe" / "recipe.yaml",
            root / "recipe" / "community" / "recipe.yaml.in",
        )

    def test_shared_and_community_only_contract_drift_is_rejected(self) -> None:
        mutations = (
            ("name: mtest", "name: other"),
            ("mojo ==1.0.0b2", "mojo ==1.0.0b3"),
            ("mojo-compiler ==1.0.0b2", "mojo-compiler ==1.0.0b3"),
            ("license: MIT", "license: Apache-2.0"),
            ("license_file: LICENSE", "license_file: COPYING"),
            (
                "homepage: https://github.com/mikeleppane/mtest",
                "homepage: https://example.invalid/mtest",
            ),
            ("skip:\n    - linux and aarch64", "skip:\n    - false"),
            ("bash recipe/build.sh", "bash other/build.sh"),
            ("mtest --help >/dev/null", "mtest help >/dev/null"),
            ("mtest --no-config test_smoke.mojo", "mtest test_smoke.mojo"),
            ("    - mikeleppane", "    - someone-else"),
        )
        with tempfile.TemporaryDirectory(prefix="mtest-recipe-drift-") as raw_tmp:
            root = Path(raw_tmp)
            local, community = self._sources(root)
            original = community.read_text(encoding="utf-8")
            for old, new in mutations:
                with self.subTest(old=old):
                    mutated = original.replace(old, new, 1)
                    self.assertNotEqual(mutated, original)
                    community.write_text(mutated, encoding="utf-8")
                    with self.assertRaises(AssertionError):
                        check_recipe_drift(local, community)
                    community.write_text(original, encoding="utf-8")

    def test_local_source_and_community_schema_drift_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-recipe-drift-") as raw_tmp:
            root = Path(raw_tmp)
            local, community = self._sources(root)
            local_text = local.read_text(encoding="utf-8")
            local_mutations = (
                ("  - path: ..", "  - path: elsewhere"),
                ("number: 0", "number: 1"),
            )
            for old, new in local_mutations:
                with self.subTest(old=old):
                    local.write_text(
                        local_text.replace(old, new, 1),
                        encoding="utf-8",
                    )
                    with self.assertRaises(AssertionError):
                        check_recipe_drift(local, community)

            local.write_text(local_text, encoding="utf-8")
            community_text = community.read_text(encoding="utf-8")
            community.write_text(
                "schema_version: 1\n" + community_text,
                encoding="utf-8",
            )
            with self.assertRaises(AssertionError):
                check_recipe_drift(local, community)


if __name__ == "__main__":
    unittest.main()
