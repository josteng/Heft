# Heft

Native macOS markdown vault editor (Bear/Obsidian alternative). Pure Swift with a
native Xcode app target and a SwiftPM core package, targeting macOS 26. Sync is just
pointing the vault folder at iCloud Drive; there is no custom sync engine. Opens an
existing Obsidian vault unmodified, including its `.obsidian/` config.

```bash
Scripts/run.sh [vault] [note]                   # Xcode build, then launch
Scripts/bundle.sh debug                         # Xcode build without launching
Scripts/install.sh [--install-only]             # release install; launches by default
swift test                                      # core, live-surface, and disposable-vault checks
swift run Heft stats <vault>                    # read-only index report; safe on the real vault
swift run Heft render <vault> <note> [caret]    # what the live surface would draw, headless
swift run Heft daily <vault> [YYYY-MM-DD]       # template expansion without the GUI
```

## Architecture

Three targets:

- `HeftCore`: pure logic. Never imports AppKit or SwiftUI. Parsing, the link index,
  the vault scanner, moment.js date formatting, live-mode decorations.
- `HeftVimCore`: Foundation-only modal editing grammar. It returns edits and
  selections but never owns an editor buffer or imports AppKit.
- `Heft`: the macOS shell. SwiftUI chrome around an `NSTextView`.

The dependencies are Apple's swift-markdown (cmark-gfm), SwiftMath (LaTeX), and
swift-markdown-engine for its syntax-highlighting grammars.

Vault-wide scanning, indexing, settings, recents, and file watching live in a
shared `VaultSession`. Each window owns a separate `AppModel` for its open note,
navigation, folder focus, and visible panels. A focused folder scopes browsing
and search without turning that folder into another vault; multiple windows can
therefore show different parts of one vault without duplicate watchers or indexes.

### The editing surface

One Obsidian-style live surface, not source/split/preview. `LiveTextEditor` is a
single TextKit 2 buffer.

Markup is hidden by **collapsing** it: the characters stay in the text storage and
keep their place in every offset, but get a hairline font and a clear colour. The
buffer therefore always equals the file byte-for-byte, and selecting across hidden
markup copies real source. Nothing is ever rewritten to make it render.

Anything no text attribute can express (tables, LaTeX, image embeds, note
transclusions, frontmatter properties, quote and callout cards, list bullets,
checkboxes, heading rules, thematic breaks) is collapsed and then painted by the
`NSTextLayoutFragment` subclass in `LiveWidgets.swift`. That subclassability is the
whole reason the editor is on TextKit 2 rather than 1.

Markup comes back at two different granularities, which is most of what makes the
surface feel like Obsidian: block markup (heading hashes, list and quote markers,
fences, tables) reveals when the caret is anywhere on its line, while inline spans
(`**bold**`, `$math$`, links) reveal only when the caret is inside that span. The
policy lives in `Reveal` in HeftCore, so it is covered by the test suite.

Four files carry it:

- `LiveDecorator` (in HeftCore): what to style and where. Pure, testable.
- `RestyleScope` (in HeftCore): how much of that has to be redone. Pure, testable.
- `LiveStyler`: turns decorations into attributes, and decides which widgets to draw.
- `LiveWidgets`: measures tables and draws every widget.

### Tables are edited in place

A table is the one construct with a third reveal state. Everything else is
either rendered or shown as source; a table stays a drawn grid *while the caret
is in it*, and only the one cell being typed into shows its markdown. So
`Reveal.state(of:)` returns `RevealState` — `.hidden`, `.revealed`, or
`.cell(row:column:)` — and `RestyleScope` diffs that rather than a bare
"is it revealed", which is what makes moving between two cells a restyle.

`TableLayout` therefore carries where every cell came from: `cellRanges[r][c]`
is exactly the span of the file that `rawRows[r][c]` was read from (`rows`
unescapes `\|` for display, which changes the length, so the raw form is kept
alongside). `TableLayout.cursor(for:tableStart:)` turns a document selection
into a cell and an offset inside it, and returns nil for the delimiter row and
for a selection spanning cells — both of which fall back to plain source, so
the `---` row is the deliberate way to edit a table as text.

The caret inside a cell cannot be TextKit's. The grid bears no relation to the
lines its source occupies — a four-row table is one 150pt paragraph followed by
three hairlines — so TextKit puts the insertion point at the table's left edge
whichever cell is active. `TableCaretOverlay` (a subview, like the Vim block
cursor) draws it instead, positioned from the measured grid, with the native
insertion point switched to `.clear` while it is up. For the same reason clicks
inside a table are hit-tested against the grid in `mouseDown` and never reach
`super`, including drag-selection, which runs its own tracking loop confined to
the cell it started in.

