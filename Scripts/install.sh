#!/bin/bash
# Builds Heft optimised and installs it into /Applications.
#
#   Scripts/install.sh              # build, install, leave it closed
#   Scripts/install.sh --launch     # ...and open it afterwards
#   Scripts/install.sh --to ~/Applications
#
# Installing means copying the bundle: there is no installer package and no
# notarisation, because the app is signed ad-hoc for its author's own machine.
# That is enough for a locally built app and avoids pulling a paid Developer ID
# into a project that is not distributed. The consequence is that this copy
# will not run on anyone else's Mac without them building it themselves.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="/Applications"
LAUNCH=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --launch) LAUNCH=1; shift ;;
        --to)     DESTINATION="${2:?--to needs a folder}"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

DESTINATION="${DESTINATION/#\~/$HOME}"
if [[ ! -d "$DESTINATION" ]]; then
    echo "No such folder: $DESTINATION" >&2
    exit 1
fi

TARGET="$DESTINATION/Heft.app"

"$ROOT/Scripts/bundle.sh" release

# A running copy holds its bundle open, and replacing it underneath leaves the
# process on a half-deleted app.
if pgrep -x Heft >/dev/null; then
    echo "Quitting the running copy…"
    osascript -e 'tell application "Heft" to quit' >/dev/null 2>&1 || pkill -x Heft || true
    for _ in $(seq 1 20); do
        pgrep -x Heft >/dev/null || break
        sleep 0.25
    done
fi

rm -rf "$TARGET"
cp -R "$ROOT/.build/Heft.app" "$TARGET"

# Copying strips nothing, but the signature covers paths, so re-sign in place.
codesign --force --sign - "$TARGET" >/dev/null 2>&1 || true

echo "Installed $TARGET"
echo
echo "First launch: right-click the app and choose Open. macOS blocks a"
echo "double-click on an ad-hoc signed app the first time, and offers no"
echo "override in that dialog."

if [[ "$LAUNCH" -eq 1 ]]; then
    open "$TARGET"
fi
