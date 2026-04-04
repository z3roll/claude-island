#!/bin/bash
# Build Claude Island (unsigned)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=== Building Claude Island ==="

xcodebuild -scheme ClaudeIsland -configuration Release build \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -5

APP_PATH="$(ls -d ~/Library/Developer/Xcode/DerivedData/ClaudeIsland-*/Build/Products/Release/Claude\ Island.app)"

echo ""
echo "=== Build Complete ==="
echo "App: $APP_PATH"
echo ""
echo "  Install:  cp -r \"$APP_PATH\" /Applications/"
echo "  Release:  ./scripts/release.sh <version>"
