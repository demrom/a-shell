#!/bin/sh
# Run both existing direct-login regressions in the same embedded host process.
set -eu
: "${CODEX_HOME:?Use a disposable Codex home}"
log="$CODEX_HOME/log/codex-login.log"
check_login_logging() {
    event=$1
    shift
    status=0
    RUST_LOG=codex_cli=info codex -c 'forced_login_method="api"' login "$@" > login.stdout 2> login.stderr || status=$?
    if [ "$status" -ne 1 ] || ! grep -qx 'ChatGPT login is disabled. Use API key login instead.' login.stderr; then
        printf 'Codex login policy: %s status=%s FAIL\n' "$event" "$status" >&2
        return 1
    fi
    if grep -q 'failed to initialize login log file' login.stderr; then
        grep -F 'failed to initialize login log file' login.stderr >&2
        return 1
    fi
    records=$(grep -c "$event" "$log" || true)
    printf 'Codex login log: %s records=%s expected=%s\n' "$event" "$records" "$_run"
    test "$records" -eq "$_run"
}
for _run in 1 2; do
    check_login_logging 'starting device code login flow' --device-auth
    check_login_logging 'starting browser login flow'
done
printf 'CODEX_LOGIN_LOGGING_PASS\n'
