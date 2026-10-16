#!/usr/bin/env bash
# One-command TestFlight release for OrangeBubbles.
#
#   scripts/release.sh                 # archive + upload to App Store Connect
#   scripts/release.sh --export-only   # archive + export .ipa, no upload
#   scripts/release.sh --archive-only  # just the archive (signing dry run)
#
# Versioning: MARKETING_VERSION comes from app/project.yml; the build number
# is the commit count on HEAD, so every commit yields a higher build and no
# one has to remember to bump it. Override either with env vars:
#   MARKETING_VERSION=1.0.1 BUILD_NUMBER=42 scripts/release.sh
#
# Signing: automatic. On a Mac where Xcode is signed in to the team,
# -allowProvisioningUpdates creates the distribution certificate and
# profiles on first run. For CI, set an App Store Connect API key instead:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to AuthKey_XXXX.p8)
#
# Safety: refuses to run on a dirty tree, and refuses to upload anything
# whose release config is not mainnet (WALLET_NETWORK=bitcoin).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="$ROOT/app"
MODE="upload"
case "${1:-}" in
  --export-only) MODE="export" ;;
  --archive-only) MODE="archive" ;;
  "") ;;
  *) echo "usage: $0 [--export-only|--archive-only]" >&2; exit 2 ;;
esac

say() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

command -v xcodegen >/dev/null || die "xcodegen not installed (brew install xcodegen)"
command -v xcodebuild >/dev/null || die "xcodebuild not found"

if [ -n "$(git status --porcelain)" ]; then
  die "working tree is dirty — commit or stash first so the build number matches a commit"
fi

TEAM_ID=$(grep -E '^\s*DEVELOPMENT_TEAM:' "$APP/project.yml" | awk '{print $2}')
MARKETING_VERSION=${MARKETING_VERSION:-$(grep -E '^\s*MARKETING_VERSION:' "$APP/project.yml" | awk '{print $2}')}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
COMMIT=$(git rev-parse --short HEAD)
RELEASE_NETWORK=$(awk '/^  configs:/{c=1} c && /release:/{r=1} r && /WALLET_NETWORK:/{print $2; exit}' "$APP/project.yml")

say "OrangeBubbles $MARKETING_VERSION ($BUILD_NUMBER) from $COMMIT — release network: ${RELEASE_NETWORK:-unknown}"
if [ "$MODE" = "upload" ] && [ "$RELEASE_NETWORK" != "bitcoin" ]; then
  die "release config is '$RELEASE_NETWORK', not bitcoin — refusing to upload a non-mainnet build"
fi

OUT="$ROOT/build/release/$MARKETING_VERSION-$BUILD_NUMBER"
ARCHIVE="$OUT/OrangeBubbles.xcarchive"
EXPORT_DIR="$OUT/export"
LOG="$OUT/xcodebuild.log"
mkdir -p "$OUT"

say "Generating Xcode project"
(cd "$APP" && xcodegen generate >/dev/null)

AUTH_ARGS=()
if [ -n "${ASC_KEY_ID:-}" ]; then
  [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_KEY_PATH:-}" ] || die "ASC_KEY_ID set but ASC_ISSUER_ID / ASC_KEY_PATH missing"
  AUTH_ARGS=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
fi

say "Archiving (Release) → $ARCHIVE"
xcodebuild archive \
  -project "$APP/OrangeBubbles.xcodeproj" \
  -scheme OrangeBubbles \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  >"$LOG" 2>&1 || { tail -40 "$LOG"; die "archive failed — full log: $LOG"; }

# Belt and braces: read the network straight out of the archived app.
APP_PLIST="$ARCHIVE/Products/Applications/OrangeBubbles.app/Info.plist"
EXT_PLIST=$(ls "$ARCHIVE"/Products/Applications/OrangeBubbles.app/PlugIns/*.appex/Info.plist 2>/dev/null | head -1)
ARCHIVED_NET=$(/usr/libexec/PlistBuddy -c 'Print :WalletNetwork' "$EXT_PLIST" 2>/dev/null || echo unknown)
ARCHIVED_VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")
ARCHIVED_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST")
say "Archived $ARCHIVED_VER ($ARCHIVED_BUILD); extension network: $ARCHIVED_NET"
if [ "$MODE" = "upload" ] && [ "$ARCHIVED_NET" != "bitcoin" ]; then
  die "archived extension is on '$ARCHIVED_NET' — refusing to upload"
fi
[ "$MODE" = "archive" ] && { say "Done (archive only)."; exit 0; }

DESTINATION=$([ "$MODE" = "upload" ] && echo upload || echo export)
OPTIONS="$OUT/ExportOptions.plist"
cat >"$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

say "$([ "$MODE" = "upload" ] && echo 'Exporting and uploading to App Store Connect' || echo "Exporting .ipa → $EXPORT_DIR")"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
  >>"$LOG" 2>&1 || { tail -40 "$LOG"; die "export failed — full log: $LOG"; }

if [ "$MODE" = "upload" ]; then
  say "Uploaded $MARKETING_VERSION ($BUILD_NUMBER). It appears in App Store Connect → TestFlight after processing (usually 5–15 min)."
  git tag -f "v$MARKETING_VERSION-$BUILD_NUMBER" >/dev/null && echo "Tagged v$MARKETING_VERSION-$BUILD_NUMBER (push with: git push origin --tags)"
else
  say "Exported: $(ls "$EXPORT_DIR"/*.ipa)"
fi
