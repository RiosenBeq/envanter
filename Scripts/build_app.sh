#!/bin/bash
# Envanter.app paketini üretir:  ./Scripts/build_app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Derleniyor (arm64 + Intel)…"
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  BIN=".build/apple/Products/Release/Envanter"
else
  echo "  (evrensel derleme olmadı, yalnızca bu Mac için derleniyor)"
  swift build -c release
  BIN=".build/release/Envanter"
fi

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ İkon üretiliyor…"
  rm -rf build/AppIcon.iconset && mkdir -p build
  swift Scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

APP="build/Envanter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Envanter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
echo "✓ Hazır: $APP"
