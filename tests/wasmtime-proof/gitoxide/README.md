# gitoxide on stock WASI Preview2

Task task-79mc.509, 2026-10-18. This pkg experiment has not been installed or published upstream. The guest uses stock WASI imports, including `wasi:http`; it has no custom host imports or guest threads. The C1 host compiles to Pulley and runs its interpreter at opt-level 3. The host retains its existing overall size profile.

Pinned input: gitoxide v0.60.0, commit `0115e902fd0334b8f370766993eb17babed3157f`, source archive SHA256 `7414812a006ac67d38a8d7e5fa74ebb2863dac10d50fce6cdc2e0c3ddd419f2e`. Rust 1.96.1; new HTTP dependency waki 0.5.1 and transitive versions/checksums are pinned by the patch to Cargo.lock. Wasmtime 49.0.3 remains unchanged. Toolchain APIs and actual commands were checked on this Mac on 2026-10-18.

## Reproduce

Put Rust 1.96.1 and its wasm32-wasip2 target on PATH. Set CARGO_HOME to an owned cache if needed. The recipe downloads only the pinned source; it does not install a toolchain. Obtain the lead's heavy-build slot, use an owned cache/target, and retain more than 10 GiB free. `prepare` checks and patches the source without compiling; repeated preparation makes no source changes. The recipe refuses a running swift build; the lead's grant is still required for other concurrent builds.

```sh
proof=/absolute/path/to/a-shell/tests/wasmtime-proof
cache=/absolute/path/to/owned/gitoxide-cache
"$proof/gitoxide/build.sh" "$cache" prepare
"$proof/gitoxide/build.sh" "$cache" wasi
"$proof/gitoxide/build.sh" "$cache" native
```

Both guest and native CLI use opt-level z, fat LTO, one codegen unit, debug 0 and stripped symbols. Features are sha1, pretty-cli, gitoxide-core-blocking-client, plus http-client-wasi for the guest or http-client-reqwest for native. The line-rendering progress UI is disabled; the CLI executes synchronously and preserves command stdout/stderr and errors. The guest HTTP response is streamed in 64 KiB chunks; request bodies have an explicit 8 MiB limit.

Build the existing C1 host with default features and its retained package override for pulley-interpreter opt-level 3. Default features include the compiler required to accept ordinary .wasm; `--no-default-features` builds C2 and requires trusted precompiled artifacts. The host now links stock Preview2 command, filesystem and HTTP interfaces alongside the existing Preview1/Preview3 paths. The Preview2 guest sees the host sandbox root as `/`, with read/write permission; the app sandbox remains the outer authority. stdin remains EOF in this proof.

```sh
host=/absolute/path/to/C1/ashell-p3-host
wasm="$cache/target/wasm32-wasip2/release/gix.wasm"
native="$cache/target/aarch64-apple-darwin/release/gix"
"$host" "$wasm" --no-verbose --threads 1 clone https://github.com/octocat/Hello-World.git /absolute/path/to/wasi-clone
"$native" --no-verbose --threads 1 clone https://github.com/octocat/Hello-World.git /absolute/path/to/native-clone
"$host" "$wasm" --no-verbose --threads 1 -r /absolute/path/to/wasi-clone status --no-write
"$host" "$wasm" --no-verbose --threads 1 -r /absolute/path/to/wasi-clone log
"$host" "$wasm" --no-verbose --threads 1 -r /absolute/path/to/wasi-clone diff tree HEAD~1 HEAD
```

The maintained `check.sh C1-HOST GIX.wasm NATIVE-GIX ABSOLUTE-DISPOSABLE-DIRECTORY` runs both real HTTPS clones and all four comparisons, including explicit checks for a nonempty log/diff and modified/untracked status. It requires a new disposable directory and retains stdout/stderr for every invocation.

Run the same last three command arguments with native gix and its clone path. Compare stdout, stderr and exit status. For a nonempty status assertion, append `WASI comparison change` to README and create untracked.txt identically in both clones, then rerun status. Do not compare timing while another heavy build runs.

