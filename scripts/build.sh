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
BUILD_ARGS=(
    -scheme ClaudeIsland
    -configuration Release
    build
    CODE_SIGN_IDENTITY="-"
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=NO
)
if [ -n "$MARKETING_VERSION" ]; then
    BUILD_ARGS+=("MARKETING_VERSION=$MARKETING_VERSION")
fi
if [ -n "$CURRENT_PROJECT_VERSION" ]; then
    BUILD_ARGS+=("CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION")
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
echo "=== Build Complete ==="
echo "App: $APP_PATH"
echo ""
echo "  Install:  cp -r \"$APP_PATH\" /Applications/"
echo "  Release:  ./scripts/release.sh <version>"
