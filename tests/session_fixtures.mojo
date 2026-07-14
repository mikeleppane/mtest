"""Tiny known-outcome Mojo fixtures for the session orchestration tests.

Not a test module (no `test_` prefix), so the runner never builds it as a
suite; it is imported via `-I tests`. Each helper writes a MINIMAL real Mojo
source into a temp tree so the session can genuinely build-and-execute it — the
only faithful way to exercise the keystone — and returns configs wired to that
tree. Keep every fixture as small as its outcome demands: build output lands
under the temp root's own `build/`, never the repo's.
"""
from std.os import makedirs
from std.os.path import dirname, exists
from std.tempfile import mkdtemp

from mtest.config import (
    ColorWhen,
    Precompile,
    RunnerConfig,
    ShowOutput,
    Verbosity,
)

# A binary that exits 0 -> PASS.
comptime SRC_PASS = "def main():\n    pass\n"
# A binary that exits nonzero (an uncaught raise) -> FAIL.
comptime SRC_FAIL = 'def main() raises:\n    raise Error("boom")\n'
# A binary that dies by SIGABRT -> CRASH (never a FAIL).
comptime SRC_CRASH = (
    "from std.ffi import external_call\n\n\ndef main():\n    _ ="
    ' external_call["abort", Int32]()\n'
)
# A source the compiler rejects -> COMPILE_ERROR (never a run outcome).
comptime SRC_COMPILE_ERROR = 'def main():\n    var x: Int = "nope"\n'
# A binary that never exits -> TIMEOUT under a deadline.
comptime SRC_HANG = "def main():\n    while True:\n        pass\n"


def temp_root() raises -> String:
    """Create and return a fresh, empty temp directory to use as a root."""
    return mkdtemp()


def write_file(root: String, rel: String, content: String) raises:
    """Write `content` to `root/rel`, creating parent directories as needed."""
    var full = root + "/" + rel
    var parent = dirname(full)
    if parent != "" and not exists(parent):
        makedirs(parent)
    with open(full, "w") as f:
        f.write(content)


def base_config() raises -> RunnerConfig:
    """A default config with a short 2-second run deadline for the fixtures."""
    var c = RunnerConfig.default()
    c.timeout_secs = 2
    return c^
