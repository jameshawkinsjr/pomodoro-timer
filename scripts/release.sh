#!/bin/bash
#
# Publishes the committed code as a release that the app on this Mac installs by itself.
#
#   scripts/release.sh                     notes are the commit titles since the last release
#   scripts/release.sh "What changed."
#
# Builds the app (build.sh), packs it in Pomodoro-Timer-<version>-<build>.dmg and puts that and
# latest.json (version, build, file, sha256, publishedAt, notes) in the releases folder:
# $POMODORO_RELEASES, else ~/Library/Application Support/Pomodoro Timer/releases. The app reads
# that folder every minute (ReleaseFolder in UpdateChecker.swift). The last three images are kept.
# Then tags the commit v<version>-<build> and pushes the tag (a failed push only warns).
#
# Handoff's after-merge step runs this in its _release checkout of main. The build number is the
# git commit count: commit before releasing again. Raise VERSION for a new version number.

set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash your changes first: a release is built from the committed code." >&2
    exit 1
fi

APP_NAME="Pomodoro Timer"
BUILD_DIR="build"
RELEASES="${POMODORO_RELEASES:-$HOME/Library/Application Support/Pomodoro Timer/releases}"
VERSION="$(cat VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD)"
TAG="v$VERSION-$BUILD_NUMBER"
FILE="Pomodoro-Timer-$VERSION-$BUILD_NUMBER.dmg"
if [ -e "$RELEASES/$FILE" ]; then
    echo "Release $FILE already exists in $RELEASES. Commit something new first." >&2
    exit 1
fi

NOTES="${1:-}"
if [ -z "$NOTES" ]; then
    PREVIOUS="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
    NOTES="$(git log --format='- %s' ${PREVIOUS:+$PREVIOUS..}HEAD)"
fi

./build.sh

# A plain image, not make_dmg.sh's: the updater only needs the app, and this one stays scriptable
# when nobody is at the Mac.
echo "==> Packing $FILE"
PACK="$BUILD_DIR/release-image"
rm -rf "$PACK" "$BUILD_DIR/$FILE"
mkdir -p "$PACK"
ditto "$BUILD_DIR/$APP_NAME.app" "$PACK/$APP_NAME.app"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$PACK" -fs HFS+ -format UDZO -ov "$BUILD_DIR/$FILE"
rm -rf "$PACK"
SHA="$(shasum -a 256 "$BUILD_DIR/$FILE" | cut -d' ' -f1)"

python3 -I - "$VERSION" "$BUILD_NUMBER" "$FILE" "$SHA" "$NOTES" > "$BUILD_DIR/latest.json" <<'PY'
import json, sys, datetime
version, build, file, sha, notes = sys.argv[1:]
print(json.dumps({
    "version": version, "build": int(build), "file": file, "sha256": sha,
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "notes": notes,
}, indent=2))
PY

echo "==> Publishing to $RELEASES"
mkdir -p "$RELEASES"
# The image goes in before latest.json names it, and each lands with a rename, so the app never
# reads half a file.
cp "$BUILD_DIR/$FILE" "$RELEASES/.$FILE.partial"
mv "$RELEASES/.$FILE.partial" "$RELEASES/$FILE"
cp "$BUILD_DIR/latest.json" "$RELEASES/.latest.json.partial"
mv "$RELEASES/.latest.json.partial" "$RELEASES/latest.json"
ls -t "$RELEASES"/Pomodoro-Timer-*.dmg | tail -n +4 | while IFS= read -r old; do rm -f "$old"; done

if git tag "$TAG" && git push origin "$TAG"; then
    echo "==> Tagged $TAG"
else
    echo "    Couldn't tag or push $TAG; the release is published anyway." >&2
fi
echo "==> Released $VERSION (build $BUILD_NUMBER)"
