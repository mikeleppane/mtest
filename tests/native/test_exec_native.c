#define _POSIX_C_SOURCE 200809L

#include "../../native/mtest_exec_native.h"
#include "../../native/mtest_exec_native_test.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
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

static int exercise_platform_constants(void) {
    CHECK(MTEST_EXEC_TEST_CONSTANT_SIGCHLD == 1, "SIGCHLD constant id");
    CHECK(MTEST_EXEC_TEST_CONSTANT_EIO == 4, "EIO constant id");
    CHECK(MTEST_EXEC_TEST_CONSTANT_ETXTBSY == 5, "ETXTBSY constant id");
    CHECK(
        mtest_exec_test_constant(MTEST_EXEC_TEST_CONSTANT_SIGCHLD) == SIGCHLD,
        "SIGCHLD constant is header-derived"
    );
    CHECK(
        mtest_exec_test_constant(MTEST_EXEC_TEST_CONSTANT_EIO) == EIO,
        "EIO constant is header-derived"
    );
    CHECK(
        mtest_exec_test_constant(MTEST_EXEC_TEST_CONSTANT_ETXTBSY) == ETXTBSY,
        "ETXTBSY constant is header-derived"
    );
    CHECK(mtest_exec_test_constant(0) == -1, "zero constant id is rejected");
    CHECK(
        mtest_exec_test_constant(UINT32_MAX) == -1,
        "unknown constant id is rejected"
    );
    return 0;
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
    CHECK(mtest_exec_process_open(&spec, &second, &error) == 0,
          "a second child opens concurrently into a free slot");
    CHECK(second.handle != process.handle,
          "concurrent children carry distinct handles");
    CHECK(mtest_exec_process_abort(second.handle, 0, &error) == 0,
          "aborting one child leaves the other live");

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
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_GROUP_KILL, 1, EPERM, 0
          ) == 0,
          "configure observed group-kill permission failure");
    CHECK(mtest_exec_process_group(
              process.handle, MTEST_EXEC_GROUP_KILL, &group, &error
          ) == -1,
          "injected observed group-kill failure remains visible");
    CHECK(error.operation == MTEST_EXEC_OP_GROUP_KILL &&
              error.error_number == EPERM,
          "injected observed group-kill error is exact");
    CHECK(mtest_exec_test_fault_seen(MTEST_EXEC_OP_GROUP_KILL) == 1,
          "observed group-kill fault is consumed exactly once");
    mtest_exec_test_fault_reset();
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

    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_GROUP_KILL, 1, EIO, 0
          ) == 0,
          "configure post-reap group-kill fault");
    CHECK(mtest_exec_process_group(
              process.handle, MTEST_EXEC_GROUP_KILL, &group, &error
          ) == -1,
          "post-reap group action is rejected");
    CHECK(error.operation == MTEST_EXEC_OP_GROUP_KILL &&
              error.error_number == EINVAL,
          "post-reap group rejection is exact");
    CHECK(mtest_exec_test_fault_seen(MTEST_EXEC_OP_GROUP_KILL) == 0,
          "post-reap rejection precedes the group-kill seam");
    mtest_exec_test_fault_reset();
    CHECK(strcmp(stdout_capture, "out") == 0, "stdout byte fidelity");
    CHECK(strcmp(stderr_capture, "err") == 0, "stderr byte fidelity");
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_GROUP_TERM, 1, EIO, 0
          ) == 0,
          "configure reaped-abort first group fault");
    int abort_result = mtest_exec_process_abort(process.handle, 0, &error);
    CHECK(mtest_exec_test_fault_seen(MTEST_EXEC_OP_GROUP_TERM) == 0,
          "reaped abort guard precedes checked group operation");
    CHECK(abort_result == 0, "abort consumes swept reaped process");
    mtest_exec_test_fault_reset();
    return 0;
}

static int exercise_preobserve_zombie_only_term(void) {
    struct mtest_exec_bytes argv[1] = {bytes("/usr/bin/true")};
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = 1;

    struct mtest_exec_process_ref process;
    struct mtest_exec_error error;
    CHECK(mtest_exec_process_open(&spec, &process, &error) == 0,
          "open child for pre-observe group TERM");

    int waitable = 0;
    for (int attempt = 0; attempt < 500 && !waitable; ++attempt) {
        siginfo_t information;
        memset(&information, 0, sizeof(information));
        CHECK(waitid(
                  P_PID,
                  (id_t)process.leader_pid,
                  &information,
                  WEXITED | WNOHANG | WNOWAIT
              ) == 0,
              "external waitid for pre-observe group TERM");
        waitable = information.si_pid == process.leader_pid;
        if (!waitable) {
            const struct timespec delay = {0, 1000000L};
            (void)nanosleep(&delay, NULL);
        }
    }
    CHECK(waitable, "pre-observe group TERM child became waitable");

    struct mtest_exec_group_result group;
#if defined(__APPLE__)
    CHECK(mtest_exec_process_group(
              process.handle, MTEST_EXEC_GROUP_PROBE, &group, &error
          ) == -1,
          "pre-observe zombie-only group probe remains fail-closed");
    CHECK(error.operation == MTEST_EXEC_OP_GROUP_PROBE &&
              error.error_number == EPERM,
          "pre-observe zombie-only group probe error is exact");
#endif
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_GROUP_TERM, 1, EPERM, 0
          ) == 0,
          "configure pre-observe group-TERM permission failure");
    CHECK(mtest_exec_process_group(
              process.handle, MTEST_EXEC_GROUP_TERM, &group, &error
          ) == -1,
          "injected pre-observe group-TERM failure remains visible");
    CHECK(error.operation == MTEST_EXEC_OP_GROUP_TERM &&
              error.error_number == EPERM,
          "injected pre-observe group-TERM error is exact");
    CHECK(mtest_exec_test_fault_seen(MTEST_EXEC_OP_GROUP_TERM) == 1,
          "pre-observe group-TERM fault is consumed exactly once");
    mtest_exec_test_fault_reset();
    CHECK(mtest_exec_process_group(
              process.handle, MTEST_EXEC_GROUP_TERM, &group, &error
          ) == 0,
          "pre-observe zombie-only group TERM is complete");
    CHECK(group.state == MTEST_EXEC_GROUP_PRESENT,
          "pre-observe zombie-only group TERM reports present");
    CHECK(mtest_exec_process_abort(process.handle, 0, &error) == 0,
          "abort consumes pre-observe zombie-only group TERM child");
    return 0;
}

static int exercise_reaped_unswept_abort_child(void) {
    struct mtest_exec_bytes argv[1] = {bytes("/usr/bin/true")};
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = 1;

    struct mtest_exec_process_ref process;
    struct mtest_exec_error error;
    CHECK(mtest_exec_process_open(&spec, &process, &error) == 0,
          "open child for reaped unswept abort");

    int waitable = 0;
    for (int attempt = 0; attempt < 500 && !waitable; ++attempt) {
        struct mtest_exec_observe_result observation;
        CHECK(mtest_exec_process_observe(
                  process.handle, &observation, &error
              ) == 0,
              "observe child for reaped unswept abort");
        waitable = observation.state == MTEST_EXEC_LEADER_WAITABLE;
        if (!waitable) {
            const struct timespec delay = {0, 1000000L};
            (void)nanosleep(&delay, NULL);
        }
    }
    CHECK(waitable, "unswept leader became waitable");
    CHECK(mtest_exec_process_channel_close(
              process.handle, MTEST_EXEC_CHANNEL_STDOUT, &error
          ) == 0,
          "close unswept stdout channel");
    CHECK(mtest_exec_process_channel_close(
              process.handle, MTEST_EXEC_CHANNEL_STDERR, &error
          ) == 0,
          "close unswept stderr channel");
    CHECK(mtest_exec_process_channel_close(
              process.handle, MTEST_EXEC_CHANNEL_SETUP, &error
          ) == 0,
          "close unswept setup channel");
    struct mtest_exec_reap_result reap;
    CHECK(mtest_exec_process_reap(process.handle, &reap, &error) == 0,
          "reap unswept leader");

    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_GROUP_KILL, 1, EIO, 0
          ) == 0,
          "configure unswept post-reap group-kill fault");
    CHECK(mtest_exec_process_abort(process.handle, 0, &error) == -1,
          "abort rejects reaped unswept process");
    CHECK(error.operation == MTEST_EXEC_OP_NONE &&
              error.error_number == EBUSY,
          "reaped unswept abort error is exact");
    CHECK(mtest_exec_test_fault_seen(MTEST_EXEC_OP_GROUP_KILL) == 0,
          "reaped unswept abort does not reach group-kill seam");
    mtest_exec_test_fault_reset();

    struct mtest_exec_process_ref second;
    CHECK(mtest_exec_process_open(&spec, &second, &error) == 0,
          "a reaped-unswept slot pins itself but a fresh slot still opens");
    CHECK(mtest_exec_process_abort(second.handle, 0, &error) == 0,
          "the fresh child aborts cleanly beside the pinned slot");
    return 0;
}

