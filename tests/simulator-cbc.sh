#!/bin/bash
# Exercise the packaged command through the full app's normal startup profile.
set -euo pipefail
sim=${1:?Pass a Simulator UDID}
bundle=${2:?Pass the app bundle identifier}
problem=${3:?Pass the reference LP problem}
data=$(xcrun simctl get_app_container "$sim" "$bundle" data)
docs="$data/Documents"
mkdir -p "$docs"
cp "$problem" "$docs/cbc-ci.lp"
cat > "$docs/.profile" <<'PROFILE'
cd ~/Documents
cbc cbc-ci.lp -solve -solution cbc-ci.sol -quit > cbc-ci.stdout 2> cbc-ci.stderr
echo CBC_PROFILE_COMPLETE > cbc-ci.complete
PROFILE
launch=$(xcrun simctl launch "$sim" "$bundle")
pid=${launch##*: }
for ((attempt=0; attempt<120; attempt++)); do
    kill -0 "$pid"
    if [[ -s $docs/cbc-ci.complete ]]; then
        if grep -Fxq CBC_PROFILE_COMPLETE "$docs/cbc-ci.complete" &&
            grep -Fxq 'Optimal - objective value 10.00000000' "$docs/cbc-ci.sol" &&
            awk '$2 == "x" && $3 == 2 {x++} $2 == "y" && $3 == 2 {y++} END {exit !(x == 1 && y == 1)}' "$docs/cbc-ci.sol" &&
            kill -0 "$pid"; then
            printf 'APP_CBC_SOLVE_PASS objective=10 x=2 y=2\n'
            exit 0
        fi
        break
    fi
    sleep 0.5
done
printf 'Full app did not solve the reference LP (PID %s)\n' "$pid" >&2
for name in complete stdout stderr sol; do
    if [[ -f $docs/cbc-ci.$name ]]; then head -25 "$docs/cbc-ci.$name" >&2; fi
done
exit 1
