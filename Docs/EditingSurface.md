# The editing surface

How the live surface decides what to draw, and what it costs to type into.
Read this before changing `LiveDecorator`, `RestyleScope`, `LiveStyler` or
`LiveWidgets`; every rule here was paid for once already.

## One buffer, markup collapsed

One Obsidian-style live surface, not source/split/preview. `LiveTextEditor` is
a single TextKit 2 buffer.

Markup is hidden by **collapsing** it: the characters stay in the text storage
and keep their place in every offset, but get a hairline font and a clear
colour. The buffer therefore always equals the file byte for byte, and
selecting across hidden markup copies real source. Nothing is ever rewritten
to make it render.

Anything no text attribute can express (tables, LaTeX, image embeds, note
transclusions, frontmatter properties, quote and callout cards, list bullets,
checkboxes, heading rules, thematic breaks) is collapsed and then painted by
the `NSTextLayoutFragment` subclass in `LiveWidgets.swift`. That
subclassability is the reason the editor is on TextKit 2 rather than 1.

Markup comes back at two granularities: block markup (heading hashes, list and
quote markers, fences, tables) reveals when the caret is anywhere on its line,
inline spans (`**bold**`, `$math$`, links) only when the caret is inside them.
The policy is `Reveal` in HeftCore.

Four files carry it:

- `LiveDecorator` (HeftCore): what to style and where. Pure.
- `RestyleScope` (HeftCore): how much of that has to be redone. Pure.
- `LiveStyler`: turns decorations into attributes and decides which widgets
  to draw.
- `LiveWidgets`: measures tables and draws every widget.

## Emphasis while it is still being typed

`.pendingEmphasis` styles from the opening delimiter, the way Obsidian does,
rather than waiting for the closing pair. Four things keep it in check: it
carries no `syntax`, so an unclosed `**` stays literal text rather than being
hidden; it is applied on the caret's line rather than undone there, which is
what stops an unclosed `*` left in a note years ago from italicising the rest
of its line; both delimiter runs of a closed span are skipped, or `**bold**`
would open a second, unending span at its closer; and a run CommonMark would
not let open is passed over: one followed by punctuation with a letter before
it, or a single `*` or `_` right after a word character, the last stricter
than the spec but the rule the closed-italic pattern already applies. It is
scanned by hand because the pattern has to reach the end of the line, and
`matches(_:excluding:)` rejects any candidate touching a protected range.

## Blocks written inside a quote

The block matchers are anchored to the start of a line, so everything after a
`>` used to be quoted prose. `QuotedBlock` on `QuoteLine` carries a list
marker or heading level found after the quote's own markers, and its markup
joins the `>` in the decoration's `syntax`. It rides on the quote line rather
than arriving as its own decoration because the editor draws **one widget per
line**, keyed by line start.

Two measurements are load-bearing: indentation inside a quote is measured from
where the `>` markers stop, and the indent handed to the widget is the
paragraph's real indent, nested list included, because the card is drawn back
from the fragment's own origin. A callout's header line is excluded, since
`[!kind]` has already claimed what follows the marker.

## A picture pasted onto a bullet

A block construct used to be drawn only when alone on its line, so a picture
pasted onto a bullet stayed as its filename. `BlockLine.leadingMarkers` in
HeftCore replaces that test: it returns the length of the markers the
construct follows, `0` when it starts its own line, and nil when anything
else shares the line. A marker is the line's structure, so a picture behind
one is no less a picture; `- see ![[shot.png]]` is a sentence ending in an
embed and must keep its words. The markers must reach the construct, which is
the only thing that separates the two.

Quote markers lead for the same reason and compose with a list's. A callout's
`[!kind]` leads only when the construct is the whole title.

Because the editor draws one widget per line, the picture takes the slot the
marker's own `.list` or `.quote` widget was written into. `BlockLead` is what
that line still owes the reader, its indent, list glyph and quote bar or
callout card, and rides on `.image` and `.embed`, which paint the card, then
the glyph, then themselves through the same drawing the displaced widget
would have used.

Two geometry facts: `hideWhole` replaces the paragraph style, so it is given
the list's indent read back from the style the list wrote, before it runs;
and with that indent set the fragment's own origin already carries it, so the
picture must not be offset by the indent as well. The carried bullet is drawn
left of that origin, so `renderingSurfaceBounds` opens the same gutter `.list`
gets, or the clip shaves it off. `heft render` reports both numbers.

## A bullet that wraps

A paragraph style applies to a paragraph, and a hard line break starts a new
one, so a list's indent stopped at its line's newline. `.listContinuation`
carries the item's depth to the following lines, with no glyph and no markup.
It runs last in `blockDecorations` so it can decline lines other block
constructs own: `- item` followed by `# Heading` is a heading. A blank line
ends the run.

## Tables are edited in place

