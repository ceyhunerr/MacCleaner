#!/bin/bash
# MacCleaner'ı derler ve dist/MacCleaner.app paketini oluşturur.
# Kullanım: ./build.sh [--install] [--open] [--dmg]
#   --install  /Applications klasörüne kopyalar
#   --open     derlemeden sonra uygulamayı açar
#   --dmg      dist/MacCleaner-<sürüm>.dmg kurulum imajını oluşturur
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/MacCleaner.app"
# Terminal Rosetta altında çalışıyor olsa bile yerel (arm64) derle.
SWIFT=(arch -arm64 swift)

echo "→ Derleniyor…"
"${SWIFT[@]}" build -c release
BIN="$("${SWIFT[@]}" build -c release --show-bin-path)/MacCleaner"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "→ Simge oluşturuluyor…"
  tmp=$(mktemp -d)
  "${SWIFT[@]}" Scripts/make_icon.swift "$tmp/AppIcon.iconset"
  iconutil -c icns "$tmp/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$tmp"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacCleaner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "✓ $APP hazır"

TARGET="$APP"
for arg in "$@"; do
  case "$arg" in
    --install)
      rm -rf /Applications/MacCleaner.app
      cp -R "$APP" /Applications/
      TARGET=/Applications/MacCleaner.app
      echo "✓ /Applications/MacCleaner.app kuruldu"
      ;;
    --dmg)
      # Uygulama ve Applications kısayolu: sürükle-bırak ile kurulum.
      VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
      DMG="dist/MacCleaner-$VERSION.dmg"
      staging=$(mktemp -d)
      cp -R "$APP" "$staging/"
      ln -s /Applications "$staging/Applications"
      rm -f "$DMG"
      hdiutil create -volname MacCleaner -srcfolder "$staging" -fs HFS+ -format UDZO "$DMG" >/dev/null
      rm -rf "$staging"
      echo "✓ $DMG hazır"
      ;;
  esac
done
for arg in "$@"; do
  [ "$arg" = "--open" ] && open "$TARGET"
done
exit 0
