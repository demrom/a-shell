#include "include/ashell-p3.h"
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <unistd.h>

/* ios_system owns these invoking-thread streams and terminal mode. */
extern __thread FILE *thread_stdin;
extern __thread FILE *thread_stdout;
extern __thread FILE *thread_stderr;
extern int ios_storeInteractive(void);
extern void ios_startInteractive(void);
extern void ios_stopInteractive(void);
extern int ashell_p3_contract(int, const char *const *, FILE *, FILE *);

struct Input { int fd, stop; };
static void *watch_input(void *context) {
    struct Input *input = context;
    struct pollfd fds[] = { { input->stop, POLLIN, 0 }, { input->fd, POLLIN, 0 } };
    for (;;) {
        int ready = poll(fds, 2, -1);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0 || fds[0].revents || (fds[1].revents & (POLLERR | POLLNVAL))) return NULL;
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            unsigned char byte;
            ssize_t count = read(input->fd, &byte, 1);
            if (count <= 0) return NULL;
            if (byte == 3) { ashell_p3_interrupt(); return NULL; }
        }
    }
}

int p3proof_ios_main(int argc, char **argv) {
    int stop[2];
    if (pipe(stop)) return 1;
    int previous_cancel;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous_cancel);
    int previous_mode = ios_storeInteractive();
    ios_startInteractive();
    struct Input input = { fileno(thread_stdin), stop[0] };
    pthread_t watcher;
    if (pthread_create(&watcher, NULL, watch_input, &input)) {
        close(stop[0]); close(stop[1]);
        if (!previous_mode) ios_stopInteractive();
        pthread_setcancelstate(previous_cancel, NULL);
        return 1;
    }
    int status = ashell_p3_command(argc, (const char *const *)argv, thread_stdout, thread_stderr);
    char done = 1;
    if (write(stop[1], &done, 1) != 1) status = 1;
    pthread_join(watcher, NULL);
    close(stop[0]); close(stop[1]);
    if (!previous_mode) ios_stopInteractive();
    pthread_setcancelstate(previous_cancel, NULL);
    return status;
}

int p3contract_ios_main(int argc, char **argv) {
    int previous_cancel;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous_cancel);
    int status = ashell_p3_contract(argc, (const char *const *)argv, thread_stdout, thread_stderr);
    pthread_setcancelstate(previous_cancel, NULL);
    return status;
}
