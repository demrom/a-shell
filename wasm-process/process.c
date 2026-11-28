#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "process-signals.h"

_Static_assert(sizeof(uintptr_t) == 4, "The process ABI requires wasm32");
_Static_assert(sizeof(ashell_process_slice) == 8, "Invalid process slice layout");
_Static_assert(sizeof(ashell_process_action) == 12, "Invalid process action layout");

static int pack_vector(char *const vector[], ashell_process_slice **slices, uint32_t *length) {
    *slices = NULL;
    *length = 0;
    if (!vector) return 0;
    uint32_t count = 0;
    while (vector[count]) {
        if (count == ASHELL_PROCESS_MAX_VECTOR) return E2BIG;
        count++;
    }
    if (count == 0) return 0;
    ashell_process_slice *packed = malloc(count * sizeof(*packed));
    if (!packed) return ENOMEM;
    for (uint32_t i = 0; i < count; i++) {
        packed[i] = (ashell_process_slice){(uintptr_t)vector[i], strlen(vector[i])};
    }
    *slices = packed;
    *length = count;
    return 0;
}

static int spawn_child(pid_t *child, const char *path, const posix_spawn_file_actions_t *actions,
                       const posix_spawnattr_t *attributes, char *const argv[],
                       char *const envp[], uint32_t flags) {
    if (!path || !argv || !argv[0]) return EINVAL;
    // USEVFORK is a hint. Broker admission never duplicates the guest.
    if (attributes && (attributes->flags & ~POSIX_SPAWN_USEVFORK)) return ENOTSUP;
    ashell_process_slice *args = NULL, *env = NULL;
    uint32_t argc, envc;
    int error = pack_vector(argv, &args, &argc);
    if (!error) error = pack_vector(envp, &env, &envc);
    if (!error) {
        int32_t pid;
        error = -ashell_process_spawn(path, strlen(path), args, argc, env, envc,
                                      actions ? actions->actions : NULL, actions ? actions->count : 0,
                                      flags, &pid);
        if (!error && child) *child = pid;
    }
    free(env);
    free(args);
    return error;
}

int posix_spawn(pid_t *child, const char *path, const posix_spawn_file_actions_t *actions,
                const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    return spawn_child(child, path, actions, attributes, argv, envp, 0);
}

int posix_spawnp(pid_t *child, const char *file, const posix_spawn_file_actions_t *actions,
                 const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]) {
    return spawn_child(child, file, actions, attributes, argv, envp, ASHELL_SPAWN_SEARCH_PATH);
}

int posix_spawnattr_init(posix_spawnattr_t *attributes) {
    attributes->flags = 0;
    return 0;
}

int posix_spawnattr_destroy(posix_spawnattr_t *attributes) {
    attributes->flags = 0;
    return 0;
}

int posix_spawnattr_getflags(const posix_spawnattr_t *attributes, short *flags) {
    *flags = attributes->flags;
    return 0;
}

int posix_spawnattr_setflags(posix_spawnattr_t *attributes, short flags) {
    if (flags & ~POSIX_SPAWN_USEVFORK) return EINVAL;
    attributes->flags = flags;
    return 0;
}

int posix_spawn_file_actions_init(posix_spawn_file_actions_t *actions) {
    *actions = (posix_spawn_file_actions_t){0};
    return 0;
}

int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *actions) {
    free(actions->actions);
    *actions = (posix_spawn_file_actions_t){0};
    return 0;
}

static int push_action(posix_spawn_file_actions_t *actions, ashell_process_action action) {
    if (action.source < 0 || action.target < 0) return EBADF;
    if (actions->count == ASHELL_PROCESS_MAX_VECTOR) return E2BIG;
    size_t next_count = actions->count + 1;
    ashell_process_action *next = realloc(actions->actions, next_count * sizeof(*next));
    if (!next) return ENOMEM;
    next[actions->count] = action;
    actions->actions = next;
    actions->count = next_count;
    return 0;
}

int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *actions, int source, int target) {
    return push_action(actions, (ashell_process_action){ASHELL_PROCESS_DUP2, source, target});
}

int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *actions, int fd) {
    return push_action(actions, (ashell_process_action){ASHELL_PROCESS_CLOSE, fd, 0});
}

pid_t waitpid(pid_t child, int *status, int options) {
    if (options & ~WNOHANG) {
        errno = EINVAL;
        return -1;
    }
    int32_t encoded;
    int32_t result = ashell_process_wait(child, options & WNOHANG ? ASHELL_WAIT_NOHANG : 0, &encoded);
    if (ashell_signal_watch_child) ashell_signal_watch_child(child, result, ashell_process_wait);
    if (result < 0) {
        errno = -result;
        return -1;
    }
    if (result > 0 && status) *status = encoded;
    return result;
}

pid_t wait(int *status) {
    return waitpid(-1, status, 0);
}

