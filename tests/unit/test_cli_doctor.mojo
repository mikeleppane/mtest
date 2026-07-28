"""Tests for the `doctor` subcommand and its narrow containment seams."""
from std.pathlib import cwd
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)

from mtest.cli import parse_args
from mtest.cli.doctor import (
    _doctor_cleanup_failure_probe,
    _doctor_close_failure_probe,
    _doctor_containment_probe,
    _doctor_exit_code,
    _doctor_platform_probe,
    _doctor_root_dependency_probe,
    _has_control,
    _safe_text,
    _toolchain_identity_is_pinned,
)
from mtest.config import ColorWhen, Verbosity


def test_doctor_kind_and_accepted_controls() raises:
    var argv: List[String] = [
        "doctor",
        "--config",
        "checks.toml",
        "--color",
        "never",
        "-v",
    ]
    var result = parse_args(argv)
    assert_true(result.is_doctor())
    assert_equal(result.config_path, "checks.toml")
    assert_true(result.config.color == ColorWhen.NEVER)
    assert_true(result.config.verbosity == Verbosity.VERBOSE)

    var disabled: List[String] = ["doctor", "--no-config", "-q"]
    var disabled_result = parse_args(disabled)
    assert_true(disabled_result.is_doctor())
    assert_true(disabled_result.no_config)
    assert_true(disabled_result.config.verbosity == Verbosity.QUIET)


def test_doctor_refuses_path_operands() raises:
    var argv: List[String] = ["doctor", "tests/"]
    with assert_raises(contains="doctor"):
        _ = parse_args(argv)


def test_doctor_refuses_passthrough_tokens() raises:
    var argv: List[String] = ["doctor", "--", "--debug-level=full"]
    with assert_raises(contains="doctor"):
        _ = parse_args(argv)


def test_doctor_refuses_run_and_build_flags() raises:
    var run_flag: List[String] = ["doctor", "--timeout", "1"]
    with assert_raises(contains="--timeout"):
        _ = parse_args(run_flag)
    var build_flag: List[String] = ["doctor", "--mojo", "mojo"]
    with assert_raises(contains="--mojo"):
        _ = parse_args(build_flag)


def test_doctor_refuses_selection_and_state_flags() raises:
    var selection: List[String] = ["doctor", "-k", "fast"]
    with assert_raises(contains="-k"):
        _ = parse_args(selection)
    var state: List[String] = ["doctor", "--lf"]
    with assert_raises(contains="--lf"):
        _ = parse_args(state)


def test_doctor_refuses_reporter_flags() raises:
    var json: List[String] = ["doctor", "--json", "-"]
    with assert_raises(contains="--json"):
        _ = parse_args(json)
    var junit: List[String] = ["doctor", "--junit-xml", "report.xml"]
    with assert_raises(contains="--junit-xml"):
        _ = parse_args(junit)
    var annotations: List[String] = [
        "doctor",
        "--gh-annotations",
        "off",
    ]
    with assert_raises(contains="--gh-annotations"):
        _ = parse_args(annotations)


def test_doctor_preserves_malformed_value_refusals() raises:
    var bad_color: List[String] = ["doctor", "--color", "sometimes"]
    with assert_raises(contains="auto|always|never"):
        _ = parse_args(bad_color)
    var missing_config: List[String] = ["doctor", "--config"]
    with assert_raises(contains="requires a value"):
        _ = parse_args(missing_config)


def test_doctor_preserves_allowed_control_conflicts() raises:
    var verbosity: List[String] = ["doctor", "-q", "-v"]
    with assert_raises(contains="'-q' and '-v' are mutually exclusive"):
        _ = parse_args(verbosity)
    var config: List[String] = [
        "doctor",
        "--config",
        "mtest.toml",
        "--no-config",
    ]
    with assert_raises(
        contains="'--config' and '--no-config' are mutually exclusive"
    ):
        _ = parse_args(config)


def test_doctor_contains_an_unexpected_throw_and_continues() raises:
    var report = _doctor_containment_probe()
    assert_equal(report.code, 1)
    assert_equal(len(report.lines), 3)
    assert_equal(report.lines[0], "PASS version: mtest containment")
    assert_equal(
        report.lines[1],
        "FAIL platform: unexpected error: injected\\nunexpected\\tthrow",
    )
    assert_true(report.lines[2].startswith("PASS root: "))


def test_doctor_requires_the_pinned_toolchain_identity() raises:
    assert_true(_toolchain_identity_is_pinned("Mojo 1.0.0b2 (2cf4d08a)"))
    assert_false(_toolchain_identity_is_pinned("Mojo 1.0.0b2 (deadbeef)"))
    assert_false(_toolchain_identity_is_pinned("compatible compiler"))
    assert_false(_toolchain_identity_is_pinned("Mojo 1.0.0b1 (deadbeef)"))
    assert_false(_toolchain_identity_is_pinned("Mojo 1.0.0b2"))
    assert_false(_toolchain_identity_is_pinned("Mojo 1.0.0b2 (DEADBEEF)"))
    assert_false(_toolchain_identity_is_pinned("Mojo 1.0.0b2 (deadbee)"))
    assert_false(_toolchain_identity_is_pinned("Mojo 1.0.0b2 (deadbeef0)"))