static int exercise_reaped_unswept_abort(void) {
    pid_t child = fork();
    if (child < 0) {
        fprintf(stderr, "reaped-unswept fork failed: errno=%d\n", errno);
        return 1;
    }
    if (child == 0) {
        _exit(exercise_reaped_unswept_abort_child());
    }
    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(child, &status, 0);
    } while (waited < 0 && errno == EINTR);
    if (waited != child) {
        fprintf(stderr, "reaped-unswept wait failed: errno=%d\n", errno);
        return 1;
    }
    if (!WIFEXITED(status)) {
        fprintf(stderr, "reaped-unswept child did not exit normally\n");
        return 1;
    }
    return WEXITSTATUS(status);
}

static int exercise_terminal_setpgid_cleanup_child(void) {
    struct mtest_exec_bytes argv[1] = {bytes("/usr/bin/true")};
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = 1;
    struct mtest_exec_process_ref process;
    struct mtest_exec_error error;

    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_PARENT_SETPGID, 1, EIO, 0
          ) == 0,
          "configure terminal parent setpgid failure");
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_WAITPID, 1, EPERM, 0
          ) == 0,
          "configure terminal setpgid cleanup failure");
    CHECK(mtest_exec_process_open(&spec, &process, &error) == -1,
          "terminal setpgid cleanup rejects open");
    CHECK(error.operation == MTEST_EXEC_OP_PARENT_SETPGID &&
              error.error_number == EIO,
          "terminal cleanup retains setpgid error as primary");
    CHECK(error.cleanup_operation == MTEST_EXEC_OP_WAITPID &&
              error.cleanup_error_number == EPERM,
          "terminal cleanup exposes exact wait error");
    CHECK(mtest_exec_test_fault_seen(MTEST_EXEC_OP_WAITPID) == 1,
          "terminal cleanup consults wait seam exactly once");
    pid_t failed_leader = (pid_t)error.subject;

    struct mtest_exec_process_ref second;
    CHECK(mtest_exec_process_open(&spec, &second, &error) == 0,
          "a wedged setpgid slot pins itself but a fresh slot still opens");
    CHECK(mtest_exec_process_abort(second.handle, 0, &error) == 0,
          "the fresh child aborts cleanly beside the wedged slot");

    pid_t waited;
    do {
        waited = waitpid(failed_leader, NULL, 0);
    } while (waited < 0 && errno == EINTR);
    CHECK(waited == failed_leader || (waited < 0 && errno == ECHILD),
          "test process disposes terminal cleanup child");
    return 0;
}

static int exercise_terminal_setpgid_cleanup(void) {
    pid_t child = fork();
    if (child < 0) {
        fprintf(stderr, "terminal-setpgid fork failed: errno=%d\n", errno);
        return 1;
    }
    if (child == 0) {
        _exit(exercise_terminal_setpgid_cleanup_child());
    }
    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(child, &status, 0);
    } while (waited < 0 && errno == EINTR);
    if (waited != child) {
        fprintf(stderr, "terminal-setpgid wait failed: errno=%d\n", errno);
        return 1;
    }
    if (!WIFEXITED(status)) {
        fprintf(stderr, "terminal-setpgid child did not exit normally\n");
        return 1;
    }
    return WEXITSTATUS(status);
}

static int exercise_process_with_closed_standard_fds_child(void) {
    int saved_stdin = fcntl(
        STDIN_FILENO, F_DUPFD_CLOEXEC, STDERR_FILENO + 1
    );
    if (saved_stdin < 0) {
        fprintf(stderr, "save stdin failed: errno=%d\n", errno);
        return 1;
    }
    int saved_stdout = fcntl(
        STDOUT_FILENO, F_DUPFD_CLOEXEC, STDERR_FILENO + 1
    );
    if (saved_stdout < 0) {
        int saved_errno = errno;
        if (close(saved_stdin) != 0) {
            fprintf(stderr, "close saved stdin failed: errno=%d\n", errno);
        }
        fprintf(stderr, "save stdout failed: errno=%d\n", saved_errno);
        return 1;
    }

    int exercise_result = 1;
    int setup_failed = 0;
    if (close(STDIN_FILENO) != 0) {
        fprintf(stderr, "close stdin failed: errno=%d\n", errno);
        setup_failed = 1;
    }
    if (close(STDOUT_FILENO) != 0) {
        fprintf(stderr, "close stdout failed: errno=%d\n", errno);
        setup_failed = 1;
    }
    if (!setup_failed) {
        exercise_result = exercise_process();
    }

    int restoration_failed = 0;
    int restored_stdin = dup2(saved_stdin, STDIN_FILENO);
    if (restored_stdin < 0) {
        fprintf(stderr, "restore stdin failed: errno=%d\n", errno);
        restoration_failed = 1;
    }
    int restored_stdout = dup2(saved_stdout, STDOUT_FILENO);
    if (restored_stdout < 0) {
        fprintf(stderr, "restore stdout failed: errno=%d\n", errno);
        restoration_failed = 1;
    }

    int cleanup_failed = 0;
    if (restored_stdin >= 0 && close(STDIN_FILENO) != 0) {
        fprintf(stderr, "reclose restored stdin failed: errno=%d\n", errno);
        cleanup_failed = 1;
    }
    if (restored_stdout >= 0 && close(STDOUT_FILENO) != 0) {
        fprintf(stderr, "reclose restored stdout failed: errno=%d\n", errno);
        cleanup_failed = 1;
    }
    if (close(saved_stdin) != 0) {
        fprintf(stderr, "close saved stdin failed: errno=%d\n", errno);
        cleanup_failed = 1;
    }
    if (close(saved_stdout) != 0) {
        fprintf(stderr, "close saved stdout failed: errno=%d\n", errno);
        cleanup_failed = 1;
    }
    return setup_failed || restoration_failed || cleanup_failed
        ? 1
        : exercise_result;
}

static int exercise_process_with_closed_standard_fds(void) {
    /* This outer fork isolates descriptor mutation in a single-threaded test;
       it is not the adapter's production post-fork region. */
    pid_t child = fork();
    if (child < 0) {
        fprintf(stderr, "closed-standard-fd fork failed: errno=%d\n", errno);
        return 1;
    }
    if (child == 0) {
        _exit(exercise_process_with_closed_standard_fds_child());
    }
    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(child, &status, 0);
    } while (waited < 0 && errno == EINTR);
    if (waited != child) {
        fprintf(stderr, "closed-standard-fd wait failed: errno=%d\n", errno);
        return 1;
    }
    if (!WIFEXITED(status)) {
        fprintf(stderr, "closed-standard-fd child did not exit normally\n");
        return 1;
    }
    return WEXITSTATUS(status);
}

