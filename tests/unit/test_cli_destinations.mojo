"""Tests for the shared report-destination set, its refusals, and its labels."""
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    TestSuite,
)

from mtest.cli import FlagId, flag_specs
from mtest.cli.destinations import (
    Destination,
    active_destinations,
    destination_collision,
    destination_parent_error,
)
from mtest.config import (
    ActiveConfigKeys,
    CliOverlay,
    ConfigEnvironment,
    FileConfig,
    ResolvedConfig,
    RunnerConfig,
    resolve_config,
)

from tmptree import remove_tree, temp_root


def _from_cli(
    json_dest: String,
    junit_dest: String,
    md_dest: String,
    html_dest: String,
) -> ResolvedConfig:
    """Resolve the four destinations as the command line supplied them."""
    var overlay = CliOverlay.default()
    overlay.json_dest = json_dest.copy()
    overlay.saw_json = json_dest != ""
    overlay.junit_dest = junit_dest.copy()
    overlay.saw_junit_xml = junit_dest != ""
    overlay.report_md_dest = md_dest.copy()
    overlay.saw_report_md = md_dest != ""
    overlay.report_html_dest = html_dest.copy()
    overlay.saw_report_html = html_dest != ""
    return resolve_config(
        RunnerConfig.default(),
        FileConfig.empty(),
        ConfigEnvironment.empty(),
        overlay,
    )


def _from_file(
    json_dest: String,
    junit_dest: String,
    md_dest: String,
    html_dest: String,
    config_file: String,
) -> ResolvedConfig:
    """Resolve the four destinations as a project file supplied them."""
    var file = FileConfig.empty()
    file.json_dest = json_dest.copy()
    file.saw_json = json_dest != ""
    file.junit_dest = junit_dest.copy()
    file.saw_junit_xml = junit_dest != ""
    file.report_md_dest = md_dest.copy()
    file.saw_report_md = md_dest != ""
    file.report_html_dest = html_dest.copy()
    file.saw_report_html = html_dest != ""
    var resolved = resolve_config(
        RunnerConfig.default(),
        file,
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )
    resolved.config_file = config_file.copy()
    return resolved^


def test_active_destinations_keep_one_fixed_order() raises:
    var destinations = active_destinations(
        _from_cli("a.ndjson", "b.xml", "c.md", "d.html")
    )
    assert_equal(len(destinations), 4)
    assert_equal(destinations[0].format, "json")
    assert_equal(destinations[1].format, "junit-xml")
    assert_equal(destinations[2].format, "md")
    assert_equal(destinations[3].format, "html")
    assert_equal(destinations[0].path, "a.ndjson")
    assert_equal(destinations[3].path, "d.html")


def test_stdout_stream_and_absent_destinations_are_not_files() raises:
    """`--json -` names the inherited stream, which no file can collide with."""
    var stream = active_destinations(_from_cli("-", "", "", ""))
    assert_equal(len(stream), 0)
    var none = active_destinations(_from_cli("", "", "", ""))
    assert_equal(len(none), 0)


def test_inactive_keys_contribute_no_destination() raises:
    """A command whose projection drops the report keys opens none of them."""
    var resolved = _from_cli("a.ndjson", "b.xml", "c.md", "d.html")
    resolved.active_keys = ActiveConfigKeys.debug()
    assert_equal(len(active_destinations(resolved)), 0)


def test_parents_are_the_lexical_directory_of_each_destination() raises:
    var destinations = active_destinations(
        _from_cli("bare.ndjson", "src/b.xml", "./c.md", "/tmp/d.html")
    )
    assert_equal(destinations[0].parent, "")
    assert_equal(destinations[1].parent, "src")
    assert_equal(destinations[2].parent, ".")
    assert_equal(destinations[3].parent, "/tmp")


def _long_spelling(flag_id: Int) raises -> String:
    """The `--` spelling `flag_specs()` carries for one flag identity."""
    for spec in flag_specs():
        if spec.id == flag_id and spec.spelling.startswith("--"):
            return spec.spelling.copy()
    raise Error("no long spelling for flag id " + String(flag_id))


