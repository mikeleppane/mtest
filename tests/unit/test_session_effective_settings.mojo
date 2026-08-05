"""Pure per-file override resolution at the session boundary.

The config layer carries ordered override tables without matching them. These
tests pin the session's root-relative lookup: scalars use first-supplier wins,
CLI provenance suppresses only the corresponding scalar, and serial pinning is
a monotonic union across global globs and every matching table.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.config import (
    CliOverlay,
    ConfigEnvironment,
    FileConfig,
    OverrideRule,
    Provenance,
    ResolvedConfig,
    RunnerConfig,
    resolve_config,
)
from mtest.session.effective_settings import effective_file_settings
from mtest.session.pipeline import RunPipeline


def _rule(files: List[String]) -> OverrideRule:
    var rule = OverrideRule.empty()
    rule.files = files.copy()
    return rule^


def _resolved(
    overrides: List[OverrideRule],
    overlay: CliOverlay = CliOverlay.default(),
) -> ResolvedConfig:
    var defaults = RunnerConfig.default()
    defaults.timeout_secs = 30
    defaults.compile_timeout_secs = 60
    defaults.retries = 2
    defaults.serial_globs = ["tests/global_*.mojo"]
    var file = FileConfig.empty()
    file.overrides = overrides.copy()
    return resolve_config(
        defaults,
        file,
        ConfigEnvironment.empty(),
        overlay,
    )


def test_nonmatching_file_uses_global_values() raises:
    var rule = _rule(["tests/matched_*.mojo"])
    rule.timeout_secs = 7
    rule.saw_timeout = True
    rule.compile_timeout_secs = 8
    rule.saw_compile_timeout = True
    rule.retries = 9
    rule.saw_retries = True
    rule.serial = True
    rule.saw_serial = True

    var resolved = _resolved([rule.copy()])
    var settings = effective_file_settings(resolved, "tests/ordinary_test.mojo")

    assert_equal(settings.timeout_secs, 30)
    assert_equal(settings.compile_timeout_secs, 60)
    assert_equal(settings.retries, 2)
    assert_false(settings.serial)


def test_first_matching_supplier_wins_each_scalar() raises:
    var first = _rule(["tests/*.mojo"])
    first.timeout_secs = 7
    first.saw_timeout = True
    first.compile_timeout_secs = 8
    first.saw_compile_timeout = True
    first.retries = 1
    first.saw_retries = True
    var second = _rule(["tests/test_*.mojo"])
    second.timeout_secs = 70
    second.saw_timeout = True
    second.compile_timeout_secs = 80
    second.saw_compile_timeout = True
    second.retries = 10
    second.saw_retries = True

    var resolved = _resolved([first.copy(), second.copy()])
    var settings = effective_file_settings(resolved, "tests/test_one.mojo")

    assert_equal(settings.timeout_secs, 7)
    assert_equal(settings.compile_timeout_secs, 8)
    assert_equal(settings.retries, 1)


def test_later_matching_table_fills_earlier_omissions_independently() raises:
    var first = _rule(["tests/*.mojo"])
    first.timeout_secs = 7
    first.saw_timeout = True
    var second = _rule(["tests/test_*.mojo"])
    second.timeout_secs = 70
    second.saw_timeout = True
    second.compile_timeout_secs = 8
    second.saw_compile_timeout = True
    second.retries = 1
    second.saw_retries = True

    var resolved = _resolved([first.copy(), second.copy()])
    var settings = effective_file_settings(resolved, "tests/test_one.mojo")

    assert_equal(settings.timeout_secs, 7)
    assert_equal(settings.compile_timeout_secs, 8)
    assert_equal(settings.retries, 1)


def test_cli_provenance_suppresses_only_its_scalar() raises:
    var rule = _rule(["tests/*.mojo"])
    rule.timeout_secs = 7
    rule.saw_timeout = True
    rule.compile_timeout_secs = 8
    rule.saw_compile_timeout = True
    rule.retries = 1
    rule.saw_retries = True
    var overlay = CliOverlay.default()
    overlay.timeout_secs = 90
    overlay.saw_timeout = True
    overlay.compile_timeout_secs = 90
    overlay.saw_compile_timeout = True
    overlay.retries = 4
    overlay.saw_retries = True

    var resolved = _resolved([rule.copy()], overlay)
    var settings = effective_file_settings(resolved, "tests/test_one.mojo")

    assert_equal(settings.timeout_secs, 90)
    assert_equal(settings.compile_timeout_secs, 90)
    assert_equal(settings.retries, 4)


def test_non_cli_provenance_permits_scalar_overrides() raises:
    var rule = _rule(["tests/*.mojo"])
    rule.timeout_secs = 7
    rule.saw_timeout = True
    rule.compile_timeout_secs = 8
    rule.saw_compile_timeout = True
    rule.retries = 1
    rule.saw_retries = True
    var resolved = _resolved([rule.copy()])
    resolved.provenance.timeout_secs = Provenance.ENV_MTEST_MOJO
    resolved.provenance.compile_timeout_secs = Provenance.MTEST_TOML
    resolved.provenance.retries = Provenance.DEFAULT

    var settings = effective_file_settings(resolved, "tests/test_one.mojo")

    assert_equal(settings.timeout_secs, 7)
    assert_equal(settings.compile_timeout_secs, 8)
    assert_equal(settings.retries, 1)


def test_serial_false_cannot_unpin_a_global_serial_match() raises:
    var rule = _rule(["tests/global_*.mojo"])
    rule.serial = False
    rule.saw_serial = True

    var resolved = _resolved([rule.copy()])
    var settings = effective_file_settings(resolved, "tests/global_one.mojo")

    assert_true(settings.serial)


def test_serial_union_reaches_a_later_true_table() raises:
    var omitted = _rule(["tests/*.mojo"])
    var false_rule = _rule(["tests/test_*.mojo"])
    false_rule.serial = False
    false_rule.saw_serial = True
    var true_rule = _rule(["tests/test_one.mojo"])
    true_rule.serial = True
    true_rule.saw_serial = True

    var resolved = _resolved(
        [omitted.copy(), false_rule.copy(), true_rule.copy()]
    )
    var settings = effective_file_settings(resolved, "tests/test_one.mojo")

    assert_true(settings.serial)


def test_override_globs_share_discovery_fnmatch_semantics() raises:
    var rule = _rule(["tests/[ab]?/test_*.mojo"])
    rule.timeout_secs = 7
    rule.saw_timeout = True
    var resolved = _resolved([rule.copy()])

    assert_equal(
        effective_file_settings(
            resolved, "tests/ax/test_nested.mojo"
        ).timeout_secs,
        7,
    )
    assert_equal(
        effective_file_settings(
            resolved, "tests/cx/test_nested.mojo"
        ).timeout_secs,
        30,
    )


def test_pipeline_admits_each_files_effective_retry_budget() raises:
    var pipeline = RunPipeline.from_retry_budgets([0, 2], False, 0)

    assert_false(pipeline.admit_crash_retry(0))
    assert_true(pipeline.admit_crash_retry(1))
    assert_true(pipeline.admit_crash_retry(1))
    assert_false(pipeline.admit_crash_retry(1))


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
