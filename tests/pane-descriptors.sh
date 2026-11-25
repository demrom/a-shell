#!/bin/bash
# Run the standalone public pane API consumer against the matching ios_system.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
framework=${1:?Pass the Simulator ios_system.framework}
work=$(mktemp -d)
device=
cleanup() {
    local status=$?
    if [[ -n $device ]]; then
        xcrun simctl shutdown "$device" || true
        if ! xcrun simctl delete "$device"; then
            printf 'Could not delete Simulator %s\n' "$device" >&2
            if [[ $status == 0 ]]; then status=1; fi
        fi
    fi
    if ! rm -r "$work" && [[ $status == 0 ]]; then status=1; fi
    exit "$status"
}
trap cleanup EXIT
mkdir "$work/Frameworks"
cp -R "$framework" "$work/Frameworks/"
arch=$(uname -m)
model=com.apple.CoreSimulator.SimDeviceType.iPhone-17
runtime=$(xcrun simctl list runtimes -j | jq -r --arg model "$model" --arg arch "$arch" \
    '[.runtimes[] | select(.isAvailable and (.identifier | contains("iOS")) and ($arch != "x86_64" or (.version | startswith("26."))) and any(.supportedDeviceTypes[]?; .identifier == $model))] | sort_by(.version | split(".") | map(tonumber)) | last.identifier // empty')
if [[ -z $runtime ]]; then
    printf 'No available iOS runtime supports iPhone 17 on %s\n' "$arch" >&2
    exit 1
fi
xcrun --sdk iphonesimulator clang -target "$arch-apple-ios16.0-simulator" -fobjc-arc \
    -F"$work/Frameworks" -framework Foundation -framework ios_system -Wl,-rpath,@executable_path/Frameworks \
    "$root/tests/pane-descriptors.m" "$root/ShellWorkers/NativePane.m" -o "$work/pane-descriptors"
codesign --force --sign - "$work/Frameworks/ios_system.framework"
codesign --force --sign - "$work/pane-descriptors"
device=$(xcrun simctl create Pane-Descriptors "$model" "$runtime")
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl spawn "$device" "$work/pane-descriptors"
