#!/usr/bin/env bash
# Downloads a static ffmpeg binary suitable for bundling inside the .app.
# For production builds you should use a binary you've audited and signed
# yourself, ideally built from a known-good source revision.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p Helpers

ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then
    URL="https://www.osxexperts.net/ffmpeg7arm.zip"   # Replace with your audited source
else
    URL="https://www.osxexperts.net/ffmpeg7intel.zip"
fi

echo "Downloading ffmpeg for $ARCH from $URL…"
TMP="$(mktemp -d)"
curl -L -o "$TMP/ffmpeg.zip" "$URL"
unzip -q "$TMP/ffmpeg.zip" -d "$TMP/extract"
mv "$TMP/extract/ffmpeg" Helpers/ffmpeg
chmod +x Helpers/ffmpeg
rm -rf "$TMP"

echo "✓ Helpers/ffmpeg ready. Verify with: file Helpers/ffmpeg"
echo ""
echo "Next: sign the binary with your Developer ID before bundling:"
echo "  codesign --force --options runtime --timestamp \\"
echo "    --sign \"Developer ID Application: YOUR NAME (TEAMID)\" Helpers/ffmpeg"
