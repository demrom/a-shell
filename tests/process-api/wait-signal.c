#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static volatile sig_atomic_t child_event;
static volatile sig_atomic_t alarm_event;

static void handle(int number) {
    child_event += number == SIGCHLD;
    alarm_event += number == SIGALRM;
}

int main(void) {
    struct sigaction action = {.sa_handler = handle, .sa_flags = SA_RESTART};
    sigset_t blocked, original, during;
    if (sigemptyset(&action.sa_mask) || sigaction(SIGCHLD, &action, NULL) || sigaction(SIGALRM, &action, NULL)) return 90;
    if (sigemptyset(&blocked) || sigaddset(&blocked, SIGCHLD) || sigaddset(&blocked, SIGALRM)
        || sigprocmask(SIG_BLOCK, &blocked, &original)) return 91;

    char *argv[] = {"sleep", "10", NULL};
    pid_t child;
    if (posix_spawnp(&child, argv[0], NULL, NULL, argv, environ)) return 92;
    int status = -123;
    if (waitpid(child, &status, WNOHANG) || status != -123) return 93;
    if (alarm(1) || sigsuspend(&original) != -1 || errno != EINTR || alarm_event != 1 || child_event) return 94;
    if (kill(child, SIGTERM)) return 95;
    // Do not call wait again yet. The worker may already complete before we
    // suspend, and the notification must leave its status and PID reserved.
    if (alarm(3) || sigsuspend(&original) != -1 || errno != EINTR || alarm_event != 1 || child_event != 1) return 96;
    alarm(0);
    if (kill(child, 0)) return 97;
    if (sigprocmask(SIG_SETMASK, NULL, &during) || sigismember(&during, SIGCHLD) != 1 || sigismember(&during, SIGALRM) != 1) return 98;
    if (waitpid(child, &status, WNOHANG) != child || !WIFSIGNALED(status) || WTERMSIG(status) != SIGTERM) return 99;
    if (kill(child, 0) != -1 || errno != ESRCH || sigprocmask(SIG_SETMASK, &original, NULL) || child_event != 1) return 100;
    return puts("process-wait-signal-ok") < 0;
}
