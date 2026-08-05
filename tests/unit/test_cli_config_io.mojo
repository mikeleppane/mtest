"""Tests for the configuration and last-run-state files `main` reads and writes.

Every case runs against a real temp tree, because what is under test is what the
filesystem answers: a path that is not there, a directory where a file was
promised, a payload over the ceiling, and a cache root that cannot be created.
"""
from std.os import makedirs, mkdir
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.cli.config_io import (
    STATE_MAX_BYTES,
    load_config,
    load_state,
    persist_state,
    state_path,
)
from mtest.config import TOML_SOURCE_MAX_BYTES
from mtest.model import EXIT_USAGE_ERROR

from tmptree import remove_tree, temp_root


def _write(path: String, text: String) raises:
    """Write `text` to `path`, replacing whatever was there."""
    with open(path, "w") as handle:
        handle.write(text)


def _read(path: String) raises -> String:
    """The complete contents of `path`."""
    with open(path, "r") as handle:
        return handle.read()


def _write_bytes(path: String, data: List[UInt8]) raises:
    """Write `data` verbatim to `path`, interpreting nothing."""
    with open(path, "w") as handle:
        handle.write_bytes(Span(data))


def _filler(size: Int) -> String:
    """A `size`-byte ASCII payload, doubled rather than appended byte by byte.

    The ceilings under test are megabytes, so a per-byte loop would dominate
    the module's runtime.
    """
    var out = String("#")
    while out.byte_length() < size:
        var half = out.copy()
        out += half
    return String(out[byte=0:size])


def test_no_config_selects_no_file_at_all() raises:
    """`--no-config` never names a file, so nothing can be refused."""
    var root = temp_root()
    try:
        _write(root + "/mtest.toml", "[run]\ntimeout = 1\n")
        var loaded = load_config(root, "", True)
        assert_equal(loaded.error, "")
        assert_equal(loaded.error_code, 0)
        assert_equal(loaded.config_file, "")
        assert_false(loaded.file.saw_timeout)
    finally:
        remove_tree(root)


def test_an_absent_default_file_is_not_an_error() raises:
    """A project without `mtest.toml` is ordinary, not a refusal."""
    var root = temp_root()
    try:
        var loaded = load_config(root, "", False)
        assert_equal(loaded.error, "")
        assert_equal(loaded.error_code, 0)
        assert_equal(loaded.config_file, "")
    finally:
        remove_tree(root)


def test_an_absent_explicit_file_is_a_usage_error() raises:
    """Naming a file that is not there is a typo the caller has to see."""
    var root = temp_root()
    try:
        var loaded = load_config(root, "ci/mtest.toml", False)
        assert_equal(loaded.error_code, EXIT_USAGE_ERROR)
        assert_equal(
            loaded.error,
            "config: ci/mtest.toml: configuration file does not exist",
        )
        # The representation survives the refusal, so `config show` and the
        # diagnostic name the same file.
        assert_equal(loaded.config_file, "ci/mtest.toml")
    finally:
        remove_tree(root)


def test_a_directory_at_the_config_path_is_refused() raises:
    """A directory opens and reads; only the file-type check catches it."""
    var root = temp_root()
    try:
        mkdir(root + "/mtest.toml")
        var loaded = load_config(root, "", False)
        assert_equal(loaded.error_code, EXIT_USAGE_ERROR)
        assert_equal(
            loaded.error,
            "config: mtest.toml: configuration path is not a regular file",
        )
    finally:
        remove_tree(root)


def test_a_config_file_over_the_ceiling_is_refused() raises:
    """The reader hands back one byte past the ceiling so this can be seen."""
    var root = temp_root()
    try:
        _write(root + "/mtest.toml", _filler(TOML_SOURCE_MAX_BYTES + 1))
        var loaded = load_config(root, "", False)
        assert_equal(loaded.error_code, EXIT_USAGE_ERROR)
        assert_equal(
            loaded.error,
            "config: mtest.toml: configuration file exceeds "
            + String(TOML_SOURCE_MAX_BYTES)
            + "-byte limit",
        )
    finally:
        remove_tree(root)


