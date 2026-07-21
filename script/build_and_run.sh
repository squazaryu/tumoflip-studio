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

CONFIGURATION=debug
if [[ "$MODE" == "--install" || "$MODE" == "install" ]]; then
    CONFIGURATION=release
fi
TUMOFLIP_STUDIO_CONFIGURATION="$CONFIGURATION" "$ROOT_DIR/script/package_app.sh" bundle

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

install_app() {
    local install_path="/Applications/$DISPLAY_NAME.app"
    local staging_path="/Applications/.$APP_NAME.installing"
    local backup_path="/Applications/.$APP_NAME.previous"
    local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    rm -rf "$staging_path" "$backup_path"
    ditto "$APP_BUNDLE" "$staging_path"

    if [[ -d "$install_path" ]]; then
        mv "$install_path" "$backup_path"
    fi

    if ! mv "$staging_path" "$install_path"; then
        if [[ -d "$backup_path" ]]; then
            mv "$backup_path" "$install_path"
        fi
        return 1
    fi

    if ! /usr/bin/codesign --verify --deep --strict "$install_path"; then
        rm -rf "$install_path"
        if [[ -d "$backup_path" ]]; then
            mv "$backup_path" "$install_path"
        fi
        return 1
    fi

    rm -rf "$backup_path"
    touch "$install_path"
    "$lsregister" -f "$install_path"
    /usr/bin/open -n "$install_path"
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
