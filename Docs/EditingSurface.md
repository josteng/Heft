# The editing surface

How the live surface decides what to draw, and what it costs to type into.
Read this before changing `LiveDecorator`, `RestyleScope`, `LiveStyler` or
`LiveWidgets`; every rule here was paid for once already.

## The editing surface

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

## Emphasis while it is still being typed

`**bold**` only styled once the closing pair arrived, so text stayed plain
until the span was finished. `.pendingEmphasis` styles from the *opening*
delimiter, the way Obsidian does.

Three things keep it from being a menace. It carries **no `syntax`**, so
nothing is collapsed: an unclosed `**` is literal text in the file, and hiding
it would misrepresent the buffer. It is the one style **applied** on the
caret's line rather than undone there — it rides `revealsWithItsLine`, which
is what stops an unclosed `*` left in a note years ago from italicising the
rest of its line forever. And a delimiter that a *closed* span already starts
on is skipped, or `**bold**` would open a second, unending span at the same
offset.

The scan is by hand rather than by regex because the pattern has to reach the
end of the line, and `matches(_:excluding:)` rejects any candidate that so
much as touches a protected range — which any line holding one code span
would.

## Blocks written inside a quote

The block matchers are anchored to the start of a line, so everything after a
`>` was quoted prose: `> - item` had no bullet and no indent, and `> ## H` was
body text. `QuotedBlock` on `QuoteLine` carries a list marker or heading level
found *after* the quote's own markers, and its markup joins the `>` in the
decoration's `syntax` so both collapse together.

It rides on the quote line rather than arriving as its own decoration because
the editor draws **one widget per line**, keyed by line start: a bullet and a
quote bar on the same line are one thing to draw, not two competing for the
same key. So `.quote` carries an optional `QuotedBlock` and hands it to the
same glyph drawing `.list` uses.

Two numbers are load-bearing. Indentation inside a quote is measured from
where the `>` markers stop, or every quoted list reads as one level deeper
than it is. And the indent handed to the *widget* must be the paragraph's real
indent, nested list included: the card is drawn back from the fragment's own
origin, so passing the quote's own edge instead leaves the fragment indented
and the card not, stepping the whole card right on every list line.

A callout's header line is excluded: `[!kind]` has already claimed what
follows the marker there.

## A picture pasted onto a bullet

Pasting an image writes `![[shot.png]]` at the caret, so in a daily log made
of bullets it always arrives as `- ![[shot.png]]`. The surface drew nothing
for that. A block construct was only drawn when it was **alone on its line**,
and the test for that asked whether everything before it was whitespace: a
list marker is not whitespace, so every pasted picture stayed as its filename
in blue. The markdown spelling `- ![](shot.png)` had the mirror-image bug,
drawing the picture and silently deleting the bullet.

`BlockLine.leadingMarkers` in HeftCore replaces that test and is pure. It
returns the length of the markers the construct follows, `0` when the
construct starts its own line, and nil when anything else shares the line. A
marker is the line's *structure* rather than its content, so a picture behind
one is no less a picture; but `- see ![[shot.png]]` is a sentence that happens
to end in an embed, and drawing that as a block would hide the sentence behind
the picture's reserved height. Which is why it returns a length rather than a
bool, and why "the markers must reach the construct" is load-bearing: only
that separates the two, and a mutation removing it passed until a case with
words *between* the marker and the embed was added.

Quote markers lead for the same reason and compose with a list's, so
`> ![[shot.png]]` and `> - ![[shot.png]]` are both pictures inside a quote. A
callout's `[!kind]` leads too, but only when the construct is the *whole*
title: `> [!tip] ![[shot.png]]` is a picture where the title would be, which
is what Obsidian draws, while `> [!tip] See ![[shot.png]]` is a title that
ends in an embed and must keep its words.

The editor draws **one widget per line**, keyed by line start, so the picture
takes the slot the marker's own `.list` or `.quote` widget was written into one
pass earlier. `BlockLead` is what that line still owed the reader — its indent,
its list glyph, and its quote bar or callout card — and rides on `.image` and
`.embed`, which paint the card first, then the glyph, then themselves. Each
part goes through the same drawing the displaced widget would have used, so a
quoted bullet holding a picture needs no third code path.

Two geometry facts, both of which broke the page first:

- `hideWhole` replaces the paragraph style, so it has to be given the list's
  indent or the line loses it. The indent is *read back* from the style the
  list wrote rather than recomputed from the marker's depth, so the two cannot
  disagree, and it has to be read before `hideWhole` runs.
