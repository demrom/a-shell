#include "include/ashell-p3.h"
#include <limits.h>
#include <pthread.h>
#include <string.h>
#include <time.h>

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
    return ashell_p3_command_tty(argc, argv, out, err, NULL);
}

/* Stock `wasmtime [run] [--dir HOST[::GUEST]] [--] file.wasm [args...]`. The guest
 * sees the whole filesystem already, so --dir is accepted and changes nothing.
 * --trusted-precompiled is ours: a .cwasm from the exact trusted build (C2). */
static const char *const other_subcommands[] = {
    "serve", "explore", "wast", "config", "settings", "objdump", "completion", "help",
};
static void usage(FILE *to) {
    fprintf(to, "usage: wasmtime [run] [--dir HOST[::GUEST]] [--] FILE.wasm [ARGS...]\n       wasmtime compile [-o OUT.cwasm] FILE.wasm\n");
}

/* Stock `wasmtime compile [-o OUT.cwasm] FILE.wasm`; OUT defaults to FILE with a .cwasm
 * extension. Publishes atomically and prints the elapsed time. */
static int compile_command(int argc, const char *const *argv, FILE *out, FILE *err) {
    const char *outpath = NULL, *input = NULL;
    for (int i = 2; i < argc; i++) {
        if ((strcmp(argv[i], "-o") == 0 || strcmp(argv[i], "--output") == 0) && i + 1 < argc) outpath = argv[++i];
        else if (argv[i][0] != '-' && !input) input = argv[i];
        else { fprintf(err, "usage: wasmtime compile [-o OUT.cwasm] FILE.wasm\n"); return 2; }
    }
    if (!input) { fprintf(err, "usage: wasmtime compile [-o OUT.cwasm] FILE.wasm\n"); return 2; }
    char derived[PATH_MAX];
    if (!outpath) {
        size_t n = strlen(input), dot = n;
        while (dot > 0 && input[dot - 1] != '.' && input[dot - 1] != '/') dot--;
        if (dot == 0 || input[dot - 1] == '/') dot = n + 1;
        snprintf(derived, sizeof derived, "%.*s.cwasm", (int)(dot - 1), input);
        outpath = derived;
    }
    AshellP3Runner *runner = ashell_p3_new();
    if (!runner) { fprintf(err, "wasmtime: engine creation failed\n"); return 1; }
    FILE *files[] = { out, err };
    AshellP3Output sink = { (uintptr_t)files, output };
    fprintf(out, "wasmtime: compiling %s for this device (one time)...\n", input);
    fflush(out);
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    int status = ashell_p3_compile(runner, input, outpath, sink);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    if (status == 0) fprintf(out, "wasmtime: wrote %s in %.2f s\n", outpath, (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) / 1e9);
    ashell_p3_delete(runner);
    return status;
}

int ashell_p3_command_tty(int argc, const char *const *argv, FILE *out, FILE *err, const AshellP3Tty *tty) {
    return ashell_p3_command_env(argc, argv, out, err, tty, NULL);
}

int ashell_p3_command_env(int argc, const char *const *argv, FILE *out, FILE *err, const AshellP3Tty *tty, const char *const *envp) {
    int trusted = 0, i = 1;
    if (i < argc && strcmp(argv[i], "compile") == 0) return compile_command(argc, argv, out, err);
    if (i < argc && strcmp(argv[i], "run") == 0) i++;
    else if (i < argc) {
        for (size_t n = 0; n < sizeof other_subcommands / sizeof *other_subcommands; n++) {
            if (strcmp(argv[i], other_subcommands[n]) == 0) {
                fprintf(err, "wasmtime: subcommand '%s' is not supported in a-Shell; only 'run' is\n", argv[i]);
                return 2;
            }
        }
    }
    for (; i < argc && argv[i][0] == '-' && argv[i][1]; i++) {
        const char *flag = argv[i];
        if (strcmp(flag, "--") == 0) { i++; break; }
        if (strcmp(flag, "-h") == 0 || strcmp(flag, "--help") == 0) { usage(out); return 0; }
        if (strcmp(flag, "--trusted-precompiled") == 0) trusted = 1;
        else if (strcmp(flag, "--dir") == 0 || strcmp(flag, "-d") == 0) {
            if (++i == argc) { fprintf(err, "wasmtime: %s needs a value\n", flag); return 2; }
        } else if (strncmp(flag, "--dir=", 6) != 0) {
            fprintf(err, "wasmtime: option '%s' is not supported in a-Shell\n", flag);
            return 2;
        }
    }
    if (i >= argc) {
        usage(err);
        return 2;
    }
    argc -= i;
    argv += i;
    AshellP3Runner *runner = ashell_p3_new();
    if (!runner) { fprintf(err, "wasmtime: engine creation failed\n"); return 1; }
    pthread_mutex_lock(&active_lock);
    if (active) {
        pthread_mutex_unlock(&active_lock);
        ashell_p3_delete(runner);
        fprintf(err, "wasmtime: worker already running a guest\n");
        return 1;
    }
    active = runner;
    pthread_mutex_unlock(&active_lock);
    ashell_p3_set_tty(runner, tty);
    ashell_p3_set_env(runner, envp);
    FILE *files[] = { out, err };
    AshellP3Output sink = { (uintptr_t)files, output };
    int status = trusted ? ashell_p3_run_trusted(runner, argv[0], (size_t)argc, argv, sink)
        : ashell_p3_run(runner, argv[0], (size_t)argc, argv, sink);
    pthread_mutex_lock(&active_lock);
    active = NULL;
    pthread_mutex_unlock(&active_lock);
    ashell_p3_delete(runner);
    return status;
}