static int exercise_second_candidate_allocation_failure(void) {
    const char *original_path = getenv("PATH");
    char *saved_path = original_path == NULL ? NULL : strdup(original_path);
    CHECK(original_path == NULL || saved_path != NULL, "save PATH");
    if (setenv("PATH", "/mtest-one:/mtest-two:/mtest-three", 1) != 0) {
        int saved_errno = errno;
        free(saved_path);
        fprintf(stderr, "set three-component PATH failed: errno=%d\n",
                saved_errno);
        return 1;
    }

    struct mtest_exec_bytes argv[1] = {bytes("mtest-no-such-program")};
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = 1;
    struct mtest_exec_process_ref process;
    struct mtest_exec_error error;
    int configure_result = mtest_exec_test_fault_configure(
        MTEST_EXEC_OP_PLAN_ALLOC, 7, ENOMEM, 0
    );
    int open_result = -1;
    if (configure_result == 0) {
        open_result = mtest_exec_process_open(&spec, &process, &error);
    }
    uint32_t allocation_attempts =
        mtest_exec_test_fault_seen(MTEST_EXEC_OP_PLAN_ALLOC);
    mtest_exec_test_fault_reset();

    int cleanup_result = 0;
    if (open_result == 0) {
        cleanup_result = mtest_exec_process_abort(process.handle, 0, &error);
    }
    int restore_result = saved_path == NULL
        ? unsetenv("PATH")
        : setenv("PATH", saved_path, 1);
    int restore_errno = errno;
    free(saved_path);

    CHECK(configure_result == 0,
          "configure second candidate allocation fault");
    CHECK(open_result == -1, "second candidate allocation fails open");
    CHECK(error.operation == MTEST_EXEC_OP_PLAN_ALLOC &&
              error.error_number == ENOMEM,
          "candidate allocation error is exact");
    CHECK(allocation_attempts == 8,
          "interior NULL is followed by the third candidate allocation");
    CHECK(cleanup_result == 0, "clean unexpected successful open");
    if (restore_result != 0) {
        fprintf(stderr, "restore PATH failed: errno=%d\n", restore_errno);
        return 1;
    }
    return 0;
}

static int exercise_consumed_close_error(void) {
    struct mtest_exec_bytes argv[1] = {bytes("/bin/sleep")};
    struct mtest_exec_bytes full_argv[2] = {argv[0], bytes("30")};
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = full_argv;
    spec.argc = 2;
    struct mtest_exec_process_ref process;
    struct mtest_exec_error error;
    CHECK(mtest_exec_process_open(&spec, &process, &error) == 0,
          "open child for consumed close error");
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_CLOSE_CHANNEL, 1, EIO, 0
          ) == 0,
          "configure consumed close error");
    CHECK(mtest_exec_process_channel_close(
              process.handle, MTEST_EXEC_CHANNEL_STDOUT, &error
          ) == -1,
          "close reports injected post-syscall error");
    CHECK(error.operation == MTEST_EXEC_OP_CLOSE_CHANNEL &&
              error.error_number == EIO,
          "consumed close error is exact");
    int consumed_fd = (int)error.subject;
    int replacement = open("/dev/null", O_RDONLY);
    CHECK(replacement == consumed_fd,
          "closed descriptor number is immediately reusable");
    mtest_exec_test_fault_reset();
    CHECK(mtest_exec_process_abort(process.handle, 0, &error) == 0,
          "abort succeeds after consumed channel close");
    CHECK(fcntl(replacement, F_GETFD) >= 0,
          "abort never closes the replacement descriptor");
    CHECK(close(replacement) == 0, "close replacement descriptor");
    return 0;
}

static int exercise_retryable_abort_group_kill(void) {
    struct mtest_exec_bytes argv[2] = {bytes("/bin/sleep"), bytes("30")};
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = 2;
    struct mtest_exec_process_ref process;
    struct mtest_exec_error error;
    CHECK(mtest_exec_process_open(&spec, &process, &error) == 0,
          "open child for retryable abort group kill");
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_GROUP_TERM, 1, EIO, 0
          ) == 0,
          "configure abort group-term failure");
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_GROUP_KILL, 1, EIO, 0
          ) == 0,
          "configure abort group-kill failure");
    CHECK(mtest_exec_process_abort(process.handle, 0, &error) == -1,
          "abort reports unproven group sweep");
    CHECK(error.cleanup_operation == MTEST_EXEC_OP_GROUP_TERM &&
              error.cleanup_error_number == EIO,
          "abort preserves the first group cleanup error");
    CHECK(mtest_exec_test_fault_seen(MTEST_EXEC_OP_GROUP_KILL) == 1,
          "abort attempts the failing group sweep exactly once");
    CHECK(kill(process.leader_pid, 0) == 0,
          "failed group sweep leaves the unreaped leader live");
    siginfo_t information;
    memset(&information, 0, sizeof(information));
    CHECK(waitid(
              P_PID,
              (id_t)process.leader_pid,
              &information,
              WEXITED | WNOHANG | WNOWAIT
          ) == 0,
          "inspect leader after failed group sweep");
    CHECK(information.si_pid == 0,
          "failed group sweep never kills or makes the leader waitable");
    mtest_exec_test_fault_reset();
    CHECK(mtest_exec_process_abort(process.handle, 0, &error) == 0,
          "later abort retries sweep and consumes the pinned handle");
    return 0;
}

static int exercise_transient_group_signal_eperm(void) {
    struct mtest_exec_bytes argv[2] = {bytes("/bin/sleep"), bytes("30")};
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = 2;
    struct mtest_exec_process_ref process;
    struct mtest_exec_group_result group;
    struct mtest_exec_error error;

    CHECK(mtest_exec_process_open(&spec, &process, &error) == 0,
          "open child for transient group-signal EPERM");
    CHECK(mtest_exec_test_group_signal_eperm_configure(
              MTEST_EXEC_OP_GROUP_KILL, 2
          ) == 0,
          "configure transient group-kill EPERM sequence");
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_GROUP_KILL, 1, EPERM, 0
          ) == 0,
          "configure injected group-kill EPERM before transient sequence");
    CHECK(mtest_exec_process_group(
              process.handle, MTEST_EXEC_GROUP_KILL, &group, &error
          ) == -1,
          "injected group-kill EPERM remains immediate");
    CHECK(error.operation == MTEST_EXEC_OP_GROUP_KILL &&
              error.error_number == EPERM,
          "injected group-kill EPERM remains exact");
    CHECK(mtest_exec_test_fault_seen(MTEST_EXEC_OP_GROUP_KILL) == 1,
          "injected group-kill EPERM is consumed once");
    CHECK(mtest_exec_test_group_signal_eperm_seen(
              MTEST_EXEC_OP_GROUP_KILL
          ) == 0,
          "injected group-kill EPERM bypasses transient syscall retry");
    CHECK(mtest_exec_process_group(
              process.handle, MTEST_EXEC_GROUP_KILL, &group, &error
          ) == 0,
          "transient group-kill EPERM is retried");
    CHECK(group.state == MTEST_EXEC_GROUP_PRESENT,
          "retried group kill reports present");
    CHECK(mtest_exec_test_group_signal_eperm_seen(
              MTEST_EXEC_OP_GROUP_KILL
          ) == 3,
          "two transient EPERMs precede one successful group kill");
    /* Named fault accounting runs once per group-loop visit: the first call
       injects at seen=1, then the second call visits twice for EPERM and once
       for the successful kill, producing the exact composite count of four. */
    CHECK(mtest_exec_test_fault_seen(MTEST_EXEC_OP_GROUP_KILL) == 4,
          "named fault observes its injected call plus all three retry calls");
    mtest_exec_test_fault_reset();
    CHECK(mtest_exec_process_abort(process.handle, 0, &error) == 0,
          "abort consumes transient group-signal child");

    CHECK(mtest_exec_process_open(&spec, &process, &error) == 0,
          "open child for bounded group-signal EPERM");
    CHECK(mtest_exec_test_group_signal_eperm_configure(
              MTEST_EXEC_OP_GROUP_TERM, 100
          ) == 0,
          "configure persistent group-term EPERM sequence");
    CHECK(mtest_exec_process_group(
              process.handle, MTEST_EXEC_GROUP_TERM, &group, &error
          ) == -1,
          "persistent group-term EPERM remains visible after retry bound");
    CHECK(error.operation == MTEST_EXEC_OP_GROUP_TERM &&
              error.error_number == EPERM,
          "bounded group-term EPERM error is exact");
    CHECK(mtest_exec_test_group_signal_eperm_seen(
              MTEST_EXEC_OP_GROUP_TERM
          ) == 21,
          "group-term EPERM retry count is exactly bounded");
    CHECK(mtest_exec_test_fault_seen(MTEST_EXEC_OP_GROUP_TERM) == 0,
          "bounded syscall seam does not consume the fault-injection seam");
    mtest_exec_test_fault_reset();
    CHECK(mtest_exec_process_abort(process.handle, 0, &error) == 0,
          "abort consumes bounded group-signal child");
    return 0;
}

