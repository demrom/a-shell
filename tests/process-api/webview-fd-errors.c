#include <errno.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    int pair[2] = {-1, -1};
    if (pipe(pair) != -1 || errno != EIO || pair[0] != -1 || pair[1] != -1) return 90;
    if (pipe(pair) != 0) return 91;
    if (close(pair[1]) != -1 || errno != EIO) return 92;
    if (dup2(pair[0], pair[1]) != pair[1]) return 93;
    if (close(pair[0]) || close(pair[1])) return 94;
    puts("process-fd-errors-ok");
    return 0;
}
