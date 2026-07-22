/* KERN_PROC_PGRP is a Darwin extension whose public structures use BSD types
   hidden by a strict POSIX feature level. Request both namespaces explicitly. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L

#include "mtest_exec_native.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>

#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif

#if MTEST_EXEC_TESTING
#include "mtest_exec_native_test.h"
#endif

extern char **environ;

#define MTEST_ETXTBSY_RETRIES 5u
#define MTEST_ETXTBSY_DELAY_MS 50
#define MTEST_ABORT_SLICE_NS 10000000L
#define MTEST_DARWIN_GROUP_EPERM_RETRIES 20u
#define MTEST_DARWIN_GROUP_EPERM_RETRY_NS 1000000L

_Static_assert(sizeof(sig_atomic_t) <= sizeof(int32_t), "sig_atomic_t width");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "runtime ownership must be lock-free");

struct mtest_exec_plan {
    char **argv;
    size_t argc;
    char **environment;
    char *cwd;
    int has_cwd;
    char **candidates;
    char ***shell_argv;
    size_t candidate_count;
};

struct mtest_exec_process {
    uint64_t handle;
    pid_t leader;
    pid_t process_group;
    int stdout_fd;
    int stderr_fd;
    int setup_fd;
    int observed;
    int reaped;
    int group_swept;
};

enum mtest_runtime_state {
    MTEST_RUNTIME_CLOSED = 0,
    MTEST_RUNTIME_OPENING = 1,
    MTEST_RUNTIME_OPEN = 2,
    MTEST_RUNTIME_CHILD_ACTIVE = 3,
    MTEST_RUNTIME_RESTORE_REQUIRED = 4
};

/* Fixed-size process registry. Each slot pairs a record with its own lock-free
   lifecycle latch: a slot is claimed by a FREE->ACTIVE compare-exchange and
   released back to FREE once its child is fully torn down. The capacity is
   pinned to one, so exactly one live child is admitted at a time; the loops and
   the token-validated handle lookup are written to hold for any capacity. */
#define MTEST_EXEC_SLOT_CAPACITY 1u

enum mtest_slot_lifecycle {
    MTEST_SLOT_FREE = 0,
    MTEST_SLOT_ACTIVE = 1
};

/* SAFETY: the signal handler accesses only `mtest_interrupt_flag`. The runtime
   state machine and the per-slot lifecycle latches are lock-free atomics; every
   record field is ordinary-thread state read only after a passing lifecycle and
   token check. With the table pinned to one slot, a second runtime or a second
   live child is still rejected exactly as before. */
static volatile sig_atomic_t mtest_interrupt_flag;
static _Atomic int mtest_runtime_state;
static struct mtest_exec_process mtest_process[MTEST_EXEC_SLOT_CAPACITY];
static _Atomic int mtest_slot_lifecycle[MTEST_EXEC_SLOT_CAPACITY];
static uint64_t mtest_next_handle = 1;
static struct sigaction mtest_old_int;
static struct sigaction mtest_old_term;
static struct sigaction mtest_old_chld;
static struct sigaction mtest_old_pipe;
static int mtest_old_int_saved;
static int mtest_old_term_saved;
static int mtest_old_chld_saved;
static int mtest_old_pipe_saved;
static int mtest_int_installed;
static int mtest_term_installed;
static int mtest_chld_installed;
/* SIGPIPE is ignored for the runtime's lifetime (the SECOND deliberate exec
   carve-out, after the tty probe): a broken destination pipe -- a `--json -`
   consumer that closed early, e.g. `mtest --json - | head` -- must return EPIPE
   to the reporter's write so it can latch a fatal abort, never kill mtest with
   the default SIGPIPE disposition (death at 141). The previous disposition is
   saved here and restored on close, symmetrically with SIGINT/SIGTERM. */
static int mtest_pipe_installed;

#if MTEST_EXEC_TESTING
#define MTEST_TEST_MONOTONIC_WAIT_MAX_MS 10000u

struct mtest_fault_state {
    uint32_t operation;
    uint32_t occurrence;
    uint32_t seen;
    int32_t error_number;
    int64_t result_value;
    uint32_t secondary_occurrence;
    int32_t secondary_error_number;
    int64_t secondary_result_value;
};

static struct mtest_fault_state mtest_faults[MTEST_EXEC_OP_WAITPID + 1];
static uint32_t mtest_interrupt_delivery_operation;
static int mtest_interrupt_delivery_signal;
static uint32_t mtest_group_signal_eperm_operation;
static uint32_t mtest_group_signal_eperm_forced_failures;
static uint32_t mtest_group_signal_eperm_seen;
static uint32_t mtest_monotonic_wait_occurrence;
static uint32_t mtest_monotonic_wait_seen;
static uint32_t mtest_monotonic_wait_max_ms;
static uint32_t mtest_monotonic_wait_fired;

int32_t mtest_exec_test_constant(uint32_t constant_id) {
    switch (constant_id) {
        case MTEST_EXEC_TEST_CONSTANT_SIGCHLD:
            return SIGCHLD;
        case MTEST_EXEC_TEST_CONSTANT_EIO:
            return EIO;
        case MTEST_EXEC_TEST_CONSTANT_ETXTBSY:
            return ETXTBSY;
        default:
            return -1;
    }
}

static int mtest_fail_if_requested(uint32_t operation) {
    if (operation == MTEST_EXEC_OP_NONE || operation > MTEST_EXEC_OP_WAITPID) {
        return 0;
    }
    struct mtest_fault_state *fault = &mtest_faults[operation];
    if (fault->operation != operation) {
        return 0;
    }
    fault->seen += 1;
    if (fault->seen == fault->occurrence) {
        errno = fault->error_number;
        return 1;
    }
    if (fault->seen == fault->secondary_occurrence) {
        errno = fault->secondary_error_number;
        return 1;
    }
    return 0;
}

static int64_t mtest_fault_result(uint32_t operation) {
    if (operation <= MTEST_EXEC_OP_WAITPID) {
        const struct mtest_fault_state *fault = &mtest_faults[operation];
        if (fault->operation == operation &&
            fault->seen == fault->occurrence) {
            return fault->result_value;
        }
        if (fault->operation == operation &&
            fault->seen == fault->secondary_occurrence) {
            return fault->secondary_result_value;
        }
    }
    return 0;
}

void mtest_exec_test_fault_reset(void) {
    memset(mtest_faults, 0, sizeof(mtest_faults));
    mtest_interrupt_delivery_operation = MTEST_EXEC_OP_NONE;
    mtest_interrupt_delivery_signal = 0;
    mtest_group_signal_eperm_operation = MTEST_EXEC_OP_NONE;
    mtest_group_signal_eperm_forced_failures = 0;
    mtest_group_signal_eperm_seen = 0;
    mtest_monotonic_wait_occurrence = 0;
    mtest_monotonic_wait_seen = 0;
    mtest_monotonic_wait_max_ms = 0;
    mtest_monotonic_wait_fired = 0;
}

int32_t mtest_exec_test_fault_configure(
    uint32_t operation,
    uint32_t occurrence,
    int32_t error_number,
    int64_t result_value
) {
    if (operation == MTEST_EXEC_OP_NONE || operation > MTEST_EXEC_OP_WAITPID ||
        occurrence == 0 || error_number < 0 || result_value < 0) {
        return -1;
    }
    if (operation == MTEST_EXEC_OP_CHILD_SETUP_WRITE) {
        if (error_number == 0 &&
            (result_value < 1 ||
             result_value >= (int64_t)sizeof(
                 ((struct mtest_exec_setup_state *)0)->raw
             ))) {
            return -1;
        }
        if (error_number > 0 && result_value != 0) {
            return -1;
        }
    } else if (result_value != 0 || error_number == 0) {
        return -1;
    }
    struct mtest_fault_state *fault = &mtest_faults[operation];
    fault->operation = operation;
    fault->occurrence = occurrence;
    fault->seen = 0;
    fault->error_number = error_number;
    fault->result_value = result_value;
    fault->secondary_occurrence = 0;
    fault->secondary_error_number = 0;
    fault->secondary_result_value = 0;
    return 0;
}

int32_t mtest_exec_test_fault_configure_secondary(
    uint32_t operation,
    uint32_t occurrence,
    int32_t error_number,
    int64_t result_value
) {
    if (operation == MTEST_EXEC_OP_NONE || operation > MTEST_EXEC_OP_WAITPID ||
        occurrence == 0 || error_number < 0 || result_value < 0) {
        return -1;
    }
    struct mtest_fault_state *fault = &mtest_faults[operation];
    if (fault->operation != operation || occurrence <= fault->occurrence) {
        return -1;
    }
    if (operation == MTEST_EXEC_OP_CHILD_SETUP_WRITE) {
        if (error_number == 0 &&
            (result_value < 1 ||
             result_value >= (int64_t)sizeof(
                 ((struct mtest_exec_setup_state *)0)->raw
             ))) {
            return -1;
        }
        if (error_number > 0 && result_value != 0) {
            return -1;
        }
    } else if (result_value != 0 || error_number == 0) {
        return -1;
    }
    fault->secondary_occurrence = occurrence;
    fault->secondary_error_number = error_number;
    fault->secondary_result_value = result_value;
    return 0;
}

uint32_t mtest_exec_test_fault_seen(uint32_t operation) {
    if (operation > MTEST_EXEC_OP_WAITPID) {
        return 0;
    }
    const struct mtest_fault_state *fault = &mtest_faults[operation];
    return fault->operation == operation ? fault->seen : 0;
}

int32_t mtest_exec_test_group_signal_eperm_configure(
    uint32_t operation,
    uint32_t forced_failures
) {
    if ((operation != MTEST_EXEC_OP_GROUP_TERM &&
         operation != MTEST_EXEC_OP_GROUP_KILL) ||
        forced_failures == 0) {
        return -1;
    }
    mtest_group_signal_eperm_operation = operation;
    mtest_group_signal_eperm_forced_failures = forced_failures;
    mtest_group_signal_eperm_seen = 0;
    return 0;
}

uint32_t mtest_exec_test_group_signal_eperm_seen(uint32_t operation) {
    return operation == mtest_group_signal_eperm_operation
        ? mtest_group_signal_eperm_seen
        : 0;
}

int32_t mtest_exec_test_monotonic_wait_configure(
    uint32_t occurrence,
    uint32_t max_wait_ms
) {
    if (occurrence == 0 || max_wait_ms == 0 ||
        max_wait_ms > MTEST_TEST_MONOTONIC_WAIT_MAX_MS) {
        return -1;
    }
    mtest_monotonic_wait_occurrence = occurrence;
    mtest_monotonic_wait_seen = 0;
    mtest_monotonic_wait_max_ms = max_wait_ms;
    mtest_monotonic_wait_fired = 0;
    return 0;
}

uint32_t mtest_exec_test_monotonic_wait_fired(void) {
    return mtest_monotonic_wait_fired;
}

