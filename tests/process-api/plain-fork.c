#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    pid_t child = fork();
    if (child == 0) {
        puts("uncommitted child output");
        return 91;
    }
    if (child != -1 || errno != ENOTSUP) return 90;
    return puts("process-plain-fork-unsupported") < 0;
}
