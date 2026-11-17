#!/bin/bash
# Builds mikko.app for local runs. The `mikko` command-line tool is an Xcode target
# (mikko-cli) that the app copies to Contents/Helpers/mikko, so Debug builds, Release
# builds and archives all contain it. Signing here is ad hoc; see scripts/release.sh.
# Usage: scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"

xcodegen generate >/dev/null
xcodebuild -project Mikko.xcodeproj -scheme Mikko -configuration "$CONFIG" -derivedDataPath .build/xc build \
  | grep -E "error|warning: |BUILD" || true

APP=".build/xc/Build/Products/$CONFIG/mikko.app"
test -x "$APP/Contents/Helpers/mikko" || { echo "missing Contents/Helpers/mikko" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
echo "$APP"
