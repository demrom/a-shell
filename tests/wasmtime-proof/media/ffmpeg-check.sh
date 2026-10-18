#!/bin/bash
# Measure real CLI work, then validate the encoded video through public tools.
set -euo pipefail
if [[ $# != 1 || $1 != /* ]]; then
  echo 'usage: ffmpeg-check.sh ABSOLUTE-CACHE' >&2
  exit 2
fi
cache=$1
fixtures=$cache/fixtures
echo "956fb7fee25722e40df2e14360a50c1ea6b4ce1d4724dbf09e6362b18ab0d85a  $fixtures/input.avi" | shasum -a 256 -c -
processes=$(ps -Ao comm)
if printf '%s\n' "$processes" | grep -E 'cargo|rustc|swift-build|swift-frontend|xcodebuild' >/dev/null; then
  echo 'Another heavy build is running; timing would be contaminated.' >&2
  exit 75
fi
command_text() {
  printf '%q ' "$@"
}
options=(-hide_banner -loglevel error -nostdin -threads 1 -filter_threads 1)
encode=(-an -vf scale=160:90 -c:v mpeg4 -threads 1 -q:v 5 -fflags +bitexact -flags +bitexact -map_metadata -1 -y)
native=$(command_text nice -n 15 "$cache/ffmpeg-native9/ffmpeg" "${options[@]}" -i "$fixtures/input.avi" "${encode[@]}" "$fixtures/native.avi")
wasi=$(command_text nice -n 15 "$cache/wasmkit-build/release/wasmkit-cli" run --wasi-threads --dir "$fixtures::/work" "$cache/ffmpeg-wasi9-threads/ffmpeg" "${options[@]}" -i /work/input.avi "${encode[@]}" /work/wasmkit.avi)
hyperfine --runs 5 --warmup 1 --shell=none --style basic --export-json "$cache/ffmpeg-benchmark.json" \
  --command-name native-ffmpeg9 "$native" --command-name wasmkit-ffmpeg9 "$wasi"
processes=$(ps -Ao comm)
if printf '%s\n' "$processes" | grep -E 'cargo|rustc|swift-build|swift-frontend|xcodebuild' >/dev/null; then
  echo 'A heavy build started during timing; discard this benchmark.' >&2
  exit 75
fi
cmp "$fixtures/native.avi" "$fixtures/wasmkit.avi"
for output in native wasmkit; do
  echo "7229e72cc41fd5b79205a2be79a50b8004d6c39cc704e5e6ff3c9b3fa9f7aeed  $fixtures/$output.avi" | shasum -a 256 -c -
  ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,nb_frames,duration -of json "$fixtures/$output.avi" > "$cache/ffmpeg-$output-validation.json"
  jq -e '.streams | length == 1' "$cache/ffmpeg-$output-validation.json" >/dev/null
  jq -e '.streams[0] | .codec_name == "mpeg4" and .width == 160 and .height == 90 and .nb_frames == "150" and .duration == "10.000000"' "$cache/ffmpeg-$output-validation.json" >/dev/null
done
echo 'PASS: both real transcodes have identical bytes and 150 MPEG-4 frames at 160x90 over 10 seconds.'
