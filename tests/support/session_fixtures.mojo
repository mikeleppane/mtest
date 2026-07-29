"""Tiny known-outcome Mojo fixtures for the session orchestration tests.

Not a test module (no `test_` prefix), so the runner never builds it as a
suite; it is imported via `-I tests/support`. Each helper writes a MINIMAL real Mojo
source into a temp tree so the session can genuinely build-and-execute it — the
only faithful way to exercise the keystone — and returns configs wired to that
tree. Keep every fixture as small as its outcome demands: build output lands
under the temp root's own `build/`, never the repo's.

`temp_root` is re-exported from `tmptree` — one scratch-root primitive for the
whole suite — so `from session_fixtures import temp_root` keeps working.

Two configs, not one. `base_config` is what a suite reaches for: real builds by
the real compiler, reached through a wrapper so the build cache keys something
cheap. `real_toolchain_config` names the compiler on PATH directly, and only
the handful of store suites whose subject is that key frame use it. Read
`base_config` for the argument.
"""
from std.os import getenv, makedirs
from std.os.path import dirname, exists

from tmptree import temp_root

from mtest.config import (
    ColorWhen,
    Precompile,
    RunnerConfig,
    ShowOutput,
    Verbosity,
)

# A real one-test TestSuite that passes -> a VALID report, exit 0 -> PASS.
# The session now PARSES each run's own report, so a report-BEARING fixture is
# the honest PASS case: `def main(): pass` prints no report and is MALFORMED.
comptime SRC_PASS = (
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_pass() raises:\n"
    "    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
# A real one-test TestSuite whose test fails -> a VALID report with a FAIL row
# and the failure trailer, exit 1 -> FAIL.
comptime SRC_FAIL = (
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_fail() raises:\n"
    "    assert_true(False)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
# A real TestSuite with THREE failing tests -> a VALID report with three FAIL
# rows -> the --maxfail overshoot fixture (one file contributes 3 to the
# failing-test count in a single scheduling step).
comptime SRC_FAIL_MULTI = (
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_fail_one() raises:\n"
    "    assert_true(False)\n\n\n"
    "def test_fail_two() raises:\n"
    "    assert_true(False)\n\n\n"
    "def test_fail_three() raises:\n"
    "    assert_true(False)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
# A binary that dies by SIGABRT -> CRASH (never a FAIL).
comptime SRC_CRASH = (
    "from std.ffi import external_call\n\n\ndef main():\n    _ ="
    ' external_call["abort", Int32]()\n'
)
# A source the compiler rejects -> COMPILE_ERROR (never a run outcome).
comptime SRC_COMPILE_ERROR = 'def main():\n    var x: Int = "nope"\n'
# A binary that never exits -> TIMEOUT under a deadline.
comptime SRC_HANG = "def main():\n    while True:\n        pass\n"

# --- The hostile handshake set: report-shaped adversaries. --------------------

# Compiles, runs, exits 0, prints NO report -> ABSENT -> MALFORMED_SUITE.
comptime SRC_SILENT = "def main():\n    pass\n"
# Runs a real suite TWICE, appending a second complete report block for the same
# path -> AMBIGUOUS -> MALFORMED_SUITE. (run() returns for a passing suite.)
comptime SRC_FORGER = (
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_one() raises:\n"
    "    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
# Runs a real suite, then hand-forges a trailing Summary the grammar rejects (a
# Summary with no rule before it) -> OFF_GRAMMAR -> DRIFT (exit 3). The
# sanctioned user-authored path to exit 3.
comptime SRC_LIAR = (
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_one() raises:\n"
    "    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
    '    print("Summary [ 0.00s ] 1 tests run: 1 passed , 0 failed ,'
    ' 0 skipped ")\n'
)
# A real suite that collects ZERO tests -> a VALID zero-test report, exit 0 ->
# PASS that ran zero tests (the closed zero-test ceiling, no longer PASS-from-
# exit-status).
comptime SRC_ZERO = (
    "from std.testing import TestSuite\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)


# --- Selection fixtures: distinct names for -k / --only, plus a chameleon. ----

# Three passing tests with distinct names -> a probe lists all three; `-k add`
# selects two, a node id selects one. Source order: add_one, add_two, sub_one.
comptime SRC_MATRIX = (
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_add_one() raises:\n    assert_true(True)\n\n\n"
    "def test_add_two() raises:\n    assert_true(True)\n\n\n"
    "def test_sub_one() raises:\n    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
# A passing and a failing test; selecting the failing one runs it under --only
# and reports FAIL while the passing one is deselected.
comptime SRC_MATRIX_FAIL = (
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_ok() raises:\n    assert_true(True)\n\n\n"
    "def test_bad() raises:\n    assert_true(False)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
# The chameleon: under --skip-all it lists test_real AND test_ghost, but under
# --only it registers only test_real, so `--only test_ghost` raises the stdlib's
# `… test not found in suite:`. The sanctioned proof that user code can refuse a
# name it just listed -> the loud recollect-once, then MALFORMED-SUITE.
comptime SRC_CHAMELEON = (
    "from std.sys import argv\n"
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_real() raises:\n    assert_true(True)\n\n\n"
    "def test_ghost() raises:\n    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    var has_only = False\n"
    "    for a in argv():\n"
    '        if a == "--only":\n'
    "            has_only = True\n"
    "    var s = TestSuite()\n"
    "    s.test[test_real]()\n"
    "    if not has_only:\n"
    "        s.test[test_ghost]()\n"
    "    s^.run()\n"
)


# A chameleon whose stale-name RECOVERY re-probe dies by signal. The first
# --skip-all lists both tests and drops a marker in the invocation root; the
# --only run then refuses the ghost it just listed, driving recover-once. The
# rebuild reproduces the same binary from the same source, so the second
# --skip-all sees the marker and aborts -> the recovery probe is terminal CRASH.
# That file must still reach the crash-attribution post-pass.
comptime SRC_CHAMELEON_PROBE_CRASH = (
    "from std.sys import argv\n"
    "from std.ffi import external_call\n"
    "from std.os.path import exists\n"
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_real() raises:\n    assert_true(True)\n\n\n"
    "def test_ghost() raises:\n    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    var probing = False\n"
    "    var has_only = False\n"
    "    for a in argv():\n"
    '        if a == "--skip-all":\n'
    "            probing = True\n"
    '        if a == "--only":\n'
    "            has_only = True\n"
    "    if probing:\n"
    '        if exists("probe_crash_marker"):\n'
    '            _ = external_call["abort", Int32]()\n'
    '        with open("probe_crash_marker", "w") as f:\n'
    '            f.write("1")\n'
    "    var s = TestSuite()\n"
    "    s.test[test_real]()\n"
    "    if not has_only:\n"
    "        s.test[test_ghost]()\n"
    "    s^.run()\n"
)


# A chameleon whose stale-name RECOVERY re-probe RENAMES the universe, so the
# re-selection under `-k old` collapses to EMPTY, and the recovery run then dies
# by signal. The first --skip-all lists test_old + test_alpha and drops a marker;
# `-k old` selects test_old, so mtest runs `--only test_old`, which the suite
# refuses (it registers only test_new under a selection) -> recover-once. The
# rebuild's re-probe sees the marker and now lists ONLY test_new, so re-selecting
# `-k old` yields nothing; the recovery run executes a bare `--only` and aborts.
# The crash MUST be attributed against the ORIGINAL selection [test_old], which
# does not intersect the renamed universe [test_new] -> NO_REPRODUCTION, no
# culprit. Attributing against the empty re-selection instead would widen to the
# whole universe and falsely name test_new — a test the run deselected.
comptime SRC_CHAMELEON_RENAME_CRASH = (
    "from std.sys import argv\nfrom std.ffi import external_call\nfrom"
    " std.os.path import exists\nfrom std.testing import TestSuite,"
    " assert_true\n\n\ndef test_old() raises:\n    assert_true(True)\n\n\ndef"
    " test_alpha() raises:\n    assert_true(True)\n\n\ndef test_new() raises:\n"
    "    assert_true(True)\n\n\ndef main() raises:\n    var probing = False\n  "
    "  var old_named = False\n    for a in argv():\n        if a =="
    ' "--skip-all":\n            probing = True\n        if a == "test_old":\n '
    '           old_named = True\n    var renamed = exists("rename_marker")\n  '
    "  if probing:\n        if not renamed:\n            # Write the marker"
    " BEFORE building the suite: TestSuite is\n            # explicit-destroy,"
    " so a raising `open` between its\n            # construction and `run()`"
    " would abandon it (a compile error).\n            with"
    ' open("rename_marker", "w") as f:\n                f.write("1")\n         '
    "   var s = TestSuite()\n            s.test[test_old]()\n           "
    " s.test[test_alpha]()\n            s^.run()\n        else:\n           "
    " var s = TestSuite()\n            s.test[test_new]()\n           "
    " s^.run()\n        return\n    if old_named:\n        # A selection run"
    " naming test_old: register a set WITHOUT it so the\n        # stdlib"
    " refuses the name it just listed -> the stale-name path.\n        var s ="
    " TestSuite()\n        s.test[test_new]()\n        s^.run()\n       "
    " return\n    # A bare --only (empty re-selection) or an isolation --only"
    " test_new:\n    # die by signal so the run, and any isolation rerun, is a"
    ' CRASH.\n    _ = external_call["abort", Int32]()\n'
)


# A real one-test suite that, under --skip-all, prints a complete exact-path
# all-SKIP report (in the retained HEAD) and THEN floods stdout far past the
# capture bound, so the genuine report is lost to truncation and only junk
# survives in the tail. The probe must REFUSE the forged head report under
# truncation (capture-overflow), never list `test_real`, never exit 0.
comptime SRC_FLOOD_PROBE = (
    "from std.testing import TestSuite, assert_true\n\n\ndef test_real()"
    " raises:\n    assert_true(True)\n\n\ndef main() raises:\n   "
    " TestSuite.discover_tests[__functions_in_module()]().run()\n    var unit ="
    " String(\n       "
    ' "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"\n   '
    ' )\n    var chunk = String("")\n    for i in range(1024):\n        chunk'
    " += unit\n    for i in range(200):\n        print(chunk)\n"
)
# Clean under --skip-all (a qualifying two-test collection), but under --only it
# runs the suite and THEN hand-forges a trailing Summary the grammar rejects ->
# the selected RUN is OFF_GRAMMAR -> DRIFT (exit 3), matching the default path.
comptime SRC_ONLY_LIAR = (
    "from std.sys import argv\n"
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_one() raises:\n    assert_true(True)\n\n\n"
    "def test_two() raises:\n    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    var has_only = False\n"
    "    for a in argv():\n"
    '        if a == "--only":\n'
    "            has_only = True\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
    "    if has_only:\n"
    '        print("Summary [ 0.00s ] 1 tests run: 1 passed , 0 failed ,'
    ' 0 skipped ")\n'
)
# Clean under --skip-all, but under --only it runs the suite and THEN floods
# stdout past the capture bound -> the selected RUN is capture-overflow ->
# CAPTURE_OVERFLOW (exit-1 class), matching the default path.
comptime SRC_ONLY_FLOOD = (
    "from std.sys import argv\nfrom std.testing import TestSuite,"
    " assert_true\n\n\ndef test_one() raises:\n    assert_true(True)\n\n\ndef"
    " test_two() raises:\n    assert_true(True)\n\n\ndef main() raises:\n   "
    ' var has_only = False\n    for a in argv():\n        if a == "--only":\n  '
    "          has_only = True\n   "
    " TestSuite.discover_tests[__functions_in_module()]().run()\n    if"
    " has_only:\n        var unit = String(\n           "
    ' "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"\n     '
    '   )\n        var chunk = String("")\n        for i in range(1024):\n     '
    "       chunk += unit\n        for i in range(200):\n           "
    " print(chunk)\n"
)
# A genuinely FAILING test that also PRINTS the stale-name phrase in its own
# body. The run produces a VALID FAIL report AND the phrase appears in stdout;
# an anchored stale-name check must treat this as a normal per-test FAIL, never
# as a stale-name refusal (which would discard the failing test's identity).
comptime SRC_FAIL_PHRASE = (
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_prints_phrase_and_fails() raises:\n"
    '    print("test not found in suite: not really")\n'
    "    assert_true(False)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)


def write_file(root: String, rel: String, content: String) raises:
    """Write `content` to `root/rel`, creating parent directories as needed."""
    var full = root + "/" + rel
    var parent = dirname(full)
    if parent != "" and not exists(parent):
        makedirs(parent)
    with open(full, "w") as f:
        f.write(content)


comptime PASSTHROUGH_MOJO = "/scripts/fixtures/toolchain/logging_mojo.py"
"""The transparent compiler wrapper, relative to the repository root.

`logging_mojo.py` appends a line to `MTEST_MOJO_LOG` when that variable is set
and then `execv`s the real `mojo` found on PATH with the untouched argv. With
the variable unset — which is the state every Mojo test module runs in, since
none of them sets it — the log step is skipped and nothing but the exec
remains, so exit code, stdout, and stderr are the real compiler's byte for
byte. Its own docstring states that pass-through as the contract, and the e2e
selection scenario has depended on it since before these suites did.
"""


def passthrough_mojo() -> String:
    """The transparent compiler wrapper's path, or `"mojo"` when it is missing.

    A caller gets the real compiler's behavior either way. The wrapper is
    preferred because it is what the compiler frame of a cache key ends up
    digesting, and a two-kilobyte script is a different proposition from the
    toolchain executable itself; see `base_config` for why that matters here.

    The fallback keeps the fixture honest outside a pixi shell, where
    `PIXI_PROJECT_ROOT` is unset and the path cannot be formed. Falling back to
    the bare spelling costs the digest and changes no outcome, whereas
    returning an unresolvable path would disable the cache in every suite and
    fail the ones that assert it is on.

    Returns:
        An absolute path to the wrapper when the repository root is known and
        the wrapper is there, and the bare spelling `"mojo"` otherwise.

    Examples:

    ```mojo
    from session_fixtures import passthrough_mojo

    var config = RunnerConfig.default()
    config.mojo_path = passthrough_mojo()
    ```
    """
    var repo = getenv("PIXI_PROJECT_ROOT", "")
    if repo == "":
        return String("mojo")
    var wrapper = repo + PASSTHROUGH_MOJO
    if not exists(wrapper):
        return String("mojo")
    return wrapper^


def real_toolchain_config() raises -> RunnerConfig:
    """`base_config`, but keyed against the toolchain executable itself.

    The config `base_config` hands back names a wrapper, so the toolchain frame
    of every key it produces describes that wrapper rather than the compiler on
    PATH. A test whose subject IS that frame — the digest of the real
    executable, the directory of libraries shipped beside it, or the memo that
    holds either — has to say so, and this is how it says it. Everything else
    is `base_config`'s, deadline included.

    Returns:
        A config whose `mojo_path` is the contract default, the bare spelling
        `"mojo"`, resolved through PATH exactly as a user's run resolves it.

    Raises:
        Error: Never; it mirrors `base_config`'s signature.

    Examples:

    ```mojo
    from session_fixtures import real_toolchain_config

    var ctx = env_base(real_toolchain_config(), temp_root())
    ```
    """
    var c = base_config()
    c.mojo_path = String("mojo")
    return c^


def base_config() raises -> RunnerConfig:
    """A default config that compiles for real, keyed against a cheap compiler.

    Two departures from `RunnerConfig.default()`, each for its own reason.

    **The compiler is the transparent wrapper.** The build cache is on by
    default, so every session driven from this config collects a key base, and
    the toolchain frame of that base is the digest of `mojo_path`'s bytes. The
    pinned toolchain executable is upwards of a hundred megabytes; the digest
    is computed in Mojo, and the classified suites are compiled without
    optimization, which is the combination that makes reading and hashing it
    the single largest fixed item in a session suite's runtime — larger, in
    most of these suites, than every real compile they perform put together.
    A process-lifetime memo bounds that without removing it, and it bounds it
    less than it looks: the memo is a SINGLE slot keyed on path and length, so
    a suite that points one test at a fixture shim and the next back at the
    real compiler evicts the entry and pays the whole read and hash again.
    Measured against this suite, the modules that alternate that way paid twice.
    Nor can one module share a payment with another, since every classified
    module is its own program.

    Nothing outside the store suites asserts anything about that frame's
    CONTENTS. `passthrough_mojo` therefore names a wrapper that execs the real
    compiler, which leaves every one of those suites keying, probing,
    publishing, and reusing exactly as before over a compiler whose bytes are
    cheap to read. The builds are the real compiler's, so outcomes, captured
    output, and the version banner are unchanged; nothing beside the wrapper
    looks like a toolchain, which the store records as a plain absence and
    keeps the cache on for. Tests whose subject IS that frame use
    `real_toolchain_config` and say so in their names.

    **The deadline is raised.** It is a *safety net*, not a subject. Every
    fixture here either aborts, exits, or reports within milliseconds once its
    child reaches `main()`, so the only thing this bound has to clear is the
    cost of spawning a freshly linked Mojo binary and initializing its runtime.

    That cost is not small and it is not stable. Measured on a 32-core box:
    a probe child reaches `main()` in well under a millisecond when the
    machine is idle, but with 16 concurrent session suites each spawning
    their own compiler and probe children it can exceed **two seconds**. A
    2-second deadline therefore turned every non-TIMEOUT outcome assertion in
    this suite into a race — `test_recovery_probe_crash_still_reaches_crash_attribution`
    lost it in roughly 1 of 5 full runs, reporting TIMEOUT where the fixture
    had aborted and the test asserted CRASH.

    30 seconds clears that startup cost by more than an order of magnitude
    while still bounding a genuinely hung child to well under the module's own
    runtime.

    A test that wants the deadline to *fire* must say so, and every such test
    already does: `test_deadline_overrun_is_timeout_not_fail` and
    `test_hanging_probe_times_out_exit_1` — the only two consumers of
    `SRC_HANG` — both set `timeout_secs = 1` themselves. Never lower this
    default to make one test trip its deadline; set it on that test's config.

    Returns:
        A config wired to the transparent wrapper, with the raised deadline and
        every other field at its contract default.

    Raises:
        Error: Never; the signature is `raises` for its callers' convenience.
    """
    var c = RunnerConfig.default()
    c.timeout_secs = 30
    c.mojo_path = passthrough_mojo()
    return c^