def test_a_malformed_file_carries_the_parser_diagnostic() raises:
    var root = temp_root()
    try:
        _write(root + "/mtest.toml", "[run]\ntimeout = 1 state = false\n")
        var loaded = load_config(root, "", False)
        assert_equal(loaded.error_code, EXIT_USAGE_ERROR)
        assert_true(loaded.error.startswith("config: mtest.toml: "))
        assert_equal(loaded.config_file, "mtest.toml")
    finally:
        remove_tree(root)


def test_a_file_that_cannot_be_read_as_text_is_refused() raises:
    """A read that raises is a refusal here, never an escaping error.

    A lone `0xFF` byte is not valid UTF-8 in any position, so the reader raises
    for every caller on every platform — no permission bit and no privilege
    level changes the answer.
    """
    var root = temp_root()
    try:
        _write_bytes(
            root + "/mtest.toml", [UInt8(91), UInt8(114), UInt8(255), UInt8(10)]
        )
        var loaded = load_config(root, "", False)
        assert_equal(loaded.error_code, EXIT_USAGE_ERROR)
        assert_equal(
            loaded.error,
            "config: mtest.toml: could not read configuration file",
        )
    finally:
        remove_tree(root)


def test_a_valid_file_is_parsed_and_named_relative_to_the_root() raises:
    var root = temp_root()
    try:
        makedirs(root + "/ci")
        _write(root + "/ci/mtest.toml", "[run]\ntimeout = 7\n")
        var loaded = load_config(root, "ci/mtest.toml", False)
        assert_equal(loaded.error, "")
        assert_equal(loaded.error_code, 0)
        assert_equal(loaded.config_file, "ci/mtest.toml")
        assert_true(loaded.file.saw_timeout)
        assert_equal(loaded.file.timeout_secs, 7)
    finally:
        remove_tree(root)


def test_a_file_outside_the_root_keeps_its_absolute_name() raises:
    """A path that is not under the root has no relative spelling to offer."""
    var root = temp_root()
    var elsewhere = temp_root()
    try:
        _write(elsewhere + "/other.toml", "[run]\ntimeout = 3\n")
        var loaded = load_config(root, elsewhere + "/other.toml", False)
        assert_equal(loaded.error, "")
        assert_equal(loaded.config_file, elsewhere + "/other.toml")
        assert_equal(loaded.file.timeout_secs, 3)
        # A `..` walk back into the root is normalized rather than kept.
        var walked = load_config(
            root, elsewhere + "/./sub/../other.toml", False
        )
        assert_equal(walked.config_file, elsewhere + "/other.toml")
    finally:
        remove_tree(root)
        remove_tree(elsewhere)


def test_state_path_hangs_under_the_cache_root() raises:
    assert_equal(state_path("/repo"), "/repo/.mtest-cache/lastrun")


def test_an_absent_state_file_is_silent() raises:
    """No state is the first run's ordinary condition, not a warning."""
    var root = temp_root()
    try:
        var loaded = load_state(root)
        assert_equal(len(loaded.state.records), 0)
        assert_equal(len(loaded.warnings), 0)
    finally:
        remove_tree(root)


def test_a_directory_at_the_state_path_is_ignored_loudly() raises:
    var root = temp_root()
    try:
        makedirs(state_path(root))
        var loaded = load_state(root)
        assert_equal(len(loaded.state.records), 0)
        assert_equal(len(loaded.warnings), 1)
        assert_equal(
            loaded.warnings[0],
            "state: .mtest-cache/lastrun: not a regular file — ignored",
        )
    finally:
        remove_tree(root)


def test_a_state_file_over_the_ceiling_is_ignored_loudly() raises:
    var root = temp_root()
    try:
        makedirs(root + "/.mtest-cache")
        _write(state_path(root), _filler(STATE_MAX_BYTES + 1))
        var loaded = load_state(root)
        assert_equal(len(loaded.state.records), 0)
        assert_equal(len(loaded.warnings), 1)
        assert_equal(
            loaded.warnings[0],
            "state: .mtest-cache/lastrun: exceeds the size limit — ignored",
        )
    finally:
        remove_tree(root)


