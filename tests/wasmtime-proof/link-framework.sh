#!/bin/bash
set -euo pipefail
if [[ $# != 3 ]]; then
  echo 'usage: link-framework.sh STATICLIB OUTPUT-DIRECTORY IOS-SYSTEM-FRAMEWORK' >&2
  exit 2
fi
archive=$1
output=$2
core=$3
source_dir=$(cd "$(dirname "$0")" && pwd)
[[ -f "$archive" && -f "$core/ios_system" ]]
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
bundle="$output/WasmtimeCommand.framework"
mkdir -p "$bundle"
# Link the same C entry and contract into each matched runtime variant.
nice -n 15 xcrun --sdk iphoneos clang -target arm64-apple-ios26.2 -isysroot "$sdk" \
  -O2 -Wall -Wextra -Werror -fPIC -dynamiclib -DASHELL_P3_EMBEDDED_CONTRACT \
  "$source_dir/entry.c" "$source_dir/worker.c" "$source_dir/ffi-contract.c" "$archive" \
  -F "$(dirname "$core")" -framework ios_system -framework Security \
  -Wl,-dead_strip -Wl,-install_name,@rpath/WasmtimeCommand.framework/WasmtimeCommand \
  -Wl,-exported_symbol,_wasmtime_main -Wl,-exported_symbol,_p3contract_ios_main \
  -o "$bundle/WasmtimeCommand.new"
xcrun strip -S -x "$bundle/WasmtimeCommand.new"
mv "$bundle/WasmtimeCommand.new" "$bundle/WasmtimeCommand"
cat > "$bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.example.wasmtime-command</string>
<key>CFBundleName</key><string>WasmtimeCommand</string>
<key>CFBundleExecutable</key><string>WasmtimeCommand</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
<key>MinimumOSVersion</key><string>26.2</string>
</dict></plist>
PLIST
xcrun vtool -show-build "$bundle/WasmtimeCommand"
xcrun nm -gU "$bundle/WasmtimeCommand"
shasum -a 256 "$archive" "$core/ios_system" "$bundle/WasmtimeCommand"
stat -f '%N %z bytes' "$bundle/WasmtimeCommand"