static void mtest_wait_before_monotonic_if_requested(void) {
    if (mtest_monotonic_wait_occurrence == 0) {
        return;
    }
    mtest_monotonic_wait_seen += 1;
    if (mtest_monotonic_wait_seen != mtest_monotonic_wait_occurrence) {
        return;
    }
    /* SAFETY: locate the live child through the slot lifecycle before reading
       its leader; a FREE slot's record is never consulted. */
    struct mtest_exec_process *process = NULL;
    for (size_t index = 0; index < MTEST_EXEC_SLOT_CAPACITY; ++index) {
        if (atomic_load(&mtest_slot_lifecycle[index]) == MTEST_SLOT_ACTIVE &&
            mtest_process[index].handle != 0 &&
            mtest_process[index].leader > 0) {
            process = &mtest_process[index];
            break;
        }
    }
    if (process == NULL) {
        return;
    }
    const struct timespec delay = {0, 1000000L};
    for (uint32_t attempt = 0;
         attempt <= mtest_monotonic_wait_max_ms;
         ++attempt) {
        siginfo_t information;
        memset(&information, 0, sizeof(information));
        int wait_status;
        do {
            wait_status = waitid(
                P_PID,
                (id_t)process->leader,
                &information,
                WEXITED | WNOHANG | WNOWAIT
            );
        } while (wait_status != 0 && errno == EINTR);
        if (wait_status != 0) {
            return;
        }
        if (information.si_pid == process->leader) {
            mtest_monotonic_wait_fired = 1;
            return;
        }
        if (attempt < mtest_monotonic_wait_max_ms) {
            (void)nanosleep(&delay, NULL);
        }
    }
}

void mtest_exec_test_reset_interrupt(void) {
    mtest_interrupt_flag = 0;
}

int32_t mtest_exec_test_deliver_interrupt_after(
    uint32_t operation,
    int32_t signal_number
) {
    if ((operation != MTEST_EXEC_OP_SIGACTION_INSTALL_INT ||
         signal_number != SIGINT) &&
        (operation != MTEST_EXEC_OP_SIGACTION_INSTALL_TERM ||
         signal_number != SIGTERM)) {
        return -1;
    }
    mtest_interrupt_delivery_operation = operation;
    mtest_interrupt_delivery_signal = signal_number;
    return 0;
}
#else
static int mtest_fail_if_requested(uint32_t operation) {
    (void)operation;
    return 0;
}

static int64_t mtest_fault_result(uint32_t operation) {
    (void)operation;
    return 0;
}
#endif

__attribute__((no_sanitize("address")))
static void mtest_on_interrupt(int signal_number) {
    (void)signal_number;
    /* SAFETY: POSIX permits a signal handler to assign a process-global
       volatile sig_atomic_t. ASan instrumentation is excluded only here
       because its reporting path is not async-signal-safe. */
    mtest_interrupt_flag = 1;
}

static void mtest_clear_error(struct mtest_exec_error *error) {
    if (error != NULL) {
        memset(error, 0, sizeof(*error));
    }
}

static void mtest_set_error(
    struct mtest_exec_error *error,
    uint32_t operation,
    int error_number,
    uint64_t detail,
    int64_t subject
) {
    if (error == NULL) {
        return;
    }
    error->operation = operation;
    error->error_number = error_number;
    error->detail = detail;
    error->subject = subject;
}

static void mtest_set_cleanup_error(
    struct mtest_exec_error *error,
    uint32_t operation,
    int error_number
) {
    if (error != NULL && error->cleanup_operation == MTEST_EXEC_OP_NONE) {
        error->cleanup_operation = operation;
        error->cleanup_error_number = error_number;
    }
}

static int mtest_checked_sigaction(
    uint32_t operation,
    int signal_number,
    const struct sigaction *action,
    struct sigaction *old_action
) {
    if (mtest_fail_if_requested(operation)) {
        return -1;
    }
    int result = sigaction(signal_number, action, old_action);
#if MTEST_EXEC_TESTING
    if (result == 0 && operation == mtest_interrupt_delivery_operation) {
        int delivered_signal = mtest_interrupt_delivery_signal;
        mtest_interrupt_delivery_operation = MTEST_EXEC_OP_NONE;
        mtest_interrupt_delivery_signal = 0;
        /* SAFETY: this test-only seam runs in ordinary single-threaded test
           code after sigaction returned successfully. `raise` synchronously
           invokes the newly installed handler, which only assigns the
           process-global volatile sig_atomic_t latch and retains no state. */
        (void)raise(delivered_signal);
    }
#endif
    return result;
}

static int mtest_close_raw(int fd) {
    int result = close(fd);
#if defined(__APPLE__)
    while (result != 0 && errno == EINTR) {
        result = close(fd);
    }
#else
    if (result != 0 && errno == EINTR) {
        result = 0;
    }
#endif
    return result;
}

static int mtest_close_owned(int *fd) {
    /* SAFETY: the caller exclusively owns the descriptor slot. Clear it before
       entering close because Linux consumes the descriptor even when close
       reports a late error; no cleanup path may retry a reusable integer. On
       Darwin, mtest_close_raw resolves EINTR before returning. */
    int closing = *fd;
    *fd = -1;
    return mtest_close_raw(closing);
}

static void mtest_close_quietly(int *fd) {
    if (*fd >= 0) {
        (void)mtest_close_owned(fd);
    }
}

static void *mtest_allocate(uint32_t operation, size_t size) {
    if (mtest_fail_if_requested(operation)) {
        return NULL;
    }
    void *memory = calloc(1, size);
    if (memory == NULL && errno == 0) {
        errno = ENOMEM;
    }
    return memory;
}

static char *mtest_copy_bytes(
    uint32_t operation,
    const uint8_t *data,
    uint64_t length
) {
    /* SAFETY: on success this function owns `length + 1` bytes, copies only the
       caller-declared initialized range, rejects embedded NUL, initializes the
       terminator, and returns sole ownership to the plan that frees it. */
    if (length > SIZE_MAX - 1 || (length > 0 && data == NULL)) {
        errno = EINVAL;
        return NULL;
    }
    char *copy = mtest_allocate(operation, (size_t)length + 1);
    if (copy == NULL) {
        return NULL;
    }
    if (length > 0) {
        memcpy(copy, data, (size_t)length);
        if (memchr(copy, '\0', (size_t)length) != NULL) {
            free(copy);
            errno = EINVAL;
            return NULL;
        }
    }
    copy[length] = '\0';
    return copy;
}

static void mtest_free_vector(char **vector) {
    if (vector == NULL) {
        return;
    }
    for (size_t index = 0; vector[index] != NULL; ++index) {
        free(vector[index]);
    }
    free(vector);
}

static void mtest_free_plan(struct mtest_exec_plan *plan) {
    if (plan == NULL) {
        return;
    }
    if (plan->shell_argv != NULL) {
        for (size_t index = 0; index < plan->candidate_count; ++index) {
            free(plan->shell_argv[index]);
        }
    }
    free(plan->shell_argv);
    if (plan->candidates != NULL) {
        /* SAFETY: the calloc-zeroed array has `candidate_count + 1` slots and
           every non-NULL counted slot is a distinct plan-owned allocation.
           Freeing the full counted range handles partial construction without
           treating an interior NULL as the ownership boundary. */
        for (size_t index = 0; index < plan->candidate_count; ++index) {
            free(plan->candidates[index]);
        }
    }
    free(plan->candidates);
    mtest_free_vector(plan->environment);
    mtest_free_vector(plan->argv);
    free(plan->cwd);
    free(plan);
}

static int mtest_copy_argv(
    const struct mtest_exec_process_spec *spec,
    struct mtest_exec_plan *plan
) {
    if (spec->argc == 0 || spec->argc > SIZE_MAX / sizeof(char *) - 1 ||
        spec->argv == NULL) {
        errno = EINVAL;
        return -1;
    }
    plan->argv = mtest_allocate(
        MTEST_EXEC_OP_PLAN_ALLOC,
        ((size_t)spec->argc + 1) * sizeof(char *)
    );
    if (plan->argv == NULL) {
        return -1;
    }
    plan->argc = (size_t)spec->argc;
    for (size_t index = 0; index < plan->argc; ++index) {
        if (index == 0 && spec->argv[index].length == 0) {
            errno = EINVAL;
            return -1;
        }
        plan->argv[index] = mtest_copy_bytes(
            MTEST_EXEC_OP_PLAN_ALLOC,
            spec->argv[index].data,
            spec->argv[index].length
        );
        if (plan->argv[index] == NULL) {
            return -1;
        }
    }
    return 0;
}

static int mtest_copy_environment(struct mtest_exec_plan *plan) {
    /* SAFETY: runtime ownership requires no concurrent environment mutation.
       Each observed NUL-terminated entry is copied into plan-owned storage
       before fork, and the child only reads its copy until execve. */
    size_t count = 0;
    while (environ[count] != NULL) {
        if (count == SIZE_MAX / sizeof(char *) - 1) {
            errno = EOVERFLOW;
            return -1;
        }
        count += 1;
    }
    plan->environment = mtest_allocate(
        MTEST_EXEC_OP_ENV_SNAPSHOT,
        (count + 1) * sizeof(char *)
    );
    if (plan->environment == NULL) {
        return -1;
    }
    for (size_t index = 0; index < count; ++index) {
        size_t length = strlen(environ[index]);
        plan->environment[index] = mtest_copy_bytes(
            MTEST_EXEC_OP_ENV_SNAPSHOT,
            (const uint8_t *)environ[index],
            length
        );
        if (plan->environment[index] == NULL) {
            return -1;
        }
    }
    return 0;
}

static const char *mtest_environment_path(char **environment) {
    for (size_t index = 0; environment[index] != NULL; ++index) {
        if (strncmp(environment[index], "PATH=", 5) == 0) {
            return environment[index] + 5;
        }
    }
    return NULL;
}

static char *mtest_default_path(void) {
    if (mtest_fail_if_requested(MTEST_EXEC_OP_PATH_CONFSTR)) {
        return NULL;
    }
    errno = 0;
    size_t length = confstr(_CS_PATH, NULL, 0);
    if (length == 0) {
        if (errno == 0) {
            errno = EINVAL;
        }
        return NULL;
    }
    char *path = mtest_allocate(MTEST_EXEC_OP_PATH_CONFSTR, length);
    if (path == NULL) {
        return NULL;
    }
    if (confstr(_CS_PATH, path, length) == 0) {
        int saved_errno = errno == 0 ? EINVAL : errno;
        free(path);
        errno = saved_errno;
        return NULL;
    }
    return path;
}

static int mtest_has_slash(const char *text) {
    return strchr(text, '/') != NULL;
}

static char *mtest_join_candidate(
    const char *component,
    size_t component_length,
    const char *program
) {
    size_t program_length = strlen(program);
    if (component_length == 0) {
        return mtest_copy_bytes(
            MTEST_EXEC_OP_PLAN_ALLOC,
            (const uint8_t *)program,
            program_length
        );
    }
    if (component_length > SIZE_MAX - program_length - 2) {
        errno = EOVERFLOW;
        return NULL;
    }
    size_t length = component_length + 1 + program_length;
    char *candidate = mtest_allocate(MTEST_EXEC_OP_PLAN_ALLOC, length + 1);
    if (candidate == NULL) {
        return NULL;
    }
    memcpy(candidate, component, component_length);
    candidate[component_length] = '/';
    memcpy(candidate + component_length + 1, program, program_length);
    candidate[length] = '\0';
    return candidate;
}

