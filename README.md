# Heft

A native macOS editor for a Markdown vault, where **an agent proposes changes
and you review them** instead of silently rewriting your notes.

Pure Swift and TextKit 2 — no Electron, no web view, no sync engine of its own.
It indexes a 421-note vault in a tenth of a second, the notes stay an ordinary
folder you can point anything at rather than a database only this app can read,
and it opens an existing Obsidian vault unmodified, `.obsidian/` config included.

Built because Obsidian plus Claude Code is a genuinely good way to keep notes,
and Obsidian is the half I stopped enjoying: slow to start, a pile of plugins,
and barely a Mac app — you can't even drag a note out of it into a terminal.

```bash
git clone https://github.com/josteng/Heft.git
cd Heft
Scripts/install.sh
```

Requires macOS 26 and Xcode. That installs `Heft.app` into `/Applications` and
a `heft` command into `~/.local/bin`.

---

## What it does that others don't

The same vault, opened by something that behaves like a Mac program:

- **Drag a note out** into a terminal, Finder or Mail and you hand over the
  file itself — the path resolves and stays valid.
- **`heft .`** opens the current folder from a terminal, the way `code .` does.
- **Capture from Spotlight** — file a line into today's daily note or your
  inbox without leaving what you were doing.
- **Agents propose, you review.** An agent never writes your notes.

## An agent does not edit your notes

This is the part that doesn't exist elsewhere. A coding agent writing straight
into a vault is indistinguishable from your own typing an hour later, and there
is nothing left to review. So Heft doesn't let it.

An agent proposes the new body of a note:

```bash
heft propose . "Projects/Heft.md" --from /tmp/new.md \
    --summary "tighten the opening and add a Next section"
```

Restating a long note to change a paragraph is mostly transcription, so
`--replace` takes anchored edits instead. Each anchor must match exactly once;
Heft refuses one that matches twice rather than guessing, resolves them against
the current note, and stores the result as an ordinary full-body proposal.

```bash
echo '[{"old": "the exact text", "new": "its replacement"}]' \
    | heft propose . "Projects/Heft.md" --replace --summary "tighten the opening"
```

The proposal lands in `.heft/proposals/`, the vault watcher notices it, and a
banner appears above that note: the summary, the agent, `+n −m in k places`,
and **Review**. Each hunk gets its own Accept and Reject. Accepting one applies
it and rewrites the proposal to hold only what is still undecided, so a
half-reviewed proposal is a smaller proposal, never a lost one.

Three details that make it trustworthy rather than a demo:

- The diff is computed against the note **as it is now**, not against what the
  agent read. If it moved on since, the banner says so instead of silently
  rebasing.
- Accepted changes go through the editor's buffer, so they join the normal
  autosave and undo path rather than racing it.
- No daemon and no port. The verbs live on the same binary as the app.

**Teaching an agent to use it** is one command: `heft agent-setup <vault>`, or
**File ▸ Set Up Agent Access**. It writes the vault's `CLAUDE.md`, which is
where a session started in that folder looks. It is written between markers, so
running it again after an upgrade refreshes Heft's section and leaves anything
else in the file alone.

## The editing surface

One live surface — not source/split/preview. Markup is hidden by *collapsing*
it: the characters stay in the text storage and keep their place in every
offset, so the buffer always equals the file byte-for-byte and selecting across
hidden markup copies real source.

Markup comes back at two granularities, which is most of what makes it feel
right: block markup (heading hashes, list and quote markers, fences) reveals
when the caret is anywhere on its line, while inline spans (`**bold**`,
`$math$`, links) reveal only when the caret is inside that span.

- **Tables are edited in place.** A table stays a drawn grid while the caret is
  inside it; only the cell being typed into shows its Markdown. Tab walks
  cells, rows and columns can be added without dissolving the grid, and the
  `---` row is the deliberate way to edit one as plain text.
