"""The mtest runner package.

The runner is built in layers, and the layering is one-directional — every
layer may import only from layers above it, never sideways or downward:

    Layer 0  model     outcomes, node ids, events, exit codes
    Layer 1  config    RunnerConfig
    Layer 2  discover | protocol (report/collect parsing) | report
             select (operand and name selection) | cache (build reuse)
    Layer 3  exec      the POSIX process adapter, timeouts
    Layer 4  session   orchestration: discover -> build -> run -> parse
    Layer 5  cli       hand-rolled argument parsing -> RunnerConfig; main

`exec` is the deepest module: a small process-control interface hiding pipes,
concurrent draining, FFI, platform differences, and cleanup invariants. Its
interface stays narrow even as the implementation absorbs that complexity.
"""
