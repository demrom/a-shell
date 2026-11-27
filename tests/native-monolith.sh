#!/bin/sh
# Run inside a-Shell mini; give the test its own fresh writable directory.
set -eu
mkdir "${1:?Specify a fresh fixture directory}"
cd "$1"
printf '%s\n' '<html><head><title>Native Monolith</title></head><body><img src="pixel.svg"></body></html>' > index.html
printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>' > pixel.svg
monolith -q -M index.html -o standalone.html
grep -qF '<title>Native Monolith</title>' standalone.html
grep -F 'src="data:image/svg+xml' standalone.html
if monolith -q -M index.html -o absent/output.html; then
    echo 'monolith unexpectedly wrote to a missing directory' >&2
    exit 1
fi
monolith --version
echo 'monolith: output contains an embedded SVG; command survived a failed write'
if [ "$#" -ge 2 ]; then
    # The supplied HTTP fixture serves the same HTML and SVG as above.
    monolith -q -M -t 5 "$2" -o network.html
    grep -qF '<title>Native Monolith</title>' network.html
    grep -F 'src="data:image/svg+xml' network.html
fi
