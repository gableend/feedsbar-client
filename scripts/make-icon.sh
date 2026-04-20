#!/usr/bin/env bash
#
# scripts/make-icon.sh — slice a 1024x1024 master PNG into the 10 Mac AppIcon
# size/scale variants and patch Contents.json so Xcode picks them up.
#
# Usage:
#   ./scripts/make-icon.sh                        # defaults to icon-source.png at repo root
#   ./scripts/make-icon.sh /path/to/master.png
#
# Source must be exactly 1024x1024. Anything else would either upscale (ugly)
# or be ambiguous about how to crop, so we bail rather than guess.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="${1:-$REPO_ROOT/icon-source.png}"
ICONSET="$REPO_ROOT/FeedsBarClient/Resources/Assets.xcassets/AppIcon.appiconset"

[[ -f "$SRC" ]] || { echo "source not found: $SRC" >&2; exit 1; }
[[ -d "$ICONSET" ]] || { echo "iconset dir missing: $ICONSET" >&2; exit 1; }

# Validate dimensions — sips prints two 'pixelWidth/pixelHeight' lines.
WIDTH=$(sips -g pixelWidth "$SRC" | awk '/pixelWidth/ {print $2}')
HEIGHT=$(sips -g pixelHeight "$SRC" | awk '/pixelHeight/ {print $2}')
if [[ "$WIDTH" != "1024" || "$HEIGHT" != "1024" ]]; then
    echo "source must be 1024x1024, got ${WIDTH}x${HEIGHT}" >&2
    exit 1
fi

echo "Slicing $SRC into $ICONSET"

# Each row: target pixel dimension + filename Xcode expects. The assetcatalog
# tooling is lenient about filenames as long as Contents.json references them,
# but Apple's canonical naming keeps the set legible at a glance.
#
# Two-column row strings (not associative arrays, because macOS still ships
# bash 3.2 which doesn't have them). sips is fast enough that running it ten
# times — even when two rows share a pixel size — is under a second total.
VARIANTS="16:icon_16x16.png
32:icon_16x16@2x.png
32:icon_32x32.png
64:icon_32x32@2x.png
128:icon_128x128.png
256:icon_128x128@2x.png
256:icon_256x256.png
512:icon_256x256@2x.png
512:icon_512x512.png
1024:icon_512x512@2x.png"

while IFS=':' read -r px name; do
    [[ -z "$px" ]] && continue
    target="$ICONSET/$name"
    # sips -Z scales the LARGER side to px preserving aspect ratio. With a
    # square source the result is exactly $px on both sides.
    sips -Z "$px" "$SRC" --out "$target" >/dev/null
    echo "  ${px}x${px}  $name"
done <<< "$VARIANTS"

# Rewrite Contents.json with filenames bound to each slot. Xcode ignores the
# slot entry if no filename is set, which is why a half-populated iconset
# falls back to the generic app icon (silently, of course).
cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "Contents.json updated. Rebuild in Xcode (clean build recommended) to pick up the new icon."