static int mtest_build_candidates(struct mtest_exec_plan *plan) {
    char *owned_default = NULL;
    const char *path = mtest_environment_path(plan->environment);
    if (mtest_has_slash(plan->argv[0])) {
        plan->candidate_count = 1;
    } else {
        if (path == NULL) {
            owned_default = mtest_default_path();
            if (owned_default == NULL) {
                return -1;
            }
            path = owned_default;
        }
        plan->candidate_count = 1;
        for (const char *cursor = path; *cursor != '\0'; ++cursor) {
            if (*cursor == ':') {
                plan->candidate_count += 1;
            }
        }
    }
    plan->candidates = mtest_allocate(
        MTEST_EXEC_OP_PLAN_ALLOC,
        (plan->candidate_count + 1) * sizeof(char *)
    );
    plan->shell_argv = mtest_allocate(
        MTEST_EXEC_OP_PLAN_ALLOC,
        plan->candidate_count * sizeof(char **)
    );
    if (plan->candidates == NULL || plan->shell_argv == NULL) {
        free(owned_default);
        return -1;
    }
    int candidate_error = 0;
    if (mtest_has_slash(plan->argv[0])) {
        plan->candidates[0] = mtest_join_candidate("", 0, plan->argv[0]);
        if (plan->candidates[0] == NULL) {
            candidate_error = errno;
        }
    } else {
        const char *component = path;
        for (size_t index = 0; index < plan->candidate_count; ++index) {
            const char *separator = strchr(component, ':');
            size_t length = separator == NULL
                ? strlen(component)
                : (size_t)(separator - component);
            plan->candidates[index] = mtest_join_candidate(
                component, length, plan->argv[0]
            );
            if (plan->candidates[index] == NULL && candidate_error == 0) {
                candidate_error = errno;
            }
            component = separator == NULL ? component + length : separator + 1;
        }
    }
    free(owned_default);
    for (size_t index = 0; index < plan->candidate_count; ++index) {
        if (plan->candidates[index] == NULL) {
            errno = candidate_error;
            return -1;
        }
    }
    for (size_t index = 0; index < plan->candidate_count; ++index) {
        plan->shell_argv[index] = mtest_allocate(
            MTEST_EXEC_OP_PLAN_ALLOC,
            (plan->argc + 2) * sizeof(char *)
        );
        if (plan->shell_argv[index] == NULL) {
            return -1;
        }
        plan->shell_argv[index][0] = (char *)"/bin/sh";
        plan->shell_argv[index][1] = plan->candidates[index];
        for (size_t argument = 1; argument < plan->argc; ++argument) {
            plan->shell_argv[index][argument + 1] = plan->argv[argument];
        }
    }
    return 0;
}

static struct mtest_exec_plan *mtest_build_plan(
    const struct mtest_exec_process_spec *spec,
    struct mtest_exec_error *error
) {
    if (spec == NULL || spec->reserved != 0 ||
        (spec->flags & ~MTEST_EXEC_PROCESS_HAS_CWD) != 0) {
        mtest_set_error(error, MTEST_EXEC_OP_PLAN_ALLOC, EINVAL, 0, 0);
        return NULL;
    }
    struct mtest_exec_plan *plan = mtest_allocate(
        MTEST_EXEC_OP_PLAN_ALLOC, sizeof(*plan)
    );
    if (plan == NULL) {
        mtest_set_error(error, MTEST_EXEC_OP_PLAN_ALLOC, errno, 0, 0);
        return NULL;
    }
    if (mtest_copy_argv(spec, plan) != 0) {
        mtest_set_error(error, MTEST_EXEC_OP_PLAN_ALLOC, errno, 0, 0);
        mtest_free_plan(plan);
        return NULL;
    }
    plan->has_cwd = (spec->flags & MTEST_EXEC_PROCESS_HAS_CWD) != 0;
    if (plan->has_cwd) {
        plan->cwd = mtest_copy_bytes(
            MTEST_EXEC_OP_PLAN_ALLOC, spec->cwd.data, spec->cwd.length
        );
        if (plan->cwd == NULL) {
            mtest_set_error(error, MTEST_EXEC_OP_PLAN_ALLOC, errno, 0, 0);
            mtest_free_plan(plan);
            return NULL;
        }
    }
    if (mtest_copy_environment(plan) != 0) {
        mtest_set_error(error, MTEST_EXEC_OP_ENV_SNAPSHOT, errno, 0, 0);
        mtest_free_plan(plan);
        return NULL;
    }
    if (mtest_build_candidates(plan) != 0) {
        uint32_t operation = errno == EINVAL
            ? MTEST_EXEC_OP_PATH_CONFSTR
            : MTEST_EXEC_OP_PLAN_ALLOC;
        mtest_set_error(error, operation, errno, 0, 0);
        mtest_free_plan(plan);
        return NULL;
    }
    return plan;
}

static struct mtest_exec_process *mtest_claim_slot(void) {
    /* SAFETY: scan for a FREE slot and win it with a FREE->ACTIVE
       compare-exchange. Only the thread that wins the exchange owns the record,
       so no two callers ever initialize the same slot. At capacity one a second
       claim finds no FREE slot and returns NULL, which the caller maps to the
       same EBUSY the runtime gate already reports. */
    for (size_t index = 0; index < MTEST_EXEC_SLOT_CAPACITY; ++index) {
        int expected = MTEST_SLOT_FREE;
        if (atomic_compare_exchange_strong(
                &mtest_slot_lifecycle[index], &expected, MTEST_SLOT_ACTIVE
            )) {
            return &mtest_process[index];
        }
    }
    return NULL;
}

static void mtest_release_slot(struct mtest_exec_process *process) {
    /* SAFETY: `process` points into the slot table, so the difference is its
       slot index. Clear the record before publishing the slot as FREE, so no
       later claimer or concurrent lookup can observe a live token over reused
       storage; a lookup that races the store still rejects a FREE slot. */
    size_t index = (size_t)(process - mtest_process);
    memset(process, 0, sizeof(*process));
    atomic_store(&mtest_slot_lifecycle[index], MTEST_SLOT_FREE);
}

static uint64_t mtest_first_live_handle(void) {
    /* SAFETY: a slot's published handle is meaningful only while the slot is
       ACTIVE; a FREE slot's record is never read. Returns the first live token,
       or zero when a slot is claimed but has not yet published one (an open
       still in flight, or one wedged after a failed hand-off). */
    for (size_t index = 0; index < MTEST_EXEC_SLOT_CAPACITY; ++index) {
        if (atomic_load(&mtest_slot_lifecycle[index]) == MTEST_SLOT_ACTIVE) {
            uint64_t handle = mtest_process[index].handle;
            if (handle != 0) {
                return handle;
            }
        }
    }
    return 0;
}

uint32_t mtest_exec_native_abi_version(void) {
    return MTEST_EXEC_NATIVE_ABI_VERSION;
}

