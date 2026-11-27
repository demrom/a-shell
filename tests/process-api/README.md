# Process API regression

The entry point is the regular a-Shell mini terminal. The guest starts a Dash child that writes `process-worker-ok` and exits 7. Use `dash` here: a-Shell's `sh` dispatch does not provide Dash's `exit` builtin. The guest checks the encoded child status and exits 0. The test checks the guest status, exact stdout and empty stderr. A plain Preview 1 guest checks each engine separately so an unavailable backend is not mistaken for a process regression.

Prepare both fixtures and copy them with `check.sh` into a fresh app Documents subdirectory:

```sh
wasm-tools parse tests/process-api/control.wat -o control.wasm
wasm-tools parse tests/process-api/spawn-wait.wat -o spawn-wait.wasm
```

Wait for the mini terminal, then enter these as separate commands, pressing Return after each line:

```sh
cd ~/Documents/process-check
dash check.sh
```

The script saves `*.out`, `*.err`, `*.status` and two monotonic timestamps (`*.ns`) for each invocation. `result` is `0` only when both controls and both process checks pass. On a shared Mac, check the artifact's `WasmServerPort` before starting WebView; a port collision can fail even the plain Preview 1 control.

To exercise the same public behavior through the libc overlay instead of direct imports, use stock WASI SDK 34:

```sh
for fixture in posix-spawn system execvp spawn-attributes; do
    "$WASI_SDK_PATH/bin/clang" -O2 -std=c17 -Wall -Wextra -Werror \
        -I wasm-process/include "tests/process-api/$fixture.c" \
        wasm-process/process.c -o "$fixture.wasm"
    wasm-tools validate "$fixture.wasm"
done
```

Copy those modules, `control.wasm` and `check.sh` into a separate fresh Documents subdirectory. Run `dash check.sh overlay` in that directory. It checks both engines. All four fixtures require exactly `process-worker-ok` on stdout and empty stderr. `posix-spawn` and `system` verify the encoded child exit 7 and then exit 0; the shim does not yet implement POSIX signal-mask changes around `system()`.

The `execvp` fixture requires guest exit 7 and no return from `execvp` after admission. This compatibility path does not preserve a native PID or promise POSIX delivery of signals while waiting. Admission errors return to the guest; after admission, exit 125 denotes a wait or transport failure.

The `spawn-attributes` fixture accepts GNU's `POSIX_SPAWN_USEVFORK` hint without changing worker creation. Unsupported flags fail at `posix_spawnattr_setflags` without changing the stored flags.

For a focused WebView mailbox regression off-device, run `node tests/process-api/webview-mailbox.cjs APP_BUNDLE SPAWN_WAIT_WASM`. Use the unpacked a-Shell mini bundle for its Wasmer dependencies. The test executes both repository browser scripts and injects a late WebKit prompt completion; pass `APP_BUNDLE` again as the scripts directory to test the scripts installed in that bundle. You can also pass `execvp.wasm` as the guest, a scripts directory and `7` as the expected status to verify that `proc_exit` produces no diagnostic. Neither test replaces the live WebKit run.

## WebView descriptor boundary

`node tests/process-api/webview-fd.cjs RESOURCES GUEST_WASM [pipe|popen|table|errors]` runs the actual worker, page scripts and bundled Wasmer. Only the outer WebKit prompt is stubbed. Use `Resources_mini` and `Resources` to check both vendored bundles. The `pipe` row takes the compact descriptor ABI WAT smoke; `popen` takes the compiled `popen.c` overlay guest. Build `webview-fd-table.c` with the same overlay for `table`: it opens an ordinary file after a pipe was duplicated over stdin and checks that neither stdout nor stderr is replaced. `errors` takes `webview-fd-errors.c` and requires a malformed pipe reply to publish no guest FDs and a close error to release the guest FD slot. The Node rows do not prove Swift host I/O or ExtensionKit admission.

## `popen` and `pclose`

`tests/process-api/popen.c` uses only POSIX calls. Once the FD path is implemented, build it with the same overlay and run it in both engines. It requires the child output and EOF from `popen("…", "r")`, an encoded exit 7 from `pclose`, and exactly `process-popen-ok` on guest stdout with guest exit 0. Stock SDK 34 cannot build it: with the wait header supplied, `popen` and `pclose` are undeclared. This is not part of the spawn/wait preview.

## Signal an owned worker

Build `signal-wait.wasm` from `signal-wait.wat` with `wasm-tools parse`, and build `kill.c` with the overlay command above plus `-D_WASI_EMULATED_SIGNAL -lwasi-emulated-signal`. Run each in a separate terminal command under both engines. Expect `process-signal-ok` or `process-kill-ok`, guest status 0 and empty stderr, before the worker's ten-second sleep could finish. The libc row distinguishes termination by SIGTERM from a normal exit of 143.

`kill` accepts a positive PID returned to the current guest. Signal 0 probes the child without changing its state, including after completion but before reap. SIGHUP, SIGINT, SIGQUIT, SIGKILL and SIGTERM request broker cancellation; they do not run a signal handler in the child. Acknowledged cancellation produces a signaled wait status, and reap removes the guest's ownership. Unsupported signals and process groups fail with ENOTSUP, invalid signals with EINVAL, and unowned PIDs with ESRCH. The worker bridge does not deliver signals to guest handlers, provide SIGCHLD notifications, or implement process groups.

## Guest alarm and signal masks

