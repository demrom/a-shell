#!/bin/bash
set -euo pipefail

# Build with the dependency versions and hashes in the pinned upstream superbuild.
if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [BUILD_DIR]\n' "$0" >&2
  exit 2
fi
recipe=$(cd -- "$(dirname -- "$0")/curl-impersonate" && pwd)
out=${1:-.build/curl-impersonate}
mkdir -p "$out"
out=$(cd -- "$out" && pwd)
version=2.3.0
revision=aa68bd3ddb4d03120c2f0ba0c5c631613ed9ab52
minos=14.0
name=curl-impersonate
runtime_version=3.0.5
export SOURCE_DATE_EPOCH=1792487047
export TZ=UTC

fetch() {
  local url=$1 sha=$2 archive=$3
  if [[ ! -f "$archive" ]]; then
    curl --fail --silent --show-error --location --retry 3 --max-time 300 "$url" -o "$archive.part"
    printf '%s  %s\n' "$sha" "$archive.part" | shasum -a 256 --check
    mv "$archive.part" "$archive"
  fi
  printf '%s  %s\n' "$sha" "$archive" | shasum -a 256 --check
}

sources="$out/src"
mkdir -p "$sources" "$out/downloads"
fetch "https://codeload.github.com/lexiforest/curl-impersonate/tar.gz/$revision" \
  116e1a80b49baeedb1599302736801ed414037a28bf2914d8b5e7775418f6bc6 "$out/source.tar.gz"
fetch "https://github.com/holzschu/ios_system/releases/download/v$runtime_version/ios_system.xcframework.zip" \
  d429e68102926f58bedd8e8b7105dcd169478cd6da1cef494a5f468482d1c8f5 "$out/ios_system.xcframework.zip"
# The runtime is a link input only; the app embeds its existing copy.
unzip -oq "$out/ios_system.xcframework.zip" -d "$out"
tar -xzf "$out/source.tar.gz" --strip-components 1 --exclude '*/patches/curl.patch' -C "$sources"
patch -s -d "$sources" -p1 -i "$recipe/superbuild.patch"
# The upstream superbuild invalidates curl when the patch content changes.
{
  tar -xOzf "$out/source.tar.gz" "curl-impersonate-$revision/patches/curl.patch"
  printf '\n'
  cat "$recipe/command.patch"
} > "$sources/curl.patch.new"
if ! cmp -s "$sources/curl.patch.new" "$sources/patches/curl.patch"; then
  mv "$sources/curl.patch.new" "$sources/patches/curl.patch"
fi

build_slice() {
  local sdk=$1 arch=$2 identifier=$3 suffix=$4
  local build="$out/$sdk-$arch" sysroot target flags runtime
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  target="$arch-apple-ios$minos$suffix"
  flags="-target $target -fPIC"
  runtime="$out/ios_system.xcframework/$identifier/ios_system.framework/ios_system"
  xcrun lipo -verify_arch "$arch" "$runtime"

  cmake -S "$sources" -B "$build" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR="$arch" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$minos" \
    -DCMAKE_C_COMPILER="$(xcrun --sdk "$sdk" --find clang)" \
    -DCMAKE_CXX_COMPILER="$(xcrun --sdk "$sdk" --find clang++)" \
    -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags" \
    -DCURL_IMPERSONATE_VERSION="$version" -DCURL_CA_BUNDLE=none -DCURL_CA_PATH=none \
    -DASHELL_DOWNLOAD_DIR="$out/downloads" -DASHELL_IOS_SYSTEM="$runtime" -DSUBJOBS=4
  cmake --build "$build" --target curl-impersonate --parallel 1
}

xcodebuild -version
build_slice iphoneos arm64 ios-arm64 ''
build_slice iphonesimulator arm64 ios-arm64_x86_64-simulator -simulator
build_slice iphonesimulator x86_64 ios-arm64_x86_64-simulator -simulator

framework() {
  printf '%s/%s/deps/build/curl/src/%s.framework\n' "$out" "$1" "$name"
}

