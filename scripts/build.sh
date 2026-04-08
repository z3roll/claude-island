#!/bin/bash
# Build Claude Island (unsigned)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=== Building Claude Island ==="

# Optional: release.sh passes MARKETING_VERSION + CURRENT_PROJECT_VERSION to
# override the pbxproj defaults. Standalone `./scripts/build.sh` uses whatever
# is in the project file.
: "${CURRENT_PROJECT_VERSION:=$(git rev-list --count HEAD)}"

BUILD_ARGS=(
    -scheme ClaudeIsland
    -configuration Release
    build
    CODE_SIGN_IDENTITY="-"
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=NO
    "CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION"
)
if [ -n "$MARKETING_VERSION" ]; then
    BUILD_ARGS+=("MARKETING_VERSION=$MARKETING_VERSION")
fi

xcodebuild "${BUILD_ARGS[@]}" 2>&1 | tail -5

APP_PATH="$(ls -d ~/Library/Developer/Xcode/DerivedData/ClaudeIsland-*/Build/Products/Release/Claude\ Island.app)"

# Properly adhoc-sign the bundle (with _CodeSignature/) so Sparkle's
# Apple Code Signing validation survives the zip round-trip. Without
# this, xcodebuild's CODE_SIGNING_ALLOWED=NO only leaves a linker-level
# signature and Sparkle rejects the update with errSecCSSignatureInvalid.
echo ""
echo "=== Adhoc-signing bundle ==="
codesign --force --deep --sign - "$APP_PATH" 2>&1 | tail -5
codesign --verify --deep --strict "$APP_PATH" && echo "Signature OK"

echo ""
echo "=== Installing to /Applications ==="
pkill -f "Claude Island" 2>/dev/null || true
sleep 0.3
rm -rf "/Applications/Claude Island.app"
cp -R "$APP_PATH" "/Applications/Claude Island.app"
echo "Installed to /Applications/Claude Island.app"

echo ""
echo "=== Build Complete ==="
echo "App: $APP_PATH"
echo ""
echo "  Launch:   open '/Applications/Claude Island.app'"
echo "  Release:  ./scripts/release.sh <version>"
