#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t handled;
static volatile sig_atomic_t handler_mask;

static void catch_alarm(int signal) {
    sigset_t mask;
    if (sigprocmask(SIG_SETMASK, NULL, &mask) == 0) {
        handler_mask = sigismember(&mask, SIGALRM) == 1 && sigismember(&mask, SIGTERM) == 1;
    }
    handled += signal == SIGALRM;
}

int main(void) {
    struct sigaction action = {.sa_handler = catch_alarm, .sa_flags = SA_RESTART};
    struct sigaction old_action;
    sigset_t blocked, previous, restored;
    struct timespec start, end;
    if (sigemptyset(&action.sa_mask) || sigaddset(&action.sa_mask, SIGTERM)
        || sigaction(SIGALRM, &action, &old_action) || old_action.sa_handler != SIG_DFL) return 90;
    if (sigemptyset(&blocked) || sigaddset(&blocked, SIGALRM)
        || sigprocmask(SIG_BLOCK, &blocked, &previous) || handled) return 91;
    if (clock_gettime(CLOCK_MONOTONIC, &start) || alarm(1)) return 92;
    if (sigsuspend(&previous) != -1 || errno != EINTR || handled != 1 || !handler_mask) return 93;
    if (clock_gettime(CLOCK_MONOTONIC, &end)) return 94;
    double seconds = (double)(end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
    if (seconds < 0.9 || seconds >= 3.0) return 95;
    if (sigprocmask(SIG_SETMASK, NULL, &restored) || sigismember(&restored, SIGALRM) != 1
        || sigismember(&restored, SIGTERM) || sigprocmask(SIG_SETMASK, &previous, NULL)) return 96;
    if (alarm(3) || alarm(0) != 3) return 97;
    return puts("process-signal-mask-ok") < 0;
}
