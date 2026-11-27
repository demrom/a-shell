#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <string.h>
#include <sys/wait.h>

int main(void) {
    FILE *child = popen("printf 'process-popen-ok\\n'; exit 7", "r");
    if (child == NULL) {
        perror("popen");
        return 90;
    }
    char line[64];
    int matched = fgets(line, sizeof(line), child) != NULL &&
                  strcmp(line, "process-popen-ok\n") == 0;
    int eof = fgetc(child) == EOF && feof(child) && !ferror(child);
    int status = pclose(child);
    if (!matched || !eof || status < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 7) {
        fprintf(stderr, "popen: matched=%d eof=%d wait status=%d\n", matched, eof, status);
        return 91;
    }
    fputs(line, stdout);
    return 0;
}
