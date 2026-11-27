#!/bin/sh
# Run inside one real Herdr pane. The host releases all three workers together.
set -eu
case $1 in a|b|c) ;; *) exit 2 ;; esac
cd "$HOME/Documents/$2/$1-cpu"
export HERDR_CPU_PROBE="$1-cpu"
printf '%s\n' "$HERDR_CPU_PROBE" > relative.txt
printf '%s\n' "$ASHELL_WORKER_PID" "$PWD" "$HERDR_CPU_PROBE" > ready
# The host releases the barrier after typing into all three panes. Its
# Simulator cleanup bounds the wait even when AXe is slow to set up other panes.
while [ ! -f ../start ]; do
    sleep 1
done
awk -f ../native-cpu.awk > result 2> error
printf '%s\n' "$ASHELL_WORKER_PID" "$PWD" "$HERDR_CPU_PROBE" > finished
