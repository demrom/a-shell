#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *argument = argc > 1 ? argv[1] : "none";
    printf("WASI_STDOUT:%s\n", argument);
    fprintf(stderr, "WASI_STDERR:%s\n", argument);
    return strcmp(argument, "nonzero") == 0 ? 17 : 0;
}
