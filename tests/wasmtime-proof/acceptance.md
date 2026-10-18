# Pulley worker acceptance

This is a bounded feasibility probe, not a replacement for the installed interpreter. Runtime: Wasmtime 49.0.3, `pulley64`, stock p3 hosts. Guest WIT: released WASI 0.3.1. Record build/revision, target, device/OS, date and fresh result paths with each run. A host or Simulator result does not qualify the physical extension's memory limit.

| Contract | Required boundary | Expected result | Status |
| --- | --- | --- | --- |
| Released guest ABI | Component inspection | stdout/types imports and run export remain `@0.3.1` | PASS: wasm-tools 1.262.0 decode and C1/C2 physical runs, 2026-10-18 |
| First linking gate | Stock host CLI with Pulley | Exact `WASIP3_HELLO` plus LF, status 0; stop on mismatch without downgrading | PASS: stock host CLI exit 0, exact stdout, 2026-10-18 |
| Worker hello | Real a-Shell worker command | Same exact stdout/status, main app and worker remain alive | PASS C1/C2: physical worker receipts below |
| Streamed HTTPS | Same worker, normal TLS validation | Status/body exact; first body marker arrives at least 1 s before completion of the public 3 s HTTPS drip | PASS C1/C2: 2.928505/2.963553 s |
| Cancellation/re-entry | Same worker | In-flight request stops, next hello succeeds, stdio remains usable | PASS C1/C2: independent real keyboard runs below |
| Worker memory | Physical device through assigned driver | Baseline/runtime/guest/TLS/cancel/repeat physical footprint and RSS receipts; proposed peak physical footprint <=28 MiB | PASS C1/C2: 6,538,816/5,359,240 bytes peak physical |
| Compiler size comparison | Two matched release builds | Linked size and installed delta with and without Cranelift; trusted artifact compatibility recorded | Signed package file totals measured for all three; installed static delta measured for C2/WasmKit only |
| Install/rollback | Physical device through assigned driver | Owned package install and restore; preserve existing user data/session | UNVERIFIED |

Raw mode, terminal size/resize, interactive Unicode/editing, child spawn and TUI behavior are outside this first skeleton. Their later contract must use an explicitly named a-Shell extension where WASI has no interface; no success stub is accepted. Background/foreground, app kill/relaunch and long-term artifact migration remain unqualified until physical-device checks are added and run. The assigned phone driver owns every phone operation.

## Phone verdict criteria

The final report must end with GO or NO-GO and name these numbers and the corresponding evidence files. A host-only success leaves every phone criterion unverified. Failure at the first linking gate stops this proof as instructed.

| Number | Measurement | Evidence required | Status |
| --- | --- | --- | --- |
| 1 | Released WASI p3 hello and one streamed HTTPS request inside one worker | Exact stdout/status, TLS validation and first-chunk-to-completion interval >=1 s for the public 3 s HTTPS drip | PASS: numbered physical evidence below |
| 2 | Cancellation kills the guest and the worker recovers | Cancel receipt followed by successful hello in the same worker | PASS: numbered physical evidence below |
| 3 | Peak physical footprint <=28 MiB | Physical-device baseline and peak receipts across guest/TLS/cancel/repeat | PASS: numbered physical evidence below |
| 4 | Added app size with and without Cranelift versus current WasmKit | Matched linked/installed app byte counts for all three configurations | Signed package file totals measured for all three; C1 installed static usage unmeasured |
| 5 | Cold start to first output | Physical-device monotonic timestamps with cold-state definition | PASS: numbered physical evidence below |
| 6 | CPU-bound Preview1 guest under WasmKit and Pulley | Identical .wasm SHA-256, exact result and elapsed times on the same phone | PASS: numbered physical evidence below |

## Host evidence, 2026-10-18

These measurements do not qualify the phone. Both variants use the same stock Wasmtime 49.0.3 p3 hosts and released 0.3.1 guest interfaces. C1 compiles ordinary bytecode with Cranelift; C2 loads matching trusted precompiled Pulley artifacts with Cranelift excluded.

