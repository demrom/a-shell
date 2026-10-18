#include "include/ashell-p3.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Public C ABI only; the guests, engine and filesystem are real. */
static char out[1024], err[1024];
static intptr_t sink_write(uintptr_t c, int32_t stream, const uint8_t *bytes, size_t length) {
    (void)c;
    char *to = stream == 1 ? out : err;
    size_t used = strlen(to);
    if (used + length >= 1024) return -1;
    memcpy(to + used, bytes, length);
    to[used + length] = 0;
    return (intptr_t)length;
}
static int failures;
static void expect(int ok, const char *what) {
    printf("{\"check\":\"%s\",\"pass\":%s}\n", what, ok ? "true" : "false");
    if (!ok) { failures++; fprintf(stderr, "FAIL: %s\n  stdout: %s  stderr: %s\n", what, out, err); }
}
static int run_artifact(AshellP3Runner *r, const char *path) {
    AshellP3Output sink = { 0, sink_write };
    const char *argv[] = { path };
    out[0] = err[0] = 0;
    return ashell_p3_run_trusted(r, path, 1, argv, sink);
}
static int compile(AshellP3Runner *r, const char *wasm, const char *artifact) {
    AshellP3Output sink = { 0, sink_write };
    out[0] = err[0] = 0;
    return ashell_p3_compile(r, wasm, artifact, sink);
}
static int leftovers(const char *dir) {
    char cmd[512];
    snprintf(cmd, sizeof cmd, "test \"$(ls %s | grep -c tmp)\" = 0", dir);
    return system(cmd) == 0 ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: artifact-contract HELLO.component.wasm OTHER.component.wasm MODULE.wasm\n"); return 2; }
    char dir[] = "/tmp/artifact-contract-XXXXXX";
    if (!mkdtemp(dir)) return 1;
    char art[600], garbage[600], stale[600], denied[600], missing[600];
    snprintf(art, sizeof art, "%s/a.cwasm", dir);
    snprintf(garbage, sizeof garbage, "%s/garbage.cwasm", dir);
    snprintf(stale, sizeof stale, "%s/stale.cwasm", dir);
    snprintf(denied, sizeof denied, "%s/denied.cwasm", dir);
    snprintf(missing, sizeof missing, "%s/missing.cwasm", dir);
    AshellP3Runner *r = ashell_p3_new();

    /* Compile once, run from the artifact: same output as the guest. */
    expect(compile(r, argv[1], art) == 0, "compile component: status 0");
    expect(ashell_p3_artifact_status(r, art) == ASHELL_P3_ARTIFACT_OK, "artifact status ok");
    expect(run_artifact(r, art) == 0 && !strcmp(out, "WASIP3_HELLO\n"), "run from artifact prints the guest output, status 0");
    expect(leftovers(dir) == 0, "no temp file left after compile");

    /* A Preview1 module takes the same path. */
    char mart[600];
    snprintf(mart, sizeof mart, "%s/m.cwasm", dir);
    expect(compile(r, argv[3], mart) == 0 && ashell_p3_artifact_status(r, mart) == ASHELL_P3_ARTIFACT_OK && run_artifact(r, mart) == 0, "module: compile, status ok, run 0");

    /* Changed package wasm: recompile replaces the artifact atomically (new inode). */
    struct stat before, after;
    stat(art, &before);
    expect(compile(r, argv[2], art) == 0, "recompile changed wasm into the same path");
    stat(art, &after);
    expect(before.st_ino != after.st_ino, "replacement is a rename (old mapping's inode survives)");
    expect(run_artifact(r, art) != 0 || strcmp(out, "WASIP3_HELLO\n") != 0, "artifact now runs the changed guest, not the old one");

    /* A failed compile leaves the previous artifact intact and no temp file. */
    char junk[600];
    snprintf(junk, sizeof junk, "%s/junk.wasm", dir);
    FILE *f = fopen(junk, "w"); fputs("not wasm", f); fclose(f);
    stat(art, &before);
    expect(compile(r, junk, art) == 1 && err[0], "compile of invalid wasm: status 1 with a message");
    stat(art, &after);
    expect(before.st_ino == after.st_ino && ashell_p3_artifact_status(r, art) == ASHELL_P3_ARTIFACT_OK, "failed compile leaves the previous artifact");
    expect(leftovers(dir) == 0, "no temp file left after failed compile");

    /* Status classes. */
    expect(ashell_p3_artifact_status(r, missing) == ASHELL_P3_ARTIFACT_MISSING, "missing file");
    f = fopen(garbage, "w"); fputs("this is not a wasmtime artifact", f); fclose(f);
    expect(ashell_p3_artifact_status(r, garbage) == ASHELL_P3_ARTIFACT_CORRUPT, "foreign bytes: corrupt");
    char cmd[1500];
    snprintf(cmd, sizeof cmd, "cp %s %s && perl -pi -e 's/pulley64/pulley32/g' %s", mart, stale, stale);
    expect(system(cmd) == 0 && ashell_p3_artifact_status(r, stale) == ASHELL_P3_ARTIFACT_INCOMPATIBLE, "engine target changed (pulley64 to pulley32): incompatible");
    snprintf(cmd, sizeof cmd, "cp %s %s && chmod 000 %s", art, denied, denied);
    expect(system(cmd) == 0 && (geteuid() == 0 || ashell_p3_artifact_status(r, denied) == ASHELL_P3_ARTIFACT_IO), "unreadable file: io, not corrupt");

    ashell_p3_delete(r);
    snprintf(cmd, sizeof cmd, "chmod -R u+rw %s; rm -rf %s", dir, dir);
    (void)!system(cmd);
    return failures ? 1 : 0;
}
