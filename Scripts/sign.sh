#!/usr/bin/env bash
# Compatibility entry point; signing is inside-out and rejects ad-hoc identities.
set -euo pipefail

cd "$(dirname "$0")/.."
exec python3 Scripts/release.py sign --app "${APP_PATH:-build/release/app/DerivedData/Build/Products/Release/Clipx.app}" "$@"
