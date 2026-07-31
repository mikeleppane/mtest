#include <stddef.h>

int mtest_stack_protector_canary(const char *input, size_t size);
void mtest_stack_protector_escape(volatile unsigned int *value);

int mtest_stack_protector_canary(const char *input, size_t size) {
    volatile unsigned int local = size == 0 ? 0u : (unsigned int)(unsigned char)input[0];
    mtest_stack_protector_escape(&local);
    return (int)(local & 0xffu);
}
