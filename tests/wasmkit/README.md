# WasmKitCommand smoke test

Run `bash scripts/build-wasmkit-command.sh --smoke` with Xcode 26.6 or newer. Omit `--smoke` to package without booting a Simulator. The ZIP, SwiftPM checksum, slice report and logs are under `.build/wasmkit-command/dist/` by default.

The smoke test unpacks the ZIP and runs `wasmkit hello.wasm` through the real `ios_system` dispatcher. It checks the guest's stdout and exit status. The runner does not link WasmKitCommand directly, just as the app loads it only when dispatching the command.

Use the same ZIP for full and mini. Both must embed an `ios_system` with `ios_startInteractive` (the recipe uses v3.0.6; v3.0.5 lacks the symbol). Keep the app's existing iOS 18 availability check: the framework targets iOS 18, but neither app target has to move to iOS 18.
