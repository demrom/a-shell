# Real media workload comparison

Keep both native implementations. On this Mac, WasmKit takes 18.77 times the native FFmpeg median and 8.73 times the native ImageMagick median. Pulley takes 55.25 times the native ImageMagick median. WasmKit is the fastest tested engine that runs each current guest. ImageMagick could be an optional pkg download when the runtime is already present and the user accepts the slowdown; replacing the native command by default is not justified by these results. FFmpeg's guest alone is larger than native, and its currently tested threads launcher cannot run on iOS.

This experiment compares size-oriented builds of current FFmpeg and ImageMagick on the arm64 Mac. It does not install phone commands or qualify iPhone execution. The lead owns the shared build slot; run only one build at a time, at nice 15 with two jobs and more than 10 GiB free space.

## Pinned inputs

| Input | Version or revision | Archive SHA-256 |
| --- | --- | --- |
| FFmpeg | 9.0.2 | `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` |
| ImageMagick | 7.1.2-34 | `f5163a573a1c1bff16358d0a592b2fb168ad0fd3b9dc5ff57dc7820eebc5cf79` |
| libpng | 1.6.59 | `2540302a1844ad2b2b501977abecfa850f265f97b78f065a712ab4074a89f5b5` |
| zlib | 1.3.2 | `bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16` |
| wasi-sdk | 34.0, arm64 macOS | `9c59398106b417f8f14913380fdf0097a8cc0ff4af9eb3ce0065a859e88d49e9` |
| WasmKit source | `4972ae620e25d7eaecaf6a08248b46c50b67d750` in the existing WasmKitCommand checkout | Git revision |
| WasmKitCommand stream shim | `f28b95d1c5877a7de2587c53054bdffd7f3ca953` | Git revision |
| Wasmtime C1 baseline | 49.0.3, Pulley interpreter opt-level 3 | Binary SHA-256 `dca469ab595848622f76bdcb0d38b52cbe046893ad6097c070d5f296894bdb68` |

The native compiler is Apple clang 21.0.0 (`clang-2100.3.34.2`); wasi-sdk uses clang 23.1.0. The host is arm64 macOS 26.6.2, build 25G83. The benchmark tool is hyperfine 1.20.0. Every measured command is a fresh process; its time includes runtime startup, Wasm parsing/translation, real file I/O and execution. One warmup precedes five measured runs. Disk caches remain warm. The pinned WasmKit fork emits existing WASI diagnostics through NSLog; those are part of this runtime's measured behavior.

## Build and reproduce

Choose a disposable absolute cache directory. Download the SDK from its official release and verify it before extraction:

```sh
cache=/private/tmp/media-comparison
mkdir -p "$cache"
curl -fLsS https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-34/wasi-sdk-34.0-arm64-macos.tar.gz -o "$cache/wasi-sdk.tar.gz"
echo "9c59398106b417f8f14913380fdf0097a8cc0ff4af9eb3ce0065a859e88d49e9  $cache/wasi-sdk.tar.gz" | shasum -a 256 -c -
tar -xf "$cache/wasi-sdk.tar.gz" -C "$cache"
bash tests/wasmtime-proof/media/ffmpeg-build.sh "$cache" wasi
bash tests/wasmtime-proof/media/ffmpeg-build.sh "$cache" native
```

The recipes verify source archives and retain configuration and build logs. FFmpeg needs no source patch. ImageMagick uses the adjacent narrow platform patch. Both FFmpeg builds use `--optflags=-Oz`, LTO, no debug information, no assembly, no autodetected external libraries, file I/O only, rawvideo AVI input, scale/format filters, and MPEG-4 AVI output. Disabling assembly keeps this comparison on the same C implementation; a production native build with assembly may be faster. This small codec set does not replace a general-purpose FFmpeg installation.