`TableEditing` in HeftCore holds the structural edits — rows and columns in and
out, and the cell walk Tab, Shift-Tab, Return and the arrow keys perform. Pure,
like `MarkdownEditing`: a replacement range and where the selection ends up.
Row operations splice a single line and leave the rest of the source untouched;
column operations rewrite the table into canonical `| a | b |` form, because
hand-aligned padding no longer lines up once a column has been added anyway.

### Restyling only what changed

A keystroke used to re-decorate, re-attribute and re-lay out the whole note —
twice, because the edit and the caret move that came with it each asked for a
pass. That was ~34ms of main thread per character on a 20KB note and ~90ms on a
50KB one, before the character could be drawn.

The styled result is a pure function of (decorations, their reveal state, the
text they cover), so two passes differ exactly where that input differs.
`RestyleScope` diffs the previous pass's snapshot against the current one — a
common-prefix/suffix scan for the edit, then the previous decorations shifted by
it and matched against the new ones — and returns the ranges that really moved.
Everything else keeps its attributes, and with them its layout.

Two invariants make it safe, and both are load-bearing:

- The dirty ranges are **line-aligned**, and every decoration is either wholly
  inside one or wholly outside all of them (`normalize` grows the set to a
  fixpoint to guarantee it). So the styler resets those ranges to base
  attributes and rebuilds every decoration touching them, with nothing left
  half-styled at a boundary.
- The returned `LiveLayout` still describes the **whole** document, because
  TextKit can rebuild any fragment at any time and asks it for the widgets.
  Widgets outside the dirty ranges are carried over from the previous pass and
  shifted by the edit rather than re-measured.

`Tests/HeftTests/IncrementalStylingCheck.swift` is what makes this maintainable:
it runs edit scripts through both an incrementally styled buffer and a
from-scratch one and compares every attribute on every character, through the
plain styler and through a real `HeftTextKit2View` + coordinator. Any change to
`LiveDecorator`, `LiveStyler` or `RestyleScope` should be run against it — it
caught two genuine bugs that render as "spacing is wrong after Return" and
"styling silently stops updating", neither of which any other test noticed.

### Typing substitutions

`SmartTypography` in HeftCore is the Obsidian Smart Typography equivalent, plus
what that plugin has no answer for: `->` becomes `→` as you type, `--` an en
dash, `...` an ellipsis, quotes curl. It is a pure function of (document,
caret) run *after* a character lands, so a rule is just "this text now ends at
the caret" and no rule needs to know which key triggered it. Eight groups
(quotes, dashes, ellipsis, arrows, guillemets, comparisons, symbols, fractions)
switch on and off individually, all on by default, and the same engine runs the
user's own `trigger → replacement` table. `TypingSettings` is the app-wide
store and the Typing tab in Settings; `HeftTextKit2View.applySubstitution` is
the one call site, and its `deleteBackward` puts the typed text back when
backspace comes straight after a substitution.

Three things go beyond the plugin, and they are what make the table a snippet
expander rather than a second set of arrows:

- **Firing** is per rule. `.immediately` replaces as soon as the trigger is
  complete; `.afterWord` waits for a space, a punctuation mark, or Return, the
  way macOS text replacement does, and is the default for new rules because a
  word-shaped trigger that fires the instant it completes goes off inside
  longer words. The delimiter is replaced along with the trigger and re-emitted
  unchanged, which is what keeps the caret after it and lets one backspace undo
  both. Return reaches the engine through `insertNewline` with
  `endingWord: true`, where only `.afterWord` rules may fire — anything
  immediate already had its chance.
