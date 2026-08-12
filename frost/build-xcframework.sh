#!/bin/bash
# Rebuilds the OBFrostFFI xcframework: bindings + 3 slices + symbol
# localization (bdk collision) + package copy into WalletKit.
set -e
cd "$(dirname "$0")"
cargo build --release --lib
cargo run --release --bin uniffi-bindgen generate --library target/release/libobfrost.dylib --language swift --out-dir bindings 2>/dev/null
cp bindings/obfrostFFI.h Headers/
cp bindings/obfrostFFI.modulemap Headers/module.modulemap
# Keep ONLY the uniffi C-ABI entry points global; localize everything
# else (Rust runtime + secp256k1 C lib) so the archive never collides
# with bdk-swift's own bundled copies.
nm -g target/release/libobfrost.a 2>/dev/null | grep -E " (T|S) " | awk '{print $3}' | grep -E "^_(ffi|uniffi)_obfrost" | sort -u > /tmp/keep.txt
localize() { # target arch platform min
  local T=$1 ARCH=$2 PLAT=$3 MIN=$4 A="target/$1/release/libobfrost.a"
  cargo build --release --lib --target "$T" >/dev/null 2>&1
  ld -r -arch "$ARCH" -platform_version "$PLAT" "$MIN" "$MIN" -exported_symbols_list /tmp/keep.txt -all_load "$A" -o "/tmp/ob_$T.o" 2>/dev/null
  rm -f "$A"; ar crs "$A" "/tmp/ob_$T.o"
}
localize aarch64-apple-ios arm64 ios 12.0
localize aarch64-apple-ios-sim arm64 ios-simulator 14.0
localize aarch64-apple-darwin arm64 macos 13.0
rm -rf OBFrostFFI.xcframework
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libobfrost.a -headers Headers \
  -library target/aarch64-apple-ios-sim/release/libobfrost.a -headers Headers \
  -library target/aarch64-apple-darwin/release/libobfrost.a -headers Headers \
  -output OBFrostFFI.xcframework >/dev/null
cp bindings/obfrost.swift ../app/WalletKit/Sources/OBFrost/OBFrost.swift
rm -rf ../app/WalletKit/OBFrostFFI.xcframework
cp -R OBFrostFFI.xcframework ../app/WalletKit/
echo "OBFrostFFI rebuilt + installed into WalletKit"
