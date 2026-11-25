#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
usage() { printf 'Usage: %s [--smoke] [build-dir]\n' "$0"; }
smoke=false
case ${1:-} in
--smoke)
  smoke=true
  shift
  ;;
--help | -h)
  usage
  exit 0
  ;;
-*)
  usage >&2
  exit 2
  ;;
esac
if (($# > 1)); then
  usage >&2
  exit 2
fi
build=${1:-"$root/.build/wasmkit-command"}
mkdir -p "$build"
build=$(cd "$build" && pwd)
downloads="$build/downloads"
dist="$build/dist"
mkdir -p "$downloads" "$dist"
stage=$(mktemp -d "$build/stage.XXXXXXXX")
device=
cleanup() {
  if [[ -n $device ]]; then
    xcrun simctl shutdown "$device" || true
    xcrun simctl delete "$device"
  fi
  rm -rf "$stage"
}
trap cleanup EXIT

# The wrapper's WasmKit submodule commit and its workspace Package.resolved are pinned together.
wrapper=7236ffc031aaae384ef2257a6c2b9213c4e119ec
engine=24700702a854d23b65af63780366c89e8b4996f6
minimum=18.0

fetch() {
  local url=$1 checksum=$2 output=$3
  if [[ ! -f $output ]]; then
    curl --fail --location --silent --show-error --retry 3 --max-time 300 "$url" -o "$stage/download"
    printf '%s  %s\n' "$checksum" "$stage/download" | shasum -a 256 -c -
    mv "$stage/download" "$output"
  else
    printf '%s  %s\n' "$checksum" "$output" | shasum -a 256 -c -
  fi
}

xcodebuild -version
xcrun swiftc --version
fetch "https://codeload.github.com/holzschu/WasmKitCommand/tar.gz/$wrapper" \
  e581ecff582a17f759d9fa9187ee0960d94ae8011a1089f18cb7ad86c59c3971 "$downloads/WasmKitCommand-$wrapper.tar.gz"
fetch "https://codeload.github.com/holzschu/WasmKit/tar.gz/$engine" \
  cbd094b4e188a25e61bad157e8b7642473c59017e334fb109e53a454d39c5cd7 "$downloads/WasmKit-$engine.tar.gz"
# v3.0.5 lacks ios_startInteractive, used by the command's TTY bridge.
fetch https://github.com/holzschu/ios_system/releases/download/v3.0.6/ios_system.xcframework.zip \
  c9c6dc4cde45cc271ccc8bd0553ce4d3149eced1f0ee3d9e0ce01885d93526e6 "$downloads/ios_system-v3.0.6.xcframework.zip"
source="$stage/source"
mkdir -p "$source/WasmKit"
tar -xzf "$downloads/WasmKitCommand-$wrapper.tar.gz" --strip-components 1 -C "$source"
tar -xzf "$downloads/WasmKit-$engine.tar.gz" --strip-components 1 -C "$source/WasmKit"
unzip -q "$downloads/ios_system-v3.0.6.xcframework.zip" -d "$source"

# Negative control: regress guest stdout routing without changing the smoke test.
patch -d "$source" -p1 <<'PATCH'
--- a/WasmKitCommand.swift
+++ b/WasmKitCommand.swift
@@ -126,5 +126,5 @@
                                             environment: environment,
                                             fileSystem: .host().withStdio(stdin:  fileno(thread_stdin),
-                                                                          stdout:  fileno(thread_stdout),
+                                                                          stdout:  fileno(thread_stderr),
                                                                           stderr:  fileno(thread_stderr))
                                                 // Stdio is already mapped above. The extension sandbox denies
PATCH

name=WasmKitCommand
for sdk in iphoneos iphonesimulator; do
  case $sdk in
  iphoneos)
    destination='generic/platform=iOS'
    architectures=arm64
    ;;
  iphonesimulator)
    destination='generic/platform=iOS Simulator'
    architectures='arm64 x86_64'
    ;;
  esac
  output="$stage/$sdk"
  if ! xcodebuild build -project "$source/$name.xcodeproj" -scheme "$name" \
    -configuration Release -destination "$destination" -derivedDataPath "$output" \
    -clonedSourcePackagesDirPath "$build/packages" -onlyUsePackageVersionsFromResolvedFile \
    -jobs 2 ARCHS="$architectures" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO >"$dist/$sdk-build.log" 2>&1; then
    grep -E '(^|: )(fatal )?error:|^\*\* BUILD FAILED' "$dist/$sdk-build.log" >&2 || tail -25 "$dist/$sdk-build.log" >&2
    exit 1
  fi
  framework="$output/Build/Products/Release-$sdk/$name.framework"
  mkdir -p "$framework/Resources"
  cp "$source/WasmKit/LICENSE" "$framework/Resources/WasmKit-LICENSE"
  cp "$source/WasmKit/NOTICE.txt" "$framework/Resources/WasmKit-NOTICE.txt"
  cp "$build/packages/checkouts/swift-system/LICENSE.txt" "$framework/Resources/swift-system-LICENSE.txt"
  echo "Built $sdk ($architectures)"