def test_doctor_config_dependency_is_truthful_without_a_root() raises:
    var disabled_argv: List[String] = ["doctor", "--no-config"]
    var disabled = _doctor_root_dependency_probe(parse_args(disabled_argv))
    assert_equal(disabled[0], "available")
    assert_equal(disabled[1], "FAIL toolchain: dependency exec unavailable")

    var relative_argv: List[String] = [
        "doctor",
        "--config",
        "mtest.toml",
    ]
    var relative = _doctor_root_dependency_probe(parse_args(relative_argv))
    assert_equal(relative[0], "dependency root unavailable")
    assert_equal(relative[1], "FAIL toolchain: dependency config unavailable")

    var missing_argv: List[String] = [
        "doctor",
        "--config",
        "/definitely-not-present-mtest-doctor.toml",
    ]
    var missing = _doctor_root_dependency_probe(parse_args(missing_argv))
    assert_equal(
        missing[0],
        (
            "config: /definitely-not-present-mtest-doctor.toml:"
            " configuration file does not exist"
        ),
    )
    assert_equal(missing[1], "FAIL toolchain: dependency config unavailable")

    var valid_path = String(cwd()) + "/e2e/config_project/mtest.toml"
    var valid_argv: List[String] = ["doctor", "--config", valid_path]
    var valid = _doctor_root_dependency_probe(parse_args(valid_argv))
    assert_equal(valid[0], "available")
    assert_equal(valid[1], "FAIL toolchain: dependency exec unavailable")


def test_doctor_final_interrupt_sample_selects_exit_two() raises:
    assert_equal(_doctor_exit_code(False, False, False), 0)
    assert_equal(_doctor_exit_code(True, False, False), 1)
    assert_equal(_doctor_exit_code(False, True, False), 2)
    assert_equal(_doctor_exit_code(False, False, True), 2)


def test_doctor_cleanup_refusal_names_the_unique_probe() raises:
    var detail = _doctor_cleanup_failure_probe()
    assert_true("injected primary probe failure" in detail)
    assert_true("cleanup could not remove unique probe" in detail)
    assert_true("injected cleanup remove refusal" in detail)
    assert_true(".mtest-doctor-cleanup." in detail)


def test_doctor_close_failure_replaces_the_exec_status() raises:
    assert_equal(
        _doctor_close_failure_probe(),
        "FAIL exec: runtime close failed (operation 7, errno 5)",
    )


def _repeated(unit: String, count: Int) -> String:
    var out = String("")
    for _ in range(count):
        out += unit
    return out^


def test_doctor_detail_over_the_bound_is_truncated_not_dropped() raises:
    """The bounded branch of the escaper had no coverage on any platform.

    It reads a borrowed view of the escaped text while building the shortened
    copy, which is the shape that aborted the vendored TOML integer scan on
    arm64. Exercising it keeps that shape under test instead of latent.
    """
    var under = _repeated("a", 240)
    assert_equal(_safe_text(under), under)
    assert_false("..." in _safe_text(under))

    var bounded = _safe_text(_repeated("b", 241))
    assert_equal(bounded.count_codepoints(), 240)
    assert_true(bounded.endswith("..."))
    assert_equal(bounded, _repeated("b", 237) + "...")

    # An escape expands one input codepoint into several, so the bound counts
    # escaped codepoints rather than source ones.
    var escaped = _safe_text(_repeated("\n", 200))
    assert_equal(escaped.count_codepoints(), 240)
    assert_true(escaped.endswith("..."))


def test_doctor_escaper_neutralizes_c1_controls() raises:
    """A C1 payload drives a terminal with no ESC byte anywhere in it.

    `U+009B` is CSI, `U+009D` is OSC and `U+009C` is ST in their
    single-code-point form, so a `--version` probe whose output doctor
    interpolates could repaint the screen or set the title through an escaper
    that only ever looked for ESC and the rest of C0.
    """
    assert_equal(_safe_text(chr(0x9B) + "2J"), "\\x9b2J")
    assert_equal(
        _safe_text(chr(0x9D) + "0;pwned" + chr(0x9C)), "\\x9d0;pwned\\x9c"
    )
    assert_equal(_safe_text(chr(0x80) + chr(0x9F)), "\\x80\\x9f")
    # Either side of the C1 block is ordinary text and rides through verbatim.
    assert_equal(_safe_text("~" + chr(0xA0) + "e"), "~" + chr(0xA0) + "e")


def test_doctor_control_probe_rejects_a_c1_only_identity() raises:
    """A toolchain identity made of C1 controls is unusable, not comparable.

    `_has_control` is the guard that stops such an identity being echoed back
    in the mismatch diagnostic at all, so it must cover exactly the range
    `_safe_text` escapes.
    """
    assert_true(_has_control(chr(0x9B)))
    assert_true(_has_control("mojo " + chr(0x9D) + "0;x"))
    assert_true(_has_control("mojo\x1b[31m"))
    assert_false(_has_control("mojo 1.0.0b2 (release)"))
    assert_false(_has_control("caf" + chr(0xE9) + chr(0xA0)))


def test_doctor_platform_lines_cover_both_supported_targets() raises:
    assert_equal(
        _doctor_platform_probe(False),
        "PASS platform: Linux x86_64 supported",
    )
    assert_equal(
        _doctor_platform_probe(True),
        "WARN platform: macOS arm64 supported; hosted runtime evidence pending",
    )


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
