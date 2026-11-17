#!/bin/bash
# After a GitHub release, points the Homebrew cask at it.
# Usage: scripts/bump-tap.sh <path-to-zip>     (the ZIP scripts/release.sh produced)
# Needs a clone of Anemo-Studio/homebrew-tap next to this repository (../homebrew-tap).
set -euo pipefail
cd "$(dirname "$0")/.."
ZIP="${1:?Usage: scripts/bump-tap.sh <path-to-zip>}"
VERSION=$(grep MARKETING_VERSION project.yml | head -1 | awk '{print $2}')
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
TAP="../homebrew-tap"
test -f "$TAP/Casks/mikko.rb" || { echo "No tap clone at $TAP" >&2; exit 1; }
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/mikko.rb" packaging/homebrew/mikko.rb
git -C "$TAP" commit -qam "mikko $VERSION"
git -C "$TAP" push -q
echo "Cask now at $VERSION ($SHA)"
