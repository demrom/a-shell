#!/bin/bash
# Build the pinned, thread-free WASI gitoxide experiment; never install it.
set -euo pipefail
if [[ $# != 2 || $1 != /* ]]; then
  echo 'usage: build.sh ABSOLUTE-CACHE prepare|wasi|native' >&2
  exit 2
fi
cache=$1
mode=$2
case "$mode" in prepare|wasi|native) ;; *) exit 2 ;; esac
here=$(cd "$(dirname "$0")" && pwd -P)
source=$cache/source
sha=7414812a006ac67d38a8d7e5fa74ebb2863dac10d50fce6cdc2e0c3ddd419f2e
mkdir -p "$cache"
if [[ ! -f $cache/source.tar.gz ]]; then
  curl -fLsS --connect-timeout 15 --max-time 300 \
    https://codeload.github.com/GitoxideLabs/gitoxide/tar.gz/refs/tags/v0.60.0 -o "$cache/source.tar.gz.part"
  echo "$sha  $cache/source.tar.gz.part" | shasum -a 256 -c -
  mv "$cache/source.tar.gz.part" "$cache/source.tar.gz"
fi
echo "$sha  $cache/source.tar.gz" | shasum -a 256 -c -
if [[ ! -d $source ]]; then
  mkdir -p "$source"
  tar -xzf "$cache/source.tar.gz" --strip-components=1 -C "$source"
fi
if ! patch -s -f -F 0 --dry-run -R -p1 -d "$source" < "$here/wasi.patch" >/dev/null 2>&1; then
  patch -s -f -F 0 --dry-run -p1 -d "$source" < "$here/wasi.patch" >/dev/null
  patch -s -f -F 0 -p1 -d "$source" < "$here/wasi.patch"
fi
[[ $mode != prepare ]] || exit 0
# The lead grants the shared heavy slot before this command. Keep one build at a time.
processes=$(ps -Ao comm)
if printf '%s\n' "$processes" | grep -E 'swift-build|swift-frontend' >/dev/null; then
  echo 'A swift build is running; wait for the shared heavy slot.' >&2
  exit 75
fi
available=$(df -Pk "$cache" | awk 'NR == 2 {print $4}')
[[ $available -gt 10485760 ]] || { echo 'More than 10 GiB free space is required.' >&2; exit 1; }
rustc --version | grep -q '^rustc 1\.96\.1 ' || { echo 'Rust 1.96.1 is required.' >&2; exit 1; }
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$cache/target}
export CARGO_BUILD_JOBS=2
export CARGO_PROFILE_RELEASE_OPT_LEVEL=z CARGO_PROFILE_RELEASE_LTO=fat
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 CARGO_PROFILE_RELEASE_DEBUG=0 CARGO_PROFILE_RELEASE_STRIP=symbols
features=sha1,pretty-cli,gitoxide-core-blocking-client
if [[ $mode == wasi ]]; then
  target=wasm32-wasip2
  features=$features,http-client-wasi
else
  target=$(rustc -vV | awk '/^host:/ {print $2}')
  features=$features,http-client-reqwest
fi
nice -n 15 cargo build --locked --manifest-path "$source/Cargo.toml" --release \
  --target "$target" --bin gix --no-default-features --features "$features" -j 2
