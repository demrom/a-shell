#import <Foundation/Foundation.h>
#import <ios_system/ios_system.h>

#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

static NSString *readOutput(FILE *stream)
{
    if (fflush(stream) || fseek(stream, 0, SEEK_SET)) return nil;
    NSMutableData *data = [NSMutableData data];
    char bytes[4096];
    size_t count;
    while ((count = fread(bytes, 1, sizeof(bytes), stream))) {
        [data appendBytes:bytes length:count];
    }
    if (ferror(stream)) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static BOOL matches(NSString *text, NSString *pattern)
{
    return text && [text rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

static BOOL runCBC(NSString *label, NSString *command, NSString *stdinPath, int expectedStatus,
                   NSString **log, NSString **diagnostics)
{
    FILE *input = stdinPath ? fopen(stdinPath.fileSystemRepresentation, "r") : tmpfile();
    FILE *output = tmpfile();
    FILE *error = tmpfile();
    if (!input || !output || !error) {
        if (input) fclose(input);
        if (output) fclose(output);
        if (error) fclose(error);
        return NO;
    }
    int inputFD = fileno(input);
    ios_setStreams(input, output, error);
    thread_stdin = input;
    thread_stdout = output;
    thread_stderr = error;
    int status = ios_system(command.UTF8String);
    ios_setStreams(stdin, stdout, stderr);
    thread_stdin = stdin;
    thread_stdout = stdout;
    thread_stderr = stderr;
    BOOL inputStillOpen = fcntl(inputFD, F_GETFD) != -1;
    *log = readOutput(output);
    *diagnostics = readOutput(error);
    if (inputStillOpen) fclose(input);
    fclose(output);
    fclose(error);
    int written = dprintf(STDOUT_FILENO, "CBC_SMOKE %s status=%d input_open=%d\n%s%s", label.UTF8String, status,
                          inputStillOpen, (*log).UTF8String ?: "", (*diagnostics).UTF8String ?: "");
    return written > 0 && status == expectedStatus && inputStillOpen && *log && *diagnostics;
}

static BOOL solve(NSString *inputPath, NSString *solutionPath, BOOL pipeInput)
{
    NSString *source = pipeInput ? @"stdin_lp" : [NSString stringWithFormat:@"\"%@\"", inputPath];
    NSString *command = [NSString stringWithFormat:@"cbc -import %@ -solve -solution \"%@\"", source, solutionPath];
    NSString *log, *diagnostics;
    if (!runCBC(pipeInput ? @"stdin" : @"file", command, pipeInput ? inputPath : nil, 0, &log, &diagnostics)) return NO;
    NSString *solution = [NSString stringWithContentsOfFile:solutionPath encoding:NSUTF8StringEncoding error:NULL];
    if (!solution || dprintf(STDOUT_FILENO, "%s", solution.UTF8String) < 0) return NO;
    return diagnostics.length == 0 &&
        matches(log, @"Optimal objective 10(?:\\s|$)") &&
        matches(solution, @"(?m)^Optimal - objective value 10\\.0+$") &&
        matches(solution, @"(?m)^\\s*\\d+\\s+x\\s+2\\s+") &&
        matches(solution, @"(?m)^\\s*\\d+\\s+y\\s+2\\s+");
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 3) return 2;
        alarm(60);
        static char session[] = "cbc-runtime";
        joinMainThread = true;
        ios_switchSession(session);
        if (!ios_executable("cbc")) return 3;
        NSString *input = @(argv[1]);
        NSString *directory = @(argv[2]);
        if (chdir(directory.fileSystemRepresentation)) return 4;
        struct sigaction before, after;
        if (sigaction(SIGINT, NULL, &before)) return 4;
        NSString *log, *diagnostics;
        // CBC 2.10.12 aborts on this MPS marker. The port must exit only the command thread.
        if (!runCBC(@"unsupported_sos", @"cbc -import unsupported-sos.mps", nil, 1, &log, &diagnostics) ||
            !matches(diagnostics, @"(?m)^cbc: solver aborted$")) return 5;
        if (!solve(input, [directory stringByAppendingPathComponent:@"file.sol"], NO) ||
            !solve(input, [directory stringByAppendingPathComponent:@"stdin.sol"], YES)) return 6;
        if (sigaction(SIGINT, NULL, &after) || before.sa_handler != after.sa_handler || before.sa_flags != after.sa_flags) return 7;
        for (int signal = 1; signal < NSIG; ++signal) {
            if (sigismember(&before.sa_mask, signal) != sigismember(&after.sa_mask, signal)) return 7;
        }
        ios_closeSession(session);
        puts("CBC_SMOKE_PASSED");
        return 0;
    }
}
