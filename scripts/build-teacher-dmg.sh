#!/bin/bash
#
# Сборка установщика (.dmg) Safe Exam Browser с панелью преподавателя.
#
# Запуск на Mac с установленным Xcode (бесплатно в App Store):
#     cd путь/к/seb-mac-main
#     bash scripts/build-teacher-dmg.sh
#
# Результат: build/SEB-Teacher.dmg
#
# Без переменных окружения приложение подписывается «ad-hoc» (без
# сертификата Apple) — его можно запускать на своих Mac, но при первом
# открытии macOS попросит подтвердить запуск (см. «Как установить.txt»).
#
# Если есть платный аккаунт Apple Developer, можно подписать и
# нотаризовать приложение, задав переменные:
#     SIGN_IDENTITY="Developer ID Application: Имя (TEAMID)"
#     NOTARY_PROFILE="имя профиля из: xcrun notarytool store-credentials"
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD_DIR="$ROOT/build"
APP_NAME="Safe Exam Browser"
DMG_NAME="${DMG_NAME:-SEB-Teacher}"
VOLUME_NAME="${VOLUME_NAME:-SEB Teacher}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

echo "==> Xcode: $(xcodebuild -version | head -1)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Скрипт сборки проекта увеличивает CFBundleVersion в Info.plist — сохраняем
# оригинал, чтобы не оставлять изменений в рабочей копии.
cp SafeExamBrowser-Info.plist "$BUILD_DIR/Info.plist.orig"
restore_plist() { cp "$BUILD_DIR/Info.plist.orig" SafeExamBrowser-Info.plist 2>/dev/null || true; }
trap restore_plist EXIT

echo "==> Загрузка Swift-пакетов"
xcodebuild -resolvePackageDependencies \
    -workspace SafeExamBrowser.xcworkspace \
    -scheme "$APP_NAME" \
    -derivedDataPath "$BUILD_DIR/DerivedData"

echo "==> Сборка (Release, Apple Silicon + Intel)"
set -o pipefail
xcodebuild build \
    -workspace SafeExamBrowser.xcworkspace \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    DEVELOPMENT_TEAM="" \
    GCC_TREAT_WARNINGS_AS_ERRORS=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    | tee "$BUILD_DIR/xcodebuild.log" \
    | grep -E "error:|warning: .*TeacherPanel|\*\* BUILD" || true

if ! grep -q "\*\* BUILD SUCCEEDED \*\*" "$BUILD_DIR/xcodebuild.log"; then
    echo "!! Сборка не удалась. Ошибки:"
    grep -E "error:" "$BUILD_DIR/xcodebuild.log" | sort -u | head -50
    exit 1
fi

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "!! Не найдено приложение: $APP_PATH"
    exit 1
fi

echo "==> Подпись"
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --deep --options runtime --timestamp \
        --entitlements "$ROOT/scripts/teacher-build.entitlements" \
        --sign "$SIGN_IDENTITY" "$APP_PATH"
else
    codesign --force --deep --sign - "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"

echo "==> Создание DMG"
STAGE="$BUILD_DIR/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/scripts/teacher-install-readme.txt" "$STAGE/Как установить.txt"

DMG_PATH="$BUILD_DIR/$DMG_NAME.dmg"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"

if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
    if [ -n "$NOTARY_PROFILE" ]; then
        echo "==> Нотаризация"
        xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG_PATH"
    fi
fi

echo "==> Готово: $DMG_PATH"
