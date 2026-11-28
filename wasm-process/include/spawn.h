#ifndef ASHELL_SPAWN_H
#define ASHELL_SPAWN_H

#include <sys/types.h>
#include <ashell/process.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    ashell_process_action *actions;
    size_t count;
} posix_spawn_file_actions_t;

typedef struct {
    short flags;
} posix_spawnattr_t;

// Declare the standard flag bits for portable consumers. The broker rejects
// attributes it cannot honor; USEVFORK is accepted only as an optional hint.
#define POSIX_SPAWN_RESETIDS      0x01
#define POSIX_SPAWN_SETPGROUP     0x02
#define POSIX_SPAWN_SETSIGDEF     0x04
#define POSIX_SPAWN_SETSIGMASK    0x08
#define POSIX_SPAWN_SETSCHEDPARAM 0x10
#define POSIX_SPAWN_SETSCHEDULER  0x20
#define POSIX_SPAWN_USEVFORK      0x40

int posix_spawn(pid_t *, const char *, const posix_spawn_file_actions_t *,
                const posix_spawnattr_t *, char *const [], char *const []);
int posix_spawnp(pid_t *, const char *, const posix_spawn_file_actions_t *,
                 const posix_spawnattr_t *, char *const [], char *const []);
int posix_spawn_file_actions_init(posix_spawn_file_actions_t *);
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *);
int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *, int, int);
int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *, int);
int posix_spawnattr_init(posix_spawnattr_t *);
int posix_spawnattr_destroy(posix_spawnattr_t *);
int posix_spawnattr_getflags(const posix_spawnattr_t *, short *);
int posix_spawnattr_setflags(posix_spawnattr_t *, short);

#ifdef __cplusplus
}
#endif

#endif
