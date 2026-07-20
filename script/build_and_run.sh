#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TumoflipStudio"
DISPLAY_NAME="Tumoflip Studio"
BUNDLE_ID="com.tumowuh.TumoflipStudio"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
TUMOFLIP_STUDIO_CONFIGURATION=debug "$ROOT_DIR/script/package_app.sh" bundle

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
