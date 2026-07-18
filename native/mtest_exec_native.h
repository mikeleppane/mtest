#ifndef MTEST_EXEC_NATIVE_H
#define MTEST_EXEC_NATIVE_H

#include <stddef.h>
#include <stdint.h>

#if defined(__GNUC__) || defined(__clang__)
#define MTEST_EXEC_EXPORT __attribute__((visibility("default")))
#else
#define MTEST_EXEC_EXPORT
#endif

#define MTEST_EXEC_NATIVE_ABI_VERSION 1u
#define MTEST_EXEC_PROCESS_HAS_CWD 1u

enum mtest_exec_channel {
    MTEST_EXEC_CHANNEL_STDOUT = 1,
    MTEST_EXEC_CHANNEL_STDERR = 2,
    MTEST_EXEC_CHANNEL_SETUP = 3
};

enum mtest_exec_readiness {
    MTEST_EXEC_READY_STDOUT = 1,
    MTEST_EXEC_READY_STDERR = 2,
    MTEST_EXEC_READY_SETUP = 4
};

enum mtest_exec_read_state {
    MTEST_EXEC_READ_BYTES = 1,
    MTEST_EXEC_READ_EOF = 2,
    MTEST_EXEC_READ_WOULD_BLOCK = 3
};

enum mtest_exec_setup_outcome {
    MTEST_EXEC_SETUP_WAITING = 0,
    MTEST_EXEC_SETUP_EXEC_SUCCEEDED = 1,
    MTEST_EXEC_SETUP_SPAWN_FAILED = 2,
    MTEST_EXEC_SETUP_CORRUPT = 3
};

enum mtest_exec_setup_stage {
    MTEST_EXEC_STAGE_SETPGID = 1,
    MTEST_EXEC_STAGE_CHDIR = 2,
    MTEST_EXEC_STAGE_DUP2_STDOUT = 3,
    MTEST_EXEC_STAGE_DUP2_STDERR = 4,
    MTEST_EXEC_STAGE_CLOSE = 5,
    MTEST_EXEC_STAGE_EXECVE = 6,
    MTEST_EXEC_STAGE_SETUP_WRITE = 7
};

enum mtest_exec_group_action {
    MTEST_EXEC_GROUP_PROBE = 0,
    MTEST_EXEC_GROUP_TERM = 1,
    MTEST_EXEC_GROUP_KILL = 2
};

enum mtest_exec_group_state {
    MTEST_EXEC_GROUP_PRESENT = 1,
    MTEST_EXEC_GROUP_GONE = 2
};

enum mtest_exec_observe_state {
    MTEST_EXEC_LEADER_NOT_WAITABLE = 0,
    MTEST_EXEC_LEADER_WAITABLE = 1
};

enum mtest_exec_reap_kind {
    MTEST_EXEC_REAP_EXITED = 1,
    MTEST_EXEC_REAP_SIGNALED = 2,
    MTEST_EXEC_REAP_OTHER = 3
};

enum mtest_exec_operation {
    MTEST_EXEC_OP_NONE = 0,
    MTEST_EXEC_OP_CLOCK_MONOTONIC = 1,
    MTEST_EXEC_OP_SIGACTION_QUERY_INT = 2,
    MTEST_EXEC_OP_SIGACTION_QUERY_TERM = 3,
    MTEST_EXEC_OP_SIGACTION_INSTALL_INT = 4,
    MTEST_EXEC_OP_SIGACTION_INSTALL_TERM = 5,
    MTEST_EXEC_OP_SIGACTION_RESTORE_INT = 6,
    MTEST_EXEC_OP_SIGACTION_RESTORE_TERM = 7,
    MTEST_EXEC_OP_ENV_SNAPSHOT = 8,
    MTEST_EXEC_OP_PATH_CONFSTR = 9,
    MTEST_EXEC_OP_PLAN_ALLOC = 10,
    MTEST_EXEC_OP_PIPE_STDOUT = 11,
    MTEST_EXEC_OP_PIPE_STDERR = 12,
    MTEST_EXEC_OP_PIPE_SETUP = 13,
    MTEST_EXEC_OP_FD_CLOEXEC = 14,
    MTEST_EXEC_OP_FD_NONBLOCK = 15,
    MTEST_EXEC_OP_FORK = 16,
    MTEST_EXEC_OP_PARENT_SETPGID = 17,
    MTEST_EXEC_OP_CHILD_SETPGID = 18,
    MTEST_EXEC_OP_CHILD_CHDIR = 19,
    MTEST_EXEC_OP_CHILD_DUP2_STDOUT = 20,
    MTEST_EXEC_OP_CHILD_DUP2_STDERR = 21,
    MTEST_EXEC_OP_CHILD_CLOSE = 22,
    MTEST_EXEC_OP_CHILD_POLL = 23,
    MTEST_EXEC_OP_CHILD_EXECVE = 24,
    MTEST_EXEC_OP_CHILD_SETUP_WRITE = 25,
    MTEST_EXEC_OP_POLL = 26,
    MTEST_EXEC_OP_READ_STDOUT = 27,
    MTEST_EXEC_OP_READ_STDERR = 28,
    MTEST_EXEC_OP_READ_SETUP = 29,
    MTEST_EXEC_OP_CLOSE_CHANNEL = 30,
    MTEST_EXEC_OP_GROUP_PROBE = 31,
    MTEST_EXEC_OP_GROUP_TERM = 32,
    MTEST_EXEC_OP_GROUP_KILL = 33,
    MTEST_EXEC_OP_WAITID = 34,
    MTEST_EXEC_OP_WAITPID = 35
};

