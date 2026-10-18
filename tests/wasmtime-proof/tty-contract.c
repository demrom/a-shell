#include "include/ashell-p3.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* The fake is the outer boundary only: the a-Shell terminal. The guest, engine and
 * host bridge are real. Input is delivered only while raw mode is on, and never
 * ends with EOF, so a guest that returns with the arrow key proves unbuffered reads. */
struct Terminal {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    int raw, raw_off_calls, closed, send_key, reads_while_cooked;
    char out[1024], err[1024];
};
static struct Terminal term = { .lock = PTHREAD_MUTEX_INITIALIZER, .changed = PTHREAD_COND_INITIALIZER };

static int32_t term_size(uintptr_t c, uint32_t *columns, uint32_t *rows) {
    (void)c; *columns = 80; *rows = 24; return 0;
}
static int32_t term_raw(uintptr_t c, int32_t enabled) {
    (void)c;
    pthread_mutex_lock(&term.lock);
    term.raw = enabled;
    if (!enabled) term.raw_off_calls++;
    pthread_cond_broadcast(&term.changed);
    pthread_mutex_unlock(&term.lock);
    return 0;
}
static intptr_t term_read(uintptr_t c, uint8_t *bytes, size_t length) {
    (void)c;
    pthread_mutex_lock(&term.lock);
    if (!term.raw) term.reads_while_cooked++;
    while (!term.closed && !(term.raw && term.send_key)) pthread_cond_wait(&term.changed, &term.lock);
    intptr_t n = -1;
    if (term.closed) n = 0;
    else if (length >= 3) { memcpy(bytes, "\x1b[A", 3); term.send_key = 0; n = 3; }
    pthread_mutex_unlock(&term.lock);
    return n;
}
static void term_reset(int send_key) {
    pthread_mutex_lock(&term.lock);
    term.raw = term.raw_off_calls = term.closed = term.reads_while_cooked = 0;
    term.send_key = send_key;
    term.out[0] = term.err[0] = 0;
    pthread_mutex_unlock(&term.lock);
}
static void term_close(void) {
    pthread_mutex_lock(&term.lock);
    term.closed = 1;
    pthread_cond_broadcast(&term.changed);
    pthread_mutex_unlock(&term.lock);
}
static intptr_t output(uintptr_t c, int32_t stream, const uint8_t *bytes, size_t length) {
    (void)c;
    char *to = stream == 1 ? term.out : term.err;
    pthread_mutex_lock(&term.lock);
    size_t used = strlen(to);
    if (used + length >= 1024) { pthread_mutex_unlock(&term.lock); return -1; }
    memcpy(to + used, bytes, length);
    to[used + length] = 0;
    pthread_cond_broadcast(&term.changed);
    pthread_mutex_unlock(&term.lock);
    return (intptr_t)length;
}

struct Run { AshellP3Runner *runner; const char *const *argv; size_t argc; int status; };
static void *run(void *context) {
    struct Run *r = context;
    AshellP3Output sink = { 0, output };
    r->status = ashell_p3_run(r->runner, r->argv[0], r->argc, r->argv, sink);
    return NULL;
}

static int failures;
static void expect(int ok, const char *what) {
    printf("{\"check\":\"%s\",\"pass\":%s}\n", what, ok ? "true" : "false");
    if (!ok) { failures++; fprintf(stderr, "FAIL: %s\n  stdout: %s  stderr: %s\n", what, term.out, term.err); }
}

int main(int argc, const char *const *argv) {
    if (argc != 2) { fprintf(stderr, "usage: tty-contract TTY.component.wasm\n"); return 2; }
    AshellP3Runner *runner = ashell_p3_new();
    if (!runner) return 1;
    AshellP3Tty tty = { 0, term_size, term_raw, term_read };
    const char *key[] = { argv[1], "key" }, *leave[] = { argv[1], "leave" }, *trap[] = { argv[1], "trap" };
    struct Run r = { runner, key, 2, -1 };

    /* No bridge: the guest's first call fails, nothing reaches the terminal. */
    term_reset(1);
    run(&r);
    expect(r.status == 1 && !strstr(term.out, "SIZE=") && !term.raw, "no bridge: get-size unsupported, status 1");

    /* Size, raw on, an arrow key read unbuffered (no EOF is ever sent), raw off. */
    ashell_p3_set_tty(runner, &tty);
    term_reset(1);
    run(&r);
    expect(r.status == 0 && !strcmp(term.out, "SIZE=80x24\nRAW=on\nKEYS=1b5b41\nRAW=off\n"), "size, raw, arrow key, raw off: exact stdout, status 0");
    expect(!term.raw && term.reads_while_cooked == 0, "terminal cooked after exit; no read happened in cooked mode");

    /* The guest returns with raw on: the host restores the terminal. */
    term_reset(0);
    r.argv = leave;
    run(&r);
    expect(r.status == 0 && !term.raw && term.raw_off_calls == 1, "guest returns with raw on: host restores cooked");

    /* The guest traps with raw on. */
    term_reset(0);
    r.argv = trap;
    run(&r);
    expect(r.status == 1 && !term.raw && term.raw_off_calls == 1, "guest traps with raw on: status 1, host restores cooked");

    /* Ctrl-C while the guest waits on a key in raw mode. */
    term_reset(0);
    r.argv = key;
    pthread_t thread;
    if (pthread_create(&thread, NULL, run, &r)) return 1;
    pthread_mutex_lock(&term.lock);
    while (!strstr(term.out, "RAW=on\n")) pthread_cond_wait(&term.changed, &term.lock);
    pthread_mutex_unlock(&term.lock);
    ashell_p3_cancel(runner);
    pthread_join(thread, NULL);
    term_close(); /* the abandoned terminal read returns */
    expect(r.status == 130 && !term.raw && term.raw_off_calls == 1, "cancel with raw on: status 130, host restores cooked");

    ashell_p3_delete(runner);
    return failures ? 1 : 0;
}
