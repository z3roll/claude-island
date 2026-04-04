#!/bin/bash
# Build, create DMG, and upload GitHub Release
set -e

VERSION="${1:?Usage: ./scripts/release.sh <version>  (e.g. 1.3)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GITHUB_REPO="z3roll/claude-island"

cd "$PROJECT_DIR"

# Step 1: Build
echo "=== Building ==="
./scripts/build.sh

APP_PATH="$(ls -d ~/Library/Developer/Xcode/DerivedData/ClaudeIsland-*/Build/Products/Release/Claude\ Island.app)"

# Step 2: Create DMG
echo ""
echo "=== Creating DMG ==="
DMG_PATH="/tmp/ClaudeIsland-${VERSION}.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname "Claude Island" \
    -srcfolder "$APP_PATH" \
    -ov -format UDZO \
    "$DMG_PATH"

echo "DMG: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

# Step 3: Upload to GitHub
echo ""
echo "=== Creating GitHub Release ==="
gh release create "v${VERSION}" "$DMG_PATH" \
    --repo "$GITHUB_REPO" \
    -t "Claude Island v${VERSION}" \
    --generate-notes

echo ""
echo "=== Done ==="
echo "https://github.com/${GITHUB_REPO}/releases/tag/v${VERSION}"
