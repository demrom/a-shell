#ifndef ASHELL_PROCESS_H
#define ASHELL_PROCESS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__wasm32__)
#define ASHELL_PROCESS_IMPORT(name) \
    __attribute__((import_module("ashell_v1"), import_name(name)))
#else
#define ASHELL_PROCESS_IMPORT(name)
#endif

enum {
    ASHELL_SPAWN_SEARCH_PATH = 1,
    ASHELL_SPAWN_INHERIT_ENV = 2,
    ASHELL_WAIT_NOHANG = 1,
    ASHELL_PROCESS_MAX_VECTOR = 4096,
};

typedef struct {
    uint32_t offset;
    uint32_t length;
} ashell_process_slice;

typedef struct {
    int32_t op;
    int32_t source;
    int32_t target;
} ashell_process_action;

enum {
    ASHELL_PROCESS_DUP2 = 1,
    ASHELL_PROCESS_CLOSE = 2,
};

/* Strings are UTF-8 byte slices, not C strings. A request never borrows guest
 * memory after returning. Failures are negative Preview 1 errno values.
 * Output pointers must be writable wasm32 addresses, not NULL C pointers.
 * The command-line broker currently requires argv[0] to equal path and a slash
 * in path if SEARCH_PATH is clear. Nonempty actions require FD-capable hosts.
 * The child starts in the host command's initial directory; guest chdir is not
 * propagated to this version of the import. Unreaped children are cancelled
 * and reaped by the host when their guest invocation ends. WebView keyboard
 * input is delivered to the guest and is not forwarded to a child tty. */
ASHELL_PROCESS_IMPORT("process_spawn")
int32_t ashell_process_spawn(
    const char *path, uint32_t path_length,
    const ashell_process_slice *argv, uint32_t argc,
    const ashell_process_slice *env, uint32_t envc,
    const ashell_process_action *actions, uint32_t action_count,
    uint32_t flags, int32_t *child);

/* Return the reaped child, or 0 with NOHANG if it is still running.
 * On a positive return, status contains the POSIX wait status. */
ASHELL_PROCESS_IMPORT("process_wait")
int32_t ashell_process_wait(int32_t child, uint32_t flags, int32_t *status);

/* Allocate read/write descriptors in the same table as the Preview 1 imports.
 * On error, leave that table and the output pair unchanged. */
ASHELL_PROCESS_IMPORT("process_pipe")
int32_t ashell_process_pipe(int32_t pair[2]);

/* Replace target with an alias of source without consuming source. */
ASHELL_PROCESS_IMPORT("process_dup2")
int32_t ashell_process_dup2(int32_t source, int32_t target);

#undef ASHELL_PROCESS_IMPORT

#ifdef __cplusplus
}
#endif

#endif
