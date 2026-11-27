#!/usr/bin/env bash
# Build the C1 WasmtimeCommand.framework for device arm64 and universal Simulator, then package.
# Usage: ci-framework.sh WORK_DIR ARTIFACT_DIR
set -euo pipefail
proof=$(cd "$(dirname "$0")" && pwd -P)
mkdir -p "${1:?Specify the work directory}" "${2:?Specify the artifact directory}"
work=$(cd "$1" && pwd -P)
dist=$(cd "$2" && pwd -P)

# Same pinned ios_system core as native-ports/ci-framework.sh.
revision=df998e76cea0266bd3615bb9a1f4f7d745f318a2
checksum=6d2201c1dee131b831b8108b578ede560277d1c205fd8c64f2fb9dcd70e7baca
core_source=$(mktemp -d "$work/ios-system.XXXXXX")
package=$(mktemp -d "$work/package.XXXXXX")
trap 'rm -rf "$core_source" "$package"' EXIT
curl -fLsS --retry 2 --connect-timeout 15 --max-time 180 \
  "https://codeload.github.com/holzschu/ios_system/tar.gz/$revision" -o "$core_source/input.tar.gz"
echo "$checksum  $core_source/input.tar.gz" | shasum -a 256 -c -
tar -xzf "$core_source/input.tar.gz" --strip-components=1 -C "$core_source"

RUSTC=$(rustup which --toolchain 1.96.1 rustc)
export RUSTC IPHONEOS_DEPLOYMENT_TARGET=26.2 CARGO_TARGET_DIR="$work/target"
for platform in device simulator simulator-x86_64; do
  case $platform in
    device) sdk=iphoneos arch=arm64 target=aarch64-apple-ios ;;
    simulator) sdk=iphonesimulator arch=arm64 target=aarch64-apple-ios-sim ;;
    simulator-x86_64) sdk=iphonesimulator arch=x86_64 target=x86_64-apple-ios ;;
  esac
  core=$work/core/$platform
  log=$work/ios-system-$platform.log
  if ! xcodebuild -project "$core_source/ios_system.xcodeproj" -target ios_system \
    -configuration Release -sdk "$sdk" -jobs 3 "ARCHS=$arch" ONLY_ACTIVE_ARCH=NO \
    IPHONEOS_DEPLOYMENT_TARGET=14.0 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    "CONFIGURATION_BUILD_DIR=$core" build >"$log" 2>&1; then
    tail -n 60 "$log" >&2
    exit 1
  fi
  SDKROOT=$(xcrun --sdk "$sdk" --show-sdk-path) rustup run 1.96.1 cargo build \
    --manifest-path "$proof/host/Cargo.toml" --locked --release --lib --target "$target" -j 3
  bash "$proof/link-framework.sh" "$CARGO_TARGET_DIR/$target/release/libashell_p3_host.a" \
    "$work/framework/$platform" "$core/ios_system.framework" "$platform"
done

device=$work/framework/device/WasmtimeCommand.framework
simulator=$package/WasmtimeCommand.framework
ditto "$work/framework/simulator/WasmtimeCommand.framework" "$simulator"
xcrun lipo -create "$simulator/WasmtimeCommand" \
  "$work/framework/simulator-x86_64/WasmtimeCommand.framework/WasmtimeCommand" -output "$package/universal"
mv "$package/universal" "$simulator/WasmtimeCommand"
xcrun lipo "$simulator/WasmtimeCommand" -verify_arch arm64 x86_64
xcrun lipo "$device/WasmtimeCommand" -verify_arch arm64
for platform in device simulator simulator-x86_64; do
  printf '%s\t%s\n' "$platform" "$(stat -f %z "$work/framework/$platform/WasmtimeCommand.framework/WasmtimeCommand")"
done >"$dist/WasmtimeCommand.sizes.tsv"
xcodebuild -create-xcframework -framework "$device" -framework "$simulator" \
  -output "$package/WasmtimeCommand.xcframework"
ditto -c -k --norsrc --keepParent "$package/WasmtimeCommand.xcframework" "$dist/WasmtimeCommand.xcframework.zip"
unzip -tq "$dist/WasmtimeCommand.xcframework.zip"
(cd "$dist"; shasum -a 256 WasmtimeCommand.xcframework.zip >WasmtimeCommand.checksums.txt)
printf 'source=%s\nios_system=%s\nwasmtime=49.0.3\nrust=1.96.1\n' "${GITHUB_SHA:-local}" "$revision" \
  >"$dist/WasmtimeCommand.inputs.txt"
