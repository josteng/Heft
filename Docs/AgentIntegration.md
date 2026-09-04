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

**`heft help --json` is the list**, and the only one: it is generated from
`CommandLineSpec`, which is also what the installed `heft` wrapper is built
from. What follows is the part of it this document is about, and it will be a
subset — read the real list rather than trusting this one to have kept up.

```bash
heft find <vault> <query>              # full-text search, path:line: preview
heft read <vault> <note>               # a note's source, by name or by path
heft files <vault>                     # every note, vault-relative
    --by-use                           # ...in the order the reader opens them
    --by-agent                         # ...what an agent has already proposed to

heft propose <vault> <note.md> \       # the new body arrives on stdin
    --summary "what this is for" \
    --agent claude-code
heft propose <vault> <note.md> --from /tmp/new-body.md
heft propose <vault> <note.md> --replace   # anchored old/new pairs instead

heft propose <vault> <path> --delete    # propose removing it; reads no body
heft propose <vault> <path> --move <to> # propose moving it, repointing links
heft propose <vault> <note> --group "…" # join several into one change

heft changes <vault> <note>            # what moved since you last read it
heft proposals <vault>                 # what is waiting for review
heft diff <vault> <proposal-id>        # what one of them would change
heft drop <vault> <proposal-id>        # withdraw one
```

An id is a name, taken from the `--summary`: `tighten-the-opening`, and
`tighten-the-opening-2` for the next one like it. It was a bare UUID, which
nobody can read, say out loud or type, and which a review listing would have
shown as a column of hex. A proposal with no summary is named after its note.

Any prefix long enough to name one proposal will do. An empty string is not: it
is a prefix of every id, and `heft drop "$ID"` from a shell that expanded `$ID`
to nothing used to delete whichever proposal happened to be first, and report
success. A prefix matching two is refused rather than resolved to the first.

`heft rename <vault> <path> <new>` applies immediately and is the exception:
`--dry-run` says what it would do first, and is the right thing to show
somebody before doing it. `propose --move` is the same change asked for rather
than made, and is what to reach for when nobody is watching the terminal.

### Kinds, and changes that span notes

A proposal used to be one note's new body, and two things ran that out. A
proposal for a note that **does not exist** had no note to draw a banner above,
so it could not be reached from the app at all. And a change across twelve
notes was twelve unrelated proposals: accepting seven left the vault
half-changed with nothing recording that they belonged together.

So a proposal carries a **kind** — edit, create, delete, move — and an optional
**group**. A group's id is the slug of its summary, which is why an agent joins
one by repeating the same words rather than by passing an id around. A group of
one is not a group.

Deleting and moving read no body: there is nothing to accept part of, so they
are answered whole. Accepting a group applies its edits first and its moves and
deletes afterwards, because a move renames the file the edits were written
against. It is deliberately **not atomic**: refusing to apply eleven changes
because the twelfth is stale is worse than applying eleven, and what is left
unanswered stays in the list as a smaller change — the same rule a
part-reviewed proposal already followed.

Also read-only, and better than `grep` at every one of these:
`heft outline` for a note's headings, `heft links` and `heft backlinks` for the
resolved link graph, `heft tags`, and `heft config` for the vault's settings as
JSON.

`heft attachment <vault> <note> [filename]` answers the one question `config`
cannot. Where an attachment goes is a list of rules tried in order — what
`.obsidian/app.json` says, what the notes near this one already do, the nearest
folder of a given name, beside the note, a fixed folder — because a real vault
keeps files in several places under several names, and one configured folder
name would be wrong in most of them. This resolves them the way a paste in the
editor does and prints the folder, the rule that answered, and the link text to
write. It does not copy anything: moving files into a vault is the caller's,
and a verb that did it would be the thing proposals exist to prevent.

`propose` takes the **whole new body of the note**, not a patch. An agent
already has the finished text in hand, and a full body cannot fail to apply.
Heft works out the hunks itself. Where restating a long note to change a
paragraph is silly, `--replace` takes anchored `old`/`new` pairs and refuses an
anchor that matches more than once, so a bad anchor fails at the command rather
than at review time.

### Read it before you replace it

Replacing a note wholesale is only safe if the agent saw the note it is
replacing. `heft read` records what it handed over, and a whole-body `propose`
against a note that has changed since is **refused**: without that, a line
typed between the read and the proposal came back as an ordinary removal among
the agent's own hunks, with nothing to say the agent had never seen it.

`heft changes <vault> <note>` is the way out — it diffs the recorded read
against the file as it is now — and then the note is read again. `--replace` is
exempt, because its anchors are resolved against the current note and fail if
the text they named has moved, which is the stricter check.

The record is one snapshot per note, in Application Support rather than in the
vault: it is one machine's scratch state, and writing a file into an iCloud
vault on every read would sync for nobody's benefit. `HEFT_READ_LOG` moves it.

## What happens in the editor

A proposal is a JSON file under `<vault>/.heft/proposals/`. The vault watcher
already sees that folder, so the app notices within its usual coalescing
latency — no polling, no extra watcher.

- **The review centre** sits at the top of the sidebar and lists everything
  waiting: groups, single edits, and structural changes. It is the only place
  that can show a change with no note behind it.
- A banner still appears above the note a proposal is about: the summary, the
  agent, `+n −m in k places`, and Review / Discard. Seeing a diff where you are
  reading it is the part that already worked, and centralising it would have
  been a downgrade.
- **One banner per note, ever.** A change that belongs to a group says so on
  that banner and points at the centre, rather than a second banner stacking on
  the first. A delete or a move never appears in a banner at all: a bar over the
  page offering to delete the page is the wrong place to decide that.
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

## Teaching an agent to use it

`heft agent-setup <vault>` writes all of it, and File ▸ Set Up Agent Access is
the same thing from the app. Three files:

- `CLAUDE.md` and `AGENTS.md`, each carrying the same generated section between
  `<!-- heft:agent-guide -->` markers. Two files because Claude Code reads one
  and Codex and most of the rest read the other; the same section in both
  because it is generated, and generated text cannot drift. Everything outside
  the markers is yours, including each file's own preamble, which is why they
  are not copies of one another.
- `.claude/settings.json`, which is what turns "do not write notes directly"
  from a request into a rule. `Edit(**)`, `Write(**)` and `NotebookEdit(**)`
  are denied, and `Bash(heft:*)` is allowed without a prompt.

  The deny rules carry a path rather than being bare tool names on purpose:
  the workflow below writes a scratch file in `/tmp` and reads it back with
  `--from`, so denying the tools outright would make the setup that enforces
  the contract the setup that prevents following it. Your own entries in that
  file are merged with, never replaced, and a file that is not valid JSON is
  left alone rather than overwritten.

Codex has no per-project deny list of this kind, so for it the rule lives in
`AGENTS.md` and is followed rather than enforced. Running it read-only outside
a scratch directory achieves the same thing, if you want the belt as well.

The guide is stamped with a version, because it is copied *into* your vault and
frozen there. Every agent verb checks the stamp and says on stderr when the
vault is behind; the editor offers the same as a banner. Nothing rewrites these
files on its own.

### The guide, by hand

If you would rather not run `agent-setup`, this is the shape of what it writes.
Put it in the `CLAUDE.md` at the root of your vault:

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

If `propose` says the note has changed since you read it, run
`heft changes . "Path/To/Note.md"`, then read it again and rebuild on top.

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
