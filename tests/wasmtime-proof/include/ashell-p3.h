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
 * Callback writes must be thread-safe. stdin is EOF unless a tty bridge is set.
 * run preserves the status exposed by WASI (Preview2 may reduce failure to 1),
 * returns 1 on host failure, or 130 after cancellation. */
AshellP3Runner *ashell_p3_new(void);
int32_t ashell_p3_run(const AshellP3Runner *, const char *path, size_t argc,
    const char *const *argv, AshellP3Output output);
/* Unsafe trust boundary: exact-version/configuration artifact from a trusted
 * build only. Never use this entry for downloaded/untrusted bytecode. */
int32_t ashell_p3_run_trusted(const AshellP3Runner *, const char *path, size_t argc,
    const char *const *argv, AshellP3Output output);
void ashell_p3_cancel(const AshellP3Runner *);

/* Terminal bridge behind the WIT interface ashell:tty@0.1.0 (wit/ashell-tty.wit),
 * same semantics as ashell_v1 tty_size/tty_raw. Errors are negative WASI errno.
 * size writes columns and rows. raw(1) selects direct keyboard input, raw(0)
 * the shell's line input; the host calls raw(0) when a guest that left raw mode
 * on returns, traps or is cancelled. read blocks until a byte exists and returns
 * it unbuffered (count, 0 at EOF, -1 on error); a read in flight at cancellation
 * is abandoned, so it must return once the terminal is released. All callbacks
 * are thread-safe and the context outlives every run that uses it. */
typedef struct {
    uintptr_t context;
    int32_t (*size)(uintptr_t context, uint32_t *columns, uint32_t *rows);
    int32_t (*raw)(uintptr_t context, int32_t enabled);
    intptr_t (*read)(uintptr_t context, uint8_t *bytes, size_t length);
} AshellP3Tty;
/* NULL withdraws the bridge. Without it a guest importing ashell:tty gets
 * error-code unsupported and stdin stays EOF. Set it between runs. */
void ashell_p3_set_tty(const AshellP3Runner *, const AshellP3Tty *);
void ashell_p3_delete(AshellP3Runner *);

/* Portable command entry; a-Shell passes thread_stdout/thread_stderr here.
 * The worker's interrupt route calls interrupt on its normal control thread,
 * never from a POSIX signal handler. One active command per process. */
int ashell_p3_command(int argc, const char *const *argv, FILE *out, FILE *err);
/* Same, with the terminal bridge for the duration of the command; NULL is the
 * plain command. */
int ashell_p3_command_tty(int argc, const char *const *argv, FILE *out, FILE *err, const AshellP3Tty *);
void ashell_p3_interrupt(void);
#endif
