# Agent integration

Heft is a CLI before it is a window: `Main.swift` dispatches headless verbs and
only calls `HeftApp.main()` when none of them match. The agent integration is
more verbs on that same entry point — no daemon, no port, no second binary.

The point of it is that **an agent does not edit your notes**. It proposes, and
Heft asks you. An agent writing straight into the vault is indistinguishable
from your own typing an hour later, and there is nothing left to review.

## The verbs

`heft` below is the built binary: `.build/debug/Heft`, or
`/Applications/Heft.app/Contents/MacOS/Heft` once installed.

```bash
heft find <vault> <query>              # full-text search, path:line: preview
heft read <vault> <note>               # a note's source, by name or by path
heft files <vault>                     # every note, vault-relative

heft propose <vault> <note.md> \       # the new body arrives on stdin
    --summary "what this is for" \
    --agent claude-code
heft propose <vault> <note.md> --from /tmp/new-body.md

heft proposals <vault>                 # what is waiting for review
heft diff <vault> <proposal-id>        # what one of them would change
heft drop <vault> <proposal-id>        # withdraw one
```

`propose` takes the **whole new body of the note**, not a patch. An agent
already has the finished text in hand, and a full body cannot fail to apply.
Heft works out the hunks itself.

## What happens in the editor

A proposal is a JSON file under `<vault>/.heft/proposals/`. The vault watcher
already sees that folder, so the app notices within its usual coalescing
latency — no polling, no extra watcher.

- A banner appears above the note the proposal is about: the summary, the agent,
  `+n −m in k places`, and Review / Discard.
- **Review** opens the hunks, each with its own Accept and Reject.
- Accepting one hunk applies it and rewrites the proposal to hold only what is
  still undecided. Rejecting one removes it from the proposal for good. So a
  half-reviewed proposal is a smaller proposal, never a lost one.
- ⌘K → "Review agent proposals" reaches them from any note.

Two details that matter in practice:

- The diff is computed against the note **as it is now**, not against what the
  agent read. You are deciding about your current note. If it moved on since,
  the banner says so rather than silently rebasing.
- An accepted change to the note you have open goes through the buffer, so it
  joins the normal autosave and undo path instead of racing it.

## Teaching Claude Code to use it

Put this in the `CLAUDE.md` at the root of your vault:

````markdown
# Vault

This is an Obsidian vault, edited in Heft. `heft` is
`/Applications/Heft.app/Contents/MacOS/Heft`.

## Never write notes directly

Do not use Write or Edit on `.md` files in this vault. Propose instead, and I
review in the editor:

```bash
heft read . "Note Name" > /tmp/note.md      # read it
# …produce the complete new body at /tmp/new.md…
heft propose . "Path/To/Note.md" \
    --from /tmp/new.md \
    --summary "one line on what this changes"
```

`heft find . <query>` searches the vault, `heft files .` lists every note.
`heft proposals .` and `heft diff . <id>` show what is already waiting.

Say what you proposed and stop. Do not wait for the review, and do not apply
your own proposal.
````

The last paragraph earns its place: without it an agent tends to propose a
change and then "helpfully" write the file as well.

## Demo, in one screen

```bash
Scripts/bundle.sh debug && open .build/Heft.app --args ~/Vaults/Demo
# then, in a terminal next to it:
claude "tighten the opening of Projects/Heft.md and add a Next section"
```

The banner appears while Claude is still talking.
