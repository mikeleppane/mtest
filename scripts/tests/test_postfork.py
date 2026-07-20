#!/usr/bin/env python3
"""Mutation tests for the native post-fork child call-graph audit."""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest
from unittest import mock

from scripts.checks import native_abi as native_abi_check
from scripts.checks import postfork as postfork_check


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "native" / "mtest_exec_native.c"


class PostforkCheckTests(unittest.TestCase):
    def test_repository_roots_are_exact(self) -> None:
        self.assertEqual(postfork_check.ROOT, ROOT)
        self.assertEqual(native_abi_check.ROOT, ROOT)

    def test_source_inventories_are_nonempty_and_exact(self) -> None:
        self.assertEqual(postfork_check.SOURCE, SOURCE)
        self.assertTrue(postfork_check.SOURCE.is_file())
        self.assertEqual(
            tuple(path.name for path in native_abi_check.SOURCE_FILES),
            (
                "mtest_exec_native.c",
                "mtest_exec_native.h",
                "mtest_exec_native_test.h",
            ),
        )
        self.assertGreater(len(native_abi_check.SOURCE_FILES), 0)

    def test_empty_native_abi_source_inventory_is_rejected(self) -> None:
        with mock.patch.object(native_abi_check, "SOURCE_FILES", ()):
            with self.assertRaisesRegex(SystemExit, "source inventory is empty"):
                native_abi_check.main()

    @classmethod
    def setUpClass(cls) -> None:
        cls.cc = native_abi_check.compiler()
        cls.source = SOURCE.read_text(encoding="utf-8")

    def audit_text(
        self,
        source: str,
        *,
        testing: bool = False,
        inline_header: str | None = None,
    ) -> postfork_check.AuditResult:
        with tempfile.TemporaryDirectory(prefix="mtest-postfork-test-") as raw_tmp:
            path = Path(raw_tmp) / SOURCE.name
            path.write_text(source, encoding="utf-8")
            if inline_header is not None:
                (path.parent / "mtest_child_inline.h").write_text(
                    inline_header,
                    encoding="utf-8",
                )
            return postfork_check.audit_source(path, testing=testing, cc=self.cc)

    def add_wrapper(self, definition: str, source: str | None = None) -> str:
        source = self.source if source is None else source
        marker = "static void mtest_child_exec(\n"
        self.assertEqual(source.count(marker), 1)
        source = source.replace(marker, definition + "\n\n" + marker)
        call_site = (
            "    if (mtest_fail_if_requested(MTEST_EXEC_OP_CHILD_SETPGID) ||\n"
        )
        self.assertEqual(source.count(call_site), 1)
        return source.replace(
            call_site, "    mtest_child_mutant();\n" + call_site
        )

    def assert_forbidden(self, source: str, callee: str) -> None:
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(source)
        self.assertIn(
            "mtest_child_exec -> mtest_child_mutant -> " + callee,
            str(raised.exception),
        )
        self.assertIn("forbidden post-fork call", str(raised.exception))
        self.assertRegex(str(raised.exception), r"at line [1-9][0-9]*")

    def test_real_source_has_exact_reviewed_platform_calls_in_both_variants(
        self,
    ) -> None:
        results = postfork_check.audit_variants(SOURCE, cc=self.cc)
        self.assertEqual([result.testing for result in results], [False, True])
        for result in results:
            self.assertEqual(
                set(result.platform_calls),
                postfork_check.platform_allowlist(),
            )
            self.assertIn("mtest_child_report", result.local_functions)
            self.assertIn("mtest_execve_checked", result.local_functions)
            self.assertIn("mtest_fail_if_requested", result.local_functions)

    def test_reviewed_platform_calls_exclude_unsafe_sleep(self) -> None:
        allowed = postfork_check.platform_allowlist()
        self.assertIn("poll", allowed)
        self.assertNotIn("nanosleep", allowed)

    def test_allocator_hidden_behind_local_wrapper_is_rejected(self) -> None:
        source = self.add_wrapper(
            "static void mtest_child_mutant(void) { (void)malloc(1); }"
        )
        self.assert_forbidden(source, "malloc")

    def test_allocator_in_outer_postfork_branch_is_rejected(self) -> None:
        marker = "    if (leader == 0) {\n"
        self.assertEqual(self.source.count(marker), 1)
        mutated = self.source.replace(
            marker,
            marker + "        (void)malloc(1);\n",
        )
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(mutated)
        message = str(raised.exception)
        self.assertIn("post-fork-child-branch -> malloc", message)
        self.assertIn("forbidden post-fork call", message)

    def test_allocator_between_fork_and_child_branch_is_rejected(self) -> None:
        marker = "        leader = fork();\n"
        self.assertEqual(self.source.count(marker), 1)
        mutated = self.source.replace(
            marker,
            marker + "        (void)malloc(1);\n",
        )
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(mutated)
        message = str(raised.exception)
        self.assertIn("post-fork-gap -> malloc", message)
        self.assertIn("forbidden post-fork call", message)

    def test_allocator_in_negative_guard_else_is_rejected(self) -> None:
        marker = "    if (leader == 0) {\n"
        self.assertEqual(self.source.count(marker), 1)
        mutated = self.source.replace(
            marker,
            "    else {\n        (void)malloc(1);\n    }\n" + marker,
        )
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(mutated)
        message = str(raised.exception)
        self.assertIn("post-fork-gap -> malloc", message)
        self.assertIn("forbidden post-fork call", message)

    def test_call_enclosing_fork_is_rejected(self) -> None:
        definition_marker = "int32_t mtest_exec_process_open(\n"
        self.assertEqual(self.source.count(definition_marker), 1)
        mutated = self.source.replace(
            definition_marker,
            (
                "static pid_t mtest_child_mutant(void *memory, pid_t child) {\n"
                "    free(memory);\n"
                "    return child;\n"
                "}\n\n"
                + definition_marker
            ),
        )
        fork_marker = "        leader = fork();\n"
        self.assertEqual(mutated.count(fork_marker), 1)
        mutated = mutated.replace(
            fork_marker,
            (
                "        leader = mtest_child_mutant(malloc(1), fork());\n"
            ),
        )
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(mutated)
        message = str(raised.exception)
        self.assertIn("post-fork-gap -> mtest_child_mutant -> free", message)
        self.assertIn("forbidden post-fork call", message)

    def test_implicit_cleanup_after_fork_is_rejected(self) -> None:
        definition_marker = "int32_t mtest_exec_process_open(\n"
        self.assertEqual(self.source.count(definition_marker), 1)
        mutated = self.source.replace(
            definition_marker,
            (
                "static void mtest_child_cleanup(void **slot) { free(*slot); }\n\n"
                + definition_marker
            ),
        )
        fork_marker = "        leader = fork();\n"
        self.assertEqual(mutated.count(fork_marker), 1)
        mutated = mutated.replace(
            fork_marker,
            (
                fork_marker
                + "        {\n"
                + "            void *owned __attribute__((cleanup(mtest_child_cleanup))) = NULL;\n"
                + "            (void)owned;\n"
                + "        }\n"
            ),
        )
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(mutated)
        message = str(raised.exception)
        self.assertIn("forbidden post-fork implicit cleanup", message)
        self.assertIn("post-fork-gap", message)

    def test_child_branch_without_terminal_exit_is_rejected(self) -> None:
        marker = "        _exit(127);\n    }\n\n    process->leader = leader;"
        self.assertEqual(self.source.count(marker), 1)
        mutated = self.source.replace(
            marker,
            "    }\n\n    process->leader = leader;",
        )
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(mutated)
        self.assertIn(
            "post-fork child branch must end in _exit",
            str(raised.exception),
        )

    def test_conditional_terminal_exit_is_rejected(self) -> None:
        marker = "        _exit(127);\n    }\n\n    process->leader = leader;"
        self.assertEqual(self.source.count(marker), 1)
        mutated = self.source.replace(
            marker,
            (
                "        if (leader != 0) {\n"
                "            _exit(127);\n"
                "        }\n"
                "    }\n\n    process->leader = leader;"
            ),
        )
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(mutated)
        self.assertIn(
            "post-fork child branch must end in _exit",
            str(raised.exception),
        )

    def test_wrong_child_branch_condition_is_rejected(self) -> None:
        marker = "    if (leader == 0) {\n"
        self.assertEqual(self.source.count(marker), 1)
        mutated = self.source.replace(marker, "    if (leader != 0) {\n")
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(mutated)
        self.assertIn(
            "post-fork child branch must be guarded by leader == 0",
            str(raised.exception),
        )

    def test_noncompound_child_branch_else_is_rejected(self) -> None:
        marker = "        _exit(127);\n    }\n\n    process->leader = leader;"
        self.assertEqual(self.source.count(marker), 1)
        mutated = self.source.replace(
            marker,
            (
                "        _exit(127);\n"
                "    } else\n"
                "        process->leader = leader;\n\n"
                "    process->leader = leader;"
            ),
        )
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(mutated)
        self.assertIn(
            "post-fork child branch must have exactly one body and no else",
            str(raised.exception),
        )

    def test_early_return_from_child_branch_is_rejected(self) -> None:
        marker = "        mtest_child_exec(\n"
        self.assertEqual(self.source.count(marker), 1)
        mutated = self.source.replace(marker, "        return -1;\n" + marker)
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(mutated)
        self.assertIn(
            "post-fork child branch must contain only mtest_child_exec then _exit",
            str(raised.exception),
        )

    def test_goto_from_child_branch_to_parent_code_is_rejected(self) -> None:
        child_marker = "        mtest_child_exec(\n"
        parent_marker = "    process->leader = leader;\n"
        self.assertEqual(self.source.count(child_marker), 1)
        self.assertEqual(self.source.count(parent_marker), 1)
        mutated = self.source.replace(
            child_marker,
            "        goto mtest_parent_only;\n" + child_marker,
        ).replace(
            parent_marker,
            "mtest_parent_only:\n" + parent_marker,
        )
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(mutated)
        self.assertIn(
            "post-fork child branch must contain only mtest_child_exec then _exit",
            str(raised.exception),
        )

    def test_formatter_call_is_rejected(self) -> None:
        source = self.source.replace(
            "#include <poll.h>\n", "#include <poll.h>\n#include <stdio.h>\n"
        )
        mutated = self.add_wrapper(
            "static void mtest_child_mutant(void) {\n"
            "    (void)dprintf(STDERR_FILENO, \"%s\", \"bad\");\n"
            "}",
            source,
        )
        self.assert_forbidden(mutated, "dprintf")

    def test_lock_call_is_rejected(self) -> None:
        source = self.source.replace(
            "#include <poll.h>\n", "#include <poll.h>\n#include <pthread.h>\n"
        )
        mutated = self.add_wrapper(
            "static void mtest_child_mutant(void) {\n"
            "    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;\n"
            "    (void)pthread_mutex_lock(&mutex);\n"
            "}",
            source,
        )
        self.assert_forbidden(mutated, "pthread_mutex_lock")

    def test_path_search_execvp_is_rejected(self) -> None:
        source = self.add_wrapper(
            "static void mtest_child_mutant(void) {\n"
            "    char *const args[] = {\"/bin/true\", NULL};\n"
            "    (void)execvp(args[0], args);\n"
            "}"
        )
        self.assert_forbidden(source, "execvp")

    def test_destructor_style_cleanup_is_rejected(self) -> None:
        source = self.add_wrapper(
            "static void mtest_child_mutant(void) { free(NULL); }"
        )
        self.assert_forbidden(source, "free")

    def test_indirect_call_is_rejected_fail_closed(self) -> None:
        source = self.add_wrapper(
            "static void mtest_child_mutant(void) {\n"
            "    void (*cleanup)(void *) = free;\n"
            "    cleanup(NULL);\n"
            "}"
        )
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(source)
        self.assertIn(
            "mtest_child_exec -> mtest_child_mutant -> <indirect-call>",
            str(raised.exception),
        )

    def test_function_returned_by_factory_is_rejected_as_indirect(self) -> None:
        source = self.add_wrapper(
            "static void mtest_child_bad(void) { free(NULL); }\n\n"
            "static void (*mtest_child_factory(void))(void) {\n"
            "    return mtest_child_bad;\n"
            "}\n\n"
            "static void mtest_child_mutant(void) {\n"
            "    mtest_child_factory()();\n"
            "}"
        )
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(source)
        self.assertIn(
            "mtest_child_exec -> mtest_child_mutant -> <indirect-call>",
            str(raised.exception),
        )

    def test_included_header_inline_is_not_trusted_as_local(self) -> None:
        source = self.source.replace(
            "#include <poll.h>\n",
            '#include <poll.h>\n#include "mtest_child_inline.h"\n',
        )
        mutated = self.add_wrapper(
            "static void mtest_child_mutant(void) {\n"
            "    (void)mtest_child_inline(1u);\n"
            "}",
            source,
        )
        expected_line = (
            mutated[: mutated.index("(void)mtest_child_inline")].count("\n")
            + 1
        )
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(
                mutated,
                inline_header=(
                    "static inline unsigned mtest_child_inline(unsigned value) {\n"
                    "    return value;\n"
                    "}\n"
                ),
            )
        message = str(raised.exception)
        self.assertIn(
            "mtest_child_exec -> mtest_child_mutant -> mtest_child_inline",
            message,
        )
        self.assertIn(f"at line {expected_line}", message)

    def test_unresolved_call_is_rejected_fail_closed(self) -> None:
        source = self.add_wrapper(
            "static void mtest_child_mutant(void) {\n"
            "    mtest_unknown_child_call();\n"
            "}"
        )
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(source)
        self.assertIn("post-fork AST compile failed", str(raised.exception))
        self.assertIn("mtest_unknown_child_call", str(raised.exception))

    def test_testing_only_fault_path_is_audited(self) -> None:
        marker = "static int mtest_fail_if_requested(uint32_t operation) {\n"
        self.assertEqual(self.source.count(marker), 2)
        source = self.source.replace(
            marker,
            marker + "    (void)malloc(1);\n",
            1,
        )
        production = self.audit_text(source, testing=False)
        self.assertNotIn("malloc", production.platform_calls)
        with self.assertRaises(postfork_check.AuditFailure) as raised:
            self.audit_text(source, testing=True)
        self.assertIn(
            "post-fork-gap -> mtest_fail_if_requested -> malloc",
            str(raised.exception),
        )


if __name__ == "__main__":
    unittest.main()
