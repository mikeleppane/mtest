#define _POSIX_C_SOURCE 200809L

#include "../../native/mtest_exec_native.h"
#include "../../native/mtest_exec_native_test.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void verify_main_repair_at_exit(void) {
    /* SAFETY: this atexit callback runs after main's single-threaded runtime
       path with no active child. Each native call borrows the complete aligned
       stack error record only for the call and initializes it before returning;
       no pointer is retained. The observed test-fault counter is ordinary
       process-global test state, and every successful reopen is explicitly
       closed before process termination. */
    struct mtest_exec_error error;
    uint32_t restore_attempts =
        mtest_exec_test_fault_seen(MTEST_EXEC_OP_SIGACTION_RESTORE_INT);
    mtest_exec_test_fault_reset();
    int initial_reopen = mtest_exec_runtime_open(&error);
    int repair = -2;
    int final_reopen = initial_reopen;
    if (initial_reopen != 0) {
        repair = mtest_exec_runtime_close(&error);
        final_reopen = repair == 0 ? mtest_exec_runtime_open(&error) : -2;
    }
    int reclose = final_reopen == 0
        ? mtest_exec_runtime_close(&error)
        : -2;
    fprintf(
        stderr,
        "main-open-probe: restore-attempts-before-atexit=%u "
        "initial-reopen=%d repair=%d final-reopen=%d reclose=%d\n",
        restore_attempts,
        initial_reopen,
        repair,
        final_reopen,
        reclose
    );
    (void)fflush(stderr);
}

__attribute__((constructor))
static void configure_main_open_failure(void) {
    /* SAFETY: the constructor runs single-threaded before Mojo main. The
       testing controls take scalar values only and retain no pointer. `atexit`
       retains a static function address valid for the full process lifetime;
       the callback touches only the testing adapter's process-global state. */
    mtest_exec_test_fault_reset();
    if (atexit(verify_main_repair_at_exit) != 0 ||
        mtest_exec_test_fault_configure(
            MTEST_EXEC_OP_SIGACTION_INSTALL_TERM, 1, EIO, 0
        ) != 0 ||
        mtest_exec_test_fault_configure(
            MTEST_EXEC_OP_SIGACTION_RESTORE_INT, 1, EPERM, 0
        ) != 0 ||
        mtest_exec_test_fault_configure_secondary(
            MTEST_EXEC_OP_SIGACTION_RESTORE_INT, 2, EIO, 0
        ) != 0) {
        fprintf(stderr, "main-open-probe: configuration failed\n");
        (void)fflush(stderr);
        _Exit(97);
    }
}
