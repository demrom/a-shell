# ripgrep-all package acceptance

The port runs upstream ripgrep-all 0.10.10 as an external AGPL WASI Preview 1 package. The app does not embed it. The `rga` command calls the packaged `rust-rg`, which invokes `rga-preproc` through the a-Shell worker process API. The app supplies PDFKit `pdftotext` and FFmpeg. The WASI `office` adapter extracts DOCX body text and EPUB XHTML text in spine order from ZIP members, without launching Pandoc. This is search text, not a full-fidelity conversion; e.g., DOCX footnotes, headers and comments are not indexed. The desktop Pandoc adapter is unchanged.

## Run on a-Shell mini

1. Install the arm64 Simulator app from the App build run for the combined PDFKit and worker-process host. PDFKit must be registered in the worker extensions as well as the main app.
2. Extract the verified commands CI catalog and this test directory into the test app's Documents. In a-Shell, set `PKG_SERVER` to the absolute `file://` URL of the catalog, then run `pkg install rga rga-preproc rust-rg`. Check the three installed `Documents/bin/*.wasm3` hashes against the catalog receipts; pkg's final status alone does not prove this.
3. From this test directory, run `dash check.sh acceptance-run`. Pull the receipt directory out of the app container. Require `result` to contain `PASS`, `resumed` to contain `shell-resumed`, and inspect the individual stdout, stderr, exit codes and start/end timestamps. An unmatched PDF search must return 1 without output; a preprocessor failure must not count as no match.

The authored fixtures contain the same `Second page` token, including the subtitle in `search.mp4`. Validate immutable inputs on the host with `(cd corpus && shasum -a 256 -c SHA256SUMS)`. The commands port retains its original release crate, patch and build recipe in the catalog `sources` directory.

## ZIP/XML adapter Simulator run

The same signed Mini ran the local `3c6e8f40` catalog built with the stock package lane. `wasm-tools validate` passed for all three modules, and `pkg install` placed all three validated SHA-256 payloads in `Documents/bin`. The package modules are 2,081,522 bytes (`rga`), 2,083,028 bytes (`rga-preproc`), and 2,160,294 bytes (`rust-rg`). The disposable app's `pandoc` launcher was set to fail with status 99 if invoked; the matrix passed without calling it. All eight searches matched and returned 0 with empty stderr, the silent PDF no-match returned 1, and the shell resumed. At one-second timestamp resolution DOCX and EPUB each took 1 s. This locally built catalog was not uploaded; the earlier hosted artifact below used the old Pandoc adapter.

## ZIP/XML adapter iPhone run

The same module bytes and fixtures matched their staged hashes on iPhone 16 Pro / iOS 27.2.1 in source-built Mini `2.3.3 (608)`. The app build added only temporary measurement code to the previously qualified phone source; the decoder remained external. All eight searches returned 0 with empty stderr, including `corpus/search.docx:Second page` and `corpus/search.epub:Second page`. The silent PDF no-match returned 1 and the shell resumed. DOCX completed within one timestamp tick and EPUB took 1 s at one-second resolution. The suite rejected any use of Pandoc with a fixture-local guard. Signed Mini `2.2.2 (585)` was reinstalled and launched, two device inventories confirmed it, and the lease was released.

The original `pandoc --version` worker's footprint grew from 2,786,856 to 33,769,024 bytes and available process memory fell from 33,913,304 to 2,931,136 bytes in 29.8 ms before XPC disconnected. The dedicated fixed run of the 10,357-byte DOCX (the larger Office fixture) captured 123 samples across its first two worker traces: peak sampled footprint was 12,715,584 bytes and minimum available memory was 23,984,576 bytes. Across all 24 worker traces in the lease run, peak and minimum were 13,207,104 and 23,493,056 bytes respectively. The measurements describe these fixtures and do not establish a limit for arbitrarily large documents. No termination report was available for the original disconnect.

## Previous Simulator run (Pandoc adapter)

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