struct mtest_exec_bytes {
    const uint8_t *data;
    uint64_t length;
};

struct mtest_exec_process_spec {
    const struct mtest_exec_bytes *argv;
    uint64_t argc;
    struct mtest_exec_bytes cwd;
    uint32_t flags;
    uint32_t reserved;
};

struct mtest_exec_error {
    uint32_t operation;
    int32_t error_number;
    uint32_t cleanup_operation;
    int32_t cleanup_error_number;
    uint64_t detail;
    int64_t subject;
};

struct mtest_exec_process_ref {
    uint64_t handle;
    int32_t leader_pid;
    int32_t process_group;
};

struct mtest_exec_poll_result {
    uint32_t readiness;
    uint32_t reserved;
};

struct mtest_exec_read_result {
    uint32_t state;
    int32_t error_number;
    uint64_t count;
};

struct mtest_exec_setup_state {
    uint8_t raw[8];
    uint32_t length;
    uint32_t outcome;
    uint32_t stage;
    int32_t error_number;
};

struct mtest_exec_group_result {
    uint32_t state;
    uint32_t reserved;
};

struct mtest_exec_observe_result {
    uint32_t state;
    uint32_t reserved;
};

struct mtest_exec_reap_result {
    int32_t raw_status;
    uint32_t kind;
    int32_t value;
    uint32_t reserved;
};

/* SAFETY: ABI v1 crosses from Mojo as fixed-width byte records. Every size,
   alignment, and offset below is asserted from the platform C compiler's own
   layout; reserved fields must be zero and C never retains a caller record. */
_Static_assert(sizeof(void *) == 8, "ABI v1 requires LP64 pointers");
_Static_assert(sizeof(struct mtest_exec_bytes) == 16, "bytes size");
_Static_assert(_Alignof(struct mtest_exec_bytes) == 8, "bytes alignment");
_Static_assert(offsetof(struct mtest_exec_bytes, data) == 0, "bytes.data");
_Static_assert(offsetof(struct mtest_exec_bytes, length) == 8, "bytes.length");
_Static_assert(sizeof(struct mtest_exec_process_spec) == 40, "spec size");
_Static_assert(_Alignof(struct mtest_exec_process_spec) == 8, "spec alignment");
_Static_assert(offsetof(struct mtest_exec_process_spec, argv) == 0, "spec.argv");
_Static_assert(offsetof(struct mtest_exec_process_spec, argc) == 8, "spec.argc");
_Static_assert(offsetof(struct mtest_exec_process_spec, cwd) == 16, "spec.cwd");
_Static_assert(offsetof(struct mtest_exec_process_spec, flags) == 32, "spec.flags");
_Static_assert(offsetof(struct mtest_exec_process_spec, reserved) == 36, "spec.reserved");
_Static_assert(sizeof(struct mtest_exec_error) == 32, "error size");
_Static_assert(_Alignof(struct mtest_exec_error) == 8, "error alignment");
_Static_assert(offsetof(struct mtest_exec_error, operation) == 0, "error operation");
_Static_assert(offsetof(struct mtest_exec_error, error_number) == 4, "error errno");
_Static_assert(offsetof(struct mtest_exec_error, cleanup_operation) == 8, "error cleanup operation");
_Static_assert(offsetof(struct mtest_exec_error, cleanup_error_number) == 12, "error cleanup errno");
_Static_assert(offsetof(struct mtest_exec_error, detail) == 16, "error detail");
_Static_assert(offsetof(struct mtest_exec_error, subject) == 24, "error subject");
_Static_assert(sizeof(struct mtest_exec_process_ref) == 16, "process ref size");
_Static_assert(_Alignof(struct mtest_exec_process_ref) == 8, "process ref alignment");
_Static_assert(offsetof(struct mtest_exec_process_ref, handle) == 0, "process ref handle");
_Static_assert(offsetof(struct mtest_exec_process_ref, leader_pid) == 8, "process ref leader");
_Static_assert(offsetof(struct mtest_exec_process_ref, process_group) == 12, "process ref group");
_Static_assert(sizeof(struct mtest_exec_poll_result) == 8, "poll result size");
_Static_assert(_Alignof(struct mtest_exec_poll_result) == 4, "poll result alignment");
_Static_assert(offsetof(struct mtest_exec_poll_result, readiness) == 0, "poll readiness");
_Static_assert(offsetof(struct mtest_exec_poll_result, reserved) == 4, "poll reserved");
_Static_assert(sizeof(struct mtest_exec_read_result) == 16, "read result size");
_Static_assert(_Alignof(struct mtest_exec_read_result) == 8, "read result alignment");
_Static_assert(offsetof(struct mtest_exec_read_result, state) == 0, "read result state");
_Static_assert(offsetof(struct mtest_exec_read_result, error_number) == 4, "read result errno");
_Static_assert(offsetof(struct mtest_exec_read_result, count) == 8, "read result count");
_Static_assert(sizeof(struct mtest_exec_setup_state) == 24, "setup state size");
_Static_assert(_Alignof(struct mtest_exec_setup_state) == 4, "setup state alignment");
_Static_assert(offsetof(struct mtest_exec_setup_state, raw) == 0, "setup raw");
_Static_assert(offsetof(struct mtest_exec_setup_state, length) == 8, "setup length");
_Static_assert(offsetof(struct mtest_exec_setup_state, outcome) == 12, "setup outcome");
_Static_assert(offsetof(struct mtest_exec_setup_state, stage) == 16, "setup stage");
_Static_assert(offsetof(struct mtest_exec_setup_state, error_number) == 20, "setup errno");
_Static_assert(sizeof(struct mtest_exec_group_result) == 8, "group result size");
_Static_assert(_Alignof(struct mtest_exec_group_result) == 4, "group result alignment");
_Static_assert(offsetof(struct mtest_exec_group_result, state) == 0, "group state");
_Static_assert(offsetof(struct mtest_exec_group_result, reserved) == 4, "group reserved");
_Static_assert(sizeof(struct mtest_exec_observe_result) == 8, "observe result size");
_Static_assert(_Alignof(struct mtest_exec_observe_result) == 4, "observe result alignment");
_Static_assert(offsetof(struct mtest_exec_observe_result, state) == 0, "observe state");
_Static_assert(offsetof(struct mtest_exec_observe_result, reserved) == 4, "observe reserved");
_Static_assert(sizeof(struct mtest_exec_reap_result) == 16, "reap result size");
_Static_assert(_Alignof(struct mtest_exec_reap_result) == 4, "reap result alignment");
_Static_assert(offsetof(struct mtest_exec_reap_result, raw_status) == 0, "reap raw status");
_Static_assert(offsetof(struct mtest_exec_reap_result, kind) == 4, "reap kind");
_Static_assert(offsetof(struct mtest_exec_reap_result, value) == 8, "reap value");
_Static_assert(offsetof(struct mtest_exec_reap_result, reserved) == 12, "reap reserved");

