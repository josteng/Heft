# Heft

A native macOS markdown vault editor. Opens an existing Obsidian vault as-is,
starts instantly, and syncs by living in an iCloud Drive folder rather than by
running a sync engine.

Pure Swift with a native Xcode app target and a SwiftPM core package. macOS 26+.

## Build and run

```bash
Scripts/run.sh                         # build and run the last-used vault
Scripts/run.sh /path/to/vault          # build and run a specific vault
Scripts/bundle.sh debug                 # build without launching
Scripts/install.sh                     # release install into /Applications, then launch
Scripts/install.sh --install-only      # install without launching
open Heft.xcodeproj                     # or use Xcode and press Command-R
```

The scripts invoke the Xcode project, so the result includes the native app
bundle, icon, menu bar, window restoration, signing, and App Intent metadata.
Spotlight and Shortcuts can only execute an action from a validated app bundle.
For local development, add your Apple ID in Xcode and create an Apple Development
certificate; this is free and the build scripts pick it up automatically.

### Command-line tools

```bash
swift test                                 # core and disposable-vault checks
swift run Heft stats  <vault>              # read-only index report
swift run Heft files  <vault>              # list every indexed file
swift run Heft daily  <vault> [YYYY-MM-DD] # create a daily note, print it
Scripts/run.sh <vault> <relative-path>     # launch and open one note
```

`stats` is read-only and safe to point at a real vault. `daily` writes a note.

## Architecture

Two targets, and the split is deliberate:

- **`HeftCore`** — pure logic: markdown parsing, wikilink resolution, vault
  indexing, moment-style date tokens. Never imports AppKit or SwiftUI.
- **`Heft`** — the macOS shell: SwiftUI, `NSTextView`, FSEvents.

Keeping the core UI-free makes it testable without a UI, and makes a future iOS
target (or a Skip-transpiled Android one) a question of writing a new shell
rather than untangling logic from views.

Within the macOS shell, one `VaultSession` shares the scanner, index, settings,
recents, and FSEvents watcher for a vault. Every window has its own `AppModel`,
open note, navigation state, folder focus, and panel visibility. Folder focus is
a view boundary—not a second vault—so links still resolve against the full vault.

### Why not Kotlin Multiplatform

Considered, and rejected for this app specifically. Almost nothing here is
portable: file I/O, change watching, the text editor, and the entire UI are
platform-bound. The shareable slice is the parser and the link index, which is
not worth a Gradle/JDK/SKIE toolchain and a bridging boundary — the exact place
where build failures are hardest to debug. The next target is iOS, which is
Swift anyway. See `Apude` for the pattern if that ever changes.

### Dependencies

