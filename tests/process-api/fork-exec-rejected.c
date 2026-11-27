#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    pid_t child = fork();
    if (child == 0) {
        const char *path = "/ashell-process-fixture-missing/executable";
        char *const args[] = {(char *)path, NULL};
        execv(path, args);
        _exit(127);
    }
    if (child != -1 || errno != ENOENT) return 90;
    return puts("process-fork-exec-rejected") < 0;
}
