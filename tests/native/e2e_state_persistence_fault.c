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
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * Test-only interposer for real-CLI last-run state persistence faults.
 * It recognizes only the descriptor returned for a lastrun mkstemp template.
 * The loader variable is cleared before mtest spawns any compiler or test
 * child, and this source is never linked into the product.
 */

enum mtest_fault_mode {
    MTEST_FAULT_NONE = 0,
    MTEST_FAULT_SHORT_EINTR,
    MTEST_FAULT_WRITE,
    MTEST_FAULT_CLOSE,
    MTEST_FAULT_RENAME,
};

typedef int (*mtest_mkstemp_fn)(char *);
typedef ssize_t (*mtest_write_fn)(int, const void *, size_t);
typedef int (*mtest_close_fn)(int);
typedef int (*mtest_rename_fn)(const char *, const char *);

static mtest_mkstemp_fn mtest_real_mkstemp;
static mtest_write_fn mtest_real_write;
static mtest_close_fn mtest_real_close;
static mtest_rename_fn mtest_real_rename;
static enum mtest_fault_mode mtest_mode;
static int mtest_state_fd = -1;
static int mtest_write_phase;
static const int mtest_eintr_count = 2048;

static void mtest_copy_symbol(void *target, size_t target_size, const char *name) {
    void *symbol = dlsym(RTLD_NEXT, name);

    if (target_size == sizeof(symbol)) {
        memcpy(target, &symbol, target_size);
    }
}

__attribute__((constructor)) static void mtest_initialize_faults(void) {
    const char *requested = getenv("MTEST_STATE_FAULT");

    mtest_copy_symbol(
        &mtest_real_mkstemp, sizeof(mtest_real_mkstemp), "mkstemp"
    );
    mtest_copy_symbol(&mtest_real_write, sizeof(mtest_real_write), "write");
    mtest_copy_symbol(&mtest_real_close, sizeof(mtest_real_close), "close");
    mtest_copy_symbol(&mtest_real_rename, sizeof(mtest_real_rename), "rename");

    if (requested != NULL && strcmp(requested, "short-eintr") == 0) {
        mtest_mode = MTEST_FAULT_SHORT_EINTR;
    } else if (requested != NULL && strcmp(requested, "write") == 0) {
        mtest_mode = MTEST_FAULT_WRITE;
    } else if (requested != NULL && strcmp(requested, "close") == 0) {
        mtest_mode = MTEST_FAULT_CLOSE;
    } else if (requested != NULL && strcmp(requested, "rename") == 0) {
        mtest_mode = MTEST_FAULT_RENAME;
    }
    unsetenv(MTEST_PRELOAD_VARIABLE);
}

static int mtest_faulting_mkstemp(char *template) {
    int fd;

    if (mtest_real_mkstemp == NULL) {
        errno = EIO;
        return -1;
    }
    fd = mtest_real_mkstemp(template);
    if (
        fd >= 0 && template != NULL
        && strstr(template, "lastrun.tmp.") != NULL
    ) {
        mtest_state_fd = fd;
        mtest_write_phase = 0;
    }
    return fd;
}

static ssize_t mtest_faulting_write(
    int fd, const void *buffer, size_t count
) {
    if (fd == mtest_state_fd) {
        if (mtest_mode == MTEST_FAULT_WRITE) {
            errno = EIO;
            return -1;
        }
        if (
            mtest_mode == MTEST_FAULT_SHORT_EINTR
            && mtest_write_phase == 0 && count > 1
        ) {
            size_t short_count = count > 3 ? 3 : 1;

            mtest_write_phase = 1;
            if (mtest_real_write == NULL) {
                errno = EIO;
                return -1;
            }
            return mtest_real_write(fd, buffer, short_count);
        }
        if (
            mtest_mode == MTEST_FAULT_SHORT_EINTR
            && mtest_write_phase >= 1
            && mtest_write_phase <= mtest_eintr_count
        ) {
            mtest_write_phase += 1;
            errno = EINTR;
            return -1;
        }
    }
    if (mtest_real_write == NULL) {
        errno = EIO;
        return -1;
    }
    return mtest_real_write(fd, buffer, count);
}

static int mtest_faulting_close(int fd) {
    if (fd == mtest_state_fd) {
        mtest_state_fd = -1;
        if (mtest_mode == MTEST_FAULT_CLOSE) {
            if (mtest_real_close != NULL) {
                (void)mtest_real_close(fd);
            }
            errno = EIO;
            return -1;
        }
    }
    if (mtest_real_close == NULL) {
        errno = EIO;
        return -1;
    }
    return mtest_real_close(fd);
}

static int mtest_faulting_rename(
    const char *source, const char *destination
) {
    if (
        mtest_mode == MTEST_FAULT_RENAME && source != NULL
        && strstr(source, "lastrun.tmp.") != NULL
    ) {
        errno = EIO;
        return -1;
    }
    if (mtest_real_rename == NULL) {
        errno = EIO;
        return -1;
    }
    return mtest_real_rename(source, destination);
}

#if defined(__APPLE__)

DYLD_INTERPOSE(mtest_faulting_mkstemp, mkstemp)
DYLD_INTERPOSE(mtest_faulting_write, write)
DYLD_INTERPOSE(mtest_faulting_close, close)
DYLD_INTERPOSE(mtest_faulting_rename, rename)

#else

int mkstemp(char *template) {
    return mtest_faulting_mkstemp(template);
}

ssize_t write(int fd, const void *buffer, size_t count) {
    return mtest_faulting_write(fd, buffer, count);
}

int close(int fd) {
    return mtest_faulting_close(fd);
}

int rename(const char *source, const char *destination) {
    return mtest_faulting_rename(source, destination);
}

#endif
