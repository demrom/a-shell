#import <Foundation/Foundation.h>
#import <ios_system/ios_system.h>
#include <dlfcn.h>
#include <unistd.h>

static bool reset_stream(FILE *stream)
{
    if (fflush(stream) || ftruncate(fileno(stream), 0) || fseek(stream, 0, SEEK_SET)) {
        perror("reset smoke stream");
        return false;
    }
    return true;
}

static int run(const char *command, FILE *output, FILE *errors)
{
    if (!reset_stream(output) || !reset_stream(errors)) {
        return -1;
    }
    ios_setStreams(stdin, output, errors);
    int status = ios_system(command);
    if (fflush(output) || fflush(errors)) {
        perror("flush smoke streams");
        return -1;
    }
    return status;
}

// Exercise the same exported entry point twice on one thread.
static bool check_reentry(FILE *output, FILE *errors)
{
    void *framework = dlopen("curl-impersonate.framework/curl-impersonate", RTLD_NOW | RTLD_LOCAL);
    int (*entry)(int, char **) = framework ? dlsym(framework, "curl_impersonate_main") : NULL;
    if (!entry) {
        NSLog(@"Cannot load curl-impersonate entry point: %s", dlerror());
        return false;
    }

    bool passed = true;
    for (int i = 0; i < 2; i++) {
        if (!reset_stream(output) || !reset_stream(errors)) {
            passed = false;
            break;
        }
        char *args[] = {"curl-impersonate", "-q", "--parallel", "--output", "/dev/null",
                        "--write-out", "%{urlnum}", "file:///dev/null", NULL};
        int status = entry(8, args);
        rewind(output);
        int index = fgetc(output);
        char progress[512] = "";
        rewind(errors);
        bool header = fgets(progress, sizeof(progress), errors) &&
            strstr(progress, "DL% UL%  Dled  Uled  Xfers  Live");
        NSLog(@"same-thread invocation %d: urlnum=%c; progress header=%s; exit %d", i + 1,
              index == EOF ? '?' : index, header ? "yes" : "no", status);
        if (status || index != '0' || fgetc(output) != EOF || !header) {
            passed = false;
            break;
        }
    }
    dlclose(framework);
    return passed;
}

int main(void)
{
    @autoreleasepool {
        initializeEnvironment();
        ios_switchSession("curl-impersonate smoke");
        // Match a-Shell's bundled CA setup instead of the standalone ios_system default.
        NSString *ca = [NSBundle.mainBundle pathForResource:@"cacert" ofType:@"pem"];
        if (!ca || setenv("SSL_CERT_FILE", ca.fileSystemRepresentation, 1) ||
            unsetenv("CURL_CA_BUNDLE") || unsetenv("SSL_CERT_DIR")) {
            NSLog(@"Cannot configure the bundled CA file");
            return 1;
        }

        FILE *output = tmpfile();
        FILE *errors = tmpfile();
        if (!output || !errors) {
            perror("tmpfile");
            return 1;
        }

        const char *invalid = "curl-impersonate -q --invalid-smoke-option";
        int bad = run(invalid, output, errors);
        char error[512] = "";
        rewind(errors);
        fgets(error, sizeof(error), errors);
        NSLog(@"%s\n%sstatus=%d", invalid, error, bad);
        if (bad <= 0 || !strstr(error, "--invalid-smoke-option")) {
            return 1;
        }

        if (!check_reentry(output, errors)) {
            return 1;
        }

        const char *request =
            "curl-impersonate -q --impersonate chrome150 --silent --show-error --fail --max-time 30 "
            "--output /dev/null --write-out %{http_code} https://example.com";
        for (int i = 0; i < 2; i++) {
            int status = run(request, output, errors);
            char http[8] = "";
            rewind(output);
            fread(http, 1, sizeof(http) - 1, output);
            NSLog(@"%s\nHTTP %s; exit %d", request, http, status);
            if (status || strcmp(http, "200")) {
                rewind(errors);
                for (int c; (c = fgetc(errors)) != EOF;) {
                    fputc(c, stderr);
                }
                return 1;
            }
        }

        NSString *missingHome = [NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *missingCA = [missingHome stringByAppendingPathComponent:@"cacert.pem"];
        if (setenv("CURL_HOME", missingHome.fileSystemRepresentation, 1) ||
            setenv("SSL_CERT_FILE", missingCA.fileSystemRepresentation, 1)) {
            perror("setenv");
            return 1;
        }
        int badCA = run(request, output, errors);
        char diagnostics[2048] = "";
        rewind(errors);
        fread(diagnostics, 1, sizeof(diagnostics) - 1, errors);
        NSLog(@"Explicit missing SSL_CERT_FILE: exit %d", badCA);
        // CURLE_SSL_CACERT_BADFILE with diagnostics from this command only.
        if (badCA != 77 || !strstr(diagnostics, missingCA.fileSystemRepresentation) ||
            strstr(diagnostics, "--invalid-smoke-option")) {
            NSLog(@"Unexpected CA failure diagnostics: %s", diagnostics);
            return 1;
        }

        ios_setStreams(stdin, stdout, stderr);
        fclose(output);
        fclose(errors);
        return 0;
    }
}
