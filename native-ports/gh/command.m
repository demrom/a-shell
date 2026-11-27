// Capture the command streams before entering Go, which uses its own threads.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ios_system.h"

extern int gh_embedded_run(int, char **, int, int, int, char *, char *, char *);

static char *copy_env(const char *name) {
    const char *value = ios_getenv(name);
    return value && *value ? strdup(value) : NULL;
}

int gh_ios_main(int argc, char **argv) {
    FILE *input = ios_stdin(), *output = ios_stdout(), *errors = ios_stderr();
    if (argc < 1 || !input || !output || !errors ||
        fflush(output) == EOF || fflush(errors) == EOF) return 1;

    char *token = copy_env("GH_TOKEN");
    if (!token) token = copy_env("GITHUB_TOKEN");
    char *repo = copy_env("GH_REPO");
    char *host = copy_env("GH_HOST");
    int previous;
    int status = 1;
    // pthread cancellation cannot unwind Go; restore it only after cleanup.
    if (pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous) == 0) {
        status = gh_embedded_run(argc, argv, fileno(input), fileno(output),
            fileno(errors), token, repo, host);
        free(token);
        free(repo);
        free(host);
        pthread_setcancelstate(previous, NULL);
        return status;
    }
    free(token);
    free(repo);
    free(host);
    return status;
}
