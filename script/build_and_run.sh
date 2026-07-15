#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TumoflipStudio"
DISPLAY_NAME="Tumoflip Studio"
BUNDLE_ID="com.tumowuh.TumoflipStudio"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

swift build --configuration release --jobs 2
BUILD_BINARY="$(swift build --configuration release --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
fi
chmod +x "$APP_BINARY"
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

install_app() {
    ditto "$APP_BUNDLE" "/Applications/$DISPLAY_NAME.app"
    /usr/bin/open -n "/Applications/$DISPLAY_NAME.app"
}

case "$MODE" in
    run)
        open_app
        ;;
    --install|install)
        install_app
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app
        sleep 2
        pgrep -x "$APP_NAME" >/dev/null
        ;;
    *)
        echo "usage: $0 [run|--install|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
