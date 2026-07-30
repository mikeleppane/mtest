#include <stddef.h>

int mtest_stack_protector_canary(const char *input, size_t size);

int mtest_stack_protector_canary(const char *input, size_t size) {
    volatile char local[64];
    size_t count = size < sizeof(local) ? size : sizeof(local);
    for (size_t index = 0; index < count; ++index) {
        local[index] = input[index];
    }
    return count == 0 ? 0 : local[count - 1];
}
