#!/bin/bash
# Build a static Q8 PNG-capable CLI and its pinned dependencies; never install globally.
set -euo pipefail
if [[ $# != 2 || $1 != /* ]]; then
  echo 'usage: imagemagick-build.sh ABSOLUTE-CACHE native|wasi' >&2
  exit 2
fi
cache=$1
mode=$2
here=$(cd "$(dirname "$0")" && pwd -P)
case "$mode" in native|wasi) ;; *) exit 2 ;; esac
mkdir -p "$cache"
prepare() {
  local name=$1 archive=$2 sha=$3 url=$4
  if [[ ! -f $cache/$archive ]]; then
    curl -fLsS --connect-timeout 15 --max-time 300 "$url" -o "$cache/$archive.part"
    echo "$sha  $cache/$archive.part" | shasum -a 256 -c -
    mv "$cache/$archive.part" "$cache/$archive"
  fi
  echo "$sha  $cache/$archive" | shasum -a 256 -c -
  if [[ ! -d $cache/$name-source ]]; then
    mkdir "$cache/$name-source"
    tar -xf "$cache/$archive" --strip-components=1 -C "$cache/$name-source"
  fi
}
prepare zlib zlib-1.3.2.tar.gz bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16 https://zlib.net/zlib-1.3.2.tar.gz
prepare png libpng-1.6.59.tar.gz 2540302a1844ad2b2b501977abecfa850f265f97b78f065a712ab4074a89f5b5 https://codeload.github.com/pnggroup/libpng/tar.gz/refs/tags/v1.6.59
prepare im ImageMagick-7.1.2-34.tar.gz f5163a573a1c1bff16358d0a592b2fb168ad0fd3b9dc5ff57dc7820eebc5cf79 https://codeload.github.com/ImageMagick/ImageMagick/tar.gz/refs/tags/7.1.2-34
if ! patch -s -f -F 0 --dry-run -R -p1 -d "$cache/im-source" < "$here/imagemagick-wasi.patch" >/dev/null 2>&1; then
  patch -s -f -F 0 --dry-run -p1 -d "$cache/im-source" < "$here/imagemagick-wasi.patch" >/dev/null
  patch -s -f -F 0 -p1 -d "$cache/im-source" < "$here/imagemagick-wasi.patch"
fi
# The caller must hold the lead's heavy-build slot; this only checks collisions.
processes=$(ps -Ao comm)
if printf '%s\n' "$processes" | grep -E 'cargo|rustc|swift-build|swift-frontend|xcodebuild' >/dev/null; then
  echo 'Another heavy build is running; wait for the shared slot.' >&2
  exit 75
fi
available=$(df -Pk "$cache" | awk 'NR == 2 {print $4}')
[[ $available -gt 10485760 ]] || { echo 'More than 10 GiB free space is required.' >&2; exit 1; }
prefix=$cache/im-$mode-prefix
export CC=clang CXX=clang++ AR=ar RANLIB=ranlib
export CFLAGS='-Oz -flto' CXXFLAGS='-Oz -flto' LDFLAGS=-flto
host=()
if [[ $mode == wasi ]]; then
  sdk=$cache/wasi-sdk-34.0-arm64-macos
  [[ -x $sdk/bin/clang ]] || { echo 'Pinned wasi-sdk 34.0 arm64 macOS is required in the cache.' >&2; exit 1; }
  export CC="$sdk/bin/clang --target=wasm32-wasip1" CXX="$sdk/bin/clang++ --target=wasm32-wasip1"
  export AR="$sdk/bin/llvm-ar" RANLIB="$sdk/bin/llvm-ranlib"
  export CHOST=wasm32-unknown-wasi
  export CFLAGS='-Oz -flto -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_PROCESS_CLOCKS'
  export CXXFLAGS="$CFLAGS" LDFLAGS='-flto -Wl,--strip-all,-mllvm,-wasm-enable-sjlj,-mllvm,-wasm-use-legacy-eh=false -Wl,-z,stack-size=1048576'
  export LIBS='-lsetjmp -lwasi-emulated-signal -lwasi-emulated-getpid -lwasi-emulated-process-clocks'
  host=(--host=wasm32-unknown-wasi)
fi
mkdir -p "$cache/zlib-$mode" "$cache/png-$mode" "$cache/im-$mode"
(
  cd "$cache/zlib-$mode"
  nice -n 15 "$cache/zlib-source/configure" --static --prefix="$prefix" > configure.log 2>&1
  nice -n 15 make -j 2 > build.log 2>&1
  nice -n 15 make install > install.log 2>&1
)
export CPPFLAGS="-I$prefix/include" LDFLAGS="$LDFLAGS -L$prefix/lib"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
(
  cd "$cache/png-$mode"
  nice -n 15 "$cache/png-source/configure" "${host[@]}" --prefix="$prefix" --disable-shared --enable-static --disable-tests --disable-tools > configure.log 2>&1
  nice -n 15 make -j 2 > build.log 2>&1
  nice -n 15 make install > install.log 2>&1
)
cd "$cache/im-$mode"
nice -n 15 "$cache/im-source/configure" "${host[@]}" --prefix="$prefix" \
  --disable-shared --enable-static --disable-openmp --disable-opencl --without-threads \
  --without-modules --without-magick-plus-plus --without-perl --disable-hdri --with-quantum-depth=8 \
  --enable-zero-configuration --disable-installed --disable-docs --disable-dpc \
  --without-bzlib --without-zip --without-zstd --without-x --without-autotrace --without-dps \
  --without-fftw --without-flif --without-fpx --without-djvu --without-fontconfig --without-freetype \
  --without-raqm --without-gdi32 --without-gslib --without-gvc --without-dmr --without-heic \
  --without-jbig --without-jpeg --without-jxl --without-lcms --without-openjp2 --without-lqr \
  --without-lzma --without-openexr --without-pango --without-raw --without-rsvg --without-tiff \
  --without-uhdr --without-webp --without-wmf --without-xml --with-png=yes --with-zlib=yes > configure.log 2>&1
nice -n 15 make -j 2 > build.log 2>&1
if [[ $mode == native ]]; then
  strip -S -x utilities/magick
  codesign --force --sign - utilities/magick
  codesign --verify --strict utilities/magick
fi
