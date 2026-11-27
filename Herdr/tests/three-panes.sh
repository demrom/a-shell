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
cp "$fixtures/native-cpu.awk" "$fixtures/native-cpu-pane.sh" "$fixtures/native-interrupt-pane.sh" "$receipts/"
mkdir "$receipts/"{a,b,c}-cpu
steps=$(mktemp)
diagnostics=${HERDR_TEST_LOG_DIR:-}
started=$(date '+%Y-%m-%d %H:%M:%S')
if [[ -n $diagnostics ]]; then mkdir -p "$diagnostics"; fi

record_phase() {
	if [[ -n $diagnostics ]]; then
		{
			printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"
			ps -axo pid=,comm= | awk -v prefix="$app/Extensions/ShellWorker" 'index($0, prefix)'
		} >> "$diagnostics/phases.log"
	fi
}

input_time() {
	perl -MTime::HiRes=time -e 'printf "%.3f", time'
}

run_batch() {
	local phase=$1 status=0
	if [[ -z $diagnostics ]]; then
		axe batch --udid "$sim" --file "$steps" >/dev/null
		return
	fi
	printf '%s %s HID batch start\n' "$(input_time)" "$phase" >> "$diagnostics/input-timing.log" || true
	axe batch --udid "$sim" --file "$steps" --verbose >/dev/null \
		2> "$diagnostics/hid-$phase.stderr" || status=$?
	printf '%s %s HID batch exit=%s\n' "$(input_time)" "$phase" "$status" >> "$diagnostics/input-timing.log" || true
	if ((status != 0)); then tail -25 "$diagnostics/hid-$phase.stderr" >&2 || true; fi
	return "$status"
}

before_focus_deadline() {
	local remaining=$(($1 - SECONDS))
	shift
	((remaining > 0)) || return 124
	if ((remaining > 25)); then remaining=25; fi
	perl -e 'alarm shift; exec @ARGV or die $!' "$remaining" "$@"
}

terminal_responder() {
	# An in-app AX tree (or a successful HID send) alone cannot prove keyboard focus.
	local predicate='(category == "KeyboardSceneDelegate" AND composedMessage CONTAINS "_inputViewsForResponder: <") OR (category == "Client" AND composedMessage CONTAINS "resignFirstResponder")'
	before_focus_deadline "$1" xcrun simctl spawn "$sim" log show \
		--info --start "$started" --style compact --process "$host_pid" --predicate "$predicate" |
		awk '/_inputViewsForResponder:|resignFirstResponder/ { last = $0 } END { print last }'
}