## Host observations

The actual HTTPS clone of octocat/Hello-World exited 0, checked out README containing `Hello World!\n`, and produced byte-identical ref output to native. Both clones resolved HEAD to `7fd1a60b01f91b314f59955a4e4d4e80d8edf11d`. Clean status, changed/untracked status, log, and a nonempty tree diff all returned 0 with byte-identical stdout and empty stderr. These are full CLI invocations over real repositories, through the real command boundary.

Cancellation was checked at two public boundaries. A local HTTP fixture held the clone's `/repo.git/info/refs?service=git-upload-pack` request without returning headers. After that request arrived, an independent controller sent SIGINT to the host CLI: exit 130. The C ABI client `gix-cancel.c` received the same SIGINT, called the public cancellation API on its control thread, observed clone status 130, then executed `--version` on the same Runner: status 0 and exact `gix 0.60.0\n`. The fixture confirmed that the clone request was pending when SIGINT arrived. Public HTTPS clone success is a separate row.

```sh
nice -n 15 clang -O2 -Wall -Wextra -Werror "$proof/gix-cancel.c" /absolute/path/to/C1/libashell_p3_host.a -framework Security -framework SystemConfiguration -o /absolute/path/to/gix-cancel
# Start a local delayed HTTP fixture, then send SIGINT after its info/refs request arrives.
/absolute/path/to/gix-cancel "$wasm" http://127.0.0.1:PORT/repo.git /absolute/path/to/disposable-clone
```

Retained local raw evidence: `/private/tmp/wasmkit-task-79mc496/pkg509-evidence/command-comparison.json`, `cancel-results.json`, clone stdout/stderr/status files and compile logs. This directory is disposable; committed result files preserve command output, statuses and artifact sizes. Artifact hashes are build-path-specific and do not assert bit-for-bit reproducibility across different paths.

## Actual gaps and narrow fixes

- The unmodified CLI failed in crossterm, then signal-hook, then Tokio/reqwest's threaded runtime. The guest omits the renderer and POSIX signal registration; the host owns cancellation. The new HTTP backend implements the existing gix Http contract using waki and stock WASI HTTP, without adding pthread/process stubs.
- std::process::id traps on WASI. Tempfile ownership is now explicitly forkless on WASI (`None`, compared only within the current instance); native retains real process IDs. Randomness still starts with the existing OS entropy source, without invented fixed IDs or seeds.
- memmap2's WASI implementation returns Unsupported. Pack, loose-object, index and commit-graph readers use ordinary file reads on WASI; native retains mappings. Whole-file heap copies increase memory costs. Large repositories are unqualified, especially under the phone's process memory cap.
- filetime's generic Wasm modification-time accessor panics. WASI index loading uses checked std metadata.modified and converts the actual SystemTime. Metadata errors remain errors.
- io-close has no WASI File implementation. WASI checkout syncs files before dropping them, surfacing write errors; native retains explicit close. WASI cannot set executable bits: checkout of an executable file returns Unsupported and reports the failed mode change. Desktop viewer requests also return Unsupported.
- The HTTP backend supports the measured public GET/POST flow. Redirect responses fail explicitly; redirect following and credential retry are not implemented. Client proxy/custom CA/TLS version/SSL-disable/backend/HTTP-version/low-speed overrides fail explicitly because stock WASI HTTP owns those settings. Native HTTP configuration remains unchanged. Larger uploads fail at the stated cap; broad authentication/configuration compatibility is unverified.
- The pinned Rust Preview2 guest imports `wasi:cli/exit@0.2.6` with a success/failure result only. An invalid CLI option returns native status 2 but WASI status 1, with the same error text before the executable-specific usage line. The host cannot recover the lost numeric code; a future guest/toolchain must use the stock exit-with-code interface, which Wasmtime 49 already supports. Host cancellation still returns 130.
- No guest threading, subprocess hooks, external filters, desktop browser, SSH transport, TUI, stdin prompts, or large-repository memory claim is made. Smallest next steps are the missing platform-specific capability when a real command requires it, followed by its CLI regression; do not add success-returning stubs.