| Host observation | C1 | C2 |
| --- | --- | --- |
| Exact hello, streamed HTTPS and same-runner recovery | PASS | PASS |
| Cold C entry to hello's first output | 0.053110 s | 0.003304 s |
| HTTPS first body marker to completion | 3.000971 s | 2.999834 s |
| Original cancellation latency | DISQUALIFIED: HTTP error-body race | DISQUALIFIED: HTTP error-body race |
| Peak physical footprint, entire host process | 14,402,040 bytes | 4,407,776 bytes |
| Stripped arm64 iOS framework, unsigned | 9,936,464 bytes | 5,114,232 bytes |

Evidence files are `ffi-contract-c1.jsonl`, `ffi-contract-c2.jsonl`, `ios-c1-build.log`, `ios-c2-build.log`, `ios-c1-link.log` and `ios-c2-link.log` in the owned output directory. Framework bytes are measured build artifacts, not installed app deltas. The Preview1 CPU guest's 20,000,000-round checksum is `96d4bdf4`; Mac Pulley computation was approximately 0.23 s. These host timings are separate from the physical comparison below.

The matched upstream WasmKitCommand/WasmKit baseline also builds for arm64 iOS 26.2: stripped unsigned framework 2,595,248 bytes, source wrapper unchanged, WasmKit submodule `4972ae620e25d7eaecaf6a08248b46c50b67d750`. Its build evidence is `wasmkit-build.log`. It is absent from the current mini candidate and must be added for the physical comparison.

## Cancellation fixture correction, 2026-10-18

Harness defect `task-5hct`: the public service caps delay plus duration at ten seconds. The old twenty-second request and a ten-second request with default two-second delay return HTTP 400. A first-body marker alone allowed an error-body cancellation race to pass. The corrected contract uses `duration=8&delay=0&numbytes=8&code=200`, requires HTTP 200 and an actual asterisk before cancellation, rejects completed bodies, and records those conditions. Old internal cancellation receipts and the original host worker pipe smoke do not qualify live-stream cancellation. Other measurements remain independent.

Corrected host C1/C2 contract receipts are `ffi-contract-c1-valid-cancel.jsonl` and `ffi-contract-c2-valid-cancel.jsonl`, with corresponding `.status` files requiring zero. Both pass exact hello, streamed HTTPS, cancellation of an unfinished HTTP 200 body with status 130, and exact same-runner hello recovery. The strengthened contract rejected the invalid ten-second fixture; those RED outputs are retained as `ffi-contract-c1-invalid-fixture-red.jsonl` and `ffi-contract-c2-invalid-fixture-red.jsonl`.

## Physical worker verdict, 2026-10-18

GO for the bounded Wasmtime+Pulley runtime proof. C1 supports ordinary Wasm bytecode; C2 removes Cranelift and requires trusted matching precompiled artifacts. Use C1 when ordinary bytecode is required. C2 is suitable for controlled artifacts. This evidence does not qualify a shipping app or select the default runtime: the diagnostic packages are subsets, and WasmKit ran this Preview1 CPU guest faster.

Evidence root: `/private/tmp/colors-task-79mc-352/pulley-190`. The assigned driver ran fresh HerdrWorkerB processes in pane `w1:p2`: C1 PID 82279, C2 PID 82359, corrected WasmKit PID 84043. The main app's full launch/XPC latency is excluded from the cold metric. Device deployment target was iOS 26.2; the latest same-day diagnostic headers report iPhone OS 27.0.1 (24A446), without a fresh live OS query.

