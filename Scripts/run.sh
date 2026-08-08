#!/bin/bash
# Build the .app and launch it, replacing any running instance.
#
#   Scripts/run.sh                      # last-used vault (or welcome screen)
#   Scripts/run.sh <vault>              # open a specific vault
#   Scripts/run.sh <vault> <note.md>    # ...and jump straight to a note
#   Scripts/run.sh --release            # optimised build
#
# The script keeps the one-command workflow while Xcode supplies the native app
# bundle, resources, signing, and App Intent metadata.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="debug"

if [[ "${1:-}" == "--release" ]]; then
    CONFIG="release"
    shift
fi

VAULT="${1:-}"
NOTE="${2:-}"

"$ROOT/Scripts/bundle.sh" "$CONFIG"

if [[ "$CONFIG" == "debug" ]]; then
    XCODE_CONFIGURATION="Debug"
else
    XCODE_CONFIGURATION="Release"
fi
APP="$ROOT/.build/XcodeDerivedData/Build/Products/$XCODE_CONFIGURATION/Heft.app"

# Replace a running copy so the new build is what actually starts.
if pgrep -x Heft >/dev/null; then
    echo "Quitting running instance…"
    osascript -e 'tell application "Heft" to quit' >/dev/null 2>&1 || pkill -x Heft || true
    for _ in $(seq 1 20); do
        pgrep -x Heft >/dev/null || break
        sleep 0.25
    done
fi

ARGS=()
if [[ -n "$VAULT" ]]; then
    # Resolve to an absolute path: the app is launched detached and does not
    # inherit this shell's working directory.
    if [[ ! -d "$VAULT" ]]; then
        echo "No such vault folder: $VAULT" >&2
        exit 1
    fi
    VAULT="$(cd "$VAULT" && pwd)"
    ARGS+=(--vault "$VAULT")
    [[ -n "$NOTE" ]] && ARGS+=(--open "$NOTE")
fi

if [[ ${#ARGS[@]} -gt 0 ]]; then
    open -a "$APP" --args "${ARGS[@]}"
else
    open -a "$APP"
fi

echo "Launched Heft (${CONFIG})${VAULT:+ on $VAULT}"
