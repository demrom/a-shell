// Host dispatch policy test: real pane, ios_system, wasm3 and ashell.exec.
// Only unused UIKit and the external WasmKit command entry are substituted.
#import "ios_system.h"
#include "herdr_pane.h"
#include <assert.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>

@implementation UIPasteboard
+ (instancetype)generalPasteboard { return nil; }
@dynamic hasStrings, hasURLs, string, URL;
@end
void display_alert(NSString *title, NSString *message) { abort(); }

int wasmkit_dispatch_fixture(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "hello.wasm")) return 2;
    fputs("WASMKIT_DISPATCH_HELLO\n", thread_stdout);
    fflush(thread_stdout);
    // Keep the pane live until the test verifies its reservation, then deliver EOF.
    return fgetc(thread_stdin) == EOF ? 0 : 1;
}
static void timeout_handler(int signal) { _Exit(124); }
int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 3);
        signal(SIGALRM, timeout_handler);
        alarm(30);
        initializeEnvironment();
        joinMainThread = false;
        int fd = -1;
        void *job = NULL;
        const char *env[] = { "HERDR_IOS_PTY=0", NULL };
        assert(!herdr_pane_spawn("wasmkit hello.wasm", argv[1], 80, 24, env, &fd, &job));
        struct pollfd input = { .fd = fd, .events = POLLIN };
        assert(poll(&input, 1, 5000) > 0);
        char bytes[4096] = {0};
        ssize_t used = read(fd, bytes, sizeof(bytes) - 1);
        assert(used > 0);
        fwrite(bytes, 1, (size_t)used, stdout);
        if (!strcmp(bytes, "WASMKIT_DISPATCH_HELLO\n")) {
            int other_fd = -1;
            void *other = NULL;
            assert(herdr_pane_spawn("wasmkit hello.wasm", argv[1], 80, 24, env, &other_fd, &other) == EBUSY);
            assert(other_fd == -1 && !other);
        }
        assert(!herdr_pane_close_stdin(job));
        int status = -1, done = 0;
        for (int i = 0; i < 500 && !done; i++) {
            done = herdr_pane_poll(job, &status);
            if (!done) usleep(10000);
        }
        herdr_pane_release(job);
        close(fd);
        fprintf(stdout, "PANE_STATUS=%d\n", status);
        fflush(stdout);
        if (done != 1 || status || strcmp(bytes, "WASMKIT_DISPATCH_HELLO\n")) return 1;

        // The guest calls the real ashell.exec host import, which dispatches back
        // through this same ios_system and must refuse nested engine commands.
        FILE *out = tmpfile(), *err = tmpfile(), *in = tmpfile();
        assert(out && err && in);
        ios_switchSession("nested-dispatch-test");
        ios_setStreams(in, out, err);
        thread_stdin = in; thread_stdout = out; thread_stderr = err;
        char command[4096];
        assert(snprintf(command, sizeof(command), "wasm3 %s nested", argv[2]) < sizeof(command));
        pid_t pid = ios_fork();
        ios_system(command);
        ios_waitpid(pid);
        status = ios_getCommandStatus();
        ios_releaseThreadId(pid);
        rewind(out);
        memset(bytes, 0, sizeof(bytes));
        used = fread(bytes, 1, sizeof(bytes) - 1, out);
        fwrite(bytes, 1, (size_t)used, stdout);
        fflush(stdout);
        char diagnostic[4096];
        ssize_t error_bytes = pread(fileno(err), diagnostic, sizeof(diagnostic), 0);
        if (error_bytes > 0) write(STDERR_FILENO, diagnostic, (size_t)error_bytes);
        fprintf(stdout, "NESTED_GUEST_STATUS=%d\n", status);
        fflush(stdout);
        assert(status == 0);
        assert(strstr(bytes, "nested-wasm3 rc=0 out=\"\" err_nonempty=true status=126 flags=0"));
        assert(strstr(bytes, "nested-wasmkit rc=0 out=\"\" err_nonempty=true status=126 flags=0"));
        fclose(in); fclose(out); fclose(err);
        puts("PASS: top-level pane dispatch0, concurrent pane EBUSY, real ashell.exec nested engines126");
        return 0;
    }
}