device=$(framework iphoneos-arm64)
sim_arm64=$(framework iphonesimulator-arm64)
sim_x86=$(framework iphonesimulator-x86_64)
sim="$out/universal/$name.framework"
mkdir -p "$sim"
cp "$sim_arm64/Info.plist" "$sim/Info.plist"
xcrun lipo -create "$sim_arm64/$name" "$sim_x86/$name" -output "$sim/$name"

# Retain notices from the source of every bundled static dependency.
licenses="$out/licenses"
mkdir -p "$licenses"
deps="$out/iphoneos-arm64/deps/src"
cp "$sources/LICENSE" "$licenses/curl-impersonate.txt"
for spec in boringssl/LICENSE brotli/LICENSE cares/LICENSE.md curl/COPYING nghttp2/COPYING nghttp3/COPYING ngtcp2/COPYING zlib/LICENSE zstd/LICENSE; do
  cp "$deps/$spec" "$licenses/${spec%%/*}.txt"
done
for frame in "$device" "$sim"; do
  mkdir -p "$frame/Licenses"
  cp "$licenses/"*.txt "$frame/Licenses/"
  codesign --force --sign - --timestamp=none "$frame"
done

# Build in empty staging so an existing ZIP cannot contribute stale members.
staging=$(mktemp -d "$out/package.XXXXXXXX")
xcodebuild -create-xcframework -framework "$device" -framework "$sim" \
  -output "$staging/$name.xcframework"

expected() {
  local platform=$1 arch=$2 binary=$3 build deps
  build=$(xcrun vtool -arch "$arch" -show-build "$binary")
  printf '%s\n' "$build"
  grep -Fxq "platform $platform" <<<"$(awk '{$1=$1; print}' <<<"$build")"
  grep -Fxq "minos $minos" <<<"$(awk '{$1=$1; print}' <<<"$build")"
  [[ $(xcrun nm -arch "$arch" -gjU "$binary") == _curl_impersonate_main ]]
  [[ $(xcrun otool -arch "$arch" -D "$binary" | tail -n 1) == "@rpath/$name.framework/$name" ]]
  deps=$(xcrun otool -arch "$arch" -L "$binary" | awk 'NR > 1 {print $1}')
  grep -Fxq @rpath/ios_system.framework/ios_system <<<"$deps"
  while read -r lib; do
    case "$lib" in
      "@rpath/$name.framework/$name"|@rpath/ios_system.framework/ios_system|/usr/lib/*|/System/Library/Frameworks/*) ;;
      *) printf 'Unexpected dylib dependency: %s\n' "$lib" >&2; exit 1 ;;
    esac
  done <<<"$deps"
}

audit() {
  local xcframework="$staging/$name.xcframework" binary
  binary="$xcframework/ios-arm64/$name.framework/$name"
  [[ $(xcrun lipo -archs "$binary") == arm64 ]]
  xcrun lipo -info "$binary"
  expected IOS arm64 "$binary"
  binary="$xcframework/ios-arm64_x86_64-simulator/$name.framework/$name"
  [[ $(xcrun lipo -archs "$binary" | tr ' ' '\n' | sort | paste -sd ' ' -) == 'arm64 x86_64' ]]
  xcrun lipo -info "$binary"
  expected IOSSIMULATOR arm64 "$binary"
  expected IOSSIMULATOR x86_64 "$binary"
}
audit | tee "$staging/slices.txt"
(
  cd "$staging"
  find "$name.xcframework" -exec touch -t 202610200904.07 {} +
  find "$name.xcframework" -print | LC_ALL=C sort | zip -Xq "$name.xcframework.zip" -@
  shasum -a 256 "$name.xcframework.zip" > checksums.txt
  shasum -a 256 --check checksums.txt
  [[ $(swift package compute-checksum "$name.xcframework.zip") == "$(awk '{print $1}' checksums.txt)" ]]
)
mkdir -p "$out/dist"
mv "$staging/$name.xcframework.zip" "$staging/slices.txt" "$staging/checksums.txt" "$out/dist/"
printf 'Artifact: %s/dist/%s.xcframework.zip\n' "$out" "$name"