ImageMagick uses Q8 without HDRI, LTO and `-Oz`, static PNG/zlib, no OpenMP/OpenCL/POSIX threads, and no external delegates or other optional format libraries. Its native executable retains only system dylib dependencies. This is a PNG resize/conversion build, not a replacement for the full ImageMagick feature set.

FFmpeg 9 requires threads even for its CLI. A thread-free configure attempt exits successfully but silently disables `CONFIG_FFMPEG`. The working target is `wasm32-wasip1-threads`, with `-pthread`, imported shared memory and a declared 256 MiB maximum. The maximum is a virtual memory growth limit, not a measured footprint or approval to exceed an iOS worker budget. The SDK supplies its documented signal and process-clock compatibility libraries. These do not provide asynchronous POSIX signals. No success-returning compatibility functions were invented.

Build the existing pinned WasmKit CLI with the same host shim already used by the command's host tests. `wrapper` names the existing WasmKitCommand checkout at the revisions above:

```sh
wrapper=/absolute/path/to/WasmKitCommand
cp "$wrapper/tests/command-host/Package.resolved" "$wrapper/WasmKit/Package.resolved"
xcrun clang -mmacosx-version-min=15.0 -c -fobjc-arc "$wrapper/tests/command-host/Sources/ios_system/streams.m" -I "$wrapper/tests/command-host/Sources/ios_system/include" -o "$cache/streams.o"
nice -n 15 swift build --package-path "$wrapper/WasmKit" --scratch-path "$cache/wasmkit-build" --cache-path "$cache/swift-cache" -c release --product wasmkit-cli --force-resolved-versions -j 2 -Xswiftc -num-threads -Xswiftc 2 -Xswiftc -I -Xswiftc "$wrapper/tests/command-host/Sources/ios_system/include" -Xlinker "$cache/streams.o"
```

Generate the fixed input with the installed native FFmpeg 9.0.2. That installation supplies the synthetic source filter, which is intentionally absent from the measured small codec build:

```sh
mkdir -p "$cache/fixtures"
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x180:rate=15:duration=10 -an -c:v rawvideo -pix_fmt yuv420p -threads 1 -y "$cache/fixtures/input.avi"
bash tests/wasmtime-proof/media/ffmpeg-check.sh "$cache"
```

The input SHA-256 is `956fb7fee25722e40df2e14360a50c1ea6b4ce1d4724dbf09e6362b18ab0d85a`. Both measured builds produce exactly the same 200,434-byte AVI: SHA-256 `7229e72cc41fd5b79205a2be79a50b8004d6c39cc704e5e6ff3c9b3fa9f7aeed`. The check also uses ffprobe to verify 150 MPEG-4 frames at 160x90 over ten seconds. Hyperfine fails on a nonzero exit. No timing row is accepted while another build overlaps it.

## Results and recommendation

Measured on 2026-10-18, with one warmup and five successful fresh processes per row:

| Workload | Runtime | Median (ms) | Min (ms) | Max (ms) |
| --- | --- | ---: | ---: | ---: |
| FFmpeg 9 transcode | Native | 34.309 | 32.889 | 44.049 |
| FFmpeg 9 transcode | WasmKit threads CLI | 643.878 | 633.967 | 679.735 |
| FFmpeg 9 transcode | Pulley C1 baseline / gc-null | Not runnable: WASI threads unavailable | - | - |
| ImageMagick PNG resize/convert | Native | 182.850 | 179.258 | 185.448 |
| ImageMagick PNG resize/convert | WasmKit command wrapper | 1596.695 | 1579.791 | 1668.269 |
| ImageMagick PNG resize/convert | Pulley C1 opt3 + gc-null + P1 preopen | 10102.199 | 9861.456 | 10647.403 |
| ImageMagick PNG resize/convert | Unchanged Pulley C1 baseline | Not runnable: standard exceptions disabled | - | - |

