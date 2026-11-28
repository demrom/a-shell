#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#ifndef _WASI_EMULATED_SIGNAL
#define _WASI_EMULATED_SIGNAL 1
#endif

#include <ashell/process.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include "process-signals.h"

#define ASHELL_NSEC UINT64_C(1000000000)
#define ASHELL_SIGNAL_BIT(number) (UINT64_C(1) << ((number) - 1))
#define ASHELL_UNBLOCKABLE (ASHELL_SIGNAL_BIT(SIGKILL) | ASHELL_SIGNAL_BIT(SIGSTOP))

// All of this state is local to one WASI instance. No host signals are installed.
static struct sigaction actions[_NSIG];
static sigset_t mask;
static sigset_t pending;
static uint64_t deadline;
static int32_t watched_child;
static ashell_wait_function peek_child;

static int failure(int error) {
    errno = error;
    return -1;
}

static int valid_signal(int number) {
    return number > 0 && number < _NSIG;
}

int sigemptyset(sigset_t *set) { *set = 0; return 0; }
int sigfillset(sigset_t *set) { *set = UINT64_MAX; return 0; }

int sigaddset(sigset_t *set, int number) {
    if (!valid_signal(number)) return failure(EINVAL);
    *set |= ASHELL_SIGNAL_BIT(number);
    return 0;
}

int sigdelset(sigset_t *set, int number) {
    if (!valid_signal(number)) return failure(EINVAL);
    *set &= ~ASHELL_SIGNAL_BIT(number);
    return 0;
}

int sigismember(const sigset_t *set, int number) {
    if (!valid_signal(number)) return failure(EINVAL);
    return (*set & ASHELL_SIGNAL_BIT(number)) != 0;
}

static int now(uint64_t *nanoseconds) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) < 0) return -1;
    *nanoseconds = (uint64_t)value.tv_sec * ASHELL_NSEC + (uint64_t)value.tv_nsec;
    return 0;
}

static int collect_alarm(void) {
    if (deadline == 0) return 0;
    uint64_t current;
    if (now(&current) < 0) return -1;
    if (current >= deadline) {
        deadline = 0;
        pending |= ASHELL_SIGNAL_BIT(SIGALRM);
    }
    return 0;
}

void ashell_signal_watch_child(int32_t requested, int32_t result, ashell_wait_function wait_function) {
    // A WNOHANG miss arms the usual waitpid/sigsuspend loop. Rearm only
    // after another miss, so an unreaped child cannot wake repeatedly.
    if (result == 0) {
        watched_child = requested;
        peek_child = wait_function;
    } else if (requested == watched_child || result == watched_child) {
        watched_child = 0;
    }
}

static int collect_child(void) {
    if (watched_child) {
        int32_t result = peek_child(watched_child, ASHELL_WAIT_PEEK, NULL);
        if (result > 0) pending |= ASHELL_SIGNAL_BIT(SIGCHLD);
        if (result != 0) watched_child = 0;
        if (result < 0 && result != -ECHILD && result != -EINVAL && result != -ENOTSUP) return failure(-result);
    }
    return 0;
}

static int collect_signals(void) {
    int alarm_error = collect_alarm() < 0 ? errno : 0;
    if (collect_child() < 0) return -1;
    return alarm_error ? failure(alarm_error) : 0;
}

static int default_ignored(int number) {
    return number == SIGCHLD || number == SIGURG || number == SIGWINCH || number == SIGCONT;
}

static int dispatch(void) {
    while (pending & ~mask) {
        int number = __builtin_ctzll(pending & ~mask) + 1;
        sigset_t bit = ASHELL_SIGNAL_BIT(number);
        pending &= ~bit;
        struct sigaction action = actions[number];
        if (action.sa_handler == SIG_IGN) continue;
        if (action.sa_handler == SIG_DFL) {
            if (default_ignored(number)) continue;
            _Exit(128 + number);
        }
        sigset_t previous = mask;
        mask |= (action.sa_mask | bit) & ~ASHELL_UNBLOCKABLE;
        action.sa_handler(number);
        mask = previous;
        return 1;
    }
    return 0;
}

