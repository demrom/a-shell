#include "include/ashell-p3.h"
#include <pthread.h>
#include <string.h>
#include <time.h>
#ifdef __APPLE__
#include <mach/mach.h>
#endif

struct Run {
    AshellP3Runner *runner;
    const char *const *args;
    pthread_mutex_t lock;
    pthread_cond_t ready;
    char text[4096];
    size_t used;
    int first;
    int status;
    int trusted;
    FILE *out, *err;
    double first_output;
    double started, first_at, done_at;
};
static double monotonic(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1000000000.0;
}
static intptr_t output(uintptr_t context, int32_t stream, const uint8_t *bytes, size_t length) {
    struct Run *r = (struct Run *)context;
    if (stream == 2) return fwrite(bytes, 1, length, r->err);
    pthread_mutex_lock(&r->lock);
    if (length >= sizeof(r->text) - r->used) { pthread_mutex_unlock(&r->lock); return -1; }
    memcpy(r->text + r->used, bytes, length);
    r->used += length;
    r->text[r->used] = 0;
    if (!r->first_output) r->first_output = monotonic();
    if (!r->first && strstr(r->text, "HTTP_FIRST\n")) {
        r->first = 1;
        r->first_at = monotonic();
        pthread_cond_signal(&r->ready);
    }
    if (strstr(r->text, "HTTP_DONE\n")) r->done_at = monotonic();
    pthread_mutex_unlock(&r->lock);
    return (intptr_t)length;
}
static void *run(void *context) {
    struct Run *r = context;
    AshellP3Output sink = { (uintptr_t)r, output };
    r->started = monotonic();
    r->status = r->trusted ? ashell_p3_run_trusted(r->runner, r->args[0], 3, r->args, sink)
        : ashell_p3_run(r->runner, r->args[0], 3, r->args, sink);
    return NULL;
}
static int memory(FILE *out, const char *phase) {
#ifdef __APPLE__
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t status = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (status != KERN_SUCCESS || count < TASK_VM_INFO_REV3_COUNT) return 1;
    fprintf(out, "{\"phase\":\"%s\",\"physical_footprint\":%llu,\"peak_physical_footprint\":%lld,\"rss\":%llu,\"peak_rss\":%llu}\n",
        phase, (unsigned long long)info.phys_footprint, (long long)info.ledger_phys_footprint_peak,
        (unsigned long long)info.resident_size, (unsigned long long)info.resident_size_peak);
#else
    fprintf(out, "{\"phase\":\"%s\",\"physical_footprint\":null}\n", phase);
#endif
    fflush(out);
    return 0;
}
int ashell_p3_contract(int argc, const char *const *argv, FILE *out, FILE *err) {
    double entered = monotonic();
    int trusted = argc > 1 && strcmp(argv[1], "--trusted-precompiled") == 0;
    if (trusted) { argc--; argv++; }
    if (argc != 4) { fprintf(err, "usage: ffi-contract [--trusted-precompiled] HELLO HTTPS AUTHORITY\n"); return 2; }
    if (memory(out, "baseline")) return 1;
    AshellP3Runner *runner = ashell_p3_new();
    if (!runner) return 1;
    if (memory(out, "engine")) { ashell_p3_delete(runner); return 1; }
    const char *complete[] = { argv[2], argv[3], "/drip?duration=3&numbytes=6&code=200" };
    struct Run r = { .runner = runner, .args = complete, .lock = PTHREAD_MUTEX_INITIALIZER, .ready = PTHREAD_COND_INITIALIZER, .trusted = trusted, .out = out, .err = err };
    const char *hello[] = { argv[1] };
    AshellP3Output sink = { (uintptr_t)&r, output };
    int cold = trusted ? ashell_p3_run_trusted(runner, argv[1], 1, hello, sink)
        : ashell_p3_run(runner, argv[1], 1, hello, sink);
    if (cold != 0 || strcmp(r.text, "WASIP3_HELLO\n")) return 1;
    fprintf(out, "{\"cold_hello_status\":0,\"cold_entry_to_first_output_seconds\":%.6f,\"cold_state\":\"fresh process required; starts at C entry before engine creation\"}\n", r.first_output-entered);
    if (memory(out, "hello")) return 1;
    r.used = 0;
    r.text[0] = 0;
    r.first_output = 0;
    run(&r);
    if (r.status != 0 || strcmp(r.text, "HTTP_STATUS=200\nHTTP_FIRST\n******\nHTTP_DONE\n") || r.done_at - r.first_at < 1.0) return 1;
    fprintf(out, "{\"host_https_status\":0,\"first_seconds\":%.6f,\"remaining_stream_seconds\":%.6f}\n", r.first_at-r.started, r.done_at-r.first_at);
    if (memory(out, "https")) return 1;
    const char *cancel[] = { argv[2], argv[3], "/drip?duration=20&numbytes=20&code=200" };
    r.args = cancel;
    r.used = r.first = 0;
    r.text[0] = 0;
    pthread_t thread;
    if (pthread_create(&thread, NULL, run, &r)) return 1;
    pthread_mutex_lock(&r.lock);
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 30;
    int timed_out = 0;
    while (!r.first && !timed_out) timed_out = pthread_cond_timedwait(&r.ready, &r.lock, &deadline);
    pthread_mutex_unlock(&r.lock);
    double cancelled = monotonic();
    ashell_p3_cancel(runner);
    pthread_join(thread, NULL);
    if (timed_out || r.status != 130) return 1;
    fprintf(out, "{\"cancel_status\":130,\"cancel_seconds\":%.6f}\n", monotonic()-cancelled);
    if (memory(out, "cancel")) return 1;
    r.used = 0;
    r.text[0] = 0;
    int recovered = trusted ? ashell_p3_run_trusted(runner, argv[1], 1, hello, sink)
        : ashell_p3_run(runner, argv[1], 1, hello, sink);
    ashell_p3_delete(runner);
    pthread_cond_destroy(&r.ready);
    pthread_mutex_destroy(&r.lock);
    if (recovered != 0 || strcmp(r.text, "WASIP3_HELLO\n")) return 1;
    if (memory(out, "recovery")) return 1;
    fputs("{\"same_runner_recovery_status\":0,\"exact_hello\":true}\n", out);
    return 0;
}

#ifndef ASHELL_P3_EMBEDDED_CONTRACT
int main(int argc, const char *const *argv) {
    return ashell_p3_contract(argc, argv, stdout, stderr);
}
#endif
