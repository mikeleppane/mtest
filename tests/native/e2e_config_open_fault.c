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
#endif

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int (*mtest_open_fn)(const char *, int, ...);

static mtest_open_fn mtest_real_open;
static const char *mtest_swap_path;
static int mtest_swapped;

static void mtest_copy_symbol(void *target, size_t target_size, const char *name) {
    void *symbol = dlsym(RTLD_NEXT, name);

    if (target_size == sizeof(symbol)) {
        memcpy(target, &symbol, target_size);
    }
}

__attribute__((constructor)) static void mtest_initialize_fault(void) {
    mtest_copy_symbol(&mtest_real_open, sizeof(mtest_real_open), "open");
    mtest_swap_path = getenv("MTEST_CONFIG_SWAP_PATH");
    unsetenv(MTEST_PRELOAD_VARIABLE);
}

static int mtest_faulting_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    va_list arguments;

    if ((flags & O_CREAT) != 0) {
        va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
    if (
        !mtest_swapped && path != NULL && mtest_swap_path != NULL
        && strcmp(path, mtest_swap_path) == 0
    ) {
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
    }
    if (mtest_real_open == NULL) {
        errno = EIO;
        return -1;
    }
    if ((flags & O_CREAT) != 0) {
        return mtest_real_open(path, flags, mode);
    }
    return mtest_real_open(path, flags);
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
    }
    if ((flags & O_CREAT) != 0) {
        return mtest_faulting_open(path, flags, mode);
    }
    return mtest_faulting_open(path, flags);
}

#endif