| Criterion | C1: Cranelift included | C2: compiler excluded | Evidence relative to root |
| --- | --- | --- | --- |
| 1. WASI p3 hello and streamed HTTPS | Exact hello/status 0; stream continues 2.928505 s after first marker | Exact hello/status 0; stream continues 2.963553 s | `c1-readback/c1.jsonl`, `c2-readback/c2.jsonl` |
| 2. Cancel and worker recovery | Real Ctrl-C after HTTP 200 and body asterisk: status 130, next exact hello/status 0 and ordinary `WORKER_RECOVERED` | Same checks pass | `c1-keyboard8-timing.json`, `c2-keyboard8-timing.json`; each `c1-readback/` or `c2-readback/` contains matching `*-keyboard8.status`, `*-recovered.stdout`, `*-recovered.status`, `*-ordinary.txt` |
| 3. Peak physical footprint <=29,360,128 bytes (28 MiB) | 6,538,816 bytes, PASS; peak RSS 32,014,336 bytes | 5,359,240 bytes, PASS; peak RSS 20,168,704 bytes | `c1-readback/c1.jsonl`, `c2-readback/c2.jsonl` |
| 4. Added app size versus WasmKit | +7,292,094 regular-file bytes | +2,460,462 regular-file bytes | `c1-package.json`, `c2-package.json`, `wasmkit-package.json` |
| 5. Cold C entry before engine creation to first output | 79.129 ms | 9.728 ms | `c1-readback/c1.jsonl`, `c2-readback/c2.jsonl` |
| 6. Same Preview1 CPU workload, 20,000,000 rounds | 221.076208 ms, 1.761423 times WasmKit | 244.475750 ms, 1.947859 times WasmKit | `c1-readback/c1-cpu.txt`, `c2-readback/c2-cpu.txt`, `fixed238-results.json`, `fixed238-readback/preopen-cpu.txt` |

WasmKit's CPU result is 125.510000 ms. All three results have checksum `96d4bdf4`. C1 and WasmKit execute the identical original `.wasm`, SHA-256 `f44063a3cc8deb68f7b688225ae17bb6c3b44840bd966885590785c318e9340e`; C2 executes its matching trusted precompiled equivalent. These are single guest-inner observations that exclude load/dispatch/startup, so they establish this observed cost without a statistical performance claim.

Signed diagnostic package regular-file totals are C1 408,082,080 bytes, C2 403,250,448 bytes and WasmKit 400,789,986 bytes. These are package file sums, not filesystem allocation or installed usage. Installed static usage was measured for C2 (415,502,336 bytes) and WasmKit (413,057,024 bytes): delta 2,445,312 bytes. C1 installed static usage remains unmeasured. The package size receipts precede the guard/preopen corrections; the corrected WasmKit framework retains the same stripped unsigned size, 2,595,248 bytes. Rebuilt signed package totals were not remeasured. `phone-metrics.json` aggregates the measurements; raw receipts retain earlier status fields from their creation time.

The corrected WasmKit comparison required the ios_system guard fix `e18f9e7fa7feccc38104f72300488acd23e3cafc` and WasmKitCommand preopen fix `f28b95d1c5877a7de2587c53054bdffd7f3ca953`. `fixed238-results.json` records exact `WASMKIT_HELLO` plus LF, status 0 and empty stderr; the CPU guest also returns 0 with empty stderr. Worker PID 84043 is unchanged before/after and the next ordinary command prints exact `WASMKIT_PREOPEN_WORKER_RECOVERED`. Both phone guest hashes were checked against the source artifacts.

Cancellation qualification uses only the independent real keyboard runs with HTTP 200 and an actual body byte before Ctrl-C. The earlier internal HTTP 400 cancellation receipts remain disqualified under `task-5hct`. The 219 closure was attributed to installcoordinationd replacing the same app ID, not a Pulley crash; see `stop219-termination.txt`. The diagnostic app is still installed in the latest receipt; restoring the frozen app and qualifying its ordinary behavior belongs to the lead and assigned phone driver.

The released 0.3.1 guest links against stock Wasmtime 49.0.3 p3 hosts without an ABI downgrade or Wasmtime patch. The measured runtime fits the 28 MiB physical footprint limit. The costs are the added package bytes and the observed Preview1 CPU slowdown above. Interactive terminal/child-spawn imports, full lifecycle and default-runtime selection retain their separate acceptance work.

GO

## Interpreter profile experiment, 2026-10-18

