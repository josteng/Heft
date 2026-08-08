#!/bin/bash
# Assembles a real .app bundle around the SwiftPM executable.
# Needed because this project has no Xcode project: a bare `swift run`
# binary has no bundle, so it gets no dock icon, no menu bar and no
# window restoration. Usage: Scripts/bundle.sh [debug|release]

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/Heft"
APP="$ROOT/.build/Heft.app"

swift build -c "$CONFIG" --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Heft"

# SwiftPM emits each dependency's resources as a sibling .bundle. `Bundle.module`
# looks in the app's Resources directory, so they must be copied in or the
# lookup traps at runtime — SwiftMath's math fonts live here.
shopt -s nullglob
for resource in "$ROOT/.build/$CONFIG"/*.bundle; do
    cp -R "$resource" "$APP/Contents/Resources/"
done
shopt -u nullglob

# Compile the layered icon. macOS 26 reads Assets.car and picks the light, dark
# or tinted variant itself; the .icns actool emits alongside it is the fallback
# for earlier systems. See Resources/Heft.icon/README.md.
#
# actool ships with Xcode, not with the Command Line Tools, and this machine's
# xcode-select may well point at the latter. Finding Xcode through DEVELOPER_DIR
# keeps that a local detail rather than a system setting the build depends on.
ICON_KEYS=""
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [[ -d "$ROOT/Resources/Heft.icon" ]] && command -v actool >/dev/null \
   && [[ -n "${DEVELOPER_DIR:-}" ]]; then
    PARTIAL="$(mktemp -t heft-icon-plist)"
    actool "$ROOT/Resources/Heft.icon" \
        --compile "$APP/Contents/Resources" \
        --platform macosx \
        --minimum-deployment-target 26.0 \
        --app-icon Heft \
        --output-partial-info-plist "$PARTIAL" \
        --errors --warnings >/dev/null
    ICON_KEYS='    <key>CFBundleIconFile</key>        <string>Heft</string>
    <key>CFBundleIconName</key>        <string>Heft</string>'
    rm -f "$PARTIAL"
else
    echo "warning: Xcode not found, building without an app icon" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Heft</string>
    <key>CFBundleDisplayName</key>     <string>Heft</string>
    <key>CFBundleExecutable</key>      <string>Heft</string>
    <key>CFBundleIdentifier</key>      <string>dev.stenglein.Heft</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
$ICON_KEYS
    <key>LSMinimumSystemVersion</key>  <string>26.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSSupportsAutomaticTermination</key> <true/>
    <!-- Declared as an editor of markdown so Finder offers Heft in Open With
         and the app can be made the default for .md files. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>     <string>Markdown Document</string>
            <key>CFBundleTypeRole</key>     <string>Editor</string>
            <key>LSHandlerRank</key>        <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
                <string>public.plain-text</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS grants a stable identity: without this the app is
# re-prompted for file access and loses UserDefaults between launches.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
