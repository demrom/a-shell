# App build matrix

`.github/workflows/app-build.yml` builds the existing `a-Shell-noPython`, `a-Shell-mini` and `a-Shell` targets for generic iOS (arm64) and iOS Simulator (arm64 and x86_64 in the same app). The matrix builds unsigned apps, checks their executable architectures and verifies PhotosUI linkage. The noPython Simulator job then ad hoc signs disposable copies of the app and checks the public command URL callback, the cloud-file and font commands, native terminal interactive state, original JPEG/MP4 Photos bytes, cached video format detection (`ffprobe`) and cache reuse, exact WebView WebAssembly stream redirection, and the relay on loopback. A native Simulator consumer checks failed pane-spawn descriptor cleanup against the pinned ios_system ABI. These are Simulator checks, not signing or behavior qualification on a physical device. A separate host job runs the staging, Photos and iCloud download regressions. Use a `ci/app-build-*` branch for a fork run without updating its default branch. CI defaults to `macos-26-intel`; a manual dispatch can set `runner` to `macos-26` to use an Arm64 host instead. This does not change the app architectures.

Use Xcode 26.6 and uv from a clean, dedicated checkout:

```sh
uv run ci/build-app.py build a-Shell-noPython device
uv run ci/build-app.py build a-Shell-noPython simulator
```

Use `prepare` instead of `build` to verify and install the inputs without compiling. Add `--dry-run` to list the selected installation paths without downloading or replacing files. Repeated runs verify cached archives and replace only outputs the script previously installed. Do not use a checkout populated by `downloadFrameworks.sh` or another framework installation. The script leaves `project.pbxproj` unchanged. The build produces apps under `.build/app/`, and the job summary lists each unavailable framework path, including inputs of dependent targets. The workflow also attaches the same summary as a text artifact.

## Update an input

`xcfs/frameworks.json` owns the pins. `releases` contains the published SwiftPM ZIPs and their SHA-256 digests. `artifacts` groups exact `.xcframework.zip` members by fork Actions archive; each record pins the archive URL, SHA-256, producer run attempt and source revision. A release is preferred if it contains the job's full architecture set. The resolver tries the pinned fork artifact if the release lacks a compatible slice; a checksum failure never falls back. Compatibility is checked against both the xcframework's `Info.plist` and its Mach-O architectures.

Fill in a pending input by adding the exact artifact member to its producer archive's `frameworks` map. For a new producer run, verify the outer archive digest and audit the inner ZIP and its binaries before changing a pin. Actions archives expire; replace an unavailable archive with a verified upstream release when published or with a new qualified artifact pinned to its exact run attempt. `extra` lists link inputs specified through build settings rather than file references. `resources` lists non-framework runtime files supplied by the same producer archives.

After changing a release pin, regenerate and check the existing release-only SwiftPM package:

```sh
uv run ci/build-app.py package > xcfs/Package.swift
uv run ci/build-app.py package --check
```

Run `bash tests/app-frameworks.sh` to check the staging CLI's missing-input summary, universal Simulator fallback, rerun and checksum failure behavior without network downloads. For the post-build URL check and its local invocation, see [URL logging](../tests/url-logging/README.md). Install AXe using that guide and put it on `PATH` for all the local Simulator commands below. Run `bash tests/simulator-interactive-state.sh APP` to check the app's native terminal callbacks and command reentry. Use `bash tests/simulator-app.sh APP tests/simulator-app-commands.sh commands FONT` with the [font fixture](../tests/fonts.md), or `bash tests/simulator-app.sh APP tests/simulator-app-commands.sh wasm WASM` with the [compiled WASM fixture](../tests/wasm-output.md). The `bundled-font` mode takes the same font fixture and a disposable app copy whose `UIAppFonts` already lists that font. For `photos`, decode `tests/fixtures/photos-cache.{jpg,mp4}.base64` with `/usr/bin/base64 -D -i INPUT -o OUTPUT`, and run `bash tests/simulator-app.sh APP tests/simulator-app-commands.sh photos OUTPUT.jpg OUTPUT.mp4` with `ffprobe` on `PATH`. The test verifies both imported originals byte for byte before and after a second sync, checks that the video is readable by `ffprobe`, and checks that cache metadata does not change. Omit the MP4 only to run the image-only check. Use `bash tests/simulator-app.sh APP tests/simulator-relay.sh true` with OpenSSL 3 for the loopback relay with client certificates, or `false` for token-only mode. Each run uses a fresh Simulator. If another Simulator app owns the WASM listener port, change `WasmServerPort` in `Info.plist` of a disposable copy before pointing the driver at it. Do not stop another Simulator to free its port.

After a mini Simulator build, run `bash tests/simulator-app.sh APP Herdr/tests/three-panes.sh ashellmini --confirm-open` for the terminal flow or `bash tests/simulator-worker-pool.sh APP IOS_SYSTEM_FRAMEWORK` for the native extension consumer. Pass the Simulator `ios_system.framework` that supplied the app build, including its headers. The native driver adds its command registrations only to the disposable copy.

After a full Simulator build, run `bash tests/simulator-app.sh APP tests/simulator-cbc.sh tests/cbc/small.lp` to solve the reference LP through the app's startup profile. For Codex, run `bash tests/simulator-codex.sh APP terminal` for the CLI checks, `bash tests/simulator-codex.sh APP login-logging` for both direct-login log paths, or `bash tests/simulator-codex.sh APP transport` for the tool transport checks. The login test rejects authentication by policy, and the transport test uses a loopback Responses fixture. Both use a disposable `CODEX_HOME` and require no credentials.
