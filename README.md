# Heft

**Somewhere you actually want to write.**

A Mac app for Markdown notes: nice to write in, your files stay yours, and a
command line built for the coding agent you already use. Native Swift, no
Electron, no lock-in.

Apple Notes and Bear feel right, but your notes live in a database nothing else
can open. Obsidian keeps them as plain files you own, but it is a web app in a
window: drag a note out into a terminal and nothing happens. Heft is the feel
of the first with the files of the second.

The same split shows up the moment you point an agent at your notes. Obsidian
gives it plain Markdown and nothing else, so it falls back to grep. The apps
that hold your data answer it by selling you an assistant of their own. Heft
does neither: the `heft` command hands an agent a resolved index of the vault
to read from, and lets it propose changes for you to review hunk by hunk.

Bring whichever agent you already use. Heft has none of its own to sell you.

Point it at any folder of Markdown files, or at an existing Obsidian vault,
which opens unmodified: no import, no database, nothing to migrate out of. It
stays a normal vault, so those same notes still open and edit in Obsidian on
your phone. Quick open (⌘O), a command palette (⌘P) and recents are where you
would expect them.

Oh, and it has daily notes, capture from Spotlight, and a Vim mode (yes,
really).

```bash
git clone https://github.com/josteng/Heft.git
cd Heft
Scripts/install.sh
```

Requires macOS 26 and Xcode. That installs `Heft.app` into `/Applications` and
a `heft` command into `~/.local/bin`. There is no signed release yet, so on a
Mac that did not build it, Gatekeeper will refuse to open the app.

**New here? [`Docs/GettingStarted.md`](Docs/GettingStarted.md)** covers opening
a vault, the five things worth trying first, daily notes and capture.

---

## Why you might want it

- **It is nice to write in.** One live surface, not source/split/preview.
  Markup hides and comes back as the caret moves through it, and the file on
  disk is never rewritten to make that happen. Tables are edited as tables.
  Pictures land on the bullet you paste them onto. `->` becomes an arrow as
  you type.
- **It behaves like a Mac program.** `heft .` opens a folder the way `code .`
  does. Spotlight files a line into today's note or your inbox without you
  leaving what you were doing. Dragging a note into Mail attaches the file
  itself, because the path resolves and keeps resolving.
- **Agents read a resolved index, and write only by asking.** A text search
  finds the words in a link; it does not know what the link points at.
  `heft links` and `heft backlinks` do, aliases and headings and all, and they
  say which links point at nothing. `heft config` reports your daily-note
  folder and filename format, so what an agent writes matches the rest of your
  vault. And when it wants to change something, `heft propose` puts that in a
  banner above the note, to accept or reject hunk by hunk.
- **It is fast, and stays fast.** A vault of 424 notes and 58 attachments is
  scanned in 10 ms; the full link index takes 0.44 s off the main thread, so
  the tree is up immediately. Typing re-styles only what changed, so a long
  note does not get slower to type in. `heft stats` reports the same numbers
  for your own vault.

Also in there: daily notes and a calendar, PDF export of the rendered note
rather than the source, and capture from Spotlight.

Built because Obsidian plus Claude Code is a genuinely good way to keep notes,
and Obsidian is the half I stopped enjoying: slow to start, and never quite a
Mac app.

*Heft* is German for a school exercise book, which I always preferred writing
in to a notepad. In English it means weight and substance. Both were the point.

---

> [!NOTE]
> Everything below is reference. It is long because the app has a lot of
> surface (and because I used AI to draft the rest of this README), and nobody
> needs to read it end to end: skim whatever looks interesting, or point your
> agent at this file when you want to know whether Heft does some particular
> thing. Once it is installed, `heft help` is faster than scrolling.
>
> And yes, this app is heavily vibe-coded. But it is what I write my own notes
> in every day, and I intend to keep fixing and improving it, with whatever I
> find or you report.

## The editing surface

There is one surface. Markup is hidden by *collapsing* it: the characters stay
in the text storage and keep their place in every offset, so the buffer always
equals the file byte for byte, and selecting across hidden markup copies real
source. Nothing is ever rewritten to make the page look right.

Markup comes back at two granularities, which is most of what makes it feel
right. Block markup (heading hashes, list and quote markers, fences) reveals
when the caret is anywhere on its line; inline spans (`**bold**`, `$math$`,
links) reveal only when the caret is inside that span.

