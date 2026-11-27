#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>

extern char **environ;

int main(void) {
    posix_spawnattr_t attributes;
    if (posix_spawnattr_init(&attributes) != 0) return 90;
    short flags = -1;
    if (posix_spawnattr_getflags(&attributes, &flags) != 0 || flags != 0) return 91;
    if (posix_spawnattr_setflags(&attributes, POSIX_SPAWN_USEVFORK) != 0) return 92;
    const short unsupported[] = {POSIX_SPAWN_RESETIDS, POSIX_SPAWN_SETPGROUP,
        POSIX_SPAWN_SETSIGDEF, POSIX_SPAWN_SETSIGMASK, POSIX_SPAWN_SETSCHEDPARAM, POSIX_SPAWN_SETSCHEDULER};
    for (size_t i = 0; i < sizeof(unsupported) / sizeof(*unsupported); ++i) {
        if (posix_spawnattr_setflags(&attributes, unsupported[i]) != EINVAL) return 93;
    }
    if (posix_spawnattr_setflags(&attributes, -1) != EINVAL) return 93;
    if (posix_spawnattr_getflags(&attributes, &flags) != 0 || flags != POSIX_SPAWN_USEVFORK) return 94;
    char *const argv[] = {"dash", "-c", "echo process-worker-ok; exit 7", NULL};
    pid_t child;
    if (posix_spawnp(&child, argv[0], NULL, &attributes, argv, environ) != 0) return 95;
    if (posix_spawnattr_destroy(&attributes) != 0) return 96;
    int status;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 7) return 97;
    return 0;
}
