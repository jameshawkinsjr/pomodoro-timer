#!/bin/bash
# Builds the app and packages it into build/Pomodoro Timer.dmg with a
# drag-to-Applications layout.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

APP_NAME="Pomodoro Timer"
APP="build/$APP_NAME.app"
DMG="build/$APP_NAME.dmg"
STAGING="build/dmg-staging"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG"

rm -rf "$STAGING"
echo "Created $DMG"
