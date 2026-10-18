#!/bin/bash
# Build the same pinned file-only FFmpeg CLI for native macOS or WASI threads.
set -euo pipefail
if [[ $# != 2 || $1 != /* ]]; then
  echo 'usage: ffmpeg-build.sh ABSOLUTE-CACHE native|wasi' >&2
  exit 2
fi
cache=$1
mode=$2
case "$mode" in native|wasi) ;; *) exit 2 ;; esac
mkdir -p "$cache"
sha=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
archive=$cache/ffmpeg-9.0.2.tar.xz
if [[ ! -f $archive ]]; then
  curl -fLsS --connect-timeout 15 --max-time 300 https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz -o "$archive.part"
  echo "$sha  $archive.part" | shasum -a 256 -c -
  mv "$archive.part" "$archive"
fi
echo "$sha  $archive" | shasum -a 256 -c -
if [[ ! -d $cache/ffmpeg-source ]]; then
  mkdir "$cache/ffmpeg-source"
  tar -xf "$archive" --strip-components=1 -C "$cache/ffmpeg-source"
fi
# The caller must hold the lead's heavy-build slot; this only checks collisions.
processes=$(ps -Ao comm)
if printf '%s\n' "$processes" | grep -E 'cargo|rustc|swift-build|swift-frontend|xcodebuild' >/dev/null; then
  echo 'Another heavy build is running; wait for the shared slot.' >&2
  exit 75
fi
available=$(df -Pk "$cache" | awk 'NR == 2 {print $4}')
[[ $available -gt 10485760 ]] || { echo 'More than 10 GiB free space is required.' >&2; exit 1; }
options=(--disable-autodetect --disable-everything --enable-ffmpeg --disable-ffprobe
  --disable-asm --enable-pthreads --disable-w32threads --disable-os2threads
  --disable-network --enable-protocol=file --enable-demuxer=avi --enable-decoder=rawvideo
  --enable-encoder=mpeg4 --enable-muxer=avi '--enable-filter=scale,format' --enable-swscale
  --disable-debug --disable-doc --optflags=-Oz)
if [[ $mode == wasi ]]; then
  sdk=$cache/wasi-sdk-34.0-arm64-macos
  [[ -x $sdk/bin/clang ]] || { echo 'Pinned wasi-sdk 34.0 arm64 macOS is required in the cache.' >&2; exit 1; }
  options+=(--cc="$sdk/bin/clang" --cxx="$sdk/bin/clang++" --ar="$sdk/bin/llvm-ar"
    --ranlib="$sdk/bin/llvm-ranlib" --nm="$sdk/bin/llvm-nm" --strip="$sdk/bin/llvm-strip"
    --target-os=none --arch=wasm32 --enable-cross-compile
    --extra-cflags='--target=wasm32-wasip1-threads -pthread -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -flto'
    --extra-ldflags='--target=wasm32-wasip1-threads -pthread -flto -Wl,--strip-all,--import-memory,--export-memory,--max-memory=268435456'
    --extra-libs='-lwasi-emulated-signal -lwasi-emulated-process-clocks')
  build=$cache/ffmpeg-wasi9-threads
else
  options+=(--cc=clang --extra-cflags=-flto --extra-ldflags=-flto)
  build=$cache/ffmpeg-native9
fi
mkdir -p "$build"
cd "$build"
nice -n 15 "$cache/ffmpeg-source/configure" "${options[@]}" > configure-final.log 2>&1
grep -q '^#define CONFIG_FFMPEG 1$' config.h
nice -n 15 make -j 2 > build-final.log 2>&1
