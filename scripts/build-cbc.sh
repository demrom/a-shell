#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build=${1:-"$root/.build/cbc"}
mkdir -p "$build"
build=$(cd "$build" && pwd)
# COIN-OR's legacy Autotools and libtool recipes split paths containing whitespace.
if [[ $build == *[[:space:]]* ]]; then
    echo "Pass a CBC build directory without whitespace: scripts/build-cbc.sh /tmp/cbc-build" >&2
    exit 2
fi
mkdir -p "$build/downloads"
work=$(mktemp -d "$build/work.XXXXXXXX")
trap 'status=$?; if (( status == 0 )); then rm -rf "$work"; else echo "Build files: $work" >&2; fi' EXIT
mkdir -p "$work/src"
cp "$root/ports/cbc/ios-streams.hpp" "$work/ios-streams.hpp"

fetch() {
    local url=$1 checksum=$2 file=$3
    if [[ ! -f $file ]]; then
        curl -fLsS --retry 3 "$url" -o "$work/download"
        printf '%s  %s\n' "$checksum" "$work/download" | shasum -a 256 -c -
        mv "$work/download" "$file"
    fi
    printf '%s  %s\n' "$checksum" "$file" | shasum -a 256 -c -
}

projects=()
while read -r project version checksum; do
    archive="$build/downloads/$project-$version.tar.gz"
    fetch "https://codeload.github.com/coin-or/$project/tar.gz/refs/tags/releases/$version" "$checksum" "$archive"
    mkdir "$work/src/$project"
    tar -xzf "$archive" --strip-components 1 -C "$work/src/$project"
    projects+=("$project")
