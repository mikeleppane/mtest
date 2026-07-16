"""Deliberate native heap-buffer-overflow control for the ASan harness."""
from std.ffi import external_call


def main():
    """Call the testing adapter's ASan out-of-bounds probe."""
    # SAFETY: this test-only no-argument/void ABI retains no Mojo pointer. Its
    # native body deliberately writes OOB and the harness requires ASan abort.
    external_call["mtest_exec_test_asan_oob", NoneType]()
