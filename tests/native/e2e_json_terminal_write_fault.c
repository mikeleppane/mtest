#define _GNU_SOURCE

#if defined(__APPLE__)
#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee \
        __attribute__((section("__DATA,__interpose,interposing"))) = { \
            (const void *)(unsigned long)&_replacement, \
            (const void *)(unsigned long)&_replacee, \
        };
#else
#include <dlfcn.h>
#endif

#include <errno.h>
#include <stddef.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>

/*
 * Test-only write interposer for the real CLI E2E terminal-record failure.
 * It rejects only the exact JSON event marker; every other write follows the
 * platform interposition contract. This source is never linked into mtest.
 */

static const char mtest_terminal_marker[] = "\"event\":\"session_finished\"";

static int mtest_contains_terminal_marker(const void *buffer, size_t count) {
    const unsigned char *bytes = buffer;
    const size_t marker_length = sizeof(mtest_terminal_marker) - 1;

    if (buffer == NULL || count < marker_length) {
        return 0;
    }
    for (size_t offset = 0; offset <= count - marker_length; ++offset) {
        if (memcmp(bytes + offset, mtest_terminal_marker, marker_length) == 0) {
            return 1;
        }
    }
    return 0;
}

#if defined(__APPLE__)

static ssize_t mtest_faulting_write(int fd, const void *buffer, size_t count) {
    if (mtest_contains_terminal_marker(buffer, count)) {
        errno = EIO;
        return -1;
    }
    struct iovec vector = {(void *)buffer, count};
    return writev(fd, &vector, 1);
}

DYLD_INTERPOSE(mtest_faulting_write, write)

#else

typedef ssize_t (*mtest_write_fn)(int, const void *, size_t);

static mtest_write_fn mtest_real_write;

__attribute__((constructor)) static void mtest_resolve_real_write(void) {
    void *symbol = dlsym(RTLD_NEXT, "write");

    _Static_assert(
        sizeof(mtest_real_write) == sizeof(symbol),
        "function and object pointers must share a representation"
    );
    memcpy(&mtest_real_write, &symbol, sizeof(mtest_real_write));
}

static ssize_t mtest_faulting_write(int fd, const void *buffer, size_t count) {
    if (mtest_contains_terminal_marker(buffer, count)) {
        errno = EIO;
        return -1;
    }
    if (mtest_real_write == NULL) {
        errno = EIO;
        return -1;
    }
    return mtest_real_write(fd, buffer, count);
}

ssize_t write(int fd, const void *buffer, size_t count) {
    return mtest_faulting_write(fd, buffer, count);
}

#endif
