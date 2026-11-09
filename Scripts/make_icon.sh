#!/bin/bash
# Builds Resources/AppIcon.icns from Resources/AppIcon-1024.png, drawn by Scripts/draw_icon.swift.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon-1024.png --out AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon-1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
echo "==> Resources/AppIcon.icns"