def test_a_state_file_at_exactly_the_ceiling_is_still_read() raises:
    """The boundary belongs to the accepted side, so the refusal is exact.

    The payload carries no valid header, so what comes back is the header
    diagnostic — proof the size check let the file through rather than
    replacing that answer with its own.
    """
    var root = temp_root()
    try:
        makedirs(root + "/.mtest-cache")
        _write(state_path(root), _filler(STATE_MAX_BYTES))
        var loaded = load_state(root)
        assert_equal(len(loaded.warnings), 1)
        assert_true("mtest-lastrun v1" in loaded.warnings[0])
    finally:
        remove_tree(root)


def test_a_wrong_header_drops_every_record_with_one_warning() raises:
    var root = temp_root()
    try:
        makedirs(root + "/.mtest-cache")
        _write(state_path(root), "mtest-lastrun v9\nfile\ttests/a.mojo\n")
        var loaded = load_state(root)
        assert_equal(len(loaded.state.records), 0)
        assert_equal(len(loaded.warnings), 1)
        assert_true("mtest-lastrun v1" in loaded.warnings[0])
    finally:
        remove_tree(root)


def test_a_malformed_record_is_dropped_and_the_rest_kept() raises:
    """State narrows a selection, so one bad line costs one record."""
    var root = temp_root()
    try:
        makedirs(root + "/.mtest-cache")
        _write(
            state_path(root),
            "mtest-lastrun v1\nfile\ttests/a.mojo\nnonsense\n",
        )
        var loaded = load_state(root)
        assert_equal(len(loaded.state.records), 1)
        assert_equal(loaded.state.records[0].identifier, "tests/a.mojo")
        assert_equal(len(loaded.warnings), 1)
        assert_true("dropped malformed record" in loaded.warnings[0])
    finally:
        remove_tree(root)


def test_persisted_state_reads_back_and_the_cache_root_is_marked() raises:
    """Publication creates the cache root `--cache-clear` is allowed to delete.
    """
    var root = temp_root()
    try:
        var failure = persist_state(
            root, "mtest-lastrun v1\nfile\ttests/a.mojo\n"
        )
        assert_false(failure)
        assert_true(exists(root + "/.mtest-cache/CACHEDIR.TAG"))
        var loaded = load_state(root)
        assert_equal(len(loaded.warnings), 0)
        assert_equal(len(loaded.state.records), 1)
        assert_equal(loaded.state.records[0].identifier, "tests/a.mojo")
    finally:
        remove_tree(root)


def test_persisting_over_an_earlier_state_replaces_it() raises:
    var root = temp_root()
    try:
        var first = persist_state(root, "mtest-lastrun v1\nfile\tone.mojo\n")
        assert_false(first)
        # Read back before overwriting: a first write that silently did nothing
        # would leave the second one with nothing to replace, and the assertions
        # below would pass on an empty tree.
        var before = load_state(root)
        assert_equal(len(before.state.records), 1)
        assert_equal(before.state.records[0].identifier, "one.mojo")

        var failure = persist_state(root, "mtest-lastrun v1\nfile\ttwo.mojo\n")
        assert_false(failure)
        var loaded = load_state(root)
        assert_equal(len(loaded.state.records), 1)
        assert_equal(loaded.state.records[0].identifier, "two.mojo")
    finally:
        remove_tree(root)


def test_a_state_directory_that_cannot_be_created_is_reported() raises:
    """A file sitting where `.mtest-cache` belongs cannot be written through.

    The refusal is `ENOTDIR` from the temp creation rather than a permission
    denial, so the case holds for any user, root included. What is already at
    that path has to survive: a persistence that could not publish must leave
    the tree as it found it rather than clearing the way for itself.
    """
    var root = temp_root()
    try:
        _write(root + "/.mtest-cache", "not a directory")
        var failure = persist_state(root, "mtest-lastrun v1\n")
        assert_true(failure)
        assert_equal(
            failure.value(),
            "mtest: state: could not persist .mtest-cache/lastrun",
        )
        assert_equal(_read(root + "/.mtest-cache"), "not a directory")
    finally:
        remove_tree(root)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