- [swift-markdown](https://github.com/swiftlang/swift-markdown) for CommonMark
  and GFM parsing.
- [SwiftMath](https://github.com/mgriebling/SwiftMath) for native LaTeX
  typesetting.
- `swift-markdown-engine` for its syntax-highlighting grammars.

Obsidian's non-CommonMark syntax is applied to *text nodes* of the parsed AST,
never by regex over raw source — by that point cmark has already isolated code
spans and fenced blocks, so a `[[link]]` written inside a code sample is
structurally out of reach.

## What works

- **File tree** with folders, images, PDFs and any other file (Obsidian lets a
  link point at anything, so everything is indexed), plus inline creation,
  rename, drag-and-drop moves, Recent and Tags views.
- **Live editor** — one continuous `NSTextView` with inline markdown styling,
  debounced autosave and a find bar. Headings, lists, task lists, tables, code
  blocks with copy, block quotes, Obsidian callouts (`> [!warning]`),
  `==highlights==`, images and math render directly in the editing surface.
- **Wikilinks** — `[[note]]`, `[[note|alias]]`, `[[note#heading]]`,
  `[[note#^block]]`, embeds `![[image.png|400]]`, note transclusion.
  Typing `[[` or `![[` opens filename completion and auto-pairs the closing
  brackets. Unresolved links render orange and create the note when clicked.
- **Backlinks** panel with the referencing line as context, plus unresolved
  outgoing links.
- **Calendar** with a dot per existing daily note; clicking a day creates it
  from the vault's configured template. If none exists, the calendar can set
  up editable daily-note and template paths, show supported placeholders with
  a live preview, and create an Obsidian-compatible configuration.
- **Quick open** (⌘O) with fuzzy matching.
- **Content search** (⇧⌘F) across the focused folder or the full vault.
- **Command palette** (⌘P) for daily-note settings and window controls such as
  the sidebar, calendar, backlinks, and colorful formatting.
- **Spotlight and Shortcuts actions** capture to `Inbox.md`, append a
  timestamped item to today's daily note, or open either note in the best
  matching Heft window. They currently use the most recently opened vault.
  Inbox capture is also available in-app with ⇧⌘I.
- **Image paste and drop** into the vault's attachment folder, content-hashed so
  pasting the same screenshot twice does not create a second file.
- **Live reload** via FSEvents; external edits appear without clobbering unsaved
  local changes.
- **Multiple windows** over the same or different vaults, with an optional
  folder-focused view whose file tree, quick open, tags, recents, and search are
  scoped to that folder. Two windows can edit different notes; opening the same
  note brings its existing editor window forward.
- **Link-safe file operations** — note and folder rename/move operations update
  path-qualified wikilinks that resolve to the affected files, including links
  in notes moved along with a folder.

## Production safety

- Saves are atomic and compare the current file with the exact source Heft
  originally loaded. If Obsidian, iCloud or another process changes the same
  note during local editing, autosave pauses and asks which version to keep.
- An unresolved conflict blocks switching notes or vaults. If a window closes
  before the conflict is resolved, Heft preserves the local buffer as a
  timestamped `Heft Recovery` markdown note.
- Deletion requires confirmation and moves items to the macOS Trash.
- A note can have only one writable Heft editor. Structural operations are
  blocked when they would rewrite a source note open in another window.
- iCloud provides synchronization, not versioned backup. Important vaults
  should still be covered by Time Machine, Git, or another backup system.

### Obsidian compatibility

Heft reads the vault's own `.obsidian/` config rather than guessing: daily-note
folder, filename format and template, attachment folder, and wikilink-vs-
markdown link preference. `.obsidian`, `.trash`, `.makemd` and `.space` are
skipped.

Two syntax details that trip up naive parsers, both found in a real vault and
both handled:

- `![[chart.png\|500]]` — the pipe is escaped inside tables.
- `\[[[Paper Name]]` — a literal bracket abutting a link; the link is the
  innermost pair.

Measured against a 379-note vault: scan 8 ms, full index 122 ms, 84.7% of
wikilinks resolved (the remainder are genuinely missing notes, which Obsidian
also reports as unresolved).

## Keyboard

| Shortcut | Action |
|---|---|
| ⌘O | Quick open |
| ⌘N | New note |
| ⌘S | Save pending edits now |
| ⇧⌘S | Toggle sidebar |
| ⇧⌘I | Capture to Inbox |
| ⇧⌘N | New window |
| ⇧⌘T | Today's daily note |
| ⇧⌘O | Open vault in new window |
| ⇧⌘D | Toggle calendar |
| ⌥⌘B | Toggle backlinks |

## Not built yet

- **Vim mode.** The vault has `vimMode: true`, so this is wanted. The plan is to
  embed real Neovim via VimR's `NvimView` rather than reimplement modal editing.
- Graph view, plugins and themes.

## Testing

The same Swift Testing suite is available from Xcode and SwiftPM:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Heft.xcodeproj -scheme Heft -destination 'platform=macOS' test
swift test
```

The test sources live under `Tests/HeftTests` and currently contain 194
lower-level checks. They cover parsing, formatting, links and settings, then
create a UUID-named temporary vault to exercise the mutable app shell:
autosave, save conflicts, close-time recovery, editor leases, note creation,
rename and move, and link-safe folder rename/move. The temporary vault is
removed after every run, and the integration harness preserves the user's
remembered vault setting. None of the test harness ships in `Heft.app`.
