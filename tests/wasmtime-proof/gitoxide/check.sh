#!/bin/bash
# Compare consumer-visible CLI behavior against the same-source native build.
set -euo pipefail
if [[ $# != 4 || $4 != /* ]]; then
  echo 'usage: check.sh C1-HOST GIX.wasm NATIVE-GIX ABSOLUTE-DISPOSABLE-DIRECTORY' >&2
  exit 2
fi
host=$1
wasm=$2
native=$3
output=$4
[[ ! -e $output ]] || { echo 'Use a new disposable directory.' >&2; exit 2; }
mkdir -p "$output"
"$native" --no-verbose --threads 1 clone https://github.com/octocat/Hello-World.git "$output/native" > "$output/native-clone.out" 2> "$output/native-clone.err"
"$host" "$wasm" --no-verbose --threads 1 clone https://github.com/octocat/Hello-World.git "$output/wasi" > "$output/wasi-clone.out" 2> "$output/wasi-clone.err"
cmp "$output/native-clone.out" "$output/wasi-clone.out"
cmp "$output/native-clone.err" "$output/wasi-clone.err"
printf 'Hello World!\n' > "$output/expected-readme"
cmp "$output/expected-readme" "$output/wasi/README"
compare() {
  local name=$1
  shift
  "$native" --no-verbose --threads 1 -r "$output/native" "$@" > "$output/native-$name.out" 2> "$output/native-$name.err"
  "$host" "$wasm" --no-verbose --threads 1 -r "$output/wasi" "$@" > "$output/wasi-$name.out" 2> "$output/wasi-$name.err"
  cmp "$output/native-$name.out" "$output/wasi-$name.out"
  cmp "$output/native-$name.err" "$output/wasi-$name.err"
}
compare status-clean status --no-write
[[ ! -s $output/wasi-status-clean.out ]]
compare log log
[[ -s $output/wasi-log.out ]]
compare diff diff tree HEAD~1 HEAD
[[ -s $output/wasi-diff.out ]]
for engine in native wasi; do
  printf 'WASI comparison change\n' >> "$output/$engine/README"
  printf 'untracked fixture\n' > "$output/$engine/untracked.txt"
done
compare status-dirty status --no-write
printf '  M README\n  ? untracked.txt\n' > "$output/expected-dirty"
cmp "$output/expected-dirty" "$output/wasi-status-dirty.out"
echo 'PASS: HTTPS clone, clean/dirty status, log and nonempty tree diff match native stdout/stderr; all exit 0.'
