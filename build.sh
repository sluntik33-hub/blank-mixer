#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

command -v xcodegen >/dev/null 2>&1 || {
  echo "Ошибка: не найден xcodegen. Установите: brew install xcodegen"
  exit 1
}

xcodegen generate

# ВАЖНО: ad-hoc, но ВКЛЮЧЁННАЯ подпись (не NO/NO как раньше).
# Несигнированный бинарник не имеет стабильной "code identity", из-за чего
# TCC (система разрешений macOS) не запоминает выданное разрешение на запись
# системного звука и спрашивает его заново при каждом перезапуске.
# Ad-hoc подпись даёт стабильную идентичность, пока бинарник не пересобран
# заново — разрешение запросится один раз при первом запуске из /Applications.
xcodebuild \
  -project PurpleMixer.xcodeproj \
  -scheme PurpleMixer \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  build

APP_PATH="build/Build/Products/Release/BLANK3.0.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Ошибка: $APP_PATH не найден."
  exit 1
fi

echo "Готово: $APP_PATH"

echo "Для DMG запустите: ./make-dmg.sh"

echo ""
echo "Разрешение на системный звук спросится один раз при первом запуске"
echo "из /Applications. Если после этого macOS всё равно продолжает"
echo "спрашивать заново — сбросьте старое (возможно повреждённое, от"
echo "несигнированных тестовых сборок) разрешение командой:"
echo "  tccutil reset AudioCapture com.yourname.blank3"
echo "и запустите .app из /Applications ещё раз (не из build/, путь тоже"
echo "должен быть стабильным)."
