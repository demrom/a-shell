#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>
#include <ios_system/ios_system.h>
#undef kill
extern pid_t ios_currentPid(void);
typedef int (*Spawn)(const char *, const char *, unsigned, unsigned, const char *const *, int *, void **);
typedef void (*Release)(void *);
static pid_t workerPid(int fd) {
    struct pollfd input = { fd, POLLIN, 0 };
    if (poll(&input, 1, 3000) <= 0) return -1;
    char output[64] = {0};
    ssize_t length = read(fd, output, sizeof(output) - 1);
    return length > 0 ? atoi(output) : -1;
}
int reuse_check(int argc, char **argv) {
    Spawn spawn = dlsym(RTLD_DEFAULT, "herdr_pane_spawn");
    Release release = dlsym(RTLD_DEFAULT, "herdr_pane_release");
    if (!spawn || !release) { fprintf(thread_stdout, "missing public pane ABI\n"); return 2; }
    char cwd[4096];
    if (!getcwd(cwd, sizeof(cwd))) return 3;
    const char *command = "dash -c 'echo $HERDR_WORKER_PID; sleep 60'";
    const char *const *env = (const char *const *)environmentVariables(ios_currentPid());
    int fd = -1; void *first = NULL;
    if (argc == 2 && !strcmp(argv[1], "failure")) {
        int limit = [[NSBundle.mainBundle objectForInfoDictionaryKey:@"HerdrWorkerCount"] intValue];
        if (limit != 1) return 5;
        const char *invalidEnv[] = { "BAD", NULL };
        int refused = spawn(command, cwd, 80, 24, invalidEnv, &fd, &first);
        if (first) { release(first); close(fd); }
        NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
        first = NULL;
        int error = spawn(command, cwd, 80, 24, env, &fd, &first);
        double elapsed = (NSProcessInfo.processInfo.systemUptime - started) * 1000;
        fprintf(thread_stdout, "refused_error=%d valid_error=%d elapsed_ms=%.3f capacity=%d\n", refused, error, elapsed, limit);
        fflush(thread_stdout);
        if (first) { release(first); close(fd); }
        return refused != EINVAL || error || elapsed > 2000;
    }
    int error = spawn(command, cwd, 80, 24, env, &fd, &first);
    if (error) { fprintf(thread_stdout, "first_spawn=%d\n", error); return 4; }
    pid_t oldPid = workerPid(fd);
    release(first); close(fd);
    int oldAlive = oldPid > 0 && kill(oldPid, 0) == 0;
    void *second = NULL;
    error = spawn(command, cwd, 80, 24, env, &fd, &second);
    pid_t newPid = error ? -1 : workerPid(fd);
    int oldAliveAfter = oldPid > 0 && kill(oldPid, 0) == 0;
    int limit = [[NSBundle.mainBundle objectForInfoDictionaryKey:@"HerdrWorkerCount"] intValue];
    fprintf(thread_stdout, "old_pid=%d old_alive=%d new_pid=%d spawn_error=%d reused_live=%d old_alive_after=%d capacity=%d\n", oldPid, oldAlive, newPid, error, oldAlive && oldPid == newPid, oldAliveAfter, limit);
    fflush(thread_stdout);
    if (second) { release(second); close(fd); }
    return !oldAlive || error || newPid <= 0 || oldPid == newPid || (limit == 1 && oldAliveAfter);
}
