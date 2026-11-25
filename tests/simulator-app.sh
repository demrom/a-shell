#!/bin/bash
# Install a disposable, ad hoc signed copy and invoke a host-side test driver.
set -euo pipefail
source_app=${1:?Pass the path to the built Simulator .app}
driver=${2:?Pass a host-side test driver}
shift 2
work=$(mktemp -d)
device=
cleanup() {
  local status=$?
  if [[ -n $device ]]; then
    xcrun simctl shutdown "$device" || true
    if ! xcrun simctl delete "$device"; then
      echo "Could not delete Simulator $device" >&2
      if [[ $status == 0 ]]; then status=1; fi
    fi
  fi
  if ! rm -r "$work" && [[ $status == 0 ]]; then status=1; fi
  exit "$status"
}
trap cleanup EXIT

# The generic build is unsigned. Install a copy with the app's own group so
# Foundation can provide the shared container; leave the original app intact.
app="$work/$(basename "$source_app")"
ditto "$source_app" "$app"
info="$app/Info.plist"
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")
group=$(/usr/libexec/PlistBuddy -c 'Print :AppGroupIdentifier' "$info")
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' \
  -c "Add :com.apple.security.application-groups:0 string $group" "$work/group.plist"
codesign --force --sign - --entitlements "$work/group.plist" "$app"

type=com.apple.CoreSimulator.SimDeviceType.iPhone-17
runtime=$(xcrun simctl list runtimes -j | jq -r --arg type "$type" --arg arch "$(uname -m)" \
  '[.runtimes[] | select(.isAvailable and (.identifier | contains("iOS")) and ($arch != "x86_64" or (.version | startswith("26."))) and any(.supportedDeviceTypes[]?; .identifier == $type))] | sort_by(.version | split(".") | map(tonumber)) | last.identifier // empty')
if [[ -z $runtime ]]; then
  echo 'No available iOS runtime supports iPhone 17' >&2
  exit 1
fi
device=$(xcrun simctl create AShell-Regressions "$type" "$runtime")
data=$(xcrun simctl list devices -j | jq -er --arg id "$device" '.devices[][] | select(.udid == $id) | .dataPath')
prefs="$data/Library/Preferences/.GlobalPreferences.plist"
# Use a known language for the system Open confirmation, not the host's locale.
mkdir -p "$(dirname "$prefs")"
if [[ ! -f $prefs ]]; then plutil -create xml1 "$prefs"; fi
plutil -replace AppleLanguages -json '["en-US"]' "$prefs"
plutil -replace AppleLocale -string en_US "$prefs"
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
bash "$driver" "$device" "$bundle" "$@"
