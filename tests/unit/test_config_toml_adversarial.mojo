"""Focused adversarial regressions for the vendored native TOML parser."""
from std.testing import assert_equal, assert_false, assert_true

from mtest.config import parse_toml


def _rejects(text: String) raises:
    var result = parse_toml(text, "adversarial.toml")
    assert_false(result.is_ok)
    assert_equal(result.failure.exit_code(), 4)


def test_toml_10_basic_string_escapes_are_exact() raises:
    var slash = String(chr(92))
    var source = (
        '[run]\npaths = ["before'
        + slash
        + 'bafter", "before'
        + slash
        + 'fafter", "one'
        + slash
        + slash
        + 'slash"]\n'
    )
    var result = parse_toml(source, "escapes.toml")
    assert_true(result.is_ok, result.failure.render())
    assert_equal(result.config.paths[0], "before" + String(chr(8)) + "after")
    assert_equal(result.config.paths[1], "before" + String(chr(12)) + "after")
    assert_equal(result.config.paths[2], "one" + slash + "slash")


def test_toml_11_only_basic_string_escapes_are_rejected() raises:
    var slash = String(chr(92))
    _rejects('[run]\npaths = ["' + slash + "'\"]\n")
    _rejects('[run]\npaths = ["' + slash + 'e"]\n')
    _rejects('[run]\npaths = ["' + slash + 'x41"]\n')


def test_malformed_dotted_key_is_not_swallowed() raises:
    _rejects("run. = { timeout = 1 }\n")


def test_unrecognized_characters_raise_positioned_errors() raises:
    for character in ["@", "`", "?"]:
        var result = parse_toml(character, "unexpected-character.toml")
        assert_false(result.is_ok)
        assert_true("line 1, column 1" in result.failure.render())


def test_table_updates_hit_the_preparse_complexity_ceiling() raises:
    var source = String("")
    for index in range(65):
        source += "key" + String(index) + " = 0\n"
    var result = parse_toml(source, "many-assignments.toml")
    assert_false(result.is_ok)
    assert_true("table-update limit" in result.failure.render())

    source = ""
    for index in range(65):
        source += "[table" + String(index) + "]\n"
    result = parse_toml(source, "many-table-headers.toml")
    assert_false(result.is_ok)
    assert_true("table-update limit" in result.failure.render())


def test_duplicate_tables_and_inline_keys_are_rejected() raises:
    _rejects("[run]\ntimeout = 1\n[run]\nretries = 2\n")
    _rejects("run = { timeout = 1, timeout = 2 }\n")


def test_unterminated_and_control_bearing_strings_are_rejected() raises:
    _rejects('[run]\npaths = ["unterminated]\n')
    _rejects('[run]\npaths = ["raw\x01control"]\n')


def test_deep_inline_tables_are_rejected_without_recursing_unboundedly() raises:
    var value = String('"x"')
    for i in range(65):
        value = "{ k" + String(i) + " = " + value + " }"
    var result = parse_toml("run = " + value + "\n", "deep-inline.toml")
    assert_false(result.is_ok)
    assert_true("nesting limit" in result.failure.render())