[ffmpeg-benchmark.json](ffmpeg-benchmark.json) and [imagemagick-benchmark.json](imagemagick-benchmark.json) retain all samples and exit codes. Process checks before and after each benchmark found no heavy build. An earlier FFmpeg timing window overlapped another build and is excluded. Every AVI passes ffprobe's frame/codec/dimension/duration checks; every PPM has the expected dimensions and depth and matches native byte for byte. [verification.json](verification.json) records output hashes and the RED/GREEN evidence.

### Artifact sizes

Bytes below are stripped files and `gzip -n -9 -c` output. Mach-O files include an ad-hoc signature. Runtime rows are Mac executables; they are not iOS framework sizes, installed app deltas or memory measurements. Guest sizes include statically linked codec/dependency code. A runtime can serve multiple programs, so its cost depends on whether it is already installed.

| Artifact | Stripped bytes | gzip bytes |
| --- | ---: | ---: |
| Native FFmpeg | 1,525,872 | 723,504 |
| FFmpeg WASI threads guest | 1,986,883 | 750,809 |
| Native ImageMagick Q8 + PNG/zlib | 2,566,192 | 1,384,286 |
| ImageMagick WASI Q8 + PNG/zlib guest | 3,717,935 | 1,112,387 |
| WasmKit command wrapper runtime | 2,720,688 | 958,867 |
| WasmKit threads CLI runtime | 3,667,280 | 1,331,978 |
| Pulley C1 baseline runtime | 18,952,192 | 5,959,155 |
| Pulley C1 gc-null + P1 preopen runtime | 19,020,032 | 5,982,623 |

[artifact-sizes.json](artifact-sizes.json) records hashes and cache paths. Size-only stripped copies of the WasmKit wrapper, threads CLI and native FFmpeg were checked separately; timings use the original wrapper/CLI/native FFmpeg binaries identified in verification.json. ImageMagick native and the measured gc-null Pulley binary were stripped before timing. Native FFmpeg's extra ad-hoc signature accounts for its size difference from the measured build product.

## Runtime qualification

The current Pulley C1 runtime has no WASI threads host implementation, so this FFmpeg 9 guest is not runnable there. FFmpeg 6.1.6 was downloaded but not built; it is not the main comparison. The pinned WasmKit WASI threads launcher currently supports macOS/Linux only and requires direct threading with mprotect memory bounds checking. Its source explicitly rejects iOS. The a-Shell WasmKit command wrapper also does not yet link that launcher. A successful Mac result does not establish phone compatibility.

ImageMagick builds and performs the actual PNG resize/conversion under all three measured runtimes. Its PNG coder calls setjmp/longjmp, so disabling libpng's jump support is not a valid substitute. A real small WASI probe passes with WasmKit using `-mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false -lsetjmp`; the SDK's default legacy exception encoding is rejected. LTO additionally requires the matching backend options on wasm-ld. The guest needs a 1 MiB C stack: the real resize traps with the SDK's default 64 KiB stack and passes after relinking with `-z stack-size=1048576`.

The ImageMagick patch guards absent `sys/wait.h` and `pwd.h` using configure's existing capability macros, omits the unused popen wrapper when popen is unavailable, and disables account-database expansion of `~other-user` when its header is absent. Ordinary `~` expansion through HOME remains. External delegates reuse ImageMagick's existing unsupported-platform failure path. No shell, subprocess or pipe execution is implemented. The SDK provides its signal, process-clock and getpid compatibility libraries; the latter supplies a placeholder ID, not a host process identity. The valid-file benchmark does not qualify concurrency, process ownership, external delegate execution or temporary-file isolation across guest instances.

The unchanged Pulley C1 baseline rejects standard exceptions because its stock Wasmtime `gc` feature is absent. The measured host-only variant enables the stock `wasmtime/gc-null` feature. It also gives Preview1 the root filesystem preopen already used by Preview2. Before that change, the actual resize exits 1 with `UnableToOpenBlob`; afterwards it exits 0 and produces the native output bytes. This preopen uses host permissions and is not an additional filesystem sandbox. Phone filesystem access and this runtime variant remain unqualified.