/* Must mirror MTEST_EXEC_SLOT_CAPACITY in native/mtest_exec_native.c. */
#define TEST_SLOT_CAPACITY 64u

static int exercise_slot_capacity(void) {
    struct mtest_exec_bytes argv[2] = {bytes("/bin/sleep"), bytes("30")};
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = 2;
    struct mtest_exec_error error;
    uint64_t handles[TEST_SLOT_CAPACITY];

    for (uint32_t index = 0; index < TEST_SLOT_CAPACITY; ++index) {
        struct mtest_exec_process_ref process;
        CHECK(mtest_exec_process_open(&spec, &process, &error) == 0,
              "each child up to capacity opens");
        handles[index] = process.handle;
    }
    CHECK(handles[0] != handles[1], "slots carry distinct handles");

    struct mtest_exec_process_ref overflow;
    CHECK(mtest_exec_process_open(&spec, &overflow, &error) == -1,
          "the capacity-plus-one child is rejected");
    CHECK(error.error_number == EBUSY,
          "capacity exhaustion reports EBUSY");
    CHECK(error.detail == 0,
          "slot-exhaustion EBUSY carries detail 0, not the pin's detail 1");

    for (uint32_t index = 0; index < TEST_SLOT_CAPACITY; ++index) {
        CHECK(mtest_exec_process_abort(handles[index], 0, &error) == 0,
              "every capacity child aborts cleanly");
    }
    return 0;
}

static int exercise_stale_token(void) {
    struct mtest_exec_bytes argv[2] = {bytes("/bin/sleep"), bytes("30")};
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = 2;
    struct mtest_exec_process_ref process;
    struct mtest_exec_error error;
    CHECK(mtest_exec_process_open(&spec, &process, &error) == 0,
          "open child for stale-token proof");
    uint64_t stale = process.handle;
    CHECK(mtest_exec_process_abort(stale, 0, &error) == 0,
          "abort frees the slot and invalidates the token");

    struct mtest_exec_poll_result poll_result;
    CHECK(mtest_exec_process_poll(stale, 0, &poll_result, &error) == -1,
          "polling a freed token is rejected");
    CHECK(error.error_number == EINVAL, "stale token poll reports EINVAL");

    struct mtest_exec_process_ref reused;
    CHECK(mtest_exec_process_open(&spec, &reused, &error) == 0,
          "the freed slot is reusable");
    CHECK(reused.handle != stale,
          "the reused slot publishes a fresh token, never the stale one");
    CHECK(mtest_exec_process_abort(reused.handle, 0, &error) == 0,
          "abort consumes the reused child");
    return 0;
}

static int wait_leader_waitable(uint64_t handle) {
    struct mtest_exec_error error;
    for (int attempt = 0; attempt < 2000; ++attempt) {
        struct mtest_exec_observe_result observation;
        if (mtest_exec_process_observe(handle, &observation, &error) != 0) {
            return -1;
        }
        if (observation.state == MTEST_EXEC_LEADER_WAITABLE) {
            return 0;
        }
        const struct timespec delay = {0, 1000000L};
        (void)nanosleep(&delay, NULL);
    }
    return -1;
}

static int exercise_poll_set_readiness(void) {
    /* Each child writes to exactly one stream and exits. Once a child is
       observed waitable (exited), every one of its pipes -- stdout, stderr, and
       the exec-success setup pipe -- has HUP'd, and that readiness is sticky.
       Polling the SET after both children have exited is therefore race-free:
       readiness for handles[i] must land only in results[i]. */
    struct mtest_exec_bytes argv_a[] = {
        bytes("/bin/sh"), bytes("-c"), bytes("printf ready; exit 0")
    };
    struct mtest_exec_bytes argv_b[] = {
        bytes("/bin/sh"), bytes("-c"), bytes("printf also >&2; exit 0")
    };
    struct mtest_exec_process_spec spec_a;
    struct mtest_exec_process_spec spec_b;
    memset(&spec_a, 0, sizeof(spec_a));
    memset(&spec_b, 0, sizeof(spec_b));
    spec_a.argv = argv_a;
    spec_a.argc = 3;
    spec_b.argv = argv_b;
    spec_b.argc = 3;
    struct mtest_exec_process_ref a;
    struct mtest_exec_process_ref b;
    struct mtest_exec_error error;
    CHECK(mtest_exec_process_open(&spec_a, &a, &error) == 0, "open poll-set a");
    CHECK(mtest_exec_process_open(&spec_b, &b, &error) == 0, "open poll-set b");
    CHECK(wait_leader_waitable(a.handle) == 0, "poll-set a exits");
    CHECK(wait_leader_waitable(b.handle) == 0, "poll-set b exits");

    uint64_t handles[2] = {a.handle, b.handle};
    struct mtest_exec_poll_result results[2];
    memset(results, 0, sizeof(results));
    /* timeout_ms 0: both children have exited, so every pipe is already HUP and
       poll returns immediately. */
    CHECK(mtest_exec_poll_set(handles, 2, 0, results, &error) == 0,
          "poll_set over two exited handles succeeds");
    CHECK((results[0].readiness & MTEST_EXEC_READY_STDOUT) != 0,
          "child a's stdout readiness lands in results[0]");
    CHECK((results[0].readiness & MTEST_EXEC_READY_SETUP) != 0,
          "child a's setup-pipe readiness surfaces in the set");
    CHECK((results[1].readiness & MTEST_EXEC_READY_STDERR) != 0,
          "child b's stderr readiness lands in results[1]");
    CHECK((results[1].readiness & MTEST_EXEC_READY_SETUP) != 0,
          "child b's setup-pipe readiness surfaces in the set");

    CHECK(mtest_exec_process_abort(a.handle, 0, &error) == 0, "abort poll-set a");
    CHECK(mtest_exec_process_abort(b.handle, 0, &error) == 0, "abort poll-set b");
    return 0;
}

static int exercise_poll_set_hostile_structural(void) {
    struct mtest_exec_error error;
    struct mtest_exec_poll_result results[2];
    uint64_t handles[2] = {1, 2};
    const uint32_t sentinel_readiness = 0xA5A5A5A5u;
    const uint32_t sentinel_reserved = 0x5A5A5A5Au;

    /* Phase-one (structural) violations must return with `results` UNTOUCHED --
       proven by a sentinel prefill that no path may overwrite. */
    struct {
        uint64_t count;
        const uint64_t *handle_ptr;
        int32_t timeout_ms;
        struct mtest_exec_poll_result *result_ptr;
        const char *label;
    } cases[] = {
        {0, handles, 0, results, "count zero"},
        {TEST_SLOT_CAPACITY + 1, handles, 0, results, "count over capacity"},
        {2, NULL, 0, results, "null handles"},
        {2, handles, 0, NULL, "null results"},
        {2, handles, -2, results, "timeout below negative one"},
    };
    for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); ++index) {
        results[0].readiness = sentinel_readiness;
        results[0].reserved = sentinel_reserved;
        results[1].readiness = sentinel_readiness;
        results[1].reserved = sentinel_reserved;
        CHECK(mtest_exec_poll_set(
                  cases[index].handle_ptr,
                  cases[index].count,
                  cases[index].timeout_ms,
                  cases[index].result_ptr,
                  &error
              ) == -1,
              cases[index].label);
        CHECK(error.error_number == EINVAL,
              "structural violation reports EINVAL");
        CHECK(results[0].readiness == sentinel_readiness &&
                  results[0].reserved == sentinel_reserved &&
                  results[1].readiness == sentinel_readiness &&
                  results[1].reserved == sentinel_reserved,
              "phase-one violation leaves results untouched");
    }
    return 0;
}

