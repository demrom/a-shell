#ifndef HERDR_PANE_H
#define HERDR_PANE_H
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// command/cwd must be nonempty UTF-8; cwd must be an absolute accessible directory.
// envp is NULL or a NULL-terminated list of UTF-8 key=value overrides, copied before return.
// Dimensions are 1..9999. Returns 0 or positive errno; failure sets outputs to -1/NULL.
// Success transfers the full-duplex fd to the caller; stderr shares stdout.
// HERDR_IOS_PTY=1 requests a real Darwin PTY. EPERM logs and selects the existing
// socket transport with HERDR_IOS_PTY=0 for Dash; other PTY failures are returned.
// Other commands use a socket, blocking/CLOEXEC/SO_NOSIGPIPE. PTY fds are blocking/CLOEXEC.
// The caller may set O_NONBLOCK. PTY process-group signals remain disabled.
// Only ONE native pane or WASM capture may be active: a second spawn returns EBUSY.
// Stock ios_system changes process cwd and uses global fake PID selection. Exclude
// unrelated app commands until completion; this ABI does not provide parallel isolation.
int herdr_pane_spawn(const char *command, const char *cwd, unsigned cols,
                     unsigned rows, const char *const *envp, int *fd_out, void **job_out);

// Returns 0 running, 1 exited (writes final command status), or -errno.
// Repeated polling after exit preserves status. Drain the returned fd to EOF independently.
// A cleanup/restore error returns -errno after completion instead of hiding the failure.
int herdr_pane_poll(void *job, int *status_out);

// Snapshot the running command and real process PID; EAGAIN while starting.
int herdr_pane_state(void *job, char *command, size_t capacity, int *pid_out);

// These operations return 0 or POSITIVE errno, unlike poll.
// Resize updates kernel PTY geometry when requested and stock ios_setWindowSize.
int herdr_pane_resize(void *job, unsigned cols, unsigned rows);
// Socket mode half-closes stdin; PTY mode sends two initial VEOF keys (retained across libedit raw mode).
// Idempotent; keeps output open. PTY EOF is a request, not raw-stream half-close.
int herdr_pane_close_stdin(void *job);
// No proven app-safe command cancellation exists: returns ENOTSUP while running.
int herdr_pane_cancel(void *job);
// Interrupt a cooked foreground command; ENOTSUP means forward ETX to the TUI/editor.
int herdr_pane_interrupt(void *job);

// Sends EOF and drops the caller reference; NEVER frees a live runner or its FILEs.
// Caller must invalidate its pointer and release exactly once. No concurrent release
// with another call: keep the handle in one Arc/mutex-owned Rust lifetime.
// Close the returned fd separately. A command ignoring EOF may retain state indefinitely.
// The handle is opaque and is NOT an OS pid: never pass it to kill/waitpid/process APIs.
void herdr_pane_release(void *job);

#ifdef __cplusplus
}
#endif
#endif