A table is the one construct with a third reveal state: a drawn grid while the
caret is in it, with only the cell being typed into showing its markdown. So
`Reveal.state(of:)` returns `.hidden`, `.revealed` or `.cell(row:column:)`,
and `RestyleScope` diffs that, which is what makes moving between two cells a
restyle.

`TableLayout` carries where every cell came from: `cellRanges[r][c]` is the
span of the file `rawRows[r][c]` was read from (`rows` unescapes `\|` for
display, which changes the length). `TableLayout.cursor(for:tableStart:)`
turns a document selection into a cell and an offset, and returns nil for the
delimiter row and for a selection spanning cells; both fall back to plain
source, so the `---` row is the deliberate way to edit a table as text.

The caret inside a cell cannot be TextKit's: the grid bears no relation to the
lines its source occupies. `TableCaretOverlay` draws it from the measured
grid, with the native insertion point switched to `.clear`. Clicks inside a
table are hit-tested against the grid in `mouseDown` and never reach `super`,
including drag-selection, which is confined to the cell it started in.

`TableEditing` in HeftCore holds the structural edits and the cell walk Tab,
Shift-Tab, Return and the arrows perform. Row operations splice a single
line; column operations rewrite the table into canonical `| a | b |` form,
because hand-aligned padding no longer lines up once a column has been added.

## Restyling only what changed

The styled result is a pure function of (decorations, their reveal state, the
text they cover), so two passes differ exactly where that input differs.
`RestyleScope` diffs the previous pass's snapshot against the current one and
returns the ranges that moved; everything else keeps its attributes, and with
them its layout, which is the whole saving.

Two invariants make it safe. The dirty ranges are line-aligned, and every
decoration is wholly inside one or wholly outside all of them (`normalize`
grows the set to a fixpoint), so nothing is left half-styled at a boundary.
And the returned `LiveLayout` still describes the whole document, because
TextKit can rebuild any fragment at any time; widgets outside the dirty ranges
are carried over and shifted rather than re-measured.

Dirty ranges take their neighbouring lines only for **structural** edits. A
line's styling can depend on what is beside it, so removing that outright
breaks list styles and widget layout; but applying it to every edit rebuilt
the bullet below on every keystroke, visible as flicker. An edit safely inside
a line's text, past its leading markers and containing no newline, is local
and dirties its own line only. Anything moving a line boundary or touching the
leading markers, where `[` really can turn a bullet into a checkbox, is
structural. Four paths append to the dirty set, and a decoration confined to
one line is local whichever it arrives by.

`IncrementalStylingCheck` runs edit scripts through an incrementally styled
buffer and a from-scratch one and compares every attribute; run any change to
`LiveDecorator`, `LiveStyler` or `RestyleScope` against it.

## Typing must not wait for styling

Typing moves the caret, and `textViewDidChangeSelection` used to restyle
synchronously before the character was drawn, which is what stopped a held
key keeping up. An edit's own caret move now defers to the pass the edit
already scheduled, and `scheduleRestyle` waits longer than a key-repeat
interval while edits arrive in a burst, so a held key costs one restyle at the
end. The deferral applies only while a full restyle costs more than a key
repeat, measured on the previous pass: deferring a cheap one saves nothing and
shows the line's markup for a frame.

Two things stay synchronous: a caret move that is only a caret move, or arrow
keys stutter; and anything reading the layout it just invalidated, which is
why `TableSurface.apply` calls `restyleNow()` before placing the caret in a
row it added.