int32_t mtest_exec_runtime_open(struct mtest_exec_error *error) {
    int expected = MTEST_RUNTIME_CLOSED;
    struct sigaction action;
    struct sigaction child_action;
    int saved_errno;
    int rollback_errno = 0;

    mtest_clear_error(error);
    if (!atomic_compare_exchange_strong(
            &mtest_runtime_state, &expected, MTEST_RUNTIME_OPENING
        )) {
        mtest_set_error(error, MTEST_EXEC_OP_NONE, EBUSY, 0, 0);
        return -1;
    }
    /* SAFETY: the successful atomic transition gives this thread exclusive
       process-global runtime ownership. Clear before installing either mtest
       handler, so no handler-written interrupt can be erased during open. */
    mtest_interrupt_flag = 0;
    memset(&action, 0, sizeof(action));
    action.sa_handler = mtest_on_interrupt;
    action.sa_flags = SA_RESTART;
    memset(&child_action, 0, sizeof(child_action));
    child_action.sa_handler = SIG_DFL;
    if (sigemptyset(&action.sa_mask) != 0 ||
        sigemptyset(&child_action.sa_mask) != 0) {
        saved_errno = errno;
        atomic_store(&mtest_runtime_state, MTEST_RUNTIME_CLOSED);
        mtest_set_error(error, MTEST_EXEC_OP_NONE, saved_errno, 0, 0);
        return -1;
    }
    if (mtest_checked_sigaction(
            MTEST_EXEC_OP_SIGACTION_QUERY_INT, SIGINT, NULL, &mtest_old_int
        ) != 0) {
        saved_errno = errno;
        atomic_store(&mtest_runtime_state, MTEST_RUNTIME_CLOSED);
        mtest_set_error(
            error, MTEST_EXEC_OP_SIGACTION_QUERY_INT, saved_errno, 0, SIGINT
        );
        return -1;
    }
    mtest_old_int_saved = 1;
    if (mtest_checked_sigaction(
            MTEST_EXEC_OP_SIGACTION_QUERY_TERM, SIGTERM, NULL, &mtest_old_term
        ) != 0) {
        saved_errno = errno;
        mtest_old_int_saved = 0;
        atomic_store(&mtest_runtime_state, MTEST_RUNTIME_CLOSED);
        mtest_set_error(
            error, MTEST_EXEC_OP_SIGACTION_QUERY_TERM, saved_errno, 0, SIGTERM
        );
        return -1;
    }
    mtest_old_term_saved = 1;
    if (sigaction(SIGCHLD, NULL, &mtest_old_chld) != 0) {
        saved_errno = errno;
        mtest_old_int_saved = 0;
        mtest_old_term_saved = 0;
        atomic_store(&mtest_runtime_state, MTEST_RUNTIME_CLOSED);
        mtest_set_error(error, MTEST_EXEC_OP_NONE, saved_errno, 0, SIGCHLD);
        return -1;
    }
    mtest_old_chld_saved = 1;
    if (mtest_checked_sigaction(
            MTEST_EXEC_OP_SIGACTION_INSTALL_INT, SIGINT, &action, NULL
        ) != 0) {
        saved_errno = errno;
        mtest_old_int_saved = 0;
        mtest_old_term_saved = 0;
        mtest_old_chld_saved = 0;
        atomic_store(&mtest_runtime_state, MTEST_RUNTIME_CLOSED);
        mtest_set_error(
            error, MTEST_EXEC_OP_SIGACTION_INSTALL_INT, saved_errno, 0, SIGINT
        );
        return -1;
    }
    mtest_int_installed = 1;
    if (mtest_checked_sigaction(
            MTEST_EXEC_OP_SIGACTION_INSTALL_TERM, SIGTERM, &action, NULL
        ) != 0) {
        saved_errno = errno;
        if (mtest_checked_sigaction(
                MTEST_EXEC_OP_SIGACTION_RESTORE_INT,
                SIGINT,
                &mtest_old_int,
                NULL
            ) != 0) {
            rollback_errno = errno;
        } else {
            mtest_int_installed = 0;
        }
        if (rollback_errno == 0) {
            mtest_old_int_saved = 0;
            mtest_old_term_saved = 0;
            mtest_old_chld_saved = 0;
            atomic_store(&mtest_runtime_state, MTEST_RUNTIME_CLOSED);
        } else {
            atomic_store(
                &mtest_runtime_state, MTEST_RUNTIME_RESTORE_REQUIRED
            );
        }
        mtest_set_error(
            error,
            MTEST_EXEC_OP_SIGACTION_INSTALL_TERM,
            saved_errno,
            0,
            SIGTERM
        );
        if (rollback_errno != 0) {
            mtest_set_cleanup_error(
                error, MTEST_EXEC_OP_SIGACTION_RESTORE_INT, rollback_errno
            );
        }
        return -1;
    }
    mtest_term_installed = 1;
    if (sigaction(SIGCHLD, &child_action, NULL) != 0) {
        saved_errno = errno;
        uint32_t rollback_operation = MTEST_EXEC_OP_NONE;
        if (mtest_checked_sigaction(
                MTEST_EXEC_OP_SIGACTION_RESTORE_TERM,
                SIGTERM,
                &mtest_old_term,
                NULL
            ) != 0) {
            rollback_operation = MTEST_EXEC_OP_SIGACTION_RESTORE_TERM;
            rollback_errno = errno;
        } else {
            mtest_term_installed = 0;
        }
        if (mtest_checked_sigaction(
                MTEST_EXEC_OP_SIGACTION_RESTORE_INT,
                SIGINT,
                &mtest_old_int,
                NULL
            ) != 0) {
            if (rollback_errno == 0) {
                rollback_operation = MTEST_EXEC_OP_SIGACTION_RESTORE_INT;
                rollback_errno = errno;
            }
        } else {
            mtest_int_installed = 0;
        }
        if (rollback_errno == 0) {
            mtest_old_int_saved = 0;
            mtest_old_term_saved = 0;
            mtest_old_chld_saved = 0;
            atomic_store(&mtest_runtime_state, MTEST_RUNTIME_CLOSED);
        } else {
            atomic_store(&mtest_runtime_state, MTEST_RUNTIME_RESTORE_REQUIRED);
        }
        mtest_set_error(error, MTEST_EXEC_OP_NONE, saved_errno, 0, SIGCHLD);
        if (rollback_errno != 0) {
            mtest_set_cleanup_error(
                error, rollback_operation, rollback_errno
            );
        }
        return -1;
    }
    mtest_chld_installed = 1;
    /* Ignore SIGPIPE for the runtime's lifetime, saving the old disposition to
       restore on close (mirroring SIGINT/SIGTERM). A plain sigaction like
       SIGCHLD: this carve-out installs a disposition, not a fault-injectable
       mtest handler, so it needs no operation code. Realistically infallible
       for a valid signal, but a failure rolls the whole transaction back. */
    if (sigaction(SIGPIPE, NULL, &mtest_old_pipe) != 0) {
        saved_errno = errno;
        goto sigpipe_rollback;
    }
    mtest_old_pipe_saved = 1;
    {
        struct sigaction pipe_action;
        memset(&pipe_action, 0, sizeof(pipe_action));
        pipe_action.sa_handler = SIG_IGN;
        if (sigemptyset(&pipe_action.sa_mask) != 0 ||
            sigaction(SIGPIPE, &pipe_action, NULL) != 0) {
            saved_errno = errno;
            mtest_old_pipe_saved = 0;
            goto sigpipe_rollback;
        }
    }
    mtest_pipe_installed = 1;
    atomic_store(&mtest_runtime_state, MTEST_RUNTIME_OPEN);
    return 0;

sigpipe_rollback:
    /* SIGPIPE setup failed with nothing SIGPIPE-side installed. Best-effort
       restore SIGCHLD, then SIGTERM, then SIGINT -- the reverse of the install
       order -- before failing closed, exactly as the SIGCHLD-install failure
       path does. A rollback that itself fails leaves RESTORE_REQUIRED for the
       owner's later close to retry. */
    if (sigaction(SIGCHLD, &mtest_old_chld, NULL) != 0) {
        if (rollback_errno == 0) {
            rollback_errno = errno;
        }
    } else {
        mtest_chld_installed = 0;
    }
    {
        uint32_t rollback_operation = MTEST_EXEC_OP_NONE;
        if (mtest_checked_sigaction(
                MTEST_EXEC_OP_SIGACTION_RESTORE_TERM,
                SIGTERM,
                &mtest_old_term,
                NULL
            ) != 0) {
            if (rollback_errno == 0) {
                rollback_operation = MTEST_EXEC_OP_SIGACTION_RESTORE_TERM;
                rollback_errno = errno;
            }
        } else {
            mtest_term_installed = 0;
        }
        if (mtest_checked_sigaction(
                MTEST_EXEC_OP_SIGACTION_RESTORE_INT,
                SIGINT,
                &mtest_old_int,
                NULL
            ) != 0) {
            if (rollback_errno == 0) {
                rollback_operation = MTEST_EXEC_OP_SIGACTION_RESTORE_INT;
                rollback_errno = errno;
            }
        } else {
            mtest_int_installed = 0;
        }
        if (rollback_errno == 0) {
            mtest_old_int_saved = 0;
            mtest_old_term_saved = 0;
            mtest_old_chld_saved = 0;
            mtest_old_pipe_saved = 0;
            atomic_store(&mtest_runtime_state, MTEST_RUNTIME_CLOSED);
        } else {
            atomic_store(&mtest_runtime_state, MTEST_RUNTIME_RESTORE_REQUIRED);
        }
        mtest_set_error(error, MTEST_EXEC_OP_NONE, saved_errno, 0, SIGPIPE);
        if (rollback_errno != 0) {
            mtest_set_cleanup_error(error, rollback_operation, rollback_errno);
        }
        return -1;
    }
}

int32_t mtest_exec_runtime_close(struct mtest_exec_error *error) {
    uint32_t first_operation = MTEST_EXEC_OP_NONE;
    int first_errno = 0;
    int had_failure = 0;
    int expected = MTEST_RUNTIME_OPEN;

    mtest_clear_error(error);
retry_runtime_ownership:
    expected = MTEST_RUNTIME_OPEN;
    if (!atomic_compare_exchange_strong(
            &mtest_runtime_state, &expected, MTEST_RUNTIME_OPENING
        )) {
        if (expected == MTEST_RUNTIME_CHILD_ACTIVE) {
            /* SAFETY: CHILD_ACTIVE means a claimed slot still owns a live
               handle. Runtime close is the cross-ABI retry token: abort either
               consumes that slot, or leaves it pinned for this same ExecRuntime
               owner to retry on a later close. A slot claimed but not yet
               publishing a handle reports EBUSY without a token to abort. */
            uint64_t handle = mtest_first_live_handle();
            if (handle == 0) {
                mtest_set_error(error, MTEST_EXEC_OP_NONE, EBUSY, 1u, 0);
                return -1;
            }
            if (mtest_exec_process_abort(handle, 0, error) != 0) {
                return -1;
            }
            goto retry_runtime_ownership;
        }
        if (expected == MTEST_RUNTIME_RESTORE_REQUIRED) {
            expected = MTEST_RUNTIME_RESTORE_REQUIRED;
            if (atomic_compare_exchange_strong(
                    &mtest_runtime_state, &expected, MTEST_RUNTIME_OPENING
                )) {
                goto restore_handlers;
            }
        }
        int error_number = expected == MTEST_RUNTIME_CHILD_ACTIVE
            ? EBUSY
            : EINVAL;
        mtest_set_error(
            error,
            MTEST_EXEC_OP_NONE,
            error_number,
            expected == MTEST_RUNTIME_CHILD_ACTIVE ? 1u : 0u,
            0
        );
        return -1;
    }
restore_handlers:
    /* Restore the SIGPIPE disposition first (a plain sigaction like SIGCHLD;
       the restore order among the independent signals does not matter). */
    if (mtest_pipe_installed &&
        sigaction(SIGPIPE, &mtest_old_pipe, NULL) != 0) {
        first_errno = errno;
        had_failure = 1;
    } else {
        mtest_pipe_installed = 0;
        mtest_old_pipe_saved = 0;
    }
    if (mtest_chld_installed &&
        sigaction(SIGCHLD, &mtest_old_chld, NULL) != 0) {
        if (!had_failure) {
            first_errno = errno;
        }
        had_failure = 1;
    } else {
        mtest_chld_installed = 0;
        mtest_old_chld_saved = 0;
    }
    if (mtest_term_installed && mtest_checked_sigaction(
            MTEST_EXEC_OP_SIGACTION_RESTORE_TERM,
            SIGTERM,
            &mtest_old_term,
            NULL
        ) != 0) {
        if (!had_failure) {
            first_operation = MTEST_EXEC_OP_SIGACTION_RESTORE_TERM;
            first_errno = errno;
        }
        had_failure = 1;
    } else {
        mtest_term_installed = 0;
        mtest_old_term_saved = 0;
    }
    if (mtest_int_installed && mtest_checked_sigaction(
            MTEST_EXEC_OP_SIGACTION_RESTORE_INT,
            SIGINT,
            &mtest_old_int,
            NULL
        ) != 0) {
        if (!had_failure) {
            first_operation = MTEST_EXEC_OP_SIGACTION_RESTORE_INT;
            first_errno = errno;
        }
        had_failure = 1;
    } else {
        mtest_int_installed = 0;
        mtest_old_int_saved = 0;
    }
    if (had_failure) {
        atomic_store(
            &mtest_runtime_state, MTEST_RUNTIME_RESTORE_REQUIRED
        );
        mtest_set_error(error, first_operation, first_errno, 0, 0);
        return -1;
    }
    atomic_store(&mtest_runtime_state, MTEST_RUNTIME_CLOSED);
    return 0;
}

int32_t mtest_exec_interrupt_requested(void) {
    return mtest_interrupt_flag != 0 ? 1 : 0;
}

