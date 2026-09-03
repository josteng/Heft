#!/bin/bash
# Does the app actually start?
#
# This exists because it once did not. `heft help` was made to answer an empty
# command line, which is exactly how the Dock, Finder and `open` launch a Mac
# app: it printed usage to a stdout nobody was reading and exited. One bounce
# in the Dock, no window, and every test still green — the suite cannot launch
# an app bundle, and a bare `heft` in a terminal goes through the wrapper and
# never takes that path. The only broken route was the one everybody uses.
#
#   Scripts/smoke.sh              # build, launch, check, quit
#   Scripts/smoke.sh --keep       # leave it running to look at
#
# Always sandboxed: it must not touch real settings.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

SUITE="dev.stenglein.Heft.smoke"
TMP="$(mktemp -d)"
VAULT="$TMP/SmokeVault"
mkdir -p "$VAULT"
printf '# Smoke\n\nA paragraph, a [[link]], and a list:\n\n- one\n- two\n' > "$VAULT/Note.md"

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

cleanup() {
    if [[ "$KEEP" != "1" ]]; then
        [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null
        defaults delete "$SUITE" 2>/dev/null
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT

echo "Building..."
"$ROOT/Scripts/bundle.sh" debug >/dev/null 2>&1 || fail "the bundle would not build"
APP="$ROOT/.build/XcodeDerivedData/Build/Products/Debug/Heft.app"
[[ -x "$APP/Contents/MacOS/Heft" ]] || fail "no binary at $APP"

defaults delete "$SUITE" 2>/dev/null

# Seeded so a bare launch has somewhere to go.
#
# This is the whole point of the test: the app is started with **no arguments
# at all**, because that is how the Dock, Finder and `open` start it, and it
# is the one launch that was broken. Passing `--vault` instead tests a path
# nobody takes — the first version of this test did exactly that, and it
# passed with the bug reintroduced.
defaults write "$SUITE" "dev.stenglein.Heft.vaultPath" -string "$VAULT"

# 1. A bare exec first, which is the cheapest way to catch the exact bug this
# script exists for: the app answered an empty command line with `heft help`,
# printed usage to a stdout nobody was reading, and exited. Streams are
# captured here, which a LaunchServices launch cannot do.
echo "Launching with no arguments, the way the Dock does..."
HEFT_DEFAULTS_SUITE="$SUITE" nohup "$APP/Contents/MacOS/Heft" \
    >/tmp/heft-smoke.out 2>/tmp/heft-smoke.err &
BARE_PID=$!
disown "$BARE_PID" 2>/dev/null || true
sleep 6

if ! kill -0 "$BARE_PID" 2>/dev/null; then
    echo "--- stdout ---"; head -20 /tmp/heft-smoke.out
    echo "--- stderr ---"; head -20 /tmp/heft-smoke.err
    fail "the app exited instead of starting"
fi
# A GUI app that prints is one taking a command-line path.
if [[ -s /tmp/heft-smoke.out ]]; then
    echo "--- stdout ---"; head -20 /tmp/heft-smoke.out
    fail "the app wrote to stdout, so it took a command-line path"
fi
kill -9 "$BARE_PID" 2>/dev/null

# 2. Then again through LaunchServices, which is how the Dock and Finder really
# start it, to prove it opened something.
#
# It has to be this way round for the check below to mean anything. A bare exec
# is not a registered application process: AppleScript cannot address it, so it
# can only be killed, and a Cocoa app killed by signal never flushes its
# preferences — leaving this test reading whatever cfprefsd happened to have
# cached, which passes or fails by timing. `--env` is what makes a sandboxed
# launch possible this way; `-n` forces a new instance rather than activating
# an installed copy that is already running.
echo "Launching again through LaunchServices..."
open -n --env "HEFT_DEFAULTS_SUITE=$SUITE" "$APP" || fail "LaunchServices would not start it"
sleep 7
APP_PID=$(pgrep -n -f "XcodeDerivedData.*Heft.app/Contents/MacOS/Heft")
[[ -n "$APP_PID" ]] || fail "nothing was running after LaunchServices started it"

# 3. Quit it, then read what it wrote.
#
# Preferences written by a running process are not visible to `defaults read`:
# cfprefsd caches them per process until the writer flushes, which is on quit.
echo "Quitting..."
osascript -e "tell application \"System Events\" to tell \
    (first application process whose unix id is $APP_PID) to quit" >/dev/null 2>&1
for _ in $(seq 1 40); do
    kill -0 "$APP_PID" 2>/dev/null || break
    sleep 0.25
done
kill -9 "$APP_PID" 2>/dev/null
sleep 1

# 4. It opened the vault it was given.
#
# Proof it opened rather than merely started: a fresh recents list only gets an
# entry when a vault session is created, and the session is created by the
# scene, so an entry means the UI came up.
RECENTS=$(defaults read "$SUITE" "dev.stenglein.Heft.recentVaults" 2>/dev/null)
[[ -n "$RECENTS" ]] || fail "the app started but never opened its vault"
echo "$RECENTS" | grep -q "SmokeVault" \
    || fail "opened something else: $(echo "$RECENTS" | tr -d '\n')"
echo "  opened the vault it had, with no arguments"

# There is deliberately no "did a window appear" check. AppKit saves a window
# frame only during a graceful quit, and this test cannot quit gracefully: the
# app is launched as a bare process so LaunchServices does not know it and
# AppleScript cannot reach it. Recording the vault is the available proxy, and
# a strong one — the vault session is created by the scene, so if one exists
# the UI came up.

# 6. And it left the real settings alone.
REAL=$(defaults read dev.stenglein.Heft 2>/dev/null | grep -c "SmokeVault")
[[ "$REAL" == "0" ]] || fail "the smoke vault reached the real settings"

echo "SMOKE PASS: launched, stayed up, opened its vault, real settings untouched"
if [[ "$KEEP" == "1" ]]; then
    echo "  sandbox suite $SUITE kept for inspection"
fi
exit 0
