#!/bin/bash
# Builds a notarized, stapled mikko-<version>.zip for GitHub Releases (Developer ID).
#
# mikko is distributed outside the Mac App Store: the App Sandbox the store requires
# blocks signals to other processes, and stopping what agents left running is the core
# of the app.
#
# Signing and notarization go through the Apple account signed in to Xcode (team
# ANEMO STUDIJA, MB). Xcode creates and holds the Developer ID certificate itself
# (cloud-managed), so no certificate or notary password is needed on this Mac.
#
# Usage: scripts/release.sh            (then publish with the gh command it prints)
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM_ID="${TEAM_ID:-GL93N8FF2M}"
OUT=".build/release"
VERSION=$(grep MARKETING_VERSION project.yml | head -1 | awk '{print $2}')

rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate >/dev/null

# 1. Archive.
xcodebuild -project Mikko.xcodeproj -scheme Mikko -configuration Release \
  -archivePath "$OUT/mikko.xcarchive" archive -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
  | grep -E "error|ARCHIVE" || true

# 2. Re-sign for Developer ID and upload to Apple's notary service.
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>upload</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/mikko.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/upload" -allowProvisioningUpdates | grep -E "error|EXPORT|Uploaded" || true

# 3. Wait for Apple, then export the app with its notarization ticket stapled.
for _ in $(seq 1 60); do
  if out=$(xcodebuild -exportNotarizedApp -archivePath "$OUT/mikko.xcarchive" -exportPath "$OUT/notarized" 2>&1); then break; fi
  echo "$out" | grep -q "is processing" || { echo "$out" | tail -8 >&2; exit 1; }
  sleep 30
done
APP="$OUT/notarized/mikko.app"
test -d "$APP" || { echo "notarization did not finish in 30 minutes" >&2; exit 1; }

# 4. Check it the way Gatekeeper will on someone else's Mac.
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "debug entitlement present" >&2; exit 1
fi
test -x "$APP/Contents/Helpers/mikko"

# 5. Package. The ticket is stapled to the app, so a plain ZIP opens without warnings.
ZIP="$OUT/mikko-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "Ready: $ZIP"
echo
echo "Publish:"
echo "  gh release create v$VERSION \"$ZIP\" --repo Anemo-Studio/mikko-app --title \"mikko $VERSION\" --notes-file <notes.md>"
echo "Homebrew (Anemo-Studio/homebrew-tap, Casks/mikko.rb):"
echo "  version \"$VERSION\""
echo "  sha256 \"$SHA\""