int32_t mtest_exec_monotonic_ms(
    int64_t *milliseconds,
    struct mtest_exec_error *error
) {
    struct timespec now;
    mtest_clear_error(error);
    if (milliseconds == NULL) {
        mtest_set_error(error, MTEST_EXEC_OP_CLOCK_MONOTONIC, EINVAL, 0, 0);
        return -1;
    }
#if MTEST_EXEC_TESTING
    mtest_wait_before_monotonic_if_requested();
#endif
    if (mtest_fail_if_requested(MTEST_EXEC_OP_CLOCK_MONOTONIC) ||
        clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        mtest_set_error(error, MTEST_EXEC_OP_CLOCK_MONOTONIC, errno, 0, 0);
        return -1;
    }
    if (now.tv_sec > INT64_MAX / 1000) {
        mtest_set_error(error, MTEST_EXEC_OP_CLOCK_MONOTONIC, EOVERFLOW, 0, 0);
        return -1;
    }
    *milliseconds = (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
    return 0;
}

static int mtest_set_fd_flag(
    int fd,
    int command,
    int flag,
    uint32_t operation
) {
    if (mtest_fail_if_requested(operation)) {
        return -1;
    }
    int current = fcntl(fd, command);
    if (current < 0) {
        return -1;
    }
    int set_command = command == F_GETFD ? F_SETFD : F_SETFL;
    return fcntl(fd, set_command, current | flag);
}

static int mtest_relocate_standard_fd(int *fd) {
    if (*fd > STDERR_FILENO) {
        return 0;
    }
    if (mtest_fail_if_requested(MTEST_EXEC_OP_FD_CLOEXEC)) {
        return -1;
    }
    /* SAFETY: `pipe` returned this live, uniquely owned endpoint. The duplicate
       is constrained above the standard descriptors and owns the same pipe end
       with FD_CLOEXEC already set. Ownership moves to it only after the source
       closes; if that close reports an error, the original slot is already
       consumed, the duplicate is closed, and no cleanup retries either numeric
       descriptor. */
    int relocated = fcntl(
        *fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1
    );
    if (relocated < 0) {
        return -1;
    }
    int original = *fd;
    *fd = -1;
    if (mtest_close_raw(original) != 0) {
        int saved_errno = errno;
        (void)mtest_close_raw(relocated);
        errno = saved_errno;
        return -1;
    }
    *fd = relocated;
    return 0;
}

static int mtest_prepare_pipe(
    int pipe_fds[2],
    uint32_t pipe_operation,
    struct mtest_exec_error *error
) {
    if (mtest_fail_if_requested(pipe_operation) || pipe(pipe_fds) != 0) {
        mtest_set_error(error, pipe_operation, errno, 0, 0);
        return -1;
    }
    for (size_t index = 0; index < 2; ++index) {
        int subject = pipe_fds[index];
        if (mtest_relocate_standard_fd(&pipe_fds[index]) != 0) {
            int saved_errno = errno;
            mtest_close_quietly(&pipe_fds[0]);
            mtest_close_quietly(&pipe_fds[1]);
            mtest_set_error(
                error, MTEST_EXEC_OP_FD_CLOEXEC, saved_errno, 0, subject
            );
            return -1;
        }
    }
    if (mtest_set_fd_flag(
            pipe_fds[0], F_GETFD, FD_CLOEXEC, MTEST_EXEC_OP_FD_CLOEXEC
        ) != 0 ||
        mtest_set_fd_flag(
            pipe_fds[1], F_GETFD, FD_CLOEXEC, MTEST_EXEC_OP_FD_CLOEXEC
        ) != 0) {
        int saved_errno = errno;
        int subject = pipe_fds[0];
        mtest_close_quietly(&pipe_fds[0]);
        mtest_close_quietly(&pipe_fds[1]);
        mtest_set_error(
            error, MTEST_EXEC_OP_FD_CLOEXEC, saved_errno, 0, subject
        );
        return -1;
    }
    if (mtest_set_fd_flag(
            pipe_fds[0], F_GETFL, O_NONBLOCK, MTEST_EXEC_OP_FD_NONBLOCK
        ) != 0) {
        int saved_errno = errno;
        int subject = pipe_fds[0];
        mtest_close_quietly(&pipe_fds[0]);
        mtest_close_quietly(&pipe_fds[1]);
        mtest_set_error(
            error, MTEST_EXEC_OP_FD_NONBLOCK, saved_errno, 0, subject
        );
        return -1;
    }
    return 0;
}

static int mtest_child_close(int fd) {
    if (mtest_fail_if_requested(MTEST_EXEC_OP_CHILD_CLOSE)) {
        return -1;
    }
    return close(fd);
}

static int mtest_execve_checked(
    const char *path,
    char *const argv[],
    char *const environment[]
) {
    if (mtest_fail_if_requested(MTEST_EXEC_OP_CHILD_EXECVE)) {
        return -1;
    }
    return execve(path, argv, environment);
}

static void mtest_child_report(
    int setup_fd,
    uint32_t stage,
    int error_number
) {
    struct {
        uint32_t stage;
        int32_t error_number;
    } record;
    record.stage = stage;
    record.error_number = error_number;
    size_t count = sizeof(record);
    if (mtest_fail_if_requested(MTEST_EXEC_OP_CHILD_SETUP_WRITE)) {
        int64_t requested = mtest_fault_result(MTEST_EXEC_OP_CHILD_SETUP_WRITE);
        if (requested > 0) {
            count = (size_t)requested;
        } else {
            _exit(127);
        }
    }
    ssize_t written;
    do {
        written = write(setup_fd, &record, count);
    } while (written < 0 && errno == EINTR);
    _exit(127);
}

static int mtest_is_search_miss(int error_number) {
    return error_number == ENOENT || error_number == ESTALE ||
        error_number == ENOTDIR || error_number == ENODEV ||
        error_number == ETIMEDOUT;
}

static void mtest_child_exec(
    const struct mtest_exec_plan *plan,
    int stdout_read,
    int stdout_write,
    int stderr_read,
    int stderr_write,
    int setup_read,
    int setup_write
) {
    /* SAFETY: this is the complete post-fork child region. Every pointer and
       argv slot was fully constructed in the parent and survives in the child's
       copy-on-write image. Only sigaction, setpgid, chdir, dup2, close, execve,
       poll, write, and _exit are called; none retains a pointer after failed
       exec. sigaction, setpgid, dup2, close, execve, poll, and write are all on
       POSIX's async-signal-safe list. */

    /* Restore the SIGPIPE disposition the runtime saved before installing its
       process-wide SIG_IGN carve-out. That carve-out is PARENT-local: it keeps
       mtest's own writes to a dead --json pipe from dying at 141. But an ignored
       disposition survives execve, so without this the exec'd test binary would
       inherit SIG_IGN and a direct SIGPIPE crash would be silently swallowed
       into a false PASS. mtest_old_pipe is a file-scope static populated before
       fork and readable in the copy-on-write child. Restoring a known-valid
       disposition to SIGPIPE cannot fail in practice (EINVAL/EFAULT are
       impossible here); the check is defense-in-depth, so it takes no
       fault-injection hook, and reuses the same report-and-exit path as the
       other pre-exec setup steps. */
    if (sigaction(SIGPIPE, &mtest_old_pipe, NULL) != 0) {
        mtest_child_report(
            setup_write, MTEST_EXEC_STAGE_SIGPIPE_RESTORE, errno
        );
    }
    if (mtest_fail_if_requested(MTEST_EXEC_OP_CHILD_SETPGID) ||
        setpgid(0, 0) != 0) {
        mtest_child_report(setup_write, MTEST_EXEC_STAGE_SETPGID, errno);
    }
    if (plan->has_cwd &&
        (mtest_fail_if_requested(MTEST_EXEC_OP_CHILD_CHDIR) ||
         chdir(plan->cwd) != 0)) {
        mtest_child_report(setup_write, MTEST_EXEC_STAGE_CHDIR, errno);
    }
    if (mtest_fail_if_requested(MTEST_EXEC_OP_CHILD_DUP2_STDOUT) ||
        dup2(stdout_write, STDOUT_FILENO) < 0) {
        mtest_child_report(setup_write, MTEST_EXEC_STAGE_DUP2_STDOUT, errno);
    }
    if (mtest_fail_if_requested(MTEST_EXEC_OP_CHILD_DUP2_STDERR) ||
        dup2(stderr_write, STDERR_FILENO) < 0) {
        mtest_child_report(setup_write, MTEST_EXEC_STAGE_DUP2_STDERR, errno);
    }
    int child_fds[] = {
        stdout_read,
        stdout_write,
        stderr_read,
        stderr_write,
        setup_read
    };
    for (size_t index = 0; index < sizeof(child_fds) / sizeof(child_fds[0]); ++index) {
        if (child_fds[index] != STDOUT_FILENO &&
            child_fds[index] != STDERR_FILENO &&
            mtest_child_close(child_fds[index]) != 0) {
            mtest_child_report(setup_write, MTEST_EXEC_STAGE_CLOSE, errno);
        }
    }

    int last_errno = ENOENT;
    int saw_eacces = 0;
    for (size_t index = 0; index < plan->candidate_count; ++index) {
        uint32_t retries = 0;
        for (;;) {
            (void)mtest_execve_checked(
                plan->candidates[index], plan->argv, plan->environment
            );
            last_errno = errno;
            if (last_errno != ETXTBSY || retries >= MTEST_ETXTBSY_RETRIES) {
                break;
            }
            for (;;) {
                if (mtest_fail_if_requested(MTEST_EXEC_OP_CHILD_POLL)) {
                    mtest_child_report(
                        setup_write, MTEST_EXEC_STAGE_EXECVE, errno
                    );
                }
                /* SAFETY: POSIX requires poll to be async-signal-safe. With
                   nfds zero, the null descriptor pointer is never accessed;
                   the integer timeout bounds the ETXTBSY backoff and poll
                   retains no pointer or state after returning. */
                if (poll(NULL, 0, MTEST_ETXTBSY_DELAY_MS) >= 0) {
                    break;
                }
                if (errno != EINTR) {
                    mtest_child_report(
                        setup_write, MTEST_EXEC_STAGE_EXECVE, errno
                    );
                }
            }
            retries += 1;
        }
        if (last_errno == ENOEXEC) {
            (void)mtest_execve_checked(
                "/bin/sh", plan->shell_argv[index], plan->environment
            );
            mtest_child_report(
                setup_write, MTEST_EXEC_STAGE_EXECVE, errno
            );
        }
        if (last_errno == EACCES) {
            saw_eacces = 1;
            continue;
        }
        if (mtest_is_search_miss(last_errno)) {
            continue;
        }
        mtest_child_report(
            setup_write, MTEST_EXEC_STAGE_EXECVE, last_errno
        );
    }
    mtest_child_report(
        setup_write,
        MTEST_EXEC_STAGE_EXECVE,
        saw_eacces ? EACCES : last_errno
    );
}

static struct mtest_exec_process *mtest_process_from_handle(uint64_t handle) {
    /* SAFETY: ABI handles are generation tokens, never addresses. A zero handle
       is never live. Otherwise scan the slot table and consult each slot's
       lifecycle latch before touching its record, returning the record only
       when the slot is ACTIVE and its published token matches exactly. A FREE
       slot's fields are never read, so a stale or arbitrary integer is never
       dereferenced. */
    if (handle == 0) {
        errno = EINVAL;
        return NULL;
    }
    for (size_t index = 0; index < MTEST_EXEC_SLOT_CAPACITY; ++index) {
        if (atomic_load(&mtest_slot_lifecycle[index]) == MTEST_SLOT_ACTIVE &&
            mtest_process[index].handle == handle) {
            return &mtest_process[index];
        }
    }
    errno = EINVAL;
    return NULL;
}

static void mtest_cleanup_pipes(int stdout_pipe[2], int stderr_pipe[2], int setup_pipe[2]) {
    mtest_close_quietly(&stdout_pipe[0]);
    mtest_close_quietly(&stdout_pipe[1]);
    mtest_close_quietly(&stderr_pipe[0]);
    mtest_close_quietly(&stderr_pipe[1]);
    mtest_close_quietly(&setup_pipe[0]);
    mtest_close_quietly(&setup_pipe[1]);
}

static int mtest_waitpid_exact(pid_t leader, int *raw_status) {
    pid_t reaped;
    if (mtest_fail_if_requested(MTEST_EXEC_OP_WAITPID)) {
        reaped = -1;
    } else {
        reaped = waitpid(leader, raw_status, 0);
    }
    while (reaped < 0 && errno == EINTR) {
        reaped = waitpid(leader, raw_status, 0);
    }
    if (reaped == leader) {
        return 0;
    }
    if (reaped >= 0) {
        errno = EIO;
    }
    return -1;
}

int32_t mtest_exec_process_open(
    const struct mtest_exec_process_spec *spec,
    struct mtest_exec_process_ref *process_ref,
    struct mtest_exec_error *error
) {
    int stdout_pipe[2] = {-1, -1};
    int stderr_pipe[2] = {-1, -1};
    int setup_pipe[2] = {-1, -1};

    mtest_clear_error(error);
    if (process_ref != NULL) {
        memset(process_ref, 0, sizeof(*process_ref));
    }
    if (process_ref == NULL) {
        mtest_set_error(error, MTEST_EXEC_OP_NONE, EINVAL, 0, 0);
        return -1;
    }
    int expected = MTEST_RUNTIME_OPEN;
    if (!atomic_compare_exchange_strong(
            &mtest_runtime_state, &expected, MTEST_RUNTIME_CHILD_ACTIVE
        )) {
        int error_number = expected == MTEST_RUNTIME_CHILD_ACTIVE
            ? EBUSY
            : EINVAL;
        mtest_set_error(error, MTEST_EXEC_OP_NONE, error_number, 0, 0);
        return -1;
    }
    struct mtest_exec_plan *plan = mtest_build_plan(spec, error);
    if (plan == NULL) {
        atomic_store(&mtest_runtime_state, MTEST_RUNTIME_OPEN);
        return -1;
    }
    struct mtest_exec_process *process = mtest_claim_slot();
    if (process == NULL) {
        /* The runtime gate above admits one child at a time, so at capacity one
           the sole slot is always FREE here; a larger table can nonetheless
           exhaust its slots, which is the same busy condition. */
        mtest_free_plan(plan);
        atomic_store(&mtest_runtime_state, MTEST_RUNTIME_OPEN);
        mtest_set_error(error, MTEST_EXEC_OP_NONE, EBUSY, 0, 0);
        return -1;
    }
    memset(process, 0, sizeof(*process));
    process->stdout_fd = -1;
    process->stderr_fd = -1;
    process->setup_fd = -1;

    if (mtest_prepare_pipe(stdout_pipe, MTEST_EXEC_OP_PIPE_STDOUT, error) != 0 ||
        mtest_prepare_pipe(stderr_pipe, MTEST_EXEC_OP_PIPE_STDERR, error) != 0 ||
        mtest_prepare_pipe(setup_pipe, MTEST_EXEC_OP_PIPE_SETUP, error) != 0) {
        mtest_cleanup_pipes(stdout_pipe, stderr_pipe, setup_pipe);
        mtest_free_plan(plan);
        mtest_release_slot(process);
        atomic_store(&mtest_runtime_state, MTEST_RUNTIME_OPEN);
        return -1;
    }
    /* SAFETY: all plan strings, pointer arrays, pipe records, and retry state
       are complete before fork. Parent and child then own separate COW views;
       only the parent frees its plan after the child has entered child_exec. */
    pid_t leader;
    if (mtest_fail_if_requested(MTEST_EXEC_OP_FORK)) {
        leader = -1;
    } else {
        leader = fork();
    }
    if (leader < 0) {
        int saved_errno = errno;
        mtest_cleanup_pipes(stdout_pipe, stderr_pipe, setup_pipe);
        mtest_free_plan(plan);
        mtest_release_slot(process);
        atomic_store(&mtest_runtime_state, MTEST_RUNTIME_OPEN);
        mtest_set_error(error, MTEST_EXEC_OP_FORK, saved_errno, 0, 0);
        return -1;
    }
    if (leader == 0) {
        mtest_child_exec(
            plan,
            stdout_pipe[0],
            stdout_pipe[1],
            stderr_pipe[0],
            stderr_pipe[1],
            setup_pipe[0],
            setup_pipe[1]
        );
        _exit(127);
    }

    process->leader = leader;
    process->process_group = leader;
    if (mtest_fail_if_requested(MTEST_EXEC_OP_PARENT_SETPGID) ||
        setpgid(leader, leader) != 0) {
        int saved_errno = errno;
        if (saved_errno != EACCES && saved_errno != ESRCH) {
            (void)kill(-leader, SIGKILL);
            (void)kill(leader, SIGKILL);
            int wait_result = mtest_waitpid_exact(leader, NULL);
            int wait_errno = errno;
            mtest_cleanup_pipes(stdout_pipe, stderr_pipe, setup_pipe);
            mtest_free_plan(plan);
            mtest_set_error(
                error, MTEST_EXEC_OP_PARENT_SETPGID, saved_errno, 0, leader
            );
            if (wait_result != 0 && wait_errno != ECHILD) {
                mtest_set_cleanup_error(
                    error, MTEST_EXEC_OP_WAITPID, wait_errno
                );
                /* Fail closed because exact-child reaping is unproven and no
                   handle was published for a later abort. Returning the
                   runtime to OPEN here would hide an owned zombie and permit
                   overlapping child ownership. Real waitpid for our exact,
                   SIGKILLed child can only succeed, report ECHILD, or retry
                   EINTR; the test seam reaches this terminal invariant. */
                return -1;
            }
            mtest_release_slot(process);
            atomic_store(&mtest_runtime_state, MTEST_RUNTIME_OPEN);
            return -1;
        }
    }
    mtest_close_quietly(&stdout_pipe[1]);
    mtest_close_quietly(&stderr_pipe[1]);
    mtest_close_quietly(&setup_pipe[1]);
    process->stdout_fd = stdout_pipe[0];
    process->stderr_fd = stderr_pipe[0];
    process->setup_fd = setup_pipe[0];
    stdout_pipe[0] = -1;
    stderr_pipe[0] = -1;
    setup_pipe[0] = -1;
    process->handle = mtest_next_handle;
    mtest_next_handle += 1;
    if (mtest_next_handle == 0) {
        mtest_next_handle = 1;
    }
    process_ref->handle = process->handle;
    process_ref->leader_pid = (int32_t)leader;
    process_ref->process_group = (int32_t)leader;
    mtest_free_plan(plan);
    return 0;
}

int32_t mtest_exec_process_poll(
    uint64_t handle,
    int32_t timeout_ms,
    struct mtest_exec_poll_result *result,
    struct mtest_exec_error *error
) {
    mtest_clear_error(error);
    if (result == NULL || timeout_ms < -1) {
        mtest_set_error(error, MTEST_EXEC_OP_POLL, EINVAL, 0, timeout_ms);
        return -1;
    }
    memset(result, 0, sizeof(*result));
    struct mtest_exec_process *process = mtest_process_from_handle(handle);
    if (process == NULL) {
        mtest_set_error(error, MTEST_EXEC_OP_POLL, errno, 0, 0);
        return -1;
    }
    struct pollfd fds[3];
    uint32_t readiness[3];
    nfds_t count = 0;
    if (process->stdout_fd >= 0) {
        fds[count].fd = process->stdout_fd;
        fds[count].events = POLLIN;
        fds[count].revents = 0;
        readiness[count++] = MTEST_EXEC_READY_STDOUT;
    }
    if (process->stderr_fd >= 0) {
        fds[count].fd = process->stderr_fd;
        fds[count].events = POLLIN;
        fds[count].revents = 0;
        readiness[count++] = MTEST_EXEC_READY_STDERR;
    }
    if (process->setup_fd >= 0) {
        fds[count].fd = process->setup_fd;
        fds[count].events = POLLIN;
        fds[count].revents = 0;
        readiness[count++] = MTEST_EXEC_READY_SETUP;
    }
    int poll_result;
    do {
        if (mtest_fail_if_requested(MTEST_EXEC_OP_POLL)) {
            poll_result = -1;
        } else {
            poll_result = poll(fds, count, timeout_ms);
        }
    } while (poll_result < 0 && errno == EINTR && !mtest_interrupt_flag);
    if (poll_result < 0) {
        if (errno == EINTR && mtest_interrupt_flag) {
            return 0;
        }
        mtest_set_error(error, MTEST_EXEC_OP_POLL, errno, 0, 0);
        return -1;
    }
    for (nfds_t index = 0; index < count; ++index) {
        if ((fds[index].revents & POLLNVAL) != 0) {
            mtest_set_error(
                error, MTEST_EXEC_OP_POLL, EBADF, fds[index].revents, fds[index].fd
            );
            return -1;
        }
        if ((fds[index].revents & (POLLIN | POLLHUP | POLLERR)) != 0) {
            result->readiness |= readiness[index];
        }
    }
    return 0;
}

static int *mtest_channel_fd(
    struct mtest_exec_process *process,
    uint32_t channel
) {
    if (channel == MTEST_EXEC_CHANNEL_STDOUT) {
        return &process->stdout_fd;
    }
    if (channel == MTEST_EXEC_CHANNEL_STDERR) {
        return &process->stderr_fd;
    }
    if (channel == MTEST_EXEC_CHANNEL_SETUP) {
        return &process->setup_fd;
    }
    errno = EINVAL;
    return NULL;
}

static uint32_t mtest_read_operation(uint32_t channel) {
    if (channel == MTEST_EXEC_CHANNEL_STDOUT) {
        return MTEST_EXEC_OP_READ_STDOUT;
    }
    if (channel == MTEST_EXEC_CHANNEL_STDERR) {
        return MTEST_EXEC_OP_READ_STDERR;
    }
    return MTEST_EXEC_OP_READ_SETUP;
}

int32_t mtest_exec_process_read(
    uint64_t handle,
    uint32_t channel,
    uint8_t *buffer,
    uint64_t capacity,
    struct mtest_exec_read_result *result,
    struct mtest_exec_error *error
) {
    mtest_clear_error(error);
    if (result == NULL || buffer == NULL || capacity == 0 ||
        capacity > (uint64_t)SSIZE_MAX || channel == MTEST_EXEC_CHANNEL_SETUP) {
        mtest_set_error(error, mtest_read_operation(channel), EINVAL, capacity, channel);
        return -1;
    }
    memset(result, 0, sizeof(*result));
    struct mtest_exec_process *process = mtest_process_from_handle(handle);
    if (process == NULL) {
        mtest_set_error(error, mtest_read_operation(channel), errno, 0, channel);
        return -1;
    }
    int *fd = mtest_channel_fd(process, channel);
    if (fd == NULL) {
        mtest_set_error(error, mtest_read_operation(channel), errno, 0, channel);
        return -1;
    }
    if (*fd < 0) {
        result->state = MTEST_EXEC_READ_EOF;
        return 0;
    }
    uint32_t operation = mtest_read_operation(channel);
    ssize_t count;
    do {
        if (mtest_fail_if_requested(operation)) {
            count = -1;
        } else {
            count = read(*fd, buffer, (size_t)capacity);
        }
    } while (count < 0 && errno == EINTR && !mtest_interrupt_flag);
    if (count > 0) {
        result->state = MTEST_EXEC_READ_BYTES;
        result->count = (uint64_t)count;
        return 0;
    }
    if (count == 0) {
        int closing = *fd;
        if (mtest_close_owned(fd) != 0) {
            mtest_set_error(
                error, MTEST_EXEC_OP_CLOSE_CHANNEL, errno, 0, closing
            );
            return -1;
        }
        result->state = MTEST_EXEC_READ_EOF;
        return 0;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK ||
        (errno == EINTR && mtest_interrupt_flag)) {
        result->state = MTEST_EXEC_READ_WOULD_BLOCK;
        return 0;
    }
    result->error_number = errno;
    mtest_set_error(error, operation, errno, 0, *fd);
    return -1;
}

static int mtest_validate_setup_record(struct mtest_exec_setup_state *state) {
    uint32_t stage;
    int32_t error_number;
    memcpy(&stage, state->raw, sizeof(stage));
    memcpy(&error_number, state->raw + sizeof(stage), sizeof(error_number));
    if (stage < MTEST_EXEC_STAGE_SETPGID ||
        stage > MTEST_EXEC_STAGE_SIGPIPE_RESTORE || error_number <= 0) {
        state->outcome = MTEST_EXEC_SETUP_CORRUPT;
        return 0;
    }
    state->stage = stage;
    state->error_number = error_number;
    state->outcome = MTEST_EXEC_SETUP_SPAWN_FAILED;
    return 0;
}

int32_t mtest_exec_process_setup_drain(
    uint64_t handle,
    struct mtest_exec_setup_state *state,
    struct mtest_exec_error *error
) {
    mtest_clear_error(error);
    if (state == NULL || state->length > sizeof(state->raw) ||
        state->outcome > MTEST_EXEC_SETUP_CORRUPT) {
        mtest_set_error(error, MTEST_EXEC_OP_READ_SETUP, EINVAL, 0, 0);
        return -1;
    }
    struct mtest_exec_process *process = mtest_process_from_handle(handle);
    if (process == NULL) {
        mtest_set_error(error, MTEST_EXEC_OP_READ_SETUP, errno, 0, 0);
        return -1;
    }
    if (state->outcome != MTEST_EXEC_SETUP_WAITING) {
        return 0;
    }
    if (process->setup_fd < 0) {
        state->outcome = state->length == 0
            ? MTEST_EXEC_SETUP_EXEC_SUCCEEDED
            : MTEST_EXEC_SETUP_CORRUPT;
        return 0;
    }
    for (;;) {
        uint8_t extra;
        uint8_t *destination = state->length < sizeof(state->raw)
            ? state->raw + state->length
            : &extra;
        size_t capacity = state->length < sizeof(state->raw)
            ? sizeof(state->raw) - state->length
            : 1;
        ssize_t count;
        do {
            if (mtest_fail_if_requested(MTEST_EXEC_OP_READ_SETUP)) {
                count = -1;
            } else {
                count = read(process->setup_fd, destination, capacity);
            }
        } while (count < 0 && errno == EINTR && !mtest_interrupt_flag);
        if (count > 0) {
            if (state->length == sizeof(state->raw)) {
                state->outcome = MTEST_EXEC_SETUP_CORRUPT;
                return 0;
            }
            state->length += (uint32_t)count;
            continue;
        }
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK ||
                         (errno == EINTR && mtest_interrupt_flag))) {
            return 0;
        }
        if (count < 0) {
            mtest_set_error(
                error,
                MTEST_EXEC_OP_READ_SETUP,
                errno,
                state->length,
                process->setup_fd
            );
            return -1;
        }
        int closed_fd = process->setup_fd;
        if (mtest_close_owned(&process->setup_fd) != 0) {
            mtest_set_error(
                error, MTEST_EXEC_OP_CLOSE_CHANNEL, errno, 0, closed_fd
            );
            return -1;
        }
        if (state->length == 0) {
            state->outcome = MTEST_EXEC_SETUP_EXEC_SUCCEEDED;
            return 0;
        }
        if (state->length != sizeof(state->raw)) {
            state->outcome = MTEST_EXEC_SETUP_CORRUPT;
            return 0;
        }
        return mtest_validate_setup_record(state);
    }
}

