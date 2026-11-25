#!/bin/bash
# Exercise the packaged Codex command in a disposable full a-Shell Simulator.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $# == 2 ]]; then
    bash "$root/tests/simulator-app.sh" "$1" "$root/tests/simulator-codex.sh" "$2"
    exit
fi
if [[ $# != 3 ]]; then
    printf 'Usage: %s FULL_APP terminal|login-logging|transport\n' "$0" >&2
    exit 2
fi
sim=$1
bundle=$2
mode=$3
container=$(xcrun simctl get_app_container "$sim" "$bundle" data)
work="$container/Documents/codex-ci"
mkdir -p "$work/home"
ASHELL_TEST_URL_SCHEME=ashell bash "$root/tests/url-logging/check.sh" "$sim" "$bundle" --confirm-open
case "$mode" in
terminal)
    cp "$root/codex/tests/terminal.sh" "$work/terminal.sh"
    printf '%s\n' 'dash terminal.sh' > "$work/run.sh"
    ;;
login-logging)
    cp "$root/codex/tests/login-logging.sh" "$work/run.sh"
    ;;
transport)
    uv run "$root/codex/tests/tool-transport.py" "$work/responses" > "$work/responses.log" 2>&1 &
    server=$!
    trap 'kill "$server" 2>/dev/null || true; wait "$server" || true' EXIT
    for ((attempt=0; attempt<120; attempt++)); do
        if [[ -s $work/responses/base-url.txt ]]; then break; fi
        kill -0 "$server"
        sleep 0.5
    done
    base=$(< "$work/responses/base-url.txt")
    printf 'model = "ci-responses-fixture"\nmodel_provider = "fixture"\napproval_policy = "never"\nsandbox_mode = "danger-full-access"\n[model_providers.fixture]\nname = "Loopback test fixture"\nbase_url = "%s"\nwire_api = "responses"\nrequires_openai_auth = false\n' "$base" > "$work/home/config.toml"
    printf '%s\n' "codex exec --skip-git-repo-check 'Run the fixture and report its result'" > "$work/run.sh"
    ;;
*) printf 'Unknown Codex test mode: %s\n' "$mode" >&2; exit 2 ;;
esac
# Expand HOME and the command status in the installed app's Dash.
# shellcheck disable=SC2016
command='dash -c '\''cd "$HOME/Documents/codex-ci" || exit 2; export CODEX_HOME="$PWD/home"; dash run.sh > stdout 2> stderr; echo $? > status; echo HOST_RESTORED > complete'\'''
encoded=$(jq -nr --arg command "$command" '$command | @uri')
xcrun simctl openurl "$sim" "ashell:$encoded"
for ((attempt=0; attempt<480; attempt++)); do
    if [[ -s $work/complete ]]; then break; fi
    sleep 0.5
done
for file in status stdout stderr responses.log; do
    if [[ -s $work/$file ]]; then printf '%s:\n' "$file"; tail -40 "$work/$file"; fi
done
grep -Fx HOST_RESTORED "$work/complete"
grep -Fx 0 "$work/status"
case "$mode" in
terminal) grep -Fx CODEX_CLI_PASS "$work/stdout" ;;
login-logging) grep -Fx CODEX_LOGIN_LOGGING_PASS "$work/stdout" ;;
transport)
    wait "$server"
    trap - EXIT
    jq -e '.passed and (.checks | length == 6) and all(.checks[]; .passed)' "$work/responses/receipt.json"
    grep -Fx TRANSPORT_PASS "$work/stdout"
    ;;
esac
