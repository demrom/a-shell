#!/bin/bash
# Exercise an installed disposable Simulator app through its public terminal UI.
set -euo pipefail
if [[ $# -lt 3 || $# -gt 4 || ( $# -eq 4 && ( $3 != ashellmini || $4 != --confirm-open ) ) ]]; then
	echo "usage: $0 SIMULATOR_UDID APP_BUNDLE_ID URL_SCHEME [--confirm-open (ashellmini only)]" >&2
	exit 2
fi
sim=$1
bundle=$2
scheme=$3
command -v axe >/dev/null
command -v jq >/dev/null
data=$(xcrun simctl get_app_container "$sim" "$bundle" data)
app=$(xcrun simctl get_app_container "$sim" "$bundle" app)
fixtures=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
receipts=$(mktemp -d "$data/Documents/herdr-ui.XXXXXX")
cp "$fixtures/native-cpu.awk" "$fixtures/native-cpu-pane.sh" "$receipts/"
mkdir "$receipts/"{a,b,c}-cpu
steps=$(mktemp)
# Invoked by the EXIT trap, before the disposable Simulator is deleted.
# shellcheck disable=SC2329
finish() {
	local status=$? name
	if [[ $status != 0 ]]; then
		xcrun simctl spawn "$sim" log show --last 5m --style compact \
			--predicate 'process BEGINSWITH "ShellWorker" AND (composedMessage CONTAINS "Documents capability" OR composedMessage CONTAINS "columns" OR composedMessage CONTAINS "Terminating")' \
			| tail -25 >&2 || true
		for name in a a-after-idle b c eof.out eof.status eof.worker eof.next detached reentry; do
			if [[ -f $receipts/$name ]]; then
				printf 'receipt %s:\n' "$name" >&2
				tail -4 "$receipts/$name" >&2
			else
				printf 'receipt %s missing\n' "$name" >&2
			fi
		done
	fi
	rm -f "$steps"
	exit "$status"
}
trap 'finish' EXIT

# HID bursts can overrun Simulator input. Preserve characters and modifier order.
type_command() {
	local character escaped
	while IFS= read -r -n 1 character; do
		escaped=${character//\\/\\\\}
		escaped=${escaped//\"/\\\"}
		printf 'type "%s"\nsleep 0.08\n' "$escaped"
	done < <(printf '%s' "$1")
	printf 'sleep 0.5\nkey 40\nsleep 2\n'
}
wait_output() {
	local attempt
	for ((attempt = 0; attempt < 200; attempt++)); do
		if [ -s "$1" ]; then return 0; fi
		sleep 0.1
	done
	echo "missing or empty receipt: $1" >&2
	return 1
}

# Start at a fresh shell, with default Herdr keybindings and tab-name prompts.
if [[ ${4:-} == --confirm-open ]]; then
	root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
	sh "$root/tests/url-logging/check.sh" "$sim" "$bundle" --confirm-open
fi
launch=$(xcrun simctl launch "$sim" "$bundle")
host_pid=${launch##*: }
xcrun simctl openurl "$sim" "$scheme:herdr"
# A newly booted Simulator can take longer than a fixed delay to launch the
# first extension. Do not send pane input until a worker is live.
worker_a="$app/Extensions/ShellWorkerA.appex/ShellWorkerA"
for ((attempt=0; attempt<300; attempt++)); do
	if ps -axo comm= | awk -v worker="$worker_a" '$0 == worker { found = 1 } END { exit !found }'; then break; fi
	sleep 0.2
done
if [[ $attempt == 300 ]]; then
	echo 'Herdr did not keep the first pane worker running' >&2
	exit 1
fi
# Fresh Herdr opens its welcome dialog; Return continues to optional agent
# settings, and Escape closes settings without installing integrations.
# Without this, the first command's Return only advances onboarding.
printf 'sleep 2\ntap -x 130 -y 260\nsleep 1\nkey 40\nsleep 1\nkey 41\nsleep 1\n' >"$steps"
axe batch --udid "$sim" --file "$steps" >/dev/null
pids=()
failed=0
for pane in a b c; do
	: >"$steps"
	if [ "$pane" != a ]; then
		# Ctrl+B,c opens a name dialog; Return creates the tab, not a shell command.
		printf 'key-combo --modifiers 224 --key 5\nsleep 0.4\ntype c\nsleep 0.5\n' >>"$steps"
		type_command "pane-$pane" >>"$steps"
	fi
	printf -v command 'printenv ASHELL_WORKER_PID > ~/Documents/%s/%s' "${receipts##*/}" "$pane"
	type_command "$command" >>"$steps"
	axe batch --udid "$sim" --file "$steps" >/dev/null
	if wait_output "$receipts/$pane"; then
		pid=$(cat "$receipts/$pane")
		case "$pid" in
		'' | *[!0-9]*) echo "invalid worker PID for pane $pane" >&2; failed=1 ;;
		*) pids+=("$pid") ;;
		esac
	else
		failed=1
	fi
	if [ "$pane" = a ]; then
		# Leave the first pane untouched, then require a new receipt from the same worker.
		sleep 15
		printf -v command 'printenv ASHELL_WORKER_PID > ~/Documents/%s/a-after-idle' "${receipts##*/}"
		type_command "$command" >"$steps"
		axe batch --udid "$sim" --file "$steps" >/dev/null
		if wait_output "$receipts/a-after-idle" && cmp "$receipts/a" "$receipts/a-after-idle"; then
			printf 'same worker after 15s idle: PASS\n'
		else
			echo 'same worker after 15s idle: FAIL' >&2
			failed=1
		fi
	fi
	if [[ $failed == 0 ]]; then
		printf -v command 'sh ~/Documents/%s/native-cpu-pane.sh %s %s' "${receipts##*/}" "$pane" "${receipts##*/}"
		type_command "$command" >"$steps"
		axe batch --udid "$sim" --file "$steps" >/dev/null
		wait_output "$receipts/$pane-cpu/ready"
	fi
done
if [ "${#pids[@]}" -ne 3 ]; then
	echo 'did not get three pane receipts' >&2
	failed=1
elif [ "${pids[0]}" = "${pids[1]}" ] || [ "${pids[0]}" = "${pids[2]}" ] || [ "${pids[1]}" = "${pids[2]}" ]; then
	echo 'panes share a worker PID' >&2
	failed=1
fi
# Simulator workers are Mac processes. Verify all belong to this installed app
# and remain alive together after all three commands have produced output.
for pid in "${pids[@]+${pids[@]}}"; do
	worker=$(ps -p "$pid" -o comm=) || worker=
	case "$worker" in
	"$app"/Extensions/ShellWorker?.appex/ShellWorker?) ;;
	*)
		echo "PID $pid is not a live worker of the tested app" >&2
		failed=1
		;;
	esac
done
if [ "$failed" -eq 0 ]; then
	printf 'three concurrent workers: %s %s %s\n' "${pids[@]}"
	monotonic_seconds() { perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%.6f\n", clock_gettime(CLOCK_MONOTONIC)'; }
	worker_cpu_seconds() { LC_ALL=C ps -p "$1" -o time= | awk -F: 'NF != 2 {exit 1} {printf "%.2f\n", $1*60+$2}'; }
	before=()
	start=$(monotonic_seconds)
	for pid in "${pids[@]}"; do before+=("$(worker_cpu_seconds "$pid")"); done
	touch "$receipts/start"
	for ((attempt=0; attempt<240; attempt++)); do
		if [[ -s $receipts/a-cpu/finished && -s $receipts/b-cpu/finished && -s $receipts/c-cpu/finished ]]; then break; fi
		sleep 0.5
	done
	if [[ $attempt == 240 ]]; then echo 'Three native AWK workloads did not finish' >&2; exit 1; fi
	deltas=()
	index=0
	for pane in a b c; do
		pid=${pids[index]}
		after=$(worker_cpu_seconds "$pid")
		deltas+=("$(awk -v a="$after" -v b="${before[index]}" 'BEGIN {print a-b}')")
		cmp "$receipts/$pane-cpu/ready" "$receipts/$pane-cpu/finished"
		[[ $(head -1 "$receipts/$pane-cpu/finished") == "$pid" ]]
		grep -Fqx "$pane-cpu" "$receipts/$pane-cpu/relative.txt"
		awk -v pane="$pane-cpu" 'NR==2 && $0 !~ ("/" pane "$") {exit 1} NR==3 && $0!=pane {exit 1} END {if (NR!=3) exit 1}' "$receipts/$pane-cpu/finished"
		awk 'NR!=1 || $1<1.99999e16 || $1>2.00001e16 {exit 1} END {if (NR!=1) exit 1}' "$receipts/$pane-cpu/result"
		index=$((index+1))
	done
	end=$(monotonic_seconds)
	awk -v a="${deltas[0]}" -v b="${deltas[1]}" -v c="${deltas[2]}" -v start="$start" -v end="$end" 'BEGIN {
		# Each ps reading rounds to centiseconds; bound the aggregate downward.
		cpu = a+b+c-0.06; wall = end-start
		passed = a>0 && b>0 && c>0 && cpu>wall
		printf "HERDR_CPU_OVERLAP_%s workers=3 cpu_lower=%.2f wall_upper=%.2f\n", passed ? "PASS" : "FAIL", cpu, wall
		exit !passed
	}'

	# Idle Ctrl-D is Delete. Foreground Ctrl-D ends only cat's input.
	{
		printf 'key-combo --modifiers 224 --key 7\nsleep 0.5\n'
		printf -v command 'cat > ~/Documents/%s/eof.out' "${receipts##*/}"
		type_command "$command"
		type_command 'EOF_FOREGROUND_BYTES'
		printf 'key-combo --modifiers 224 --key 7\nsleep 1\n'
		# Expand the preceding command status in the installed worker shell.
		# shellcheck disable=SC2016
		printf -v command 'echo $? > ~/Documents/%s/eof.status' "${receipts##*/}"
		type_command "$command"
		printf -v command 'printenv ASHELL_WORKER_PID > ~/Documents/%s/eof.worker' "${receipts##*/}"
		type_command "$command"
		printf -v command 'echo EOF_FOLLOWUP > ~/Documents/%s/eof.next' "${receipts##*/}"
		type_command "$command"
	} >"$steps"
	axe batch --udid "$sim" --file "$steps" >/dev/null
	wait_output "$receipts/eof.next"
	printf 'EOF_FOREGROUND_BYTES\n' | cmp - "$receipts/eof.out"
	printf '0\n' | cmp - "$receipts/eof.status"
	cmp "$receipts/c" "$receipts/eof.worker"
	printf 'EOF_FOLLOWUP\n' | cmp - "$receipts/eof.next"
	printf 'HERDR_COMMAND_EOF_PASS worker=%s\n' "${pids[2]}"
fi

# Leave the real shell usable and prove same-process command re-entry.
printf 'key-combo --modifiers 224 --key 5\nsleep 0.4\ntype q\nsleep 3\n' >"$steps"
# Worker shells set ASHELL_WORKER_PID; a version command via URL alone could
# succeed even if the terminal never left the attached client.
printf -v command 'printenv ASHELL_WORKER_PID > ~/Documents/%s/detached' "${receipts##*/}"
type_command "$command" >>"$steps"
printf -v command 'herdr --version > ~/Documents/%s/reentry' "${receipts##*/}"
type_command "$command" >>"$steps"
axe batch --udid "$sim" --file "$steps" >/dev/null
wait_output "$receipts/reentry"
test -f "$receipts/detached"
test ! -s "$receipts/detached"
printf 'herdr 0.9.3\n' | cmp - "$receipts/reentry"
kill -0 "$host_pid"
current_host=$(xcrun simctl launch "$sim" "$bundle")
test "${current_host##*: }" = "$host_pid"
printf 'detach and same-process re-entry: PASS\nreceipts: %s\n' "$receipts"
exit "$failed"
