#!/bin/bash
# Run the existing rollout and public thread-store relocation tests on macOS.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=${1:?Pass a directory for the prepared source and test logs}
mkdir -p "$work"
work=$(cd "$work" && pwd)
CODEX_BUILD_CACHE="$work/source" bash "$root/codex/build.sh" prepare
export CARGO_TARGET_DIR="$work/target"
cd "$work/source/upstream/codex-rs"
"${CODEX_RUSTUP:-rustup}" run 1.96.1 cargo test --locked -p codex-rollout -p codex-thread-store --lib ios_relocation 2>&1 | tee "$work/relocation.log"
grep -F 'test result: ok. 6 passed; 0 failed;' "$work/relocation.log"
grep -Fx 'test local::ios_relocation_tests::ios_relocation_public_read_uses_exact_selected_copy_before_rollback ... ok' "$work/relocation.log"
grep -Fx 'test local::ios_relocation_tests::ios_relocation_public_filtered_resume_restores_workspace ... ok' "$work/relocation.log"
grep -F 'test result: ok. 2 passed; 0 failed;' "$work/relocation.log"
