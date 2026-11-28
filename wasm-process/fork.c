#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#ifndef _WASI_EMULATED_GETPID
#define _WASI_EMULATED_GETPID 1
#endif

#include <ashell/process.h>
#include <errno.h>
#include <unistd.h>

static int child_prelude;

// WASI does not have an OS process identity. These instance-local identities
// stay outside the broker PID space and let the sandboxed prelude identify
// its parent; they are not signalable and the prelude is not an admitted PID.
pid_t getpid(void) { return child_prelude ? INT32_MAX - 1 : INT32_MAX; }
pid_t getppid(void) { return child_prelude ? INT32_MAX : 0; }

int setpgid(pid_t process, pid_t group) {
    (void)process;
    (void)group;
    errno = ENOTSUP;
    return -1;
}

// WasmKit can copy an exported memory but does not expose host-side growth
// for a non-shared instance. Run this before copying the child's snapshot.
__attribute__((export_name("ashell_fork_grow")))
uint32_t ashell_fork_grow(uint32_t pages) {
    return (uint32_t)__builtin_wasm_memory_grow(0, pages);
}

uint32_t ashell_fork_exec_flags(void) {
    return child_prelude ? ASHELL_SPAWN_FORK_EXEC : 0;
}

pid_t fork(void) {
    // Binaryen Asyncify stores its cursor and limit ahead of the saved frames.
    static _Alignas(16) unsigned char capture[64 * 1024 + 8];
    if (child_prelude) {
        errno = ENOTSUP;
        return -1;
    }
    int32_t result = ashell_process_fork(capture, (uint32_t)sizeof(capture));
    if (result < 0) {
        errno = -result;
        return -1;
    }
    child_prelude = result == 0;
    return result;
}

pid_t vfork(void) {
    return fork(); // Same restricted pre-exec contract; never shares the C stack.
}
