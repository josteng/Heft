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

# `--sandbox` isolates the app's preferences into their own suite, so a test
# launch cannot touch the installed app's settings. Without it, opening a
# throwaway vault rewrites `vaultPath` — where Spotlight capture files things —
# and pushes a temporary folder into Open Recent.
SANDBOX=0
FRESH=0
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --sandbox) SANDBOX=1; shift ;;
        --fresh)   SANDBOX=1; FRESH=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

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
    # Launched as a bare process rather than through `open`, because LaunchServices
    # does not forward the environment and the whole point of the sandbox is one
    # environment variable. App Intents are not registered this way, which is fine:
    # the sandbox exists to look at the window.
    launch_sandboxed() {
        local suite="dev.stenglein.Heft.sandbox"
        if [[ "$FRESH" == "1" ]]; then
            defaults delete "$suite" 2>/dev/null || true
            echo "Sandbox preferences cleared."
        fi
        echo "Launching sandboxed (preferences in $suite; your real settings untouched)."
        # Detached, with its streams closed. A backgrounded GUI app inherits
        # stdout and stderr and holds them open for as long as it runs, so a
        # caller reading this script's output — a terminal pipeline, a script,
        # an agent's shell — waits for the app to quit rather than returning.
        HEFT_DEFAULTS_SUITE="$suite" nohup "$APP/Contents/MacOS/Heft" "$@" \
            >/dev/null 2>&1 &
        disown 2>/dev/null || true
    }

    # Passing the app bundle itself opens this exact build. `open -a "$APP"`
    # lets Launch Services resolve by bundle identity and may silently reuse an
    # older /Applications/Heft.app, which makes a freshly built feature appear
    # to be missing.
    if [[ "$SANDBOX" == "1" ]]; then
        launch_sandboxed "${ARGS[@]}"
    else
        open "$APP" --args "${ARGS[@]}"
    fi
else
    if [[ "$SANDBOX" == "1" ]]; then
        launch_sandboxed
    else
        open "$APP"
    fi
fi

echo "Launched Heft (${CONFIG})${VAULT:+ on $VAULT}"
