#!/bin/sh
# Run in a-Shell mini from this fixture directory after installing the CI catalog.
set -eu
out=${1:?pass a new receipt directory}
mkdir "$out"

run() {
    label=$1
    shift
    date +%s > "$out/$label.start"
    status=0
    "$@" > "$out/$label.stdout" 2> "$out/$label.stderr" || status=$?
    printf '%s\n' "$status" > "$out/$label.status"
    date +%s > "$out/$label.end"
}

run version rga --version
grep -Fx 'ripgrep-all 0.10.10' "$out/version.stdout"
test "$(cat "$out/version.status")" = 0
test ! -s "$out/version.stderr"

for extension in txt pdf docx epub zip txt.gz tar mp4; do
    run "$extension" rga --color=never --with-filename --rga-no-cache -- 'Second page' "corpus/search.$extension"
done
run no-match rga --color=never --rga-no-cache -- 'unmatched fixture token' corpus/search.pdf
printf '%s\n' 'shell-resumed' > "$out/resumed"

for extension in txt pdf docx epub zip txt.gz tar mp4; do
    test "$(cat "$out/$extension.status")" = 0
    test ! -s "$out/$extension.stderr"
    grep -F "corpus/search.$extension:" "$out/$extension.stdout" | grep -E 'Second page$'
done
test "$(cat "$out/no-match.status")" = 1
test ! -s "$out/no-match.stderr"
test ! -s "$out/no-match.stdout"
printf '%s\n' PASS > "$out/result"