- **Lists and headings inside a quote** render as lists and headings, bullets,
  numerals, checkboxes and all, rather than as quoted prose.
- **Rendered in the editor**: headings, task lists, code blocks with syntax
  highlighting, block quotes, Obsidian callouts (`> [!warning]`),
  `==highlights==`, images, LaTeX, note transclusion, and YAML frontmatter as a
  properties card.
- **Nested lists shape their bullets** — filled disc, hollow ring, square —
  the way browsers have always shaded nesting. Return on an empty item steps
  *out* one level instead of ending the list.
- **Wikilinks** — `[[note]]`, `[[note|alias]]`, `[[note#heading]]`,
  `[[note#^block]]`, embeds `![[image.png|400]]`. Typing `[[` opens filename
  completion. Unresolved links render dimmed and create the note when clicked.
- **Typing substitutions** — `->` becomes `→`, `--` an en dash, quotes curl, as
  you type; backspace immediately after puts back what you typed. Eight groups,
  each switchable, plus your own `trigger → replacement` table with date/time
  placeholders and a `{{caret}}` token, so a trigger can expand into a whole
  code fence with the caret already inside it. Nothing fires inside code, math,
  frontmatter, links, tags or URLs.
- **Experimental Vim mode** (Settings ▸ Vim) — an original, Foundation-only
  modal engine. Not an embedded Neovim; see `Docs/VimMode.md`.

Restyling is scoped: a keystroke re-styles only the ranges that actually
changed, rather than re-attributing the whole note twice per character.

## Around the editor

- **File tree** with folders, images and PDFs, and inline creation. Renaming
  or moving a note *or a folder* repoints the path-qualified wikilinks that
  pointed into it, including from the notes that travelled with it, while bare
  `[[Chapter]]` links that still resolve are left alone.
- **Calendar** with a dot per existing daily note; clicking a day creates it
  from the vault's configured template.
- **Backlinks** panel with the referencing line as context.
- **Quick open** (⌘O), **content search** (⇧⌘F), **command palette** (⌘P).
- **Export as PDF** (⇧⌘E) of the *rendered* note — tables, callouts, bullets,
  checkboxes and typeset LaTeX, not the Markdown source. It prints the live
  surface itself rather than a second renderer, so the page matches the editor.
- **Multiple windows** over the same or different vaults, with an optional
  folder-focused view that scopes the tree, search and quick open without
  turning that folder into a second vault.
- **Open Recent** for vaults, so switching between a real vault and a test copy
  is one menu away. Vaults sharing a folder name are told apart by their parent.
- **Go to Path…** accepts a path in the form it is actually copied in — shell
  escaped (`Mobile\ Documents`), quoted, or a `file://` URL.

## The `heft` command

```bash
heft [path]                     # open a folder or note, like `code .`
heft agent-setup <vault>        # teach an agent in that vault to propose
heft find <vault> <query>       # full-text search
heft read <vault> <note>        # a note's source
heft files <vault>              # every note, vault-relative
heft proposals <vault>          # what is waiting for review
heft diff <vault> <id>          # what one of them would change
heft stats <vault>              # read-only index report
heft daily <vault> [YYYY-MM-DD] # create a daily note from the template
heft render <vault> <note>      # what the live surface would draw, headless
heft export <vault> <note> <out.pdf>   # the rendered note as a PDF
```

`stats` and `render` are read-only and safe against a real vault.

## Obsidian compatibility

Heft reads the vault's own `.obsidian/` config rather than guessing: daily-note
folder, filename format and template, attachment folder, and wikilink-vs-
Markdown link preference. `.obsidian`, `.trash`, `.makemd` and `.space` are
skipped.

Two syntax details that trip up naive parsers, both found in a real vault and
both handled:

- `![[chart.png\|500]]` — the pipe is escaped inside tables.
- `\[[[Paper Name]]` — a literal bracket abutting a link; the link is the
  innermost pair.