Keep the per-package `pulley-interpreter` release override at `opt-level = 3` for the next phone comparison. On this Mac it reduced median guest-inner CPU time by 15.006% for a 64-byte increase in the stripped arm64 iOS framework. WasmKit still has the faster Preview1 CPU median; this result does not establish an optimal runtime dispatch rule or a phone speedup.

The original phone C1/C2 builds used `[profile.release] opt-level = "s"`, `panic = "abort"`, and `strip = "debuginfo"`, including Wasmtime and `pulley-interpreter`. `lto` and `codegen-units` were unset; the captured rustc commands contain neither `-C lto` nor `-C codegen-units`, and use `-C embed-bitcode=no`. The original nonverbose logs do not record numerical codegen units or an explicit LTO mode, so those are reported as unset rather than reconstructed flags. Both original Pulley fingerprints have the same profile ID `896238939589719598` and empty extra Rust flags. An offline verbose C1 replay reproduced the original phone static archive byte-for-byte, SHA-256 `8268c7eff85825a95584b83a7178401a766f19faddbdf992636c78cdc4348abd`. The override changes only the interpreter package; Wasmtime and the other target crates remain at `opt-level = "s"`. LTO, codegen units, guest code generation, features, cancellation and link inputs stay the same.

Evidence root: `/private/tmp/wasmkit-task-79mc496/speed27`. `c1-ios-replay.log`, `c1-ios-opt3.log`, `c1-host-opt3.log`, `original-profile-fingerprints.json` and `profile-flags.json` record the build settings. All Cargo builds used Rust 1.96.1, locked dependencies, offline mode, nice 15 and two jobs. The device links use the same ios_system input, SDK 27.1, iOS 26.2 target, C sources, dead stripping and `strip -S -x`. The baseline was relinked with the current corrected cancellation fixture for an equal comparison: baseline 9,936,464 bytes, interpreter override 9,936,528 bytes, delta +64 bytes. The optimized framework is `ios-opt3/P3Proof.framework`; its unsigned binary SHA-256 is `413247adc4e83e51cfc0e07dc9c4d3d795e8128e6c724cb8bf78fc7b52d5d811`. This experiment used the original matched core, not the subsequent pane-guard fix; the phone driver must preserve the corrected core when packaging.

Five fresh host processes per variant ran the byte-identical Preview1 CPU guest, 20,000,000 rounds, SHA-256 `f44063a3cc8deb68f7b688225ae17bb6c3b44840bd966885590785c318e9340e`. Each returned 0 with checksum `96d4bdf4`. Runs were interleaved with rotated ordering, nice 15, after builds finished; guest-inner `CPU_NS` is separate from process wall time. The host reports macOS 26.6.2 arm64. WasmKit uses the corrected real wrapper and pinned engine in Swift Release, with the host stdio/environment adapter; the earlier Swift debug build is excluded. Dependencies were already cached and package updates/prefetching were disabled.

| Runtime | Median | Minimum | Maximum | Spread (max minus min) |
| --- | --- | --- | --- | --- |
| Current C1, interpreter opt-s | 233.969084 ms | 220.659250 ms | 273.218584 ms | 52.559334 ms |
| C1, interpreter opt-3 only | 198.860542 ms | 196.678000 ms | 248.224500 ms | 51.546500 ms |
| WasmKit Release | 123.041750 ms | 121.089708 ms | 179.307459 ms | 58.217751 ms |

`cpu-five-runs.json` records all fifteen samples, order, process statuses, wall timings and executable hashes; individual stdout/stderr files are alongside it. All five paired C1 observations favored opt-3, but the ranges overlap. These observations support the small profile change and a phone A/B check, not a statistical or cross-device performance claim. Current and optimized C1 medians are respectively 1.901542 and 1.616204 times the WasmKit median. The earlier physical six-criterion verdict remains evidence for the original opt-s builds; the new profile has not been measured on the phone.

Verified against the cached Wasmtime 49.0.3 source, the inexpensive configuration checks are:

| Setting | Current behavior and next action | Source relative to cached crate |
| --- | --- | --- |
| `cranelift_opt_level` | Already `OptLevel::Speed`; this optimizes guest bytecode separately from Cargo's host interpreter profile. A `SpeedAndSize` comparison is cheap but has no presumed speed benefit. Changing compilation settings requires regenerating matching C2 artifacts. | `wasmtime-49.0.3/src/config.rs:1538` |
| Register allocator | Default backtracking already targets code quality. Keep it; SinglePass targets compile speed and carries an upstream maturity warning. | `wasmtime-49.0.3/src/config.rs:1563`, `cranelift-codegen-meta-0.136.3/src/shared/settings.rs:33` |
| `signals_based_traps` and memory guard | Pulley target defaults explicitly disable signal traps and set guards to zero. Cranelift also forbids relying on memory signals for Pulley. Enabling signals or larger guards cannot provide the native bounds-check-elision path. Keep these defaults. | `wasmtime-environ-49.0.3/src/tunables.rs:224`, `wasmtime-internal-cranelift-49.0.3/src/func_environ.rs:5906` |
| Memory reservation/growth and COW | Cheap to vary when investigating allocation, startup or footprint. The target is 64-bit and inherits a 4 GiB virtual reservation with a zero Pulley guard. These are not a likely fix for this register arithmetic loop; virtual reservation is distinct from physical footprint. | `wasmtime-environ-49.0.3/src/tunables.rs:324`, `wasmtime-49.0.3/src/config.rs:1929`, `wasmtime-49.0.3/src/config.rs:2285` |
| Epoch interruption | Enabled to satisfy cancellation. Disabling it is a cheap benchmark control for instrumentation cost, but fails the guest cancellation requirement and is not an adoption option without another proven mechanism. Fuel is already off. | `host/src/lib.rs:108`, `wasmtime-49.0.3/src/config.rs:627`, `wasmtime-49.0.3/src/config.rs:648` |

The interpreter dispatch loop uses the stable Rust match loop in this build. Tail-call dispatch is a separate compile-time configuration, not a `Config` speed knob; it was not changed or tested here. The next measurement should be the interpreter-only opt-3 artifact against current C1 on the phone, through the lead's exclusive driver.

## Native CPU reference, 2026-10-18

The native host median for the same 20,000,000-round loop is 32.544000 ms. Relative to that median, WasmKit takes 3.780781 times as long, C1 with interpreter opt-3 takes 6.110513 times as long, and current C1 takes 7.189316 times as long. This measures one CPU loop; it does not predict the speed of a full native Codex build.

The native executable was compiled from the entire unchanged `cpu/src/main.rs` with Rust 1.96.1 (`31fca3adb`, 2026-06-26), `rustc -C opt-level=3 cpu/src/main.rs -o cpu-native`, target `aarch64-apple-darwin`. Source SHA-256: `c01cadc5d159acfa97ce18cb0c1f8fc9aabd4118e700c67cad276c5ebe26924d`; executable SHA-256: `08928ff89126c37978d99082aaeb56246c55d59217cae5ffbf800d47c444b009`. Five fresh processes at nice 15 returned status 0, empty stderr and checksum `96d4bdf4`. Their inner `CPU_NS` values were 34122917, 31810000, 32544000, 32597583 and 31838459. These native runs followed the original interpreter measurements above; they were not interleaved with them. Process startup remains excluded, and wall times are retained separately.

| Host runtime | Median | Minimum | Maximum | Median / native median |
| --- | --- | --- | --- | --- |
| Native Rust opt-3 | 32.544000 ms | 31.810000 ms | 34.122917 ms | 1.000000 |
| WasmKit Release | 123.041750 ms | 121.089708 ms | 179.307459 ms | 3.780781 |
| C1, interpreter opt-3 only | 198.860542 ms | 196.678000 ms | 248.224500 ms | 6.110513 |
| Current C1, interpreter opt-s | 233.969084 ms | 220.659250 ms | 273.218584 ms | 7.189316 |