Emphasis styles from the opening delimiter, so `**bold` is already bold while
you are still typing it, and an unclosed `*` left in a note years ago cannot
italicise the rest of it.

- **Tables are edited in place.** A table stays a drawn grid while the caret is
  inside it; only the cell being typed into shows its Markdown. Tab walks the
  cells, rows and columns go in and out without dissolving the grid, and the
  `---` row is the deliberate way to edit one as plain text.
- **Lists and headings written inside a quote** render as lists and headings:
  bullets, numerals, checkboxes and all, rather than as quoted prose.
- **Pictures render wherever they land**: in prose, on a bullet, inside a quote
  or callout, in a table cell, at the size the link asks for
  (`![[shot.png|500]]`, or `|500x300`).
- **Rendered in the editor**: headings, task lists, syntax-highlighted code
  blocks, block quotes, Obsidian callouts (`> [!warning]`), `==highlights==`,
  images, LaTeX, note transclusion, and YAML frontmatter as a properties card.
- **Nested lists shape their bullets**, filled disc to hollow ring to square,
  the way browsers have always shaded nesting. Return on an empty item steps
  *out* one level instead of ending the list.
- **Wikilinks**: `[[note]]`, `[[note|alias]]`, `[[note#heading]]`,
  `[[note#^block]]`, embeds `![[image.png|400]]`. Typing `[[` opens filename
  completion. Unresolved links render dimmed and create the note when clicked.
- **Task states**: `[ ]` and `[x]`, plus the widespread conventions Obsidian
  also boxes: `[/]` in progress, `[-]` abandoned, `[>]` deferred, `[?]`
  uncertain. The character is drawn inside its box. Only `[x]` is struck
  through, because only `[x]` means finished.
- **Footnotes**: `[^1]` in the prose is drawn raised and small, the way a
  footnote marker has looked in print for four hundred years, and `[^1]:`
  opens a definition with a hanging indent.
- **Callout completion**: typing `> [!` lists the thirteen kinds with their
  icons and finds one by any of its Obsidian spellings, so `tldr` offers
  `abstract`. Accepting always writes the canonical name.
- **Typing substitutions**: `->` becomes an arrow, `--` an en dash, quotes
  curl, as you type; backspace immediately afterwards puts back what you
  typed. Eight groups, each switchable, plus your own trigger table with
  date and time placeholders and a `{{caret}}` token, so one trigger can
  expand into a whole code fence with the caret already inside it. Nothing
  fires inside code, math, frontmatter, links, tags or URLs.
- **Experimental Vim mode** (Settings ▸ Vim): an original, Foundation-only
  modal engine, not an embedded Neovim. See [`Docs/VimMode.md`](Docs/VimMode.md).

Typing stays quick on a long note because a keystroke re-styles only the
ranges that actually changed, rather than re-parsing and re-attributing the
whole document twice per character.

## Around the editor

- **File tree** with folders, images and PDFs, and inline creation. Renaming or
  moving a note *or a folder* repoints the path-qualified wikilinks that
  pointed into it, including from the notes that travelled with it, while bare
  `[[Chapter]]` links that still resolve are left exactly as they were written.
  The same work is `heft rename`, so a misspelled folder can be fixed without
  clicking through the tree.
- **Quick open** (⌘O), **content search** (⇧⌘F), **command palette** (⌘P).
  Quick open and the palette rank by how often you use something, discounted by
  how long ago, so with nothing typed they open on what you actually work in
  rather than on an alphabetical listing. Typing still puts the better match
  first; familiarity only breaks ties.
- **Calendar** with a dot per existing daily note; clicking a day creates it
  from the vault's configured template.
- **Backlinks** panel, with the referencing line as context.
- **Export as PDF** (⇧⌘E) of the *rendered* note: tables, callouts, bullets,
  checkboxes and typeset LaTeX, not the Markdown source. It prints the live
  surface itself rather than a second renderer, so the page matches the editor.
  Page size, orientation, margin, text size, colours and whether to add the
  note's name are chosen in the save panel and remembered. Colours default to
  *adjusted for paper*: your hues, darkened only where they would be too pale
  on white. Text size is set in **points on the page**, so it means the same
  thing on any display.
- **Attachments go where you say** (Settings ▸ Attachments), and the default
  names no folder at all: it looks at where the notes in that part of the vault
  already keep theirs. On a vault whose attachment folders were named three
  different ways, that found all three with nothing configured. Only a rule
  that names a single folder ever creates one.
