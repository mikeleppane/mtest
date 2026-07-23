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
/* Arm a one-shot reentry: the next entry into the interrupt handler re-enters
   the handler once, from inside itself, mid-transition. Genuine nesting, not a
   queued masked signal. */
MTEST_EXEC_EXPORT void mtest_exec_test_arm_interrupt_reentry(void);
/* Invoke the interrupt handler directly once (as the OS would on delivery). */
MTEST_EXEC_EXPORT void mtest_exec_test_invoke_interrupt(void);
/* Real back-to-back delivery: install the handler unmasked (SA_NODEFER), raise
   the signal so it nests synchronously inside itself, restore, and return the
   saturating count. Proves no transition is lost under genuine OS reentry. */
MTEST_EXEC_EXPORT uint32_t mtest_exec_test_nested_interrupt_count(void);
/* Configure a fault scoped to one handle's operation, so a multi-slot test can
   fail exactly one slot's operation. Composes with the global fault table:
   both are consulted, the handle-scoped record fires only for its handle. */
MTEST_EXEC_EXPORT int32_t mtest_exec_test_fault_configure_handle(
    uint64_t handle,
    uint32_t operation,
    uint32_t occurrence,
    int32_t error_number
);
/* Observed activations of the handle-scoped fault since it was configured. */
MTEST_EXEC_EXPORT uint32_t mtest_exec_test_fault_handle_seen(void);
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