Decorating reparsed the whole document per keystroke, which made typing scale
with the note rather than the edit. `LiveDecorator.decorations(in:reusing:)`
reuses the previous parse when the edit provably could not have changed
anything outside one blank-line-bounded region, and reparses that region
alone. The region is the paragraph the edit sits in, plus the paragraphs
either side of any blank line it touches, since an edit on a blank line joins
them; that is what lets Return, a pasted block and a merged paragraph take the
fast path, not only a character typed inside a line. Two guards make it safe:
a region containing anything that can open a construct across blank lines (a
fence, `$$`, a comment, or `---` at the start of a line, where a thematic
break or frontmatter fence can stand; a table's separator row must not count)
is never reused, and neither is one that any cached decoration crosses the
boundary of. That second guard asks about ranges, not kinds: a list of block
styles missed `$…$`, which pairs across blank lines. The region's decorations
are appended as a group, which is safe because decorations only overlap
within a paragraph.
`IncrementalDecorationCheck` compares the reusing decorator against a full
scan directly, since the styling check would let a wrong reuse agree with
itself.

## Backslash escapes, and where they are scanned

`\*` is a literal asterisk. One scan marks a backslash plus ASCII punctuation
as a protected range, and every inline matcher already excludes protected
ranges, so that single pass stops `\*`, `\_`, `\[` and the rest from opening
anything. Matching left to right and non-overlapping is what makes `\\*`
right.

Where the scan sits is load-bearing in both directions. It runs after maths
and code have claimed their contents, because those are full of backslashes
that are not escapes, and treating `\frac` as one made the block stop
matching. The price is that `` \` `` does not stop a code span opening, which
CommonMark says it should, and that is a far smaller wrong than losing the
maths. It runs before emphasis and links, which is the point of it.

## Reference links, and the two passes they need

`[label]` is a link when something further down the file defines that label
and an ordinary bracketed aside when nothing does. It is the only construct
here whose meaning depends on the rest of the note, so the definitions are
collected first and every reference is checked against them; anything with no
definition is left as prose. That is what keeps `[ ]`, a bracketed aside and
a wikilink out of it without a single special case.

Order does the rest of the work. Definitions are matched before bare URLs are
looked for, or the autolink matcher claims the URL out of `[a]: https://…`
and leaves the definition in pieces. The full form is matched before the
collapsed one and the collapsed before the shortcut, because each shorter
pattern is a prefix of the longer: matching `[label]` first would take the
`[text]` out of `[text][label]` and leave the rest as prose.

All three forms resolve to an ordinary link decoration, so colouring,
clicking, PDF export and every rendered view work on them without knowing
they were written this way. Only the definition line has a style of its own:
its brackets and colon collapse, the label keeps the link colour, and the URL
stays visible in grey, because a definition whose URL was hidden could not be
checked or corrected without revealing the line first. Labels are compared
lowercased with runs of whitespace collapsed, which is CommonMark's rule and
the difference between `[Read More]` finding its definition and failing
silently over a capital letter.

Single-line definitions only. CommonMark allows the URL or title to run onto
following lines; the matcher here works line by line, and nobody writes that
by hand.

## Setext headings

`Text` underlined with `===` is an H1 and with `---` an H2, matched before the
thematic break because setext takes precedence for the same characters. The
line above must be an ordinary paragraph line: blank means the `---` is a
rule, and a line opening a block of its own is that block. Two deliberate
divergences from CommonMark: a single `-` is not an underline, or the line
above would become a heading the instant a list item was started under it;
and only the single line above is the heading, not the whole paragraph.

## Auto-pairing

Obsidian splits this into "Auto pair brackets" and "Auto pair Markdown
syntax", and so does Heft. Neither character set is documented, so Heft's are
`(` `[` `{` and `*` `_`. Not the backtick, which Obsidian also leaves alone:
paired, a code fence became six of them with the caret in the middle.

`BracketPairing` is pure and is not a `SmartTypography` rule: a substitution
runs after a character has landed and cannot put the caret back between two
characters it just wrote, so `insertText` asks it before inserting. Four
rules, each because the obvious version is annoying: a closer already under
the caret is stepped over; nothing pairs immediately before a word, since
typing `(` in front of text is how wrapping it by hand starts; a symmetric
marker does not pair immediately after a word either, or `snake_case` pairs
its underscore; except that a second `*` inside a pair opens another, because
that is how `**bold**` starts. `[[` falls out of these rules on its own.
Quotes belong to the curling substitution and are left alone.

## Typing substitutions

`SmartTypography` in HeftCore is the Obsidian Smart Typography equivalent plus
a snippet table. It is a pure function of (document, caret) run after a
character lands, so a rule is "this text now ends at the caret" and no rule
needs to know which key fired. Eight built-in groups switch individually and
the same engine runs the user's `trigger → replacement` table;
`HeftTextKit2View.applySubstitution` is the one call site, and its
`deleteBackward` puts the typed text back when backspace follows at once.

What the table adds beyond arrows: firing is per rule, `.afterWord` (the
default, like macOS text replacement, or a word-shaped trigger fires inside
longer words) or `.immediately`, with the delimiter re-emitted unchanged so
one backspace undoes both; placeholders go through `MomentFormat.expandTemplate`
and share the daily-note token list, with `{{caret}}` as Heft's own; and
chained rules match what is on screen (`←>` for `<->`), ordered before the
two-character rules that would claim the same suffix. Return reaches the
engine through `insertNewline` with `endingWord: true`, where only
`.afterWord` rules may fire.

Nothing fires inside code, maths, frontmatter, wiki links, link destinations,
tags or URLs; `SmartTypography.allowsSubstitution` is a cheap own scan rather
than a `LiveDecorator` pass because it runs on every keystroke.

## Completion

`[[` and `> [!` share one panel, so `WikiCompletionItem` carries a title,
detail and symbol rather than a `NoteRef`, and the view remembers which
`CompletionKind` is open. `CalloutCompletionContext` only fires on the line
that opens a quote block, because Obsidian reads `[!kind]` nowhere else, and
only with the caret inside the name being typed, or every callout on the line
would reopen the menu. Aliases find a row; accepting writes the canonical name.
