#!/usr/bin/env python3
"""Unit tests for the layering-doctrine gate."""

from __future__ import annotations

import contextlib
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from scripts.checks import layering


def _write(root: Path, files: dict[str, str]) -> None:
    """Materialize a synthetic source tree.

    Args:
        root: Directory to write beneath, standing in for a repository root.
        files: Root-relative path -> file contents.
    """
    for name, body in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")


def _code(source: str) -> list[str]:
    """Return one stripped line of code per physical line of source.

    Args:
        source: Mojo source to strip.

    Returns:
        The code each line contributes, with docstrings and comments removed.
    """
    return [text for _number, text in layering.strip_docstrings_and_comments(source)]


def _scan(files: dict[str, str]) -> layering.Report:
    """Scan a synthetic tree written to a temporary directory.

    Args:
        files: Root-relative path -> file contents.

    Returns:
        The report the scanner produced for that tree.
    """
    with tempfile.TemporaryDirectory(prefix="mtest-layering-") as raw:
        root = Path(raw)
        _write(root, files)
        return layering.scan(root)


class StrippingTests(unittest.TestCase):
    def test_a_triple_quoted_block_contributes_no_code(self) -> None:
        source = '"""Docs.\n\nfrom mtest.session import run_session\n"""\nvar x = 1\n'

        code = _code(source)

        self.assertEqual(code, ["", "", "", "", "var x = 1"])

    def test_line_numbers_survive_stripping(self) -> None:
        source = '"""Docs."""\n\nfrom mtest.model import Outcome\n'

        stripped = layering.strip_docstrings_and_comments(source)

        self.assertEqual(stripped[2], (3, "from mtest.model import Outcome"))

    def test_a_comment_contributes_no_code(self) -> None:
        source = "# from mtest.session import run_session\nvar x = 1  # exit(0)\n"

        code = _code(source)

        self.assertEqual(code, ["", "var x = 1  "])

    def test_a_string_literal_keeps_its_contents(self) -> None:
        source = 'var rc = external_call["mtest_exec_reap", Int32]()\n'

        code = _code(source)

        self.assertEqual(code, [source.rstrip("\n")])

    def test_a_hash_inside_a_string_is_not_a_comment(self) -> None:
        source = 'var fence = "# mtest"\n'

        code = _code(source)

        self.assertEqual(code, ['var fence = "# mtest"'])

    def test_a_docstring_closing_and_reopening_on_one_line(self) -> None:
        source = '"""Docs."""\nvar x = 1\n"""More docs."""\nvar y = 2\n'

        code = _code(source)

        self.assertEqual(code, ["", "var x = 1", "", "var y = 2"])


