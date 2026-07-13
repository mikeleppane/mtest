"""The mtest runner package.

This package is intentionally EMPTY at this stage: the runner is built in
layers, and an empty package that compiles is the correct starting point, not a
placeholder to fill. Its only present job is to keep the `build` gate green so
that package rot is caught the moment it appears.

The planned layering is one-directional — every layer may import only from
layers above it, never sideways or downward:

    Layer 0  model     outcomes, node ids, events, exit codes  (no internal imports)
    Layer 1  config    RunnerConfig
    Layer 2  discover | protocol (report/collect parsing) | report (event consumers)
    Layer 3  exec      the POSIX process adapter, timeouts
    Layer 4  session   orchestration: discover -> build -> run -> parse -> events
    Layer 5  cli       hand-rolled argument parsing -> RunnerConfig; main

`exec` is the deepest module in the design: a small process-control interface
hiding pipes, concurrent draining, FFI, platform differences, and cleanup
invariants. The interface stays narrow even as the implementation absorbs that
complexity.
"""
