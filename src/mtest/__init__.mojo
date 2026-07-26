"""The mtest runner package: a pytest-like test runner for Mojo.

mtest orchestrates the standard library's per-file `std.testing.TestSuite`. A
TestSuite owns discovery, per-test selection, and the report format inside one
file. mtest owns everything between files: recursive discovery, building each
file, executing and supervising it as a subprocess, aggregating results, and
reporting for CI. Every test file is built and its binary executed directly,
because `mojo run` masks every outcome to `1`.

mtest is not an assertion library (assertions come from `std.testing`), not a
property-testing framework, and not a TestSuite replacement: it depends on
TestSuite's per-file protocol.

The runner is built in layers, and the layering is one-directional. Every
layer may import only from layers above it, never sideways or downward:

    Layer 0  model     outcomes, node ids, events, exit codes
    Layer 0  platform  the narrow platform-I/O boundary
    Layer 1  config    RunnerConfig
    Layer 2  discover | protocol (report/collect parsing) | report
             select (operand and name selection) | cache (build reuse)
    Layer 3  exec      the POSIX process adapter, timeouts
    Layer 4  session   orchestration: discover -> build -> run -> parse
    Layer 5  cli       hand-rolled argument parsing -> RunnerConfig

`main` sits above every layer as the composition root, not inside `cli`: it is
the only `exit()` caller, it wires the reporters and the session together, and
it owns argv, env, and exit and nothing else.

`exec` is the deepest module: a small process-control interface hiding pipes,
concurrent draining, FFI, platform differences, and cleanup invariants. Its
interface stays narrow even as the implementation absorbs that complexity.
"""
