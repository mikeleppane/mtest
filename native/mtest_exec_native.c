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

#if MTEST_EXEC_TESTING
#include "mtest_exec_native_test.h"
#endif

extern char **environ;

#define MTEST_ETXTBSY_RETRIES 5u
#define MTEST_ETXTBSY_DELAY_NS 50000000L
#define MTEST_ABORT_SLICE_NS 10000000L

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

/* SAFETY: the signal handler accesses only `mtest_interrupt_flag`. Runtime and
   process state are ordinary-thread state guarded by the one lock-free atomic
   state machine; ABI v1 rejects a second runtime or active child. */
static volatile sig_atomic_t mtest_interrupt_flag;
static _Atomic int mtest_runtime_state;
static struct mtest_exec_process mtest_process;
static uint64_t mtest_next_handle = 1;
static struct sigaction mtest_old_int;
static struct sigaction mtest_old_term;
static struct sigaction mtest_old_chld;
static int mtest_old_int_saved;
static int mtest_old_term_saved;
static int mtest_old_chld_saved;
static int mtest_int_installed;
static int mtest_term_installed;
static int mtest_chld_installed;

#if MTEST_EXEC_TESTING
struct mtest_fault_state {
    uint32_t operation;
    uint32_t occurrence;
    uint32_t seen;
    int32_t error_number;
    int64_t result_value;
};

static struct mtest_fault_state mtest_faults[MTEST_EXEC_OP_WAITPID + 1];

static int mtest_fail_if_requested(uint32_t operation) {
    if (operation == MTEST_EXEC_OP_NONE || operation > MTEST_EXEC_OP_WAITPID) {
        return 0;
    }
    struct mtest_fault_state *fault = &mtest_faults[operation];
    if (fault->operation != operation) {
        return 0;
    }
    fault->seen += 1;
    if (fault->seen != fault->occurrence) {
        return 0;
    }
    errno = fault->error_number;
    return 1;
}

static int64_t mtest_fault_result(uint32_t operation) {
    if (operation <= MTEST_EXEC_OP_WAITPID) {
        const struct mtest_fault_state *fault = &mtest_faults[operation];
        if (fault->operation == operation &&
            fault->seen == fault->occurrence) {
            return fault->result_value;
        }
    }
    return 0;
}

