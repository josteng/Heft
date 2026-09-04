# Gotchas, all of them hard-won

Each of these cost a debugging session. They are here rather than in
`CLAUDE.md` because that file is read on every request and this list is
needed on some of them; read it when touching AppKit, TextKit, printing,
preferences or the icon.

## Gotchas, all of them hard-won

- **Xcode 26.6 is installed, but `xcode-select` points at the Command Line Tools.**
  So `xcodebuild`, `actool` and friends fail with "requires Xcode" until
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` is set — which
  `Scripts/bundle.sh` does for itself rather than changing the machine globally.
  Tests live in `Tests/HeftTests` and therefore also need that `DEVELOPER_DIR`
  when the selected Command Line Tools and installed SDK do not match.
- **A dynamic system colour resolves the moment you call `withAlphaComponent`,**
  using whatever appearance is current then — not the one you are drawing in.
  `quaternarySystemFill.withAlphaComponent(0.6)` painted a near-white slab
  behind dark-mode blockquotes. Use such colours as they come, or resolve them
  explicitly through `RenderContext.resolved(_:)`.
- **`paragraphSpacingBefore` lands inside the layout fragment; `paragraphSpacing`
  does not.** So a block drawn across several paragraphs gets its top padding
  for free and has to paint its bottom padding into the reserved gap below,
  extending `renderingSurfaceBounds` to match.
- **Exporting at the editor's own size is too big for paper.** The type is
  chosen to be read on a display at arm's length; a book sets its body around
  10pt. The same note came out four pages where Obsidian took three. The fix
  is `NSPrintInfo.scalingFactor` plus a proportionally *wider* view, so every
  relationship survives the shrink — fonts, widgets, tables, line spacing —
  where restyling at a smaller font would not.
- **The export size is stored in points, not as a percentage.** It was a
  percentage of `Theme.bodySize` first, and that is the same number but the
  wrong idea: it reads as though it might depend on the display (it never
  did — a print point is 1/72 inch), and it would have silently changed
  meaning the day the editor gained a font-size setting.
  `scale(forEditorBodySize:)` takes the editor's size as an argument rather
  than reading the constant, so 12pt on paper stays 12pt whatever the editor
  does. A test measures the finished PDF to prove it.
- **Print pagination will invent blank pages, in two different ways.**
  `horizontalPagination = .automatic` splits a view a fraction of a point too
  wide into two page-columns, giving content/blank/content/blank; `.clip` is
  right, because the width is chosen deliberately and there is nothing to
  decide. And the vertical arithmetic can still land one page past the last
  line whatever the view's height, so the finished PDF is checked and a wholly
  empty trailing page removed. Emptiness is decided by **rasterising**: half of
  what this editor draws is painted by a layout fragment and is not in the text
  layer, so a page holding only a table reports no string.
- **The installed `heft` and the GUI share `UserDefaults`; `swift run Heft`
  does not.** Both installed entry points are the same binary in the same
  bundle, so both read and write the `dev.stenglein.Heft` domain — a ranking
  the CLI records is the ranking the switcher opens on. The development build
  has no bundle identifier and lands in a domain named after the executable
  (`Heft`), which is *desirable*: a debug run must not clobber the installed
  app's settings. It does mean anything on the CLI that reads app state —
  `files --by-use` does — reads back empty under `swift run` and has to be
  tested through the installed `heft`.
- **`standardizedFileURL` rewrites `/private/tmp` to `/tmp`.** Both the vault
  session and the CLI standardize before building a per-vault defaults key, so
  they agree; anything computing such a key by hand must standardize too, or it
  writes to a key nothing ever reads.
- **Every Heft.app on the machine claims one bundle identifier, and there are
  always several.** Build products under `.build`, and one per git worktree:
  eleven were registered at once here. LaunchServices registers each, so one
  identifier names a handful of bundles carrying whatever icon was current when
  each was built, and the App Shortcut rows in Spotlight are drawn from that
  registration rather than from the installed app. The result is the Dock and
  Finder showing the new icon while "Add to Today's Note" shows one from
  months ago — which reads as a broken build and is a stale registration. Two
  of the eleven carried a visibly different `Heft.icns` from the installed one.
  `Scripts/install.sh` now unregisters every other copy and re-registers the
  installed one, on every install, because rebuilding a worktree puts its copy
  back. Same root cause as the icon-preview trap in
  `Resources/Heft.icon/README.md`: IconServices caches per bundle identifier.
- **A persisted settings struct needs a hand-written `init(from:)`.** The
  synthesised `Codable` requires every field, so adding one setting made every
  file written before it undecodable — and the fallback is the defaults, so a
  remembered paper size, margin and text size would silently reset the first
  time anyone exported after an update. `PDFExportOptions` decodes each field
  with `decodeIfPresent` and a default. Same lesson as `TypingSettings`
  storing the *disabled* groups: a settings file is a format, and a format
  has to tolerate being older than the code reading it.
- **The editor's palette is chosen against a screen, not paper.** A yellow
  accent measures 1.51:1 against white, which is close to invisible.
  Mirroring every colour setting for export was the obvious answer and the
  wrong one — twelve more controls and two palettes to keep in step, for a
  problem that is measurable rather than a matter of taste. `PrintColours`
  keeps the hue and steps the brightness down until it clears 3:1, so that
  yellow prints as `rgb(178, 143, 0)` at 3.08:1: the same colour, darker. 3:1
  rather than 4.5:1 because these colours are emphasis, links, tags and
  headings, never body text, which stays near-black.
- **`SymbolConfiguration(paletteColors:)` flattens an SF Symbol.** It is the
  obvious way to tint one and it throws the detail away: every `.fill` symbol
  becomes a solid silhouette, so `pencil.circle.fill` and `info.circle.fill`
  are both a plain disc. It is wrong on screen too — at 14pt it just reads as
  a coloured blob, and it went unnoticed until an export made it large enough
  to look at. A *template* image keeps the detail and ignores the fill colour,
  so `tintedSymbol` combines the two: draw the mask, then recolour it with
  `.sourceIn`, which repaints the opaque pixels and leaves the negative space
  transparent so the callout's card shows through. Cached on symbol, size and
  tint, since two kinds differ only by colour.
- **Collapsed markup is invisible on the page and still text in a PDF.** So an
  export carried its own source, and a widget drawing over source that is
  still present put every table and formula in there twice. `PDFExport`
  replaces each collapsed character with a zero-width space of the same count
  — deleting is not available, because `hideWhole` reserves a widget's height
  on the very lines it collapsed, so those lines are its canvas. Three things
  make it safe and each broke the page first: detach the text view's delegate
  (its `textDidChange` schedules a restyle that re-decorates markdown-free
  text into plain prose) but *not* the layout manager's (that is what supplies
  the widgets); copy attributes per character, since replacing with a plain
  string applies the first character's to the whole run; and keep any
  character carrying a `.kern`, because an inline formula's gap is a kern and
  kerning is not applied to a zero-width space.
- **Checking the GUI without a screen: what works and what does not.** Four
  routes were tried against a real settings pane.
  `ImageRenderer` works, needs no permission and no window, and is what the
  suite uses — but it cannot draw AppKit-backed controls, so every Picker,
  Slider and Toggle comes out as a yellow placeholder. It sees layout, text
  and custom drawing, which is most of what is Heft's own.
  `cacheDisplay` / `bitmapImageRepForCachingDisplay` on an `NSHostingView`
  return blank: SwiftUI's content is in CALayers, not `draw(_:)`.
  `CGWindowListCreateImage` did work and was obsoleted in macOS 15.
  `screencapture -l<windowNumber>` needs Screen Recording *and* a window the
  window server is actually compositing — a window parked at -10000 is on no
  display and captures blank.
  So: `ImageRenderer` for custom drawing, `heft export` for the editing
  surface (which is how the TextKit-1 downgrade, the clipped lines and the
  blank pages were all caught), and structural tests for menus, which no
  rendering technique reaches.
- **`Scripts/smoke.sh` is the only thing that checks the app starts, and it
  must launch with *no arguments*.** `swift test` cannot launch an app bundle,
  so nothing in the suite notices an app that exits immediately — which is
  what shipped when `heft help` was made to answer an empty command line, the
  way the Dock, Finder and `open` all start a Mac app. The first version of
  this script passed `--vault` and passed happily with the bug reintroduced:
  arguments were not empty, so the broken branch was never reached. It seeds
  the sandbox suite with a vault and then starts the app with nothing on the
  command line at all.
- **Autosave has two states where it writes nothing, and both used to risk
  everything.** An unresolved save conflict pauses it deliberately, so the
  buffer accumulates edits with nothing writing them anywhere; and a failed
  write (full volume, permissions, an iCloud file that will not materialise)
  reports itself and leaves the buffer dirty to retry. In both, the only copy
  of the work was in memory, and the recovery copy was written when the
  *window closed* — which covers quitting and not losing power.
  `DraftStore` mirrors the buffer to one stable file per note in Application
  Support in both cases, refreshed on the same 700ms debounce as a save and
  deleted the moment the buffer reaches its note. Opening a note promotes any
  draft that outlived its process into the vault as an ordinary
  "(Heft Recovery)" note, so it is seen where notes are seen; a draft that
  matches the note is discarded instead of littering the vault.
- **A Cocoa app killed with `SIGTERM` never flushes its preferences.** So a
  test that reads what the app wrote has to quit it gracefully, or read
  something the app has flushed itself. `VaultSession` synchronises after
  recording the capture vault for the second reason: that value is read by a
  *separate process* (the App Intent, the `heft` command), and left in
  cfprefsd's cache it survives a clean quit but not a crash or a flat battery.
- **`Scripts/run.sh --sandbox` is how to launch the GUI for testing.** It puts
  every preference in its own suite (`--fresh` wipes it first), so a test
  launch cannot rewrite `vaultPath`, Open Recent or the rankings. Everything
  goes through `HeftDefaults.shared` rather than `UserDefaults.standard` for
  exactly this reason, and a test fails if any call site reaches for the
  latter: one setting escaping is enough to lose the property.
- **Without `--sandbox`, launching the GUI repoints Spotlight capture.**
  Opening a vault writes `dev.stenglein.Heft.vaultPath`, which is where
  `CaptureToInboxIntent` and `AddToTodaysNoteIntent` file things from outside
  the app. So a test launch silently aims "Add to Today's Note" at a temporary
  folder, and it stays aimed there after the folder is deleted. Put it back
  afterwards:
  `defaults write dev.stenglein.Heft dev.stenglein.Heft.vaultPath -string <real vault>`.
- **Obsidian templates use moment.js tokens, which collide with ICU.** moment `DD` is
  day-of-month but ICU `DD` is day-of-year; moment `WW` is the ISO week but ICU `WW`
  is week-of-month; moment escapes with `[W]` where ICU uses `'W'`. `MomentFormat`
  implements them directly. Never route these through `DateFormatter`.
- **Replacing the buffer is right for a new note and destructive for the same
  one.** `documentGeneration` used to mean both, so an edit arriving from
  iCloud, Obsidian or an agent scrolled the reader back to the top and dropped
  the caret. `documentGenerationKeepsPosition` separates them, and
  `LiveTextEditor.mapLocation` moves the caret by the size of the change above
  it. Scroll is restored *after* the restyle, never before: scrolling within an
  estimated height lands somewhere else.
- **A line whose every character is collapsed markup has no height.** `> `
  with nothing after it, or `- ` on its own, is entirely hairline font, and
  TextKit gives it a fragment barely over zero high. Pressing Return inside a
  quote made exactly that: the marker was inserted correctly and the new line
  drew as a slot a fraction of a line tall with nowhere to put the caret. Both
  the list and the quote paragraph styles therefore reserve an ordinary line's
  height unconditionally. It has to be unconditional rather than "only when the
  line is empty": the reservation is sized to the line the *revealed* source
  produces, so a line moves neither when it is clicked into nor when it is left.
- **Reserve widget height with `minimumLineHeight`, not by overriding
  `layoutFragmentFrame`.** Line height is ordinary paragraph geometry the layout
  manager must honour; the frame override did not survive contact with reality and
  the widgets rendered as hairlines.
- **Writing an attribute discards TextKit's layout for that range, even when
  the value written is the one already there.** Measured: on a 20KB note,
  `ensureLayout` costs 0.4ms when the layout is valid and 18ms after the styler
  has rewritten every attribute to an identical value. This is the whole reason
  restyling is scoped; it is also the trap to remember before adding a
  "just set it again, it's cheap" write to `LiveStyler`.
- **`NSTextStorage.string` hands back its live backing store, and bridging it
  through `as NSString` can hand back that same mutable object.** Keeping one
  as a snapshot of "what the document looked like last time" means it silently
  becomes the current text on the next keystroke; `RestyleScope.Snapshot`
  therefore copies. Symptom when it does not: the diff compares the document
  against itself, finds nothing changed, and the surface stops restyling
  entirely.
- **`NSLayoutManager` does not retain its `NSTextStorage`.** Laying a table
  cell out on the side to find a caret position, and dropping the storage on
  the same line (`let (manager, container, _) = typeset(cell)` — `_` keeps
  nothing), does not crash. It quietly answers 0 for every position, which
  reads as a caret pinned to the left edge of the cell and a selection with no
  rectangles at all. `TableGrid.typeset` takes a closure and wraps the body in
  `withExtendedLifetime` so the lifetime cannot be got wrong.
- **`enumerateEnclosingRects` wants `{NSNotFound, 0}` for
  `withinSelectedGlyphRange`** when you just want the boxes a range covers.
  Passing the same range twice asks for its intersection with a selection the
  layout manager does not have, and comes back empty every time.
- **A subview of an `NSTextView` composites over the text the view drew**, so a
  selection highlight filled in an overlay covers the glyphs it is meant to sit
  behind. `TableCaretOverlay` paints the active cell's string again on top of
  its own fill; the layout is identical, so the second pass lands exactly where
  the first did.
- **The space the table `+` strips occupy is reserved whether or not they are
  drawn.** They only appear while the caret is in the table, and reserving
  their height on demand would shove the rest of the note down by 17pt on every
  click into a table and back up on every click out.
- **A cell's height must be measured from what it looks like at rest**, never
  from what is drawn. The revealed cell holds different text — its markup, and
  no picture where a picture was — so measuring the drawn cell made a row
  change height the instant it was clicked into, moving the row out from under
  the pointer and the rest of the note with it. Measured at 148pt against 96pt
  for a table holding one picture. The widths were already measured this way,
  for the same reason.
- **A `TextField`'s title is the row's label in a `Form`, not its
  placeholder.** Passing the example as the title put `Inbox.md` in the margin
  with an empty box beside it, reading as a caption on the row above. Give the
  row a real label and the example goes in `prompt:`.
- **`NSApp` is an implicitly unwrapped optional and is nil until an
  application instance exists.** Anything reachable from outside the app — a
  snapshot harness, a test — crashes on it. `NSApplication.shared` makes one if
  there is none.
- **A settings pane must not fill itself in on appear.** `onAppear` never
  fires for a view that is never on screen, and the window builds each pane off
  screen, so a pane that copied its state in there came up as its own empty
  placeholder. Read the state in the body and write it back through a
  `Binding`. Heft measured pane heights by hand for a while, for the same
  reason and with the same symptom — a tab clipped halfway down a control —
  before `NSHostingController.sizingOptions` replaced the lot; see
  `SettingsWindowController`.
- **A pipe typed inside a table is written `\|`.** A literal pipe is the end
  of a cell, which is what markdown says and what Obsidian escapes for you.
  Typing one into `![[shot.png|500]]` split the row and left `]]` in the cell
  after it, taking the table's shape with it. Only inside a table: a backslash
  appearing in prose is nobody's idea of helpful.
- **A size written into a table cell is that cell asking its column for
  room.** Measuring a picture at a nominal width in the first pass threw the
  request away: two cells asking for `|500` were sized by the words above them,
  and the pictures then filled those narrow columns — a table of charts came
  out a third of the size the same table has in Obsidian. The table is still
  scaled to fit the text column afterwards, so asking for more than there is
  room for costs nothing, and two cells asking for the same thing get the same
  width. Obsidian gets that last part wrong, and it is worth not copying.
- **A size written into a link may use the whole text column.** The narrower
  460pt cap is for a picture dropped in at whatever size it was saved at, so
  it does not read as a banner; a number written by hand is not that, and
  clamping it looked like the picture being cut off at some arbitrary point.
- **`ImageDisplaySize` is the one rule for how big a picture is drawn**, and
  it is used by prose, quoted lines, bullets and table cells alike. A size in
  the link wins (`![[shot.png|500]]`, `|500x300`), nothing is ever wider than
  the room it has, and `fills` is what separates a cell from prose: Obsidian
  fits a picture to its column, while in prose a small picture stays small
  rather than being blown up to the width of the page. A table measures its
  columns from the words first and fits the pictures afterwards, or a picture
  would decide the width of the column it is then fitted to.
- **A picture inside a table cell is an `NSTextAttachment`.** Cells are drawn
  as attributed text rather than as layout fragments, so `drawsWidgets` is off
  for them and the widget pass that draws every other picture never runs; an
  embed came out as its filename in blue. An attachment goes through the
  measurement and drawing already there. Never in the *revealed* cell, which
  shows the file's own characters so that an offset into it means the same
  thing as an offset into the document — which is what the caret inside a
  table is placed from.
- **Showing a cell's markers makes its text longer**, so the row can wrap and
  grow, which moves everything below it in the document. Where the table is
  narrower than the text column, `TableGrid.compute` spends the spare width on
  the active column instead — no other column changes, so nothing outside the
  table moves. Column widths are always measured from the *rendered* text, so
  entering and leaving a cell never resizes a column on its own.
- **Two `Date`s read from the same unchanged file can compare unequal.** A
  filesystem timestamp round-trips as a binary double, and two reads have been
  seen to differ below the precision either one prints at. So `modified ==
  known` silently answered "changed" every time, which would have left the
  per-second file read in place while looking like it had been fixed. Compare
  modification dates with a tolerance, never with `==`.
- **The open note is polled once a second, and that tick must stay at one
  second.** It is the only thing that catches a *same-process* write, which
  the vault watcher ignores on purpose; backing the interval off while the app
  is in the background looks free and fails the integration check that covers
  it. What was expensive was never the tick, it was that the tick read the
  whole note off disk every time — on an iCloud vault, a full file read per
  second per window for as long as Heft was open. A modification-date gate in
  front of the read fixes that without touching the interval.
- **`String.range(of:options:.regularExpression)` builds a fresh
  `NSRegularExpression` every call.** Fine once, ruinous per line: quote-marker
  detection alone was most of the cost of decorating a long note. The
  document-wide sweeps go through the cached `regex(_:)`; anything per line or
  per match is scanned by hand.
- **A styling pass must not scroll.** `scrollRangeToVisible` ran on every
  pass, so any pass that did real work pulled the page to wherever the caret
  happened to be — and after a note opens the caret is at the very top. Open a
  note, scroll down, click: the first pass to do real work yanked the page back
  up, and nothing after it did, because by then the caret was where the reader
  was looking. `keepCaretVisible` scrolls only when the caret has actually
  moved *and* is off screen. Restyling an unchanged document takes an early
  exit and never reaches the scroll, so a test that restyles twice proves
  nothing: it has to reset the styling first.
- **Lay the document out eagerly** (`ensureLayout`) after every restyle. TextKit 2
  estimates the height of regions it has not reached, assuming ordinary lines. This
  editor's fragments are nothing like ordinary (a six-line table is one 148pt
  fragment plus five hairlines), so the estimate is far enough out that clicking
  makes the document resize, sliding text under the pointer and turning a click into
  a drag-selection.
- **Never mutate text attributes while the mouse is tracking.** `super.mouseDown`
  runs its own event loop until the button comes up and posts selection changes from
  inside it. Restyling there rewrites what the loop is hit-testing against, landing
  the caret on the wrong character. Restyles are queued and applied on mouse-up.
- **`NSColor.cgColor` resolves against `NSAppearance.current`, which is not set
  during fragment drawing.** Wrap widget drawing in
  `appearance.performAsCurrentDrawingAppearance`, or gutter glyphs get the light
  palette and vanish on a dark background.
- **`NSImage.draw` needs `respectFlipped: true`** in a text container, or images and
  formulae come out mirrored.
- **Protection in `LiveDecorator` rejects any candidate that *intersects* a protected
  range.** So block constructs must be collected before inline spans are protected,
  or `# The $h(t)$ model` loses its heading entirely instead of nesting.
