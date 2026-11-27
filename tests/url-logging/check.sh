#!/bin/sh
# Host-side regression through the app's public command URL scheme.
set -eu
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ] || { [ "$#" -eq 3 ] && [ "$3" != --confirm-open ]; }; then
    printf 'usage: sh check.sh SIMULATOR_UDID APP_BUNDLE_ID [--confirm-open]\n' >&2
    exit 64
fi
udid=$1
bundle=$2
confirm=${3:-}
scheme=${ASHELL_TEST_URL_SCHEME:-ashellmini}
case "$scheme" in
    ashell|ashellmini) ;;
    *) printf 'Unknown app URL scheme: %s\n' "$scheme" >&2; exit 64 ;;
esac
if [ -n "$confirm" ]; then
    command -v axe >/dev/null
    command -v jq >/dev/null
    data=$(xcrun simctl list devices -j | jq -er --arg id "$udid" '.devices[][] | select(.udid == $id) | .dataPath')
    language=$(plutil -extract AppleLanguages.0 raw -o - "$data/Library/Preferences/.GlobalPreferences.plist")
    case "$language" in
        en|en-*) ;;
        *) printf 'The unattended confirmation requires an English Simulator.\n' >&2; exit 64 ;;
    esac
    app=$(xcrun simctl get_app_container "$udid" "$bundle" app)
    # The full app supplies only CFBundleName.
    if ! name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app/Info.plist" 2>/dev/null) || [ -z "$name" ]; then
        name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app/Info.plist")
    fi
    prompt='Open in “'"$name"'”?'
fi
container=$(xcrun simctl get_app_container "$udid" "$bundle" data)
receipt="$container/Documents/url-logging-$$.txt"
trap 'rm -f "$receipt"' EXIT
launch=$(xcrun simctl launch "$udid" "$bundle")
pid=${launch##*: }
# %25s decodes to literal %s in the command, rather than a logging format.
literal='URI_LOG_%s_OK'
xcrun simctl openurl "$udid" "$scheme:echo%20URI_LOG_%25s_OK%20%3E%20$receipt"
deadline=$(($(date +%s) + 120))
next_ui=0
prompt_taps=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
        printf 'FAIL: app exited while opening a URL containing %%s\n' >&2
        exit 1
    fi
    if [ -n "$confirm" ] && [ ! -s "$receipt" ] && [ "$(date +%s)" -ge "$next_ui" ]; then
        # SpringBoard can briefly return no accessibility tree. Use the Open
        # button from this exact sheet, not another global accessibility query.
        if tree=$(axe describe-ui --udid "$udid") && coords=$(printf '%s\n' "$tree" | jq -er --arg prompt "$prompt" '
            [.. | objects | select(.type == "Sheet" and .AXLabel == $prompt) |
                .. | objects | select(.type == "Button" and .AXLabel == "Open" and .enabled == true) |
                select(.frame.width > 0 and .frame.height > 0) |
                [.frame.x + .frame.width / 2, .frame.y + .frame.height / 2] | map(floor)] |
            unique | select(length == 1) | first | @tsv'); then
            IFS=$(printf '\t') read -r x y <<EOF
$coords
EOF
            if axe tap --udid "$udid" -x "$x" -y "$y" >/dev/null; then
                prompt_taps=$((prompt_taps + 1))
            fi
        fi
        next_ui=$(($(date +%s) + 2))
    fi
    if [ -s "$receipt" ]; then
        actual=$(cat "$receipt")
        if [ "$actual" != "$literal" ]; then
            printf 'FAIL: command output did not preserve literal %%s\n' >&2
            exit 1
        fi
        logs=$(xcrun simctl spawn "$udid" log show --last 10m --style compact --predicate "processIdentifier == $pid AND composedMessage CONTAINS 'url-logging-$$.txt' AND (composedMessage BEGINSWITH 'Calling openURLContexts with ' OR composedMessage BEGINSWITH 'We received an URL in openURLContexts:')")
        if ! printf '%s\n' "$logs" | grep -F 'We received an URL in openURLContexts:' >/dev/null; then
            sleep 0.2
            continue
        fi
        if ! printf '%s\n' "$logs" | grep -F "$literal" >/dev/null || ! printf '%s\n' "$logs" | grep -F 'URI_LOG_%25s_OK' >/dev/null; then
            printf 'FAIL: URL logging did not preserve literal %%s\n' >&2
            printf '%s\n' "$logs" >&2
            exit 1
        fi
        printf 'URL_LOGGING_PASS\n'
        exit 0
    fi
    sleep 0.2
done
printf 'FAIL: command receipt or matching log timed out (Open taps: %s)\n' "$prompt_taps" >&2
exit 1
