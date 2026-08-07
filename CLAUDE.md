# Heft

Native macOS markdown vault editor (Bear/Obsidian alternative). Pure Swift, plain
Swift Package Manager, no Xcode project, macOS 26 target. Sync is just pointing the
vault folder at iCloud Drive; there is no custom sync engine. Opens an existing
Obsidian vault unmodified, including its `.obsidian/` config.

```bash
swift build                                     # compile
Scripts/bundle.sh debug                         # assemble .build/Heft.app (dock icon + menu bar)
swift run Heft selftest                         # 87 assertions over the pure logic
swift run Heft stats <vault>                    # read-only index report; safe on the real vault
swift run Heft render <vault> <note> [caret]    # what the live surface would draw, headless
swift run Heft daily <vault> [YYYY-MM-DD]       # template expansion without the GUI
```

## Architecture

Two targets:

- `HeftCore`: pure logic. Never imports AppKit or SwiftUI. Parsing, the link index,
  the vault scanner, moment.js date formatting, live-mode decorations.
- `Heft`: the macOS shell. SwiftUI chrome around an `NSTextView`.

The only dependencies are Apple's swift-markdown (cmark-gfm) and SwiftMath (LaTeX).

### The editing surface

One Obsidian-style live surface, not source/split/preview. `LiveTextEditor` is a
single TextKit 2 buffer.

Markup is hidden by **collapsing** it: the characters stay in the text storage and
keep their place in every offset, but get a hairline font and a clear colour. The
buffer therefore always equals the file byte-for-byte, and selecting across hidden
markup copies real source. Nothing is ever rewritten to make it render.

Anything no text attribute can express (tables, LaTeX, image embeds, list bullets,
checkboxes, heading rules, thematic breaks) is collapsed and then painted by the
`NSTextLayoutFragment` subclass in `LiveWidgets.swift`. That subclassability is the
whole reason the editor is on TextKit 2 rather than 1.

Three files carry it:

- `LiveDecorator` (in HeftCore): what to style and where. Pure, testable.
- `LiveStyler`: turns decorations into attributes, and decides which widgets to draw.
- `LiveWidgets`: measures tables and draws every widget.

## Gotchas, all of them hard-won

- **No Xcode on this machine**, only Command Line Tools, so `swift test` cannot run:
  XCTest and swift-testing both ship with Xcode. Assertions live in
  `Sources/HeftCore/SelfCheck.swift` and run via `swift run Heft selftest`.
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
- **Real-vault syntax that breaks naive parsers:** Obsidian writes `\|` for a literal
  pipe inside tables (`![[chart.png\|500]]`), and brackets can abut links
  (`\[[[Paper Name]]`), where the link is the innermost pair.

## Known gaps

- Renaming a note does not update wikilinks pointing at the old name.
- Embed display widths are ignored: `![[img.png|700]]` renders at natural size,
  capped at 460pt.
- Deferred: Vim editing (the plan is embedding real Neovim via VimR's `NvimView`,
  not reimplementing modal editing), graph view, plugins, full-text search.

## Decisions already made

Kotlin Multiplatform was evaluated and rejected: the only portable slice is the
parser and link index, which is not worth the Gradle/SKIE boundary, and iOS is the
next target and is Swift anyway. See the `Apude` repo for what that boundary costs.

A web-based renderer was rejected outright. This is a native app.
