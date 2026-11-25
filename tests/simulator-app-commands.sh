#!/bin/bash
# Run the existing app command fixtures through the installed app's public URL route.
set -euo pipefail
sim=${1:?Pass a Simulator UDID}
bundle=${2:?Pass the app bundle identifier}
mode=${3:?Pass commands, bundled-font, photos, or wasm}
input=${4:?Pass the font, JPEG, or compiled wasm-output.wasm fixture}
video=${5:-}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
container=$(xcrun simctl get_app_container "$sim" "$bundle" data)
documents="$container/Documents"
work="$documents/ashell-ci"
mkdir -p "$work"
case $mode in
    commands|bundled-font)
        mkdir -p "$documents/Fonts"
        cp "$input" "$documents/Fonts/Fixture.ttf"
        if [[ $mode == bundled-font ]]; then
            cp "$root/fonts-existing.sh" "$work/"
        else
            cp "$root/cloud-files.sh" "$root/fonts.sh" "$work/"
        fi
        ;;
    photos) ;; # Seed the disposable library after opening the app.
    wasm) cp "$input" "$work/wasm-output.wasm" ;;
    *) printf 'Unknown app fixture mode: %s\n' "$mode" >&2; exit 2 ;;
esac

# First contact may display the public Open-in confirmation. The existing URL
# consumer handles it, then ordinary calls use the same authorized route.
bash "$root/url-logging/check.sh" "$sim" "$bundle" --confirm-open
open_command() {
    local encoded
    encoded=$(jq -nr --arg command "$1" '$command | @uri')
    xcrun simctl openurl "$sim" "ashellmini:$encoded"
}
check_command() {
    local name=$1 count
    open_command "dash -c 'cd \"\$HOME/Documents/ashell-ci\" && dash $name.sh > $name.stdout 2> $name.stderr; echo \$? > $name.status'" || return
    for ((count=0; count<300; count++)); do
        if [[ -s "$work/$name.status" ]]; then
            if grep -Fxq 0 "$work/$name.status"; then return 0; fi
            printf '%s: app command exited %s\n' "$name" "$(< "$work/$name.status")" >&2
            tail -35 "$work/$name.stdout" "$work/$name.stderr" >&2
            return 1
        fi
        sleep 0.2
    done
    printf '%s: app command did not write a status receipt\n' "$name" >&2
    tail -15 "$work/$name.stdout" "$work/$name.stderr" 2>/dev/null || true
    return 1
}
pin_stream_writer() {
    local launch
    command -v lsof >/dev/null
    launch=$(xcrun simctl launch "$sim" "$bundle")
    app_pid=${launch##*: }
    kill -0 "$app_pid"
}
streams_closed() {
    local open_files status=0
    kill -0 "$app_pid" || return
    # Wait for descriptor closure on the actual Simulator app process.
    open_files=$(lsof -a -p "$app_pid" -- "$@" 2>&1) || status=$?
    if [[ $status == 1 && -z $open_files ]]; then return 0; fi
    if [[ $status != 0 ]]; then printf '%s\n' "$open_files" >&2; fi
    return 1
}
wait_for_streams() {
    local stderr_file=$1 count
    shift
    for ((count=0; count<150; count++)); do
        if [[ -f $stderr_file ]] && grep -Fxq err-2 "$stderr_file" && streams_closed "$stderr_file" "$@"; then
            return 0
        fi
        sleep 0.2
    done
    printf 'App did not finish writing WASM streams: %s\n' "${stderr_file##*/}" >&2
    if [[ -f $stderr_file ]]; then tail -12 "$stderr_file" >&2; fi
    return 1
}
if [[ $mode == photos ]]; then
    xcrun simctl addmedia "$sim" "$input"
    if [[ -n $video ]]; then
        command -v ffprobe >/dev/null
        xcrun simctl addmedia "$sim" "$video"
    fi
    xcrun simctl privacy "$sim" grant photos "$bundle"
    # TCC can stop the old app while changing its grant. Track the new writer.
    pin_stream_writer
    sync_photos() {
        local output="$work/$1" errors="$work/$2" command count
        # The URL route returns no command exit code. Every nonzero exit of
        # this Photos sync writes stderr; check it only after both streams close.
        printf -v command 'photos > %q 2> %q' "$output" "$errors"
        open_command "$command"
        for ((count=0; count<640; count++)); do
            kill -0 "$app_pid" || return 1
            if [[ -f $output && -f $errors && ( -s $output || -s $errors ) ]] && streams_closed "$output" "$errors"; then
                if [[ ! -s $errors ]] && printf '%s\n' \~/Documents/Photos | cmp - "$output"; then return 0; fi
                printf 'Photos reported a sync error: %s\n' "$1" >&2
                tail -20 "$errors" >&2
                return 1
            fi
            sleep 0.5
        done
        printf 'Photos did not finish the sync: %s\n' "$1" >&2
        return 1
    }
    snapshot_index() {
        jq -esS 'select(length == 1) | .[0] | select(type == "object" and length > 0 and all(.[]; .files | type == "object"))' \
            "$documents/Photos/.photos-index.json" > "$work/$1-index.json"
    }
    sync_photos photos-root.txt photos-first.err
    (cd "$work" && HOME="$container" sh "$root/photos.sh" before)
    snapshot_index before
    cached=$(find "$documents/Photos" -type f -exec cmp -s "$input" {} \; -print -quit)
    if [[ -z $cached ]]; then
        printf 'The imported JPEG is missing from the original-byte cache\n' >&2
        exit 1
    fi
    if [[ -n $video ]]; then
        if ! grep -Eq '^PHOTOS_GREEN originals=[1-9][0-9]* video_checked=1$' "$work/photos-success.txt"; then
            printf 'Photos did not produce a playable cached video\n' >&2
            cat "$work/photos-success.txt" >&2
            exit 1
        fi
        cached_video=$(find "$documents/Photos" -type f -exec cmp -s "$video" {} \; -print -quit)
        if [[ -z $cached_video ]]; then
            printf 'The imported MP4 is missing from the original-byte cache\n' >&2
            exit 1
        fi
    fi
    sync_photos photos-root-repeat.txt photos-repeat.err
    cmp "$input" "$cached"
    if [[ -n $video ]]; then cmp "$video" "$cached_video"; fi
    snapshot_index after
    diff -u "$work/before-index.json" "$work/after-index.json"
    (cd "$work" && HOME="$container" sh "$root/photos.sh" after)
    printf 'APP_PHOTOS_CACHE_PASS\n'
    exit 0
fi
if [[ $mode == bundled-font ]]; then
    check_command fonts-existing
    grep -Fxq 0 "$documents/fonts-existing-status.txt"
    grep -Fxq complete "$documents/fonts-existing-complete.txt"
    printf 'APP_FONT_COEXISTENCE_PASS\n'
    exit 0
fi
if [[ $mode == commands ]]; then
    failed=0
    if check_command cloud-files && grep -Fxq CLOUD_FILES_GREEN "$work/cloud-files.stdout"; then
        printf 'APP_CLOUD_FILES_PASS\n'
    else
        failed=1
    fi
    if check_command fonts && grep -Fxq complete "$documents/fonts-complete.txt" &&
        grep -Fq 'JetBrainsMonoNFM-Regular 17.0 pt' "$documents/fonts-selected.txt"; then
        printf 'APP_FONT_REGISTRATION_PASS\n'
    else
        failed=1
    fi
    exit "$failed"
fi
# WASM runs on the WebView bridge. Enter it directly through the app rather
# than using the status of a nested native Dash command that only queued it.
pin_stream_writer
wasm_failed=0
printf -v wasm_path '%q' "$work/wasm-output.wasm"
printf -v redirects '> %q 2>&1' "$work/combined.txt"
if open_command "wasm $wasm_path $redirects" && wait_for_streams "$work/combined.txt"; then
    printf 'out-1\nerr-1\nout-2\nerr-2\n' | diff -u - "$work/combined.txt" || wasm_failed=1
else
    wasm_failed=1
fi
printf -v redirects '> %q 2> %q' "$work/stdout.txt" "$work/stderr.txt"
if open_command "wasm $wasm_path $redirects" && wait_for_streams "$work/stderr.txt" "$work/stdout.txt" &&
    printf 'out-1\nout-2\n' | diff -u - "$work/stdout.txt" &&
    printf 'err-1\nerr-2\n' | diff -u - "$work/stderr.txt" && [[ $wasm_failed == 0 ]]; then
    printf 'APP_WASM_STREAMS_PASS\n'
else
    exit 1
fi
