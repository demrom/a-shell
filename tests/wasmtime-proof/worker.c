#include "include/ashell-p3.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>

/* ios_system owns these invoking-thread streams and terminal mode. */
extern __thread FILE *thread_stdin;
extern __thread FILE *thread_stdout;
extern __thread FILE *thread_stderr;
extern int ios_storeInteractive(void);
extern void ios_startInteractive(void);
extern void ios_stopInteractive(void);
extern int ios_getWindowSize(int *width, int *height, const void *sessionId);
extern const void *ios_getContext(void);
extern int ashell_p3_contract(int, const char *const *, FILE *, FILE *);

/* Keys for the guest's stdin. The one watcher below owns the terminal descriptor,
 * so it forwards every byte but Ctrl-C through this pipe. The struct is leaked on
 * purpose: a read abandoned at cancellation may start after the command ended and
 * must find `ended` set, never a freed context. Only the descriptors are closed. */
struct Keys {
    pthread_mutex_t lock;
    int fds[2], ended, reading;
};
static void keys_close(struct Keys *keys) {
    close(keys->fds[0]);
    keys->fds[0] = -1;
}
static int32_t tty_size(uintptr_t context, uint32_t *columns, uint32_t *rows) {
    (void)context;
    int width = 0, height = 0;
    if (ios_getWindowSize(&width, &height, ios_getContext()) != 0 || width <= 0 || height <= 0) return -59;
    *columns = (uint32_t)width;
    *rows = (uint32_t)height;
    return 0;
}
/* Interactive mode already carries the whole command: the watcher needs it to see
 * Ctrl-C. Raw therefore selects nothing further here, and the command's exit
 * restores the entry mode, which also covers a guest that left raw on. */
static int32_t tty_raw(uintptr_t context, int32_t enabled) {
    (void)context;
    if (enabled) ios_startInteractive();
    return 0;
}
static intptr_t tty_read(uintptr_t context, uint8_t *bytes, size_t length) {
    struct Keys *keys = (struct Keys *)context;
    pthread_mutex_lock(&keys->lock);
    if (keys->ended) { pthread_mutex_unlock(&keys->lock); return 0; }
    keys->reading++;
    int fd = keys->fds[0];
    pthread_mutex_unlock(&keys->lock);
    ssize_t count;
    do count = read(fd, bytes, length); while (count < 0 && errno == EINTR);
    pthread_mutex_lock(&keys->lock);
    int last = --keys->reading == 0 && keys->ended;
    pthread_mutex_unlock(&keys->lock);
    if (last) keys_close(keys);
    return count < 0 ? -1 : count;
}

struct Input { int fd, stop, forward; };
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
            if (input->forward >= 0 && write(input->forward, &byte, 1) < 0 && errno != EAGAIN && errno != EINTR) input->forward = -1;
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
    struct Keys *keys = calloc(1, sizeof *keys);
    if (!keys || pipe(keys->fds) || fcntl(keys->fds[1], F_SETFL, O_NONBLOCK)) {
        close(stop[0]); close(stop[1]);
        if (!previous_mode) ios_stopInteractive();
        pthread_setcancelstate(previous_cancel, NULL);
        return 1;
    }
    pthread_mutex_init(&keys->lock, NULL);
    AshellP3Tty tty = { (uintptr_t)keys, tty_size, tty_raw, tty_read };
    struct Input input = { fileno(thread_stdin), stop[0], keys->fds[1] };
    pthread_t watcher;
    if (pthread_create(&watcher, NULL, watch_input, &input)) {
        close(stop[0]); close(stop[1]);
        if (!previous_mode) ios_stopInteractive();
        pthread_setcancelstate(previous_cancel, NULL);
        return 1;
    }
    int status = ashell_p3_command_tty(argc, (const char *const *)argv, thread_stdout, thread_stderr, &tty);
    char done = 1;
    if (write(stop[1], &done, 1) != 1) status = 1;
    pthread_join(watcher, NULL);
    close(keys->fds[1]);
    pthread_mutex_lock(&keys->lock);
    keys->ended = 1;
    int idle = keys->reading == 0;
    pthread_mutex_unlock(&keys->lock);
    if (idle) keys_close(keys);
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
