#!/bin/bash
# Builds Pomodoro Timer.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PomodoroTimer"

APP="build/Pomodoro Timer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PomodoroTimer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The updater compares CFBundleVersion, so it's the git commit count: a plain integer that only grows.
VERSION="$(cat VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD)"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$APP/Contents/Info.plist"

# Ad-hoc sign so macOS will run it locally.
codesign --force --sign - "$APP"

echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
echo "Run with: open \"$APP\"  (or copy it to /Applications)"
