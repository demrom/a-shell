#!/usr/bin/env bash
# Build one product for device and both Simulator architectures, then package.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
product=${1:?Specify gh, monolith, or dua}
case $product in gh|monolith|dua) ;; *) exit 2 ;; esac
mkdir -p "${2:?Specify the work directory}" "${3:?Specify the artifact directory}"
work=$(cd "$2" && pwd -P)
dist=$(cd "$3" && pwd -P)

revision=df998e76cea0266bd3615bb9a1f4f7d745f318a2
checksum=6d2201c1dee131b831b8108b578ede560277d1c205fd8c64f2fb9dcd70e7baca
source=$(mktemp -d "$work/ios-system.XXXXXX")
trap 'rm -rf "$source"' EXIT
curl -fLsS --retry 2 --connect-timeout 15 --max-time 180 \
  "https://codeload.github.com/holzschu/ios_system/tar.gz/$revision" -o "$source/input.tar.gz"
echo "$checksum  $source/input.tar.gz" | shasum -a 256 -c -
tar -xzf "$source/input.tar.gz" --strip-components=1 -C "$source"

for platform in device simulator simulator-x86_64; do
  sdk=iphonesimulator arch=arm64
  if [[ $platform == device ]]; then sdk=iphoneos; fi
  if [[ $platform == simulator-x86_64 ]]; then arch=x86_64; fi
  runtime=$work/sdk/$platform
  log=$work/ios-system-$platform.log
  if ! xcodebuild -project "$source/ios_system.xcodeproj" -target ios_system \
    -configuration Release -sdk "$sdk" -jobs 3 "ARCHS=$arch" ONLY_ACTIVE_ARCH=NO \
    IPHONEOS_DEPLOYMENT_TARGET=14.0 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    "CONFIGURATION_BUILD_DIR=$runtime" build >"$log" 2>&1; then
    tail -n 60 "$log" >&2
    exit 1
  fi
  bash "$here/build.sh" "$product" "$runtime" "$platform" "$work/command"
done

package=$(mktemp -d "$work/package.XXXXXX")
trap 'rm -rf "$source" "$package"' EXIT
command=$work/command/$product
device=$command/device/$product.framework
simulator=$package/$product.framework
ditto "$command/simulator/$product.framework" "$simulator"
xcrun lipo -create "$simulator/$product" "$command/simulator-x86_64/$product.framework/$product" \
  -output "$package/universal"
mv "$package/universal" "$simulator/$product"
xcrun lipo "$simulator/$product" -verify_arch arm64 x86_64
xcrun lipo "$device/$product" -verify_arch arm64
for platform in device simulator simulator-x86_64; do
  printf '%s\t%s\n' "$platform" "$(stat -f %z "$command/$platform/$product.framework/$product")"
done >"$dist/$product.sizes.tsv"

xcodebuild -create-xcframework -framework "$device" -framework "$simulator" \
  -output "$package/$product.xcframework"
ditto -c -k --norsrc --keepParent "$package/$product.xcframework" "$dist/$product.xcframework.zip"
unzip -tq "$dist/$product.xcframework.zip"
(cd "$dist"; shasum -a 256 "$product.xcframework.zip" >"$product.checksums.txt")
printf 'source=%s\nios_system=%s\n' "${GITHUB_SHA:-local}" "$revision" >"$dist/$product.inputs.txt"
