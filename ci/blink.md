# Blink framework

Builds jart/blink commit `1ef448de1e3e8ab7cc90d2a0a977be8b4c2d91ea` from a SHA256-verified source archive. The removed a-Shell device binary embeds this exact revision and revision count 593. Its build command used a dynamic library and minimum iOS 14. The recipe retains the source revision and minimum OS and adds arm64/x86_64 Simulator support.

JIT and fork are disabled using upstream configure options. This produces an interpreter-only build with a different feature and export set from the original JIT-enabled binary. Target configuration probes compile and link against the selected SDK; runtime-only probes are conservatively disabled. A native host Blink executes the upstream dependency generator. GNU Make 4 or newer is required. The current Apple linker needs `-no_fixup_chains` for this source's packed pointer tables.

The archive contains one dynamic XCFramework: arm64 iOS and universal arm64/x86_64 Simulator. Packaging and binary audits do not establish guest execution, a-Shell command integration, re-entry or physical-device behavior. The original binary imports libc process functions without an ios_system adapter; this recipe preserves that boundary. Qualify the consumer before using it as an embedded command.
