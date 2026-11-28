# ripgrep-all package acceptance

The port runs upstream ripgrep-all 0.10.10 as an external AGPL WASI Preview 1 package. The app does not embed it. The `rga` command calls the packaged `rust-rg`, which invokes `rga-preproc` through the a-Shell worker process API. The app supplies PDFKit `pdftotext` and FFmpeg. DOCX and EPUB require the WasmKit-compatible Pandoc 3.10 package (the exception-translated payload, not the unmodified release module).

## Run on a-Shell mini

1. Install the arm64 Simulator app from the App build run for the combined PDFKit and worker-process host. PDFKit must be registered in the worker extensions as well as the main app.
2. Extract the verified commands CI catalog and this test directory into the test app's Documents. In a-Shell, set `PKG_SERVER` to the absolute `file://` URL of the catalog, then run `pkg install rga rga-preproc rust-rg`. Check the three installed `Documents/bin/*.wasm3` hashes against the catalog receipts; pkg's final status alone does not prove this.
3. Install the separately verified Pandoc dependency in the test app. The [upstream 3.10 WASI archive](https://github.com/jgm/pandoc/releases/tag/3.10) needs Binaryen 133 `--emit-exnref` without `--all-features`. The translated payload's SHA-256 is `a9a5b8bc0d485319a69647895bc18909533838f58a02c266bdaca6ddf039ed30`. Put the translated module at `~/Documents/bin/pandoc.wasm3` and use an executable `pandoc` launcher that calls `wasmkit "$HOME/Documents/bin/pandoc.wasm3" "$@"`.
4. From this test directory, run `dash check.sh acceptance-run`. Pull the receipt directory out of the app container. Require `result` to contain `PASS`, `resumed` to contain `shell-resumed`, and inspect the individual stdout, stderr, exit codes and start/end timestamps. An unmatched PDF search must return 1 without output; a preprocessor failure must not count as no match.

The authored fixtures contain the same `Second page` token, including the subtitle in `search.mp4`. Validate immutable inputs on the host with `(cd corpus && shasum -a 256 -c SHA256SUMS)`. The commands port retains its original release crate, patch and build recipe in the catalog `sources` directory.

## Verified Simulator run

The iPhone 17 / iOS 27.2 Simulator ran [signed Mini CI artifact 15265352515](https://github.com/demrom/a-shell/actions/runs/46150373455), built at `61dc1e256` on top of PDFKit commit `691093e13`, with [commands CI artifact 15266208954](https://github.com/demrom/a-Shell-commands/actions/runs/46152936495) at `5245f04d`. The catalog ZIP (2,811,681 bytes) and all three installed modules matched their published SHA-256 digests. The modules are 1,989,756 bytes (`rga`), 1,991,095 bytes (`rga-preproc`), and 2,160,120 bytes (`rust-rg`). `rga --version` printed `ripgrep-all 0.10.10`.

```text
corpus/search.txt:Second page
corpus/search.pdf:Page 2: Second page
corpus/search.docx:Second page
corpus/search.epub:Second page
corpus/search.zip:search.txt: Second page
corpus/search.txt.gz:Second page
corpus/search.tar:search.txt: Second page
corpus/search.mp4:00:00.000 --> 00:00.900: Second page
```

All eight searches returned 0 with empty stderr. The no-match PDF search returned 1 with empty stdout and stderr. At one-second timestamp resolution, PDF and MP4 took 1 s, DOCX and EPUB 2 s, and ZIP completed within one timestamp tick. The shell resumed after the contract.

Separately, a native Rust probe over [the PDFKit CI Mini](https://github.com/demrom/a-shell/actions/runs/45967725654) called `ios_popen("pdftotext -f 2 -l 2 sample.pdf -", "r")` and read the child's exact `Second page\n\n\x0c` stdout. This tests native dispatch; the WASI port uses the explicit worker process ABI instead.

This configuration disables the threaded on-disk cache and omits the SQLite and XZ adapters on WASI. Moving between catalog revisions in a disposable test container requires `pkg remove rga rga-preproc rust-rg` before reinstalling: the installer refuses to overwrite an existing different payload. On a leased physical iPhone, run the same CLI contract with a signed, matching Mini, pull the receipt bytes via CoreDevice, then restore build 585 and independently read back its installed version before releasing the lease. Do not use the Simulator app on a phone.