- **A toolbar item costs title bar whether or not it draws anything.** The
  scope picker was contributed from the sidebar and kept across a collapse as
  a zero-width, zero-opacity, clipped item, on the theory that AppKit
  sometimes forgot to restore an item that came and went. With the sidebar
  hidden that pushed the sidebar toggle **80pt** from the traffic lights,
  where Notes and the rest put it around 36, and nothing on screen said why:
  the item is invisible, so all that shows is a toggle sitting too far right.
  Framing the content to zero does not help, and neither does emptying it —
  measured, and the obvious guess was wrong twice. `NSHostingController`
  reports zero for both, because the cost is the item's *slot* rather than its
  view, which no hosting measurement can see. The only fix is not to
  contribute the item, and the way to find that is to remove things from the
  real window and watch where the toggle lands (`screencapture -l<window>`,
  then read off the traffic lights as a scale: they are 14pt each).
- **Calendar visibility belongs in the View menu, not the window toolbar.** The
  `Show Calendar` command also has the `⇧⌘D` shortcut. Leave the system-provided
  `NavigationSplitView` sidebar toggle untouched.
- **macOS's own substitutions stay off** (`isAutomaticQuoteSubstitutionEnabled`
  and friends in `makeNSView`). They know nothing about markdown and would curl
  the quotes inside a code fence. `SmartTypography` is their replacement, and
  turning any of them back on would put two engines on the same keystroke.
