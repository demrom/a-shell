#include <stdio.h>
#include <unistd.h>

int main(void) {
    char *argv[] = {"dash", "-c", "echo process-worker-ok; exit 7", NULL};
    execvp(argv[0], argv);
    perror("execvp returned");
    return 90;
}