- **Where new notes go** (Settings ▸ General): beside the note you have open,
  in the folder the sidebar has selected, or a folder you name, which is the
  one case Heft will create. A folder picked in the sidebar always wins: that
  is you pointing at a place, and a setting should not override a gesture. The
  same pane decides when a window opens its calendar.
- **What opens on startup** (Settings ▸ Startup, per vault): nothing, the note
  you were last on, today's daily note, one named note, or a path worked out
  from the date in the same tokens a daily-note template uses, so
  `Weeks/{{date:GGGG-[W]WW}}.md` gets you a weekly note. A note named on the
  command line still wins.
- **Multiple windows** over the same or different vaults, with an optional
  folder-focused view that scopes the tree, search and quick open without
  turning that folder into a second vault.
- **Open Recent** for vaults, so switching between a real vault and a test copy
  is one menu away. Vaults sharing a folder name are told apart by their parent.
- **Go to Path…** accepts a path in the form it is actually copied in: shell
  escaped (`Mobile\ Documents`), quoted, or a `file://` URL.

## An agent proposes, you review

Optional, and the part that does not exist elsewhere. Heft has no assistant of
its own and nothing to subscribe to: it is built for the agent you already use,
on notes that stay yours.

What it does add is a rule. A coding agent writing straight into a vault is
indistinguishable from your own typing an hour later, and there is nothing left
to review. So Heft does not let it.

An agent proposes the new body of a note:

```bash
heft propose . "Projects/Heft.md" --from /tmp/new.md \
    --summary "tighten the opening and add a Next section"
```

Restating a long note to change a paragraph is mostly transcription, so
`--replace` takes anchored edits instead. Each anchor must match exactly once;
Heft refuses one that matches twice rather than guessing.

```bash
echo '[{"old": "the exact text", "new": "its replacement"}]' \
    | heft propose . "Projects/Heft.md" --replace --summary "tighten the opening"
```

The proposal lands in `.heft/proposals/`, the vault watcher notices, and a
banner appears above that note: the summary, the agent, `+n −m in k places`,
and **Review**. Each hunk gets its own Accept and Reject. Accepting one applies
it and rewrites the proposal to hold only what is still undecided, so a
half-reviewed proposal is a smaller proposal, never a lost one.

Not every change is one note's text, so the sidebar keeps a **review centre**
listing everything waiting. A new note has no note to draw a banner above; a
delete or a move is a fact about the tree rather than about a page; and a change
across twelve notes is one change, not twelve, once the agent names it:

```bash
heft propose . "Old/Note.md" --move "New/Note.md" --summary "..."
heft propose . "Stale.md" --delete --summary "..."
heft propose . "A.md" --from /tmp/a.md --group "rename the concept" --summary "..."
```

A note whose change belongs to a group says so on its banner and points at the
centre. One banner per note, ever.

Four details that make it trustworthy rather than a demo:

- The diff is computed against the note **as it is now**, not against what the
  agent read. If it moved on since, the banner says so instead of silently
  rebasing.
- A whole-body proposal for a note that changed since the agent read it is
  **refused**, because it would replace text the agent never saw. `heft
  changes <vault> <note>` shows what moved, and it reads the note again.
- Accepted changes go through the editor's buffer, so they join the normal
  autosave and undo path rather than racing it.
- No daemon and no port. The verbs live on the same binary as the app.

**Teaching an agent to use it** is one command: `heft agent-setup <vault>`, or
File ▸ Set Up Agent Access. It writes the vault's `CLAUDE.md` and `AGENTS.md`,
which is where a session started in that folder looks, whichever agent you
brought. Both are written between markers, so running it again after an upgrade
refreshes Heft's section and leaves anything else in each file alone.

It also writes `.claude/settings.json`, which turns the main instruction from a
request into a rule: editing a file **inside the vault** is denied, and `heft`
is allowed without a prompt. Writing outside the vault is untouched, since
`heft propose --from /tmp/new.md` depends on it, and your own settings in that
file are merged with rather than replaced.

This is a guardrail, not a sandbox: an agent with a shell can still write a
file, and the point is that the easy path and the correct path are the same
path. Codex has no per-project permission file at all, so there the rule lives
in `AGENTS.md` and is followed rather than enforced.

