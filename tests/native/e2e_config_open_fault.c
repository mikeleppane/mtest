#define _GNU_SOURCE

#if defined(__APPLE__)
#define MTEST_PRELOAD_VARIABLE "DYLD_INSERT_LIBRARIES"
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
#define MTEST_PRELOAD_VARIABLE "LD_PRELOAD"
#include <dlfcn.h>
#endif

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/*
 * Test-only open interposer for the configuration pathname-swap race. It
 * replaces the selected config path with a FIFO exactly once, immediately
 * before the real open, so the opened descriptor no longer names the regular
 * file that was checked. This source is never linked into mtest.
 */

static const char *mtest_swap_path;
static int mtest_swapped;

/*
 * Reach the real implementation. The two platforms differ, and the difference
 * is not cosmetic: on macOS, dlsym(RTLD_NEXT, "open") resolves to the
 * interposer itself, so a pointer obtained that way turns every passthrough
 * into unbounded self-recursion. dyld does not apply interposing tuples to the
 * image that declares them, so a direct call by name is the supported escape.
 */
#if defined(__APPLE__)

static int mtest_pass_open(
    const char *path, int flags, mode_t mode, int has_mode
) {
    if (has_mode) {
        return open(path, flags, mode);
    }
    return open(path, flags);
}

#else

typedef int (*mtest_open_fn)(const char *, int, ...);

static mtest_open_fn mtest_real_open;

static void mtest_copy_symbol(void *target, size_t target_size, const char *name) {
    void *symbol = dlsym(RTLD_NEXT, name);

    if (target_size == sizeof(symbol)) {
        memcpy(target, &symbol, target_size);
    }
}

static int mtest_pass_open(
    const char *path, int flags, mode_t mode, int has_mode
) {
    if (mtest_real_open == NULL) {
        errno = EIO;
        return -1;
    }
    if (has_mode) {
        return mtest_real_open(path, flags, mode);
    }
    return mtest_real_open(path, flags);
}

#endif

__attribute__((constructor)) static void mtest_initialize_fault(void) {
#if !defined(__APPLE__)
    mtest_copy_symbol(&mtest_real_open, sizeof(mtest_real_open), "open");
#endif
    mtest_swap_path = getenv("MTEST_CONFIG_SWAP_PATH");
    unsetenv(MTEST_PRELOAD_VARIABLE);
}

/* Return 0 to continue to the real open, or -1 with errno already set. */
static int mtest_apply_swap(const char *path, int flags) {
    if (
        mtest_swapped || path == NULL || mtest_swap_path == NULL
        || strcmp(path, mtest_swap_path) != 0
    ) {
        return 0;
    }
    mtest_swapped = 1;
    if (
        (flags & O_NONBLOCK) == 0
        || (flags & O_CLOEXEC) == 0
    ) {
        errno = EINVAL;
        return -1;
    }
    if (unlink(path) != 0 || mkfifo(path, 0600) != 0) {
        errno = EIO;
        return -1;
    }
    return 0;
}

static int mtest_faulting_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    int has_mode = (flags & O_CREAT) != 0;
    va_list arguments;

    if (has_mode) {
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
    if (mtest_apply_swap(path, flags) != 0) {
        return -1;
    }
    return mtest_pass_open(path, flags, mode, has_mode);
}

#if defined(__APPLE__)

DYLD_INTERPOSE(mtest_faulting_open, open)

#else

int open(const char *path, int flags, ...) {
    mode_t mode = 0;
    va_list arguments;

    if ((flags & O_CREAT) != 0) {
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
        return mtest_faulting_open(path, flags, mode);
    }
    return mtest_faulting_open(path, flags);
}

#endif
