#!/bin/bash
# Drive the real limited-library picker on the CI iPhone 17 Simulator.
set -euo pipefail
sim=${1:?Pass a Simulator UDID}
bundle=${2:?Pass the app bundle identifier}
work=${3:?Pass a directory with the A, B, and C PNG fixtures}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
container=$(xcrun simctl get_app_container "$sim" "$bundle" data)
docs="$container/Documents"
open_command() {
    local encoded
    encoded=$(jq -nr --arg command "$1" '$command | @uri')
    xcrun simctl openurl "$sim" "ashellmini:$encoded"
}
start_sync() {
    local stage=$1 command options=
    if [[ $stage == changed ]]; then options=' --select'; fi
    # The initial shell directory can be the app group, while Photos caches
    # in the app's own Documents. Use the installed container explicitly.
    printf -v command 'photos%s > %q 2> %q' "$options" "$docs/photos-$stage.stdout" "$docs/photos-$stage.stderr"
    open_command "$command"
}
point_matches() {
    local point=$1 filter=$2 item
    item=$(axe describe-ui --udid "$sim" --point "$point" --minimal-keys) || return
    jq -e "$filter" <<< "$item" >/dev/null
}
select_photos() {
    local x attempt
    # The picker is a remote Photos extension. Its cells are visible to point
    # queries even when the app-wide accessibility tree cannot enumerate them.
    local photo='.type == "Image" and .AXUniqueId == "PXGGridLayout-Info" and (.AXLabel | startswith("Photo, "))'
    local done='.type == "Button" and .AXUniqueId == "Update" and .AXLabel == "Done"'
    for ((attempt=0; attempt<30; attempt++)); do
        if point_matches 201,390 "$photo" 2>/dev/null && point_matches 364,144 "$done" 2>/dev/null; then break; fi
        sleep 0.5
    done
    if ((attempt == 30)); then printf 'Photos selection sheet did not open\n' >&2; return 1; fi
    # Freshly imported C, B and A are the left, middle and right cells.
    # The unchanged membership verifier independently checks their byte hashes.
    for x in "$@"; do
        point_matches "$x,390" "$photo"
        axe tap --udid "$sim" -x "$x" -y 390
        # Let the remote picker finish updating its selection before Done.
        sleep 1
    done
    point_matches 364,144 "$done"
    axe tap --udid "$sim" -x 364 -y 144
}
wait_for_sync() {
    local stage=$1 attempt stdout="$docs/photos-$1.stdout" stderr="$docs/photos-$1.stderr"
    for ((attempt=0; attempt<240; attempt++)); do
        if [[ -s $stdout || -s $stderr ]]; then break; fi
        sleep 0.5
    done
    if [[ -s $stderr ]]; then head -25 "$stderr" >&2; return 1; fi
    if [[ ! -s $stdout ]] || ! grep -Fxq \~/Documents/Photos "$stdout"; then
        xcrun simctl io "$sim" screenshot "$work/$stage-timeout.png" || true
        printf 'Photos %s did not return the cache path\n' "$stage" >&2
        return 1
    fi
    printf '%s\n' "$docs/Photos" > "$work/$stage-root.txt"
    # Run stat through the installed shell, just like the manual fixture. The
    # serialized app URL command runs after the preceding Photos call returns.
    local command
    # shellcheck disable=SC2016
    printf -v command 'dash -c '\''cd "$HOME/Documents" || exit 2; stat -f "%%N|%%i|%%m|%%z|%%Lp" "$HOME/Documents/Photos"/*/* > photos-%s.stat 2> photos-%s.stat-err; echo $? > photos-%s.stat-status'\''' "$stage" "$stage" "$stage"
    open_command "$command"
    for ((attempt=0; attempt<120; attempt++)); do
        if [[ -s $docs/photos-$stage.stat-status ]]; then break; fi
        sleep 0.5
    done
    if ! grep -Fxq 0 "$docs/photos-$stage.stat-status"; then
        head -15 "$docs/photos-$stage.stat-err" >&2
        return 1
    fi
    sh "$root/photos-membership.sh" "$stage" "$work/expected.json" "$work" "$docs/Photos" "$docs/photos-$stage.stat"
}
for asset in A B C; do
    xcrun simctl addmedia "$sim" "$work/$asset.png"
    sleep 1
done
# Launch the stock library once so the first limited-access request can open
# its picker service on a freshly booted Simulator.
xcrun simctl launch "$sim" com.apple.mobileslideshow
bash "$root/url-logging/check.sh" "$sim" "$bundle" --confirm-open
if axe describe-ui --udid "$sim" --minimal-keys | jq -e 'any(..|objects; .AXUniqueId? == "xmark.circle.fill" and .AXLabel? == "Close")' >/dev/null; then
    axe tap --udid "$sim" --id xmark.circle.fill --element-type Button
fi
jq -n --arg A "$(shasum -a 256 "$work/A.png" | cut -d' ' -f1)" \
    --arg B "$(shasum -a 256 "$work/B.png" | cut -d' ' -f1)" \
    --arg C "$(shasum -a 256 "$work/C.png" | cut -d' ' -f1)" '{A:$A,B:$B,C:$C}' > "$work/expected.json"
start_sync initial
for ((attempt=0; attempt<30; attempt++)); do
    if tree=$(axe describe-ui --udid "$sim" --minimal-keys) && coords=$(jq -er '
        [.. | objects | select(.type == "Button" and .enabled == true and
          (.AXLabel == "Limit Access…" or (.AXLabel == "Select Photos" and .AXUniqueId == "kTCCServicePhotos-limited-button"))) |
          [.frame.x + .frame.width / 2, .frame.y + .frame.height / 2] | map(floor)] | unique |
          select(length == 1) | first | @tsv' <<< "$tree"); then
        IFS=$'\t' read -r x y <<< "$coords"
        axe tap --udid "$sim" -x "$x" -y "$y"
        break
    fi
    sleep 0.5
done
if ((attempt == 30)); then printf 'Limited Photos permission button did not appear\n' >&2; exit 1; fi
select_photos 335 201
wait_for_sync initial
start_sync changed
select_photos 335 67
wait_for_sync changed
