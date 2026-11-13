#!/usr/bin/env bash
# Install an explicitly selected, checksum-verified standalone Mach-O binary.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${FFMPEG_URL:?Set FFMPEG_URL to an audited HTTPS standalone FFmpeg binary}"
: "${FFMPEG_SHA256:?Set FFMPEG_SHA256 to its independently verified SHA-256}"
case "$FFMPEG_URL" in https://*) ;; *) echo "FFMPEG_URL must use HTTPS" >&2; exit 1 ;; esac
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 300 --output "$scratch/ffmpeg" "$FFMPEG_URL"
actual="$(shasum -a 256 "$scratch/ffmpeg" | awk '{print $1}')"
if [ "$actual" != "$FFMPEG_SHA256" ]; then
    echo "FFmpeg checksum mismatch; existing helper was preserved." >&2
    exit 1
fi
chmod 755 "$scratch/ffmpeg"
bash Scripts/validate-ffmpeg.sh "$scratch/ffmpeg"
mkdir -p Helpers
mv -f "$scratch/ffmpeg" Helpers/ffmpeg
printf 'Installed verified FFmpeg (%s). Release builds also require matching source metadata and notices; build-ffmpeg.py creates the complete release helper.\n' "$actual"
