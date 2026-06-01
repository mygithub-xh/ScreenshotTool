#!/bin/bash
set -e

APP_NAME="截图工具"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"

# Build with debug or release config
CONFIG="${1:-release}"
if [ "$CONFIG" = "release" ]; then
    swift build -c release
    BINARY="$BUILD_DIR/release/ScreenshotTool"
else
    swift build
    BINARY="$BUILD_DIR/debug/ScreenshotTool"
fi

# Create .app bundle
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/ScreenshotTool"
cp "$PROJECT_DIR/Sources/ScreenshotTool/Info.plist" "$APP_BUNDLE/Contents/"
if [ -f "$PROJECT_DIR/Sources/ScreenshotTool/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Sources/ScreenshotTool/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

# Note: com.apple.developer.screen-capture entitlement requires a real Apple Developer
# certificate for signing. Without it, ScreenCaptureKit still prompts for Screen
# Recording permission via TCC on first use.

# Install to /Applications so login item (SMAppService) works correctly
INSTALL_TARGET="/Applications/$APP_NAME.app"
rm -rf "$INSTALL_TARGET"
cp -R "$APP_BUNDLE" "$INSTALL_TARGET"

echo "✅ Build complete: $APP_BUNDLE"
echo "   Installed to: $INSTALL_TARGET"
echo "   Launch with: open \"$INSTALL_TARGET\""
