# WASI 0.3.1 / Pulley first gate

This probe runs a real guest generated from the released WASI 0.3.1 WIT against Wasmtime 49.0.3's stock p3 host bindings. The host selects `pulley64`; its CLI process exposes guest stdout and reports instantiation or execution errors through its exit status. It does not prove iOS support, worker memory use, HTTPS or cancellation.

The first gate must pass before adding the worker runtime. If the released guest cannot link, retain the error and stop; do not rename its interfaces or downgrade its WIT.

`guest/wit/deps` contains unmodified CLI WIT and its dependencies from the central `WebAssembly/WASI` v0.3.1 release archive, SHA-256 `319d0eacc2d7abb8d5ccc44ac0e5c0d1ea0ebd8098ec83569aced46dbf9eb3e8`. These definitions, rather than an RC snapshot, determine the guest ABI. Guest bindings use wit-bindgen 0.61.1. Host crates use Wasmtime 49.0.3 without source patches.

With Rust 1.96.1, the `wasm32-unknown-unknown` standard library, and wasm-tools 1.262.0 available, run from this directory:

```sh
export CARGO_TARGET_DIR=/absolute/path/to/owned/target
nice -n 15 cargo build --manifest-path guest/Cargo.toml --locked --release --target wasm32-unknown-unknown -j 2
wasm-tools component new "$CARGO_TARGET_DIR/wasm32-unknown-unknown/release/ashell_p3_hello.wasm" -o "$CARGO_TARGET_DIR/hello.component.wasm"
wasm-tools component wit "$CARGO_TARGET_DIR/hello.component.wasm"
nice -n 15 cargo build --manifest-path host/Cargo.toml --locked --release -j 2
"$CARGO_TARGET_DIR/release/ashell-p3-host" "$CARGO_TARGET_DIR/hello.component.wasm" > "$CARGO_TARGET_DIR/hello.stdout"
printf 'WASIP3_HELLO\n' > "$CARGO_TARGET_DIR/hello.expected"
cmp "$CARGO_TARGET_DIR/hello.expected" "$CARGO_TARGET_DIR/hello.stdout"
```

Builds require the lead's heavy slot and more than 10 GiB free space. The phone is driven separately by the assigned phone owner. No iOS install/run command belongs to this first host gate.

## Exported worker boundary

`host` also builds a Rust static library. `include/ashell-p3.h` declares its caller-owned runner and output callbacks. `entry.c` owns one active command per process. `worker.c` passes ios_system's invoking-thread streams, reads Ctrl-C through the worker's existing input descriptor, disables pthread cancellation while Rust is active, and restores the previous interactive mode before returning. No process descriptors are replaced. Guest stdin is EOF in this slice; typed bytes other than Ctrl-C are discarded.

`ffi-contract.c` exercises the exported C ABI with real guests. It checks exact hello, an HTTPS 200 body of six asterisks, at least one second between first body output and completion of the three-second drip, cancellation returning 130, and exact hello again on the same runner. The external fixture is `httpbingo.org`; the guest sends a descriptive User-Agent and uses the stock host's public TLS roots. Request timeouts are bounded. The initial request without a User-Agent returned 402; it is not a Wasmtime defect.

On Apple platforms the contract records `TASK_VM_INFO` physical footprint, ledger peak physical footprint, current RSS and peak RSS at baseline, engine creation, hello, HTTPS, cancellation and recovery. The cold hello timer starts at the C contract entry, before engine creation, and ends at the first output callback. Start a fresh worker process for a cold measurement. App launch and XPC dispatch are outside this timer and need separate driver timestamps if included in the reported result.

## Build the two runtime variants

Set `CARGO_TARGET_DIR` to an owned absolute directory and `proof` to this source directory. All builds require the lead's heavy slot, nice 15, jobs 2 and more than 10 GiB free. The commands use locked dependencies and Rust 1.96.1. They install no tools.

Build hello first as above, preserving `hello.component.wasm` before the HTTPS feature overwrites the guest library output:

```sh
nice -n 15 cargo build --manifest-path "$proof/guest/Cargo.toml" --locked --release --target wasm32-unknown-unknown --features https -j 2
wasm-tools component new "$CARGO_TARGET_DIR/wasm32-unknown-unknown/release/ashell_p3_hello.wasm" -o "$CARGO_TARGET_DIR/https.component.wasm"
nice -n 15 cargo build --manifest-path "$proof/cpu/Cargo.toml" --locked --release --target wasm32-wasip1 -j 2
mkdir -p "$CARGO_TARGET_DIR/c1" "$CARGO_TARGET_DIR/c2"
nice -n 15 cargo build --manifest-path "$proof/host/Cargo.toml" --locked --release -j 2
cp "$CARGO_TARGET_DIR/release/libashell_p3_host.a" "$CARGO_TARGET_DIR/c1/"
cp "$CARGO_TARGET_DIR/release/ashell-p3-host" "$CARGO_TARGET_DIR/c1/"
"$CARGO_TARGET_DIR/c1/ashell-p3-host" compile "$CARGO_TARGET_DIR/hello.component.wasm" "$CARGO_TARGET_DIR/hello.cwasm"
"$CARGO_TARGET_DIR/c1/ashell-p3-host" compile "$CARGO_TARGET_DIR/https.component.wasm" "$CARGO_TARGET_DIR/https.cwasm"
"$CARGO_TARGET_DIR/c1/ashell-p3-host" compile "$CARGO_TARGET_DIR/wasm32-wasip1/release/ashell-cpu-proof.wasm" "$CARGO_TARGET_DIR/cpu.cwasm"
nice -n 15 cargo build --manifest-path "$proof/host/Cargo.toml" --locked --release --no-default-features -j 2
cp "$CARGO_TARGET_DIR/release/libashell_p3_host.a" "$CARGO_TARGET_DIR/c2/"
cp "$CARGO_TARGET_DIR/release/ashell-p3-host" "$CARGO_TARGET_DIR/c2/"
```

