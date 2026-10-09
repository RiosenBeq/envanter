#!/bin/bash
# NextGen Envanter.app paketini ve şirket içi dağıtım arşivini üretir:
#   ./Scripts/build_app.sh            → build/NextGen Envanter.app + build/NextGen-Envanter-<sürüm>.zip
#   ./Scripts/build_app.sh --dmg      → ayrıca .dmg disk görüntüsü
# Uygulama App Store'a gönderilmez; ad-hoc imzalanır. İlk açılışta macOS uyarı verirse:
#   Finder'da uygulamaya sağ tıklayıp "Aç" deyin ya da:  xattr -dr com.apple.quarantine "/Applications/NextGen Envanter.app"
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="NextGen Envanter"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

echo "▸ Derleniyor (arm64 + Intel)…"
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  BIN=".build/apple/Products/Release/Envanter"
  TOOL=".build/apple/Products/Release/EnvanterTool"
else
  echo "  (evrensel derleme olmadı, yalnızca bu Mac için derleniyor)"
  swift build -c release
  BIN=".build/release/Envanter"
  TOOL=".build/release/EnvanterTool"
fi

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ İkon üretiliyor…"
  rm -rf build/AppIcon.iconset && mkdir -p build
  swift Scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Envanter"
# Komut satırı aracı da paketin içinde dağıtılır (Contents/MacOS/EnvanterTool)
cp "$TOOL" "$APP/Contents/MacOS/EnvanterTool"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
echo "✓ Hazır: $APP"

ZIP="build/NextGen-Envanter-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ Dağıtım arşivi: $ZIP"

if [ "${1:-}" = "--dmg" ]; then
  DMG="build/NextGen-Envanter-$VERSION.dmg"
  rm -rf build/dmg "$DMG" && mkdir -p build/dmg
  cp -R "$APP" build/dmg/
  ln -s /Applications build/dmg/Applications
  hdiutil create -volname "$APP_NAME" -srcfolder build/dmg -ov -format UDZO "$DMG" >/dev/null
  echo "✓ Disk görüntüsü: $DMG"
fi
