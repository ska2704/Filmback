#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_OUT="${1:-$(dirname "$PROJECT_DIR")}"
BUILD_CACHE="${FILMBACK_BUILD_DIR:-$PROJECT_DIR/.build}"
mkdir -p "$BUILD_OUT"
swift build --build-system native --package-path "$PROJECT_DIR" --scratch-path "$BUILD_CACHE" -c release
BIN_DIR="$(swift build --build-system native --package-path "$PROJECT_DIR" --scratch-path "$BUILD_CACHE" -c release --show-bin-path)"
APP_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/filmback-package.XXXXXX")"
trap 'rm -rf "$APP_TEMP"' EXIT
APP_DIR="$APP_TEMP/Filmback.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/Filmback" "$APP_DIR/Contents/MacOS/Filmback"
cp "$PROJECT_DIR/scripts/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$PROJECT_DIR/README.md" "$APP_DIR/Contents/Resources/README.md"
if [ -f "$PROJECT_DIR/scripts/AppIcon.icns" ]; then
  cp "$PROJECT_DIR/scripts/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
if [ -d "$PROJECT_DIR/Assets/Covers" ]; then
  ditto "$PROJECT_DIR/Assets/Covers" "$APP_DIR/Contents/Resources/Covers"
fi
xattr -cr "$APP_DIR"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
ditto -c -k --keepParent --norsrc --noextattr "$APP_DIR" "$BUILD_OUT/Filmback-macOS.zip"
ditto --norsrc --noextattr "$APP_DIR" "$BUILD_OUT/Filmback.app"
printf 'Built %s\n' "$BUILD_OUT/Filmback-macOS.zip"
