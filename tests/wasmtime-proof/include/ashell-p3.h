#ifndef ASHELL_P3_H
#define ASHELL_P3_H
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef struct Runner AshellP3Runner;
typedef struct {
    uintptr_t context;
    intptr_t (*write)(uintptr_t context, int32_t stream, const uint8_t *bytes, size_t length);
} AshellP3Output;

/* One runner per worker. run/delete are exclusive; cancel may run concurrently.
 * Caller keeps runner, argv and output context alive until run/cancel return.
 * Callback writes must be thread-safe. stdin is EOF for this bounded proof.
 * run returns 0, 1 on failure, or 130 after cancellation. */
AshellP3Runner *ashell_p3_new(void);
int32_t ashell_p3_run(const AshellP3Runner *, const char *path, size_t argc,
    const char *const *argv, AshellP3Output output);
/* Unsafe trust boundary: exact-version/configuration artifact from a trusted
 * build only. Never use this entry for downloaded/untrusted bytecode. */
int32_t ashell_p3_run_trusted(const AshellP3Runner *, const char *path, size_t argc,
    const char *const *argv, AshellP3Output output);
void ashell_p3_cancel(const AshellP3Runner *);
void ashell_p3_delete(AshellP3Runner *);

/* Portable command entry; a-Shell passes thread_stdout/thread_stderr here.
 * The worker's interrupt route calls interrupt on its normal control thread,
 * never from a POSIX signal handler. One active command per process. */
int ashell_p3_command(int argc, const char *const *argv, FILE *out, FILE *err);
void ashell_p3_interrupt(void);
#endif
