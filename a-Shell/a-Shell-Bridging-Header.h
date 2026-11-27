//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import "KBWebViewBase.h"
#include <errno.h>
#include <sys/types.h>

#if __has_include(<ios_system/ios_spawn.h>)
#include <ios_system/ios_spawn.h>
#endif

// Older ios_system builds do not have the worker-only POSIX adapter.
static inline int ashellSpawnWorkerWithDirectory(pid_t *pid, const char *path, const char *directory,
                                                  char *const argv[], char *const envp[]) {
#if defined(IOS_SPAWN_H)
    ios_posix_spawn_file_actions_t actions;
    int error = ios_posix_spawn_file_actions_init(&actions);
    if (error) return error;
    error = ios_posix_spawn_file_actions_addchdir_np(&actions, directory);
    if (!error) error = ios_posix_spawn(pid, path, &actions, NULL, argv, envp);
    ios_posix_spawn_file_actions_destroy(&actions);
    return error;
#else
    return ENOTSUP;
#endif
}

static inline pid_t ashellWaitWorker(pid_t pid, int *status, int options) {
#if defined(IOS_SPAWN_H)
    return ios_wait4(pid, status, options, NULL, NULL);
#else
    errno = ENOTSUP;
    return -1;
#endif
}

static inline int ashellKillWorker(pid_t pid, int signal) {
#if defined(IOS_WORKER_KILL_SUPPORTED)
    return ios_kill_worker(pid, signal);
#else
    return ENOTSUP;
#endif
}

// Existing ios_system status setter; pthread cancellation skips a command return.
void set_session_errno(int status);
#import "../native-deps/herdr-parallel-port/PaneWire.h"

#import "../ml/AShellML.h"
#import "../ml/AShellMLInstall.h"
