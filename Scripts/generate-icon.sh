#!/usr/bin/env bash
# Generates the Clipx app icon from an inline SVG ("trim grips" mark:
# two pink trimmer grips framing a white X on a dark navy squircle).
# Uses macOS built-in `sips` and `iconutil` so no extra deps required.
set -euo pipefail

cd "$(dirname "$0")/.."

ICONSET="Resources/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
SRC="$TMP/icon.png"

# Generate a 1024×1024 placeholder by rendering an SVG via webkit2png or
# qlmanage. Simplest approach: emit an SVG and use rsvg-convert if available,
# otherwise fall back to a solid-color PNG via Python/sips.
SVG="$TMP/icon.svg"
cat > "$SVG" <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#0c0c1e"/>
      <stop offset="1" stop-color="#201c40"/>
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="1024" height="1024" rx="224" fill="url(#g)"/>
  <g fill="#ff3366">
    <rect x="212" y="302" width="96" height="420" rx="34"/>
    <rect x="716" y="302" width="96" height="420" rx="34"/>
  </g>
  <g fill="none" stroke="#fafafa" stroke-width="80" stroke-linecap="round">
    <path d="M 380 380 L 644 644"/>
    <path d="M 644 380 L 380 644"/>
  </g>
</svg>
SVGEOF

# Try rsvg-convert (brew install librsvg) first, fall back to qlmanage
if command -v rsvg-convert >/dev/null; then
    rsvg-convert -w 1024 -h 1024 -o "$SRC" "$SVG"
elif command -v qlmanage >/dev/null; then
    qlmanage -t -s 1024 -o "$TMP" "$SVG" >/dev/null
    mv "$TMP/icon.svg.png" "$SRC"
else
    echo "✗ Need rsvg-convert (brew install librsvg) or qlmanage"
    exit 1
fi

# Generate every size required for a macOS iconset.
declare -a SIZES=(
    "16:icon_16x16"
    "32:icon_16x16@2x"
    "32:icon_32x32"
    "64:icon_32x32@2x"
    "128:icon_128x128"
    "256:icon_128x128@2x"
    "256:icon_256x256"
    "512:icon_256x256@2x"
    "512:icon_512x512"
    "1024:icon_512x512@2x"
)

mkdir -p "$ICONSET"
for spec in "${SIZES[@]}"; do
    SIZE="${spec%%:*}"
    NAME="${spec##*:}"
    sips -z "$SIZE" "$SIZE" "$SRC" --out "$ICONSET/${NAME}.png" >/dev/null
done

# Update Contents.json with the filenames so Xcode picks them up.
cat > "$ICONSET/Contents.json" <<'JSONEOF'
{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSONEOF

echo "✓ Generated icon set in $ICONSET"
rm -rf "$TMP"