static int exercise_poll_set_hostile_semantic(void) {
    struct mtest_exec_bytes argv[2] = {bytes("/bin/sleep"), bytes("30")};
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = 2;
    struct mtest_exec_process_ref process;
    struct mtest_exec_error error;
    CHECK(mtest_exec_process_open(&spec, &process, &error) == 0,
          "open child for poll-set semantic proof");

    const uint32_t sentinel = 0xA5A5A5A5u;
    struct mtest_exec_poll_result results[2];

    /* Duplicate handle: the validated span is zeroed first, then EINVAL. */
    uint64_t duplicate[2] = {process.handle, process.handle};
    results[0].readiness = sentinel;
    results[0].reserved = sentinel;
    results[1].readiness = sentinel;
    results[1].reserved = sentinel;
    CHECK(mtest_exec_poll_set(duplicate, 2, 0, results, &error) == -1,
          "a duplicate handle in the set is rejected");
    CHECK(error.error_number == EINVAL, "duplicate handle reports EINVAL");
    CHECK(results[0].readiness == 0 && results[0].reserved == 0 &&
              results[1].readiness == 0 && results[1].reserved == 0,
          "semantic rejection first zeroes exactly the validated span");

    /* Stale handle at index 1: zeroed span, EINVAL, detail = offending index. */
    uint64_t stale[2] = {process.handle, process.handle + 999};
    results[0].readiness = sentinel;
    results[1].readiness = sentinel;
    CHECK(mtest_exec_poll_set(stale, 2, 0, results, &error) == -1,
          "a stale handle in the set is rejected");
    CHECK(error.error_number == EINVAL, "stale handle reports EINVAL");
    CHECK(error.detail == 1, "stale handle reports the offending index");
    CHECK(results[0].readiness == 0 && results[1].readiness == 0,
          "the stale path also leaves the span zeroed");

    CHECK(mtest_exec_process_abort(process.handle, 0, &error) == 0,
          "abort poll-set semantic child");
    return 0;
}

static int exercise_handle_scoped_fault(void) {
    struct mtest_exec_bytes argv[2] = {bytes("/bin/sleep"), bytes("30")};
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = 2;
    struct mtest_exec_process_ref a;
    struct mtest_exec_process_ref b;
    struct mtest_exec_error error;
    CHECK(mtest_exec_process_open(&spec, &a, &error) == 0, "open fault-scope a");
    CHECK(mtest_exec_process_open(&spec, &b, &error) == 0, "open fault-scope b");

    /* Target only child b's group TERM. Child a's identical action must not see
       the fault -- the seam distinguishes slots by handle. */
    struct mtest_exec_group_result group;
    CHECK(mtest_exec_test_fault_configure_handle(
              b.handle, MTEST_EXEC_OP_GROUP_TERM, 1, EIO
          ) == 0,
          "configure a handle-scoped group-TERM fault on b");
    CHECK(mtest_exec_process_group(
              a.handle, MTEST_EXEC_GROUP_TERM, &group, &error
          ) == 0,
          "a's group TERM is untouched by b's scoped fault");
    CHECK(mtest_exec_test_fault_handle_seen() == 0,
          "the scoped fault ignores the non-target handle");
    CHECK(mtest_exec_process_group(
              b.handle, MTEST_EXEC_GROUP_TERM, &group, &error
          ) == -1,
          "b's group TERM fires the scoped fault");
    CHECK(error.operation == MTEST_EXEC_OP_GROUP_TERM &&
              error.error_number == EIO,
          "b's scoped fault error is exact");
    CHECK(mtest_exec_test_fault_handle_seen() == 1,
          "the scoped fault fires exactly once, on its target");
    mtest_exec_test_fault_reset();

    CHECK(mtest_exec_process_abort(a.handle, 0, &error) == 0, "abort fault-scope a");
    CHECK(mtest_exec_process_abort(b.handle, 0, &error) == 0, "abort fault-scope b");
    return 0;
}

static int run_capture(
    const struct mtest_exec_process_spec *spec,
    char *out,
    size_t out_cap,
    size_t *out_len,
    uint32_t *setup_outcome,
    int *reap_value
) {
    struct mtest_exec_process_ref process;
    struct mtest_exec_error error;
    if (mtest_exec_process_open(spec, &process, &error) != 0) {
        fprintf(stderr, "run_capture: open failed op=%u errno=%d\n",
                error.operation, error.error_number);
        return -1;
    }
    struct mtest_exec_setup_state setup;
    memset(&setup, 0, sizeof(setup));
    char errbuf[256];
    size_t err_len = 0;
    int out_eof = 0;
    int err_eof = 0;
    int waitable = 0;
    *out_len = 0;
    out[0] = '\0';
    for (int attempt = 0; attempt < 3000 && !waitable; ++attempt) {
        struct mtest_exec_poll_result pr;
        struct mtest_exec_observe_result obs;
        if (mtest_exec_process_poll(process.handle, 10, &pr, &error) != 0 ||
            mtest_exec_process_setup_drain(process.handle, &setup, &error) != 0 ||
            drain_channel(process.handle, MTEST_EXEC_CHANNEL_STDOUT,
                          out, out_cap, out_len, &out_eof) != 0 ||
            drain_channel(process.handle, MTEST_EXEC_CHANNEL_STDERR,
                          errbuf, sizeof(errbuf), &err_len, &err_eof) != 0 ||
            mtest_exec_process_observe(process.handle, &obs, &error) != 0) {
            return -1;
        }
        waitable = obs.state == MTEST_EXEC_LEADER_WAITABLE;
    }
    if (!waitable) {
        fprintf(stderr, "run_capture: leader never became waitable\n");
        return -1;
    }
    struct mtest_exec_group_result group;
    if (mtest_exec_process_group(
            process.handle, MTEST_EXEC_GROUP_KILL, &group, &error
        ) != 0) {
        return -1;
    }
    for (int attempt = 0; attempt < 300 &&
                          (!out_eof || !err_eof ||
                           setup.outcome == MTEST_EXEC_SETUP_WAITING); ++attempt) {
        struct mtest_exec_poll_result pr;
        if (mtest_exec_process_poll(process.handle, 10, &pr, &error) != 0 ||
            mtest_exec_process_setup_drain(process.handle, &setup, &error) != 0 ||
            drain_channel(process.handle, MTEST_EXEC_CHANNEL_STDOUT,
                          out, out_cap, out_len, &out_eof) != 0 ||
            drain_channel(process.handle, MTEST_EXEC_CHANNEL_STDERR,
                          errbuf, sizeof(errbuf), &err_len, &err_eof) != 0) {
            return -1;
        }
    }
    struct mtest_exec_reap_result reap;
    if (mtest_exec_process_reap(process.handle, &reap, &error) != 0 ||
        mtest_exec_process_close(process.handle, &error) != 0) {
        return -1;
    }
    *setup_outcome = setup.outcome;
    *reap_value = reap.value;
    return 0;
}