def test_command_line_labels_come_from_the_flag_table() raises:
    """A diagnostic must never name a flag the parser does not accept.

    Rebuilding the spelling from the `mtest.toml` key would do exactly that
    the first time a key and its flag stop matching, so the label is read off
    the same table the parser matches against.
    """
    var destinations = active_destinations(
        _from_cli("a.ndjson", "b.xml", "c.md", "d.html")
    )
    assert_equal(
        destinations[0].label, "cli: '" + _long_spelling(FlagId.JSON) + "'"
    )
    assert_equal(
        destinations[1].label,
        "cli: '" + _long_spelling(FlagId.JUNIT_XML) + "'",
    )
    assert_equal(
        destinations[2].label,
        "cli: '" + _long_spelling(FlagId.REPORT) + " md:'",
    )
    assert_equal(
        destinations[3].label,
        "cli: '" + _long_spelling(FlagId.REPORT) + " html:'",
    )
    # The spellings the table is expected to hold today, so a silent rename of
    # both sides at once still fails.
    assert_equal(destinations[0].label, "cli: '--json'")
    assert_equal(destinations[1].label, "cli: '--junit-xml'")
    assert_equal(destinations[2].label, "cli: '--report md:'")
    assert_equal(destinations[3].label, "cli: '--report html:'")


def test_project_file_labels_name_the_table_key_and_the_file() raises:
    var named = active_destinations(
        _from_file("a.ndjson", "b.xml", "c.md", "d.html", "ci/mtest.toml")
    )
    assert_equal(named[0].label, "config: ci/mtest.toml: [report] json")
    assert_equal(named[1].label, "config: ci/mtest.toml: [report] junit-xml")
    assert_equal(named[2].label, "config: ci/mtest.toml: [report] md")
    assert_equal(named[3].label, "config: ci/mtest.toml: [report] html")
    # An unnamed file still has to be nameable in the remedy.
    var unnamed = active_destinations(_from_file("", "", "c.md", "", ""))
    assert_equal(unnamed[0].label, "config: mtest.toml: [report] md")


def test_missing_parent_is_refused_with_the_layer_that_set_it() raises:
    var from_file = destination_parent_error(
        active_destinations(
            _from_file("", "", "no-such-directory/c.md", "", "mtest.toml")
        )
    )
    assert_true(from_file)
    assert_equal(
        from_file.value(),
        (
            "config: mtest.toml: [report] md destination parent directory does"
            " not exist: 'no-such-directory' (see mtest --help)"
        ),
    )
    var from_cli = destination_parent_error(
        active_destinations(_from_cli("", "no-such-directory/b.xml", "", ""))
    )
    assert_true(from_cli)
    assert_equal(
        from_cli.value(),
        (
            "cli: '--junit-xml' destination parent directory does not exist:"
            " 'no-such-directory' (see mtest --help)"
        ),
    )


def test_existing_and_absent_parents_are_accepted() raises:
    """A directory that is there, and a destination with no directory at all.

    The existing parent is a temp tree this test creates, so the verdict does
    not depend on where the harness was invoked from.
    """
    var root = temp_root()
    try:
        var existing = destination_parent_error(
            active_destinations(
                _from_cli("bare.ndjson", root + "/b.xml", "", "")
            )
        )
        assert_false(existing)
    finally:
        remove_tree(root)
    var empty = destination_parent_error(List[Destination]())
    assert_false(empty)


def test_two_spellings_of_one_file_are_refused() raises:
    var collision = destination_collision(
        active_destinations(_from_cli("out.txt", "./out.txt", "", ""))
    )
    assert_true(collision)
    assert_true("cli: '--json' and cli: '--junit-xml'" in collision.value())
    assert_true("name the same destination" in collision.value())
    assert_true("each report needs its own path" in collision.value())


def test_distinct_destinations_and_a_lone_one_never_collide() raises:
    var distinct = destination_collision(
        active_destinations(_from_cli("a.ndjson", "b.xml", "c.md", "d.html"))
    )
    assert_false(distinct)
    var lone = destination_collision(
        active_destinations(_from_cli("", "", "c.md", ""))
    )
    assert_false(lone)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
