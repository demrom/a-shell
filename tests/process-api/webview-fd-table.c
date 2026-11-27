#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    int pair[2];
    if (pipe(pair) < 0) return 90;
    if (dup2(pair[1], STDIN_FILENO) < 0) return 91;
    int fd = open("fixture", O_RDONLY);
    if (fd <= STDERR_FILENO) return 92;
    if (close(fd) || close(pair[0]) || close(pair[1]) || close(STDIN_FILENO)) return 93;
    puts("process-fd-table-ok");
    return 0;
}
