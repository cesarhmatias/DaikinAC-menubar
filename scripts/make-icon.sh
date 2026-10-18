#!/bin/bash
# Renders the app icon and packs it as Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d /tmp/daikinac-icon.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
swift scripts/make-icon.swift "$WORK/icon-1024.png"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "$WORK/icon-1024.png" Resources/AppIcon.png
printf 'Icon written to Resources/AppIcon.icns\n'
