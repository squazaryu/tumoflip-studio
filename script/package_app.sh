#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-bundle}"
APP_NAME="TumoflipStudio"
DISPLAY_NAME="Tumoflip Studio"
APP_VERSION="${TUMOFLIP_STUDIO_VERSION:-0.1.0}"
BUILD_NUMBER="${TUMOFLIP_STUDIO_BUILD_NUMBER:-1}"
RELEASE_TAG="${TUMOFLIP_STUDIO_RELEASE_TAG:-v${APP_VERSION}}"
CONFIGURATION="${TUMOFLIP_STUDIO_CONFIGURATION:-release}"
SIGNING_IDENTITY="${TUMOFLIP_STUDIO_SIGNING_IDENTITY:--}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "TUMOFLIP_STUDIO_VERSION must use major.minor.patch, got: $APP_VERSION" >&2
    exit 2
fi

if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "TUMOFLIP_STUDIO_BUILD_NUMBER must be a positive integer, got: $BUILD_NUMBER" >&2
    exit 2
fi

case "$MODE" in
    bundle|archive) ;;
    *)
        echo "usage: $0 [bundle|archive]" >&2
        exit 2
        ;;
esac

case "$CONFIGURATION" in
    debug|release) ;;
    *)
        echo "TUMOFLIP_STUDIO_CONFIGURATION must be debug or release" >&2
        exit 2
        ;;
esac

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION" --product "$APP_NAME" --jobs 2
BUILD_BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/Resources/Info.plist" "$INFO_PLIST"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
chmod +x "$APP_BINARY"

/usr/bin/plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$INFO_PLIST"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$INFO_PLIST"

SIGNING_KIND="developer-id"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    SIGNING_KIND="ad-hoc"
fi

/usr/bin/codesign \
    --force \
    --deep \
    --options runtime \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE"

/usr/bin/plutil -lint "$INFO_PLIST"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

ARCHITECTURES="$(/usr/bin/lipo -archs "$APP_BINARY" | tr ' ' '-')"
printf '%s\n' \
    "tag=$RELEASE_TAG" \
    "version=$APP_VERSION" \
    "build=$BUILD_NUMBER" \
    "configuration=$CONFIGURATION" \
    "architectures=$ARCHITECTURES" \
    "signing=$SIGNING_KIND" \
    >"$DIST_DIR/BUILD-METADATA.txt"

if [[ "$MODE" == "archive" ]]; then
    ARCHIVE_NAME="$APP_NAME-$RELEASE_TAG-macos-$ARCHITECTURES.zip"
    ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
    rm -f "$ARCHIVE_PATH" "$DIST_DIR/SHA256SUMS"
    (
        cd "$DIST_DIR"
        COPYFILE_DISABLE=1 /usr/bin/zip -qry -X "$ARCHIVE_NAME" "$DISPLAY_NAME.app"
    )
    if /usr/bin/unzip -Z1 "$ARCHIVE_PATH" | /usr/bin/grep -Eq '(^|/)\._|^__MACOSX/'; then
        echo "archive contains AppleDouble metadata" >&2
        exit 1
    fi
    (
        cd "$DIST_DIR"
        /usr/bin/shasum -a 256 "$ARCHIVE_NAME" >SHA256SUMS
    )
    echo "archive=$ARCHIVE_PATH"
    echo "checksums=$DIST_DIR/SHA256SUMS"
fi

echo "app=$APP_BUNDLE"