## Reproduce ImageMagick and the Pulley variant

Use the SDK/cache above and the existing command-host Runner binary built from the pinned WasmKitCommand revision. The benchmark uses that existing wrapper for thread-free ImageMagick, and the stock threads CLI for FFmpeg. `wasmtime` below is an owned copy of this proof host's `ashell-p3-host` executable, named for the command interface being integrated separately; it does not claim an installed a-Shell command or framework. It accepts the bare `wasmtime file.wasm args` form.

```sh
bash tests/wasmtime-proof/media/imagemagick-build.sh "$cache" wasi
bash tests/wasmtime-proof/media/imagemagick-build.sh "$cache" native
MAGICK_THREAD_LIMIT=1 magick -size 2048x1536 gradient:'#173f5f-#ed553b' -fill '#3caea3' -draw 'circle 1024,768 1700,768' -fill '#f6d55c' -draw 'rectangle 240,260 800,1180' -strip "$cache/fixtures/input.png"
mkdir -p "$cache/runtimes"
cp /absolute/path/to/command-host/release/Runner "$cache/runtimes/wasmkit"
export CARGO_TARGET_DIR=/absolute/path/to/owned/cargo-target
nice -n 15 cargo build --locked --release --manifest-path tests/wasmtime-proof/host/Cargo.toml --features wasmtime/gc-null -j 2
cp "$CARGO_TARGET_DIR/release/ashell-p3-host" "$cache/runtimes/wasmtime"
strip -S -x "$cache/runtimes/wasmtime"
codesign --force --sign - "$cache/runtimes/wasmtime"
codesign --verify --strict "$cache/runtimes/wasmtime"
bash tests/wasmtime-proof/media/imagemagick-check.sh "$cache"
```

The input PNG SHA-256 is `1d52f455f2db71d383d3216e28c106971df71dfb664fbaf24ab21a7f907866d8`; its generator is the installed ImageMagick 7.1.2-34 Q16-HDRI command, separate from the measured Q8 build. Each result is a 1024x768 8-bit RGB PPM with SHA-256 `ea54d98e780fb40c683fae132e2767b2296a595c507c17a3d6b5b38ab166ce46`. Existing files are overwritten only within the chosen cache. Guest/runtime hash changes require requalification.

To recreate the command-host release Runner, follow the package assembly in the pinned wrapper's `tests/preopens.sh`, replacing its debug build with release:

```sh
hostout="$cache/command-host"
mkdir -p "$hostout/host/Sources/WasmKitCommand"
cp "$wrapper/tests/command-host/Package.swift" "$wrapper/tests/command-host/Package.resolved" "$hostout/host/"
cp -R "$wrapper/tests/command-host/Sources/Runner" "$hostout/host/Sources/"
cp "$wrapper/WasmKitCommand.swift" "$hostout/host/Sources/WasmKitCommand/"
WASMKIT_SOURCE="$wrapper/WasmKit" nice -n 15 swift build --package-path "$hostout/host" --scratch-path "$hostout/build" -c release -j 2 --force-resolved-versions -Xswiftc -num-threads -Xswiftc 2 -Xswiftc -I -Xswiftc "$wrapper/tests/command-host/Sources/ios_system/include" -Xlinker "$cache/streams.o"
cp "$hostout/build/release/Runner" "$cache/runtimes/wasmkit"
```

For the size-only Mach-O rows, copy the native FFmpeg, wrapper and threads CLI binaries, apply `strip -S -x COPY`, then `codesign --force --sign - COPY` and `codesign --verify --strict COPY`. ImageMagick's native recipe and the Pulley command above already strip/sign their executable. Measure file bytes and `gzip -n -9 -c FILE | wc -c`; exact signed hashes can change with the output path/toolchain.