#ifdef __cplusplus
extern "C" {
#endif

MTEST_EXEC_EXPORT uint32_t mtest_exec_native_abi_version(void);
MTEST_EXEC_EXPORT int32_t mtest_exec_runtime_open(struct mtest_exec_error *error);
MTEST_EXEC_EXPORT int32_t mtest_exec_runtime_close(struct mtest_exec_error *error);
MTEST_EXEC_EXPORT int32_t mtest_exec_interrupt_requested(void);
MTEST_EXEC_EXPORT int32_t mtest_exec_monotonic_ms(int64_t *milliseconds, struct mtest_exec_error *error);
MTEST_EXEC_EXPORT int32_t mtest_exec_process_open(const struct mtest_exec_process_spec *spec, struct mtest_exec_process_ref *process, struct mtest_exec_error *error);
MTEST_EXEC_EXPORT int32_t mtest_exec_process_poll(uint64_t handle, int32_t timeout_ms, struct mtest_exec_poll_result *result, struct mtest_exec_error *error);
MTEST_EXEC_EXPORT int32_t mtest_exec_process_read(uint64_t handle, uint32_t channel, uint8_t *buffer, uint64_t capacity, struct mtest_exec_read_result *result, struct mtest_exec_error *error);
MTEST_EXEC_EXPORT int32_t mtest_exec_process_setup_drain(uint64_t handle, struct mtest_exec_setup_state *state, struct mtest_exec_error *error);
MTEST_EXEC_EXPORT int32_t mtest_exec_process_channel_close(uint64_t handle, uint32_t channel, struct mtest_exec_error *error);
MTEST_EXEC_EXPORT int32_t mtest_exec_process_group(uint64_t handle, uint32_t action, struct mtest_exec_group_result *result, struct mtest_exec_error *error);
MTEST_EXEC_EXPORT int32_t mtest_exec_process_observe(uint64_t handle, struct mtest_exec_observe_result *result, struct mtest_exec_error *error);
MTEST_EXEC_EXPORT int32_t mtest_exec_process_reap(uint64_t handle, struct mtest_exec_reap_result *result, struct mtest_exec_error *error);
MTEST_EXEC_EXPORT int32_t mtest_exec_process_close(uint64_t handle, struct mtest_exec_error *error);
MTEST_EXEC_EXPORT int32_t mtest_exec_process_abort(uint64_t handle, uint32_t grace_ms, struct mtest_exec_error *error);

#ifdef __cplusplus
}
#endif

#endif
