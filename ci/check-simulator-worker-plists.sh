#!/bin/bash
# Validate ExtensionKit metadata on a staged Mini before signing the host.
set -euo pipefail
if [[ $# != 2 || ( $1 != check && $1 != repair ) ]]; then
    echo "Usage: $0 check|repair STAGED_SIMULATOR_MINI.app" >&2
    exit 2
fi
mode=$1
app=$2
base=$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist")
expected="$base.ShellWorker"
count=$(plutil -extract ShellWorkerCount raw -o - "$app/Info.plist")
shopt -s nullglob
workers=("$app"/Extensions/ShellWorker?.appex)
if [[ ${#workers[@]} != "$count" ]]; then
    echo "Expected $count workers; found ${#workers[@]}" >&2
    exit 1
fi
key=EXAppExtensionAttributes.EXExtensionPointIdentifier
failed=0
for worker in "${workers[@]}"; do
    info="$worker/Info.plist"
    if actual=$(plutil -extract "$key" raw -o - "$info" 2>/dev/null); then
        if [[ $actual != "$expected" ]]; then
            printf '%s: expected %s, found %s\n' "${worker##*/}" "$expected" "$actual" >&2
            failed=1
        fi
    elif [[ $mode == repair ]]; then
        if ! plutil -extract EXAppExtensionAttributes xml1 -o /dev/null "$info" 2>/dev/null; then
            plutil -insert EXAppExtensionAttributes -dictionary "$info"
        fi
        plutil -insert "$key" -string "$expected" "$info"
        codesign --force --sign - --preserve-metadata=entitlements,identifier,flags "$worker"
        printf '%s: restored %s\n' "${worker##*/}" "$expected"
    else
        printf '%s: missing %s\n' "${worker##*/}" "$key" >&2
        failed=1
    fi
done
exit "$failed"
