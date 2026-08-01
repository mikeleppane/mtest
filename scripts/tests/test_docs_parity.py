#!/usr/bin/env python3
"""Mutation tests for the documentation-site parity gate.

Each test builds a temporary tree holding the README and the site pages,
corrupts exactly one thing, and asserts the gate rejects it. The corruptions
are the ways the site stops being a navigator and becomes a second, ungated
home for commands: a byte inside a mirror drifts, a page grows an undeclared
block, a declaration stops resolving, a page appears that nothing declares, and
the site configuration stops excluding the internal working directories. A
checker that has quietly stopped rejecting any of them would leave the site
free to publish commands this repository never runs.

The green path over the real tree is asserted too, so a site page and its
README source cannot drift in the working copy without a red gate, and so the
declarations are known to name blocks that exist rather than merely to be
well-formed.
"""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from scripts.checks import docs_parity, version


TRACKED_FILES = (docs_parity.README_PATH, *docs_parity.SITE_PAGES)


class RepositoryParityTests(unittest.TestCase):
    """The declarations, and the live tree they describe."""

    def test_site_pages_are_the_three_landing_pages(self) -> None:
        self.assertEqual(
            docs_parity.SITE_PAGES,
            (
                Path("docs/index.md"),
                Path("docs/getting-started.md"),
                Path("docs/ci.md"),
            ),
        )

    def test_reference_pages_are_the_three_documents_the_site_navigates_to(
        self,
    ) -> None:
        self.assertEqual(
            docs_parity.REFERENCE_PAGES,
            (
                Path("docs/cli-contract.md"),
                Path("docs/json-stream.md"),
                Path("docs/releasing.md"),
            ),
        )

    def test_each_page_declares_the_blocks_it_actually_shows(self) -> None:
        """The content floor, pinned here rather than inside the gate.

        `check_declarations` can only prove the table is self-consistent: a
        page emptied of both its blocks and its declarations satisfies it.
        Counting the declarations per page from outside the module is what
        makes that deletion a red gate, the same way the bump and version
        inventories are pinned against literals rather than against the code
        that produces them.
        """
        counted: dict[Path, int] = {}
        for block in docs_parity.PARITY_BLOCKS:
            counted[block.page] = counted.get(block.page, 0) + 1
        self.assertEqual(
            counted,
            {
                Path("docs/index.md"): 1,
                Path("docs/getting-started.md"): 3,
                Path("docs/ci.md"): 3,
            },
        )

    def test_declarations_are_well_formed(self) -> None:
        docs_parity.check_declarations()

    def test_every_mirrored_block_matches_its_readme_source(self) -> None:
        docs_parity.check_parity_blocks()

    def test_no_site_page_holds_an_undeclared_block(self) -> None:
        docs_parity.check_site_blocks_are_all_declared()

    def test_every_tracked_documentation_page_is_declared(self) -> None:
        docs_parity.check_no_undeclared_pages()

    def test_the_site_configuration_excludes_the_internal_directories(self) -> None:
        docs_parity.check_site_configuration()

    def test_the_tracked_internal_design_document_is_still_excluded(self) -> None:
        """`.gitignore` came after this file, so only the site config hides it.

        git ignores what is not already tracked, and this document was tracked
        before `docs/superpowers/` was ignored. It is therefore present in a
        clean checkout, and the configuration's exclusion is the only thing
        between it and a published page.
        """
        internal = Path(
            "docs/superpowers/specs/2026-07-23-test-confidence-hardening-design.md"
        )
        self.assertTrue((docs_parity.REPO_ROOT / internal).is_file(), internal)
        self.assertTrue(
            any(
                str(internal).startswith(f"docs/{excluded}")
                for excluded in docs_parity.EXCLUDED_DOC_DIRECTORIES
            ),
            internal,
        )

    def test_every_site_page_that_renders_a_version_is_gated_as_one(self) -> None:
        """A mirrored transcript is still a public version surface.

        The parity gate proves a page agrees with the README; it says nothing
        about whether what they agree on is the release being shipped. That is
        the version gate's job, so any site page rendering a literal has to be
        declared a transcript site there as well.
        """
        for page in docs_parity.SITE_PAGES:
            renders = version.TRANSCRIPT_RE.search(
                (docs_parity.REPO_ROOT / page).read_text(encoding="utf-8")
            )
            self.assertEqual(
                renders is not None,
                page in version.TRANSCRIPT_SITES,
                f"{page} renders a version literal iff it is a transcript site",
            )


