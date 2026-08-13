#!/bin/bash
# Regenerates bdkFFI.xcframework for locally vendored bdk-swift 1.2.0, patched
# with a Mac Catalyst (ios-arm64-maccatalyst) slice so OrangeBubbles can run in
# Messages on Mac. Upstream bdk-swift 1.2.0 ships only iOS / iOS-sim / macos.
#
# The .a slices (up to ~180 MB) exceed GitHub's 100 MB limit, so the xcframework
# is gitignored and rebuilt on demand by this script. Idempotent. Requires Xcode
# + rustup. Fetching the upstream release / bdk-ffi source is dependency
# retrieval, not an app backend — the app itself remains serverless.
set -e
cd "$(dirname "$0")"
VER=1.2.0
XC="bdkFFI.xcframework"
PB=/usr/libexec/PlistBuddy

# 1) Base xcframework (3 upstream slices): reuse SPM cache if present, else fetch.
if [ ! -d "$XC" ]; then
  CACHE=$(find ~/Library/Developer/Xcode/DerivedData -type d \
    -path "*artifacts/bdk-swift/bdkFFI/bdkFFI.xcframework" 2>/dev/null | head -1)
  if [ -n "$CACHE" ]; then
    echo "→ copying base xcframework from SPM cache"; cp -R "$CACHE" "$XC"
  else
    echo "→ downloading upstream bdkFFI.xcframework $VER"
    curl -fsSL "https://github.com/bitcoindevkit/bdk-swift/releases/download/$VER/bdkFFI.xcframework.zip" -o /tmp/bdkffi.zip
    rm -rf /tmp/bdkffi-unzip && unzip -q /tmp/bdkffi.zip -d /tmp/bdkffi-unzip
    cp -R "$(find /tmp/bdkffi-unzip -maxdepth 3 -name bdkFFI.xcframework | head -1)" "$XC"
  fi
fi

# 2) Already patched?
if $PB -c "Print" "$XC/Info.plist" 2>/dev/null | grep -q "ios-arm64-maccatalyst"; then
  echo "✓ bdkFFI.xcframework already has a Mac Catalyst slice"; exit 0
fi

# 3) Build bdk-ffi VER for the Catalyst target (ABI matches the prebuilt exactly).
rustup target add aarch64-apple-ios-macabi >/dev/null 2>&1 || true
SRC=/tmp/bdk-ffi-$VER
[ -d "$SRC" ] || git clone --depth 1 --branch "v$VER" https://github.com/bitcoindevkit/bdk-ffi.git "$SRC"
( cd "$SRC/bdk-ffi" && cargo build --release --lib --target aarch64-apple-ios-macabi )
MACLIB="$SRC/bdk-ffi/target/aarch64-apple-ios-macabi/release/libbdkffi.a"

# 4) Add the slice + register it in Info.plist.
mkdir -p "$XC/ios-arm64-maccatalyst/Headers"
cp "$MACLIB" "$XC/ios-arm64-maccatalyst/libbdkffi.a"
cp -R "$XC/ios-arm64/Headers/." "$XC/ios-arm64-maccatalyst/Headers/"
IDX=$(plutil -p "$XC/Info.plist" | grep -c '"LibraryIdentifier"')   # append after existing
$PB -c "Add :AvailableLibraries:$IDX dict" "$XC/Info.plist"
$PB -c "Add :AvailableLibraries:$IDX:BinaryPath string libbdkffi.a" "$XC/Info.plist"
$PB -c "Add :AvailableLibraries:$IDX:HeadersPath string Headers" "$XC/Info.plist"
$PB -c "Add :AvailableLibraries:$IDX:LibraryIdentifier string ios-arm64-maccatalyst" "$XC/Info.plist"
$PB -c "Add :AvailableLibraries:$IDX:LibraryPath string libbdkffi.a" "$XC/Info.plist"
$PB -c "Add :AvailableLibraries:$IDX:SupportedArchitectures array" "$XC/Info.plist"
$PB -c "Add :AvailableLibraries:$IDX:SupportedArchitectures:0 string arm64" "$XC/Info.plist"
$PB -c "Add :AvailableLibraries:$IDX:SupportedPlatform string ios" "$XC/Info.plist"
$PB -c "Add :AvailableLibraries:$IDX:SupportedPlatformVariant string maccatalyst" "$XC/Info.plist"
echo "✓ patched bdkFFI.xcframework with a Mac Catalyst slice"
