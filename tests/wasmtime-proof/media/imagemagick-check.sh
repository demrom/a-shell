#!/bin/bash
# Benchmark PNG decoding, real resizing and conversion to an 8-bit RGB PPM.
set -euo pipefail
if [[ $# != 1 || $1 != /* ]]; then
  echo 'usage: imagemagick-check.sh ABSOLUTE-CACHE' >&2
  exit 2
fi
cache=$1
fixtures=$cache/fixtures
echo "1d52f455f2db71d383d3216e28c106971df71dfb664fbaf24ab21a7f907866d8  $fixtures/input.png" | shasum -a 256 -c -
processes=$(ps -Ao comm)
if printf '%s\n' "$processes" | grep -E 'cargo|rustc|swift-build|swift-frontend|xcodebuild' >/dev/null; then
  echo 'Another heavy build is running; timing would be contaminated.' >&2
  exit 75
fi
command_text() {
  printf '%q ' "$@"
}
options=("$fixtures/input.png" -resize '1024x768!' -depth 8 -strip)
native=$(command_text nice -n 15 "$cache/im-native/utilities/magick" "${options[@]}" "ppm:$fixtures/native.ppm")
wasmkit=$(command_text nice -n 15 "$cache/runtimes/wasmkit" "$cache/im-wasi/utilities/magick" "${options[@]}" "ppm:$fixtures/wasmkit.ppm")
pulley=$(command_text nice -n 15 "$cache/runtimes/wasmtime" "$cache/im-wasi/utilities/magick" "${options[@]}" "ppm:$fixtures/pulley.ppm")
hyperfine --runs 5 --warmup 1 --shell=none --style basic --export-json "$cache/imagemagick-benchmark.json" \
  --command-name native-imagemagick "$native" --command-name wasmkit-imagemagick "$wasmkit" --command-name pulley-gc-imagemagick "$pulley"
processes=$(ps -Ao comm)
if printf '%s\n' "$processes" | grep -E 'cargo|rustc|swift-build|swift-frontend|xcodebuild' >/dev/null; then
  echo 'A heavy build started during timing; discard this benchmark.' >&2
  exit 75
fi
cmp "$fixtures/native.ppm" "$fixtures/wasmkit.ppm"
cmp "$fixtures/native.ppm" "$fixtures/pulley.ppm"
for output in native wasmkit pulley; do
  magick identify -format '%m %w %h %z\n' "$fixtures/$output.ppm" > "$cache/imagemagick-$output-validation.txt"
  grep -qx 'PPM 1024 768 8' "$cache/imagemagick-$output-validation.txt"
done
echo 'PASS: all real PNG resize/conversions produce identical 1024x768 8-bit RGB PPM files.'
