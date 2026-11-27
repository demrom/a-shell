#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    int status = system("echo process-worker-ok; exit 7");
    if (status != (7 << 8)) {
        fprintf(stderr, "system: expected wait status %d, got %d (errno %d)\n", 7 << 8, status, errno);
        return 90;
    }
    return system(NULL) != 0 ? 0 : 91;
}
