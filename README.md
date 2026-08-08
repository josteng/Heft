# Heft

A native macOS markdown vault editor. Opens an existing Obsidian vault as-is,
starts instantly, and syncs by living in an iCloud Drive folder rather than by
running a sync engine.

Pure Swift, plain SwiftPM, no Xcode project. macOS 26+.

## Build and run

```bash
swift build                 # compile
swift run Heft              # run (no bundle: no dock icon, no menu bar)
Scripts/bundle.sh debug     # assemble .build/Heft.app
open .build/Heft.app        # run as a real app
```

`swift run Heft` launches a bare executable. Use `Scripts/bundle.sh` and open the
`.app` for the real thing: dock icon, menu bar, window restoration.

### Command-line tools

```bash
swift run Heft selftest                    # assertions over the pure logic
swift run Heft stats  <vault>              # read-only index report
swift run Heft files  <vault>              # list every indexed file
swift run Heft daily  <vault> [YYYY-MM-DD] # create a daily note, print it
Scripts/bundle.sh debug && open .build/Heft.app --args --vault <path> --open <relative-path>
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

Only [swift-markdown](https://github.com/swiftlang/swift-markdown) (Apple,
cmark-gfm). Obsidian's non-CommonMark syntax is applied to *text nodes* of the
parsed AST, never by regex over raw source — by that point cmark has already
isolated code spans and fenced blocks, so a `[[link]]` written inside a code
sample is structurally out of reach.

## What works

- **File tree** with folders, images, PDFs and any other file (Obsidian lets a
  link point at anything, so everything is indexed).
- **Editor** — `NSTextView` with markdown syntax highlighting, debounced
  autosave, find bar.
- **Preview** — headings, lists, task lists, tables, code blocks with copy,
  block quotes, Obsidian callouts (`> [!warning]`), `==highlights==`, images.
- **Source / Split / Preview** modes.
- **Wikilinks** — `[[note]]`, `[[note|alias]]`, `[[note#heading]]`,
  `[[note#^block]]`, embeds `![[image.png|400]]`, note transclusion.
  Unresolved links render orange and create the note when clicked.
- **Backlinks** panel with the referencing line as context, plus unresolved
  outgoing links.
- **Calendar** with a dot per existing daily note; clicking a day creates it
  from the vault's configured template. If none exists, the calendar can set
  up editable daily-note and template paths, show supported placeholders with
  a live preview, and create an Obsidian-compatible configuration.
- **Quick open** (⌘O) with fuzzy matching.
- **Command palette** (⌘P) for daily-note settings and window controls such as
  the sidebar, calendar, backlinks, and colorful formatting.
- **Image paste and drop** into the vault's attachment folder, content-hashed so
  pasting the same screenshot twice does not create a second file.
- **Live reload** via FSEvents; external edits appear without clobbering unsaved
  local changes.
- **Multiple windows** over the same or different vaults, with an optional
  folder-focused view whose file tree, quick open, tags, recents, and search are
  scoped to that folder. Two windows can edit different notes; opening the same
  note brings its existing editor window forward.

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
| ⇧⌘N | New window |
| ⇧⌘T | Today's daily note |
| ⇧⌘O | Open vault in new window |
| ⇧⌘D | Toggle calendar |
| ⌥⌘B | Toggle backlinks |

## Not built yet

- **Vim mode.** The vault has `vimMode: true`, so this is wanted. The plan is to
  embed real Neovim via VimR's `NvimView` rather than reimplement modal editing.
- Graph view, plugins, themes, presentation mode.
- Live/inline preview (Typora-style); currently source, split or preview.
- Tag pane, search across note *contents* (quick open matches names and paths).

## Testing

There is no test target. XCTest and swift-testing both ship with Xcode, and this
project builds against the Command Line Tools, where `swift test` cannot run.
The equivalent assertions live in `Sources/HeftCore/SelfCheck.swift` and run via
`swift run Heft selftest` (47 checks). If a full Xcode is installed later, they
move to a real test target essentially unchanged.