- With that indent set, the layout fragment's **own origin already carries
  it** (`frame.minX` is 31 for a top-level item, 53 for a nested one, while
  the text's `typographicBounds.minX` stays 0). Offsetting the picture by the
  indent as well put it twice as far in. `heft render` reports both numbers
  for exactly this reason.

And the carried bullet is drawn *left* of that origin, so `renderingSurfaceBounds`
has to open the same 44pt gutter `.list` gets or the clip shaves it off
entirely — which is what happened: the picture moved, the bullet vanished.

## A bullet that wraps

A paragraph style applies to a paragraph, and a hard line break starts a new
one, so the indent a list marker gave its line stopped at that line's newline
and the rest of the item fell back to the left margin — a long bullet in a
narrow window rendered ragged. `.listContinuation` carries the item's depth to
those lines, with no glyph and no markup, since the bullet belongs to the first
line and the editor draws one widget per line.

The pass runs **last** in `blockDecorations` so it can see every other block
construct found on the same pass and decline the lines they own: `- item`
followed by `# Heading` is a heading. Fences, tables and frontmatter are already
in `protected` by then; `$$` is found afterwards and so needs naming. A blank
line ends the run.

## Tables are edited in place

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

## Restyling only what changed

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

## Typing must not wait for styling

A keystroke used to run a full decorate and style *before the character was
drawn*, because typing moves the caret and `textViewDidChangeSelection`
restyled synchronously. Measured: 21ms per character on a 50KB structured
note. macOS repeats a held key every `KeyRepeat × 15ms` — 30ms on a fast
setting — so a held key could not keep up, and each character arrived visibly
late.

An edit's own caret move now defers to the pass the edit already scheduled,
and `scheduleRestyle` waits longer than a repeat interval while edits are
arriving in a burst, so holding a key costs one restyle at the end rather than
one per character. The critical path fell to 3.1ms on that note.

Two things must stay synchronous, and both are load-bearing: a caret move that
is *only* a caret move (or arrow keys stutter), and anything reading the layout
it just invalidated — `TableSurface.apply` calls `restyleNow()` because the row
it added has to exist before the caret is placed in it.

Decorating is what made typing scale with the length of the note rather than
with the size of the edit: it reparsed the whole document on every keystroke.
`LiveDecorator.decorations(in:reusing:)` reuses the previous parse when the
edit provably could not have changed anything outside one blank-line-bounded
paragraph, reparsing that paragraph alone and shifting the rest. Measured 5–6×
cheaper on a note-shaped document; a 23KB note went from 7.0ms to 4.8ms per
keystroke, which is the difference between missing and making a frame on a
144Hz display.

Two guards are what make it safe, and both are proven by mutation against the
differential check: a paragraph containing anything that can open a construct
across blank lines (a fence, `---`, `$$`, a comment) is never reused, and
neither is one that any cached decoration *crosses the boundary of*.

That second guard was first written as a list of block styles and was wrong:
it named the block constructs and missed `$…$`, which pairs across blank lines
and so reaches into a paragraph holding no maths of its own — dropping the
maths decoration entirely. It asks about ranges now, not kinds, so a
construct added later cannot be forgotten from a list. The rest of the guards are defence in
depth — `paragraph(containing:)` rejecting blank lines already subsumes them
today, which the check confirms, but that is a property of `paragraph` rather
than of them.

The reparsed paragraph's decorations are appended as a group rather than left
in phase order. That is safe because decorations only ever overlap within a
paragraph, so their relative order — a heading applied before the bold inside
it — is preserved, and `RestyleScope` matches by location rather than by
position whenever the source changed.

Dirty ranges used to take their neighbouring lines — always. A line's styling
can depend on what is beside it (whether the next line continues the list,
whether this is the last line of a quote), so removing that outright breaks
list paragraph styles and widget layout, which the incremental check catches at
once. But applying it to *every* edit meant a character typed on one list line
restyled the line below it, rebuilding that line's bullet on every keystroke —
visible as the dot flickering.

So `normalize` now separates the two. An edit safely inside a line's text,
past its leading markers and containing no newline, is **local**: it dirties
its own line and no further. Anything that moves a line boundary, or touches
the run of markers a line begins with — where typing `[` really can turn a
bullet into a checkbox — is **structural** and still takes its neighbours.

Four separate paths appended to the dirty set, and classifying only the first
fixed almost nothing: a decoration that *overlaps* the edit reaches the set by
two more routes, and a reveal change by a fourth. Typing inside `**bold**`
went through the overlap paths, which is why the flicker survived the first
attempt. A decoration confined to one line is local wherever it arrives from.

Mutation-proven from both sides: making everything structural brings the
flicker back, making everything local goes stale. The single-line test on
decorations is the exception — the edit-level classification already routes
the dangerous cases, so removing it alone breaks nothing today. It is kept
because that is a property of the edit rules, not of it.

`Tests/HeftTests/IncrementalDecorationCheck.swift` is the oracle, and it has to
be: the incremental-styling check compares an incrementally styled buffer
against a from-scratch one, and if both used the reusing decorator a wrong
reuse would agree with itself. So it drives edit scripts — including deletions,
pasted fences and blank lines — through both decorators and compares the
decorations directly, and it fails if the fast path never ran.

`Tests/HeftTests/TypingPerformanceCheck.swift` guards the budget, and
`IncrementalStylingCheck` asserts a deferred pass was actually *scheduled*, so
deferring can never be mistaken for deciding no restyle was needed.

`Tests/HeftTests/IncrementalStylingCheck.swift` is what makes this maintainable:
it runs edit scripts through both an incrementally styled buffer and a
from-scratch one and compares every attribute on every character, through the
plain styler and through a real `HeftTextKit2View` + coordinator. Any change to
`LiveDecorator`, `LiveStyler` or `RestyleScope` should be run against it — it
caught two genuine bugs that render as "spacing is wrong after Return" and
"styling silently stops updating", neither of which any other test noticed.

## Typing substitutions

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

## Completion

`[[` and `> [!` are the same interaction and share one panel, so
`WikiCompletionItem` carries a title, detail and symbol rather than a
`NoteRef`, and the view remembers which `CompletionKind` is open: accepting a
row has to re-detect the same context the rows were built from.

`CalloutCompletionContext` is pure and shaped deliberately like
`WikiCompletionContext`. Two rules are load-bearing. It only fires on the line
that *opens* a quote block, because Obsidian reads `[!kind]` nowhere else and
completing on a body line would write something that renders as literal text.
And the caret has to be inside the name being typed, or every callout on the
caret's line would reopen the menu. Aliases are offered so `tldr` finds
`abstract`, but accepting always writes the canonical name: they exist so a
row can be found, not so one vault spells a callout four ways.