class RankTests(unittest.TestCase):
    def test_a_downward_import_is_clean(self) -> None:
        report = _scan(
            {
                "src/mtest/session/store.mojo": (
                    "from mtest.config import RunnerConfig\n"
                ),
                "src/mtest/config/__init__.mojo": "",
            }
        )

        self.assertEqual(report.violations, ())

    def test_an_upward_import_is_a_violation(self) -> None:
        report = _scan(
            {
                "src/mtest/config/resolve.mojo": (
                    "from mtest.session import run_session\n"
                )
            }
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("src/mtest/config/resolve.mojo:1: R1-rank:", report.violations[0])
        self.assertIn("mtest.session", report.violations[0])

    def test_a_same_rank_cross_package_import_is_a_violation(self) -> None:
        report = _scan(
            {"src/mtest/model/events.mojo": "from mtest.platform import write_all\n"}
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("R1-rank:", report.violations[0])

    def test_a_self_import_is_clean(self) -> None:
        report = _scan(
            {"src/mtest/model/events.mojo": "from mtest.model.outcome import Outcome\n"}
        )

        self.assertEqual(report.violations, ())

    def test_a_package_with_no_declared_rank_is_a_violation(self) -> None:
        report = _scan({"src/mtest/telemetry/probe.mojo": "var x = 1\n"})

        self.assertEqual(len(report.violations), 1)
        self.assertIn("R1-rank:", report.violations[0])
        self.assertIn("telemetry", report.violations[0])

    def test_a_bare_upward_import_is_a_violation(self) -> None:
        report = _scan(
            {"src/mtest/config/resolve.mojo": "import mtest.session.store\n"}
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("R1-rank:", report.violations[0])
        self.assertIn("mtest.session.store", report.violations[0])

    def test_a_bare_downward_import_is_clean(self) -> None:
        report = _scan(
            {"src/mtest/session/store.mojo": "import mtest.config.resolve\n"}
        )

        self.assertEqual(report.violations, ())

    def test_a_bare_import_of_a_std_module_is_ignored(self) -> None:
        report = _scan({"src/mtest/session/store.mojo": "import mtest_helpers\n"})

        self.assertEqual(report.violations, ())
        self.assertEqual(report.infos, ())

    def test_the_composition_root_may_import_every_layer(self) -> None:
        report = _scan(
            {
                "src/main.mojo": "from mtest.session import run_session\n",
                "src/mtest/session/__init__.mojo": (
                    "from mtest.session.session import run_session\n"
                ),
            }
        )

        self.assertEqual(report.violations, ())


class SiblingTests(unittest.TestCase):
    def test_a_layer_two_sibling_import_is_a_violation(self) -> None:
        report = _scan(
            {"src/mtest/report/console.mojo": "from mtest.discover import walk\n"}
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn(
            "src/mtest/report/console.mojo:1: R2-sibling:", report.violations[0]
        )

    def test_a_bare_layer_two_sibling_import_is_a_violation(self) -> None:
        report = _scan(
            {"src/mtest/report/console.mojo": "import mtest.discover.walk\n"}
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("R2-sibling:", report.violations[0])

    def test_a_layer_two_import_of_a_lower_layer_is_clean(self) -> None:
        report = _scan(
            {"src/mtest/report/console.mojo": "from mtest.config import RunnerConfig\n"}
        )

        self.assertEqual(report.violations, ())


class FacadeBypassTests(unittest.TestCase):
    FACADE = "from mtest.session.store import Store\n"

    def test_a_private_deep_import_is_a_violation(self) -> None:
        report = _scan(
            {
                "src/mtest/cli/doctor.mojo": (
                    "from mtest.session.store import _slot\n"
                ),
                "src/mtest/session/__init__.mojo": self.FACADE,
            }
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("R3-facade-bypass:", report.violations[0])
        self.assertIn("_slot", report.violations[0])
        self.assertEqual(report.infos, ())

    def test_a_deep_import_of_an_exported_name_is_a_violation(self) -> None:
        report = _scan(
            {
                "src/mtest/cli/doctor.mojo": "from mtest.session.store import Store\n",
                "src/mtest/session/__init__.mojo": self.FACADE,
            }
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("R3-facade-bypass:", report.violations[0])
        self.assertIn("Store", report.violations[0])

    def test_a_deep_import_of_an_unexported_name_is_info(self) -> None:
        report = _scan(
            {
                "src/mtest/cli/doctor.mojo": "from mtest.session.store import Slot\n",
                "src/mtest/session/__init__.mojo": self.FACADE,
            }
        )

        self.assertEqual(report.violations, ())
        self.assertEqual(len(report.infos), 1)
        self.assertIn("R3-deep-import:", report.infos[0])
        self.assertIn("Slot", report.infos[0])

    def test_an_aliased_facade_export_still_shadows(self) -> None:
        report = _scan(
            {
                "src/mtest/cli/doctor.mojo": "from mtest.session.store import Store\n",
                "src/mtest/session/__init__.mojo": (
                    "from mtest.session.store import Slot as Store\n"
                ),
            }
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("R3-facade-bypass:", report.violations[0])

    def test_a_same_package_private_import_is_clean(self) -> None:
        report = _scan(
            {
                "src/mtest/session/pool.mojo": (
                    "from mtest.session.store import _slot\n"
                ),
                "src/mtest/session/__init__.mojo": self.FACADE,
            }
        )

        self.assertEqual(report.violations, ())
        self.assertEqual(report.infos, ())

    def test_a_facade_import_is_never_a_bypass(self) -> None:
        report = _scan(
            {
                "src/mtest/cli/doctor.mojo": "from mtest.session import Store\n",
                "src/mtest/session/__init__.mojo": self.FACADE,
            }
        )

        self.assertEqual(report.violations, ())
        self.assertEqual(report.infos, ())

    def test_the_composition_root_counts_as_inside_cli(self) -> None:
        report = _scan(
            {
                "src/main.mojo": "from mtest.cli.doctor import _diagnose\n",
                "src/mtest/cli/__init__.mojo": (
                    "from mtest.cli.doctor import diagnose\n"
                ),
            }
        )

        self.assertEqual(report.violations, ())
        self.assertEqual(report.infos, ())

    def test_a_bare_deep_import_is_info(self) -> None:
        report = _scan(
            {
                "src/mtest/cli/doctor.mojo": "import mtest.session.store\n",
                "src/mtest/session/__init__.mojo": self.FACADE,
            }
        )

        self.assertEqual(report.violations, ())
        self.assertEqual(len(report.infos), 1)
        self.assertIn("R3-deep-import:", report.infos[0])
        self.assertIn("imported whole", report.infos[0])

    def test_a_bare_aliased_import_names_the_module_not_the_alias(self) -> None:
        report = _scan(
            {"src/mtest/config/resolve.mojo": "import mtest.session.store as s\n"}
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("mtest.session.store", report.violations[0])

    def test_an_aliased_deep_import_of_an_exported_name_is_a_violation(self) -> None:
        # Judging the alias instead would call `invoke` a name the facade does
        # not export and report the bypass as information.
        report = _scan(
            {
                "src/mtest/cli/doctor.mojo": (
                    "from mtest.session.session import run_session as invoke\n"
                ),
                "src/mtest/session/__init__.mojo": (
                    "from mtest.session.session import run_session\n"
                ),
            }
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("R3-facade-bypass:", report.violations[0])
        self.assertIn("run_session", report.violations[0])
        self.assertEqual(report.infos, ())

    def test_an_aliased_private_import_is_still_private(self) -> None:
        report = _scan(
            {
                "src/mtest/cli/doctor.mojo": (
                    "from mtest.session.store import _slot as public_name\n"
                ),
                "src/mtest/session/__init__.mojo": self.FACADE,
            }
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("R3-facade-bypass:", report.violations[0])
        self.assertIn("_slot", report.violations[0])

    def test_a_multi_line_import_list_is_parsed(self) -> None:
        report = _scan(
            {
                "src/mtest/cli/doctor.mojo": (
                    "from mtest.session.store import (\n    Slot,\n    _slot,\n)\n"
                ),
                "src/mtest/session/__init__.mojo": self.FACADE,
            }
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("_slot", report.violations[0])
        self.assertEqual(len(report.infos), 1)
        self.assertIn("Slot", report.infos[0])


class SubpackageFacadeTests(unittest.TestCase):
    """A package nested inside a package offers a surface of its own."""

    STORE_FACADE = "from mtest.session.store.filesystem import STORE_DIR\n"
    SESSION_FACADE = "from mtest.session.store import ensure_cache_root\n"

    def test_a_deep_import_around_a_subpackage_facade_is_a_violation(self) -> None:
        # The name is exported by the store's own facade and not by the
        # session facade above it, so a checker that only reads top-level
        # facades reports this bypass as information.
        report = _scan(
            {
                "src/mtest/cli/cache_admin.mojo": (
                    "from mtest.session.store.filesystem import STORE_DIR\n"
                ),
                "src/mtest/session/store/__init__.mojo": self.STORE_FACADE,
                "src/mtest/session/__init__.mojo": self.SESSION_FACADE,
            }
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("R3-facade-bypass:", report.violations[0])
        self.assertIn("STORE_DIR", report.violations[0])
        self.assertIn("mtest/session/store/__init__.mojo", report.violations[0])
        self.assertEqual(report.infos, ())

    def test_a_subpackage_module_may_reach_its_own_siblings(self) -> None:
        report = _scan(
            {
                "src/mtest/session/store/artifact.mojo": (
                    "from mtest.session.store.filesystem import STORE_DIR\n"
                ),
                "src/mtest/session/store/__init__.mojo": self.STORE_FACADE,
                "src/mtest/session/__init__.mojo": self.SESSION_FACADE,
            }
        )

        self.assertEqual(report.violations, ())
        self.assertEqual(report.infos, ())

    def test_a_subpackage_module_may_reach_the_package_it_sits_in(self) -> None:
        report = _scan(
            {
                "src/mtest/session/store/artifact.mojo": (
                    "from mtest.session.scratch import _mangle\n"
                ),
                "src/mtest/session/store/__init__.mojo": self.STORE_FACADE,
                "src/mtest/session/__init__.mojo": self.SESSION_FACADE,
            }
        )

        self.assertEqual(report.violations, ())
        self.assertEqual(report.infos, ())

    def test_the_package_above_must_use_the_subpackage_facade(self) -> None:
        report = _scan(
            {
                "src/mtest/session/pool.mojo": (
                    "from mtest.session.store.filesystem import STORE_DIR\n"
                ),
                "src/mtest/session/store/__init__.mojo": self.STORE_FACADE,
                "src/mtest/session/__init__.mojo": self.SESSION_FACADE,
            }
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("mtest/session/store/__init__.mojo", report.violations[0])

    def test_an_import_through_the_subpackage_facade_is_judged_above_it(self) -> None:
        report = _scan(
            {
                "src/mtest/cli/cache_admin.mojo": (
                    "from mtest.session.store import ensure_cache_root\n"
                ),
                "src/mtest/session/store/__init__.mojo": self.STORE_FACADE,
                "src/mtest/session/__init__.mojo": self.SESSION_FACADE,
            }
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("mtest/session/__init__.mojo", report.violations[0])
        self.assertIn("ensure_cache_root", report.violations[0])

    def test_a_directory_with_no_facade_falls_back_to_its_package(self) -> None:
        report = _scan(
            {
                "src/mtest/cli/doctor.mojo": (
                    "from mtest.session.detail.thing import Store\n"
                ),
                "src/mtest/session/__init__.mojo": (
                    "from mtest.session.store import Store\n"
                ),
            }
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("mtest/session/__init__.mojo", report.violations[0])


class ExitConfinementTests(unittest.TestCase):
    def test_exit_in_the_composition_root_is_clean(self) -> None:
        report = _scan({"src/main.mojo": "exit(status)\n"})

        self.assertEqual(report.violations, ())

    def test_exit_outside_the_composition_root_is_a_violation(self) -> None:
        report = _scan({"src/mtest/cli/doctor.mojo": "    exit(2)\n"})

        self.assertEqual(len(report.violations), 1)
        self.assertIn("src/mtest/cli/doctor.mojo:1: R4-exit:", report.violations[0])

    def test_an_identifier_ending_in_exit_is_not_an_exit_call(self) -> None:
        report = _scan({"src/mtest/model/exit_code.mojo": "def resolve_exit(code):\n"})

        self.assertEqual(report.violations, ())

    def test_an_aliased_exit_call_is_a_violation(self) -> None:
        # Without alias tracking neither line is seen: the import binds a name
        # the rule does not know, and the call spells that name.
        report = _scan(
            {
                "src/mtest/cli/doctor.mojo": (
                    "from std.sys import exit as terminate\nterminate(1)\n"
                )
            }
        )

        self.assertEqual(len(report.violations), 2)
        self.assertIn(
            "src/mtest/cli/doctor.mojo:1: R4-exit-import:", report.violations[0]
        )
        self.assertIn("src/mtest/cli/doctor.mojo:2: R4-exit:", report.violations[1])

    def test_importing_exit_outside_the_composition_root_is_a_violation(self) -> None:
        report = _scan({"src/mtest/cli/doctor.mojo": "from std.sys import exit\n"})

        self.assertEqual(len(report.violations), 1)
        self.assertIn("R4-exit-import:", report.violations[0])

    def test_the_composition_root_may_alias_exit(self) -> None:
        report = _scan(
            {"src/main.mojo": "from std.sys import exit as terminate\nterminate(1)\n"}
        )

        self.assertEqual(report.violations, ())


class ForeignCallTests(unittest.TestCase):
    def test_the_platform_layer_may_declare_any_symbol(self) -> None:
        report = _scan(
            {"src/mtest/platform/fs.mojo": 'var rc = external_call["chmod", Int32]()\n'}
        )

        self.assertEqual(report.violations, ())

    def test_exec_may_call_the_native_adapter_abi(self) -> None:
        report = _scan(
            {
                "src/mtest/exec/supervise.mojo": (
                    'var rc = external_call["mtest_exec_process_reap", Int32]()\n'
                )
            }
        )

        self.assertEqual(report.violations, ())

    def test_the_sanctioned_signal_helper_call_is_allowed(self) -> None:
        report = _scan(
            {"src/mtest/exec/signals.mojo": 'external_call["kill", Int32]()\n'}
        )

        self.assertEqual(report.violations, ())

    def test_the_same_symbol_in_another_exec_module_is_a_violation(self) -> None:
        report = _scan(
            {"src/mtest/exec/capture.mojo": 'external_call["kill", Int32]()\n'}
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("R5-external-call:", report.violations[0])
        self.assertIn("kill", report.violations[0])

    def test_a_foreign_call_above_exec_is_a_violation(self) -> None:
        report = _scan(
            {"src/mtest/report/console.mojo": 'external_call["write", Int]()\n'}
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn(
            "src/mtest/report/console.mojo:1: R5-external-call:", report.violations[0]
        )

    def test_a_symbol_on_the_line_after_the_bracket_is_read(self) -> None:
        report = _scan(
            {
                "src/mtest/report/console.mojo": (
                    'var rc = external_call[\n    "write",\n    Int,\n](fd)\n'
                )
            }
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn(
            "src/mtest/report/console.mojo:1: R5-external-call:", report.violations[0]
        )
        self.assertIn("write", report.violations[0])

    def test_the_import_of_the_intrinsic_is_not_a_call(self) -> None:
        report = _scan(
            {"src/mtest/exec/signals.mojo": "from std.ffi import external_call\n"}
        )

        self.assertEqual(report.violations, ())

    def test_an_aliased_foreign_call_above_exec_is_a_violation(self) -> None:
        # Without alias tracking neither line is seen: the import binds a name
        # the rule does not know, and the call subscripts that name.
        report = _scan(
            {
                "src/mtest/report/console.mojo": (
                    'from std.ffi import external_call as ffi\nffi["write", Int]()\n'
                )
            }
        )

        self.assertEqual(len(report.violations), 2)
        self.assertIn(
            "src/mtest/report/console.mojo:1: R5-external-call-import:",
            report.violations[0],
        )
        self.assertIn(
            "src/mtest/report/console.mojo:2: R5-external-call:", report.violations[1]
        )
        self.assertIn("write", report.violations[1])

    def test_importing_the_intrinsic_above_exec_is_a_violation(self) -> None:
        report = _scan(
            {"src/mtest/report/console.mojo": "from std.ffi import external_call\n"}
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("R5-external-call-import:", report.violations[0])

    def test_an_alias_does_not_launder_an_unsanctioned_exec_symbol(self) -> None:
        report = _scan(
            {
                "src/mtest/exec/signals.mojo": (
                    'from std.ffi import external_call as ffi\nffi["execve", Int32]()\n'
                )
            }
        )

        self.assertEqual(len(report.violations), 1)
        self.assertIn("R5-external-call:", report.violations[0])
        self.assertIn("execve", report.violations[0])

    def test_the_platform_layer_may_alias_the_intrinsic(self) -> None:
        report = _scan(
            {
                "src/mtest/platform/fs.mojo": (
                    'from std.ffi import external_call as ffi\nffi["chmod", Int32]()\n'
                )
            }
        )

        self.assertEqual(report.violations, ())

    def test_an_aliased_allowance_call_is_still_reconciled(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-layering-") as raw:
            root = Path(raw)
            _write(
                root,
                {
                    "src/mtest/exec/signals.mojo": (
                        "from std.ffi import external_call as ffi\n"
                        'ffi["kill", Int32]()\n'
                    )
                },
            )

            layering.check_foreign_allowance_is_live(root)


class DocstringRedHerringTests(unittest.TestCase):
    SOURCE = '''"""Run a session.

Examples:
    ```mojo
    from mtest.session import run_session
    from mtest.session.store import _slot
    from mtest.discover import walk
    ```

    A failing run makes `main` call `exit()` with the resolved code, and the
    boundary below reaches libc through `external_call["kill", ...]`.
"""
from mtest.config import RunnerConfig
'''

    def test_an_examples_block_triggers_no_rule(self) -> None:
        report = _scan({"src/mtest/report/console.mojo": self.SOURCE})

        self.assertEqual(report.violations, ())
        self.assertEqual(report.infos, ())

    def test_the_same_text_as_code_would_trigger(self) -> None:
        report = _scan(
            {"src/mtest/report/console.mojo": self.SOURCE.replace('"""', "", 2)}
        )

        self.assertNotEqual(report.violations, ())


class SymlinkedSourceTests(unittest.TestCase):
    def test_a_symlinked_module_is_still_judged(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-layering-") as raw:
            root = Path(raw)
            _write(
                root,
                {
                    "elsewhere/resolve.mojo": "from mtest.session import run\n",
                    "src/mtest/model/keep.mojo": "var x = 1\n",
                },
            )
            link = root / "src/mtest/config/resolve.mojo"
            link.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(root / "elsewhere/resolve.mojo", link)

            report = layering.scan(root)

        self.assertEqual(len(report.violations), 1)
        self.assertIn("src/mtest/config/resolve.mojo:1: R1-rank:", report.violations[0])


class FailClosedTests(unittest.TestCase):
    def test_a_tree_with_no_source_is_a_failure(self) -> None:
        with (
            tempfile.TemporaryDirectory(prefix="mtest-layering-") as raw,
            self.assertRaisesRegex(AssertionError, "no Mojo source"),
        ):
            layering.scan(Path(raw))

    def test_an_empty_rank_table_is_a_failure(self) -> None:
        with (
            mock.patch.object(layering, "RANK", {}),
            self.assertRaisesRegex(AssertionError, "intended inventory is empty"),
        ):
            layering.scan(layering.REPO_ROOT)


class RepositoryTests(unittest.TestCase):
    """The gate has teeth against the tree it guards, not only against toys."""

    def test_the_repository_root_tracks_the_nested_checker(self) -> None:
        self.assertEqual(layering.REPO_ROOT, Path(__file__).resolve().parents[2])

    def test_the_repository_has_no_layering_violation(self) -> None:
        report = layering.scan(layering.REPO_ROOT)

        self.assertEqual(list(report.violations), [])

    def test_dropping_a_layer_from_rank_reddens_the_real_tree(self) -> None:
        mutated = {
            name: rank for name, rank in layering.RANK.items() if name != "session"
        }

        with mock.patch.object(layering, "RANK", mutated):
            report = layering.scan(layering.REPO_ROOT)

        self.assertTrue(any("session" in line for line in report.violations))

    def test_every_facade_on_disk_is_in_the_inventory(self) -> None:
        # The nested one is the case the top-level-only lookup missed: its
        # exports are the surface a `mtest.session.store.*` import goes around.
        facades = layering.facade_packages(layering.source_files(layering.REPO_ROOT))

        self.assertIn("session.store", facades)
        self.assertIn(
            "STORE_DIR", layering.facade_exports(layering.REPO_ROOT, "session.store")
        )

    def test_the_rank_table_names_exactly_the_packages_on_disk(self) -> None:
        layering.check_rank_covers_the_tree(layering.REPO_ROOT)

    def test_a_rank_entry_with_no_package_on_disk_is_named(self) -> None:
        mutated = {**layering.RANK, "telemetry": 2}

        with (
            mock.patch.object(layering, "RANK", mutated),
            self.assertRaisesRegex(AssertionError, "telemetry"),
        ):
            layering.check_rank_covers_the_tree(layering.REPO_ROOT)

    def test_every_allowed_symbol_is_still_called(self) -> None:
        layering.check_foreign_allowance_is_live(layering.REPO_ROOT)

    def test_an_allowance_for_a_call_that_is_gone_is_named(self) -> None:
        mutated = {
            **layering.EXEC_LIBC_ALLOWANCE,
            "src/mtest/exec/paths.mojo": frozenset({"readlink"}),
        }

        with (
            mock.patch.object(layering, "EXEC_LIBC_ALLOWANCE", mutated),
            self.assertRaisesRegex(AssertionError, "readlink"),
        ):
            layering.check_foreign_allowance_is_live(layering.REPO_ROOT)

    def test_an_empty_allowance_fails_closed(self) -> None:
        with (
            mock.patch.object(layering, "EXEC_LIBC_ALLOWANCE", {}),
            self.assertRaisesRegex(AssertionError, "intended inventory is empty"),
        ):
            layering.check_foreign_allowance_is_live(layering.REPO_ROOT)

    def test_the_checker_passes_on_the_repository(self) -> None:
        # `main` prints the deep-import ledger, and this suite runs immediately
        # before the checker itself in `repo-policy-check`; without this the
        # ledger reaches a green run twice.
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            status = layering.main()

        self.assertEqual(status, 0)
        self.assertIn("layering-check: OK", printed.getvalue())


if __name__ == "__main__":
    unittest.main()
