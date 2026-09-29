#!/bin/bash
# Собирает релизный .app и упаковывает его в красивый DMG
# (окно с иконкой приложения и ярлыком «Программы» для перетаскивания).
# Нужны только встроенные утилиты macOS; create-dmg — по желанию.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="BLANK3.0"
VERSION=$(grep CFBundleShortVersionString project.yml | sed -E "s/.*\"(.*)\"/\1/")
[[ "$VERSION" == *'$('* ]] && VERSION="3.0"
DMG="dist/${APP_NAME}-${VERSION}.dmg"
APP_PATH="build/Build/Products/Release/${APP_NAME}.app"

./build.sh
mkdir -p dist
rm -f "$DMG"

if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "$APP_NAME" \
    --window-size 540 340 \
    --icon-size 110 \
    --icon "${APP_NAME}.app" 140 160 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 400 160 \
    "$DMG" "$APP_PATH"
else
  STAGE=$(mktemp -d)
  cp -R "$APP_PATH" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✅ Готово: $DMG"