- **`TypingSettings` stores the *disabled* substitution groups, not the
  enabled ones.** Storing what is on means a group added in a later version is
  absent from every settings file written before it existed, so it arrives
  switched off for exactly the people who have already visited the pane. An
  opt-out list records "everything, unless you said otherwise", which is the
  actual default. The one-time migration from the old format subtracts from
  `legacyKnownGroups` rather than from `allCases`, for the same reason.
- **Smart Typography breaks Vim's quote text objects, and the two features
  cannot both be naive about it.** By the time the caret is inside a quotation,
  `"` has become `“ ”`, so `ci"` searches for a character that is no longer in
  the file and silently does nothing — in a note written in this editor it never
  works at all. `VimOptions.matchesTypographicQuotes` (on by default, with a
  toggle in Settings → Vim) makes `i"`/`a"` match `“…”` and `«…»` and `i'`/`a'`
  match `‘…’`. The curly forms are scanned as open-then-close rather than as a
  run of one character, or the `’` in `it’s` would pair with the next apostrophe
  and take half the line with it.
- **A typing substitution must not fire on anything but a typed character.**
  `insertText` is also how paste, drag, attachment insertion and link
  completion put text in, so `applySubstitution` insists on a single character
  into a collapsed selection. A pasted `-->` is quoted material, not typing.