- **Placeholders** in a replacement go through `MomentFormat.expandTemplate`,
  and are documented by the same copyable `PlaceholderReference` list the
  daily-note sheet uses, since they are the same tokens and two lists would
  read as two systems. `SmartTypography.library` offers ready-made rules
  (today's daily-note link, a timed log entry, a code block) through an "Add
  from Library" menu rather than seeding them into a fresh install: they
  arrive as ordinary editable rows, and are the fastest way to see what the
  placeholders do. A test fires every one of them, because a mistyped
  placeholder is invisible in the pane and only shows up as literal `{{…}}` in
  a note.
  so `{{date:YYYY-MM-DD}}`, `{{time:HH:mm}}` and `{{title}}` mean the same
  thing they do in a daily-note template. `{{caret}}` is Heft's own: the engine
  strips it and reports its offset in `TextSubstitution.caretOffset`, so a
  snippet can leave the caret inside the fence it just wrote.
- **Chained rules.** `<->`, `<=>` and `-->` are matched as `←>`, `≤>` and `–>`,
  because by the time the third character arrives the first two have already
  been replaced. They match what is on screen, not what was typed, and must
  stay ordered before the two-character rules that would otherwise claim the
  same suffix.

Nothing fires inside code, math, frontmatter, wiki links, link destinations,
tags or URLs — `SmartTypography.allowsSubstitution` is a cheap own scan rather
than a `LiveDecorator` pass, because it runs on every keystroke and only has to
answer for one position.

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
- **Never point the GUI at the real vault while testing.** It autosaves. Use a copied
  sandbox vault, or the read-only `stats` and `render` commands.
- **Obsidian templates use moment.js tokens, which collide with ICU.** moment `DD` is
  day-of-month but ICU `DD` is day-of-year; moment `WW` is the ISO week but ICU `WW`
  is week-of-month; moment escapes with `[W]` where ICU uses `'W'`. `MomentFormat`
  implements them directly. Never route these through `DateFormatter`.
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
- **Showing a cell's markers makes its text longer**, so the row can wrap and
  grow, which moves everything below it in the document. Where the table is
  narrower than the text column, `TableGrid.compute` spends the spare width on
  the active column instead — no other column changes, so nothing outside the
  table moves. Column widths are always measured from the *rendered* text, so
  entering and leaving a cell never resizes a column on its own.
- **`String.range(of:options:.regularExpression)` builds a fresh
  `NSRegularExpression` every call.** Fine once, ruinous per line: quote-marker
  detection alone was most of the cost of decorating a long note. The
  document-wide sweeps go through the cached `regex(_:)`; anything per line or
  per match is scanned by hand.
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

- Embed display widths are ignored: `![[img.png|700]]` renders at natural size,
  capped at 460pt.
- A transcluded note is styled but gets no widgets of its own, so a table or
  picture inside an embed shows as source. This is also the recursion guard.
- An embedded note is clipped at 420pt and faded, because a layout fragment
  cannot scroll.
- Lists and headings inside a `>` block are not detected: the block matchers are
  anchored to the start of the line, so `> - item` is quoted text, not a list.
- Callout folding (`[!note]-`) parses and hides the marker but does not fold.
- A table selection cannot span two cells: dragging is confined to the cell it
  began in, and a selection made any other way (Select All, a find match)
  drops the table back to plain source rather than highlighting across pipes.
- Column alignment cannot be changed from the grid; edit the `---` row, which
  is what a caret on it shows the table as source for.
- Renaming a *folder* does not repoint path-shaped links into it; renaming a
  note does.
- Native tabbing is not customized; workspace windows are independent windows.
- Vim mode is experimental. Ex commands, named and system registers, mappings,
  macros, marks and jump lists, blockwise put, and `H M L` are not implemented;
  `Docs/VimMode.md` tracks the full command surface.
- Deferred: graph view, plugins.

## The icon

`Resources/Heft.icon` is a layered macOS 26 icon, compiled by `actool` during
bundling into `Assets.car` plus an `.icns` fallback. Its format is undocumented
and was reverse engineered; see `Resources/Heft.icon/README.md` before editing.

## Decisions already made

Kotlin Multiplatform was evaluated and rejected: the only portable slice is the
parser and link index, which is not worth the Gradle/SKIE boundary, and iOS is the
next target and is Swift anyway. See the `Apude` repo for what that boundary costs.

A web-based renderer was rejected outright. This is a native app.

Embedding real Neovim (via VimR's `NvimView`) was the earlier plan for Vim mode
and was reversed. An embedded editor wants to own its own buffer, which would
have forked the one thing this app is built around: TextKit 2 is the single
buffer, and with it autosave, live styling, undo, and input methods. It also
keeps a GPL program out of the shipping binary. `HeftVimCore` is instead an
original Foundation-only state machine that returns transactions for the
existing `NSTextView` to apply, and is portable to a future iPadOS shell.
Neovim still earns its keep as a *test* oracle: the suite drives
`nvim --clean --headless` as a separate process when it is installed, and every
disagreement it has found is preserved as a local regression that runs without
it. See `Docs/VimMode.md`, which also records the licensing boundary.