done

device_slice=ios-arm64
simulator_slice=ios-arm64_x86_64-simulator
archive="$stage/$name.xcframework"
xcodebuild -create-xcframework \
  -framework "$stage/iphoneos/Build/Products/Release-iphoneos/$name.framework" \
  -framework "$stage/iphonesimulator/Build/Products/Release-iphonesimulator/$name.framework" \
  -output "$archive"

: >"$dist/slices.txt"
verify_slice() {
  local slice=$1 platform=$2 expected_archs=$3 binary arch info
  binary="$archive/$slice/$name.framework/$name"
  test "$(xcrun lipo -archs "$binary" | tr ' ' '\n' | LC_ALL=C sort | paste -sd ' ' -)" = "$expected_archs"
  for arch in $expected_archs; do
    info=$(xcrun vtool -arch "$arch" -show-build "$binary")
    test "$(awk '$1 == "platform" { print $2 }' <<<"$info")" = "$platform"
    test "$(awk '$1 == "minos" { print $2 }' <<<"$info")" = "$minimum"
    xcrun nm -arch "$arch" -gU "$binary" | awk '$NF == "_wasmkit" { found = 1 } END { exit !found }'
    xcrun otool -arch "$arch" -L "$binary" |
      awk '$1 == "@rpath/ios_system.framework/ios_system" { found = 1 } END { exit !found }'
    printf '%s %s %s minOS=%s\n' "$slice" "$arch" "$platform" "$minimum" | tee -a "$dist/slices.txt"
  done
}
verify_slice "$device_slice" IOS arm64
verify_slice "$simulator_slice" IOSSIMULATOR 'arm64 x86_64'

zip="$name.xcframework.zip"
ditto -c -k --norsrc --keepParent "$archive" "$stage/$zip"
checksum=$(xcrun swift package compute-checksum "$stage/$zip")
printf '%s  %s\n' "$checksum" "$zip" >"$stage/checksums.txt"
(cd "$stage" && shasum -a 256 -c checksums.txt)
mv "$stage/$zip" "$stage/checksums.txt" "$dist/"

if "$smoke"; then
  # Test the published bytes, not the framework in DerivedData.
  unzip -q "$dist/$zip" -d "$stage/unpacked"
  app="$stage/WasmKitSmoke.app"
  frameworks="$app/Frameworks"
  mkdir -p "$frameworks"
  cp -R "$stage/unpacked/$name.xcframework/$simulator_slice/$name.framework" "$frameworks/"
  cp -R "$source/ios_system.xcframework/$simulator_slice/ios_system.framework" "$frameworks/"
  target="$(uname -m)-apple-ios$minimum-simulator"
  xcrun --sdk iphonesimulator clang -target "$target" -fobjc-arc "$root/tests/wasmkit/main.m" \
    -F"$frameworks" -framework ios_system -framework Foundation \
    -Wl,-rpath,@executable_path/Frameworks -o "$app/WasmKitSmoke"
  xxd -r -p "$root/tests/wasmkit/hello.hex" "$app/hello.wasm"
  cp "$root/tests/wasmkit/Info.plist" "$root/tests/wasmkit/commandDictionary.plist" "$app/"
  codesign --force --sign - "$frameworks/$name.framework"
  codesign --force --sign - "$frameworks/ios_system.framework"
  codesign --force --sign - "$app"

  device_type=com.apple.CoreSimulator.SimDeviceType.iPhone-17
  runtime=$(xcrun simctl list runtimes -j | jq -er --arg type "$device_type" '
    [.runtimes[] | select(.isAvailable and (.identifier | contains(".iOS-"))
      and (.version | split(".")[0] | tonumber >= 18)
      and any(.supportedDeviceTypes[]?; .identifier == $type))]
    | sort_by(.version | split(".") | map(tonumber)) | last.identifier')
  device=$(xcrun simctl create WasmKitCommand-Smoke "$device_type" "$runtime")
  echo "Running wasmkit hello.wasm on $runtime ($(uname -m))"
  xcrun simctl boot "$device"
  xcrun simctl bootstatus "$device" -b
  status=0
  xcrun simctl spawn "$device" "$app/WasmKitSmoke" >"$dist/hello.stdout" 2>"$dist/hello.stderr" || status=$?
  tee <"$dist/hello.stdout"
  tee <"$dist/hello.stderr" >&2
  test "$status" = 0
  diff -u <(printf 'Hello from WASI!\n') "$dist/hello.stdout"
  grep -Fxq 'wasmkit hello.wasm: status=0' "$dist/hello.stderr"
fi
