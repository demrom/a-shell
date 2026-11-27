#import <Foundation/Foundation.h>
#import <ios_system/ios_system.h>

int main(void) {
    @autoreleasepool {
        // ios_system uses the real bundle's commandDictionary.plist and dlopen.
        if (chdir(NSBundle.mainBundle.bundlePath.fileSystemRepresentation) != 0) {
            perror("chdir");
            return 1;
        }
        static char session[] = "wasmkit-smoke";
        ios_switchSession(session);
        ios_setStreams(stdin, stdout, stderr);
        thread_stdin = stdin;
        thread_stdout = stdout;
        thread_stderr = stderr;
        int helloStatus = ios_system("wasmkit hello.wasm");
        fprintf(stderr, "wasmkit hello.wasm: status=%d\n", helloStatus);
        int pipeStatus = ios_system("wasmkit pipe.wasm");
        fprintf(stderr, "wasmkit pipe.wasm: status=%d\n", pipeStatus);
        int killStatus = ios_system("wasmkit kill-unowned.wasm");
        fprintf(stderr, "wasmkit kill-unowned.wasm: status=%d\n", killStatus);
        int peekForkStatus = ios_system("wasmkit peek-fork.wasm");
        fprintf(stderr, "wasmkit peek-fork.wasm: status=%d\n", peekForkStatus);
        ios_closeSession(session);
        return helloStatus != 0 || pipeStatus != 0 || killStatus != 0 || peekForkStatus != 0;
    }
}
