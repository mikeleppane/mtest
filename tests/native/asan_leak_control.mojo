"""Deliberate native heap-leak control for the ASan/LSan harness."""
from std.ffi import external_call


def main():
    """Call the testing adapter's ASan leak probe."""
    # SAFETY: this test-only no-argument/void ABI retains no Mojo pointer. Its
    # native body deliberately leaks and the harness requires LSan termination.
    external_call["mtest_exec_test_asan_leak", NoneType]()