- **Real-vault syntax that breaks naive parsers:** Obsidian writes `\|` for a literal
  pipe inside tables (`![[chart.png\|500]]`), and brackets can abut links
  (`\[[[Paper Name]]`), where the link is the innermost pair.
- **`.tint()` does not reach `Color.accentColor`.** It steers stock controls,
  but a view filling a shape with `Color.accentColor` keeps resolving to the
  *system* accent, so the calendar dots and sidebar selection ignored the
  Appearance setting. Views that paint their own highlight read
  `@Environment(\.appAccent)`; `AppAccent` in `AppearanceSettings.swift` sets
  both, at each scene root. AppKit views (`WikiCompletionPanel`) are outside
  SwiftUI's environment entirely and read `AppearanceSettings.shared`.
- **A custom colour used by a fragment must be resolved at style time**, in
  `LiveStyler` where `RenderContext` is in scope, and travel with the widget
  (`headingAccent`, `checkbox`, tag pills all do). Reading
  `AppearanceSettings.shared` inside `draw` bypasses the restyle-on-change
  fingerprint in `LiveTextEditor`, so open windows keep the old colour.
- **`locationForCharacter(at:)` under-reports the character immediately after a
  kerned one** by a couple of points, an attribute-run boundary falling right
  there. The error does not accumulate: the character after *that* is exact.
  Tag pills kern for the room they overhang into, so they take care never to
  kern the character before one that matters — the gap in front of a tag opens
  before the preceding space (leaving the tag's own position exact to place the
  pill from), and the gap behind goes on the tag's last character rather than
  the space after it (leaving the caret where the next typed character lands;
  kerning that space stranded the caret short of the following letter, and the
  gap only appeared once something was typed, trailing whitespace having no
  width to widen).

