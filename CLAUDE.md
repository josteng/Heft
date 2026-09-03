# Heft

Native macOS markdown vault editor (Bear/Obsidian alternative). Pure Swift with a
native Xcode app target and a SwiftPM core package, targeting macOS 26. Sync is just
pointing the vault folder at iCloud Drive; there is no custom sync engine. Opens an
existing Obsidian vault unmodified, including its `.obsidian/` config.

```bash
Scripts/smoke.sh                                # does the app actually start?
Scripts/run.sh [vault] [note]                   # Xcode build, then launch
Scripts/run.sh --sandbox [vault]                # ...with isolated preferences
Scripts/bundle.sh debug                         # Xcode build without launching
Scripts/install.sh [--install-only]             # release install; launches by default
swift test                                      # core, live-surface, and disposable-vault checks
swift run Heft stats <vault>                    # read-only index report; safe on the real vault
swift run Heft render <vault> <note> [caret]    # what the live surface would draw, headless
swift run Heft daily <vault> [YYYY-MM-DD]       # template expansion without the GUI
swift run Heft help [--json]                    # every verb and flag, from CommandLineSpec
swift run Heft proposals <vault>                # agent edits waiting for review
swift run Heft backlinks|links|outline <vault> <note>   # the resolved link index
swift run Heft tags|config <vault>              # tags with counts; settings as JSON
swift run Heft export <vault> <note> <out.pdf>  # rendered note as a PDF, headless
    # --text-size N --paper a4|letter|legal|tabloid --landscape --margin narrow|normal|wide --title
```

## Architecture

Three targets:

- `HeftCore`: pure logic. Never imports AppKit or SwiftUI. Parsing, the link index,
  the vault scanner, moment.js date formatting, live-mode decorations.
- `HeftVimCore`: Foundation-only modal editing grammar. It returns edits and
  selections but never owns an editor buffer or imports AppKit. Anything it
  cannot answer from the text alone — which lines are on screen for `H M L`,
  replaying a macro's keys against a document it does not hold — comes back as
  a `VimHostAction` for the text view to carry out.
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

### Emphasis while it is still being typed

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

### Blocks written inside a quote

The block matchers are anchored to the start of a line, so everything after a
`>` was quoted prose: `> - item` had no bullet and no indent, and `> ## H` was
body text. `QuotedBlock` on `QuoteLine` carries a list marker or heading level
found *after* the quote's own markers, and its markup joins the `>` in the
decoration's `syntax` so both collapse together.

It rides on the quote line rather than arriving as its own decoration because
the editor draws **one widget per line**, keyed by line start: a bullet and a
quote bar on the same line are one thing to draw, not two competing for the
same key. So `.quote` carries an optional `QuotedBullet` and hands it to the
same glyph drawing `.list` uses.

Two numbers are load-bearing. Indentation inside a quote is measured from
where the `>` markers stop, or every quoted list reads as one level deeper
than it is. And the indent handed to the *widget* must be the paragraph's real
indent, nested list included: the card is drawn back from the fragment's own
origin, so passing the quote's own edge instead leaves the fragment indented
and the card not, stepping the whole card right on every list line.

A callout's header line is excluded: `[!kind]` has already claimed what
follows the marker there.

### A picture pasted onto a bullet

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

### Typing must not wait for styling

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

### One place the verbs are declared

`CommandLineSpec` in HeftCore is the only list of what the command line can
do. `heft help` prints it, `heft help --json` is what an agent reads, and
`Scripts/install.sh` asks the freshly built binary for `help --verbs` and
bakes the answer into the shell wrapper.

That last one is why the table exists at all. The wrapper's verb list was a
second, hand-written copy of the dispatch, and it drifted the first time a
verb was added: `heft export` was rewritten to `heft open export` and reported
"no such file or folder: export" from a binary that handled it perfectly well.
A hand-written help text would have been a third copy and would have rotted
the same way.

Dispatch in `Main.swift` is still hand-written — making it table-driven is a
bigger change than the problem warrants — so two tests hold the invariant
instead: every dispatched verb is in the spec, and every declared verb is
dispatched. A verb missing from the spec is a verb no agent can discover *and*
one the wrapper turns into `open`.

### Ranking the switchers

Quick Open and the command palette both order by **frecency**: how often
something is used, discounted by how long ago. `Frecency` in HeftCore holds
one Double and one date per item — a use adds 1, and the score halves every
three days, with the decay applied on read. That is algebraically a sum of
`0.5 ^ (age / halfLife)` over every past use, without keeping a history.

Recency alone was the obvious alternative and is wrong: an MRU list puts a
note opened once by accident above one opened every morning. Frequency alone
never lets go of last year's project. `VaultSession.recentPaths` stays as it
is, because the sidebar's Recent list is a *history* and has to keep the order
things happened; this is a *ranking*.

With nothing typed, frecency is the whole order — an alphabetical list of every
note is a directory listing, not a switcher. With something typed it is worth
at most `VaultIndex.boostWeight` (60), which is less than the gap between any
two match tiers, so familiarity reorders results *within* a tier and can never
lift a substring match above a prefix one. Both sorts carry the original index
as a final tiebreak, because Swift's sort is not stable and every unused note
scores the same: without it a fresh vault's list would reshuffle between
openings.

#### What counts as a use

