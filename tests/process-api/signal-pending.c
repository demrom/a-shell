#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
static volatile sig_atomic_t delivered;

static void handle(int number) {
    if (number == SIGALRM) delivered++;
}

int main(void) {
    struct sigaction action = {.sa_handler = handle};
    sigset_t blocked, original;
    if (sigemptyset(&action.sa_mask) || sigaction(SIGALRM, &action, NULL)
        || sigemptyset(&blocked) || sigaddset(&blocked, SIGALRM)
        || sigprocmask(SIG_BLOCK, &blocked, &original)) return 90;
    char *args[] = {"sleep", "10", NULL};
    pid_t child;
    if (posix_spawnp(&child, args[0], NULL, NULL, args, environ)) return 91;
    if (waitpid(child, NULL, WNOHANG) || alarm(1)) return 92;
    struct timespec interval = {.tv_sec = 1, .tv_nsec = 50000000};
    if (nanosleep(&interval, NULL)) return 93;
    // Deliver the ready alarm without consuming the child's readiness watch.
    if (sigsuspend(&original) != -1 || errno != EINTR || delivered != 1) return 94;
    // With no deliverable signal, the same armed watch can report its real error.
    if (sigsuspend(&original) != -1 || errno != EIO || delivered != 1) return 98;
    if (waitpid(child, NULL, WNOHANG) || raise(SIGALRM) || delivered != 1) return 95;
    errno = ERANGE;
    // The independent queued signal must be delivered and a successful mask update
    // must not expose an error from the readiness probe.
    if (sigprocmask(SIG_UNBLOCK, &blocked, NULL) || errno != ERANGE || delivered != 2) return 96;
    if (kill(child, SIGTERM) || waitpid(child, NULL, 0) != child) return 97;
    return puts("process-signal-pending-ok") < 0;
}