## Known gaps

- A transcluded note is styled but gets no widgets of its own, so a table or
  picture inside an embed shows as source. This is also the recursion guard.
- An embedded note is clipped at 420pt and faded, because a layout fragment
  cannot scroll.
- Callout folding (`[!note]-`) parses and hides the marker but does not fold.
- A table selection cannot span two cells: dragging is confined to the cell it
  began in, and a selection made any other way (Select All, a find match)
  drops the table back to plain source rather than highlighting across pipes.
- Column alignment cannot be changed from the grid; edit the `---` row, which
  is what a caret on it shows the table as source for.
- Native tabbing is not customized; workspace windows are independent windows.
- Vim mode is experimental. Ex commands, system/clipboard registers, mappings,
  jump lists, and blockwise put are not implemented; `Docs/VimMode.md` tracks
  the full command surface and the handful of narrow places the prose objects
  differ from Vim.
- A drawn block on the **last line of a file** reserves its height twice, so a
  note ending in a picture or a formula gets a picture-sized gap under it.
  TextKit lays an extra, empty line fragment after the document's final
  newline *inside the same paragraph*, and it takes the paragraph's tall
  `minimumLineHeight` with it. Paragraph attributes cannot separate the two:
  giving that final newline its own style changes nothing, because the style
  is read from the paragraph's first character. Anything with a line after it
  is unaffected. In a PDF export the same fragment also draws its content at
  the wrong horizontal offset. What *is* fixed is anything painted across the
  fragment — `paintedBackgroundHeight` subtracts the empty fragment, so a
  quote, callout or code block last in a note is no longer a line taller than
  its contents. About a fifth of a line of that fragment's line spacing is
  still in there, which would take guessing at a paragraph style to remove.
- Consecutive lines are always line breaks in the editor, whatever the vault's
  `strictLineBreaks` says: joining two source lines into one rendered paragraph
  would mean rewriting the buffer, and the buffer is the file. Only
  Presentation reads the vault's setting. The Appearance override that used to
  sit over it was removed for the same reason.
- A group of proposals is applied in an order that works but is not atomic, and
  nothing rolls back if one member fails partway.
- Deferred: graph view, plugins.
