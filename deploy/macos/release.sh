#!/usr/bin/env bash
# Optics macOS release script (Release Plan §5.4–§5.10).
#
# Usage:
#   APPLE_ID=you@bryzos.com TEAM_ID=XXXXXXXXXX APP_PASSWORD=xxxx-xxxx-xxxx-xxxx \
#   SPARKLE_KEY_FILE=~/.sparkle/optics_ed25519 \
#     ./deploy/macos/release.sh 1.0.0
#
# Prereqs:
#   - Apple Developer ID Application certificate installed in the login keychain.
#   - `xcrun notarytool` (Xcode 13+).
#   - `create-dmg` (npm i -g create-dmg) for the installer.
#   - Sparkle's `sign_update` on PATH (brew install sparkle).
#
# Outputs:
#   build/macos/release/Optics-<VERSION>.dmg              (signed + notarized + stapled)
#   build/macos/release/Optics-<VERSION>.dmg.edSignature  (Sparkle EdDSA signature)
#   build/macos/release/appcast-item-<VERSION>.xml        (paste into appcast.xml)

set -euo pipefail

VERSION="${1:?Usage: release.sh <version>}"
APPLE_ID="${APPLE_ID:?Set APPLE_ID env var}"
TEAM_ID="${TEAM_ID:?Set TEAM_ID env var}"
APP_PASSWORD="${APP_PASSWORD:?Set APP_PASSWORD env var (Apple app-specific password)}"
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:?Set SPARKLE_KEY_FILE env var (path to EdDSA private key)}"

cd "$(dirname "$0")/../.."   # project root: program/flutter_app/

OUT_DIR="build/macos/release"
mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/Optics-$VERSION.dmg"

echo "▶︎ Building macOS release…"
flutter build macos --release

APP="build/macos/Build/Products/Release/Optics.app"
# Tolerate either capitalization since the bundle name was rebranded from "optics" → "Optics".
if [ ! -d "$APP" ] && [ -d "build/macos/Build/Products/Release/optics.app" ]; then
  APP="build/macos/Build/Products/Release/optics.app"
fi
test -d "$APP" || { echo "Build output not found: $APP"; exit 1; }

echo "▶︎ Code signing…"
codesign --deep --force --options runtime \
  --sign "Developer ID Application: Bryzos, LLC ($TEAM_ID)" \
  "$APP"

echo "▶︎ Verifying signature…"
codesign --verify --verbose=2 "$APP"

echo "▶︎ Creating DMG…"
rm -f "$DMG"
create-dmg \
  --volname "Optics" \
  --window-size 500 320 \
  --icon-size 96 \
  --app-drop-link 360 160 \
  "$DMG" \
  "$APP"

echo "▶︎ Signing DMG…"
codesign --sign "Developer ID Application: Bryzos, LLC ($TEAM_ID)" "$DMG"

echo "▶︎ Submitting to Apple notarization (this can take 5–15 min)…"
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD" \
  --wait

echo "▶︎ Stapling notarization ticket…"
xcrun stapler staple "$DMG"

echo "▶︎ Signing DMG with Sparkle EdDSA key…"
SIG=$(sign_update -f "$SPARKLE_KEY_FILE" "$DMG")
echo "$SIG" > "$DMG.edSignature"

LENGTH=$(stat -f%z "$DMG")
PUBDATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

cat > "$OUT_DIR/appcast-item-$VERSION.xml" <<EOF
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://updates.optics.bryzos.com/macos/release-notes/$VERSION.html</sparkle:releaseNotesLink>
      <enclosure
        url="https://updates.optics.bryzos.com/macos/Optics-$VERSION.dmg"
        sparkle:version="$VERSION"
        sparkle:shortVersionString="$VERSION"
        $SIG
        length="$LENGTH"
        type="application/octet-stream" />
    </item>
EOF

echo
echo "✅ Done. Outputs in $OUT_DIR/"
echo "   1. Upload $DMG to the update host."
echo "   2. Paste appcast-item-$VERSION.xml as the new top <item> in appcast.xml."
echo "   3. Re-upload appcast.xml to https://updates.optics.bryzos.com/macos/."
