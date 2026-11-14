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

DEFAULT_IDENTITY="record2gif Local Signing"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$SIGN_IDENTITY"
elif security find-identity -p codesigning 2>/dev/null | grep -Fq "\"$DEFAULT_IDENTITY\""; then
    IDENTITY="$DEFAULT_IDENTITY"
else
    IDENTITY="-"
    echo "Warning: '$DEFAULT_IDENTITY' identity not found in keychain; falling back to ad-hoc signing (-). Screen Recording permission will reset on each rebuild." >&2
fi

echo "Signing $APP_DIR with identity: $IDENTITY"
codesign --force --deep --sign "$IDENTITY" "$APP_DIR"
codesign -dr - "$APP_DIR"
echo "Built $APP_DIR"
