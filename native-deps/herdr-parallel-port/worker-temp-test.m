// Exercise the actual worker spawn boundary and registered native command on macOS.
#import "PaneWire.h"
#import "ios_system.h"
#include <assert.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>

@implementation UIPasteboard
+ (instancetype)generalPasteboard { return nil; }
@dynamic hasStrings, hasURLs, string, URL;
@end
void display_alert(NSString *title, NSString *message) { abort(); }

static NSString *expectedTemporaryDirectory;
int worker_temp_fixture(int argc, char **argv) {
    const char *process = getenv("TMPDIR");
    const char *command = ios_getenv("TMPDIR");
    if (!process || !command || strcmp(process, expectedTemporaryDirectory.UTF8String) || strcmp(command, process)) {
        fprintf(thread_stdout, "FAIL: inherited host TMPDIR reached the native command\n");
        return 1;
    }
    FILE *file = tmpfile();
    if (!file) { fprintf(thread_stdout, "FAIL: libc tmpfile errno=%d\n", errno); return 2; }
    assert(fputs("native-temporary-roundtrip", file) >= 0);
    rewind(file);
    char bytes[64] = {0};
    assert(fread(bytes, 1, sizeof(bytes) - 1, file) == 26);
    assert(strcmp(bytes, "native-temporary-roundtrip") == 0);
    assert(fclose(file) == 0);
    char temporary[PATH_MAX];
    size_t length = confstr(_CS_DARWIN_USER_TEMP_DIR, temporary, sizeof(temporary));
    if (!length || length > sizeof(temporary) || access(temporary, W_OK)) {
        fprintf(thread_stdout, "FAIL: Darwin user temporary directory is unavailable\n");
        return 3;
    }
    char template[PATH_MAX];
    assert(snprintf(template, sizeof(template), "%s/worker-temp.XXXXXX", temporary) < sizeof(template));
    int fd = mkstemp(template);
    if (fd < 0) { fprintf(thread_stdout, "FAIL: Darwin user temp create errno=%d\n", errno); return 4; }
    assert(unlink(template) == 0);
    assert(close(fd) == 0);
    fprintf(thread_stdout, "PASS: worker TMPDIR in libc and command environment, tmpfile roundtrip, Darwin user temp\n");
    return 0;
}
static void timeout_handler(int signal) { _Exit(124); }
int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        signal(SIGALRM, timeout_handler);
        alarm(15);
        expectedTemporaryDirectory = NSTemporaryDirectory();
        NSURL *documents = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        NSURL *probe = [documents URLByAppendingPathComponent:@".herdr-pane-access.temp-test" isDirectory:YES];
        NSError *error = nil;
        assert([[NSFileManager defaultManager] createDirectoryAtURL:probe withIntermediateDirectories:YES attributes:nil error:&error]);
        NSData *bookmark = [documents bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
        assert(bookmark);
        NSObject<HerdrPaneWire> *service = herdr_worker_service();
        NSString *inherited = [@"TMPDIR=" stringByAppendingString:[documents.path stringByAppendingPathComponent:@"missing-host-container/tmp"]];
        __block int code = -1;
        __block NSFileHandle *socket = nil;
        [service spawn:@"worker-temp-fixture" cwd:bookmark home:bookmark documents:bookmark probe:probe.path
                   env:@[inherited, @"HERDR_IOS_PTY=0"] cols:80 rows:24
                 reply:^(int result, NSFileHandle *handle, int pid) { code = result; socket = handle; }];
        if (code) { fprintf(stderr, "Worker spawn failed: %d\n", code); return 1; }
        assert(socket);
        NSMutableData *output = [NSMutableData data];
        __block int status = -1;
        for (int attempt = 0; attempt < 100; attempt++) {
            struct pollfd pending = {.fd = socket.fileDescriptor, .events = POLLIN};
            assert(poll(&pending, 1, 100) >= 0);
            if (pending.revents & POLLIN) {
                char bytes[4096];
                ssize_t count = read(socket.fileDescriptor, bytes, sizeof(bytes));
                if (count > 0) [output appendBytes:bytes length:(NSUInteger)count];
            }
            [service poll:^(int done, int result) { if (done) status = result; }];
            if (status >= 0) break;
        }
        [service releasePane];
        fwrite(output.bytes, 1, output.length, stdout);
        NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
        if (status || ![text containsString:@"PASS: worker TMPDIR"]) return 1;
        return 0;
    }
}
