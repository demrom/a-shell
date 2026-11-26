#!/bin/sh
# Run inside one real Herdr pane. The host releases all three workers together.
set -eu
case $1 in a|b|c) ;; *) exit 2 ;; esac
cd "$HOME/Documents/$2/$1-cpu"
export HERDR_CPU_PROBE="$1-cpu"
printf '%s\n' "$HERDR_CPU_PROBE" > relative.txt
printf '%s\n' "$ASHELL_WORKER_PID" "$PWD" "$HERDR_CPU_PROBE" > ready
attempt=0
while [ ! -f ../start ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 180 ] || exit 2
    sleep 1
done
awk -f ../native-cpu.awk > result
printf '%s\n' "$ASHELL_WORKER_PID" "$PWD" "$HERDR_CPU_PROBE" > finished
