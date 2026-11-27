#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>

extern char **environ;

int main(void) {
    char *const argv[] = {"dash", "-c", "echo process-worker-ok; exit 7", NULL};
    pid_t child;
    int status;
    if (posix_spawnp(&child, argv[0], NULL, NULL, argv, environ) != 0) {
        fputs("posix_spawnp failed\n", stderr);
        return 90;
    }
    if (wait(&status) != child) {
        perror("wait");
        return 91;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 7) return 92;
    if (waitpid(child, NULL, WNOHANG) != -1 || errno != ECHILD) return 93;
    return 0;
}