class ParityMutationTests(unittest.TestCase):
    """The gate's rejections, each watched firing on its own corruption."""

    def _clone(self, root: Path) -> None:
        """Copy the README and every site page into a temporary root.

        Args:
            root: Empty directory standing in for the repository root.
        """
        for relative in TRACKED_FILES:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(docs_parity.REPO_ROOT / relative, target)

    def _tree(self) -> tempfile.TemporaryDirectory[str]:
        """Return a temporary directory already holding the gated documents."""
        raw = tempfile.TemporaryDirectory(prefix="mtest-docs-parity-")
        self._clone(Path(raw.name))
        return raw

    def _rewrite(self, root: Path, relative: Path, old: str, new: str) -> None:
        """Replace the first occurrence of one string in a cloned document.

        Args:
            root: The temporary repository root.
            relative: Repository-relative path of the document to rewrite.
            old: Text to replace, which must be present.
            new: Its replacement.
        """
        path = root / relative
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text, relative)
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def test_a_clean_clone_passes(self) -> None:
        """Every rejection below has to be caused by its own mutation."""
        with self._tree() as raw:
            root = Path(raw)
            docs_parity.check_declarations(root)
            docs_parity.check_parity_blocks(root)
            docs_parity.check_site_blocks_are_all_declared(root)

    def test_a_changed_byte_inside_a_mirrored_block_is_rejected(self) -> None:
        """The defect the gate exists for: a page command that drifted."""
        with self._tree() as raw:
            root = Path(raw)
            self._rewrite(
                root, Path("docs/index.md"), "pixi add mtest", "pixi add mtst"
            )
            with self.assertRaisesRegex(AssertionError, "docs/index.md"):
                docs_parity.check_parity_blocks(root)

    def test_the_failure_names_both_sides_and_the_first_difference(self) -> None:
        """A red gate has to say what drifted, not only that something did."""
        with self._tree() as raw:
            root = Path(raw)
            self._rewrite(
                root, Path("docs/ci.md"), "timeout-minutes: 30", "timeout-minutes: 45"
            )
            with self.assertRaises(AssertionError) as caught:
                docs_parity.check_parity_blocks(root)
            message = str(caught.exception)
            self.assertIn("docs/ci.md", message)
            self.assertIn("README.md", message)
            self.assertIn("Run it in CI", message)
            self.assertIn("timeout-minutes: 45", message)

    def test_a_changed_info_string_is_rejected(self) -> None:
        """A block that changed language changed what it claims to be."""
        with self._tree() as raw:
            root = Path(raw)
            self._rewrite(root, Path("docs/getting-started.md"), "```mojo", "```python")
            with self.assertRaisesRegex(AssertionError, "info string"):
                docs_parity.check_parity_blocks(root)

    def test_an_undeclared_block_added_to_a_page_is_rejected(self) -> None:
        """The obvious bypass: show a command without declaring a mirror."""
        with self._tree() as raw:
            root = Path(raw)
            page = root / "docs" / "ci.md"
            extra = "\n```console\n$ mtest tests/\n```\n"
            page.write_text(page.read_text(encoding="utf-8") + extra, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "undeclared fenced block"):
                docs_parity.check_site_blocks_are_all_declared(root)

    def test_a_renamed_readme_section_is_rejected(self) -> None:
        """A declaration that names nothing must fail, not match nothing."""
        with self._tree() as raw:
            root = Path(raw)
            self._rewrite(
                root, docs_parity.README_PATH, "## Run it in CI", "## Running it in CI"
            )
            with self.assertRaisesRegex(AssertionError, "Run it in CI"):
                docs_parity.check_parity_blocks(root)

    def test_a_readme_index_that_no_longer_exists_is_rejected(self) -> None:
        """Deleting the source block must be louder than a silent skip."""
        with self._tree() as raw:
            root = Path(raw)
            readme = root / docs_parity.README_PATH
            text = readme.read_text(encoding="utf-8")
            start = text.index("```yaml\n      - uses: mikeleppane/mtest@v1")
            end = text.index("```\n", text.index("args: --gh-annotations auto"))
            readme.write_text(text[:start] + text[end + 4 :], encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, r"holds only 2 blocks"):
                docs_parity.check_parity_blocks(root)

    def test_a_page_index_that_no_longer_exists_is_rejected(self) -> None:
        """A page that lost a mirrored block is a broken declaration too."""
        with self._tree() as raw:
            root = Path(raw)
            (root / "docs" / "index.md").write_text(
                "# mtest\n\nNothing here.\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(AssertionError, "declares block 0"):
                docs_parity.check_parity_blocks(root)

    def test_a_vanished_page_is_reported_not_crashed(self) -> None:
        """`main()` catches AssertionError alone, so a deleted page must be one."""
        with self._tree() as raw:
            root = Path(raw)
            (root / "docs" / "getting-started.md").unlink()
            with self.assertRaisesRegex(AssertionError, "does not exist"):
                docs_parity.check_declarations(root)
            with self.assertRaisesRegex(AssertionError, "cannot read"):
                docs_parity.check_parity_blocks(root)


class DeclarationTableTests(unittest.TestCase):
    """The table itself, which the comparisons above take on trust."""

    def test_a_page_outside_the_site_list_is_rejected(self) -> None:
        """A declared page nothing sweeps could carry undeclared copies."""
        stray = docs_parity.ParityBlock(Path("docs/tour.md"), 0, "Installation", 0)
        with (
            mock.patch.object(
                docs_parity, "PARITY_BLOCKS", (*docs_parity.PARITY_BLOCKS, stray)
            ),
            self.assertRaisesRegex(AssertionError, "docs/tour.md"),
        ):
            docs_parity.check_declarations()

    def test_one_copy_declared_against_two_sources_is_rejected(self) -> None:
        """Two declarations for one block would make the pairing ambiguous."""
        duplicate = docs_parity.ParityBlock(
            Path("docs/index.md"), 0, "Your first test", 0
        )
        with (
            mock.patch.object(
                docs_parity, "PARITY_BLOCKS", (*docs_parity.PARITY_BLOCKS, duplicate)
            ),
            self.assertRaisesRegex(AssertionError, "declared twice"),
        ):
            docs_parity.check_declarations()


class FenceScannerTests(unittest.TestCase):
    """The block scanner, whose ordinals every declaration depends on."""

    def test_blocks_are_returned_in_document_order_with_their_info_strings(
        self,
    ) -> None:
        blocks = docs_parity.fenced_blocks(
            "intro\n\n```console\n$ one\n```\n\ntext\n\n```yaml\nkey: two\n```\n",
            "example",
        )
        self.assertEqual([block.info for block in blocks], ["console", "yaml"])
        self.assertEqual([block.body for block in blocks], ["$ one\n", "key: two\n"])
        self.assertEqual([block.line for block in blocks], [3, 9])

    def test_a_fence_inside_a_block_does_not_open_a_new_one(self) -> None:
        """A longer fence wrapping a shorter one is one block, not three."""
        blocks = docs_parity.fenced_blocks(
            "````markdown\n```console\n$ one\n```\n````\n", "example"
        )
        self.assertEqual(len(blocks), 1)
        self.assertEqual(blocks[0].body, "```console\n$ one\n```\n")

    def test_an_unterminated_fence_is_rejected(self) -> None:
        """Every later ordinal would otherwise mean a different block."""
        with self.assertRaisesRegex(AssertionError, "never closed"):
            docs_parity.fenced_blocks("```console\n$ one\n", "example")

    def test_a_heading_inside_a_fence_does_not_end_a_section(self) -> None:
        """README transcripts contain `## ` lines that are output, not headings."""
        readme = (
            "## One\n\n```console\n## not a heading\n```\n\n"
            "## Two\n\n```yaml\nk: v\n```\n"
        )
        blocks = docs_parity.readme_section_blocks(readme, "One", "example")
        self.assertEqual(len(blocks), 1)
        self.assertEqual(blocks[0].body, "## not a heading\n")

    def test_a_duplicated_section_heading_is_rejected(self) -> None:
        """Two sections with one name make an ordinal ambiguous."""
        with self.assertRaisesRegex(AssertionError, "found 2"):
            docs_parity.readme_section_blocks("## One\n\n## One\n", "One", "example")

    def test_an_indented_fence_inside_an_admonition_is_seen(self) -> None:
        """Material's tips indent their fences four spaces; they still render."""
        blocks = docs_parity.fenced_blocks(
            '!!! tip "Try it"\n\n    ```console\n    $ mtest tests/\n    ```\n',
            "example",
        )
        self.assertEqual(len(blocks), 1)
        self.assertEqual(blocks[0].info, "console")

    def test_an_indented_block_is_compared_without_its_container_indent(self) -> None:
        """The renderer removes that indentation, so the comparison does too."""
        blocks = docs_parity.fenced_blocks(
            '=== "Pixi"\n\n    ```console\n    $ mtest tests/\n    ```\n', "example"
        )
        self.assertEqual(blocks[0].body, "$ mtest tests/\n")

    def test_both_scanners_agree_about_a_fence_line_inside_a_block(self) -> None:
        """One scanner serves both readers, so section bounds cannot diverge.

        A body line spelling an opening fence used to close the block for the
        section splitter while leaving it open for the block reader, which
        would put the two under different fence states from that line onward.
        """
        readme = (
            "## One\n\n````markdown\n```console\n$ one\n```\n````\n\n"
            "## Two\n\n```yaml\nk: v\n```\n"
        )
        section = docs_parity.readme_section_blocks(readme, "One", "example")
        whole = docs_parity.fenced_blocks(readme, "example")
        self.assertEqual(len(section), 1)
        self.assertEqual(len(whole), 2)
        self.assertEqual(section[0].body, whole[0].body)


class IndentedCodeTests(unittest.TestCase):
    """The unfenced construct that renders as code and declares nothing."""

    def test_an_indented_code_block_is_reported(self) -> None:
        self.assertEqual(
            docs_parity.indented_code_lines(
                "Run this:\n\n    mtest tests/\n", "example"
            ),
            (3,),
        )

    def test_a_list_continuation_is_not_code(self) -> None:
        """Indented prose under a list item is content, and stays legal."""
        self.assertEqual(
            docs_parity.indented_code_lines(
                "- item\n\n    still the item\n", "example"
            ),
            (),
        )

    def test_an_admonition_body_is_not_code(self) -> None:
        """A container indents everything it holds; that is not a code block."""
        self.assertEqual(
            docs_parity.indented_code_lines(
                '!!! note "Heads up"\n\n    Ordinary prose in a tip.\n', "example"
            ),
            (),
        )

    def test_indented_lines_inside_a_fence_are_the_block_body(self) -> None:
        self.assertEqual(
            docs_parity.indented_code_lines(
                "```yaml\n\n    strategy:\n      matrix: [1]\n```\n", "example"
            ),
            (),
        )

    def test_code_nested_deeper_than_a_list_item_is_reported(self) -> None:
        """A list item absorbs its marker's width, not four further spaces."""
        self.assertEqual(
            docs_parity.indented_code_lines(
                "- item\n\n      mtest tests/\n", "example"
            ),
            (3,),
        )

    def test_code_nested_deeper_than_a_container_is_reported(self) -> None:
        """An admonition absorbs four spaces; eight is a code block inside it."""
        self.assertEqual(
            docs_parity.indented_code_lines(
                '!!! note "Heads up"\n\n        mtest tests/\n', "example"
            ),
            (3,),
        )

    def test_an_ordered_list_marker_shifts_the_code_column_by_its_width(self) -> None:
        """The threshold follows the marker, so `1. ` and `- ` differ."""
        self.assertEqual(
            docs_parity.indented_code_lines("1. item\n\n    still it\n", "example"),
            (),
        )
        self.assertEqual(
            docs_parity.indented_code_lines("1. item\n\n       code\n", "example"),
            (3,),
        )

    def test_a_site_page_carrying_one_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-docs-parity-") as raw:
            root = Path(raw)
            for relative in TRACKED_FILES:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(docs_parity.REPO_ROOT / relative, target)
            page = root / "docs" / "ci.md"
            page.write_text(
                page.read_text(encoding="utf-8") + "\nRun this:\n\n    mtest tests/\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "indented code block"):
                docs_parity.check_site_blocks_are_all_declared(root)

    def test_a_site_page_nesting_one_under_a_list_is_rejected(self) -> None:
        """The bypass the container rule opened: indent past the item's body."""
        with tempfile.TemporaryDirectory(prefix="mtest-docs-parity-") as raw:
            root = Path(raw)
            for relative in TRACKED_FILES:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(docs_parity.REPO_ROOT / relative, target)
            page = root / "docs" / "ci.md"
            page.write_text(
                page.read_text(encoding="utf-8")
                + "\n- Then run it:\n\n      mtest tests/ --shard hash:1/4\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "indented code block"):
                docs_parity.check_site_blocks_are_all_declared(root)


class RawHtmlCodeTests(unittest.TestCase):
    """The other unfenced construct that reaches a reader as code."""

    def test_a_raw_pre_element_is_reported(self) -> None:
        self.assertEqual(
            docs_parity.raw_html_code_lines(
                "Run this:\n\n<pre>mtest tests/</pre>\n", "example"
            ),
            (3,),
        )

    def test_every_refused_element_is_reported(self) -> None:
        for element in ("pre", "code", "textarea"):
            with self.subTest(element=element):
                self.assertEqual(
                    docs_parity.raw_html_code_lines(
                        f"<{element}>mtest tests/</{element}>\n", "example"
                    ),
                    (1,),
                )

    def test_raw_html_inside_a_fence_is_that_block_body(self) -> None:
        """A fenced block showing HTML is a declared mirror, not a container."""
        self.assertEqual(
            docs_parity.raw_html_code_lines(
                "```html\n<pre>markup</pre>\n```\n", "example"
            ),
            (),
        )

    def test_a_site_page_carrying_one_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-docs-parity-") as raw:
            root = Path(raw)
            for relative in TRACKED_FILES:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(docs_parity.REPO_ROOT / relative, target)
            page = root / "docs" / "ci.md"
            page.write_text(
                page.read_text(encoding="utf-8")
                + "\n<pre>pixi run mtest tests --shard hash:1/4</pre>\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "raw-HTML code container"):
                docs_parity.check_site_blocks_are_all_declared(root)

    def test_no_site_page_uses_one_today(self) -> None:
        for page in docs_parity.SITE_PAGES:
            text = (docs_parity.REPO_ROOT / page).read_text(encoding="utf-8")
            self.assertEqual(docs_parity.raw_html_code_lines(text, str(page)), (), page)


class PageSweepTests(unittest.TestCase):
    """The inverse sweep that stops a new page from being ungated from birth."""

    def _repository(self, root: Path) -> None:
        """Build a temporary git repository holding every declared document.

        Args:
            root: Empty directory to initialize as a repository.
        """
        subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)
        tracked = (
            docs_parity.README_PATH,
            docs_parity.MKDOCS_PATH,
            *docs_parity.SITE_PAGES,
            *docs_parity.REFERENCE_PAGES,
        )
        for relative in tracked:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(docs_parity.REPO_ROOT / relative, target)
        subprocess.run(
            ["git", "-C", str(root), "add", "--", *(str(p) for p in tracked)],
            check=True,
        )

    def _track(self, root: Path, relative: str, text: str) -> None:
        """Write one extra document into the temporary repository and track it.

        Args:
            root: The temporary repository root.
            relative: Repository-relative path of the new document.
            text: Its contents.
        """
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "--", relative], check=True)

    def test_a_clean_repository_passes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-docs-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            docs_parity.check_no_undeclared_pages(root)

    def test_a_new_page_declaring_nothing_is_rejected(self) -> None:
        """The hole a hand-written page list cannot close on its own.

        The page declares no parity block, so every comparison skips it; it
        renders no version literal, so the version sweep skips it too. Only
        this sweep sees it.
        """
        with tempfile.TemporaryDirectory(prefix="mtest-docs-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            self._track(
                root,
                "docs/tutorial.md",
                "# Tutorial\n\n```console\n$ mtest tests --shard hash:1/4\n```\n",
            )
            with self.assertRaisesRegex(AssertionError, "docs/tutorial.md"):
                docs_parity.check_no_undeclared_pages(root)

    def test_an_untracked_draft_is_not_a_page(self) -> None:
        """Scratch files are not published, and must not turn the gate red."""
        with tempfile.TemporaryDirectory(prefix="mtest-docs-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            (root / "docs" / "draft.md").write_text("# Draft\n", encoding="utf-8")
            docs_parity.check_no_undeclared_pages(root)

    def test_a_declared_page_that_stopped_being_tracked_is_rejected(self) -> None:
        """A site page missing from the index would publish nothing at all."""
        with tempfile.TemporaryDirectory(prefix="mtest-docs-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            subprocess.run(
                ["git", "-C", str(root), "rm", "-q", "--cached", "docs/ci.md"],
                check=True,
            )
            with self.assertRaisesRegex(AssertionError, "docs/ci.md"):
                docs_parity.check_no_undeclared_pages(root)

    def test_a_tracked_page_in_an_unexcluded_subdirectory_is_rejected(self) -> None:
        """A subdirectory the configuration does not exclude would be published."""
        with tempfile.TemporaryDirectory(prefix="mtest-docs-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            self._track(root, "docs/internal/design.md", "# Internal\n")
            with self.assertRaisesRegex(AssertionError, "docs/internal/design.md"):
                docs_parity.check_no_undeclared_pages(root)

    def test_a_page_under_an_excluded_directory_is_accepted(self) -> None:
        """The tracked internal document must not red the gate it is hidden by."""
        with tempfile.TemporaryDirectory(prefix="mtest-docs-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            self._track(root, "docs/superpowers/specs/design.md", "# Internal\n")
            docs_parity.check_no_undeclared_pages(root)

    def test_a_tree_without_git_fails_closed(self) -> None:
        """No inventory means no verdict, so the sweep refuses rather than pass."""
        with (
            tempfile.TemporaryDirectory(prefix="mtest-docs-sweep-") as raw,
            self.assertRaisesRegex(AssertionError, "cannot list tracked files"),
        ):
            docs_parity.check_no_undeclared_pages(Path(raw))


class SiteConfigurationTests(unittest.TestCase):
    """The two lines standing between internal documents and a public site."""

    def _configuration(self, root: Path) -> Path:
        """Copy the site configuration into a temporary root.

        Args:
            root: Directory standing in for the repository root.

        Returns:
            The path of the copy.
        """
        target = root / docs_parity.MKDOCS_PATH
        shutil.copyfile(docs_parity.REPO_ROOT / docs_parity.MKDOCS_PATH, target)
        return target

    def test_a_configuration_that_stopped_excluding_plans_is_rejected(self) -> None:
        for excluded in docs_parity.EXCLUDED_DOC_DIRECTORIES:
            with (
                self.subTest(excluded=excluded),
                tempfile.TemporaryDirectory(prefix="mtest-docs-config-") as raw,
            ):
                root = Path(raw)
                config = self._configuration(root)
                config.write_text(
                    config.read_text(encoding="utf-8").replace(
                        f"  {excluded}\n", "", 1
                    ),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(AssertionError, excluded):
                    docs_parity.check_site_configuration(root)

    def test_a_configuration_that_re_includes_an_excluded_directory_is_rejected(
        self,
    ) -> None:
        """`exclude_docs` is gitignore-style, so a negation puts one back.

        The exclusion line stays exactly where it was, so the check that reads
        it still finds it. One added line publishes every internal document,
        including the tracked design document that nothing else hides.
        """
        for excluded in docs_parity.EXCLUDED_DOC_DIRECTORIES:
            with (
                self.subTest(excluded=excluded),
                tempfile.TemporaryDirectory(prefix="mtest-docs-config-") as raw,
            ):
                root = Path(raw)
                config = self._configuration(root)
                config.write_text(
                    config.read_text(encoding="utf-8").replace(
                        f"  {excluded}\n", f"  {excluded}\n  !{excluded}\n", 1
                    ),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(AssertionError, "re-includes"):
                    docs_parity.check_site_configuration(root)

    def test_a_build_outside_the_ignored_directory_is_rejected(self) -> None:
        """Mkdocs' default output directory is not ignored, so it reds the tree."""
        with tempfile.TemporaryDirectory(prefix="mtest-docs-config-") as raw:
            root = Path(raw)
            config = self._configuration(root)
            config.write_text(
                config.read_text(encoding="utf-8").replace(
                    "site_dir: build/site", "site_dir: site", 1
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "must build into build/"):
                docs_parity.check_site_configuration(root)

    def test_navigating_to_an_undeclared_page_is_rejected(self) -> None:
        """Adding a page to the nav is how it reaches a reader."""
        with tempfile.TemporaryDirectory(prefix="mtest-docs-config-") as raw:
            root = Path(raw)
            config = self._configuration(root)
            config.write_text(
                config.read_text(encoding="utf-8").replace(
                    "  - Home: index.md",
                    "  - Home: index.md\n  - Tutorial: tutorial.md",
                    1,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "tutorial.md"):
                docs_parity.check_site_configuration(root)

    def test_a_site_page_dropped_from_the_navigation_is_rejected(self) -> None:
        """A page nothing navigates to is a page nobody reviews."""
        with tempfile.TemporaryDirectory(prefix="mtest-docs-config-") as raw:
            root = Path(raw)
            config = self._configuration(root)
            config.write_text(
                config.read_text(encoding="utf-8").replace(
                    "  - Continuous integration: ci.md\n", "", 1
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "ci.md"):
                docs_parity.check_site_configuration(root)

    def test_a_vanished_configuration_is_reported_not_crashed(self) -> None:
        with (
            tempfile.TemporaryDirectory(prefix="mtest-docs-config-") as raw,
            self.assertRaisesRegex(AssertionError, "cannot read"),
        ):
            docs_parity.check_site_configuration(Path(raw))


if __name__ == "__main__":
    unittest.main()
