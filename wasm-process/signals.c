#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#ifndef _WASI_EMULATED_SIGNAL
#define _WASI_EMULATED_SIGNAL 1
#endif

#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define ASHELL_NSEC UINT64_C(1000000000)
#define ASHELL_SIGNAL_BIT(number) (UINT64_C(1) << ((number) - 1))
#define ASHELL_UNBLOCKABLE (ASHELL_SIGNAL_BIT(SIGKILL) | ASHELL_SIGNAL_BIT(SIGSTOP))

// All of this state is local to one WASI instance. No host signals are installed.
static struct sigaction actions[_NSIG];
static sigset_t mask;
static sigset_t pending;
static uint64_t deadline;

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
    if (set && collect_alarm() == 0) while (dispatch()) {}
    return 0;
}

int sigpending(sigset_t *set) {
    if (collect_alarm() < 0) return -1;
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
        if (collect_alarm() < 0) { error = errno; break; }
        if (dispatch()) { error = EINTR; break; }
        if (!deadline || (mask & ASHELL_SIGNAL_BIT(SIGALRM))) { error = ENOTSUP; break; }
        uint64_t current;
        if (now(&current) < 0) { error = errno; break; }
        if (current >= deadline) continue;
        uint64_t remaining = deadline - current;
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
