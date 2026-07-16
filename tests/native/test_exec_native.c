#define _POSIX_C_SOURCE 200809L

#include "../../native/mtest_exec_native.h"
#include "../../native/mtest_exec_native_test.h"

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define CHECK(condition, message) do { \
    if (!(condition)) { \
        fprintf(stderr, "adapter-smoke: %s (line %d)\n", message, __LINE__); \
        return 1; \
    } \
} while (0)

static struct mtest_exec_bytes bytes(const char *text) {
    struct mtest_exec_bytes value;
    value.data = (const uint8_t *)text;
    value.length = strlen(text);
    return value;
}
static int drain_channel(
    uint64_t handle,
    uint32_t channel,
    char *capture,
    size_t capacity,
    size_t *length,
    int *eof
) {
    uint8_t buffer[64];
    struct mtest_exec_read_result result;
    struct mtest_exec_error error;
    if (*eof) {
        return 0;
    }
    if (mtest_exec_process_read(
            handle, channel, buffer, sizeof(buffer), &result, &error
        ) != 0) {
        fprintf(stderr, "read failed: channel=%u op=%u errno=%d\n",
                channel, error.operation, error.error_number);
        return -1;
    }
    if (result.state == MTEST_EXEC_READ_EOF) {
        *eof = 1;
        return 0;
    }
    if (result.state == MTEST_EXEC_READ_BYTES) {
        if (result.count > capacity - *length - 1) {
            fprintf(stderr, "capture overflow\n");
            return -1;
        }
        memcpy(capture + *length, buffer, (size_t)result.count);
        *length += (size_t)result.count;
        capture[*length] = '\0';
    }
    return 0;
}

static int exercise_process(void) {
    struct mtest_exec_bytes argv[] = {
        bytes("/bin/sh"),
        bytes("-c"),
        bytes("printf out; printf err >&2; exit 7")
    };
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = sizeof(argv) / sizeof(argv[0]);

    struct mtest_exec_process_ref process;
    struct mtest_exec_error error;
    CHECK(mtest_exec_process_open(&spec, &process, &error) == 0,
          "process open");

    struct mtest_exec_process_ref second;
    CHECK(mtest_exec_process_open(&spec, &second, &error) == -1,
          "second active child rejected");
    CHECK(error.error_number == EBUSY, "second active child reports EBUSY");

    struct mtest_exec_setup_state setup;
    memset(&setup, 0, sizeof(setup));
    char stdout_capture[64] = {0};
    char stderr_capture[64] = {0};
    size_t stdout_length = 0;
    size_t stderr_length = 0;
    int stdout_eof = 0;
    int stderr_eof = 0;
    int waitable = 0;

    for (int attempt = 0; attempt < 500 && !waitable; ++attempt) {
        struct mtest_exec_poll_result poll_result;
        CHECK(mtest_exec_process_poll(
                  process.handle, 10, &poll_result, &error
              ) == 0,
              "process poll");
        CHECK(mtest_exec_process_setup_drain(
                  process.handle, &setup, &error
              ) == 0,
              "setup drain");
        CHECK(drain_channel(
                  process.handle, MTEST_EXEC_CHANNEL_STDOUT,
                  stdout_capture, sizeof(stdout_capture),
                  &stdout_length, &stdout_eof
              ) == 0,
              "stdout drain");
        CHECK(drain_channel(
                  process.handle, MTEST_EXEC_CHANNEL_STDERR,
                  stderr_capture, sizeof(stderr_capture),
                  &stderr_length, &stderr_eof
              ) == 0,
              "stderr drain");
        struct mtest_exec_observe_result observation;
        CHECK(mtest_exec_process_observe(
                  process.handle, &observation, &error
              ) == 0,
              "waitid observation");
        waitable = observation.state == MTEST_EXEC_LEADER_WAITABLE;
    }
    CHECK(waitable, "leader became waitable");

    struct mtest_exec_group_result group;
    CHECK(mtest_exec_process_group(
              process.handle, MTEST_EXEC_GROUP_KILL, &group, &error
          ) == 0,
          "group sweep");

    for (int attempt = 0;
         attempt < 100 && (!stdout_eof || !stderr_eof ||
                           setup.outcome == MTEST_EXEC_SETUP_WAITING);
         ++attempt) {
        struct mtest_exec_poll_result poll_result;
        CHECK(mtest_exec_process_poll(
                  process.handle, 10, &poll_result, &error
              ) == 0,
              "post-observe poll");
        CHECK(mtest_exec_process_setup_drain(
                  process.handle, &setup, &error
              ) == 0,
              "post-observe setup drain");
        CHECK(drain_channel(
                  process.handle, MTEST_EXEC_CHANNEL_STDOUT,
                  stdout_capture, sizeof(stdout_capture),
                  &stdout_length, &stdout_eof
              ) == 0,
              "post-observe stdout drain");
        CHECK(drain_channel(
                  process.handle, MTEST_EXEC_CHANNEL_STDERR,
                  stderr_capture, sizeof(stderr_capture),
                  &stderr_length, &stderr_eof
              ) == 0,
              "post-observe stderr drain");
    }
    CHECK(stdout_eof && stderr_eof, "both output channels reached EOF");
    CHECK(setup.outcome == MTEST_EXEC_SETUP_EXEC_SUCCEEDED,
          "setup protocol reports exec success");

    struct mtest_exec_reap_result reap;
    CHECK(mtest_exec_process_reap(process.handle, &reap, &error) == 0,
          "waitpid reap");
    CHECK(reap.kind == MTEST_EXEC_REAP_EXITED && reap.value == 7,
          "exact exit status 7");

    for (int attempt = 0; attempt < 100; ++attempt) {
        CHECK(mtest_exec_process_group(
                  process.handle, MTEST_EXEC_GROUP_KILL, &group, &error
              ) == 0,
              "final group probe");
        if (group.state == MTEST_EXEC_GROUP_GONE) {
            break;
        }
        const struct timespec delay = {0, 1000000L};
        (void)nanosleep(&delay, NULL);
    }
    CHECK(group.state == MTEST_EXEC_GROUP_GONE, "process group is gone");
    CHECK(strcmp(stdout_capture, "out") == 0, "stdout byte fidelity");
    CHECK(strcmp(stderr_capture, "err") == 0, "stderr byte fidelity");
    CHECK(mtest_exec_process_close(process.handle, &error) == 0,
          "process close");
    return 0;
}