focus_terminal() {
	local phase=$1 tap_required=$2 deadline=$((SECONDS + 90)) tapped=0 closed='' tree='' tip latest=''
	local prior='' stable_since=0
	local x=130 y=260
	while ((SECONDS < deadline)); do
		if tree=$(before_focus_deadline "$deadline" axe describe-ui --udid "$sim") &&
			jq -e --argjson pid "$host_pid" --argjson x "$x" --argjson y "$y" '
				any(.. | objects; .type? == "TextArea" and .pid == $pid and .enabled == true and
					(.frame | .x <= $x and .x + .width > $x and .y <= $y and .y + .height > $y))' <<<"$tree" >/dev/null; then
			if jq -e 'any(.. | objects; .AXUniqueId? == "PopoverDismissRegion")' <<<"$tree" >/dev/null; then
				stable_since=0
				# Closing Extra keys can expose the app's next toolbar tip. Tap only the single
				# Close button on a tree with one of these known headings.
				if tip=$(jq -er '
					[.. | objects] as $nodes |
					select([$nodes[] | select(.type? == "Button" and .AXUniqueId == "xmark.circle.fill")] |
						length == 1 and .[0].enabled == true and .[0].AXLabel == "Close") |
					[$nodes[] | select(.type? == "Heading") | .AXLabel |
						if . == "Extra keys: tab, control, escape, paste and the four arrows" then "extra-keys"
						elif . == "Arrows: flick to move once, keep holding to repeat" then "arrows" else empty end] |
					unique | select(length == 1) | first' <<<"$tree") && [[ $tip != "$closed" ]]; then
					if [[ -n $diagnostics ]]; then printf '%s\n' "$tree" > "$diagnostics/$phase-$tip.ax.json"; fi
					if before_focus_deadline "$deadline" axe tap --udid "$sim" --id xmark.circle.fill --element-type Button; then
						printf 'Dismissed toolbar tip: %s\n' "$tip"
						closed=$tip
						tapped=0
						tap_required=1
					fi
				fi
			else
				closed=
				if ! latest=$(terminal_responder "$deadline"); then latest=''; fi
				if ((tap_required == 0)) && [[ $latest == *'_inputViewsForResponder: <'*'.ConfirmingTerminalView: '* ]]; then
					# A tap on an already focused terminal need not emit a new UIKit event.
					# Require the same responder and an unobstructed tree across a quiet window.
					if ((stable_since == 0)) || [[ $latest != "$prior" ]]; then
						stable_since=$SECONDS
						prior=$latest
					elif ((SECONDS - stable_since >= 5)); then
						if [[ -n $diagnostics ]]; then printf '%s\n' "$tree" > "$diagnostics/$phase-focused.ax.json"; fi
						printf 'Herdr terminal first responder (%s): %s\n' "$phase" "$latest"
						return 0
					fi
				else
					stable_since=0
				fi
				if ((tapped == 0 && stable_since == 0)); then
					if [[ -n $diagnostics ]]; then printf '%s\n' "$tree" > "$diagnostics/$phase-before-tap.ax.json"; fi
					before_focus_deadline "$deadline" axe tap --udid "$sim" -x "$x" -y "$y" || return
					tapped=1
					tap_required=0
				fi
			fi
		else
			stable_since=0
		fi
		sleep 0.3
	done
	if [[ -n $diagnostics ]]; then printf '%s\n' "$tree" > "$diagnostics/$phase-focus-timeout.ax.json"; fi
	printf 'Herdr terminal did not gain first responder (%s): %s\n' "$phase" "$latest" >&2
	return 1
}

# Invoked by the EXIT trap, before the disposable Simulator is deleted.
# shellcheck disable=SC2329
finish() {
	local status=$? name pane file log_index=0
	local predicate='process BEGINSWITH "ShellWorker" AND (composedMessage CONTAINS "Documents capability" OR composedMessage CONTAINS "columns" OR composedMessage CONTAINS "Terminating")'
	if [[ -n $diagnostics ]]; then
		record_phase "fixture exit $status" || true
		cp -R "$receipts" "$diagnostics/fixtures" || true
		while IFS= read -r -d '' file; do
			log_index=$((log_index + 1))
			cp "$file" "$diagnostics/$log_index-${file##*/}" || true
		done < <(find "$data" -type f \( -name herdr-client.log -o -name herdr.log \) -print0)
		xcrun simctl spawn "$sim" log show --start "$started" --style compact \
			--predicate "$predicate" > "$diagnostics/worker-system.log" 2>&1 || true
		local focus='(process IN {"SpringBoard", "backboardd", "a-Shell-mini"}) AND (category CONTAINS[c] "focus" OR composedMessage CONTAINS[c] "focus" OR composedMessage CONTAINS[c] "first responder" OR composedMessage CONTAINS[c] "keyboard" OR composedMessage CONTAINS[c] "alert" OR composedMessage CONTAINS[c] "modal")'
		xcrun simctl spawn "$sim" log show --info --start "$started" --style compact \
			--predicate "$focus" > "$diagnostics/focus-system.log" 2>&1 || true
	fi
	if [[ $status != 0 ]]; then
		if [[ -n $diagnostics ]]; then
			tail -25 "$diagnostics/worker-system.log" >&2 || true
		else
			xcrun simctl spawn "$sim" log show --last 5m --style compact \
				--predicate "$predicate" | tail -25 >&2 || true
		fi
		for name in a a-after-idle b c eof.out eof.status eof.worker eof.next interrupt.ready interrupt.out interrupt.returned interrupt.next detached reentry; do
			if [[ -f $receipts/$name ]]; then
				printf 'receipt %s:\n' "$name" >&2
				tail -4 "$receipts/$name" >&2
			else
				printf 'receipt %s missing\n' "$name" >&2
			fi
		done
		for pane in a b c; do
			for name in ready result error finished; do
				if [[ -f $receipts/$pane-cpu/$name ]]; then
					printf 'CPU receipt %s/%s:\n' "$pane" "$name" >&2
					tail -4 "$receipts/$pane-cpu/$name" >&2
				fi
			done
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
	local attempt name="${1#"$receipts/"}"
	for ((attempt = 0; attempt < 200; attempt++)); do
		if [ -s "$1" ]; then
			if [[ -n $diagnostics ]]; then
				printf '%s %s receipt mtime_size=%s\n' "$(input_time)" "$name" \
					"$(stat -f '%m,%z' "$1")" >> "$diagnostics/input-timing.log" || true
			fi
			return 0
		fi
		sleep 0.1
	done
	if [[ -n $diagnostics ]]; then
		printf '%s %s receipt timeout mtime_size=%s\n' "$(input_time)" "$name" \
			"$(stat -f '%m,%z' "$1" 2>/dev/null || printf absent)" >> "$diagnostics/input-timing.log" || true
	fi
	echo "missing or empty receipt: $1" >&2
	record_phase "missing or empty receipt ${1##*/}" || true
	# Record the active UI while the missing command is still on screen.
	axe describe-ui --udid "$sim" --minimal-keys |
		jq -c '[.. | objects | select(.AXLabel? != null) | {type, AXLabel, AXUniqueId}] | .[:20]' >&2 || true
	return 1
}

# Start at a fresh shell, with default Herdr keybindings and tab-name prompts.
if [[ ${4:-} == --confirm-open ]]; then
	root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
	sh "$root/tests/url-logging/check.sh" "$sim" "$bundle" --confirm-open
fi
launch=$(xcrun simctl launch "$sim" "$bundle")
host_pid=${launch##*: }
if [[ ! $host_pid =~ ^[1-9][0-9]*$ ]]; then
	printf 'Could not read Simulator app PID: %s\n' "$launch" >&2
	exit 1
fi
record_phase "start Herdr from host $host_pid" || true
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
record_phase 'first worker observed' || true
# Fresh Herdr opens its welcome dialog; Return continues to optional agent
# settings, and Escape closes settings without installing integrations.
# Without this, the first command's Return only advances onboarding.
sleep 2
focus_terminal onboarding 1
printf 'key 40\nsleep 1\nkey 41\nsleep 1\n' >"$steps"
run_batch onboarding
focus_terminal pane-input 0
record_phase 'onboarding keys sent' || true
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
	run_batch "pane-$pane"
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
		run_batch idle
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
		run_batch "cpu-$pane"
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
	if [[ $attempt == 240 ]]; then
		echo 'Three native AWK workloads did not finish' >&2
		for index in "${!pids[@]}"; do
			pid=${pids[index]}
			printf 'Worker %s CPU time before release: %ss\n' "$pid" "${before[index]}" >&2
			ps -p "$pid" -o pid -o stat -o time -o %cpu >&2 || true
		done
		exit 1
	fi
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
		printf '1249999975000000\n' | cmp - "$receipts/$pane-cpu/result"
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
	run_batch eof
	wait_output "$receipts/eof.next"
	printf 'EOF_FOREGROUND_BYTES\n' | cmp - "$receipts/eof.out"
	printf '0\n' | cmp - "$receipts/eof.status"
	cmp "$receipts/c" "$receipts/eof.worker"
	printf 'EOF_FOLLOWUP\n' | cmp - "$receipts/eof.next"
	printf 'HERDR_COMMAND_EOF_PASS worker=%s\n' "${pids[2]}"

	# A nested shell starts a foreground reader. Send Ctrl-C only after
	# readiness, then type the next line without waiting for a new prompt.
	printf -v command 'sh ~/Documents/%s/native-interrupt-pane.sh' "${receipts##*/}"
	type_command "$command" >"$steps"
	run_batch interrupt-ready
	wait_output "$receipts/interrupt.ready"
	type_command 'INTERRUPT_FOREGROUND' >"$steps"
	run_batch interrupt-input
	wait_output "$receipts/interrupt.out"
	printf 'INTERRUPT_FOREGROUND\n' | cmp - "$receipts/interrupt.out"
	test ! -e "$receipts/interrupt.returned"
	{
		printf 'key-combo --modifiers 224 --key 6\n'
		printf -v command 'printenv ASHELL_WORKER_PID > ~/Documents/%s/interrupt.next' "${receipts##*/}"
		type_command "$command"
	} >"$steps"
	run_batch interrupt-next
	wait_output "$receipts/interrupt.next"
	cmp "$receipts/c" "$receipts/interrupt.next"
	printf 'HERDR_NESTED_INTERRUPT_PASS worker=%s\n' "${pids[2]}"
fi

# Leave the real shell usable and prove same-process command re-entry.
record_phase 'send detach' || true
printf 'key-combo --modifiers 224 --key 5\nsleep 0.4\ntype q\nsleep 3\n' >"$steps"
# Worker shells set ASHELL_WORKER_PID; a version command via URL alone could
# succeed even if the terminal never left the attached client.
printf -v command 'printenv ASHELL_WORKER_PID > ~/Documents/%s/detached' "${receipts##*/}"
type_command "$command" >>"$steps"
printf -v command 'herdr --version > ~/Documents/%s/reentry' "${receipts##*/}"
type_command "$command" >>"$steps"
run_batch detach
wait_output "$receipts/reentry"
test -f "$receipts/detached"
test ! -s "$receipts/detached"
printf 'herdr 0.9.3\n' | cmp - "$receipts/reentry"
kill -0 "$host_pid"
current_host=$(xcrun simctl launch "$sim" "$bundle")
test "${current_host##*: }" = "$host_pid"
printf 'detach and same-process re-entry: PASS\nreceipts: %s\n' "$receipts"
exit "$failed"
