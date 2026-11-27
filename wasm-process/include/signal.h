#ifndef ASHELL_SIGNAL_H
#define ASHELL_SIGNAL_H

#include_next <signal.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

int kill(pid_t, int);

#if defined(_POSIX_SOURCE) || defined(_POSIX_C_SOURCE) || defined(_XOPEN_SOURCE) || defined(_GNU_SOURCE) || defined(_BSD_SOURCE)
// The SDK supplies the signal numbers, but not POSIX masks or dispositions.
#include <__typedef_sigset_t.h>
struct sigaction {
    void (*sa_handler)(int);
    sigset_t sa_mask;
    int sa_flags;
};

#define SIG_BLOCK 0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2
#define SA_NOCLDSTOP 1
#define SA_RESTART 2
#define SIGRTMIN 34
#define SIGRTMAX 64

int sigemptyset(sigset_t *);
int sigfillset(sigset_t *);
int sigaddset(sigset_t *, int);
int sigdelset(sigset_t *, int);
int sigismember(const sigset_t *, int);
int sigaction(int, const struct sigaction *, struct sigaction *);
int sigprocmask(int, const sigset_t *, sigset_t *);
int sigpending(sigset_t *);
int sigsuspend(const sigset_t *);
#endif

#ifdef __cplusplus
}
#endif

#endif
