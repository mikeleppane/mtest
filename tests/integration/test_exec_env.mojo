"""Per-child environment extension proven end-to-end through the real adapter.

The process spec carries an `env_extra` list of `KEY=VALUE` overrides. The C
adapter validates and merges them replace-not-append onto the inherited
environment before `execve`, and PATH-based candidate resolution reads the merged
environment. These tests prove that behavior as the child actually observes it —
via an env-echo actor that prints its full `os.environ` and a bare-name probe
that only resolves when a `PATH=` override points at its directory:

- a `KEY=VALUE` extra ARRIVES in the child;
- the FULL inherited environment survives the extension (PATH/HOME still present,
  and a grandchild resolves `mojo` through the inherited PATH);
- an extra REPLACES an inherited key with no surviving duplicate;
- a `PATH=` extra GOVERNS which executable a bare name resolves to.

Count 0 keeps the inherited snapshot untouched, so a spec with no extras is the
unchanged baseline.
"""
from std.testing import assert_equal, assert_true, assert_false

from mtest.exec import (
    ExecRuntime,
    ProcessSpec,
    ProcessResult,
    canonicalize,
    run_supervised,
)
from mtest.exec.spec import DEFAULT_GRACE_MS

from exec_helpers import bytes_to_str, target


def _run(var spec: ProcessSpec) raises -> ProcessResult:
    """Open a fresh runtime, run one child to completion, and close the runtime.
    """
    var runtime = ExecRuntime()
    runtime.open()
    var r = run_supervised(runtime, spec)
    runtime.close()
    return r^


def _env_spec(script: String, var env_extra: List[String]) -> ProcessSpec:
    """A `python3 <fixture script>` spec carrying `env_extra` overrides."""
    var argv = List[String]()
    argv.append("python3")
    argv.append(target(script))
    return ProcessSpec(argv^, None, 0, DEFAULT_GRACE_MS, env_extra^)


def _cmd_spec(
    var argv: List[String], var env_extra: List[String]
) -> ProcessSpec:
    """A direct `argv` spec (no interpreter) carrying `env_extra` overrides."""
    return ProcessSpec(argv^, None, 0, DEFAULT_GRACE_MS, env_extra^)


def _key_line_count(text: String, key: String) raises -> Int:
    """How many `KEY=...` lines `text` holds for exactly this key."""
    var prefix = key + "="
    var n = 0
    for line in text.split("\n"):
        if String(line).startswith(prefix):
            n += 1
    return n


def _contains_line(text: String, wanted: String) -> Bool:
    """Whether `text` holds `wanted` as a complete `\\n`-delimited line."""
    return ("\n" + wanted + "\n") in ("\n" + text)


def test_zero_env_extra_preserves_inherited_environment() raises:
    # Count 0 reproduces the v1 environment snapshot: the child still inherits
    # PATH and HOME and no injected key appears.
    var r = _run(_env_spec("env_echo.py", List[String]()))
    assert_true(r.termination.is_exited(), String(r.termination))
    var out = bytes_to_str(r.stdout_bytes)
    assert_true(_key_line_count(out, "PATH") >= 1, out)
    assert_true(_key_line_count(out, "HOME") >= 1, out)
    assert_false(_contains_line(out, "MTEST_ENVX=surprise-value"), out)


def test_env_extra_entry_arrives_in_child() raises:
    # (a) An injected extra reaches the child exactly once.
    var extras = List[String]()
    extras.append("MTEST_ENVX=surprise-value")
    var r = _run(_env_spec("env_echo.py", extras^))
    assert_true(r.termination.is_exited(), String(r.termination))
    var out = bytes_to_str(r.stdout_bytes)
    assert_true(_contains_line(out, "MTEST_ENVX=surprise-value"), out)
    assert_equal(_key_line_count(out, "MTEST_ENVX"), 1)


def test_full_inherited_environment_survives_extension() raises:
    # (b) Extending merges into, never replaces, the inherited environment: the
    # injected key AND the inherited PATH/HOME all reach the child together.
    var extras = List[String]()
    extras.append("MTEST_ENVX=surprise-value")
    var r = _run(_env_spec("env_echo.py", extras^))
    assert_true(r.termination.is_exited(), String(r.termination))
    var out = bytes_to_str(r.stdout_bytes)
    assert_true(_contains_line(out, "MTEST_ENVX=surprise-value"), out)
    assert_true(_key_line_count(out, "PATH") >= 1, out)
    assert_true(_key_line_count(out, "HOME") >= 1, out)


def test_inherited_path_resolves_grandchild_mojo() raises:
    # (b) The inherited PATH is functionally usable, not scrubbed: a grandchild
    # resolves `mojo` through it and runs `mojo --version` to a clean exit 0.
    # Exit 44 would mean PATH could not locate the binary.
    var extras = List[String]()
    extras.append("MTEST_ENVX=surprise-value")
    var r = _run(_env_spec("path_resolver.py", extras^))
    assert_true(r.termination.is_exited(), String(r.termination))
    assert_equal(r.termination.value, 0)


def test_env_extra_replaces_inherited_key_without_duplicate() raises:
    # (c) An extra whose key is already inherited REPLACES it: the child observes
    # exactly the new value and its environ carries no inherited duplicate.
    var base_r = _run(_env_spec("env_echo.py", List[String]()))
    var baseline = bytes_to_str(base_r.stdout_bytes)
    assert_true(_key_line_count(baseline, "HOME") >= 1, baseline)
    assert_false(
        _contains_line(baseline, "HOME=/mtest-env-override-sentinel"), baseline
    )

    var extras = List[String]()
    extras.append("HOME=/mtest-env-override-sentinel")
    var r = _run(_env_spec("env_echo.py", extras^))
    assert_true(r.termination.is_exited(), String(r.termination))
    var out = bytes_to_str(r.stdout_bytes)
    assert_true(_contains_line(out, "HOME=/mtest-env-override-sentinel"), out)
    assert_equal(_key_line_count(out, "HOME"), 1)


def test_path_extra_governs_candidate_resolution() raises:
    # (d) A `PATH=` extra steers candidate resolution: a bare name that lives
    # only under the override directory resolves and runs.
    var dir = canonicalize("tests/fixtures/exec")
    var extras = List[String]()
    extras.append("PATH=" + dir)
    var argv = List[String]()
    argv.append("path_probe.sh")
    var r = _run(_cmd_spec(argv^, extras^))
    assert_true(r.termination.is_exited(), String(r.termination))
    assert_equal(r.termination.value, 0)
    var out = bytes_to_str(r.stdout_bytes)
    assert_true("PATH_PROBE_RAN" in out, out)


def test_bare_probe_unresolvable_without_path_override() raises:
    # Control for (d): without the override the same bare name is on no inherited
    # PATH entry, so resolution fails — the success above is attributable to the
    # override PATH, not to the probe being findable anyway.
    var argv = List[String]()
    argv.append("path_probe.sh")
    var r = _run(_cmd_spec(argv^, List[String]()))
    assert_true(r.termination.is_spawn_failed(), String(r.termination))
