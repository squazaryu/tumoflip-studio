#!/usr/bin/env bash
set -euo pipefail

RELEASE_TAG="${1:-v0.1.0-beta.1}"
BUILD_NUMBER="${2:-2}"

if [[ ! "$RELEASE_TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-beta\.([1-9][0-9]*)$ ]]; then
    echo "release tag must match vMAJOR.MINOR.PATCH-beta.N" >&2
    exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TUMOFLIP_STUDIO_VERSION="${BASH_REMATCH[1]}" \
TUMOFLIP_STUDIO_BUILD_NUMBER="$BUILD_NUMBER" \
TUMOFLIP_STUDIO_RELEASE_TAG="$RELEASE_TAG" \
TUMOFLIP_STUDIO_CONFIGURATION=release \
    "$ROOT_DIR/script/package_app.sh" archive
