#define _POSIX_C_SOURCE 200809L
#include <ashell/process.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <time.h>

// The new ABI bit is deliberately spelled out for the pre-change RED.
#define PEEK 2u
extern char **environ;

int main(void) {
    int32_t sentinel = -123;
    char *args[] = {"sleep", "10", NULL};
    pid_t child;
    if (posix_spawnp(&child, args[0], NULL, NULL, args, environ)) return 90;
    int32_t result = ashell_process_wait(child, PEEK, &sentinel);
    if (result == -EINVAL) {
        fputs("process-wait-peek-unsupported\n", stderr);
        return 91;
    }
    if (result || sentinel != -123) return 92;
    if (ashell_process_wait(child, PEEK | ASHELL_WAIT_NOHANG, &sentinel) != -EINVAL || sentinel != -123) return 93;
    if (kill(child, SIGTERM)) return 94;
    int count;
    for (count = 0; count < 250; count++) {
        result = ashell_process_wait(child, PEEK, &sentinel);
        if (result != 0) break;
        if (nanosleep(&(struct timespec){.tv_nsec = 10000000}, NULL)) return 95;
    }
    if (result != child || sentinel != -123 || kill(child, 0)) return 96;
    if (ashell_process_wait(child, PEEK, NULL) != child) return 97;
    int status;
    if (waitpid(child, &status, WNOHANG) != child || !WIFSIGNALED(status) || WTERMSIG(status) != SIGTERM) return 98;
    if (ashell_process_wait(child, PEEK, &sentinel) != -ECHILD || sentinel != -123) return 99;
    return puts("process-wait-peek-ok") < 0;
}
