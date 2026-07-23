"""Production-shaped executable probe for lazy Mojo-to-Python interop.

The bridge import is linked into both execution paths.  The no-config path does
not call it and, on Linux, reads its own still-live process map before exit.
"""

from std.sys import argv
from std.sys.info import CompilationTarget

from tomllib_spike_bridge import parse_timeout


def _libpython_mapping_status() raises -> String:
    """Report whether this still-running process maps libpython on Linux."""
    comptime if CompilationTarget.is_macos():
        return String("unsupported")
    var maps = open("/proc/self/maps", "r").read()
    if "libpython" in maps:
        return String("true")
    return String("false")


def main() raises:
    """Exercise either the lazy no-config path or the tomllib bridge path.

    Raises:
        Error: If the arguments are invalid, the live process map cannot be
            read, or the Python/tomllib bridge cannot parse the config.
    """
    var args = argv()
    if len(args) != 2:
        raise Error("tomllib-spike: expected --no-config or --config")

    if args[1] == "--no-config":
        # This self-sample is deliberately the last work before returning, so
        # it describes the live no-config process rather than a dead child.
        print("libpython_mapped=" + _libpython_mapping_status())
        return

    if args[1] == "--config":
        var timeout = parse_timeout("[run]\ntimeout = 37\n")
        print("tomllib_timeout=" + String(timeout))
        return

    raise Error("tomllib-spike: expected --no-config or --config")