int32_t mtest_exec_process_channel_close(
    uint64_t handle,
    uint32_t channel,
    struct mtest_exec_error *error
) {
    mtest_clear_error(error);
    struct mtest_exec_process *process = mtest_process_from_handle(handle);
    if (process == NULL) {
        mtest_set_error(error, MTEST_EXEC_OP_CLOSE_CHANNEL, errno, 0, channel);
        return -1;
    }
    int *fd = mtest_channel_fd(process, channel);
    if (fd == NULL) {
        mtest_set_error(error, MTEST_EXEC_OP_CLOSE_CHANNEL, errno, 0, channel);
        return -1;
    }
    if (*fd < 0) {
        return 0;
    }
    int closing = *fd;
    int close_result = mtest_close_owned(fd);
    if (close_result != 0 ||
        mtest_fail_if_requested(MTEST_EXEC_OP_CLOSE_CHANNEL)) {
        mtest_set_error(error, MTEST_EXEC_OP_CLOSE_CHANNEL, errno, 0, closing);
        return -1;
    }
    return 0;
}

static uint32_t mtest_group_operation(uint32_t action) {
    if (action == MTEST_EXEC_GROUP_PROBE) {
        return MTEST_EXEC_OP_GROUP_PROBE;
    }
    if (action == MTEST_EXEC_GROUP_TERM) {
        return MTEST_EXEC_OP_GROUP_TERM;
    }
    return MTEST_EXEC_OP_GROUP_KILL;
}

