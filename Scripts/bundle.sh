#!/bin/bash
# Builds the native macOS app with its Xcode app target.
# Usage: Scripts/bundle.sh [debug|release]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"

case "$CONFIG" in
    debug)   XCODE_CONFIGURATION="Debug" ;;
    release) XCODE_CONFIGURATION="Release" ;;
    *) echo "Usage: Scripts/bundle.sh [debug|release]" >&2; exit 1 ;;
esac

# App Intents, the layered icon, resources, metadata, and signing are all
# standard Xcode build phases now. Keep the system xcode-select setting local.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

DERIVED_DATA="$ROOT/.build/XcodeDerivedData"
SOURCE_PACKAGES="$ROOT/.build/XcodeSourcePackages"
APP="$DERIVED_DATA/Build/Products/$XCODE_CONFIGURATION/Heft.app"

# App Intents are indexed from an ad-hoc build, but macOS refuses to execute
# them because the process is not a validated bundle. Prefer a locally
# installed Apple Development certificate when one is available. This still
# keeps a fresh checkout buildable before an Apple ID is configured in Xcode.
SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
        | awk '/"Apple Development:/{print $2; exit}'
)"
if [[ -n "$SIGNING_IDENTITY" ]]; then
    SIGNING_ARGS=(
        CODE_SIGN_STYLE=Manual
        "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY"
    )
else
    SIGNING_ARGS=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY=-
    )
fi

xcodebuild \
    -quiet \
    -project "$ROOT/Heft.xcodeproj" \
    -scheme Heft \
    -configuration "$XCODE_CONFIGURATION" \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    "${SIGNING_ARGS[@]}" \
    build

echo "Built $APP"

if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo >&2
    echo "Note: built with local ad-hoc signing." >&2
    echo "The app works, but macOS will not run its Spotlight/Shortcuts actions." >&2
    echo "Add your Apple ID and an Apple Development certificate in Xcode to enable them." >&2
fi
