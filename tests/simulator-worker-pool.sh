#!/bin/bash
# Run the existing native consumer through a disposable mini app and its workers.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ $# == 2 ]]; then
    source_app=${1:?Pass a built mini Simulator app}
    ios_headers=${2:?Pass the matching Simulator ios_system.framework with headers}
    scratch=$(mktemp -d)
    trap 'rm -r "$scratch"' EXIT
    app="$scratch/$(basename "$source_app")"
    ditto "$source_app" "$app"
    name=WorkerPoolChecks
    framework="$app/Frameworks/$name.framework"
    mkdir "$framework"
    xcrun --sdk iphonesimulator clang -target "$(uname -m)-apple-ios15.0-simulator" -dynamiclib -fobjc-arc \
        -F"$(dirname "$ios_headers")" -framework ios_system -framework Foundation \
        -Wl,-install_name,"@rpath/$name.framework/$name" "$root/worker-pool.m" -o "$framework/$name"
    cp "$app/Frameworks/ios_system.framework/Info.plist" "$framework/Info.plist"
    bundle=$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist")
    plutil -replace CFBundleIdentifier -string "$bundle.ci.$name" "$framework/Info.plist"
    plutil -replace CFBundleExecutable -string "$name" "$framework/Info.plist"
    plutil -replace CFBundleName -string "$name" "$framework/Info.plist"
    codesign --force --sign - "$framework"
    register() {
        local target=$1 command=$2 function=$3 library=$4
        plutil -insert "$command" -json "[\"$library\",\"$function\",\"\",\"file\"]" "$target/commandDictionary.plist"
        touch "$target/bin/$command"
        chmod +x "$target/bin/$command"
    }
    register "$app" worker-pool-check worker_pool_check_main "$name.framework/$name"
    register "$app" worker-pool-host-payload worker_pool_host_payload_main "$name.framework/$name"
    shopt -s nullglob
    for worker in "$app"/Extensions/ShellWorker?.appex; do
        for cmd in crash nested nested-host payload; do
            register "$worker" "worker-pool-$cmd" "worker_pool_${cmd//-/_}_main" "@rpath/$name.framework/$name"
        done
        codesign --force --sign - "$worker"
    done
    bash "$root/simulator-app.sh" "$app" "$root/simulator-worker-pool.sh" --installed
    exit
fi
if [[ $# != 3 || $3 != --installed ]]; then
    printf 'Usage: %s MINI_APP IOS_SYSTEM_FRAMEWORK\n' "$0" >&2
    exit 2
fi
sim=$1
bundle=$2
container=$(xcrun simctl get_app_container "$sim" "$bundle" data)
work="$container/Documents/worker-pool-ci"
mkdir "$work"
bash "$root/url-logging/check.sh" "$sim" "$bundle" --confirm-open
status=0
for mode in default completion identity capacity limit lifecycle lifecycle-busy lifecycle-close loss nested host; do
    arg=$mode
    if [[ $mode == default ]]; then arg=; fi
    # Expand the application home and native command status inside Dash.
    # shellcheck disable=SC2016
    printf -v command 'dash -c '\''cd "$HOME/Documents/worker-pool-ci" || exit 2; worker-pool-check %s > %s.stdout 2> %s.stderr; echo $? > %s.status'\''' "$arg" "$mode" "$mode" "$mode"
    encoded=$(jq -nr --arg command "$command" '$command | @uri')
    xcrun simctl openurl "$sim" "ashellmini:$encoded"
    for ((attempt=0; attempt<600; attempt++)); do
        if [[ -s $work/$mode.status ]]; then break; fi
        sleep 0.5
    done
    if [[ ! -s $work/$mode.status ]]; then
        printf 'worker pool mode %s timed out\n' "$mode" >&2
        exit 1
    fi
    printf 'worker pool mode %s: exit=%s\n' "$mode" "$(cat "$work/$mode.status")"
    printf '%s\n' 'stdout:'
    tail -30 "$work/$mode.stdout"
    if [[ -s $work/$mode.stderr ]]; then
        printf '%s\n' 'stderr:'
        tail -30 "$work/$mode.stderr"
    fi
    if ! grep -Fxq 0 "$work/$mode.status" || ! grep -q ': PASS' "$work/$mode.stdout"; then status=1; fi
done
test "$status" -eq 0
printf 'APP_WORKER_POOL_PASS\n'
