#include "include/ashell-p3.h"
#include <pthread.h>
#include <string.h>

static pthread_mutex_t active_lock = PTHREAD_MUTEX_INITIALIZER;
static AshellP3Runner *active;

static intptr_t output(uintptr_t context, int32_t stream, const uint8_t *bytes, size_t length) {
    FILE **files = (FILE **)context;
    FILE *file = files[stream == 1 ? 0 : 1];
    size_t count = fwrite(bytes, 1, length, file);
    if (fflush(file) != 0 || ferror(file)) return -1;
    return (intptr_t)count;
}

void ashell_p3_interrupt(void) {
    pthread_mutex_lock(&active_lock);
    if (active) ashell_p3_cancel(active);
    pthread_mutex_unlock(&active_lock);
}

int ashell_p3_command(int argc, const char *const *argv, FILE *out, FILE *err) {
    int trusted = argc > 1 && strcmp(argv[1], "--trusted-precompiled") == 0;
    if (trusted) { argc--; argv++; }
    if (argc < 2) {
        fprintf(err, "usage: p3proof COMPONENT.wasm [GUEST-ARGS...]\n");
        return 2;
    }
    AshellP3Runner *runner = ashell_p3_new();
    if (!runner) { fprintf(err, "p3proof: engine creation failed\n"); return 1; }
    pthread_mutex_lock(&active_lock);
    if (active) {
        pthread_mutex_unlock(&active_lock);
        ashell_p3_delete(runner);
        fprintf(err, "p3proof: worker already running a guest\n");
        return 1;
    }
    active = runner;
    pthread_mutex_unlock(&active_lock);
    FILE *files[] = { out, err };
    AshellP3Output sink = { (uintptr_t)files, output };
    int status = trusted ? ashell_p3_run_trusted(runner, argv[1], (size_t)argc - 1, argv + 1, sink)
        : ashell_p3_run(runner, argv[1], (size_t)argc - 1, argv + 1, sink);
    pthread_mutex_lock(&active_lock);
    active = NULL;
    pthread_mutex_unlock(&active_lock);
    ashell_p3_delete(runner);
    return status;
}
