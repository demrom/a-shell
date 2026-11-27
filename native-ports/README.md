# Native command payloads for a-Shell

These recipes build signed-app payloads, not terminal executables. The Xcode project and the stock command dictionaries do not reference unpublished frameworks. Use an owned copy of a-Shell mini for the trial. Do not use a phone build as a staging directory.

| Command | Source | Trial scope |
| --- | --- | --- |
| `gh` | GitHub CLI 2.106.0 (MIT) | `--version` and the upstream `api` command for `github.com`. Set `GH_TOKEN` (or `GITHUB_TOKEN`) in the shell if authenticating. No token store, telemetry, automatic refresh, desktop login, Git subprocesses, or other subcommands. Use a full desktop `gh` when those are required. |
| `monolith` | Monolith 2.12.0 (0BSD) | CLI document capture, including HTTP(S), local files and stdin. Asset retrieval is serial: the upstream Rayon pool does not own the command's `ios_system` streams. |
| `dua` | dua 3.0.3 (MIT) | CLI aggregation and traversal without the `tui-crossplatform` and `trash-move` features. Interactive mode needs an a-Shell terminal adapter for input, dimensions and raw-mode lifecycle; Crossterm expects a kernel tty. |

`native-ports/ci-framework.sh PRODUCT WORK_DIR ARTIFACT_DIR` builds and packages a device arm64 slice and a universal Simulator arm64/x86_64 slice. The hosted workflow runs the same command per product and uploads the ZIP, its checksum, build provenance and each thin binary's size. The pinned inputs and versions are in `ci-framework.sh` and `build.sh`. For a local port-edit loop, `native-ports/build.sh PRODUCT MATCHING_FRAMEWORKS PLATFORM BUILD_DIR` takes the existing `ios_system.framework` for that SDK and architecture. Use the shared a-Shell build lock and a private build directory.

## Acceptance

1. Download the named `native-PRODUCT` artifact from the exact successful workflow run, verify `PRODUCT.checksums.txt`, and unzip. Do not substitute a local slice and call it CI evidence.
2. Embed the Simulator slice into an owned compatible a-Shell mini app copy. For each command add `['PRODUCT.framework/PRODUCT', 'PRODUCT_ios_main', '', '']` to its `commandDictionary.plist` and the empty `bin/PRODUCT` discovery resource. Verify the `ios_system` import closure against that app before signing. Sign the staged app with the Simulator packaging process for the seed. Keep the seed unchanged.
3. Run `tests/native-PRODUCT.sh FRESH_WRITABLE_DIRECTORY` inside a-Shell mini, once directly and once via nested `dash`. Save stdout, stderr, exit status, elapsed time and the framework bytes. Also test Monolith with a controlled HTTP page and a separate asset; the checked-in fixture establishes local inlining and post-error re-entry only.
4. For a physical build, use the maintained phone packager to embed the device slices and retain its signed-app audit. Obtain the `local.herdr.hostbridge.a-Shell-mini` lease before installing; run the tests and read the fresh result files back. Restore build 585, verify the restored version and a fresh command result, then release the lease. If there is no qualified candidate or restore artifact, do not install anything.

Rollback for Simulator is to discard the owned staged app and reinstall the unchanged seed; none of these recipes mutate the seed or install on a device.
