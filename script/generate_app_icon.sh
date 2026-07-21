#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:-$ROOT_DIR/Resources/AppIconSources/AppIcon-Dark.png}"
OUTPUT="${2:-$ROOT_DIR/Resources/AppIcon.icns}"

if [[ ! -f "$SOURCE" ]]; then
    echo "icon source not found: $SOURCE" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
ICONSET="$WORK_DIR/AppIcon.iconset"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$ICONSET"

render() {
    local pixels="$1"
    local name="$2"
    /usr/bin/sips -z "$pixels" "$pixels" "$SOURCE" --out "$ICONSET/$name" >/dev/null
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

/usr/bin/iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "icon=$OUTPUT"
