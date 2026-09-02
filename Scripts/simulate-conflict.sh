#!/bin/bash
# Stages a real save conflict against a disposable vault, so the merge sheet
# can be exercised by hand.
#
# Never point this at a vault you care about: it rewrites the note underneath
# the editor on purpose, which is the whole point.
#
# The buffer is only dirty for the 700ms between a keystroke and autosave, and
# a conflict needs the outside write to land inside that window. Rather than
# ask you to type and switch windows within it, the other writer edits every
# 250ms for a while, so any single keystroke is enough.
set -euo pipefail

vault=$(mktemp -d /tmp/heft-conflict-XXXXXX)
note="$vault/Conflict Demo.md"

cat > "$note" <<'NOTE'
# Conflict Demo

Both sides are about to change a different part of this note.

- alpha
- beta
- gamma
- delta
- epsilon
NOTE

echo "Vault:  $vault"
heft "$vault" "Conflict Demo.md" >/dev/null 2>&1 || open -a Heft "$vault"

cat <<'STEPS'

In Heft, change the "- beta" line: add a word to it.

The other writer starts editing the "- epsilon" line in 5 seconds and keeps
at it for 30. The note will visibly change under you until you type, which is
the point: one keystroke of yours is then enough to collide.

STEPS

sleep 5
echo "The other writer is editing…"

deadline=$((SECONDS + 30))
while [ $SECONDS -lt $deadline ]; do
    python3 - "$note" <<'PY'
import pathlib, re, sys, time
p = pathlib.Path(sys.argv[1])
stamp = time.strftime("%H:%M:%S")
text = re.sub(r"- epsilon.*", f"- epsilon, rewritten by the other writer at {stamp}",
              p.read_text())
p.write_text(text)
PY
    sleep 0.25
done

cat <<'STEPS'

The other writer has stopped.

Heft should have offered:
  Keep My Changes / Review Changes… / Use Disk Version / Cancel

Choose "Review Changes…". Two hunks: keep yours on the beta line, take
disk's on the epsilon line, then Save Merged. Both edits survive, which
neither all-or-nothing button can do.

STEPS
echo "Delete the sandbox when done:  rm -rf $vault"
