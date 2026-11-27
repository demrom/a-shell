#!/bin/sh
# Run inside a-Shell mini; give the test its own fresh writable directory.
set -eu
mkdir "${1:?Specify a fresh fixture directory}"
cd "$1"
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST
gh --version | grep -F 'gh version 2.106.0'
status=0
gh api user >out.txt 2>err.txt || status=$?
test "$status" -eq 4
test ! -s out.txt
grep -F 'set GH_TOKEN to authenticate to github.com' err.txt
gh --version
