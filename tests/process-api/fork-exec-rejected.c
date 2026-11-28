#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    pid_t child = fork();
    if (child == 0) {
        // The broker rejects an empty executable name before worker admission.
        char empty[] = "";
        char *const args[] = {empty, NULL};
        execv(empty, args);
        _exit(127);
    }
    if (child != -1 || errno != EINVAL) return 90;
    return puts("process-fork-exec-rejected") < 0;
}
