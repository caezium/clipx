#!/usr/bin/env bash
# Dev setup for Clipx. Symlinks the Homebrew ffmpeg binary into the Helpers
# directory so unsigned dev builds of the Direct target can find it.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null; then
    echo "✗ xcodegen not found. Install with: brew install xcodegen"
    exit 1
fi

if ! command -v ffmpeg >/dev/null; then
    echo "⚠ ffmpeg not found. Install with: brew install ffmpeg"
    echo "  (You can still build the MAS target without it.)"
else
    FFMPEG_PATH="$(which ffmpeg)"
    mkdir -p Helpers
    if [ ! -L Helpers/ffmpeg ] || [ "$(readlink Helpers/ffmpeg)" != "$FFMPEG_PATH" ]; then
        ln -sf "$FFMPEG_PATH" Helpers/ffmpeg
        echo "✓ Symlinked $FFMPEG_PATH → Helpers/ffmpeg"
    fi
fi

echo "✓ Generating Xcode project from project.yml…"
xcodegen generate

echo ""
echo "Setup complete. Open Clipx.xcodeproj in Xcode."
