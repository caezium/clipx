#!/usr/bin/env bash
set -euo pipefail

helper="${1:?Usage: validate-ffmpeg.sh /path/to/ffmpeg}"
if [ ! -x "$helper" ]; then
    echo "error: FFmpeg is missing or not executable: $helper" >&2
    exit 1
fi
dependencies="$(otool -L "$helper")"
while IFS= read -r dependency; do
    case "$dependency" in
        /System/Library/*|/usr/lib/*|'') ;;
        *) echo "error: FFmpeg depends on $dependency. Release builds require a portable binary with only system libraries." >&2; exit 1 ;;
    esac
done < <(printf '%s\n' "$dependencies" | sed -n '2,$s/^[[:space:]]*\(.*\) (compatibility version.*$/\1/p')
for architecture in ${ARCHS:-$(uname -m)}; do
    lipo -verify_arch "$architecture" "$helper"
done