Evidence root: `/private/tmp/wasmkit-task-79mc496/speed29`. `native-five-runs.json` holds all five native samples, the original interpreter rows and ratios; `native-1.stdout` through `native-5.stdout` retain raw output. The native row adds an optimized machine-code reference without changing the interpreter results or the recommendation to measure opt-3 on the phone.

A separate unsigned `NativeCPU.framework` is ready for a later phone comparison: 315,904 binary bytes, SHA-256 `41b24154211aaba3f8de70e2d7b12c5936b85beb01bcd0a433db2ed5125bb1ee`, arm64 iOS 26.2, SDK 27.1, exported command `native_cpu_main`. `build-native-framework.sh`, `native-cpu.rs`, `native-entry.c`, `loop-extract.json` and `receipt.json` retain the exact sources and build recipe beside it. The Rust loop and `Instant` timer were extracted verbatim from the original source; only argument parsing and output were adapted to the C command ABI and ios_system thread streams. The same adapter linked as a host command returned exact checksum/status/streams; invalid counts and extra arguments returned 2. `file`, `vtool`, exports and dynamic dependencies were checked. This framework has not been installed or run on a phone, so no native phone timing is claimed. Packaging must preserve the corrected ios_system core; the older core used only for linking must not replace it.

## Terminal bridge `ashell:tty`, host evidence 2026-10-18 (task-79mc.512)

Host-only; the physical raw-mode check through ios_system is not done. Toolchain: Rust 1.96.1 from an owned rustup in `/private/tmp/wasmtime-tty-512/{rustup,cargo}` (`env.sh` there exports it), wasm-tools 1.262.0, target dir `/private/tmp/wasmtime-tty-512/target`. Commands are in `README.md`.

| Check | Result |
| --- | --- |
| Component imports `ashell:tty/tty@0.1.0` | `wasm-tools component wit` lists it beside stdin/stdout/environment 0.3.1 |
| RED: host at `e010fe2c` (no bridge) runs the tty component | exit 1: `component imports instance ashell:tty/tty@0.1.0, but a matching implementation was not found in the linker` |
| GREEN: `tty-contract` against the bridge host | 6/6 pass: no bridge → status 1; `SIZE=80x24 RAW=on KEYS=1b5b41 RAW=off` exact, status 0, no read in cooked mode, no EOF sent; return with raw on, trap, Ctrl-C (130) each leave the terminal cooked |
| Mutation: raw restore removed from the host | the return, trap and cancel checks fail; the others pass |
| Terminal handles (follow-up, same day): guest reads `wasi:cli` terminal-stdin/stdout/stderr | RED with the isatty callback present but host reporting false: both handle checks fail. GREEN after wiring `Tty.isatty` into each stream's `IsTerminal`: 7/7 pass, including stdout redirected with stderr on the terminal (`stdin:true stdout:false stderr:true`) and no bridge (all false) |
| Framework size, arm64 iOS 26.2, C1, stripped unsigned `P3Proof` | 9,936,528 bytes before; 9,969,696 with the first bridge (+33,168); 9,953,288 final with terminal handles and isatty (+16,760, +0.17%). Host `ashell-p3-host` on macOS, first bridge: 18,214,976 → 18,267,168 (+52,192) |

Raw mode on a-Shell, read from `a-Shell/ExtraCommands.swift` and `SceneDelegate+TerminalView.swift`: `ios_startInteractive` sets `interactiveCommandRunning`; while it is set (or the alternate buffer is active) the terminal writes each key straight to the command's stdin, otherwise it line-edits and sends on Enter, and Ctrl-C then calls `ios_kill()` instead of arriving as byte 3. ios_system sets the flag itself for native TUIs, and `p3proof_ios_main` already holds it for the whole command so the watcher sees Ctrl-C. No separate raw call exists or is needed, and `set-raw(false)` cannot return to line mode without losing that interrupt route. WasmKitCommand PR #2 makes the same `ios_startInteractive` call. The window size comes from `ios_getWindowSize`, which the app feeds with `ios_setWindowSize` and `COLUMNS`/`LINES`.

Open: a physical-device run of keys, Ctrl-C, size and leak with the final framework.
