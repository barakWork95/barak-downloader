#!/bin/bash
# בונה את "Barak Downloader.app". עם --install מעתיק גם לשולחן העבודה.
# ICON=electric ./build.sh לגרסת האייקון הכהה (ברירת מחדל: brand)
# להריץ שוב אחרי כל שינוי ב-engine.py: האפליקציה מחזיקה עותק משלו.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Barak Downloader"
ICON="${ICON:-brand}"
APP="build/$NAME.app"

mkdir -p build
if [ ! -f build/AppIcon.icns ] || [ "$(cat build/icon-variant 2>/dev/null)" != "$ICON" ] || [ tools/make_icon.swift -nt build/AppIcon.icns ]; then
  swiftc -O tools/make_icon.swift -o build/make_icon
  build/make_icon build/icon-1024.png "$ICON"
  echo "$ICON" > build/icon-variant
  for s in 16 32 48 128; do sips -z $s $s build/icon-1024.png --out chrome-extension/icons/$s.png >/dev/null; done
  rm -rf build/AppIcon.iconset && mkdir build/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/he.lproj"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15 \
  app/*.swift -o "$APP/Contents/MacOS/Barak"
cp app/Info.plist "$APP/Contents/"
cp engine.py build/AppIcon.icns "$APP/Contents/Resources/"
cp -R chrome-extension "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "נבנה: $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf "$HOME/Desktop/$NAME.app"
  cp -R "$APP" "$HOME/Desktop/"
  echo "הותקן: ~/Desktop/$NAME.app"
fi