static int exercise_env_validation(void) {
    struct mtest_exec_bytes argv[1] = {bytes("/usr/bin/true")};
    struct mtest_exec_process_spec spec;
    struct mtest_exec_error error;
    struct mtest_exec_process_ref process;

    const char *no_equals = "MTEST_ENVX";
    const char *empty_key = "=value";
    const uint8_t embedded_nul[6] = {'K', '=', 'a', '\0', 'b', 0};
    struct mtest_exec_bytes bad_cases[3];
    bad_cases[0] = bytes(no_equals);
    bad_cases[1] = bytes(empty_key);
    bad_cases[2].data = embedded_nul;
    bad_cases[2].length = 5;
    const char *labels[3] = {"no equals sign", "empty key", "embedded NUL"};
    for (size_t index = 0; index < 3; ++index) {
        memset(&spec, 0, sizeof(spec));
        spec.argv = argv;
        spec.argc = 1;
        spec.env_extra = &bad_cases[index];
        spec.env_extra_count = 1;
        CHECK(mtest_exec_process_open(&spec, &process, &error) == -1,
              labels[index]);
        CHECK(error.operation == MTEST_EXEC_OP_ENV_SNAPSHOT &&
                  error.error_number == EINVAL,
              "malformed env extra reports the env snapshot EINVAL");
    }

    struct mtest_exec_bytes duplicate[2] = {
        bytes("MTEST_ENVX=one"), bytes("MTEST_ENVX=two")
    };
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = 1;
    spec.env_extra = duplicate;
    spec.env_extra_count = 2;
    CHECK(mtest_exec_process_open(&spec, &process, &error) == -1,
          "duplicate override key is rejected");
    CHECK(error.operation == MTEST_EXEC_OP_ENV_SNAPSHOT &&
              error.error_number == EINVAL,
          "duplicate override reports env snapshot EINVAL");
    return 0;
}

static int exercise_env_merge(void) {
    if (setenv("MTEST_ENVX", "inherited", 1) != 0) {
        fprintf(stderr, "env merge: setenv failed: errno=%d\n", errno);
        return 1;
    }
    static char out[65536];
    size_t out_len = 0;
    uint32_t setup_outcome = 0;
    int reap_value = 0;

    /* Override MTEST_ENVX. Exec /usr/bin/env DIRECTLY (no shell, which would
       dedup) so the child prints the RAW merged envp. Replace-not-append means
       the inherited entry is gone: exactly one MTEST_ENVX= line survives and it
       carries the override value. */
    struct mtest_exec_bytes argv[1] = {bytes("/usr/bin/env")};
    struct mtest_exec_bytes override = bytes("MTEST_ENVX=override");
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = 1;
    spec.env_extra = &override;
    spec.env_extra_count = 1;
    CHECK(run_capture(&spec, out, sizeof(out), &out_len, &setup_outcome,
                      &reap_value) == 0,
          "override run completes");
    size_t envx_lines = 0;
    for (const char *cursor = out;
         (cursor = strstr(cursor, "MTEST_ENVX=")) != NULL; cursor += 1) {
        if (cursor == out || cursor[-1] == '\n') {
            envx_lines += 1;
        }
    }
    CHECK(envx_lines == 1,
          "the inherited entry is dropped, not appended beside the override");
    CHECK(strstr(out, "MTEST_ENVX=override\n") != NULL,
          "the surviving entry carries the override value");

    /* A novel key is appended and visible to the child. */
    struct mtest_exec_bytes argv_novel[] = {
        bytes("/bin/sh"), bytes("-c"), bytes("printf '%s' \"$MTEST_ENVY\"")
    };
    struct mtest_exec_bytes novel = bytes("MTEST_ENVY=fresh");
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv_novel;
    spec.argc = 3;
    spec.env_extra = &novel;
    spec.env_extra_count = 1;
    CHECK(run_capture(&spec, out, sizeof(out), &out_len, &setup_outcome,
                      &reap_value) == 0,
          "novel-key run completes");
    CHECK(strcmp(out, "fresh") == 0, "a novel override key is appended");

    /* A PATH override steers resolution: an unresolvable PATH makes a
       slash-free program a spawn failure, proving resolution reads merged env. */
    struct mtest_exec_bytes argv_path[1] = {bytes("mtest-no-such-xyz")};
    struct mtest_exec_bytes path_override =
        bytes("PATH=/mtest-nonexistent-dir");
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv_path;
    spec.argc = 1;
    spec.env_extra = &path_override;
    spec.env_extra_count = 1;
    CHECK(run_capture(&spec, out, sizeof(out), &out_len, &setup_outcome,
                      &reap_value) == 0,
          "PATH-override run completes");
    CHECK(setup_outcome == MTEST_EXEC_SETUP_SPAWN_FAILED,
          "an overriding PATH governs candidate resolution");

    /* env_extra_count == 0 reproduces the v1 snapshot: the inherited value is
       seen byte-identically. */
    struct mtest_exec_bytes argv_base[] = {
        bytes("/bin/sh"), bytes("-c"), bytes("printf '%s' \"$MTEST_ENVX\"")
    };
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv_base;
    spec.argc = 3;
    CHECK(run_capture(&spec, out, sizeof(out), &out_len, &setup_outcome,
                      &reap_value) == 0,
          "zero-override run completes");
    CHECK(strcmp(out, "inherited") == 0,
          "a zero override count reproduces the v1 environment");

    (void)unsetenv("MTEST_ENVX");
    return 0;
}

static int exercise_fd_limit(void) {
    struct mtest_exec_error error;
    struct rlimit saved;
    CHECK(getrlimit(RLIMIT_NOFILE, &saved) == 0, "read current fd limit");

    uint64_t reported = 0;
    CHECK(mtest_exec_fd_limit(&reported, &error) == 0, "fd limit query");
    if (saved.rlim_cur == RLIM_INFINITY) {
        CHECK(reported == MTEST_EXEC_FD_LIMIT_UNBOUNDED,
              "an unbounded soft limit maps to the sentinel");
    } else {
        CHECK(reported == (uint64_t)saved.rlim_cur,
              "the reported soft limit equals getrlimit");
    }

    struct rlimit reduced = saved;
    reduced.rlim_cur = 256;
    if (reduced.rlim_max != RLIM_INFINITY && reduced.rlim_cur > reduced.rlim_max) {
        reduced.rlim_cur = reduced.rlim_max;
    }
    CHECK(setrlimit(RLIMIT_NOFILE, &reduced) == 0, "lower the soft fd limit");
    CHECK(mtest_exec_fd_limit(&reported, &error) == 0, "fd limit re-query");
    CHECK(reported == (uint64_t)reduced.rlim_cur,
          "fd limit tracks the lowered soft limit");
    CHECK(setrlimit(RLIMIT_NOFILE, &saved) == 0, "restore the soft fd limit");
    return 0;
}

static int exercise_fd_limit_peak_child(void) {
    /* Runs in a fork of the test, inheriting the already-open runtime; it must
       not reopen or close it. Lowering the fd limit here cannot touch the
       parent's descriptors. */
    struct mtest_exec_error error;
    struct rlimit saved;
    if (getrlimit(RLIMIT_NOFILE, &saved) != 0) {
        return 1;
    }
    /* Prove the RAW spawn peak deterministically, independent of the absolute
       limit the sanitizer runtime reports. Anchor a small ceiling just above the
       current fd position, OCCUPY all headroom with dummy descriptors, then free
       exactly PEAK_HEADROOM of them. One raw spawn fits that window and SUCCEEDS,
       retaining its three read descriptors; because a spawn's fd peak (three
       pipes) exceeds what remains, the very next spawn FAILS with an EMFILE-class
       error at the boundary -- the 3N+3 peak. */
    struct mtest_exec_bytes argv[2] = {bytes("/bin/sleep"), bytes("30")};
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = 2;

    int probe = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (probe < 0) {
        return 1;
    }
    rlim_t ceiling = (rlim_t)probe + 24;
    (void)close(probe);

    struct rlimit reduced = saved;
    reduced.rlim_cur = ceiling;
    if (reduced.rlim_max != RLIM_INFINITY && reduced.rlim_cur > reduced.rlim_max) {
        reduced.rlim_cur = reduced.rlim_max;
    }
    if (setrlimit(RLIMIT_NOFILE, &reduced) != 0) {
        return 1;
    }

    static int dummies[64];
    size_t dummy_count = 0;
    for (;;) {
        int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (fd < 0) {
            break;
        }
        if (dummy_count >= sizeof(dummies) / sizeof(dummies[0])) {
            (void)close(fd);
            break;
        }
        dummies[dummy_count++] = fd;
    }
    const size_t peak_headroom = 8;
    if (dummy_count < peak_headroom + 1) {
        for (size_t index = 0; index < dummy_count; ++index) {
            (void)close(dummies[index]);
        }
        (void)setrlimit(RLIMIT_NOFILE, &saved);
        return 1;
    }
    for (size_t index = 0; index < peak_headroom; ++index) {
        (void)close(dummies[--dummy_count]);
    }

    struct mtest_exec_process_ref boundary;
    int boundary_open = mtest_exec_process_open(&spec, &boundary, &error);
    int past_open = -1;
    int past_error = 0;
    if (boundary_open == 0) {
        struct mtest_exec_process_ref past;
        past_open = mtest_exec_process_open(&spec, &past, &error);
        past_error = error.error_number;
        if (past_open == 0) {
            (void)mtest_exec_process_abort(past.handle, 0, &error);
        }
    }

    int ok = boundary_open == 0 && past_open == -1 &&
             (past_error == EMFILE || past_error == ENFILE);

    if (boundary_open == 0) {
        (void)mtest_exec_process_abort(boundary.handle, 0, &error);
    }
    for (size_t index = 0; index < dummy_count; ++index) {
        (void)close(dummies[index]);
    }
    (void)setrlimit(RLIMIT_NOFILE, &saved);
    return ok ? 0 : 1;
}