C1 includes Cranelift and accepts ordinary WebAssembly. C2 excludes Cranelift and requires an explicit `--trusted-precompiled` argument. Wasmtime deserialization is an unsafe trust boundary: use only artifacts produced by the exact trusted version/configuration, with recorded hashes. Never use that argument for untrusted downloads. Compiling Pulley on the Mac does not change the guest WIT version.

For each host variant, link the same C contract with its saved static library:

```sh
nice -n 15 clang -O2 "$proof/ffi-contract.c" "$CARGO_TARGET_DIR/c1/libashell_p3_host.a" -framework Security -framework SystemConfiguration -o "$CARGO_TARGET_DIR/c1/ffi-contract"
"$CARGO_TARGET_DIR/c1/ffi-contract" "$CARGO_TARGET_DIR/hello.component.wasm" "$CARGO_TARGET_DIR/https.component.wasm" httpbingo.org
nice -n 15 clang -O2 "$proof/ffi-contract.c" "$CARGO_TARGET_DIR/c2/libashell_p3_host.a" -framework Security -framework SystemConfiguration -o "$CARGO_TARGET_DIR/c2/ffi-contract"
"$CARGO_TARGET_DIR/c2/ffi-contract" --trusted-precompiled "$CARGO_TARGET_DIR/hello.cwasm" "$CARGO_TARGET_DIR/https.cwasm" httpbingo.org
```

For iOS, build `host` with `--lib --target aarch64-apple-ios` and `IPHONEOS_DEPLOYMENT_TARGET=26.2`, once with default features and once with `--no-default-features`. Save each archive before the second build overwrites it. Then run `link-framework.sh STATICLIB OWNED-OUTPUT IOS-SYSTEM-FRAMEWORK` for each variant. It links and strips an arm64 iOS 26.2 `P3Proof.framework`, exporting `p3proof_ios_main` and `p3contract_ios_main`. It does not sign or install. The ios_system framework is an owned copy of the phone candidate's matched core; keep its hash in the receipt. Both variants must use identical SDK, deployment target, core and link settings.

## Phone driver handoff

The assigned phone driver owns packaging, signing, installing, terminal actions, readback and rollback. Add only one `P3Proof.framework` variant to the candidate's Frameworks directory at a time. Register `p3proof` as `[@rpath/P3Proof.framework/P3Proof, p3proof_ios_main, "", no]` and `p3contract` with the same framework and `p3contract_ios_main` in the host and worker command dictionaries, including the existing empty PATH lookup files. Preserve the candidate's core and command implementations. Resign the copied candidate and verify signatures/dependency closure before installing. Restart the app and use a fresh worker between variants; never load two copies under the same framework name in one process.

Transfer the hello and HTTPS components, their trusted compiled artifacts, and the single Preview1 CPU `.wasm` with hashes to one disposable phone directory. Keep the CPU `.wasm` byte-identical for WasmKit and Pulley. In a real worker, record command status and files for:

```sh
p3contract hello.component.wasm https.component.wasm httpbingo.org > c1.jsonl 2> c1.stderr
p3proof hello.component.wasm
p3proof https.component.wasm httpbingo.org '/drip?duration=20&numbytes=20&code=200'
# Send a real Ctrl-C to this worker after HTTP_FIRST; require status 130.
p3proof hello.component.wasm
printf 'WORKER_RECOVERED\n' > recovered.txt
p3proof ashell-cpu-proof.wasm 20000000 > pulley-cpu.txt
wasmkit ashell-cpu-proof.wasm 20000000 > wasmkit-cpu.txt
```

For C2 use `p3contract --trusted-precompiled hello.cwasm https.cwasm httpbingo.org`, and `p3proof --trusted-precompiled` with the corresponding artifacts. CPU output must report rounds 20000000 and checksum `96d4bdf4`; compare `CPU_NS` on the same physical phone. Also retain outer command elapsed times. The contract's in-flight cancel and same-runner recovery supplement the real keyboard interrupt and next ordinary shell command; they do not replace those checks.

The current mini candidate has no WasmKit framework. Build the unchanged WasmKitCommand wrapper at the recorded upstream commit, with its pinned WasmKit submodule `4972ae620e25d7eaecaf6a08248b46c50b67d750`, the same matched ios_system and iOS 26.2 deployment target. Its Xcode project expects `ios_system.xcframework` at the checkout root. Use owned DerivedData/package clones, Release, `-jobs 2`, nice 15 and locked package versions. Register its stock `wasmkit` entry through `WasmKitCommand.framework` for the baseline. Do not call an unavailable-command stub a benchmark.

Measure regular-file bytes of each signed candidate and record installed app size separately if available. Report both the absolute addition to the current mini candidate and the difference against the matched WasmKit baseline. A framework archive's size is neither an installed app delta nor a memory measurement. Restore the driver's saved signed candidate after the proof and verify the next ordinary command. Complete all six numbered rows in `acceptance.md` with physical-device evidence before issuing the GO/NO-GO verdict.
