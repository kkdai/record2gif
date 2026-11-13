#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
APP_DIR="$ROOT_DIR/build/record2gif.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

cp "$BIN_PATH/Record2Gif" "$MACOS_DIR/record2gif"
chmod +x "$MACOS_DIR/record2gif"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

codesign --force --deep -s - "$APP_DIR"
echo "Built $APP_DIR"