Only the reader's own opens. `recordRecent` is reached from `AppModel.open`
and nowhere else, so `heft open` and `heft .` count — a person opening a note
from a terminal is the same act of attention as opening it in the window — and
the agent verbs record nothing, because `AgentCLI` never touches `AppModel`.

That is deliberate, not an oversight. The store is a model of *one person's*
attention, and it is the thing Quick Open opens on. A single `heft propose`
loop over thirty notes would write thirty uses and displace weeks of the
reader's own signal, with no way back short of deleting the store. `propose`
does not even edit the note it names — it writes a file under
`.heft/proposals/` and leaves the note alone.

There is already a precise channel for "an agent touched this": the proposal
list, which names the note, survives until it is reviewed, and clears when it
is. A decaying score is a much worse version of that. It is the same reasoning
that makes the vault watcher ignore Heft's own writes.

`heft files <vault> --by-use` exposes the ranking read-only, which is what an
agent should use: "what is this person working in" is a far better prior than
alphabetical order or a modification date, which every sync disturbs.

An agent's own work is kept in a **second index** under a different key and
surfaced by `--by-agent`. `heft propose` records there, and nothing else does:
an agent reads twenty notes to decide about one, so counting reads would rank
the vault by fan-out. It is also the only record that outlives a proposal —
once one is accepted, `.heft/proposals/` forgets the note was ever touched.

A store loads its copy from `UserDefaults` once, at init. A test that asks an
instance built *before* a write therefore passes even when both stores share a
key, which is how the separation test first passed against a mutation that
merged them. Read through a fresh instance.

### Completion

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

### Agent proposals

An agent does not edit the vault; it proposes, and the editor asks. `AgentCLI`
adds `propose`, `proposals`, `diff`, `drop`, `read` and `find` to the same
headless dispatch in `Main.swift` that `stats` and `render` use, so the whole
integration is a CLI rather than a daemon or a port. `heft propose` takes the
**complete new body** on stdin, not a patch: an agent already has the finished
text, and a full body cannot fail to apply. Where that would mean restating a
long note to change a paragraph, `--replace` takes anchored `old`/`new` pairs
instead; `AnchoredEdit` resolves them against the note as it is now and refuses
an anchor matching more than once, so a bad anchor fails at the command rather
than at review time and what reaches the store is still a full-body proposal.

A proposal is one JSON file under `<vault>/.heft/proposals/`, which the existing
vault watcher already sees. `NoteDiff` in HeftCore turns it into hunks, and each
one is accepted or rejected on its own in `ProposalReviewView`.

Three decisions carry it:

- The diff is against the note **as it is now**, never against what the agent
  read. The user is deciding about their current note; `Proposal.isStale` says
  so when the note moved on, rather than silently rebasing the reasoning.
- A partly reviewed proposal is a **smaller proposal**, not a lost one.
  `ProposalStore.settle` applies the accepted hunks, drops the rejected ones
  from the body for good, and rewrites the rest as a fresh proposal against the
  updated note.
- An accepted change to the open note goes through the buffer and the normal
  autosave, rather than writing the file under the editor and racing it.

`Docs/AgentIntegration.md` has the verbs and the `CLAUDE.md` snippet that makes
Claude Code reach for `propose` instead of `Write`.

The two markers are **drawn as a labelled rule** rather than hidden with the
other HTML comments, and reveal their source when the caret is on their line
like any other block. Without that the boundary is invisible, and a note typed
at what looks like the end of the file lands on managed ground; with it,
pressing Return at the end of the rendered marker lands *after* it. Anything
typed inside anyway is saved to `.heft/claude-md/` before the section is
replaced.

The guide is **stamped with a version**, because it is copied into the user's
vault and frozen there: an upgraded Heft cannot reach it, so a vault set up a
year ago would go on describing a command line that no longer exists. Every
agent verb checks the stamp and writes one line to *stderr* when the vault is
behind, naming `heft agent-setup` as the fix; the editor offers the same as a
refresh banner. Nothing rewrites `CLAUDE.md` on its own — it is the user's
file and may hold their own instructions, which is the same rule proposals
exist to enforce. Bump `AgentGuide.version` whenever the wording an agent
depends on changes.

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
- **Never point the GUI at the real vault while testing.** It autosaves. Use a copied
  sandbox vault, or the read-only `stats` and `render` commands.
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
- **A backgrounded GUI app holds the shell's stdout open.** `app &` on its own
  makes any caller reading the script's output — a pipeline, a CI step, an
  agent's shell — block until the app quits rather than returning. Launch it
  with `nohup … >/dev/null 2>&1 &` and `disown`.
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

- Embed display widths are ignored: `![[img.png|700]]` renders at natural size,
  capped at 460pt.
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
- Deferred: graph view, plugins.

## The icon

`Resources/Heft.icon` is a layered macOS 26 icon, compiled by `actool` during
bundling into `Assets.car` plus an `.icns` fallback. Its format is undocumented
and was reverse engineered; see `Resources/Heft.icon/README.md` before editing.

## Decisions already made

Kotlin Multiplatform was evaluated and rejected: the only portable slice is the
parser and link index, which is not worth the Gradle/SKIE boundary, and iOS is the
next target and is Swift anyway. The Gradle, JDK, XcodeGen and KMP-framework
pre-build phase a shared module needs cost more than the slice is worth.

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
