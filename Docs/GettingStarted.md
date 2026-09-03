# Getting started

Heft opens a folder of Markdown files. If you already have an Obsidian vault,
that is the folder — Heft reads its `.obsidian/` config and changes nothing.

## Install

```bash
git clone https://github.com/josteng/Heft.git
cd Heft
Scripts/install.sh
```

Needs **macOS 26** and **Xcode** (not just the Command Line Tools; the build
uses `xcodebuild` and `actool`). It puts `Heft.app` in `/Applications` and a
`heft` command in `~/.local/bin`.

If `heft` is not found afterwards, `~/.local/bin` is not on your `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

There is no signed release yet, so this is a build-it-yourself install. On a
Mac that did not build it, Gatekeeper will refuse to open the app.

## Open your vault

Any of these:

- **Launch the app.** With no vault yet it asks for a folder.
- **`heft ~/Notes`** — or `heft .` from inside the folder, the way `code .`
  works.
- **Drag a folder** onto the app.

Heft remembers the last vault and reopens it. `File ▸ Open Recent` switches
between vaults, which is how you keep a real vault and a scratch copy apart.

## Six things worth trying first

1. **Type some Markdown.** There is no preview pane and no source mode — the
   markup hides itself as you leave each construct and comes back when your
   caret returns to it. A heading's `#` returns when the caret is anywhere on
   its line; `**bold**` only when the caret is inside it.
2. **⌘O.** Quick open, ordered by what you actually open rather than
   alphabetically. **⌘P** is the command palette, ordered the same way.
3. **Make a table.** Command palette ▸ *Insert table*. It stays a drawn grid
   while you type in it; Tab walks the cells. The `---` row is the deliberate
   way to edit one as plain text.
4. **Paste a picture.** Onto a bullet, inside a quote, into a table cell — it
   is drawn where you put it. `![[shot.png|500]]` sets the width, `|500x300`
   both. Inside a table a pipe has to be escaped, and typing one there writes
   the `\|` for you.
5. **⇧⌘E.** Export the note as a PDF of what you see — tables, callouts,
   checkboxes, typeset LaTeX. Page size, margin and text size are in the save
   panel and are remembered.
6. **Set up agent review** (below). It is the reason Heft exists.

## Daily notes and capture

If your vault has Obsidian daily notes configured, Heft uses that
configuration. If not, `File ▸ Daily Note Settings…` sets it up and will
create the folders. **⇧⌘T** opens today's.

**⇧⌘I** files a line into `Inbox.md`. The same two actions are available from
Spotlight and Shortcuts — "Add to Today's Note" and "Capture to Inbox" — which
is the point: you can file a thought without leaving what you are doing, and
Heft stays where it was.

`Docs/TemplatesAndSlides.md` covers templates, the date tokens, typing
snippets, and how `---` turns a note into a slide deck.

## Two settings worth a look

**Settings ▸ Attachments** decides where a pasted or dropped file goes. The
default names no folder: it looks at where the notes in that part of the vault
already keep theirs, so a vault with `Thesis_Figures` in one corner and
`Covers` in another gets both right with nothing configured. The rules are
tried top to bottom and you can reorder them; only *one folder for the whole
vault* ever creates a folder.

**Settings ▸ Startup** is per vault: open nothing, the note you were last on,
today's daily note, one named note, or a path worked out from the date —
`Weeks/{{date:GGGG-[W]WW}}.md` for a weekly note, using the same tokens a
daily-note template uses. `heft open <note>` still wins over all of it.

## Working with Claude Code

The part that does not exist elsewhere. An agent editing your vault directly is
indistinguishable from your own typing an hour later, so Heft does not let it:
an agent **proposes**, and you accept or reject each hunk in the editor.

One command teaches an agent in that vault how:

```bash
heft agent-setup ~/Notes      # or File ▸ Set Up Agent Access
```

That writes the vault's `CLAUDE.md` between markers — your own notes in that
file are left alone. From then on a session started in the folder knows to run
`heft propose` instead of writing the file, and knows the read-only verbs for
asking the vault about itself:

```bash
heft help                     # every verb and flag; --json for the machine form
heft backlinks . "Note"       # what links here, with the line
heft links . "Note"           # what it links out to, resolved or not
heft outline . "Note"         # its headings
heft tags .                   # tags with counts
heft config .                 # daily-note folder, date format, attachments
heft files . --by-use         # ordered by what you actually open
```

Those matter because Heft keeps a **resolved** link index. It understands
`[[Note|alias]]`, `[[Note#Heading]]` and the escaped pipe in
`![[chart.png\|500]]` — none of which `grep` can resolve, and all of which turn
up in real vaults.

When a proposal arrives, a banner appears above that note with the summary and
`+n −m in k places`. **Review** opens it hunk by hunk. Accepting one applies it
and rewrites the proposal to hold only what is still undecided, so a
half-reviewed proposal is a smaller proposal rather than a lost one.

`Docs/AgentIntegration.md` has the full verb reference.

## If something goes wrong

- **The app will not open.** It is unsigned, so on a Mac that did not build it
  Gatekeeper blocks it. Right-click ▸ Open, once.
- **A note says its save is paused.** Something else changed the file —
  Obsidian, iCloud, an agent. Heft never overwrites in that case; it offers
  both versions and a hunk-by-hunk merge.
- **You lost power mid-edit.** Autosave writes 700ms after your last
  keystroke. While it *cannot* write — an unresolved conflict, a full disk —
  the buffer is mirrored to a draft on the same interval, and reopening that
  note brings it back as a `(Heft Recovery)` note beside it.
- **Your vault is on iCloud and a file will not open.** iCloud evicts contents
  it thinks you do not need; Heft shows those with a download badge and
  fetches on open.

## Where things are

| | |
|---|---|
| `Docs/GettingStarted.md` | this file |
| `Docs/AgentIntegration.md` | the agent verbs in full |
| `Docs/TemplatesAndSlides.md` | templates, date tokens, snippets, slides |
| `Docs/VimMode.md` | the experimental modal editing, and its limits |
| `CLAUDE.md` | architecture and every hard-won gotcha, for contributors |
