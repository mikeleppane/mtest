#define _POSIX_C_SOURCE 200809L

#include "../../native/mtest_exec_native.h"
#include "../../native/mtest_exec_native_test.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>

static volatile sig_atomic_t custom_seen;

static void custom_handler(int signal_number) {
    custom_seen = signal_number;
}
static int matches_custom(int signal_number) {
    struct sigaction current;
    if (sigaction(signal_number, NULL, &current) != 0) {
        return 0;
    }
    return current.sa_handler == custom_handler &&
        (current.sa_flags & SA_RESTART) != 0 &&
        sigismember(&current.sa_mask, SIGUSR1) == 1;
}

int main(void) {
    struct sigaction old_int;
    struct sigaction old_term;
    struct sigaction old_chld;
    struct sigaction custom;
    struct mtest_exec_error error;
    memset(&custom, 0, sizeof(custom));
    custom.sa_handler = custom_handler;
    custom.sa_flags = SA_RESTART;
    if (sigemptyset(&custom.sa_mask) != 0 ||
        sigaddset(&custom.sa_mask, SIGUSR1) != 0 ||
        sigaction(SIGINT, &custom, &old_int) != 0 ||
        sigaction(SIGTERM, &custom, &old_term) != 0 ||
        sigaction(SIGCHLD, &custom, &old_chld) != 0) {
        perror("install custom handlers");
        return 1;
    }

    if (mtest_exec_test_fault_configure(
            MTEST_EXEC_OP_SIGACTION_INSTALL_TERM, 1, EIO, 0
        ) != 0 ||
        mtest_exec_runtime_open(&error) != -1 ||
        error.operation != MTEST_EXEC_OP_SIGACTION_INSTALL_TERM ||
        error.error_number != EIO ||
        !matches_custom(SIGINT) || !matches_custom(SIGTERM) ||
        !matches_custom(SIGCHLD)) {
        fprintf(stderr, "transactional install did not restore custom actions\n");
        return 1;
    }

    mtest_exec_test_fault_reset();
    if (mtest_exec_runtime_open(&error) != 0 ||
        mtest_exec_runtime_close(&error) != 0 ||
        !matches_custom(SIGINT) || !matches_custom(SIGTERM) ||
        !matches_custom(SIGCHLD)) {
        fprintf(stderr, "explicit close did not restore custom actions\n");
        return 1;
    }

    if (sigaction(SIGINT, &old_int, NULL) != 0 ||
        sigaction(SIGTERM, &old_term, NULL) != 0 ||
        sigaction(SIGCHLD, &old_chld, NULL) != 0) {
        perror("restore original handlers");
        return 1;
    }
    if (custom_seen != 0) {
        fprintf(stderr, "custom handler ran unexpectedly\n");
        return 1;
    }
    puts("signal-transaction: OK");
    return 0;
}
