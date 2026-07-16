#include "../../native/mtest_exec_native_test.h"

#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int child_invalid_control(void) {
    pid_t child = fork();
    if (child < 0) {
        return 3;
    }
    if (child == 0) {
        mtest_exec_test_memcheck_invalid();
        _exit(4);
    }
    int status = 0;
    if (waitpid(child, &status, 0) != child) {
        return 5;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        return 2;
    }
    if (strcmp(argv[1], "asan-oob") == 0) {
        mtest_exec_test_asan_oob();
    } else if (strcmp(argv[1], "asan-uaf") == 0) {
        mtest_exec_test_asan_uaf();
    } else if (strcmp(argv[1], "asan-leak") == 0) {
        mtest_exec_test_asan_leak();
    } else if (strcmp(argv[1], "mem-undefined") == 0) {
        mtest_exec_test_memcheck_undefined();
    } else if (strcmp(argv[1], "mem-invalid") == 0) {
        mtest_exec_test_memcheck_invalid();
    } else if (strcmp(argv[1], "mem-child-invalid") == 0) {
        return child_invalid_control();
    } else if (strcmp(argv[1], "mem-fd") == 0) {
        mtest_exec_test_memcheck_fd_leak();
    } else {
        return 2;
    }
    puts("CONTROL RETURNED");
    return 0;
}
