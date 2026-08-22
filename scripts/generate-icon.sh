#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESOURCES_DIR="$PROJECT_DIR/Resources"
ICON_SOURCE="$RESOURCES_DIR/icon-1024.png"
ICONSET_DIR="/tmp/AppIconQuick.iconset"
OUTPUT_DIR="$PROJECT_DIR/Sources/Resources"
OUTPUT="$OUTPUT_DIR/AppIcon.icns"

mkdir -p "$RESOURCES_DIR" "$OUTPUT_DIR"

# Generate source PNG if it doesn't exist.
# Design: black macOS squircle, white lightning bolt. Monochrome, low key.
# Delete Resources/icon-1024.png to regenerate.
if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "Generating source icon..."
    python3 - "$ICON_SOURCE" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFilter

out = sys.argv[1]
SIZE = 1024
SS = 4                      # supersample for clean edges
S = SIZE * SS

# macOS icon grid: the tile is 824 px wide on a 1024 canvas, radius ~22.5 %.
tile = int(824 * SS)
inset = (S - tile) // 2
radius = int(tile * 0.225)

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Tile: near black with a faint vertical lift at the top.
tile_img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
tile_draw = ImageDraw.Draw(tile_img)
tile_draw.rounded_rectangle(
    (inset, inset, inset + tile, inset + tile), radius=radius, fill=(14, 14, 16, 255)
)
gradient = Image.new("L", (1, tile))
for y in range(tile):
    gradient.putpixel((0, y), int(34 * (1 - y / tile)))
gradient = gradient.resize((tile, tile))
lift = Image.new("RGBA", (S, S), (0, 0, 0, 0))
lift.paste(Image.new("RGBA", (tile, tile), (255, 255, 255, 255)), (inset, inset), gradient)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    (inset, inset, inset + tile, inset + tile), radius=radius, fill=255
)
tile_img = Image.composite(Image.alpha_composite(tile_img, lift), tile_img, mask)
img = Image.alpha_composite(img, tile_img)

# Hairline highlight just inside the edge.
draw = ImageDraw.Draw(img)
draw.rounded_rectangle(
    (inset + SS, inset + SS, inset + tile - SS, inset + tile - SS),
    radius=radius - SS, outline=(255, 255, 255, 28), width=int(1.5 * SS)
)

# Bolt: same silhouette as the original mark, in white. Coordinates are in
# bolt units where the bolt spans y = -0.42 ... 0.42.
bolt = [
    ( 0.10, -0.42),
    (-0.20,  0.04),
    ( 0.02,  0.04),
    (-0.10,  0.42),
    ( 0.22, -0.06),
    ( 0.00, -0.06),
]
bolt_height = tile * 0.50
scale = bolt_height / 0.84
cx, cy = S / 2, S / 2
points = [(cx + x * scale, cy + y * scale) for x, y in bolt]
draw.polygon(points, fill=(246, 246, 247, 255))

img = img.resize((SIZE, SIZE), Image.LANCZOS)
img.save(out, "PNG")
print("Generated", out)
PY
fi

# Generate iconset
echo "Creating iconset..."
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" > /dev/null 2>&1
    retina=$((size * 2))
    sips -z $retina $retina "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" > /dev/null 2>&1
done
sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null 2>&1

# Generate .icns
echo "Generating .icns..."
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT"
rm -rf "$ICONSET_DIR"

echo "Generated: $OUTPUT"
