"""Shared helpers for the `exec` tests (via `-I tests/support`, not a suite).

Small conveniences the exec tests share: turning captured raw bytes into a
`String` for readable assertions, counting bytes matching a value, and building
the `["python3", <script>, ...]` argv for a committed helper target.
"""
from mtest.exec import ProcessSpec


def bytes_to_str(b: List[UInt8]) -> String:
    """Render captured bytes as a `String` for assertions (valid UTF-8 here)."""
    return String(StringSlice(unsafe_from_utf8=Span(b)))


def repeat(s: String, n: Int) -> String:
    """`s` repeated `n` times. Pure."""
    var out = String("")
    for _ in range(n):
        out += s
    return out^


def count_byte(b: List[UInt8], value: UInt8) -> Int:
    """How many bytes in `b` equal `value`. Pure."""
    var n = 0
    for i in range(len(b)):
        if b[i] == value:
            n += 1
    return n


def target(name: String) -> String:
    """The repo-relative path of a committed exec helper target."""
    return String("tests/fixtures/exec/") + name


def py_spec(var argv: List[String], timeout_ms: Int = 0) -> ProcessSpec:
    """A spec running `python3` on the given argv (argv[0] is the script path).
    """
    var full = List[String]()
    full.append("python3")
    for i in range(len(argv)):
        full.append(argv[i])
    return ProcessSpec.command(full^, timeout_ms)