WASI SDK 34's `-lwasi-emulated-signal` exports `signal` and `raise` but has no `sigaction`, masks, `alarm` or `sigsuspend`. Build the opt-in overlay and fixture with the stock SDK:

```sh
"$WASI_SDK_PATH/bin/clang" -O2 -std=c17 -Wall -Wextra -Werror \
    -D_WASI_EMULATED_SIGNAL -I wasm-process/include \
    tests/process-api/signal-mask.c wasm-process/signals.c \
    -lwasi-emulated-signal -o signal-mask.wasm
```

Run `wasm ./signal-mask.wasm` and `wasmkit ./signal-mask.wasm` as separate mini terminal commands. Both must print exactly `process-signal-mask-ok` with status 0 and empty stderr. The fixture checks delivery during `sigsuspend`, the mask inside the handler, restoring the caller's mask and cancelling an alarm.

State is local to the guest. Alarm delivery is cooperative at signal calls, not asynchronous during arbitrary code or I/O. Link `process.c` and `signals.c` together for the `waitpid(WNOHANG)`/`sigsuspend` pattern: a miss arms the last requested child (or any owned child for PID -1). Readiness schedules one guest SIGCHLD without consuming the wait result. `wait-peek.c` checks the raw ABI and `wait-signal.c` checks the POSIX loop; both expect their named marker, status 0 and empty stderr. There is no signal when an unarmed child completes. Separate positive-PID misses replace the previous watch; use `waitpid(-1, ..., WNOHANG)` for an any-child watch. `sigsuspend` returns ENOTSUP when there is no deliverable source.

For readiness error isolation, build `signal-pending.c` with `-D_WASI_EMULATED_SIGNAL`, `process.c` and `signals.c`. Run `node --no-warnings tests/process-api/signal-pending-host.cjs signal-pending.wasm`. The harness uses real Preview 1 and an older broker boundary that rejects PEEK. Expect `process-signal-pending-ok`, status 0, and empty stderr: an expired alarm wakes suspend, and successful unmask delivers a second pending alarm without leaking the probe's errno. This does not send or subscribe to host signals, stop or resume guests, or queue real-time signals.

## Preview 1 account lookup

`accounts.c` supplies an empty POSIX account database: WASI Preview 1 exposes no account names, so user/group lookup by name or numeric ID returns NULL without changing errno. Build `tests/process-api/accounts.c` with `wasm-process/accounts.c` and the overlay include path; the result has no a-Shell host imports and must print `process-accounts-empty-ok`, status 0 and empty stderr.

## Restricted `fork` and `vfork`

Use stock SDK 34 and Binaryen 133. Build single-threaded wasm32 C modules with the fork overlay and export the compiler stack pointer before transforming all paths that can reach `process_fork`:

```sh
for fixture in fork-exec fork-grown plain-fork fork-exec-rejected; do
    "$WASI_SDK_PATH/bin/clang" -O2 -std=c17 -Wall -Wextra -Werror \
        -I wasm-process/include "tests/process-api/$fixture.c" \
        wasm-process/process.c wasm-process/fork.c -Wl,--export=__stack_pointer -o "$fixture.raw.wasm"
    wasm-opt "$fixture.raw.wasm" --asyncify --pass-arg=asyncify-imports@ashell_v1.process_fork \
        -o "$fixture.wasm"
    wasm-tools validate "$fixture.wasm"
done
```

The first row checks child-only `close` and `dup2`, a native worker's output through a pipe and EOF, and wait status 7. Expect `process-fork-child` and `process-fork-parent` in that order. The second exercises the WasmKit copy path after guest memory has grown, the scoped parent/child identities, and isolation before `execvp`. Expect `process-fork-grown-ok`. The third attempts child output and exit without exec. It must print only `process-plain-fork-unsupported`. The fourth calls `_exit(127)` after a rejected exec of a missing path. Expect `process-fork-exec-rejected`: the resumed parent sees `ENOENT`, not a child with status 127. Run each module separately via `wasm` and `wasmkit`; all four need status 0 and empty stderr.

The parent is suspended during the child prelude. The prelude inherits private linear memory (up to 32 MiB) and borrows FD identities for local `close`/`dup2`; only final stdio is handed to a worker. No writes or unrelated process calls are allowed from the prelude. An admitted exec transfers the actual worker PID to the parent, and ordinary wait consumes that worker. Without exec the parent gets ENOTSUP; a rejected admission is not a manufactured child status. This is not arbitrary process cloning, native `fork`, or a shared-stack `vfork`. Only the SDK stack pointer and linear memory are copied; modules with other mutable WebAssembly globals, mutated indirect tables, shared memory or threads are outside this ABI. Prelude identity values are guest-local and cannot be signaled; process groups remain unsupported.

## Interrupt a guest with a live worker

Build `cancel-spawn.wasm` with `wasm-tools parse tests/process-api/cancel-spawn.wat -o cancel-spawn.wasm`. Copy it to a fresh Documents subdirectory, `cd` there in the mini terminal, and run `wasmkit ./cancel-spawn.wasm`. Without interruption, confirm the worker writes `ready` to `process-cancel-started` and then `leaked` to `process-cancel-leaked` after 10 seconds. This is the delivery control, not a failure.

Repeat in a second fresh subdirectory. After `process-cancel-started` contains `ready`, press Ctrl-C in the mini terminal before the 10 seconds elapse. Confirm the terminal accepts another command and `process-cancel-leaked` is still absent after the control's deadline. Both the start marker and successful interrupt are required; a missing leaked marker on its own does not pass.
