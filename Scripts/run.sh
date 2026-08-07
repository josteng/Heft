#!/bin/bash
# Build the .app and launch it, replacing any running instance.
#
#   Scripts/run.sh                      # last-used vault (or welcome screen)
#   Scripts/run.sh <vault>              # open a specific vault
#   Scripts/run.sh <vault> <note.md>    # ...and jump straight to a note
#   Scripts/run.sh --release            # optimised build
#
# Launching via the bundle rather than `swift run` is deliberate: a bare SwiftPM
# executable has no dock icon, no menu bar, and no stable code identity, so
# macOS forgets the chosen vault between launches.

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
    open -a "$ROOT/.build/Heft.app" --args "${ARGS[@]}"
else
    open -a "$ROOT/.build/Heft.app"
fi

echo "Launched Heft (${CONFIG})${VAULT:+ on $VAULT}"
