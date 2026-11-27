#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>

extern char **environ;

int main(void) {
    char *sleeper[] = {"sleep", "10", NULL};
    char *normal[] = {"dash", "-c", "exit 143", NULL};
    pid_t child;
    int status = -123;
    if (posix_spawnp(&child, sleeper[0], NULL, NULL, sleeper, environ)) return 90;
    if (kill(child, 0) || waitpid(child, &status, WNOHANG) || status != -123) return 91;
    if (kill(child, SIGUSR1) != -1 || errno != ENOTSUP) return 92;
    if (kill(child, SIGTERM)) return 93;
    if (waitpid(child, &status, 0) != child || !WIFSIGNALED(status) || WTERMSIG(status) != SIGTERM) return 94;
    if (kill(child, 0) != -1 || errno != ESRCH) return 95;

    if (posix_spawnp(&child, normal[0], NULL, NULL, normal, environ)) return 96;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 143) return 97;
    return puts("process-kill-ok") < 0;
}