static int mtest_signal_process_group(
    pid_t process_group,
    int signal_number,
    uint32_t operation
) {
#if MTEST_EXEC_TESTING
    /* This seam emulates a real kill(2) EPERM sequence and is deliberately
       separate from named fault injection. The latter must remain an immediate
       fail-closed error and never enter Darwin's transient retry path. */
    if (operation == mtest_group_signal_eperm_operation) {
        mtest_group_signal_eperm_seen += 1;
        if (mtest_group_signal_eperm_seen <=
            mtest_group_signal_eperm_forced_failures) {
            errno = EPERM;
            return -1;
        }
    }
#else
    (void)operation;
#endif
    return kill(-process_group, signal_number);
}

#if defined(__APPLE__)
static int mtest_darwin_group_is_zombie_only(pid_t process_group) {
    int query[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, process_group};
    size_t length = 0;
    if (sysctl(query, 4, NULL, &length, NULL, 0) != 0 || length == 0) {
        return 0;
    }
    struct kinfo_proc *members = malloc(length);
    if (members == NULL) {
        return 0;
    }
    int complete = sysctl(query, 4, members, &length, NULL, 0) == 0 &&
        length > 0 && length % sizeof(*members) == 0;
    int zombie_only = complete;
    if (complete) {
        size_t count = length / sizeof(*members);
        for (size_t index = 0; index < count; ++index) {
            if (members[index].kp_proc.p_stat != SZOMB) {
                zombie_only = 0;
                break;
            }
        }
    }
    free(members);
    return zombie_only;
}
#endif

#if defined(__APPLE__) || MTEST_EXEC_TESTING
static int mtest_group_eperm_can_retry(uint32_t operation) {
#if defined(__APPLE__)
    (void)operation;
    return 1;
#else
    return operation == mtest_group_signal_eperm_operation;
#endif
}

static int mtest_group_is_proven_zombie_only(pid_t process_group) {
#if defined(__APPLE__)
    return mtest_darwin_group_is_zombie_only(process_group);
#else
    (void)process_group;
    return 0;
#endif
}
#endif

static int mtest_process_group_checked(
    struct mtest_exec_process *process,
    uint32_t action,
    struct mtest_exec_group_result *result,
    struct mtest_exec_error *error
) {
    int signal_number = action == MTEST_EXEC_GROUP_PROBE
        ? 0
        : (action == MTEST_EXEC_GROUP_TERM ? SIGTERM : SIGKILL);
    uint32_t operation = mtest_group_operation(action);
#if defined(__APPLE__) || MTEST_EXEC_TESTING
    uint32_t eperm_retries = 0;
#endif
    /* In testing builds, named fault occurrence accounting advances once per
       loop visit, including visits caused by the transient-EPERM seam. An
       occurrence-N named group fault may therefore fire during such a retry;
       production builds have no fault table or transient test seam. */
    for (;;) {
        int fault_injected = mtest_fail_if_requested(operation);
        int group_status = fault_injected
            ? -1
            : mtest_signal_process_group(
                process->process_group, signal_number, operation
            );
        if (group_status == 0) {
            break;
        }
        int group_errno = errno;
        if (group_errno == ESRCH) {
            result->state = MTEST_EXEC_GROUP_GONE;
            process->group_swept = 1;
            return 0;
        }
#if defined(__APPLE__) || MTEST_EXEC_TESTING
        /* Darwin's process-group signal path excludes zombies from its member
           iteration, then returns EPERM when only terminal members remain.
           Query the complete group snapshot on every real EPERM before treating
           TERM or KILL as a completed sweep. This proof does not require prior
           waitid observation: the unreaped group-leader zombie pins the PGID,
           and an all-zombie group has no member capable of executing or forking.

           XNU can also return EPERM briefly while a post-TERM member is exiting
           but has not reached SZOMB. Retry that real Darwin result for one small,
           explicit bound. A probe action, an injected EPERM, an incomplete or
           mixed snapshot after the bound, or any other errno remains an error,
           so cleanup still fails closed. The MTEST_EXEC_TESTING branch exercises
           this Darwin-only algorithm on Linux without changing production Linux
           behavior. */
        if (!fault_injected && group_errno == EPERM &&
            action != MTEST_EXEC_GROUP_PROBE &&
            mtest_group_eperm_can_retry(operation)) {
            if (mtest_group_is_proven_zombie_only(process->process_group)) {
                process->group_swept = 1;
                result->state = MTEST_EXEC_GROUP_PRESENT;
                return 0;
            }
            if (eperm_retries < MTEST_DARWIN_GROUP_EPERM_RETRIES) {
                const struct timespec delay = {
                    0, MTEST_DARWIN_GROUP_EPERM_RETRY_NS
                };
                eperm_retries += 1;
                (void)nanosleep(&delay, NULL);
                continue;
            }
        }
#endif
        mtest_set_error(
            error, operation, group_errno, 0,
            -((int64_t)process->process_group)
        );
        return -1;
    }
    if (action == MTEST_EXEC_GROUP_KILL) {
        /* A successful pre-reap SIGKILL reaches every member still in the
           owned process group. The unreaped leader, live or waitable, keeps the
           numeric group identity pinned until waitpid; retained pipe writers
           are bounded and classified separately by the Mojo supervisor. */
        process->group_swept = 1;
    }
    result->state = MTEST_EXEC_GROUP_PRESENT;
    return 0;
}

int32_t mtest_exec_process_group(
    uint64_t handle,
    uint32_t action,
    struct mtest_exec_group_result *result,
    struct mtest_exec_error *error
) {
    mtest_clear_error(error);
    if (result == NULL || action > MTEST_EXEC_GROUP_KILL) {
        mtest_set_error(error, MTEST_EXEC_OP_GROUP_PROBE, EINVAL, 0, action);
        return -1;
    }
    memset(result, 0, sizeof(*result));
    struct mtest_exec_process *process = mtest_process_from_handle(handle);
    if (process == NULL) {
        mtest_set_error(error, mtest_group_operation(action), errno, 0, 0);
        return -1;
    }
    uint32_t operation = mtest_group_operation(action);
    if (process->reaped) {
        mtest_set_error(error, operation, EINVAL, 0, 0);
        return -1;
    }
    return mtest_process_group_checked(process, action, result, error);
}