done < "$root/ports/cbc/sources.txt"
for patch_file in "$root"/ports/cbc/patches/*.patch; do
    patch -f -F0 -p1 -d "$work/src" < "$patch_file"
done

fetch https://github.com/holzschu/ios_system/releases/download/v3.0.5/ios_system.xcframework.zip \
    d429e68102926f58bedd8e8b7105dcd169478cd6da1cef494a5f468482d1c8f5 "$build/downloads/ios_system.xcframework.zip"
unzip -q "$build/downloads/ios_system.xcframework.zip" -d "$work"

build_slice() (
    sdk=$1 arch=$2
    host_arch=$arch
    [[ $arch != arm64 ]] || host_arch=aarch64
    triple="$arch-apple-ios14.0"
    platform=iPhoneOS
    slice=ios-arm64
    if [[ $sdk == iphonesimulator ]]; then
        triple+=-simulator
        platform=iPhoneSimulator
        slice=ios-arm64_x86_64-simulator
    fi
    slice_dir="$work/$sdk-$arch"
    prefix="$slice_dir/install"
    system_frameworks="$work/ios_system.xcframework/$slice"
    sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
    cc=$(xcrun --sdk "$sdk" -f clang)
    cxx=$(xcrun --sdk "$sdk" -f clang++)
    target_flags="-target $triple -isysroot $sdk_path"
    AR=$(xcrun --sdk "$sdk" -f ar)
    RANLIB=$(xcrun --sdk "$sdk" -f ranlib)
    export CC="$cc" CXX="$cxx" AR RANLIB
    export CPP="$cc -E $target_flags" CXXCPP="$cxx -E $target_flags"
    export CFLAGS="$target_flags -O2 -fPIC" CXXFLAGS="$target_flags -O2 -fPIC -std=c++11 -DNDEBUG"
    export LDFLAGS="$target_flags" PKG_CONFIG_PATH='' PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
    export F77=unavailable
    build_host=$("$work/src/Cbc/config.guess")
    mkdir -p "$prefix"
    port_flags="-DCBC_IOS_SYSTEM -DCBC_NO_INTERRUPT -fno-builtin -include $work/ios-streams.hpp"
    for project in "${projects[@]}"; do
        echo "Building $project for $triple"
        mkdir -p "$slice_dir/$project"
        (
            cd "$slice_dir/$project"
            make_args=(CXX="$cxx $port_flags" bin_PROGRAMS= noinst_PROGRAMS=)
            # The legacy install-sh races when parallel targets create include/coin.
            if ! { "$work/src/$project/$project/configure" --build="$build_host" --host="$host_arch-apple-ios" \
                --prefix="$prefix" --with-coin-instdir="$prefix" \
                --disable-shared --enable-static --disable-dependency-tracking \
                --disable-gnu-packages --with-blas=no --with-lapack=no &&
                make -j"${CBC_JOBS:-4}" "${make_args[@]}" && make -j1 "${make_args[@]}" install; } \
                > build.log 2>&1; then
                tail -100 build.log >&2
                exit 1
            fi
        )
    done
    framework="$slice_dir/cbc.framework"
    # A top-level Resources directory makes installd look for a non-flat bundle.
    mkdir -p "$framework/Licenses"
    # Link the stock CBC driver and solver stack, exporting only the command entry point.
    "$cxx" -target "$triple" -isysroot "$sdk_path" -O2 -std=c++11 -DNDEBUG \
        -I"$prefix/include/coin" -DCBC_IOS_SYSTEM -DCBC_NO_INTERRUPT -fno-builtin \
        -include "$root/ports/cbc/ios-streams.hpp" -c "$work/src/Cbc/Cbc/src/CoinSolve.cpp" -o "$slice_dir/driver.o"
    "$cxx" -target "$triple" -isysroot "$sdk_path" -O2 -std=c++11 \
        -I"$prefix/include/coin" -c "$root/ports/cbc/ios-streams.cpp" -o "$slice_dir/ios-streams.o"
    "$cxx" -target "$triple" -isysroot "$sdk_path" -dynamiclib \
        -Wl,-install_name,@rpath/cbc.framework/cbc -Wl,-exported_symbol,_main -Wl,-dead_strip \
        "$slice_dir/driver.o" "$slice_dir/ios-streams.o" -L"$prefix/lib" \
        -lCbcSolver -lCbc -lCgl -lOsiClp -lClp -lOsi -lCoinUtils -lz -lbz2 \
        -F"$system_frameworks" -framework ios_system -o "$framework/cbc"
    for project in "${projects[@]}"; do
        cp "$work/src/$project/LICENSE" "$framework/Licenses/$project-LICENSE"
    done
    cat > "$framework/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>cbc</string>
<key>CFBundleIdentifier</key><string>org.coin-or.cbc</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>cbc</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>2.10.12</string>
<key>MinimumOSVersion</key><string>14.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
<!-- Simulator installation checks platform metadata on embedded frameworks. -->
<key>DTPlatformName</key><string>$sdk</string>
</dict></plist>
PLIST
    xcrun lipo "$framework/cbc" -verify_arch "$arch"
    xcrun nm -gUj "$framework/cbc" | grep -Fx _main
    xcrun nm -uj "$framework/cbc" > "$slice_dir/imports.txt"
    if grep -E '^(_(__std(inp|outp|errp)|abort|exit|_exit|_Exit|printf|vprintf|puts|putchar|perror|signal|sigaction|setlocale)|__ZNSt3__(1|2)[34](cin|cout|cerr|clog)E)$' "$slice_dir/imports.txt"; then
        echo "Unexpected process-global imports in $triple" >&2
        exit 1
    fi
    expected_platform=IOS
    [[ $sdk != iphonesimulator ]] || expected_platform=IOSSIMULATOR
    xcrun vtool -show-build "$framework/cbc" | tee "$slice_dir/platform.txt"
    grep -Eq "^[[:space:]]+platform $expected_platform$" "$slice_dir/platform.txt"
    grep -Eq '^[[:space:]]+minos 14\.0$' "$slice_dir/platform.txt"
)

for arch in arm64 x86_64; do build_slice iphonesimulator "$arch"; done
build_slice iphoneos arm64
simulator="$work/iphonesimulator-arm64/cbc.framework"
xcrun lipo -create "$simulator/cbc" "$work/iphonesimulator-x86_64/cbc.framework/cbc" -output "$work/cbc.universal"
mv "$work/cbc.universal" "$simulator/cbc"
xcodebuild -create-xcframework -framework "$simulator" -framework "$work/iphoneos-arm64/cbc.framework" \
    -output "$work/cbc.xcframework"
(cd "$work" && zip -q -r -X cbc.xcframework.zip cbc.xcframework)

# Verify the archive (not the unzipped build products) through the command loader.
"$root/tests/cbc/simulator.sh" "$work/cbc.xcframework.zip" "$work/ios_system.xcframework" "$work" | tee "$work/cbc-smoke.log"
(
    cd "$work"
    xcrun swift package compute-checksum cbc.xcframework.zip | awk '{print $1 "  cbc.xcframework.zip"}' > checksums.txt
    shasum -a 256 -c checksums.txt
)
mkdir "$work/dist"
mv "$work/cbc.xcframework.zip" "$work/checksums.txt" "$work/cbc-smoke.log" "$work/dist/"
dist="$build/dist.${work##*.}"
mv "$work/dist" "$dist"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'dist=%s\n' "$dist" >> "$GITHUB_OUTPUT"
fi
printf 'Artifacts: %s\n' "$dist"