void mtest_exec_test_fault_reset(void) {
    memset(mtest_faults, 0, sizeof(mtest_faults));
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
        if (error_number == 0 && (result_value < 1 || result_value > 7)) {
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
    return 0;
}

uint32_t mtest_exec_test_fault_seen(uint32_t operation) {
    if (operation > MTEST_EXEC_OP_WAITPID) {
        return 0;
    }
    const struct mtest_fault_state *fault = &mtest_faults[operation];
    return fault->operation == operation ? fault->seen : 0;
}

void mtest_exec_test_reset_interrupt(void) {
    mtest_interrupt_flag = 0;
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
    return sigaction(signal_number, action, old_action);
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

static void mtest_close_quietly(int *fd) {
    if (*fd >= 0) {
        (void)mtest_close_raw(*fd);
        *fd = -1;
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
    mtest_free_vector(plan->candidates);
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
    if (mtest_has_slash(plan->argv[0])) {
        plan->candidates[0] = mtest_join_candidate("", 0, plan->argv[0]);
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
            component = separator == NULL ? component + length : separator + 1;
        }
    }
    free(owned_default);
    for (size_t index = 0; index < plan->candidate_count; ++index) {
        if (plan->candidates[index] == NULL) {
            return -1;
        }
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
    mtest_interrupt_flag = 0;
    atomic_store(&mtest_runtime_state, MTEST_RUNTIME_OPEN);
    return 0;
}

int32_t mtest_exec_runtime_close(struct mtest_exec_error *error) {
    uint32_t first_operation = MTEST_EXEC_OP_NONE;
    int first_errno = 0;
    int had_failure = 0;
    int expected = MTEST_RUNTIME_OPEN;

    mtest_clear_error(error);
    if (!atomic_compare_exchange_strong(
            &mtest_runtime_state, &expected, MTEST_RUNTIME_OPENING
        )) {
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
    if (mtest_chld_installed &&
        sigaction(SIGCHLD, &mtest_old_chld, NULL) != 0) {
        first_errno = errno;
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

static int mtest_prepare_pipe(
    int pipe_fds[2],
    uint32_t pipe_operation,
    struct mtest_exec_error *error
) {
    if (mtest_fail_if_requested(pipe_operation) || pipe(pipe_fds) != 0) {
        mtest_set_error(error, pipe_operation, errno, 0, 0);
        return -1;
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
       copy-on-write image. Only setpgid, chdir, dup2, close, execve, nanosleep,
       write, and _exit are called; none retains a pointer after failed exec. */
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
    const struct timespec retry_delay = {0, MTEST_ETXTBSY_DELAY_NS};
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
            if (mtest_fail_if_requested(MTEST_EXEC_OP_CHILD_NANOSLEEP)) {
                mtest_child_report(
                    setup_write, MTEST_EXEC_STAGE_EXECVE, errno
                );
            }
            struct timespec remaining = retry_delay;
            while (nanosleep(&remaining, &remaining) != 0) {
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
    /* SAFETY: ABI handles are generation tokens, never addresses. Validate the
       exclusive-child state and exact live token before returning the one
       static process record; stale/arbitrary integers are never dereferenced. */
    if (atomic_load(&mtest_runtime_state) != MTEST_RUNTIME_CHILD_ACTIVE ||
        handle == 0 || handle != mtest_process.handle) {
        errno = EINVAL;
        return NULL;
    }
    return &mtest_process;
}

static void mtest_cleanup_pipes(int stdout_pipe[2], int stderr_pipe[2], int setup_pipe[2]) {
    mtest_close_quietly(&stdout_pipe[0]);
    mtest_close_quietly(&stdout_pipe[1]);
    mtest_close_quietly(&stderr_pipe[0]);
    mtest_close_quietly(&stderr_pipe[1]);
    mtest_close_quietly(&setup_pipe[0]);
    mtest_close_quietly(&setup_pipe[1]);
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
    struct mtest_exec_process *process = &mtest_process;
    memset(process, 0, sizeof(*process));
    process->stdout_fd = -1;
    process->stderr_fd = -1;
    process->setup_fd = -1;

    if (mtest_prepare_pipe(stdout_pipe, MTEST_EXEC_OP_PIPE_STDOUT, error) != 0 ||
        mtest_prepare_pipe(stderr_pipe, MTEST_EXEC_OP_PIPE_STDERR, error) != 0 ||
        mtest_prepare_pipe(setup_pipe, MTEST_EXEC_OP_PIPE_SETUP, error) != 0) {
        mtest_cleanup_pipes(stdout_pipe, stderr_pipe, setup_pipe);
        mtest_free_plan(plan);
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
            (void)waitpid(leader, NULL, 0);
            mtest_cleanup_pipes(stdout_pipe, stderr_pipe, setup_pipe);
            mtest_free_plan(plan);
            atomic_store(&mtest_runtime_state, MTEST_RUNTIME_OPEN);
            mtest_set_error(
                error, MTEST_EXEC_OP_PARENT_SETPGID, saved_errno, 0, leader
            );
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
        if (mtest_close_raw(*fd) != 0) {
            mtest_set_error(error, MTEST_EXEC_OP_CLOSE_CHANNEL, errno, 0, *fd);
            return -1;
        }
        *fd = -1;
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
        stage > MTEST_EXEC_STAGE_SETUP_WRITE || error_number <= 0) {
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
        if (mtest_close_raw(process->setup_fd) != 0) {
            mtest_set_error(
                error, MTEST_EXEC_OP_CLOSE_CHANNEL, errno, 0, closed_fd
            );
            return -1;
        }
        process->setup_fd = -1;
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
    if (mtest_fail_if_requested(MTEST_EXEC_OP_CLOSE_CHANNEL) ||
        mtest_close_raw(*fd) != 0) {
        mtest_set_error(error, MTEST_EXEC_OP_CLOSE_CHANNEL, errno, 0, closing);
        return -1;
    }
    *fd = -1;
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
    int signal_number = action == MTEST_EXEC_GROUP_PROBE
        ? 0
        : (action == MTEST_EXEC_GROUP_TERM ? SIGTERM : SIGKILL);
    uint32_t operation = mtest_group_operation(action);
    if (mtest_fail_if_requested(operation) ||
        kill(-process->process_group, signal_number) != 0) {
        if (errno == ESRCH) {
            result->state = MTEST_EXEC_GROUP_GONE;
            process->group_swept = 1;
            return 0;
        }
        mtest_set_error(
            error, operation, errno, 0, -((int64_t)process->process_group)
        );
        return -1;
    }
    if (action == MTEST_EXEC_GROUP_KILL) {
        /* A successful pre-reap SIGKILL reaches every member still in the
           owned process group. The deliberately waitable leader may keep the
           numeric group observable until waitpid; retained pipe writers are
           bounded and classified separately by the Mojo supervisor. */
        process->group_swept = 1;
    }
    result->state = MTEST_EXEC_GROUP_PRESENT;
    return 0;
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
       process group is gone, and all three read channels are closed. Clearing
       the sole static record invalidates the token before runtime reuse. */
    memset(process, 0, sizeof(*process));
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

    if (!process->reaped) {
        if (kill(-process->process_group, SIGTERM) != 0 && errno != ESRCH) {
            mtest_set_cleanup_error(error, MTEST_EXEC_OP_GROUP_TERM, errno);
        }
        int64_t start_ms = 0;
        int64_t now_ms = 0;
        struct timespec delay = {0, MTEST_ABORT_SLICE_NS};
        if (mtest_exec_monotonic_ms(&start_ms, error) != 0) {
            start_ms = 0;
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
        if (!process->observed) {
            if (kill(-process->process_group, SIGKILL) != 0 && errno != ESRCH) {
                mtest_set_cleanup_error(error, MTEST_EXEC_OP_GROUP_KILL, errno);
            }
            if (kill(process->leader, SIGKILL) != 0 && errno != ESRCH) {
                mtest_set_cleanup_error(error, MTEST_EXEC_OP_GROUP_KILL, errno);
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
        if (process->observed && !process->reaped) {
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
    }
    if (kill(-process->process_group, SIGKILL) != 0 && errno != ESRCH) {
        mtest_set_cleanup_error(error, MTEST_EXEC_OP_GROUP_KILL, errno);
    }
    if (kill(-process->process_group, 0) != 0 && errno == ESRCH) {
        process->group_swept = 1;
    }
    if (!process->reaped || !process->group_swept) {
        if (error != NULL && error->operation == MTEST_EXEC_OP_NONE) {
            mtest_set_error(error, MTEST_EXEC_OP_NONE, EBUSY, 0, process->leader);
        }
        return -1;
    }
    int had_error = error->operation != MTEST_EXEC_OP_NONE ||
        error->cleanup_operation != MTEST_EXEC_OP_NONE;
    if (had_error) {
        return -1;
    }
    mtest_free_process(process);
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
