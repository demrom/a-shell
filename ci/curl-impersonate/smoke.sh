#!/bin/bash
set -euo pipefail

# Exercise the packaged CLI via ios_system, using the app's command dictionary.
if [[ $# != 2 ]]; then
  printf 'Usage: %s BUILD_DIR BOOTED_SIMULATOR_UDID\n' "$0" >&2
  exit 2
fi
here=$(cd -- "$(dirname -- "$0")" && pwd)
root=$(cd -- "$here/../.." && pwd)
out=$(cd -- "$1" && pwd)
udid=$2
scratch=$(mktemp -d "$out/smoke.XXXXXXXX")
app="$scratch/CurlSmoke.app"
sim=ios-arm64_x86_64-simulator
mkdir -p "$app/Frameworks" "$app/bin"
(
  cd "$out/dist"
  shasum -a 256 --check checksums.txt
)
unzip -q "$out/dist/curl-impersonate.xcframework.zip" -d "$scratch"
ditto "$scratch/curl-impersonate.xcframework/$sim/curl-impersonate.framework" \
  "$app/Frameworks/curl-impersonate.framework"
ditto "$out/ios_system.xcframework/$sim/ios_system.framework" "$app/Frameworks/ios_system.framework"
cp "$root/Resources_mini/bin/curl-impersonate" "$app/bin/"
cp "$root/Resources_mini/commandDictionary.plist" "$app/commandDictionary.plist"
cp "$root/cacert.pem" "$app/cacert.pem"

plutil -create xml1 "$app/Info.plist"
plutil -insert CFBundleIdentifier -string org.ashell.curl-smoke "$app/Info.plist"
plutil -insert CFBundleExecutable -string CurlSmoke "$app/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$app/Info.plist"

sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
arch=$(uname -m)
xcrun --sdk iphonesimulator clang -target "$arch-apple-ios14.0-simulator" -isysroot "$sdk" \
  -F"$app/Frameworks" -framework ios_system -framework Foundation \
  -Wl,-rpath,@executable_path/Frameworks "$here/smoke.m" -o "$app/CurlSmoke"
codesign --force --sign - --timestamp=none "$app/Frameworks/ios_system.framework"
codesign --force --sign - --timestamp=none "$app"
SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$app/Frameworks" xcrun simctl spawn "$udid" "$app/CurlSmoke"
