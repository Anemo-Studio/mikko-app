#!/bin/bash
# Builds a notarized, stapled mikko.dmg for direct download (Developer ID).
#
# mikko is distributed outside the Mac App Store: the App Sandbox the store requires
# blocks signals to other processes, and stopping what agents left running is the core
# of the app.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in the login keychain (Xcode > Settings >
#      Accounts > Manage Certificates, Account Holder role required).
#   2. A notarytool profile:
#        xcrun notarytool store-credentials mikko-notary --apple-id <id> --team-id <TEAMID>
#      (uses an app-specific password from account.apple.com)
#
# Usage: TEAM_ID=ABCDE12345 scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID}"
PROFILE="${NOTARY_PROFILE:-mikko-notary}"
OUT=".build/release"
VERSION=$(grep MARKETING_VERSION project.yml | head -1 | awk '{print $2}')

rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate >/dev/null

# 1. Archive, signed with Developer ID, hardened runtime and a secure timestamp.
xcodebuild -project Mikko.xcodeproj -scheme Mikko -configuration Release \
  -archivePath "$OUT/mikko.xcarchive" archive \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS="--timestamp" \
  | grep -E "error|ARCHIVE" || true

# 2. Export for Developer ID distribution (Xcode strips get-task-allow here).
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/mikko.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" | grep -E "error|EXPORT" || true
APP="$OUT/export/mikko.app"

# 3. Check every signature the way the notary service will.
codesign --verify --deep --strict --verbose=2 "$APP"
for bin in "$APP/Contents/MacOS/mikko" "$APP/Contents/Helpers/mikko"; do
  codesign -dvv "$bin" 2>&1 | grep -q "Timestamp=" || { echo "no secure timestamp on $bin" >&2; exit 1; }
  codesign -dvv "$bin" 2>&1 | grep -q "runtime" || { echo "no hardened runtime on $bin" >&2; exit 1; }
done
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "get-task-allow present — do not ship a debug signature" >&2; exit 1
fi

# 4. Disk image, signed, notarized, stapled.
#    The app is notarized and stapled first, so the copy inside the disk image (and the
#    one Homebrew installs) carries its own ticket and opens offline.
ditto -c -k --keepParent "$APP" "$OUT/mikko.zip"
xcrun notarytool submit "$OUT/mikko.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
DMG="$OUT/mikko-$VERSION.dmg"
hdiutil create -volname "mikko" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# 5. What Gatekeeper will say on a user's Mac.
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP"
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "Ready: $DMG"
echo
echo "Publish:"
echo "  gh release create v$VERSION \"$DMG\" --repo Anemo-Studio/mikko-app --title \"mikko $VERSION\" --notes-file <notes.md>"
echo "Homebrew (Anemo-Studio/homebrew-tap, Casks/mikko.rb):"
echo "  version \"$VERSION\""
echo "  sha256 \"$SHA\""
