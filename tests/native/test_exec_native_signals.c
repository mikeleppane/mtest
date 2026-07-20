#define _POSIX_C_SOURCE 200809L

#include "../../native/mtest_exec_native.h"
#include "../../native/mtest_exec_native_test.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static volatile sig_atomic_t custom_seen;

static void custom_handler(int signal_number) {
    custom_seen = signal_number;
}

static struct mtest_exec_bytes bytes(const char *text) {
    struct mtest_exec_bytes value;
    value.data = (const uint8_t *)text;
    value.length = strlen(text);
    return value;
}

/* Re-executed through the adapter as a probe: report the SIGPIPE disposition
   this child INHERITED. Exit 0 iff it is the pristine default the parent set
   before the runtime opened; nonzero if it is the runtime's parent-local
   SIG_IGN carve-out. Runs before anything that could touch SIGPIPE. */
static int run_sigpipe_probe(void) {
    struct sigaction current;
    if (sigaction(SIGPIPE, NULL, &current) != 0) {
        return 2;
    }
    return current.sa_handler == SIG_DFL ? 0 : 1;
}

/* Open the runtime (installing the parent-local SIGPIPE=SIG_IGN carve-out),
   spawn the probe through the adapter, and require it to have inherited
   SIG_DFL -- proving the child region restored the pre-runtime disposition
   before execve. Returns 0 on success, 1 on any failure. The caller has
   already set SIGPIPE to SIG_DFL, so that is the disposition the runtime saves
   and the child must recover. */
static int check_child_sigpipe_restored(const char *self_path) {
    struct mtest_exec_error error;
    if (mtest_exec_runtime_open(&error) != 0) {
        fprintf(stderr, "sigpipe probe: runtime open failed\n");
        return 1;
    }

    struct mtest_exec_bytes probe_argv[2] = {
        bytes(self_path), bytes("__sigpipe_probe__")
    };
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = probe_argv;
    spec.argc = 2;

    struct mtest_exec_process_ref process;
    if (mtest_exec_process_open(&spec, &process, &error) != 0) {
        fprintf(stderr, "sigpipe probe: spawn failed\n");
        (void)mtest_exec_runtime_close(&error);
        return 1;
    }

    int waitable = 0;
    for (int attempt = 0; attempt < 500 && !waitable; ++attempt) {
        struct mtest_exec_observe_result observation;
        if (mtest_exec_process_observe(
                process.handle, &observation, &error
            ) != 0) {
            fprintf(stderr, "sigpipe probe: observe failed\n");
            (void)mtest_exec_runtime_close(&error);
            return 1;
        }
        waitable = observation.state == MTEST_EXEC_LEADER_WAITABLE;
        if (!waitable) {
            const struct timespec delay = {0, 1000000L};
            (void)nanosleep(&delay, NULL);
        }
    }
    if (!waitable) {
        fprintf(stderr, "sigpipe probe: leader never became waitable\n");
        (void)mtest_exec_runtime_close(&error);
        return 1;
    }

    /* Sweep the process group so the reaped handle can be consumed and the
       runtime closed cleanly (an unswept leader keeps the runtime pinned). */
    struct mtest_exec_group_result group;
    if (mtest_exec_process_group(
            process.handle, MTEST_EXEC_GROUP_KILL, &group, &error
        ) != 0) {
        fprintf(stderr, "sigpipe probe: group sweep failed\n");
        (void)mtest_exec_runtime_close(&error);
        return 1;
    }

    if (mtest_exec_process_channel_close(
            process.handle, MTEST_EXEC_CHANNEL_STDOUT, &error
        ) != 0 ||
        mtest_exec_process_channel_close(
            process.handle, MTEST_EXEC_CHANNEL_STDERR, &error
        ) != 0 ||
        mtest_exec_process_channel_close(
            process.handle, MTEST_EXEC_CHANNEL_SETUP, &error
        ) != 0) {
        fprintf(stderr, "sigpipe probe: channel close failed\n");
        (void)mtest_exec_runtime_close(&error);
        return 1;
    }

    struct mtest_exec_reap_result reap;
    if (mtest_exec_process_reap(process.handle, &reap, &error) != 0) {
        fprintf(stderr, "sigpipe probe: reap failed\n");
        (void)mtest_exec_runtime_close(&error);
        return 1;
    }
    if (mtest_exec_process_close(process.handle, &error) != 0) {
        fprintf(stderr, "sigpipe probe: process close failed\n");
        (void)mtest_exec_runtime_close(&error);
        return 1;
    }
    if (mtest_exec_runtime_close(&error) != 0) {
        fprintf(stderr, "sigpipe probe: runtime close failed\n");
        return 1;
    }

    if (reap.kind != MTEST_EXEC_REAP_EXITED || reap.value != 0) {
        fprintf(
            stderr,
            "child SIGPIPE was not restored to default: kind=%d value=%d "
            "(the exec'd binary inherited the runtime SIG_IGN carve-out)\n",
            (int)reap.kind,
            (int)reap.value
        );
        return 1;
    }
    return 0;
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

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "__sigpipe_probe__") == 0) {
        return run_sigpipe_probe();
    }
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
    if (mtest_exec_test_deliver_interrupt_after(
            MTEST_EXEC_OP_SIGACTION_INSTALL_INT, SIGINT
        ) != 0 ||
        mtest_exec_runtime_open(&error) != 0 ||
        mtest_exec_interrupt_requested() != 1 ||
        mtest_exec_runtime_close(&error) != 0) {
        fprintf(stderr, "interrupt delivered during open was not latched\n");
        return 1;
    }

    if (mtest_exec_runtime_open(&error) != 0 ||
        mtest_exec_interrupt_requested() != 0 ||
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

    /* The exec'd test binary must inherit the PRE-runtime SIGPIPE disposition,
       not the parent-local SIG_IGN carve-out. Establish a known SIG_DFL, spawn
       the probe through the adapter, and require the child to have seen SIG_DFL;
       restore the prior disposition afterwards. */
    struct sigaction dfl_pipe;
    struct sigaction old_pipe;
    memset(&dfl_pipe, 0, sizeof(dfl_pipe));
    dfl_pipe.sa_handler = SIG_DFL;
    if (sigemptyset(&dfl_pipe.sa_mask) != 0 ||
        sigaction(SIGPIPE, &dfl_pipe, &old_pipe) != 0) {
        perror("establish default SIGPIPE for the probe");
        return 1;
    }
    if (check_child_sigpipe_restored(argv[0]) != 0) {
        return 1;
    }
    if (sigaction(SIGPIPE, &old_pipe, NULL) != 0) {
        perror("restore SIGPIPE after the probe");
        return 1;
    }

    puts("signal-transaction: OK");
    return 0;
}