int main(void) {
    struct mtest_exec_error error;
    CHECK(mtest_exec_native_abi_version() == MTEST_EXEC_NATIVE_ABI_VERSION,
          "ABI version");
    CHECK(mtest_exec_interrupt_requested() == 0,
          "interrupt is initially clear");
    CHECK(mtest_exec_runtime_open(&error) == 0, "runtime open");
    CHECK(mtest_exec_runtime_open(&error) == -1 &&
              error.error_number == EBUSY,
          "second active runtime rejected");
    CHECK(kill(getpid(), SIGINT) == 0, "deliver SIGINT");
    CHECK(mtest_exec_interrupt_requested() == 1, "SIGINT latches");
    mtest_exec_test_reset_interrupt();
    CHECK(mtest_exec_interrupt_requested() == 0, "test reset re-arms");
    CHECK(kill(getpid(), SIGTERM) == 0, "deliver SIGTERM");
    CHECK(mtest_exec_interrupt_requested() == 1, "SIGTERM latches");
    mtest_exec_test_reset_interrupt();

    int64_t now = 0;
    CHECK(mtest_exec_monotonic_ms(&now, &error) == 0 && now > 0,
          "monotonic clock");
    CHECK(exercise_process() == 0, "real process supervision seam");

    struct mtest_exec_bytes fault_argv[1] = {bytes("/bin/true")};
    struct mtest_exec_process_spec fault_spec;
    memset(&fault_spec, 0, sizeof(fault_spec));
    fault_spec.argv = fault_argv;
    fault_spec.argc = 1;
    struct mtest_exec_process_ref fault_process;
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_FD_CLOEXEC, 2, EIO, 0
          ) == 0,
          "configure occurrence-specific fd fault");
    CHECK(mtest_exec_process_open(
              &fault_spec, &fault_process, &error
          ) == -1,
          "second adapter-local fcntl occurrence fails");
    CHECK(error.operation == MTEST_EXEC_OP_FD_CLOEXEC &&
              error.error_number == EIO &&
              mtest_exec_test_fault_seen(MTEST_EXEC_OP_FD_CLOEXEC) == 2,
          "named occurrence and error are exact");
    mtest_exec_test_fault_reset();

    CHECK(mtest_exec_process_open(
              &fault_spec, &fault_process, &error
          ) == 0,
          "open child for abort-error precedence");
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_CLOCK_MONOTONIC, 1, EIO, 0
          ) == 0,
          "configure abort clock failure");
    CHECK(mtest_exec_process_abort(
              fault_process.handle, 0, &error
          ) == -1,
          "abort never launders primary machinery error");
    CHECK(error.operation == MTEST_EXEC_OP_CLOCK_MONOTONIC &&
              error.error_number == EIO,
          "abort preserves primary clock failure");
    mtest_exec_test_fault_reset();
    CHECK(mtest_exec_process_abort(
              fault_process.handle, 0, &error
          ) == 0,
          "successful abort retry consumes the retained handle");
    CHECK(mtest_exec_runtime_close(&error) == 0, "runtime close");

    mtest_exec_test_fault_configure(
        MTEST_EXEC_OP_SIGACTION_INSTALL_TERM, 1, EIO, 0
    );
    CHECK(mtest_exec_runtime_open(&error) == -1,
          "injected second install failure");
    CHECK(error.operation == MTEST_EXEC_OP_SIGACTION_INSTALL_TERM &&
              error.error_number == EIO &&
              error.cleanup_operation == MTEST_EXEC_OP_NONE,
          "install failure preserves initiating error and rolls back");
    mtest_exec_test_fault_reset();

    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_SIGACTION_INSTALL_TERM, 1, EIO, 0
          ) == 0,
          "configure initiating install fault");
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_SIGACTION_RESTORE_INT, 1, EPERM, 0
          ) == 0,
          "configure rollback fault");
    CHECK(mtest_exec_runtime_open(&error) == -1,
          "injected install plus rollback failure");
    CHECK(error.operation == MTEST_EXEC_OP_SIGACTION_INSTALL_TERM &&
              error.error_number == EIO &&
              error.cleanup_operation == MTEST_EXEC_OP_SIGACTION_RESTORE_INT &&
              error.cleanup_error_number == EPERM,
          "initiating error wins and cleanup error remains visible");
    mtest_exec_test_fault_reset();
    CHECK(mtest_exec_runtime_close(&error) == 0,
          "explicit close repairs failed installation rollback");

    CHECK(mtest_exec_runtime_open(&error) == 0,
          "runtime opens after transactional rollback");

    mtest_exec_test_fault_configure(
        MTEST_EXEC_OP_SIGACTION_RESTORE_TERM, 1, EIO, 0
    );
    CHECK(mtest_exec_runtime_close(&error) == -1,
          "injected restoration failure is fallible");
    CHECK(error.operation == MTEST_EXEC_OP_SIGACTION_RESTORE_TERM &&
              error.error_number == EIO,
          "restoration failure is named exactly");
    struct mtest_exec_bytes blocked_argv[1] = {bytes("/bin/true")};
    struct mtest_exec_process_spec blocked_spec;
    memset(&blocked_spec, 0, sizeof(blocked_spec));
    blocked_spec.argv = blocked_argv;
    blocked_spec.argc = 1;
    struct mtest_exec_process_ref blocked_process;
    CHECK(mtest_exec_process_open(
              &blocked_spec, &blocked_process, &error
          ) == -1 && error.error_number == EINVAL,
          "partial teardown blocks new child ownership");
    mtest_exec_test_fault_reset();
    CHECK(mtest_exec_runtime_close(&error) == 0,
          "explicit close retry finishes restoration");

    CHECK(mtest_exec_runtime_open(&error) == 0,
          "sequential runtime reinstall");
    CHECK(mtest_exec_runtime_close(&error) == 0,
          "sequential runtime teardown");
    puts("adapter-smoke: OK");
    return 0;
}
