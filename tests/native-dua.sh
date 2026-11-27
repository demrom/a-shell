#!/bin/sh
# Run inside a-Shell mini; give the test its own fresh writable directory.
set -eu
mkdir "${1:?Specify a fresh fixture directory}"
cd "$1"
mkdir 'test directory'
printf 1234567 >'test directory/seven-byte-file'
NO_COLOR=1 dua aggregate --apparent-size --format bytes --no-total 'test directory' > result.txt
grep -E '^[[:space:]]*7[[:space:]]+[bB][[:space:]]+.*seven-byte-file$' result.txt
dua --version
