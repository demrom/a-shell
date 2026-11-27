#define _POSIX_C_SOURCE 200809L
#define _WASI_EMULATED_GETPID 1
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    size_t page = __builtin_wasm_memory_grow(0, 2);
    if (page == SIZE_MAX) return 89;
    volatile uint8_t *written = (volatile uint8_t *)(page * 65536);
    *written = 37;
    pid_t parent = getpid();
    pid_t child = vfork();
    if (child < 0) return 90;
    if (child == 0) {
        if (*written != 37 || getppid() != parent || getpid() == parent) _Exit(91);
        *written = 50;
        char *argv[] = {"dash", "-c", "exit 7", NULL};
        execvp(argv[0], argv);
        _Exit(92);
    }
    int status = -1;
    if (*written != 37 || waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 7) return 93;
    return puts("process-fork-grown-ok") < 0;
}
