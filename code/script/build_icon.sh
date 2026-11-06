#!/usr/bin/env bash
# Export the project-owned artwork to Apple's standard macOS icon representations.
set -euo pipefail
CODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$CODE_DIR/Resources/AppIconSource.png"
ICONSET="$CODE_DIR/.build/AppIcon.iconset"
OUTPUT="$CODE_DIR/Resources/AppIcon.icns"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  DOUBLE=$((SIZE * 2))
  /usr/bin/sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  /usr/bin/sips -z "$DOUBLE" "$DOUBLE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$OUTPUT"
/usr/bin/sips -z 1024 1024 "$SOURCE" --out "$CODE_DIR/Resources/AppIcon.png" >/dev/null
echo "$OUTPUT"