static int running_under_fd_tracker(void) {
    /* Detect Valgrind: it injects its vgpreload interceptors via LD_PRELOAD. */
    const char *preload = getenv("LD_PRELOAD");
    return preload != NULL && strstr(preload, "vgpreload") != NULL;
}

static int exercise_fd_limit_peak(void) {
    if (running_under_fd_tracker()) {
        /* Skip the RAW fd-exhaustion peak under Valgrind's --track-fds only.
           Valgrind's --track-fds remaps its own reserved descriptors under the
           deliberately low RLIMIT_NOFILE this test imposes, so recycled fd
           numbers are misreported as already-closed; the adapter's close
           discipline is single-close by construction (see mtest_close_owned),
           and the identical cleanup path is covered under Valgrind by the
           fault-injected EMFILE test (exercise_emfile_pipe_cleanup). The raw
           peak is genuinely exercised under native-check. */
        return 0;
    }
    /* Isolate the rlimit mutation and its many spawns in a subprocess so the
       reduced limit never touches the parent test's descriptors. */
    pid_t child = fork();
    if (child < 0) {
        fprintf(stderr, "fd-peak fork failed: errno=%d\n", errno);
        return 1;
    }
    if (child == 0) {
        _exit(exercise_fd_limit_peak_child());
    }
    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(child, &status, 0);
    } while (waited < 0 && errno == EINTR);
    if (waited != child || !WIFEXITED(status)) {
        fprintf(stderr, "fd-peak child did not exit normally\n");
        return 1;
    }
    return WEXITSTATUS(status);
}

static int exercise_emfile_pipe_cleanup(void) {
    /* Fault-injected twin of the occupied-headroom fd peak, run under Valgrind
       with no reduced RLIMIT_NOFILE (hence no --track-fds guard). Two boundaries:
       first an EMFILE at PIPE_STDOUT, where the failure precedes pipe() so no
       descriptor exists and the cleanup is memory/state only (cleanup_pipes over
       {-1,-1} -> free_plan -> release_slot -> settle); then an EMFILE at
       PIPE_STDERR, where PIPE_STDOUT's pipe() has already created two real
       descriptors, so the same cleanup must close those two once each while the
       stderr and setup slots stay skipped. Together they prove the EMFILE
       cleanup leaks no memory, double-closes no descriptor, and leaves the
       runtime reusable. */
    struct mtest_exec_error error;
    struct mtest_exec_bytes argv[1] = {bytes("/usr/bin/true")};
    struct mtest_exec_process_spec spec;
    memset(&spec, 0, sizeof(spec));
    spec.argv = argv;
    spec.argc = 1;
    struct mtest_exec_process_ref process;

    mtest_exec_test_fault_reset();
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_PIPE_STDOUT, 1, EMFILE, 0
          ) == 0,
          "configure EMFILE at the stdout pipe seam");
    CHECK(mtest_exec_process_open(&spec, &process, &error) == -1,
          "EMFILE at pipe creation rejects open");
    CHECK(error.operation == MTEST_EXEC_OP_PIPE_STDOUT &&
              error.error_number == EMFILE,
          "EMFILE cleanup names the stdout pipe operation exactly");
    CHECK(mtest_exec_test_fault_seen(MTEST_EXEC_OP_PIPE_STDOUT) == 1,
          "EMFILE fault fired at the first stdout pipe attempt");
    mtest_exec_test_fault_reset();

    /* Partial-pipe variant: arm the EMFILE at the SECOND pipe so PIPE_STDOUT's
       pipe() first creates two real descriptors and PIPE_STDERR's pipe() then
       fails. process_open must run the mixed cleanup -- close the two real
       stdout descriptors once each through mtest_close_owned while the stderr
       and setup slots stay {-1, -1} and are skipped. This is the real-fd close
       discipline the raw peak proves only outside Valgrind; here it runs under
       --track-fds with no reduced RLIMIT_NOFILE. */
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_PIPE_STDERR, 1, EMFILE, 0
          ) == 0,
          "configure EMFILE at the stderr pipe seam");
    CHECK(mtest_exec_process_open(&spec, &process, &error) == -1,
          "EMFILE at the second pipe rejects open");
    CHECK(error.operation == MTEST_EXEC_OP_PIPE_STDERR &&
              error.error_number == EMFILE,
          "partial-pipe cleanup names the stderr pipe operation exactly");
    CHECK(mtest_exec_test_fault_seen(MTEST_EXEC_OP_PIPE_STDERR) == 1,
          "EMFILE fault fired once at the stderr pipe attempt");
    mtest_exec_test_fault_reset();

    CHECK(mtest_exec_process_open(&spec, &process, &error) == 0,
          "runtime is reusable after EMFILE pipe cleanup");
    CHECK(mtest_exec_process_abort(process.handle, 0, &error) == 0,
          "ordinary lifecycle follows EMFILE pipe cleanup");
    return 0;
}

static int exercise_interrupt_counting(void) {
    /* Sequential: a single observed activation reads 1. */
    mtest_exec_test_reset_interrupt();
    CHECK(mtest_exec_interrupt_count() == 0, "interrupt count starts at 0");
    CHECK(kill(getpid(), SIGINT) == 0, "deliver one SIGINT");
    CHECK(mtest_exec_interrupt_count() == 1,
          "one observed activation counts 1");

    /* Saturation: further activations saturate at 2 and never overflow. */
    CHECK(kill(getpid(), SIGTERM) == 0, "deliver SIGTERM");
    CHECK(mtest_exec_interrupt_count() == 2,
          "a second observed activation escalates to 2");
    CHECK(kill(getpid(), SIGINT) == 0, "deliver a third signal");
    CHECK(mtest_exec_interrupt_count() == 2,
          "the count saturates at 2");
    mtest_exec_test_reset_interrupt();
    CHECK(mtest_exec_interrupt_count() == 0, "reset re-arms the counter");

    /* Forced reentry: a one-shot hook re-enters the handler mid-transition, via
       a direct recursive call -- genuine nesting, no lost transition. */
    mtest_exec_test_arm_interrupt_reentry();
    mtest_exec_test_invoke_interrupt();
    CHECK(mtest_exec_interrupt_count() == 2,
          "forced mid-transition reentry still reaches exactly 2");
    mtest_exec_test_reset_interrupt();

    /* Real back-to-back delivery through an unmasked (SA_NODEFER) install. */
    CHECK(mtest_exec_test_nested_interrupt_count() == 2,
          "real nested delivery reaches 2 with no lost transition");
    mtest_exec_test_reset_interrupt();
    return 0;
}

