#!/usr/bin/env bash
# Build a pinned command against an existing, matching ios_system framework.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
product=${1:?Usage: build.sh PRODUCT FRAMEWORKS PLATFORM BUILD_DIR}
frameworks=$(cd "${2:?Specify the ios_system framework parent}" && pwd -P)
platform=${3:?Specify device, simulator, or simulator-x86_64}
mkdir -p "${4:?Specify a build directory}"
build=$(cd "$4" && pwd -P)
case $product in
  dua)
    repo=Byron/dua-cli version=3.0.3
    checksum=e1918a15a39ec1f25a2f16f8395512b21025221ff9b0a5ba9bb8eb6b17a4178a
    features=(--no-default-features)
    ;;
  gh)
    repo=cli/cli version=2.106.0
    checksum=ffbaa7f4ba49ca7755ad29c4c92ae28046a969c47476a2218e3ae30183f81346
    ;;
  monolith)
    features=(--no-default-features --features cli)
    repo=Y2Z/monolith version=2.12.0
    checksum=57e452913097c13614ef9c76d95264571a8580f30f6d4d52e6eea70437f6dbb8
    ;;
  *) echo "Unknown command: $product" >&2; exit 2 ;;
esac
case $platform in
  device) sdk=iphoneos target=aarch64-apple-ios arch=arm64 mach=IOS ;;
  simulator) sdk=iphonesimulator target=aarch64-apple-ios-sim arch=arm64 mach=IOSSIMULATOR ;;
  simulator-x86_64) sdk=iphonesimulator target=x86_64-apple-ios arch=x86_64 mach=IOSSIMULATOR ;;
  *) echo "Unknown platform: $platform" >&2; exit 2 ;;
esac
runtime=$frameworks/ios_system.framework/ios_system
xcrun vtool -arch "$arch" -show-build "$runtime" | grep -E "platform +$mach$" >/dev/null

work=$build/$product/$platform
output=$work/$product.framework
mkdir -p "$work" "$output"
archive=$build/$product-v$version.tar.gz
if [[ ! -f $archive ]]; then
  temporary=$(mktemp "$archive.XXXXXX")
  trap 'rm -f "$temporary"' EXIT
  curl -fLsS --retry 2 --connect-timeout 15 --max-time 180 \
    "https://codeload.github.com/$repo/tar.gz/refs/tags/v$version" -o "$temporary"
  echo "$checksum  $temporary" | shasum -a 256 -c -
  mv "$temporary" "$archive"
  trap - EXIT
fi
echo "$checksum  $archive" | shasum -a 256 -c -
# Re-extract before patching: no cached source can silently keep an old port patch.
source=$(mktemp -d "$work/source.XXXXXX")
trap 'rm -rf "$source"' EXIT
tar -xzf "$archive" --strip-components=1 -C "$source"
SDKROOT=$(xcrun --sdk "$sdk" --show-sdk-path)
export SDKROOT IPHONEOS_DEPLOYMENT_TARGET=14.0
install_name=@rpath/$product.framework/$product
if [[ $product == gh ]]; then
  export GOTOOLCHAIN=local GOCACHE=$work/go-cache GOMAXPROCS=3
  [[ $(go env GOVERSION) == go1.27.4 ]] || { echo 'Go 1.27.4 required' >&2; exit 1; }
  mkdir "$source/embedded"
  cp "$here/gh/entry.go" "$source/embedded/main.go"
  clang_target=$arch-apple-ios14.0
  goarch=arm64
  if [[ $sdk == iphonesimulator ]]; then clang_target=$clang_target-simulator; fi
  if [[ $arch == x86_64 ]]; then goarch=amd64; fi
  overlay=()
  if [[ $arch == arm64 ]]; then
    runtime_source=$(go env GOROOT)/src/runtime/os_workdir_ios_arm64.go
    runtime_copy=$work/os_workdir_ios_arm64.go
    echo "4382ac94186c24d0087bf378af0fd2fc860fefee29554488b94fe9eddbba6bdf  $runtime_source" | shasum -a 256 -c -
    cp "$runtime_source" "$runtime_copy"
    patch -s -f -F 0 "$runtime_copy" <"$here/gh/runtime-cwd.patch"
    jq -n --arg original "$runtime_source" --arg replacement "$runtime_copy" \
      '{Replace: {($original): $replacement}}' >"$work/go-ios-overlay.json"
    overlay=(-overlay "$work/go-ios-overlay.json")
  fi
  clang=$(xcrun --sdk "$sdk" --find clang)
  GOOS=ios GOARCH=$goarch CGO_ENABLED=1 CC=$clang \
  CGO_CFLAGS="-isysroot \"$SDKROOT\" -target $clang_target" \
  CGO_LDFLAGS="-isysroot \"$SDKROOT\" -target $clang_target" \
    go build -C "$source" ${overlay[@]+"${overlay[@]}"} -mod=readonly -p 3 -trimpath -buildvcs=false \
    -ldflags "-X github.com/cli/cli/v2/internal/build.Version=$version" \
    -buildmode=c-archive -o "$work/gh.a" ./embedded
  "$clang" -target "$clang_target" -isysroot "$SDKROOT" -Wall -Wextra -Werror \
    -I "$frameworks/ios_system.framework/Headers" -dynamiclib "$here/gh/command.m" "$work/gh.a" \
    -F "$frameworks" -framework ios_system -framework Foundation -framework UIKit -framework Security \
    -lresolv -Wl,-exported_symbol,_gh_ios_main -Wl,-install_name,"$install_name" -o "$output/$product"
else
  patch -s -f -F 0 -p1 -d "$source" <"$here/$product/native.patch"
  cp "$here/host_io.rs" "$source/src/host_io.rs"
  export CARGO_TARGET_DIR=$work/target CARGO_BUILD_JOBS=3
  # Cargo can otherwise find a different rustc earlier on PATH than rustup uses.
  RUSTC=$(rustup which --toolchain 1.96.1 rustc)
  export RUSTC
  # A Rust panic must return to the app. Preserve LINKEDIT alignment for dyld.
  export CARGO_PROFILE_RELEASE_PANIC=unwind CARGO_PROFILE_RELEASE_STRIP=none
  rustup run 1.96.1 cargo rustc --locked --release --target "$target" \
    --manifest-path "$source/Cargo.toml" --lib "${features[@]}" -- \
    --remap-path-prefix "$source=$product-source" \
    -L "framework=$frameworks" -l framework=ios_system \
    -C "link-arg=-Wl,-install_name,$install_name"
  cp "$CARGO_TARGET_DIR/$target/release/lib$product.dylib" "$output/$product"
fi
cp "$source/LICENSE" "$output/LICENSE"
cat >"$output/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$product</string>
<key>CFBundleIdentifier</key><string>com.asheKube.a-Shell.$product</string>
<key>CFBundleName</key><string>$product</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>14.0</string>
</dict></plist>
EOF
plutil -lint "$output/Info.plist"
build_version=$(xcrun vtool -arch "$arch" -show-build "$output/$product")
grep -E "platform +$mach$" <<<"$build_version"
grep -E 'minos +14\.0$' <<<"$build_version"
exports=$(xcrun nm -gU "$output/$product")
grep -E " T _${product}_ios_main$" <<<"$exports"
xcrun otool -L "$output/$product"
stat -f 'Binary bytes: %z' "$output/$product"
shasum -a 256 "$output/$product"
