#!/bin/bash
# Exercise native toolbar actions through the visible terminal and Simulator clipboard.
set -euo pipefail
sim=${1:?Pass a Simulator UDID}
bundle=${2:?Pass the app bundle identifier}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
documents=$(xcrun simctl get_app_container "$sim" "$bundle" data)/Documents
mkdir -p "$documents"
# Configure the two actions through the same per-user file as on a device.
printf 'selection.pin.in.out systemAction selectAll\nseparator\ndoc.on.doc systemAction copy\n' > "$documents/.toolbarDefinition"
nonce=$(uuidgen | tr -d '-')
expected="TOOLBAR_COPY_$nonce"
sentinel="COPY_NOT_RUN_$nonce"
# A normal startup profile emits the complete line only as rendered output.
receipt="$documents/toolbar-copy.txt"
complete="$documents/toolbar-profile.complete"
printf 'echo %s | pbcopy\necho %s\necho ready > %q\n' "$sentinel" "$expected" "$complete" > "$documents/.profile"
bash "$root/url-logging/check.sh" "$sim" "$bundle" --confirm-open
launch=$(xcrun simctl launch "$sim" "$bundle")
pid=${launch##*: }
grep -Fxq ready "$complete"
# An iPhone 17 terminal tap brings the software keyboard into view. The first
# keyboard launch can show the system QuickPath introduction over the toolbar.
axe tap --udid "$sim" -x 130 -y 260
if axe tap --udid "$sim" --element-type Button --label Continue --wait-timeout 2; then
    axe tap --udid "$sim" -x 130 -y 260
fi

# Image-backed toolbar buttons expose the configured action as their AX label.
axe tap --udid "$sim" --element-type Button --label selectAll --wait-timeout 5
axe tap --udid "$sim" --element-type Button --label copy --wait-timeout 5
# Read the running app's UIKit pasteboard through its public pbpaste command.
printf -v command 'pbpaste > %q' "$receipt"
encoded=$(jq -nr --arg command "$command" '$command | @uri')
xcrun simctl openurl "$sim" "${ASHELL_TEST_URL_SCHEME:-ashellmini}:$encoded"
for ((attempt=0; attempt<40; attempt++)); do
    kill -0 "$pid"
    if [[ -s $receipt ]] && tr -d '\r' < "$receipt" | grep -Fx "$expected" >/dev/null; then
        printf 'APP_TOOLBAR_COPY_PASS same_pid=%s\n' "$pid"
        exit 0
    fi
    sleep 0.25
done
printf 'Toolbar Copy did not put the exact rendered line on the app pasteboard\n' >&2
if [[ -f $receipt ]]; then
    if grep -Fxq "$sentinel" "$receipt"; then
        printf 'The in-app seed was not replaced by the Copy action\n' >&2
    else
        printf 'Pasteboard bytes: %s\n' "$(wc -c < "$receipt")" >&2
    fi
fi
exit 1
