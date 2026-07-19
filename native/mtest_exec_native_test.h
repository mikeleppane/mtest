#ifndef MTEST_EXEC_NATIVE_TEST_H
#define MTEST_EXEC_NATIVE_TEST_H

#include <stdint.h>

#include "mtest_exec_native.h"

#ifdef __cplusplus
extern "C" {
#endif

MTEST_EXEC_EXPORT int32_t mtest_exec_test_constant(uint32_t constant_id);
MTEST_EXEC_EXPORT void mtest_exec_test_fault_reset(void);
MTEST_EXEC_EXPORT int32_t mtest_exec_test_fault_configure(uint32_t operation, uint32_t occurrence, int32_t error_number, int64_t result_value);
MTEST_EXEC_EXPORT int32_t mtest_exec_test_fault_configure_secondary(
    uint32_t operation,
    uint32_t occurrence,
    int32_t error_number,
    int64_t result_value
);
MTEST_EXEC_EXPORT uint32_t mtest_exec_test_fault_seen(uint32_t operation);
MTEST_EXEC_EXPORT int32_t mtest_exec_test_group_signal_eperm_configure(
    uint32_t operation,
    uint32_t forced_failures
);
MTEST_EXEC_EXPORT uint32_t mtest_exec_test_group_signal_eperm_seen(
    uint32_t operation
);
MTEST_EXEC_EXPORT int32_t mtest_exec_test_monotonic_wait_configure(
    uint32_t occurrence,
    uint32_t max_wait_ms
);
MTEST_EXEC_EXPORT uint32_t mtest_exec_test_monotonic_wait_fired(void);
MTEST_EXEC_EXPORT void mtest_exec_test_reset_interrupt(void);
MTEST_EXEC_EXPORT int32_t mtest_exec_test_deliver_interrupt_after(
    uint32_t operation,
    int32_t signal_number
);
MTEST_EXEC_EXPORT void mtest_exec_test_asan_oob(void);
MTEST_EXEC_EXPORT void mtest_exec_test_asan_uaf(void);
MTEST_EXEC_EXPORT void mtest_exec_test_asan_leak(void);
MTEST_EXEC_EXPORT void mtest_exec_test_memcheck_undefined(void);
MTEST_EXEC_EXPORT void mtest_exec_test_memcheck_invalid(void);
MTEST_EXEC_EXPORT void mtest_exec_test_memcheck_fd_leak(void);

#ifdef __cplusplus
}
#endif

#endif
