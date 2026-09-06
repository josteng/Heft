# Gotchas, all of them hard-won

Each of these cost a debugging session. They are here rather than in
`CLAUDE.md` because that file is read on every request and this list is
needed on some of them; read it when touching AppKit, TextKit, printing,
preferences or the icon.

## Build and machine

- **Xcode is installed, but `xcode-select` points at the Command Line Tools.**
  `xcodebuild`, `actool` and `swift test` fail with "requires Xcode" until
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` is set, which
  `Scripts/bundle.sh` does for itself rather than changing the machine.
- **Every Heft.app on the machine claims one bundle identifier**, one per
  build product and per git worktree. LaunchServices registers each, and
  Spotlight's App Shortcut rows are drawn from whichever registration is
  current, so the Dock shows the new icon while "Add to Today's Note" shows an
  old one. `Scripts/install.sh` unregisters every other copy on every install.
  Same root cause as the icon-preview trap in `Resources/Heft.icon/README.md`.
- **`Scripts/smoke.sh` is the only thing that checks the app starts, and it
  must launch with no arguments.** `swift test` cannot launch a bundle, and an
  app that exits at once when started the way the Dock starts it is exactly
  what shipped once. A script that passed `--vault` never reached that branch.
- **`NSApp` is nil until an application instance exists.** A snapshot harness
  or a test crashes on it; `NSApplication.shared` makes one.
- **Checking the GUI without a screen.** `ImageRenderer` sees layout, text and
  custom drawing and is what the suite uses; it cannot draw AppKit-backed
  controls, which come out as placeholders. `cacheDisplay` on an
  `NSHostingView` is blank, `CGWindowListCreateImage` is gone, and
  `screencapture -l` needs Screen Recording and a window the server is
  compositing. So: `ImageRenderer` for custom drawing, `heft export` for the
  editing surface, structural tests for menus.

## Preferences and processes

- **Everything goes through `HeftDefaults.shared`, never `UserDefaults.standard`.**
  `Scripts/run.sh --sandbox` puts every preference in its own suite so a test
  launch cannot rewrite `vaultPath`, Open Recent or the rankings; one call site
  reaching for the standard domain is enough to lose that, and a test fails on
  any that does.
- **Without `--sandbox`, launching the GUI repoints Spotlight capture.**
  Opening a vault writes `dev.stenglein.Heft.vaultPath`, which is where the App
  Intents file things. Put it back afterwards:
  `defaults write dev.stenglein.Heft dev.stenglein.Heft.vaultPath -string <real vault>`.
- **The installed `heft` and the GUI share `UserDefaults`; `swift run Heft`
  does not.** The development build has no bundle identifier and lands in a
  domain named after the executable, which is what keeps a debug run from
  clobbering the installed app. It means anything on the CLI that reads app
  state, `files --by-use` for one, reads back empty under `swift run`.
- **`standardizedFileURL` rewrites `/private/tmp` to `/tmp`.** Anything
  building a per-vault defaults key must standardize first, or it writes to a
  key nothing reads.
- **A Cocoa app killed with `SIGTERM` never flushes its preferences.** A test
  reading what the app wrote has to quit it gracefully. `VaultSession`
  synchronises after recording the capture vault because a separate process
  reads it.
- **A persisted settings struct needs a hand-written `init(from:)`.** The
  synthesised `Codable` requires every field, so adding one setting makes every
  file written before it undecodable and silently resets the lot.
  `PDFExportOptions`, `Proposal` and `TypingSettings` all decode field by
  field with defaults.
- **`TypingSettings` stores the disabled substitution groups, not the enabled
  ones.** A group added later is absent from every older file, and an opt-out
  list reads that as on, which is the default.
- **A store loads its `UserDefaults` copy once, at init.** A test asking an
  instance built before a write passes against a mutation that merged two
  stores; read through a fresh instance.

## Vault and disk

- **Two `Date`s read from the same unchanged file can compare unequal.** A
  filesystem timestamp round-trips as a double, and two reads have differed
  below the precision either prints at. Compare modification dates with a
  tolerance, or as integer nanoseconds, never with `==`.
- **An iCloud vault is never quiet after a save.** `IgnoreSelf` hides Heft's
  own write, but the sync daemon then clones the file and rewrites its
  attributes from another process, and those events pass every path filter.
  Filtering by event flag would be guessing at the daemon; instead the index
  reuses the previous parse of any file whose size and date are unchanged,
  and the session publishes only when the tree or the answers differ.
- **The open note is polled once a second, and that tick stays at one
  second.** It is the only thing that catches a same-process write, which the
  watcher ignores on purpose. The cost was never the tick but reading the
  whole note on each one; a modification-date gate fixes that.
- **Autosave has two states where it writes nothing.** An unresolved conflict
  pauses it, and a failed write leaves the buffer dirty to retry. `DraftStore`
  mirrors the buffer to Application Support in both, on the save debounce, so
  the only copy of the work is never in memory alone; opening the note
  promotes a draft that outlived its process to a "(Heft Recovery)" note.
- **Obsidian templates use moment.js tokens, which collide with ICU.** moment
  `DD` is day-of-month where ICU `DD` is day-of-year; `WW` is the ISO week
  where ICU's is week-of-month; moment escapes with `[W]`. `MomentFormat`
  implements them directly. Never route these through `DateFormatter`.
- **Real-vault syntax that breaks naive parsers:** Obsidian writes `\|` for a
  literal pipe inside tables (`![[chart.png\|500]]`), and brackets can abut
  links (`\[[[Paper Name]]`), where the link is the innermost pair.

## SwiftUI and the window

- **Nothing on `AppModel` may be published per keystroke.** Every view in the
  window observes the model, so each publish redraws the sidebar, calendar,
  status bar and toolbar. `text` is a plain property; typing publishes only
  the counts, to `NoteStats`, which the status bar alone observes.
- **The split view's toolbars must live on a view that does not observe the
  model.** A toolbar builder runs whenever its view re-renders, and rebuilding
  the window's two toolbars leaks AppKit key-value dependencies every time, so
  a window grew slower and larger with each publish for as long as it stayed
  open. `WorkspaceSplit` declares them and observes `WindowChrome` alone;
  `ContentView` observes the model and keeps the sheets and alerts.
- **A toolbar item costs title bar whether or not it draws anything.** A
  zero-width, clipped, transparent item still pushed the sidebar toggle away
  from the traffic lights; the cost is the item's slot, which no hosting
  measurement can see. The only fix is not to contribute the item.
- **No `fixedSize(vertical: true)` on text in the sidebar.** The split view
  probes its sidebar at zero width for a minimum and the window takes it; a
  vertically fixed text answers with one character per line, and a fresh
  vault opened a window taller than the screen. Inside a popover or a sheet
  it is harmless.
- **`.tint()` does not reach `Color.accentColor`.** A view filling a shape
  with it keeps the system accent. Views painting their own highlight read
  `@Environment(\.appAccent)`; AppKit views read `AppearanceSettings.shared`.
- **A custom colour used by a fragment is resolved at style time**, in
  `LiveStyler`, and travels with the widget. Reading `AppearanceSettings.shared`
  inside `draw` bypasses the restyle-on-change fingerprint, so open windows
  keep the old colour.
- **A settings pane must not fill itself in on appear.** The window builds
  each pane off screen, where `onAppear` never fires. Read state in the body
  and write back through a `Binding`; `NSHostingController.sizingOptions`
  sizes the pane.
- **A `TextField`'s title is the row's label in a `Form`, not its
  placeholder.** The example goes in `prompt:`.
- **Calendar visibility belongs in the View menu, not the toolbar.** Leave the
  system `NavigationSplitView` sidebar toggle untouched.
- **Replacing the buffer is right for a new note and destructive for the same
  one.** `documentGenerationKeepsPosition` separates the two, and
  `LiveTextEditor.mapLocation` moves the caret by the change above it. Scroll
  is restored after the restyle, never before.

## TextKit and the editing surface

- **Writing an attribute discards TextKit's layout for that range, even when
  the value written is the one already there.** The whole reason restyling is
  scoped, and the trap before adding a "just set it again" write to
  `LiveStyler`.
- **`NSTextStorage.string` hands back its live backing store**, and `as
  NSString` can hand back the same mutable object. A snapshot kept that way
  becomes the current text on the next keystroke; `RestyleScope.Snapshot`
  copies.
- **`String.range(of:options:.regularExpression)` builds a fresh
  `NSRegularExpression` every call.** Document-wide sweeps go through the
  cached `regex(_:)`; anything per line is scanned by hand.
- **Protection in `LiveDecorator` rejects any candidate that intersects a
  protected range**, so block constructs must be collected before inline spans
  are protected, or `# The $h(t)$ model` loses its heading.
- **A styling pass must not scroll.** `keepCaretVisible` scrolls only when the
  caret has moved and is off screen; a pass that ran `scrollRangeToVisible`
  pulled the page to a caret the reader had left behind.
- **Lay the document out eagerly** (`ensureLayout`) after every restyle.
  TextKit estimates the height of regions it has not reached as ordinary
  lines, and this editor's fragments are nothing like ordinary, so a click
  resized the document under the pointer.
- **Never mutate text attributes while the mouse is tracking.** `super.mouseDown`
  runs its own loop and hit-tests against what it started with; restyles are
  queued and applied on mouse-up.
- **A line whose every character is collapsed markup has no height.** List
  and quote styles reserve an ordinary line's height unconditionally, sized to
  the revealed source, so a line moves neither when clicked into nor left.
- **Reserve widget height with `minimumLineHeight`, not by overriding
  `layoutFragmentFrame`.** The override did not survive contact with the
  layout manager.
- **`paragraphSpacingBefore` lands inside the layout fragment; `paragraphSpacing`
  does not.** A block drawn across paragraphs paints its bottom padding into
  the reserved gap and extends `renderingSurfaceBounds` to match.
- **`NSColor.cgColor` resolves against `NSAppearance.current`, which is not set
  during fragment drawing.** Wrap widget drawing in
  `performAsCurrentDrawingAppearance`, or gutter glyphs get the light palette.
- **A dynamic system colour resolves the moment `withAlphaComponent` is
  called**, in whatever appearance is current then. Use such colours as they
  come, or resolve through `RenderContext.resolved(_:)`.
- **`NSImage.draw` needs `respectFlipped: true`** in a text container, or
  images and formulae come out mirrored.
- **`locationForCharacter(at:)` under-reports the character immediately after a
  kerned one.** The error does not accumulate. Tag pills therefore never kern
  the character before one that matters: the gap in front of a tag opens
  before the preceding space, and the gap behind goes on the tag's last
  character rather than the following space, which would strand the caret.
- **macOS's own substitutions stay off** in `makeNSView`. They know nothing
  about markdown, and `SmartTypography` is their replacement; two engines on
  one keystroke is the failure mode.
- **A typing substitution fires only on a typed character.** `insertText` is
  also paste, drag and completion, so `applySubstitution` insists on a single
  character into a collapsed selection.
- **Smart Typography breaks Vim's quote objects unless they know about it.**
  `"` has become `“ ”` by the time `ci"` runs. `matchesTypographicQuotes`
  makes the objects match the curly forms, scanned open-then-close so the `’`
  in `it’s` pairs with nothing.

## Tables

- **`NSLayoutManager` does not retain its `NSTextStorage`.** Dropping the
  storage on the same line does not crash; it answers 0 for every position.
  `TableGrid.typeset` wraps the body in `withExtendedLifetime`.
- **`enumerateEnclosingRects` wants `{NSNotFound, 0}` for
  `withinSelectedGlyphRange`** when you want the boxes a range covers.
- **A subview of an `NSTextView` composites over the text**, so
  `TableCaretOverlay` paints the active cell's string again over its own fill.
- **The table `+` strips' space is reserved whether or not they are drawn**, or
  the note shifts on every click into and out of a table.
- **A cell's height is measured from what it looks like at rest**, never from
  the revealed cell, or a row changes height the instant it is clicked into.
  Column widths are measured the same way, for the same reason.
- **Showing a cell's markers makes its text longer.** `TableGrid.compute`
  spends the table's spare width on the active column so nothing outside the
  table moves.
- **A pipe typed inside a table is written `\|`**, as Obsidian does; a literal
  pipe ends the cell. Only inside a table.
- **A size written into a table cell is that cell asking its column for
  room**, honoured in the first pass; the table is still scaled to fit
  afterwards. Two cells asking the same get the same width.
- **`ImageDisplaySize` is the one rule for how big a picture is drawn**, for
  prose, quotes, bullets and cells alike. A size in the link wins, nothing is
  wider than its room, a cell fills its column and prose does not, and a
  hand-written size may use the whole text column where a pasted picture is
  capped so it does not read as a banner.
- **A picture inside a table cell is an `NSTextAttachment`.** Cells are drawn
  as attributed text, so the widget pass never runs there. Never in the
  revealed cell, whose characters must match the file's for the caret.

## Export and printing

- **Exporting at the editor's own size is too big for paper.** Use
  `NSPrintInfo.scalingFactor` with a proportionally wider view, so every
  relationship survives the shrink; restyling at a smaller font would not.
- **The export size is stored in points, not as a percentage** of the editor
  body, or it would change meaning the day the editor gained a font-size
  setting. `scale(forEditorBodySize:)` takes the editor's size as an argument.
- **Print pagination invents blank pages two ways.** `horizontalPagination`
  must be `.clip`, and a wholly empty trailing page is removed after the fact,
  decided by rasterising: half of what this editor draws is not in the text
  layer.
- **Collapsed markup is invisible on the page and still text in a PDF.**
  `PDFExport` replaces each collapsed character with a zero-width space, per
  character to keep attributes, keeping any character carrying a `.kern`, with
  the text view's delegate detached but not the layout manager's.
- **The editor's palette is chosen against a screen, not paper.** `PrintColours`
  keeps each hue and darkens it until it clears 3:1 against white; a second
  palette of settings was the obvious answer and the wrong one.
- **`SymbolConfiguration(paletteColors:)` flattens an SF Symbol** to a
  silhouette. `tintedSymbol` draws the template image and recolours it with
  `.sourceIn`, which keeps the detail.

## Known gaps

Markdown Heft does not read, found by auditing the decorator against CommonMark:

- **Reference links**, all four forms. Nothing renders, and the definition
  line sits in the note as a paragraph. The only construct needing two passes.
- **Indented code blocks.** Deferred on purpose: telling one from a list
  continuation line is ambiguous, and getting it wrong turns a nested list
  into code. Fenced blocks won.
- **Entity references** (`&amp;`) stay literal.
- **Hard line breaks** (two trailing spaces) are not recognised; only PDF
  export could show it.
- **Raw HTML** renders as nothing. A decision: rendering it needs a web view
  or a subset renderer, and a web renderer was rejected in `CLAUDE.md`.
- **`***x***` and multi-backtick code spans** use targeted patterns rather than
  the delimiter-run algorithm, so an unusual run can still be spanned wrongly.

And elsewhere:

- A transcluded note is styled but gets no widgets of its own, which is also
  the recursion guard. An embedded note is clipped at a fixed height and
  faded, because a layout fragment cannot scroll.
- Callout folding (`[!note]-`) hides the marker but does not fold.
- A table selection cannot span two cells; a selection made any other way
  drops the table to plain source. Column alignment is edited on the `---`
  row.
- Native tabbing is not customised; workspace windows are independent.
- Vim mode is experimental; `Docs/VimMode.md` tracks the command surface and
  where it differs from Vim.
- A drawn block on the last line of a file reserves its height twice. TextKit
  lays an extra empty fragment after the final newline inside the same
  paragraph, and paragraph attributes cannot separate the two. What is painted
  across the fragment is corrected; the gap under a final picture is not.
- Consecutive lines are always line breaks in the editor, whatever the vault's
  `strictLineBreaks` says: joining them would rewrite the buffer, and the
  buffer is the file. Only Presentation reads the setting.
- A group of proposals is applied in an order that works but is not atomic.
- Deferred: graph view, plugins.
