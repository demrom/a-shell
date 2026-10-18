/* Exercise the public runner ABI: SIGINT during a real clone, then reuse it. */
#include "include/ashell-p3.h"
#include <pthread.h>
#include <signal.h>
#include <string.h>

struct Interrupt { AshellP3Runner *runner; sigset_t signals; };
static void *interrupt(void *context) {
    struct Interrupt *state = context;
    int received;
    if (sigwait(&state->signals, &received) == 0 && received == SIGINT)
        ashell_p3_cancel(state->runner);
    return NULL;
}
static intptr_t output(uintptr_t context, int32_t stream, const uint8_t *bytes, size_t length) {
    (void)context;
    return (intptr_t)fwrite(bytes, 1, length, stream == 1 ? stdout : stderr);
}
int main(int argc, const char *const *argv) {
    if (argc != 4) {
        fputs("usage: gix-cancel GIX.wasm CLONE-URL DESTINATION\n", stderr);
        return 2;
    }
    struct Interrupt state = {0};
    sigemptyset(&state.signals);
    sigaddset(&state.signals, SIGINT);
    if (pthread_sigmask(SIG_BLOCK, &state.signals, NULL)) return 1;
    state.runner = ashell_p3_new();
    if (!state.runner) return 1;
    pthread_t thread;
    if (pthread_create(&thread, NULL, interrupt, &state)) return 1;
    const char *clone[] = {argv[1], "--no-verbose", "--threads", "1", "clone", argv[2], argv[3]};
    AshellP3Output sink = {0, output};
    int cancelled = ashell_p3_run(state.runner, argv[1], 7, clone, sink);
    if (cancelled != 130) {
        fprintf(stderr, "clone cancellation returned %d, expected 130\n", cancelled);
        return 1;
    }
    pthread_join(thread, NULL);
    const char *version[] = {argv[1], "--version"};
    int recovered = ashell_p3_run(state.runner, argv[1], 2, version, sink);
    ashell_p3_delete(state.runner);
    if (recovered != 0) return 1;
    fputs("CANCEL_STATUS=130 SAME_RUNNER_RECOVERY=0\n", stdout);
    return 0;
}