int kill(pid_t child, int signal) {
    int32_t result = ashell_process_kill(child, signal);
    if (result < 0) {
        errno = -result;
        return -1;
    }
    return 0;
}

extern char **environ;

static int wait_for_child(pid_t child) {
    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return status;
}

int system(const char *command) {
    // a-Shell ships Dash. Interpret a shell command only at this libc boundary.
    if (!command) return 1;
    char *argv[] = {"dash", "-c", (char *)command, NULL};
    pid_t child;
    int error = posix_spawnp(&child, argv[0], NULL, NULL, argv, environ);
    if (error == ENOENT || error == ENOEXEC || error == EACCES) return 127 << 8;
    if (error != 0) {
        errno = error;
        return -1;
    }
    return wait_for_child(child);
}

__attribute__((weak)) uint32_t ashell_fork_exec_flags(void);

static int exec_worker(const char *path, char *const argv[], char *const envp[], uint32_t flags) {
    if (ashell_fork_exec_flags) flags |= ashell_fork_exec_flags();
    pid_t child;
    int error = spawn_child(&child, path, NULL, NULL, argv, envp, flags);
    if (error != 0) {
        errno = error;
        return -1;
    }
    // Admission succeeded: do not return to the replaced command or run its
    // exit handlers. This is a status proxy, not native PID replacement.
    int status = wait_for_child(child);
    if (status < 0) _Exit(125);
    if (WIFEXITED(status)) _Exit(WEXITSTATUS(status));
    if (WIFSIGNALED(status)) _Exit(128 + WTERMSIG(status));
    _Exit(125);
}

int execve(const char *path, char *const argv[], char *const envp[]) {
    return exec_worker(path, argv, envp, 0);
}

int execv(const char *path, char *const argv[]) {
    return execve(path, argv, environ);
}

int execvp(const char *path, char *const argv[]) {
    return exec_worker(path, argv, environ, ASHELL_SPAWN_SEARCH_PATH);
}

int pipe(int fds[2]) {
    int32_t pair[2];
    int32_t result = ashell_process_pipe(pair);
    if (result < 0) {
        errno = -result;
        return -1;
    }
    fds[0] = pair[0];
    fds[1] = pair[1];
    return 0;
}

int pipe2(int fds[2], int flags) {
    // WASI SDK 34 encodes O_CLOEXEC as zero; workers inherit explicit stdio only.
    if (flags & ~O_CLOEXEC) {
        errno = flags & ~((int)O_CLOEXEC | O_NONBLOCK) ? EINVAL : ENOTSUP;
        return -1;
    }
    return pipe(fds);
}

int dup2(int source, int target) {
    int32_t result = ashell_process_dup2(source, target);
    if (result < 0) {
        errno = -result;
        return -1;
    }
    return target;
}

struct popen_child {
    FILE *stream;
    pid_t pid;
    struct popen_child *next;
};

static struct popen_child *popen_children;

FILE *popen(const char *command, const char *mode) {
    if (!command || !mode || (strcmp(mode, "r") && strcmp(mode, "w"))) {
        errno = EINVAL;
        return NULL;
    }
    struct popen_child *child = malloc(sizeof(*child));
    if (!child) return NULL;
    int fds[2];
    if (pipe(fds) < 0) {
        free(child);
        return NULL;
    }
    int writing = mode[0] == 'w';
    int parent_fd = fds[writing];
    int child_fd = fds[!writing];
    int target = writing ? STDIN_FILENO : STDOUT_FILENO;
    FILE *stream = fdopen(parent_fd, mode);
    if (!stream) {
        int error = errno;
        close(parent_fd);
        close(child_fd);
        free(child);
        errno = error;
        return NULL;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    int error = posix_spawn_file_actions_addclose(&actions, parent_fd);
    if (!error && child_fd != target) error = posix_spawn_file_actions_adddup2(&actions, child_fd, target);
    if (!error && child_fd != target) error = posix_spawn_file_actions_addclose(&actions, child_fd);
    char *argv[] = {"dash", "-c", (char *)command, NULL};
    if (!error) error = posix_spawnp(&child->pid, argv[0], &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(child_fd);
    if (error) {
        fclose(stream);
        free(child);
        errno = error;
        return NULL;
    }
    child->stream = stream;
    child->next = popen_children;
    popen_children = child;
    return stream;
}

int pclose(FILE *stream) {
    struct popen_child **slot = &popen_children;
    while (*slot && (*slot)->stream != stream) slot = &(*slot)->next;
    if (!*slot) {
        errno = ECHILD;
        return -1;
    }
    struct popen_child *child = *slot;
    *slot = child->next;
    pid_t pid = child->pid;
    free(child);
    int error = fclose(stream) == EOF ? errno : 0;
    int status = wait_for_child(pid);
    if (error) {
        errno = error;
        return -1;
    }
    return status;
}
