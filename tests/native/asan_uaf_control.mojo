"""Deliberate native heap-use-after-free control for the ASan harness."""
from std.ffi import external_call


def main():
    """Call the testing adapter's ASan use-after-free probe."""
    # SAFETY: this test-only no-argument/void ABI retains no Mojo pointer. Its
    # native body deliberately reads freed memory and the harness requires abort.
    external_call["mtest_exec_test_asan_uaf", NoneType]()
