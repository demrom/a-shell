#ifndef ASHELL_SIGNAL_H
#define ASHELL_SIGNAL_H

#include_next <signal.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

int kill(pid_t, int);

#ifdef __cplusplus
}
#endif

#endif
