# Embedded Herdr

The mini target embeds Herdr v0.9.3 (`7b116c05bfda646af39d2524c54e70c751f57ee8`). Its original Rust client, server, renderer and Ghostty terminal engine run inside the app. Each pane runs its shell in a Generic Non-UI extension worker through `ashell_pane_*`.

Install Rust 1.96.1 with the appropriate iOS target, Zig 0.16.0, Git and Xcode. Build the static archive before building the mini app:

```sh
rustup target add --toolchain 1.96.1 aarch64-apple-ios-sim
./Herdr/build.sh aarch64-apple-ios-sim
```

For a signed device build, select `aarch64-apple-ios` in both commands. The recipe downloads the pinned source, applies the adapter patches, builds with the locked dependencies and prints the archive checksum. `Herdr/build/` contains generated files and is ignored. Rerunning resets only the recipe's generated source checkout and preserves its build caches. Set `ZIG` to select a Zig executable or `ZIG_GLOBAL_CACHE_DIR` to use an existing package cache.

The mini target selects the archive matching its SDK, retains `herdr_ios_main` for command lookup, registers `herdr`, forwards terminal resize events and includes Herdr's Apache 2.0 license in the app resources. The worker pool requires iOS 26 or later and its matching ios_system and Dash prerequisites.

Run `herdr` in the app terminal. `herdr --version`, `--help`, `--skill` and `--default-config` write to the current command streams. Other desktop CLI operations return status 78. One embedded Herdr instance owns the host terminal at a time; another returns status 16. The client and server communicate through an in-process socket pair during that command. There is no detached background server or desktop IPC service.

The adapter forwards pane input, output, geometry, exit status, interrupts and close to the pool. Cwd defaults to the current command directory and pane calls are serialized per worker handle. Restored container paths are relocated under the current app home. Worker capacity, termination and recovery follow the pool contract in `ShellWorkers/NativePane.h` and the root README.

To check an installed disposable Simulator app, install AXe and jq, start with a fresh shell in a portrait iPhone Simulator and keep Herdr's default keybindings and tab-name prompts. Run:

```sh
./Herdr/tests/three-panes.sh SIMULATOR_UDID APP_BUNDLE_ID URL_SCHEME
```

The harness starts Herdr, dismisses the first-run welcome and optional integrations screens, then enters commands through the public terminal UI with paced keystrokes. It checks that pane A answers from the same worker after 15 seconds of idle time. It confirms the new tab names and requires three distinct live workers belonging to the installed app. Each pane runs the same native AWK workload from a separate directory with its own environment marker and relative file. The host releases all three together and requires the conservative sum of their CPU time to exceed the elapsed wall time. In the last pane, idle Ctrl-D must leave the shell alive and foreground Ctrl-D must end `cat` with the exact input and status zero. A follow-up command must run in the original worker. The check attempts detach even when a pane PID receipt is missing, then types a host-shell check and `herdr --version` into the same terminal without restarting the app. Direct runs leave receipts in the app's Documents directory; failures print the receipts before the CI wrapper deletes the Simulator. The mini Simulator matrix uses `bash tests/simulator-app.sh APP Herdr/tests/three-panes.sh ashellmini --confirm-open` to install an ad hoc signed copy and authorize its public URL route before the test.

Pane cancellation, physical-device behavior, application backgrounding, saved-session migration and worker WASM routing require separate qualification.
