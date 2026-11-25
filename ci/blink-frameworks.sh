#!/bin/bash
set -euo pipefail
recipe=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$recipe/.." && pwd)
work=${BLINK_BUILD_DIR:-$root/.build/blink-work}
out="$root/.build"
revision=1ef448de1e3e8ab7cc90d2a0a977be8b4c2d91ea
mkdir -p "$work" "$out"
work=$(cd "$work" && pwd)
archive="$work/blink.tar.gz"
checksum=c799c217bcfabb5fd7012295cfd04ac0cb14f6fe8cb7fa5ab25b81a1b0f46820
check_archive() {
  printf '%s  %s\n' "$checksum" "$1" | shasum -a 256 -c -
}
if [ ! -f "$archive" ] || ! check_archive "$archive" >/dev/null 2>&1; then
  download=$(mktemp "$work/blink.tar.gz.XXXXXX")
  trap 'rm -f "$download"' EXIT
  curl -fLsS --retry 3 "https://codeload.github.com/jart/blink/tar.gz/$revision" -o "$download"
  check_archive "$download"
  mv -f "$download" "$archive"
  trap - EXIT
fi
command -v gmake >/dev/null || { echo 'GNU Make 4 or newer is required (brew install make).' >&2; exit 1; }
prepare() {
  local destination=$1
  rm -rf "$destination"
  mkdir -p "$destination"
  tar -xzf "$archive" -C "$destination" --strip-components=1
  patch -d "$destination" -p1 < "$recipe/blink-cross.patch"
  # Upstream launches configuration probes in parallel; serialize them too.
  sed 's/) &$/)/' "$destination/configure" > "$destination/configure.serial"
  mv "$destination/configure.serial" "$destination/configure"
}
prepare "$work/host"
(
  cd "$work/host"
  sh configure --disable-jit MODE= CC=clang LDFLAGS=-Wl,-no_fixup_chains
  gmake -j2 o//blink/blink
  o/blink/blink -v
)
for spec in iphoneos:arm64 iphonesimulator:arm64 iphonesimulator:x86_64; do
  sdk=${spec%:*}
  arch=${spec#*:}
  source="$work/$sdk-$arch"
  triple="$arch-apple-ios14.0"
  platform=iPhoneOS
  if [ "$sdk" = iphonesimulator ]; then
    triple="$triple-simulator"
    platform=iPhoneSimulator
  fi
  sdkroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  prepare "$source"
  (
    cd "$source"
    # Link SDK probes without executing target programs. Fork and JIT are unavailable on iOS.
    CROSS_COMPILE=1 sh configure --disable-jit --disable-fork MODE= CC=clang \
      "CFLAGS=-O2 -target $triple -isysroot $sdkroot" \
      "LDFLAGS=-dynamiclib -target $triple -isysroot $sdkroot -Wl,-no_fixup_chains"
    # The Makefile expands VM unquoted, so use a path relative to this slice.
    gmake -j2 VM=../host/o/blink/blink \
      'BLINK_COMMITS=-DBLINK_COMMITS=\"593\"' \
      "BLINK_GITSHA=-DBLINK_GITSHA=\\\"$revision\\\"" o//blink/blink
    # Upstream's optional make include can hide failures in the host tool.
    test -s o/depend
  )
  framework="$work/frameworks/$sdk-$arch/blink.framework"
  mkdir -p "$framework"
  cp "$source/o/blink/blink" "$framework/blink"
  cp "$source/LICENSE" "$framework/LICENSE"
  install_name_tool -id @rpath/blink.framework/blink "$framework/blink"
  nm -arch "$arch" -gUj "$framework/blink" | awk '$0 == "_main" {found=1} END {exit !found}'
  cat > "$framework/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>blink</string>
<key>CFBundleIdentifier</key><string>org.jart.blink</string>
<key>CFBundleName</key><string>blink</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>MinimumOSVersion</key><string>14.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
</dict></plist>
PLIST
done
sim="$work/frameworks/iphonesimulator-universal/blink.framework"
mkdir -p "$sim"
cp "$work/frameworks/iphonesimulator-arm64/blink.framework/Info.plist" "$sim/Info.plist"
cp "$work/frameworks/iphonesimulator-arm64/blink.framework/LICENSE" "$sim/LICENSE"
lipo -create "$work/frameworks/iphonesimulator-arm64/blink.framework/blink" \
  "$work/frameworks/iphonesimulator-x86_64/blink.framework/blink" -output "$sim/blink"
rm -rf "$out/blink.xcframework"
xcodebuild -create-xcframework -framework "$work/frameworks/iphoneos-arm64/blink.framework" \
  -framework "$sim" -output "$out/blink.xcframework"
(
  cd "$out"
  rm -f blink.xcframework.zip
  zip -qry blink.xcframework.zip blink.xcframework
  printf '%s  blink.xcframework.zip\n' "$(swift package compute-checksum blink.xcframework.zip)" > checksums.txt
)
sum=$(awk '{print $1}' "$out/checksums.txt")
uv run --script "$recipe/audit-artifact.py" "$out/blink.xcframework.zip" --sha256 "$sum" --max-minos 14.0 > "$out/blink.audit.json"
