#!/bin/bash
# Exercise the existing native interactive-state consumer in a disposable app.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ $# == 1 ]]; then
    source_app=$1
    scratch=$(mktemp -d)
    trap 'rm -r "$scratch"' EXIT
    app="$scratch/$(basename "$source_app")"
    ditto "$source_app" "$app"
    name=InteractiveStateChecks
    framework="$app/Frameworks/$name.framework"
    mkdir "$framework"
    xcrun --sdk iphonesimulator clang -target "$(uname -m)-apple-ios15.0-simulator" -dynamiclib \
        -F"$app/Frameworks" -framework ios_system -Wl,-install_name,"@rpath/$name.framework/$name" \
        "$root/interactive-state.m" -o "$framework/$name"
    cp "$app/Frameworks/ios_system.framework/Info.plist" "$framework/Info.plist"
    bundle=$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist")
    plutil -replace CFBundleIdentifier -string "$bundle.ci.$name" "$framework/Info.plist"
    plutil -replace CFBundleExecutable -string "$name" "$framework/Info.plist"
    plutil -replace CFBundleName -string "$name" "$framework/Info.plist"
    codesign --force --sign - "$framework"
    plutil -insert interactive-state -json '["InteractiveStateChecks.framework/InteractiveStateChecks","interactive_state_main","","file"]' "$app/commandDictionary.plist"
    touch "$app/bin/interactive-state"
    chmod +x "$app/bin/interactive-state"
    bash "$root/simulator-app.sh" "$app" "$root/simulator-interactive-state.sh"
    exit
fi
if [[ $# != 2 ]]; then
    printf 'Usage: %s APP or %s SIMULATOR_UDID BUNDLE_ID\n' "$0" "$0" >&2
    exit 2
fi
sim=$1
bundle=$2
container=$(xcrun simctl get_app_container "$sim" "$bundle" data)
work="$container/Documents/interactive-state-ci"
mkdir "$work"
bash "$root/url-logging/check.sh" "$sim" "$bundle" --confirm-open
# The installed Dash, not the host, expands HOME and each status.
# shellcheck disable=SC2016
command='dash -c '\''cd "$HOME/Documents/interactive-state-ci" || exit 2; interactive-state > first.out 2> first.err; echo $? > first.status; interactive-state > second.out 2> second.err; echo $? > second.status; echo NEXT_COMMAND > complete'\'''
xcrun simctl openurl "$sim" "ashellmini:$(jq -nr --arg command "$command" '$command | @uri')"
for ((attempt=0; attempt<300; attempt++)); do
    if [[ -s $work/complete ]]; then break; fi
    sleep 0.2
done
if [[ ! -s $work/complete ]]; then
    printf 'Interactive-state app command did not finish\n' >&2
    ls -la "$work" >&2
    exit 1
fi
failed=0
for call in first second; do
    printf 'interactive-state %s: status=%s\n' "$call" "$(cat "$work/$call.status")"
    grep -Fxq 0 "$work/$call.status" || failed=1
    printf '0 1 0\n0 1 0\n' | diff -u - "$work/$call.out" || failed=1
    test ! -s "$work/$call.err" || failed=1
done
grep -Fx NEXT_COMMAND "$work/complete"
test "$failed" -eq 0
printf 'APP_INTERACTIVE_STATE_PASS\n'
