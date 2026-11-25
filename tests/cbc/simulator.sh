#!/bin/bash
set -euo pipefail
archive=$1 ios_system=$2 work=$3
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
archive=$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")
ios_system=$(cd "$ios_system" && pwd)
slice=ios-arm64_x86_64-simulator
app="$work/cbc-runtime.app"
mkdir -p "$app/Frameworks" "$work/smoke-output"
cp "$root/tests/cbc/unsupported-sos.mps" "$work/smoke-output/"
unzip -q "$archive" -d "$work/smoke-input"
cp -R "$work/smoke-input/cbc.xcframework/$slice/cbc.framework" "$app/Frameworks/"
cp -R "$ios_system/$slice/ios_system.framework" "$app/Frameworks/"
cp "$root/Resources/commandDictionary.plist" "$app/"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>cbc-runtime</string>
<key>CFBundleIdentifier</key><string>org.coin-or.cbc.runtime</string>
<key>CFBundleName</key><string>cbc-runtime</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>DTPlatformName</key><string>iphonesimulator</string>
<key>MinimumOSVersion</key><string>14.0</string>
</dict></plist>
PLIST
arch=$(uname -m)
xcrun --sdk iphonesimulator clang -target "$arch-apple-ios14.0-simulator" -fobjc-arc \
    "$root/tests/cbc/runtime.m" -F"$app/Frameworks" -framework ios_system -framework Foundation \
    -Wl,-rpath,@executable_path/Frameworks -o "$app/cbc-runtime"
codesign --force --sign - "$app/Frameworks/cbc.framework"
codesign --force --sign - "$app/Frameworks/ios_system.framework"
codesign --force --sign - "$app"

type=com.apple.CoreSimulator.SimDeviceType.iPhone-17
runtime=$(xcrun simctl list runtimes -j | jq -er --arg device "$type" '[.runtimes[] | select(.isAvailable and any(.supportedDeviceTypes[]?; .identifier == $device))] | sort_by(.version | split(".") | map(tonumber)) | last.identifier')
device=$(xcrun simctl create CBC-Runtime "$type" "$runtime")
trap 'xcrun simctl shutdown "$device"; xcrun simctl delete "$device"' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
# InstallCoordination can be starting even after bootstatus reports completion.
for attempt in 1 2 3; do
    if install_log=$(LC_ALL=C xcrun simctl install "$device" "$app" 2>&1); then break; fi
    printf '%s\n' "$install_log" >&2
    if [[ $attempt == 3 || $install_log != *'domain=IXErrorDomain, code=2)'* ||
        $install_log != *'Failed to create promise'* ]]; then exit 1; fi
    sleep 3
done
installed=$(xcrun simctl get_app_container "$device" org.coin-or.cbc.runtime app)
SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$installed/Frameworks" \
    xcrun simctl spawn "$device" "$installed/cbc-runtime" "$root/tests/cbc/small.lp" "$work/smoke-output"
