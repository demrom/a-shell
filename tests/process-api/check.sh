#!/bin/sh
# Run in a fresh a-Shell mini working directory with the fixture modules.
set -eu

case ${1-bootstrap} in
    bootstrap) fixtures=spawn:spawn-wait:0 ;;
    overlay) fixtures='spawn-c:posix-spawn:0 system:system:0 execvp:execvp:7 spawn-attributes:spawn-attributes:0' ;;
    *) printf 'Usage: %s [bootstrap|overlay]\n' "$0" >&2; exit 2 ;;
esac

run() {
    label=$1
    engine=$2
    module=$3
    python3 -c 'import time; print(time.monotonic_ns())' > "$label.ns"
    status=0
    "$engine" "$PWD/$module.wasm" > "$label.out" 2> "$label.err" || status=$?
    printf '%s\n' "$status" > "$label.status"
    python3 -c 'import time; print(time.monotonic_ns())' >> "$label.ns"
}

printf 'process-control-ok\n' > expected-control
printf 'process-worker-ok\n' > expected-worker
failed=0
for engine in wasm wasmkit; do
    run "$engine-control" "$engine" control
    if ! grep -qx 0 "$engine-control.status" ||
       ! diff expected-control "$engine-control.out" ||
       [ -s "$engine-control.err" ]; then
        printf '%s\n' "$engine: control failed" >&2
        failed=1
        continue
    fi
    for fixture in $fixtures; do
        name=${fixture%%:*}
        module=${fixture#*:}
        expected=${module#*:}
        run "$engine-$name" "$engine" "${module%:*}"
        if ! grep -qx "$expected" "$engine-$name.status" ||
           ! diff expected-worker "$engine-$name.out" ||
           [ -s "$engine-$name.err" ]; then
            printf '%s: %s failed\n' "$engine" "$name" >&2
            failed=1
        fi
    done
done
printf '%s\n' "$failed" > result
exit "$failed"
