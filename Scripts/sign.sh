#!/usr/bin/env bash
# Signs the built .app and its bundled ffmpeg helper for direct distribution.
# Run after xcodebuild has produced build/DerivedData/Build/Products/Release/Clipx.app.
set -euo pipefail

if [ -z "${DEVELOPER_ID:-}" ]; then
    echo "Set DEVELOPER_ID, e.g.:"
    echo "  export DEVELOPER_ID='Developer ID Application: Your Name (TEAMID)'"
    exit 1
fi

APP_PATH="${APP_PATH:-build/DerivedData/Build/Products/Release/Clipx.app}"
if [ ! -d "$APP_PATH" ]; then
    echo "✗ App not found at $APP_PATH. Build first."
    exit 1
fi

# Sign nested helpers bottom-up (per TN2206)
if [ -f "$APP_PATH/Contents/Helpers/ffmpeg" ]; then
    echo "✓ Signing ffmpeg helper…"
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        "$APP_PATH/Contents/Helpers/ffmpeg"
fi

# Then the main app
echo "✓ Signing main app…"
codesign --force --options runtime --timestamp --deep \
    --entitlements Configs/Clipx-Direct.entitlements \
    --sign "$DEVELOPER_ID" \
    "$APP_PATH"

echo "✓ Verifying…"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --verbose "$APP_PATH" || true

echo ""
echo "Next: notarize via"
echo "  xcrun notarytool submit $APP_PATH --apple-id YOUR@email --team-id TEAMID --password APP-PASSWORD --wait"
echo "Then staple:"
echo "  xcrun stapler staple $APP_PATH"