int32_t mtest_exec_process_observe(
    uint64_t handle,
    struct mtest_exec_observe_result *result,
    struct mtest_exec_error *error
) {
    mtest_clear_error(error);
    if (result == NULL) {
        mtest_set_error(error, MTEST_EXEC_OP_WAITID, EINVAL, 0, 0);
        return -1;
    }
    memset(result, 0, sizeof(*result));
    struct mtest_exec_process *process = mtest_process_from_handle(handle);
    if (process == NULL) {
        mtest_set_error(error, MTEST_EXEC_OP_WAITID, errno, 0, 0);
        return -1;
    }
    if (process->reaped || process->observed) {
        result->state = MTEST_EXEC_LEADER_WAITABLE;
        return 0;
    }
    siginfo_t information;
    memset(&information, 0, sizeof(information));
    int status;
    do {
        if (mtest_fail_if_requested(MTEST_EXEC_OP_WAITID)) {
            status = -1;
        } else {
            status = waitid(
                P_PID,
                (id_t)process->leader,
                &information,
                WEXITED | WNOHANG | WNOWAIT
            );
        }
    } while (status != 0 && errno == EINTR);
    if (status != 0) {
        mtest_set_error(
            error, MTEST_EXEC_OP_WAITID, errno, 0, process->leader
        );
        return -1;
    }
    if (information.si_pid == process->leader) {
        process->observed = 1;
        result->state = MTEST_EXEC_LEADER_WAITABLE;
    } else {
        result->state = MTEST_EXEC_LEADER_NOT_WAITABLE;
    }
    return 0;
}

int32_t mtest_exec_process_reap(
    uint64_t handle,
    struct mtest_exec_reap_result *result,
    struct mtest_exec_error *error
) {
    mtest_clear_error(error);
    if (result == NULL) {
        mtest_set_error(error, MTEST_EXEC_OP_WAITPID, EINVAL, 0, 0);
        return -1;
    }
    memset(result, 0, sizeof(*result));
    struct mtest_exec_process *process = mtest_process_from_handle(handle);
    if (process == NULL || !process->observed || process->reaped) {
        mtest_set_error(error, MTEST_EXEC_OP_WAITPID, EINVAL, 0, 0);
        return -1;
    }
    int raw_status = 0;
    pid_t reaped;
    do {
        if (mtest_fail_if_requested(MTEST_EXEC_OP_WAITPID)) {
            reaped = -1;
        } else {
            reaped = waitpid(process->leader, &raw_status, 0);
        }
    } while (reaped < 0 && errno == EINTR);
    if (reaped != process->leader) {
        mtest_set_error(
            error, MTEST_EXEC_OP_WAITPID, errno, 0, process->leader
        );
        return -1;
    }
    process->reaped = 1;
    result->raw_status = raw_status;
    if (WIFEXITED(raw_status)) {
        result->kind = MTEST_EXEC_REAP_EXITED;
        result->value = WEXITSTATUS(raw_status);
    } else if (WIFSIGNALED(raw_status)) {
        result->kind = MTEST_EXEC_REAP_SIGNALED;
        result->value = WTERMSIG(raw_status);
    } else {
        result->kind = MTEST_EXEC_REAP_OTHER;
    }
    return 0;
}

static int mtest_process_all_channels_closed(
    const struct mtest_exec_process *process
) {
    return process->stdout_fd < 0 && process->stderr_fd < 0 &&
        process->setup_fd < 0;
}

static void mtest_free_process(struct mtest_exec_process *process) {
    /* SAFETY: callers reach this only after the leader is reaped, its owned
       process group is gone, and all three read channels are closed. Releasing
       the slot clears the record and invalidates its token before the runtime
       returns to OPEN for reuse. */
    mtest_release_slot(process);
    atomic_store(&mtest_runtime_state, MTEST_RUNTIME_OPEN);
}

int32_t mtest_exec_process_close(
    uint64_t handle,
    struct mtest_exec_error *error
) {
    mtest_clear_error(error);
    struct mtest_exec_process *process = mtest_process_from_handle(handle);
    if (process == NULL) {
        mtest_set_error(error, MTEST_EXEC_OP_NONE, errno, 0, 0);
        return -1;
    }
    if (!process->reaped || !process->group_swept ||
        !mtest_process_all_channels_closed(process)) {
        mtest_set_error(error, MTEST_EXEC_OP_NONE, EBUSY, 0, process->leader);
        return -1;
    }
    mtest_free_process(process);
    return 0;
}

int32_t mtest_exec_process_abort(
    uint64_t handle,
    uint32_t grace_ms,
    struct mtest_exec_error *error
) {
    struct mtest_exec_error local_error;
    if (error == NULL) {
        error = &local_error;
    }
    mtest_clear_error(error);
    struct mtest_exec_process *process = mtest_process_from_handle(handle);
    if (process == NULL) {
        mtest_set_error(error, MTEST_EXEC_OP_NONE, errno, 0, 0);
        return -1;
    }
    mtest_close_quietly(&process->stdout_fd);
    mtest_close_quietly(&process->stderr_fd);
    mtest_close_quietly(&process->setup_fd);

    if (process->reaped) {
        if (!process->group_swept) {
            mtest_set_error(
                error, MTEST_EXEC_OP_NONE, EBUSY, 0, process->leader
            );
            return -1;
        }
        mtest_free_process(process);
        return 0;
    }

    struct mtest_exec_group_result group_result;
    struct mtest_exec_error group_error;
    memset(&group_result, 0, sizeof(group_result));
    mtest_clear_error(&group_error);
    if (mtest_process_group_checked(
            process, MTEST_EXEC_GROUP_TERM, &group_result, &group_error
        ) != 0) {
        mtest_set_cleanup_error(
            error, group_error.operation, group_error.error_number
        );
    }
    int64_t start_ms = 0;
    int64_t now_ms = 0;
    struct timespec delay = {0, MTEST_ABORT_SLICE_NS};
    struct mtest_exec_error clock_error;
    mtest_clear_error(&clock_error);
    if (mtest_exec_monotonic_ms(&start_ms, &clock_error) != 0) {
        start_ms = 0;
        mtest_set_error(
            error,
            clock_error.operation,
            clock_error.error_number,
            clock_error.detail,
            clock_error.subject
        );
    }
    while (!process->observed && start_ms != 0) {
        struct mtest_exec_observe_result observation;
        struct mtest_exec_error observe_error;
        if (mtest_exec_process_observe(
                handle, &observation, &observe_error
            ) != 0) {
            mtest_set_cleanup_error(
                error, observe_error.operation, observe_error.error_number
            );
            break;
        }
        if (observation.state == MTEST_EXEC_LEADER_WAITABLE) {
            break;
        }
        if (mtest_exec_monotonic_ms(&now_ms, &observe_error) != 0) {
            mtest_set_cleanup_error(
                error, observe_error.operation, observe_error.error_number
            );
            break;
        }
        if (now_ms - start_ms >= (int64_t)grace_ms) {
            break;
        }
        (void)nanosleep(&delay, NULL);
    }
    if (!process->group_swept) {
        memset(&group_result, 0, sizeof(group_result));
        mtest_clear_error(&group_error);
        if (mtest_process_group_checked(
                process, MTEST_EXEC_GROUP_KILL, &group_result, &group_error
            ) != 0) {
            mtest_set_cleanup_error(
                error, group_error.operation, group_error.error_number
            );
            /* Preserve the unreaped leader, whether live or waitable, as a
               PID/PGID identity pin. A later abort can retry the group sweep
               safely; reaping here would make the numeric group identity
               reusable while descendants may live. */
            return -1;
        }
    }
    if (!process->observed) {
        if (kill(process->leader, SIGKILL) != 0 && errno != ESRCH) {
            mtest_set_cleanup_error(error, MTEST_EXEC_OP_GROUP_KILL, errno);
            /* Without a proven group member or direct-leader termination,
               blocking wait below could hang indefinitely. */
            return -1;
        }
        siginfo_t information;
        memset(&information, 0, sizeof(information));
        int status;
        do {
            status = waitid(
                P_PID,
                (id_t)process->leader,
                &information,
                WEXITED | WNOWAIT
            );
        } while (status != 0 && errno == EINTR);
        if (status == 0) {
            process->observed = 1;
        } else {
            mtest_set_cleanup_error(error, MTEST_EXEC_OP_WAITID, errno);
        }
    }
    if (process->observed) {
        int raw_status;
        pid_t reaped;
        do {
            reaped = waitpid(process->leader, &raw_status, 0);
        } while (reaped < 0 && errno == EINTR);
        if (reaped == process->leader) {
            process->reaped = 1;
        } else {
            mtest_set_cleanup_error(error, MTEST_EXEC_OP_WAITPID, errno);
        }
    }
    if (!process->reaped || !process->group_swept) {
        if (error != NULL && error->operation == MTEST_EXEC_OP_NONE) {
            mtest_set_error(error, MTEST_EXEC_OP_NONE, EBUSY, 0, process->leader);
        }
        return -1;
    }
    int had_error = error->operation != MTEST_EXEC_OP_NONE ||
        error->cleanup_operation != MTEST_EXEC_OP_NONE;
    /* Reap + group sweep + the eager channel closes above prove that native
       ownership is complete even when an earlier diagnostic must be returned. */
    mtest_free_process(process);
    if (had_error) {
        return -1;
    }
    return 0;
}

#if MTEST_EXEC_TESTING
static volatile uint8_t mtest_sanitizer_sink;

__attribute__((noinline))
void mtest_exec_test_asan_oob(void) {
    volatile uint8_t *bytes = (volatile uint8_t *)malloc(8);
    if (bytes == NULL) {
        abort();
    }
    bytes[16] = 0x5a;
    free((void *)bytes);
}

__attribute__((noinline))
void mtest_exec_test_asan_uaf(void) {
    volatile uint8_t *bytes = (volatile uint8_t *)malloc(8);
    if (bytes == NULL) {
        abort();
    }
    free((void *)bytes);
    bytes[0] = 0x5a;
}

__attribute__((noinline))
void mtest_exec_test_asan_leak(void) {
    volatile uint8_t *bytes = (volatile uint8_t *)malloc(64);
    if (bytes == NULL) {
        abort();
    }
    bytes[0] = 0x5a;
    mtest_sanitizer_sink = bytes[0];
}

__attribute__((noinline))
void mtest_exec_test_memcheck_undefined(void) {
    volatile uint8_t *bytes = (volatile uint8_t *)malloc(1);
    if (bytes == NULL) {
        abort();
    }
    if (bytes[0] != 0) {
        mtest_sanitizer_sink = 1;
    }
    free((void *)bytes);
}

__attribute__((noinline))
void mtest_exec_test_memcheck_invalid(void) {
    volatile uint8_t *bytes = (volatile uint8_t *)malloc(8);
    if (bytes == NULL) {
        abort();
    }
    free((void *)bytes);
    mtest_sanitizer_sink = bytes[0];
}

__attribute__((noinline))
void mtest_exec_test_memcheck_fd_leak(void) {
    int fd = open("/dev/null", O_RDONLY);
    if (fd < 0) {
        abort();
    }
    mtest_sanitizer_sink = (uint8_t)fd;
}
#endif