int main(void) {
    CHECK(exercise_platform_constants() == 0, "platform constants");
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
    CHECK(mtest_exec_native_abi_version() == 2u, "ABI version is 2");
    CHECK(exercise_interrupt_counting() == 0, "counted interrupt escalation");

    int64_t now = 0;
    CHECK(mtest_exec_monotonic_ms(&now, &error) == 0 && now > 0,
          "monotonic clock");
    CHECK(exercise_process() == 0, "real process supervision seam");
    CHECK(exercise_slot_capacity() == 0, "multi-child slot capacity");
    CHECK(exercise_stale_token() == 0, "stale token rejection and reuse");
    CHECK(exercise_poll_set_readiness() == 0, "poll_set readiness truth");
    CHECK(exercise_poll_set_hostile_structural() == 0,
          "poll_set structural hostile callers");
    CHECK(exercise_poll_set_hostile_semantic() == 0,
          "poll_set semantic hostile callers");
    CHECK(exercise_handle_scoped_fault() == 0, "handle-scoped fault targeting");
    CHECK(exercise_env_validation() == 0, "env override validation");
    CHECK(exercise_env_merge() == 0, "env override merge");
    CHECK(exercise_fd_limit() == 0, "fd limit query");
    CHECK(exercise_fd_limit_peak() == 0, "fd limit raw spawn peak");
    CHECK(exercise_emfile_pipe_cleanup() == 0,
          "EMFILE pipe-creation cleanup under Valgrind");
    CHECK(exercise_preobserve_zombie_only_term() == 0,
          "pre-observe zombie-only group TERM");
    CHECK(exercise_reaped_unswept_abort() == 0,
          "reaped unswept abort stays terminal");
    CHECK(exercise_terminal_setpgid_cleanup() == 0,
          "terminal setpgid cleanup stays non-reusable");
    int closed_standard_fds_result =
        exercise_process_with_closed_standard_fds();
    CHECK(closed_standard_fds_result == 0,
          "capture survives closed stdin and stdout");
    CHECK(exercise_second_candidate_allocation_failure() == 0,
          "second candidate allocation failure seam");
    CHECK(exercise_consumed_close_error() == 0,
          "consumed close error ownership");
    CHECK(exercise_retryable_abort_group_kill() == 0,
          "retryable abort group kill");
    CHECK(exercise_transient_group_signal_eperm() == 0,
          "transient group-signal EPERM retry");
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_CHILD_SETUP_WRITE, 1, EIO, 9
          ) == -1,
          "reject oversized setup-record fault");

    struct mtest_exec_bytes fault_argv[1] = {bytes("/usr/bin/true")};
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

    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_PARENT_SETPGID, 1, EIO, 0
          ) == 0,
          "configure parent setpgid failure");
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_WAITPID, 1, EINTR, 0
          ) == 0,
          "configure interrupted setpgid cleanup reap");
    CHECK(mtest_exec_process_open(
              &fault_spec, &fault_process, &error
          ) == -1,
          "parent setpgid failure rejects open");
    CHECK(error.operation == MTEST_EXEC_OP_PARENT_SETPGID &&
              error.error_number == EIO,
          "parent setpgid error remains primary");
    CHECK(mtest_exec_test_fault_seen(MTEST_EXEC_OP_WAITPID) == 1,
          "setpgid cleanup uses named wait seam exactly once");
    pid_t failed_leader = (pid_t)error.subject;
    errno = 0;
    CHECK(waitpid(failed_leader, NULL, WNOHANG) == -1 && errno == ECHILD,
          "setpgid cleanup reaps the exact child after EINTR");
    mtest_exec_test_fault_reset();
    CHECK(mtest_exec_process_open(
              &fault_spec, &fault_process, &error
          ) == 0,
          "runtime is reusable after proven setpgid cleanup");
    CHECK(mtest_exec_process_abort(
              fault_process.handle, 0, &error
          ) == 0,
          "ordinary lifecycle follows setpgid cleanup");

    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_PARENT_SETPGID, 1, EIO, 0
          ) == 0,
          "configure parent setpgid failure before ECHILD");
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_WAITPID, 1, ECHILD, 0
          ) == 0,
          "configure ECHILD setpgid cleanup reap");
    CHECK(mtest_exec_process_open(
              &fault_spec, &fault_process, &error
          ) == -1,
          "parent setpgid failure with ECHILD rejects open");
    CHECK(error.operation == MTEST_EXEC_OP_PARENT_SETPGID &&
              error.error_number == EIO,
          "ECHILD cleanup retains setpgid error as primary");
    CHECK(error.cleanup_operation == MTEST_EXEC_OP_NONE &&
              error.cleanup_error_number == 0,
          "ECHILD proves cleanup without a terminal error");
    CHECK(mtest_exec_test_fault_seen(MTEST_EXEC_OP_WAITPID) == 1,
          "ECHILD cleanup consults wait seam exactly once");
    failed_leader = (pid_t)error.subject;
    mtest_exec_test_fault_reset();
    pid_t echid_waited;
    do {
        echid_waited = waitpid(failed_leader, NULL, 0);
    } while (echid_waited < 0 && errno == EINTR);
    CHECK(echid_waited == failed_leader ||
              (echid_waited < 0 && errno == ECHILD),
          "test process disposes simulated ECHILD child");
    CHECK(mtest_exec_process_open(
              &fault_spec, &fault_process, &error
          ) == 0,
          "runtime is reusable after ECHILD setpgid cleanup");
    CHECK(mtest_exec_process_abort(
              fault_process.handle, 0, &error
          ) == 0,
          "ordinary lifecycle follows ECHILD cleanup");

    CHECK(mtest_exec_process_open(
              &fault_spec, &fault_process, &error
          ) == 0,
          "open child for abort TERM-error precedence");
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_GROUP_TERM, 1, EIO, 0
          ) == 0,
          "configure abort TERM failure");
    CHECK(mtest_exec_process_abort(
              fault_process.handle, 0, &error
          ) == -1,
          "abort retains TERM error after successful cleanup");
    CHECK(error.operation == MTEST_EXEC_OP_NONE &&
              error.error_number == 0 &&
              error.cleanup_operation == MTEST_EXEC_OP_GROUP_TERM &&
              error.cleanup_error_number == EIO,
          "abort TERM cleanup error is exact");
    mtest_exec_test_fault_reset();
    CHECK(mtest_exec_process_open(
              &fault_spec, &fault_process, &error
          ) == 0,
          "TERM-error cleanup consumed handle despite diagnostic");
    CHECK(mtest_exec_process_abort(
              fault_process.handle, 0, &error
          ) == 0,
          "clean child after TERM-error recovery proof");

    CHECK(mtest_exec_process_open(
              &fault_spec, &fault_process, &error
          ) == 0,
          "open child for abort TERM-plus-clock precedence");
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_GROUP_TERM, 1, EIO, 0
          ) == 0,
          "configure abort TERM failure before clock failure");
    CHECK(mtest_exec_test_fault_configure(
              MTEST_EXEC_OP_CLOCK_MONOTONIC, 1, EPERM, 0
          ) == 0,
          "configure abort clock failure after TERM failure");
    CHECK(mtest_exec_process_abort(
              fault_process.handle, 0, &error
          ) == -1,
          "abort retains TERM error beside primary clock error");
    CHECK(error.operation == MTEST_EXEC_OP_CLOCK_MONOTONIC &&
              error.error_number == EPERM &&
              error.cleanup_operation == MTEST_EXEC_OP_GROUP_TERM &&
              error.cleanup_error_number == EIO,
          "abort TERM-plus-clock precedence is exact");
    mtest_exec_test_fault_reset();
    CHECK(mtest_exec_process_open(
              &fault_spec, &fault_process, &error
          ) == 0,
          "TERM-plus-clock cleanup consumed handle despite diagnostic");
    CHECK(mtest_exec_process_abort(
              fault_process.handle, 0, &error
          ) == 0,
          "clean child after TERM-plus-clock recovery proof");

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
    CHECK(mtest_exec_process_open(
              &fault_spec, &fault_process, &error
          ) == 0,
          "clock-error cleanup consumed handle despite diagnostic");
    CHECK(mtest_exec_process_abort(
              fault_process.handle, 0, &error
          ) == 0,
          "clean child after clock-error recovery proof");
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
    struct mtest_exec_bytes blocked_argv[1] = {bytes("/usr/bin/true")};
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
