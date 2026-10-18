# Pulley worker acceptance

This is a bounded feasibility probe, not a replacement for the installed interpreter. Runtime: Wasmtime 49.0.3, `pulley64`, stock p3 hosts. Guest WIT: released WASI 0.3.1. Record build/revision, target, device/OS, date and fresh result paths with each run. A host or Simulator result does not qualify the physical extension's memory limit.

| Contract | Required boundary | Expected result | Status |
| --- | --- | --- | --- |
| Released guest ABI | Component inspection | stdout/types imports and run export remain `@0.3.1` | PASS: wasm-tools 1.262.0 decode, 2026-10-18; runtime not yet exercised |
| First linking gate | Stock host CLI with Pulley | Exact `WASIP3_HELLO` plus LF, status 0; stop on mismatch without downgrading | PASS: stock host CLI exit 0, exact stdout, 2026-10-18 |
| Worker hello | Real a-Shell worker command | Same exact stdout/status, main app and worker remain alive | UNVERIFIED |
| Streamed HTTPS | Same worker, normal TLS validation | Status/body exact; first body marker arrives at least 1 s before completion of the public 3 s HTTPS drip | UNVERIFIED |
| Cancellation/re-entry | Same worker | In-flight request stops, next hello succeeds, stdio remains usable | UNVERIFIED |
| Worker memory | Physical device through assigned driver | Baseline/runtime/guest/TLS/cancel/repeat physical footprint and RSS receipts; proposed peak physical footprint <=28 MiB | UNVERIFIED |
| Compiler size comparison | Two matched release builds | Linked size and installed delta with and without Cranelift; trusted artifact compatibility recorded | UNVERIFIED |
| Install/rollback | Physical device through assigned driver | Owned package install and restore; preserve existing user data/session | UNVERIFIED |

Raw mode, terminal size/resize, interactive Unicode/editing, child spawn and TUI behavior are outside this first skeleton. Their later contract must use an explicitly named a-Shell extension where WASI has no interface; no success stub is accepted. Background/foreground, app kill/relaunch and long-term artifact migration remain unqualified until physical-device checks are added and run. The assigned phone driver owns every phone operation.

## Phone verdict criteria

The final report must end with GO or NO-GO and name these numbers and the corresponding evidence files. A host-only success leaves every phone criterion unverified. Failure at the first linking gate stops this proof as instructed.

| Number | Measurement | Evidence required | Status |
| --- | --- | --- | --- |
| 1 | Released WASI p3 hello and one streamed HTTPS request inside one worker | Exact stdout/status, TLS validation and first-chunk-to-completion interval >=1 s for the public 3 s HTTPS drip | UNVERIFIED |
| 2 | Cancellation kills the guest and the worker recovers | Cancel receipt followed by successful hello in the same worker | UNVERIFIED |
| 3 | Peak physical footprint <=28 MiB | Physical-device baseline and peak receipts across guest/TLS/cancel/repeat | UNVERIFIED |
| 4 | Added app size with and without Cranelift versus current WasmKit | Matched linked/installed app byte counts for all three configurations | UNVERIFIED |
| 5 | Cold start to first output | Physical-device monotonic timestamps with cold-state definition | UNVERIFIED |
| 6 | CPU-bound Preview1 guest under WasmKit and Pulley | Identical .wasm SHA-256, exact result and elapsed times on the same phone | UNVERIFIED |

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

Evidence files are `ffi-contract-c1.jsonl`, `ffi-contract-c2.jsonl`, `ios-c1-build.log`, `ios-c2-build.log`, `ios-c1-link.log` and `ios-c2-link.log` in the owned output directory. Framework bytes are measured build artifacts, not installed app deltas. The Preview1 CPU guest's 20,000,000-round checksum is `96d4bdf4`; Mac Pulley computation was approximately 0.23 s. Phone WasmKit/Pulley timing remains unverified.

The matched upstream WasmKitCommand/WasmKit baseline also builds for arm64 iOS 26.2: stripped unsigned framework 2,595,248 bytes, source wrapper unchanged, WasmKit submodule `4972ae620e25d7eaecaf6a08248b46c50b67d750`. Its build evidence is `wasmkit-build.log`. It is absent from the current mini candidate and must be added for the physical comparison.

## Cancellation fixture correction, 2026-10-18

Harness defect `task-5hct`: the public service caps delay plus duration at ten seconds. The old twenty-second request and a ten-second request with default two-second delay return HTTP 400. A first-body marker alone allowed an error-body cancellation race to pass. The corrected contract uses `duration=8&delay=0&numbytes=8&code=200`, requires HTTP 200 and an actual asterisk before cancellation, rejects completed bodies, and records those conditions. Old internal cancellation receipts and the original host worker pipe smoke do not qualify live-stream cancellation. Other measurements remain independent.

Corrected host C1/C2 contract receipts are `ffi-contract-c1-valid-cancel.jsonl` and `ffi-contract-c2-valid-cancel.jsonl`, with corresponding `.status` files requiring zero. Both pass exact hello, streamed HTTPS, cancellation of an unfinished HTTP 200 body with status 130, and exact same-runner hello recovery. The strengthened contract rejected the invalid ten-second fixture; those RED outputs are retained as `ffi-contract-c1-invalid-fixture-red.jsonl` and `ffi-contract-c2-invalid-fixture-red.jsonl`.

Physical C1 evidence from the assigned driver is partial acceptance: `c1-readback/c1.jsonl` records cold C entry to first output 0.079129 s, streamed body interval 2.928505 s, and peak physical footprint 6,538,816 bytes. Its internal cancellation remains disqualified. The independent real keyboard run requires `c1-keyboard8-before-cancel.txt` showing HTTP 200 and an asterisk, then `c1-readback/c1-keyboard8.status` = 130, `c1-recovered.status` = 0 with exact hello, and `c1-ordinary.txt` = `WORKER_RECOVERED`. These files live under the driver's `pulley-190` evidence directory. C2 and the complete matched size/CPU comparison remain pending; no final phone verdict is claimed here.