## Phone status

The unsigned iOS C1 runtime built against corrected ios_system core `4de113152cc25eba706c16c0b7984476fb43d2dbe397fca46a6e577cfb02dd44`. Framework size is 11,665,968 bytes, SHA256 `51041c7207e5d9501a58fab1c425a9adcb9bbd59b02aa7bf4b141f60ba0f3fc0`, SDK 27.1 and minimum iOS 26.2. Expected command exports and platform metadata passed.

Pending: the lead and .352 must run the same clone/status/log/diff/cancel/recovery rows in a worker, using the updated C1 Preview2 runtime and this exact guest. No phone action or installation was performed by this worker. Preview2 gitoxide needs its own phone qualification.

## Phone driver commands

Use the lead's exclusive phone window and current approved candidate. Integrate only the updated C1 WasmtimeCommand.framework, with the existing `wasmtime` command dictionary/PATH entries in host and worker. Keep the corrected core and preserve the candidate's other owner changes. Follow the existing signing, single-source receipt and rollback procedure. This worker grants no phone slot and has not installed the artifact.

Transfer the exact guest and its SHA256SUMS from `/private/tmp/wasmkit-task-79mc496/pkg509-phone-inputs` to a disposable `~/Documents/herdr-pkg509` directory. Check the hash after transfer. Run the following in one real Herdr worker; record its PID before and after. Capture command status separately from stdout/stderr.

```sh
pkg="$HOME/Documents/herdr-pkg509"
mkdir -p "$pkg"
wasmtime "$pkg/gix.wasm" --version > "$pkg/version.out" 2> "$pkg/version.err"
wasmtime "$pkg/gix.wasm" --no-verbose --threads 1 clone https://github.com/octocat/Hello-World.git "$pkg/repo" > "$pkg/clone.out" 2> "$pkg/clone.err"
wasmtime "$pkg/gix.wasm" --no-verbose --threads 1 -r "$pkg/repo" status --no-write > "$pkg/status-clean.out" 2> "$pkg/status-clean.err"
wasmtime "$pkg/gix.wasm" --no-verbose --threads 1 -r "$pkg/repo" log > "$pkg/log.out" 2> "$pkg/log.err"
wasmtime "$pkg/gix.wasm" --no-verbose --threads 1 -r "$pkg/repo" diff tree HEAD~1 HEAD > "$pkg/diff.out" 2> "$pkg/diff.err"
printf 'WASI comparison change\n' >> "$pkg/repo/README"
printf 'untracked fixture\n' > "$pkg/repo/untracked.txt"
wasmtime "$pkg/gix.wasm" --no-verbose --threads 1 -r "$pkg/repo" status --no-write > "$pkg/status-dirty.out" 2> "$pkg/status-dirty.err"
```

Compare these files with the transferred host-native `expected-*.out` and `expected-*.err` files. Require status 0, exact output and unchanged worker PID. The clean status must be empty; the dirty status must list modified README and untracked.txt. The expected log and tree diff are nonempty. This is a tiny repository qualification; retain any physical memory measurement separately from file sizes.

In a separate disposable destination, start the same clone invocation, send an independent real keyboard Ctrl-C while it is active, and require status 130. Run `wasmtime "$pkg/gix.wasm" --version` and an ordinary command immediately afterward in the same worker, requiring status 0 and exact output. Record whether cancellation occurred during component compilation or after HTTP started; the host's delayed-HTTP test already proves cancellation while a clone request is pending. If the tiny clone completes before Ctrl-C, that attempt does not qualify; repeat with a controlled delayed clone endpoint in a lead-approved fixture window. Never count a completed clone or an HTTP error as cancellation. Route runtime defects back with exact output/status; restore the saved candidate after the proof unless the lead directs otherwise.
