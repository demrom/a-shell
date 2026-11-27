#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    int fds[2];
    if (pipe(fds) < 0) {
        fprintf(stderr, "pipe failed: errno=%d\n", errno);
        return 90;
    }
    const int alias = 42;
    if (dup2(fds[1], alias) != alias || close(fds[1]) != 0) {
        perror("dup2 or close");
        return 91;
    }
    const char payload[] = {'a', '\0', 'b', '\n'};
    if (write(alias, payload, sizeof(payload)) != sizeof(payload) || close(alias) != 0) {
        perror("write or close");
        return 92;
    }
    char received[sizeof(payload)];
    if (read(fds[0], received, sizeof(received)) != sizeof(received) ||
        memcmp(payload, received, sizeof(received)) != 0 || read(fds[0], received, 1) != 0 ||
        close(fds[0]) != 0) {
        fputs("pipe data or EOF mismatch\n", stderr);
        return 93;
    }
    puts("process-pipe-ok");
    return 0;
}
