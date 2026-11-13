#!/usr/bin/env bash
set -euo pipefail

source_root="${SRCROOT:?Run as the Direct target build phase}"
helper="$source_root/Helpers/ffmpeg"
destination="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers"
if [ ! -x "$helper" ]; then
    echo "error: Missing Helpers/ffmpeg. Run Scripts/setup.sh for development or install a verified portable FFmpeg binary." >&2
    exit 1
fi
if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
    bash "$source_root/Scripts/validate-ffmpeg.sh" "$helper"
    python3 "$source_root/Scripts/release.py" check-helper
fi
mkdir -p "$destination"
install -m 755 "$helper" "$destination/ffmpeg"
support="$source_root/Helpers/ffmpeg-support"
if [ -d "$support" ]; then
    notices="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/FFmpeg"
    mkdir -p "$notices"
    cp "$support/"* "$notices/"
fi
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$destination/ffmpeg"
fi
