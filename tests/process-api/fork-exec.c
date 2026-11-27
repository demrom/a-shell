#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    int fds[2];
    if (pipe(fds)) return 89;
    pid_t child = fork();
    if (child < 0) return 90;
    if (child == 0) {
        if (close(fds[0]) || dup2(fds[1], STDOUT_FILENO) != STDOUT_FILENO || close(fds[1])) _Exit(91);
        char *argv[] = {"dash", "-c", "echo process-fork-child; exit 7", NULL};
        execvp(argv[0], argv);
        _Exit(92);
    }
    if (close(fds[1])) return 93; // The child's close must not consume the parent's pipe.
    char bytes[64];
    size_t got = 0;
    while (got < sizeof(bytes)) {
        ssize_t count = read(fds[0], bytes + got, sizeof(bytes) - got);
        if (count < 0) return 94;
        if (!count) break;
        got += (size_t)count;
    }
    if (close(fds[0])) return 95;
    static const char expected[] = "process-fork-child\n";
    if (got != sizeof(expected) - 1 || memcmp(bytes, expected, got)) return 96;
    int status = -1;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 7) return 97;
    if (fwrite(bytes, 1, got, stdout) != got) return 98;
    return puts("process-fork-parent") < 0;
}