Obsidian templates use moment.js tokens, which collide with ICU: moment `DD` is
day-of-month where ICU `DD` is day-of-year. Heft implements the moment tokens
directly rather than routing them through `DateFormatter`.

Measured against a 379-note vault: scan 8 ms, full index 122 ms, 84.7% of
wikilinks resolved (the rest are genuinely missing notes, which Obsidian also
reports as unresolved).

## Not losing your notes

- Saves are atomic and compare the file against the exact source Heft loaded.
  If Obsidian, iCloud or another process changes the same note during editing,
  autosave pauses and asks which version to keep.
- An unresolved conflict blocks switching notes or vaults. If a window closes
  first, the local buffer is preserved as a timestamped `Heft Recovery` note.
- Deletion asks, and moves to the macOS Trash.
- A note has one writable editor; structural operations are blocked when they
  would rewrite a note open in another window.
- iCloud is synchronisation, not backup. Keep Time Machine or Git as well.

## Keyboard

| Shortcut | Action |
|---|---|
| ⌘O | Quick open |
| ⌘N | New note |
| ⌘P | Command palette |
| ⌘S | Save pending edits now |
| ⇧⌘F | Search the vault |
| ⇧⌘E | Export as PDF |
| ⇧⌘I | Capture to Inbox |
| ⇧⌘T | Today's daily note |
| ⇧⌘S | Toggle sidebar |
| ⇧⌘D | Toggle calendar |
| ⇧⌘O | Open vault in new window |
| ⌥⌘B | Toggle backlinks |

## Architecture

Three targets, and the split is deliberate:

- **`HeftCore`** — pure logic: parsing, the link index, the vault scanner,
  moment-style date tokens, live-mode decorations, diffing. Never imports
  AppKit or SwiftUI.
- **`HeftVimCore`** — a Foundation-only modal editing state machine. It emits
  transactions and selections; it never owns the document buffer.
- **`Heft`** — the macOS shell: SwiftUI, `NSTextView`, FSEvents.

Keeping the core UI-free makes it testable without a UI, and makes iOS a
question of writing a new shell rather than untangling logic from views.

Anything no text attribute can express — tables, LaTeX, image embeds,
transclusions, callout cards, list bullets, checkboxes — is collapsed and then
painted by an `NSTextLayoutFragment` subclass. That subclassability is the
whole reason the editor is on TextKit 2 rather than 1.

Dependencies: Apple's swift-markdown (cmark-gfm), SwiftMath (LaTeX), and
swift-markdown-engine for syntax-highlighting grammars.

## Development

```bash
Scripts/run.sh [vault] [note]   # debug build, launched without installing
Scripts/bundle.sh debug         # build the .app without launching
swift test                      # the full suite
```

`Scripts/run.sh` is the one to use while iterating — it launches from `.build`
and takes a vault path, so risky editor changes can be pointed at a disposable
copy. The GUI autosaves; never aim it at a vault you care about while testing.

The suite is 39 tests across 6 suites: pure checks over parsing, formatting,
links, paths and settings; a live-surface check that runs edit scripts through
both an incrementally styled buffer and a from-scratch one and compares every
attribute on every character; a disposable-vault integration check that
exercises autosave, save conflicts, recovery, renames and link repointing; and
the table and proposal suites. Temporary vaults are UUID-named and removed
afterwards, and the harness restores any user setting it touches.

When Neovim is installed, the Vim suite additionally runs command sequences and
a generated operator/motion/count matrix through `nvim --clean --headless` and
compares the resulting buffer against `HeftVimCore`. It is a development-only
oracle: no Neovim or GPL source is linked, copied, bundled, or required at
runtime, and the checks skip when `nvim` is absent.

## Not built yet

- Graph view, plugins, themes.
- Advanced Vim: Ex commands, system and clipboard registers, mappings, jump
  lists beyond the previous-position mark, full blockwise put.
- A table selection cannot span two cells; column alignment is changed by
  editing the `---` row.

## Licence

Not yet chosen.
