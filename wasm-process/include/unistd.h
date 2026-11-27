#ifndef ASHELL_UNISTD_H
#define ASHELL_UNISTD_H

#include_next <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

int execve(const char *, char *const [], char *const []);
int execv(const char *, char *const []);
int execvp(const char *, char *const []);
unsigned alarm(unsigned);

#ifdef __cplusplus
}
#endif

#endif
