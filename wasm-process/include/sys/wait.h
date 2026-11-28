#ifndef ASHELL_SYS_WAIT_H
#define ASHELL_SYS_WAIT_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WNOHANG 1
#define WEXITSTATUS(status) (((status) >> 8) & 0xff)
#define WTERMSIG(status) ((status) & 0x7f)
#define WIFEXITED(status) (WTERMSIG(status) == 0)
#define WIFSIGNALED(status) (WTERMSIG(status) != 0 && WTERMSIG(status) != 0x7f)

pid_t waitpid(pid_t, int *, int);
pid_t wait(int *);

#ifdef __cplusplus
}
#endif

#endif