[`Docs/AgentIntegration.md`](Docs/AgentIntegration.md) has the detail, including
what Codex's sandbox can and cannot be made to do.

## The `heft` command

Every verb is declared in one place, so **`heft help` is the list** and
`heft help --json` is the same thing for an agent, including which verbs are
read-only and therefore safe against a live vault. Most of them are. What
follows is the shape, not a second copy of it: this README learned that lesson
once already, when a hand-written verb list drifted and turned `heft export`
into `heft open export`.

```bash
heft [path]                    # open a folder or note, like `code .`
heft help [--json]             # every verb and flag
```

**Yours**: `daily`, `rename`, `export`, `agent-setup`.

**An agent's, all read-only**: `find`, `read`, `files` (`--by-use` is the order
Quick Open opens on), `outline`, `links`, `backlinks`, `tags`, `config`,
`attachment`, `changes`, `keys`. Plus the proposal verbs: `propose`,
`proposals`, `diff`, `drop`.

**Diagnostics**, about Heft's rendering rather than about your notes: `stats`,
`render`.

The query verbs are why an agent is better off with Heft than with a folder of
Markdown. Heft keeps a **resolved** link index, so `backlinks` and `links`
understand `[[Note|alias]]`, `[[Note#Heading]]` and the escaped pipe inside
`![[chart.png\|500]]`, none of which grep can resolve and all of which turn up
in real vaults. `config` reports the daily-note folder, filename format and
attachment folder, so a note an agent writes fits the vault's conventions
instead of guessing at them. And `keys` means "how do I do X in the app" has an
answer that is looked up rather than invented.

## Obsidian compatibility

Heft reads the vault's own `.obsidian/` config rather than guessing: daily-note
folder, filename format and template, attachment folder, and wikilink versus
Markdown link preference. `.obsidian`, `.trash`, `.makemd` and `.space` are
skipped.

One deliberate difference: with an attachment folder set to a subfolder
(`./assets`), Heft uses the nearest such folder *above* the note rather than
always making one beside it, so a project keeps one attachment folder instead
of growing one per subfolder. Nothing is created by that search.

Comments are hidden in both spellings: HTML's `<!-- -->` and Obsidian's own
`%%…%%`, inline or as a block.

Two syntax details that trip up naive parsers, both found in a real vault and
both handled:

- `![[chart.png\|500]]`, where the pipe is escaped inside a table. Heft reads
  that and writes it: typing a `|` inside a table escapes it for you, because
  an unescaped one ends the cell.
- `\[[[Paper Name]]`, a literal bracket abutting a link; the link is the
  innermost pair.

Obsidian templates use moment.js tokens, which collide with ICU: moment `DD` is
day-of-month where ICU `DD` is day-of-year. Heft implements the moment tokens
directly rather than routing them through `DateFormatter`.

[`Docs/TemplatesAndSlides.md`](Docs/TemplatesAndSlides.md) covers daily-note
templates, the full token table, the typing-substitution snippets, and how
`---` splits a note into slides.

## Not losing your notes

- Saves are atomic and compare the file against the exact source Heft loaded.
  If Obsidian, iCloud or another process changes the same note while you are
  editing, autosave pauses and asks which version to keep.
- While autosave cannot write, whether from an unresolved conflict, a full disk
  or a permissions change, the buffer is mirrored to a draft on the same 700 ms
  debounce. If Heft never gets to finish, opening that note again brings the
  draft back as a `(Heft Recovery)` note beside it. A crash or a flat battery
  costs the same fraction of a second it does at any other time.
- An unresolved conflict blocks switching notes or vaults. If a window closes
  first, the buffer is preserved as a timestamped recovery note.
- Deletion asks, and moves to the macOS Trash.
- A note has one writable editor; structural operations are blocked when they
  would rewrite a note open in another window.
- iCloud is synchronisation, not backup. Keep Time Machine or Git as well.

## Keyboard

The notable ones, which a test keeps in step with the app. `heft keys` prints
every one, grouped, and is also how an agent answers when you ask it how to do
something in the app.

| Shortcut | Action |
|---|---|
| ⌘N | New Note |
| ⇧⌘I | Capture to Inbox |
| ⇧⌘T | Today's Daily Note |
| ⇧⌘O | Open Vault in New Window |
| ⇧⌘E | Export as PDF |
| ⌘S | Save pending edits now |
| ⇧⌘F | Search the vault |
| ⌘O | Quick open |
| ⌘P | Command palette |
| ⇧⌘J | Show this note in the file tree |
| ⇧⌘S | Toggle sidebar |
| ⇧⌘D | Toggle calendar |
| ⌥⌘B | Toggle backlinks |

