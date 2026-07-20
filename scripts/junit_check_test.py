#!/usr/bin/env python3
"""Unit tests for the JUnit schema/arithmetic gate.

These synthesize small <testsuite>/<testsuites> fragments directly (no XSD
involved) to pin the arithmetic and structural invariants precisely, then
exercise the full checker (schema plus arithmetic) end-to-end against the two
committed fixtures — proving the broken one is REJECTED before the faithful
mock is accepted.
"""

from __future__ import annotations

import unittest
from pathlib import Path
from xml.etree import ElementTree as ET

from scripts import junit_check


FIXTURES = Path(__file__).resolve().parent / "fixtures" / "junit"
BROKEN_FIXTURE = FIXTURES / "mock-broken.xml"
MOCK_FIXTURE = FIXTURES / "mock.xml"


def _suite(fragment: str) -> ET.Element:
    return ET.fromstring(fragment)


class SuiteArithmeticTests(unittest.TestCase):
    def test_consistent_counts_including_sentinel_rows_are_clean(self) -> None:
        suite = _suite(
            '<testsuite name="s" tests="3" failures="1" errors="0" skipped="0">'
            '<testcase name="[build]"/>'
            '<testcase name="t1"/>'
            '<testcase name="t2"><failure type="E"/></testcase>'
            "</testsuite>"
        )
        totals, findings = junit_check.suite_arithmetic(suite)
        self.assertEqual(findings, [])
        self.assertEqual(totals, junit_check.SuiteTotals(3, 1, 0, 0))

    def test_flaky_only_testcase_counts_as_passing(self) -> None:
        suite = _suite(
            '<testsuite name="s" tests="1" failures="0" errors="0" skipped="0">'
            '<testcase name="t1"><flakyFailure type="E"/></testcase>'
            "</testsuite>"
        )
        _, findings = junit_check.suite_arithmetic(suite)
        self.assertEqual(findings, [])

    def test_error_with_rerun_error_counts_once_against_errors(self) -> None:
        suite = _suite(
            '<testsuite name="s" tests="1" failures="0" errors="1" skipped="0">'
            '<testcase name="t1"><error type="E"/><rerunError type="E"/></testcase>'
            "</testsuite>"
        )
        totals, findings = junit_check.suite_arithmetic(suite)
        self.assertEqual(findings, [])
        self.assertEqual(totals.errors, 1)

    def test_declared_tests_mismatch_is_reported(self) -> None:
        suite = _suite(
            '<testsuite name="mismatch" tests="9" failures="0" errors="0" skipped="0">'
            '<testcase name="t1"/>'
            "</testsuite>"
        )
        totals, findings = junit_check.suite_arithmetic(suite)
        self.assertEqual(totals, junit_check.SuiteTotals(1, 0, 0, 0))
        self.assertEqual(len(findings), 1)
        self.assertIn("mismatch", findings[0])
        self.assertIn("declared", findings[0])

    def test_declared_failures_mismatch_is_reported(self) -> None:
        suite = _suite(
            '<testsuite name="s" tests="1" failures="1" errors="0" skipped="0">'
            '<testcase name="t1"/>'
            "</testsuite>"
        )
        _, findings = junit_check.suite_arithmetic(suite)
        self.assertEqual(len(findings), 1)

    def test_build_and_attempts_sentinels_together_is_rejected(self) -> None:
        suite = _suite(
            '<testsuite name="s" tests="2" failures="0" errors="0" skipped="0">'
            '<testcase name="[build]"/>'
            '<testcase name="[attempts]"/>'
            "</testsuite>"
        )
        _, findings = junit_check.suite_arithmetic(suite)
        self.assertEqual(len(findings), 1)
        self.assertIn("[build]", findings[0])
        self.assertIn("[attempts]", findings[0])

    def test_build_sentinel_alone_is_accepted(self) -> None:
        suite = _suite(
            '<testsuite name="s" tests="1" failures="0" errors="0" skipped="0">'
            '<testcase name="[build]"/>'
            "</testsuite>"
        )
        _, findings = junit_check.suite_arithmetic(suite)
        self.assertEqual(findings, [])


class RootArithmeticTests(unittest.TestCase):
    def test_root_totals_matching_sum_of_suites_is_clean(self) -> None:
        root = _suite(
            '<testsuites name="mtest" tests="2" failures="1" errors="0">'
            '<testsuite name="a" tests="1" failures="1" errors="0" skipped="0">'
            '<testcase name="t1"><failure type="E"/></testcase>'
            "</testsuite>"
            '<testsuite name="b" tests="1" failures="0" errors="0" skipped="1">'
            '<testcase name="t2"><skipped/></testcase>'
            "</testsuite>"
            "</testsuites>"
        )
        summed, findings = junit_check.root_arithmetic(root)
        self.assertEqual(findings, [])
        self.assertEqual(summed, junit_check.SuiteTotals(2, 1, 0, 1))

    def test_root_skipped_attribute_present_is_rejected(self) -> None:
        root = _suite(
            '<testsuites name="mtest" tests="0" failures="0" errors="0" skipped="0">'
            "</testsuites>"
        )
        _, findings = junit_check.root_arithmetic(root)
        self.assertEqual(len(findings), 1)
        self.assertIn("skipped", findings[0])

    def test_root_tests_mismatch_against_summed_suites_is_rejected(self) -> None:
        root = _suite(
            '<testsuites name="mtest" tests="99" failures="0" errors="0">'
            '<testsuite name="a" tests="1" failures="0" errors="0" skipped="0">'
            '<testcase name="t1"/>'
            "</testsuite>"
            "</testsuites>"
        )
        _, findings = junit_check.root_arithmetic(root)
        self.assertEqual(len(findings), 1)
        self.assertIn("root tests=99", findings[0])

    def test_root_arithmetic_propagates_suite_level_findings(self) -> None:
        root = _suite(
            '<testsuites name="mtest" tests="2" failures="0" errors="0">'
            '<testsuite name="bad" tests="2" failures="0" errors="0" skipped="0">'
            '<testcase name="[build]"/>'
            '<testcase name="[attempts]"/>'
            "</testsuite>"
            "</testsuites>"
        )
        _, findings = junit_check.root_arithmetic(root)
        self.assertEqual(len(findings), 1)
        self.assertIn("bad", findings[0])


class CheckerFixtureTests(unittest.TestCase):
    """The checker's evidence pair: reject the broken fixture, accept the mock."""

    def test_a_rejects_the_broken_fixture(self) -> None:
        with self.assertRaises(junit_check.CheckFailure) as raised:
            junit_check.check_artifact(BROKEN_FIXTURE)
        self.assertIn("skipped", str(raised.exception))

    def test_b_accepts_the_faithful_mock(self) -> None:
        summed = junit_check.check_artifact(MOCK_FIXTURE)
        self.assertEqual(summed, junit_check.SuiteTotals(9, 1, 1, 1))

    def test_xmllint_runs_hermetically_against_the_vendored_schema(self) -> None:
        result = junit_check.run_xmllint(MOCK_FIXTURE)
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
