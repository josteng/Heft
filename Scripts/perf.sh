#!/bin/bash
# Measure what Heft costs: a held key and a publish in the real window, then
# the release app launched sandboxed on a vault copy, at startup, idle, under
# the attribute churn an iCloud daemon produces, and under saves.
#
#   Scripts/perf.sh <vault>          # <vault> is copied; the original is never opened
#
# Prints CPU seconds per phase, which is what Activity Monitor's percentage
# is made of. Every number here was once ten times worse; the harnesses in
# Tests/HeftTests/WindowTypingCheck.swift hold the budgets.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
VAULT="${1:-}"
[[ -d "$VAULT" ]] || { echo "usage: Scripts/perf.sh <vault>" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/heft-perf.XXXXXX")"
trap 'pkill -f "$WORK" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

echo "== window harness (debug build)"
(cd "$ROOT" && HEFT_WINDOW_KEYSTROKES=120 HEFT_WINDOW_PUBLISHES=60 \
    swift test --filter WindowTypingCheck 2>&1 | grep -E "^WINDOW (held|publish:|idle)" | sed 's/^WINDOW /   /')

echo "== release app on a copy of $(basename "$VAULT")"
"$ROOT/Scripts/bundle.sh" release >/dev/null 2>&1
APP="$WORK/Heft.app"
cp -R "$ROOT/.build/XcodeDerivedData/Build/Products/Release/Heft.app" "$APP"
# A bundle identifier of its own, or a second instance waits behind the
# installed app; ad-hoc signed, since the identity is gone with the identifier.
plutil -replace CFBundleIdentifier -string "dev.stenglein.HeftPerf.$$" "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP" >/dev/null 2>&1
COPY="$WORK/vault"
cp -R "$VAULT" "$COPY"
find "$COPY" -name '*.icloud' -delete
# `-quit` rather than `| head -1`: under pipefail, head closing the pipe
# makes find's SIGPIPE a failure and the script stops here.
NOTE="$(find "$COPY" -name '*.md' -not -path '*/.*' -print -quit)"
REL="${NOTE#"$COPY/"}"

cpu() { ps -o time= -p "$1" | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
HEFT_DEFAULTS_SUITE="dev.stenglein.Heft.perf" nohup "$APP/Contents/MacOS/Heft" --vault "$COPY" --open "$REL" >/dev/null 2>&1 &
PID=$!
disown
sleep 15
echo "   startup and 15s idle: $(cpu $PID)s CPU"
phase() {  # label seconds command-per-tick
    local label=$1 seconds=$2 tick=$3 before after
    before=$(cpu $PID)
    for _ in $(seq 1 "$seconds"); do eval "$tick"; sleep 1; done
    sleep 2
    after=$(cpu $PID)
    printf '   %s: %ss CPU over %ss\n' "$label" "$(echo "$after - $before" | bc)" "$seconds"
}
phase "quiet" 20 ":"
phase "attribute churn, one per second" 20 "xattr -w dev.example.perf \$RANDOM \"$NOTE\""
phase "saves, one per second" 20 "touch -m \"$NOTE\"; xattr -w dev.example.perf \$RANDOM \"$NOTE\""
kill $PID >/dev/null 2>&1 || true