int sigaction(int number, const struct sigaction *action, struct sigaction *old) {
    if (!valid_signal(number) || (action && (number == SIGKILL || number == SIGSTOP))) return failure(EINVAL);
    struct sigaction previous = actions[number];
    if (action) {
        if (action->sa_handler == SIG_ERR) return failure(EINVAL);
        if (action->sa_flags & ~(SA_RESTART | SA_NOCLDSTOP)) return failure(ENOTSUP);
        actions[number] = *action;
        if (action->sa_handler == SIG_IGN || (action->sa_handler == SIG_DFL && default_ignored(number))) {
            pending &= ~ASHELL_SIGNAL_BIT(number);
        }
    }
    if (old) *old = previous;
    return 0;
}

int sigprocmask(int how, const sigset_t *set, sigset_t *old) {
    sigset_t previous = mask;
    if (set) {
        sigset_t value = *set & ~ASHELL_UNBLOCKABLE;
        switch (how) {
            case SIG_BLOCK: mask |= value; break;
            case SIG_UNBLOCK: mask &= ~value; break;
            case SIG_SETMASK: mask = value; break;
            default: return failure(EINVAL);
        }
    }
    if (old) *old = previous;
    if (set) {
        int saved_errno = errno;
        collect_signals();
        errno = saved_errno;
        while (dispatch()) {}
    }
    return 0;
}

int sigpending(sigset_t *set) {
    if (collect_signals() < 0) return -1;
    *set = pending & mask;
    return 0;
}

unsigned alarm(unsigned seconds) {
    uint64_t current;
    if (now(&current) < 0) return 0;
    if (deadline && current >= deadline) pending |= ASHELL_SIGNAL_BIT(SIGALRM);
    uint64_t remaining = deadline > current ? deadline - current : 0;
    uint64_t interval = (uint64_t)seconds * ASHELL_NSEC;
    deadline = seconds == 0 ? 0 : current + (interval <= UINT64_MAX - current ? interval : UINT64_MAX - current);
    return (unsigned)(remaining / ASHELL_NSEC + (remaining % ASHELL_NSEC != 0));
}

int sigsuspend(const sigset_t *temporary) {
    sigset_t previous = mask;
    mask = *temporary & ~ASHELL_UNBLOCKABLE;
    int error;
    for (;;) {
        // A pending signal already interrupts this suspend. Don't disarm an
        // independent child watch or lose its error by polling unnecessarily.
        int alarm_error = collect_alarm() < 0 ? errno : 0;
        if (dispatch()) { error = EINTR; break; }
        int child_error = collect_child() < 0 ? errno : 0;
        if (dispatch()) { error = EINTR; break; }
        if (child_error || alarm_error) { error = child_error ? child_error : alarm_error; break; }
        int alarm_can_wake = deadline && !(mask & ASHELL_SIGNAL_BIT(SIGALRM));
        int child_can_wake = watched_child && !(mask & ASHELL_SIGNAL_BIT(SIGCHLD));
        if (!alarm_can_wake && !child_can_wake) { error = ENOTSUP; break; }
        uint64_t remaining = 20000000;
        if (alarm_can_wake) {
            uint64_t current;
            if (now(&current) < 0) { error = errno; break; }
            if (current >= deadline) continue;
            if (!child_can_wake || deadline - current < remaining) remaining = deadline - current;
        }
        struct timespec interval = {(time_t)(remaining / ASHELL_NSEC), (long)(remaining % ASHELL_NSEC)};
        if (nanosleep(&interval, NULL) < 0 && errno != EINTR) { error = errno; break; }
    }
    mask = previous;
    return failure(error);
}

// wasi-libc puts these sentinels and its narrower signal/raise in one archive
// member. Supplying the four symbols keeps our dispositions in one table.
void __SIG_ERR(int number) { (void)number; }
void __SIG_IGN(int number) { (void)number; }

void (*signal(int number, void (*handler)(int)))(int) {
    struct sigaction action = {.sa_handler = handler, .sa_flags = SA_RESTART};
    struct sigaction old;
    return sigaction(number, &action, &old) == 0 ? old.sa_handler : SIG_ERR;
}

int raise(int number) {
    if (!valid_signal(number)) return failure(EINVAL);
    if (actions[number].sa_handler == SIG_DFL && (number == SIGSTOP || number == SIGTSTP || number == SIGTTIN || number == SIGTTOU)) {
        return failure(ENOTSUP); // There is no resumable stopped guest.
    }
    if (actions[number].sa_handler == SIG_IGN || (actions[number].sa_handler == SIG_DFL && default_ignored(number))) return 0;
    pending |= ASHELL_SIGNAL_BIT(number);
    while (dispatch()) {}
    return 0;
}
