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
        int status = ios_system("wasmkit hello.wasm");
        ios_closeSession(session);
        fprintf(stderr, "wasmkit hello.wasm: status=%d\n", status);
        return status != 0;
    }
}