## Architecture

Three targets, and the split is deliberate:

- **`HeftCore`**: pure logic. Parsing, the link index, the vault scanner,
  moment-style date tokens, live-mode decorations, diffing, and the rules
  behind renaming and moving. Never imports AppKit or SwiftUI.
- **`HeftVimCore`**: a Foundation-only modal editing state machine. It emits
  transactions and selections; it never owns the document buffer.
- **`Heft`**: the macOS shell. SwiftUI, `NSTextView`, FSEvents.

About 40% of the code is in the two platform-free targets, and the boundary is
enforced rather than aspirational: neither imports AppKit or SwiftUI. That is
what lets the whole command line exist without a window, and what would make
an iOS version a question of writing new views rather than untangling logic
out of old ones.

Anything no text attribute can express, so tables, LaTeX, image embeds,
transclusions, callout cards, list bullets and checkboxes, is collapsed and
then painted by an `NSTextLayoutFragment` subclass. That subclassability is the
whole reason the editor is on TextKit 2 rather than 1.

Dependencies: Apple's swift-markdown (cmark-gfm), SwiftMath for LaTeX, and
swift-markdown-engine for its syntax-highlighting grammars.

## Development

```bash
swift test                      # the full suite
Scripts/smoke.sh                # does the app actually start?
Scripts/run.sh [vault] [note]   # debug build, launched without installing
Scripts/run.sh --sandbox [vault]   # ...with its preferences isolated
Scripts/bundle.sh debug         # build the .app without launching
```

`Scripts/run.sh` is the one to use while iterating: it builds and launches
and takes a vault path, so risky editor changes can be pointed at a disposable
copy. The GUI autosaves; never aim it at a vault you care about while testing.
`--sandbox` puts every preference in its own suite, so a test launch cannot
rewrite the Spotlight capture destination or Open Recent.

`Scripts/smoke.sh` exists because `swift test` cannot launch an app bundle, so
nothing in the suite notices an app that starts and immediately exits. One
shipped that way. It launches with no arguments, the way the Dock does.

The suite is 374 tests across 65 suites. Most are pure checks over parsing,
formatting, links, paths and settings; the ones worth knowing about are the
awkward ones:

- a live-surface check that runs edit scripts through both an incrementally
  styled buffer and a from-scratch one and compares every attribute on every
  character, plus a differential decoration check that fails if the fast path
  never ran;
- a typing-performance check that holds the per-keystroke budget;
- a disposable-vault integration check covering autosave, save conflicts,
  recovery, renames and link repointing;
- the agent verbs, driven as a subprocess against the built binary.

Temporary vaults are UUID-named and removed afterwards, and the harness
restores any user setting it touches.

Rendering is checked by *rendering*: `heft export` writes a note to PDF
headlessly, so a claim about how a table, callout or formula is drawn can be
looked at rather than inferred from a probe.

When Neovim is installed, the Vim suite additionally runs command sequences and
a generated operator/motion/count matrix through `nvim --clean --headless` and
compares the resulting buffer against `HeftVimCore`. It is a development-only
oracle: no Neovim or GPL source is linked, copied, bundled or required at
runtime, and the checks skip when `nvim` is absent.

## Not built yet

- **No signed release.** This is the one thing standing between Heft and anyone
  else running it: unsigned and un-notarised, Gatekeeper blocks it on any Mac
  that did not build it.
- **No iOS or iPadOS app.** Wanted, and not next: Obsidian opens the same vault
  on a phone today, which takes the urgency out of it without being what I
  actually want. The core is deliberately UI-free so a second shell is a matter
  of writing views, but the editing surface is the part that would need real
  rethinking on a touchscreen.
- Graph view and themes.
- Advanced Vim: Ex commands, system and clipboard registers, mappings, jump
  lists beyond the previous-position mark, full blockwise put.
- Rough edges in the editing surface: selecting across table cells, changing a
  column's alignment from the grid, widgets inside an embedded note, and
  callout folding. [`Docs/Gotchas.md`](Docs/Gotchas.md) lists them.

## Licence

Not yet chosen.
