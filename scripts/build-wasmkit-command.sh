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
wrapper=60a6f6477f13c281aea9d1379c81f41d553dcefe
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
fetch "https://codeload.github.com/demrom/WasmKitCommand/tar.gz/$wrapper" \
  5db9a9be38c24b022cf4866bfbd7d17c55686ec9a694fc9caeea863471a1ceea "$downloads/WasmKitCommand-$wrapper.tar.gz"
fetch "https://codeload.github.com/holzschu/WasmKit/tar.gz/$engine" \
  cbd094b4e188a25e61bad157e8b7642473c59017e334fb109e53a454d39c5cd7 "$downloads/WasmKit-$engine.tar.gz"
# One-off CI preview: use the fork's artifact while it is retained. The
# anonymous mirror avoids configuring a cross-repository Actions credential.
# Verify both the Actions archive and the selected XCFramework member.
runtime_archive="$downloads/ios_system-15236108501.zip"
fetch https://nightly.link/demrom/ios_system/actions/artifacts/15236108501.zip \
  f0ade018efb7d0d69469d3b21aed355e236d6e55e88a3f0d87a5ae56ed3fdb13 "$runtime_archive"
unzip -p "$runtime_archive" .build/ios_system.xcframework.zip > "$stage/ios_system.xcframework.zip"
printf '%s  %s\n' 478e445e3bc552ff3ab2154b75f0d7509ba8808a6a15bebd2acb4da77be10171 \
  "$stage/ios_system.xcframework.zip" | shasum -a 256 -c -
source="$stage/source"
mkdir -p "$source/WasmKit"
tar -xzf "$downloads/WasmKitCommand-$wrapper.tar.gz" --strip-components 1 -C "$source"
tar -xzf "$downloads/WasmKit-$engine.tar.gz" --strip-components 1 -C "$source/WasmKit"
# Replay the reviewed deltas on immutable snapshots. Ignore the parent checkout:
# git apply can otherwise skip every path under its untracked .build directory.
(cd "$source/WasmKit" && GIT_DIR=/dev/null git apply --check "$root/scripts/wasmkit-fds/engine.patch" &&
    GIT_DIR=/dev/null git apply "$root/scripts/wasmkit-fds/engine.patch")
(cd "$source" && GIT_DIR=/dev/null git apply --check "$root/scripts/wasmkit-fds/command.patch" &&
    GIT_DIR=/dev/null git apply "$root/scripts/wasmkit-fds/command.patch")
unzip -q "$stage/ios_system.xcframework.zip" -d "$source"

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
  # A top-level Resources directory hides the flat iOS framework's Info.plist from CFBundle.
  mkdir -p "$framework/Notices"
  cp "$source/WasmKit/LICENSE" "$framework/Notices/WasmKit-LICENSE"
  cp "$source/WasmKit/NOTICE.txt" "$framework/Notices/WasmKit-NOTICE.txt"
  cp "$build/packages/checkouts/swift-system/LICENSE.txt" "$framework/Notices/swift-system-LICENSE.txt"
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
    xcrun nm -arch "$arch" -u "$binary" |
      awk '$NF == "_ios_kill_worker" { kill = 1 } $NF == "_ios_peek_worker" { peek = 1 } END { exit !(kill && peek) }'
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
  xxd -r -p "$root/tests/wasmkit/pipe.hex" "$app/pipe.wasm"
  printf '80f9a8e6b15ad6ce26472a63caa6dc5e27fb64c33e7df8f9e441f87ce6cf402d  %s\n' \
    "$app/pipe.wasm" | shasum -a 256 -c -
  xxd -r -p "$root/tests/wasmkit/kill-unowned.hex" "$app/kill-unowned.wasm"
  printf 'cdfc9f70afafd7c3bd1a9e64452ed9a445b7e9021f945ff5e1c4a8292ae2c13f  %s\n' \
    "$app/kill-unowned.wasm" | shasum -a 256 -c -
  xxd -r -p "$root/tests/wasmkit/peek-fork.hex" "$app/peek-fork.wasm"
  printf '3ecc8826aac4d6e694d5af57049563dc45ef29b30c937f0564befb3d1b42a245  %s\n' \
    "$app/peek-fork.wasm" | shasum -a 256 -c -
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
  diff -u <(printf 'Hello from WASI!\nprocess-pipe-ok\nprocess-kill-ok\nprocess-peek-fork-ok\n') "$dist/hello.stdout"
  grep -Fxq 'wasmkit hello.wasm: status=0' "$dist/hello.stderr"
  grep -Fxq 'wasmkit pipe.wasm: status=0' "$dist/hello.stderr"
  grep -Fxq 'wasmkit kill-unowned.wasm: status=0' "$dist/hello.stderr"
  grep -Fxq 'wasmkit peek-fork.wasm: status=0' "$dist/hello.stderr"
fi
