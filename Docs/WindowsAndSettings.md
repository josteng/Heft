# Windows, settings, and the sidebar

What a window owns, what it only asks about, and where each preference
lives. Read this before adding a setting: the question is almost always
which of the three stores it belongs in.

## What a window knows, and what it only asks about

`AppModel` is a window's own state: the open note, the buffer, navigation,
focus, save conflicts. It is not where the rules live, and the boundary has
been crossed twice and cost something both times.

`VaultRename` in HeftCore decides which files move and what the notes pointing
at them should say. `VaultOperations` decides everything around that: cleaning
a typed name, restoring the `.md` a note is displayed without, finding a free
`Untitled 3`, and whether a rename or move can happen at all. Both used to be
`guard` statements inside `AppModel` interleaved with writes to `status`, so
the command line re-derived the `.md` rule by hand and drifted. A refusal is
therefore a value, `VaultOperations.Refusal`, with one wording the sidebar
shows, the CLI prints and a test asks for.

`VaultHost` is everything an operation has to ask a person or hand to the
system: alerts, panels, `NSWorkspace`, `NSPasteboard`. `AppKitHost` ships;
`ScriptedHost` in the test target answers from a queue, which is how the
refusals are driven end to end without a modal blocking.

Read back what the plan decided rather than recomputing it: `move` takes its
destination from the plan's path, so where the file is written and where every
link is repointed cannot disagree.

## What the palette can do

Every verb the sidebar offers on a right click is also a palette command,
acting on the note in front rather than on a clicked row, since the palette
opens over the editor where there is no row. That includes both paths: the
vault-relative one a link wants and the absolute one a terminal or an agent
wants. They were reachable only by finding the note in the tree first, which
is how someone ends up revealing a note in the Finder to read its path off
the title bar while Copy Absolute Path sits in the menu.

The four that change a file, rename, duplicate, move and trash, need the
tree's own item rather than the open note's reference, so they are dimmed
while the vault is still being scanned. They ask exactly what the menu asks;
a palette must not be a faster way to lose a note. A test holds the two
lists against each other, because the failure here is a verb added to the
menu and forgotten in the palette.

## Selecting several rows

`SidebarSelection` holds the picked rows and the three clicks that change
them: plain replaces, command toggles, shift takes the range. The range is
measured against the tree *as drawn*, so shift-clicking across a collapsed
folder takes the folder and not the notes inside it that nobody can see. The
anchor is the last row clicked without shift, kept apart from the selection
so extending twice measures from where the reader started rather than from
wherever the last extension ended.

Only a plain click opens the note or folds the folder. Command and shift are
the reader gathering rows, and swapping the editor out underneath a
half-built selection is the thing that makes multi-select feel unsafe.

A verb acts on the whole selection when the clicked row is inside it and on
that row alone otherwise, which is what stops a menu quietly acting on a
selection made a minute ago and forgotten. Trashing asks once for the lot and
drops anything already inside a selected folder, since trashing the folder
takes its contents and the count in the question has to be true. The
selection is pruned on every rescan, or the next keystroke asks about files
already in the Trash.

The list of URLs was never the hard part: moving, copying to the pasteboard
and pasting all took several before anything could select several, because a
drag out of the Finder always could.

## Ranking the switchers

Quick Open and the command palette order by **frecency**: `Frecency` in
HeftCore holds one Double and one date per item, a use adds one and the score
halves every three days, with the decay applied on read. Recency alone puts a
note opened once by accident above one opened every morning; frequency alone
never lets go of last year's project. `VaultSession.recentPaths` stays as a
history, because the sidebar's Recent list has to keep the order things
happened.

A command that cannot run right now sinks below every command that can,
keeping its rank among the others down there. Frecency alone put "Review
agent proposals" first for a reader who reviews often, on a day with nothing
to review, so Return did nothing. Hiding it instead is worse: a dim row
teaches where a command lives, a missing one teaches nothing and shifts
every row above what you were reaching for. Because it sinks, the first row
is runnable whenever any row is.

With nothing typed, frecency is the whole order. With something typed it is
worth at most `VaultIndex.boostWeight`, less than the gap between match tiers,
so familiarity reorders within a tier and never lifts a substring match above
a prefix one. Both sorts carry the original index as a final tiebreak, since
Swift's sort is not stable. Both rules live in `VaultIndex.search`: the caller
passes the raw score, because saturating it before handing it over is right
for the typed case and wrong for the empty one.

**What counts as a use:** the reader's own opens, reached from `AppModel.open`
and nowhere else, so `heft open` counts and the agent verbs do not; and the
reader's reviews, through `VaultSession.recordReview`, once per proposal, in
the ranking only. The store models one person's attention, and a `heft
propose` loop over thirty notes must not displace weeks of it. An agent's own
work is a second index under a different key (`--by-agent`), recorded by
`propose` alone, since counting reads would rank the vault by fan-out.

## Reloading, and what it costs the windows

`VaultSession` forwards its `objectWillChange` to every `AppModel` attached
to it, so every published property on the session redraws every window, and
the chrome costs more to redraw than the vault costs to scan. `reload`
therefore publishes only what differs: the index is built from the previous
one, re-reading only files whose size or date changed; `tree` is assigned
only when it differs, with `VaultItem`'s equality leaving the fingerprint
out; and `index` only when `answersMatch` says the files or their links,
tags and mentions changed. The unpublished build is kept as `latestIndex` and
the next reload starts from it. The first build of a process starts from
`IndexCache`, the same per-note parses written to Application Support by the
last build, so a cold start and every `heft` verb read only what changed
since; a vault under the temporary directory is never written there.

The same rule governs typing. `AppModel.text` is deliberately not
`@Published`; typing publishes only the counts, through `NoteStats`, which
the status bar alone observes, on a timer. A replacement from outside the
editor bumps `documentGeneration`, which is published.

The window's edited marker, the dot in the close button, does not mean
"unsaved": autosave makes that true for under a second at a time, and a dot
flickering with every pause tells the reader nothing they can act on. It
means the note cannot be written, a failed write or a conflict that has paused
saving (`saveIsBlocked`), and it makes the window ask before closing, which
is right for exactly that note.

## Renaming, in one place

`VaultRename` in HeftCore does the work; `AppModel` keeps only what a window
knows, whether another window has the file open and that the note being
edited must be read from its buffer. `heft rename` calls the same thing. A
link written as a path is repointed; a bare `[[note.pdf]]` that still resolves
is left as written. A note that changed between the plan and the write is
skipped rather than overwritten.

## What opens when Heft starts

`StartupNote` in HeftCore, stored per vault, because "always open
`Thesis/Overview`" names a note and a note exists in one vault. Five answers,
defaulting to leaving things alone: nothing, the note you were last on (not
the same thing: the first relies on macOS restoring the window), today's daily
note, a named note, or a path from the date in moment tokens, which is how a
weekly note is expressed.

Which vault comes up at all is the one app-wide answer on the same pane:
`LaunchVaultPreference`, the vault chosen while it is there, else the vault
opened last. It decides only a start with nothing to restore, since macOS
brings the open windows back, and it is separate from the capture vault: the
two were briefly one accessor, and choosing where captures go changed what
opened.

Three sources decide, in order of how deliberate they are: a note named on the
command line, then the setting, then a restored window's own note. The setting
outranks restoration, or a launch from the Dock would make it do nothing, and
it is claimed once per process. Only the daily note is created; a path in a
settings field is not a request to litter the vault with empty files.

## Where captures go

`InboxNotePreference` in HeftCore names the inbox note per vault, stored the
way `StartupNote` is and for the same reason: it names a note. It lives in
the pure target because Spotlight and Shortcuts capture with no window open
and must land in the same file the palette's Open Inbox shows; `InboxCapture`
reads it when given no path, so every caller agrees without being told.

The captures themselves run in `HeftCapture`, an App Intents extension, and
their App Shortcuts are declared there beside them. An intent compiled into
the app runs in the app process, and macOS activates the app to run it, so a
minimized Heft came out of the Dock every time a line was filed from
Spotlight; putting the window back afterwards was tried and could not beat
the activation to the screen. The extension is a process with no windows,
so there is nothing to put back. It is sandboxed, because macOS launches no
extension that is not, and reads the app's preference domain and the vault
through exception entitlements rather than an app group: the app is not
sandboxed and its settings already live in one domain. The two intents that
open a note stay in the app, which is where the windows are; a provider can
only name intents in its own target, so there is one in each. The
Capture pane in Settings edits it for the vault in front, keeps what was
typed, and says what that amounts to; a value that cannot be a path inside
the vault falls back to `Inbox.md` rather than failing a capture. The folder
is created on the first capture, since the setting is a promise about where
things go. Which *vault* a windowless capture lands in is the other half,
and app-wide because it answers which of them: `CaptureVaultPreference` is
the vault chosen once in the pane while it exists, otherwise the vault opened
last, which is what it always was. Whether a captured line starts with the time is one app-wide answer,
`CaptureTimestampPreference`, shown in the same card. Both captures write the
same kind of line, so a setting that reached the inbox but not today's note
would be one nobody could describe. Off, the time and the space after it go
together: `-  thought` with two spaces is indentation to a Markdown parser,
which is a different list. The day heading in the inbox stays either way,
since that is what keeps the file readable.

Daily captures have no setting: the log
marker in the template is the placement control, and the pane offers it to
copy.

## Settings that are not about one vault

Every pane is a grouped `Form` laid out as System Settings lays out its own:
a card holds controls and nothing else, what one control does is written
under its name inside its row (`SettingLabel`), what a group is for is
written above its card (`SectionHeading`), and nothing goes in a footer.
The panes were built one at a time in three different styles, and the
difference only showed when someone clicked through the tabs in a row.

`GeneralSettings` holds where a new note goes and when a window opens its
calendar. `NewNoteLocation` is pure and takes every fallback as an argument.
A folder chosen in the sidebar still wins over the setting: a gesture outranks
a preference. A named folder is the one that may be created, when the first
note goes in it. `CalendarVisibility`'s default is scope-aware, since a window
focused on `Projects/` has no business showing a calendar for `Journal/`;
`always` and `never` outrank a restored window's state.

Consecutive lines follow the vault's `strictLineBreaks` and nothing overrides
it. An Appearance setting that did was removed: the editor cannot honour one,
since a newline breaks the line whatever it is styled as, and only
Presentation could ever have shown it. `AppModel.renderContext` is the one
place a `RenderContext` is built; three hand-written copies drifted, and a
defaulted field in a struct built in several places is a bug waiting for its
third copy.

## The sidebar: revealing, and naming a new note

Opening a note does not rearrange the tree; `revealCurrentInSidebar` is the
deliberate version, and it opens every folder above the note, brings the
column back and sets `revealTarget`. The scroll is a request the view answers,
because only the sidebar holds the `ScrollViewReader` and knows which of its
lists is showing. It observes the request twice, once to put the file list
back and once inside the tree, and the inner one is `task(id:)` because the
tree is built after the request when switching back from Tags. `SidebarAnchor`
wraps the path in its own type so the tree's rows and the anchor do not share
an identifier.

A new note is named in the sidebar, in the row it is about to occupy. ⌘N
posts a request the view answers and falls back to a prompt when the sidebar
is hidden. The row is scrolled to through `revealTarget`, waiting for the row
rather than a fixed delay, since a note is on disk well before it is in the
tree. The note is not opened until it is named, or there are two insertion
points; naming it opens it at the path read back from the rename plan.

Files copy and paste through the general pasteboard as files, the way the
Finder does it, so a note copied here pastes into the Finder and a file
copied there pastes into a folder here. A file from outside the vault is
copied in, by a paste and by a drop alike, and stays where it was: a drop
moves only what is already in the vault, because moving a file out of the
reader's Downloads is not what dropping it on a note list should mean.
Pasted into the text, a file already in the vault becomes a link, `[[Name]]`
for a note, an embed for a picture; a note from outside is copied in beside
the open note and linked the same way.

A file that lands in the vault is scrolled to and lit for a moment, since the
tree orders by name and a PDF dropped in appears halfway down a folder. The
light goes out after a couple of seconds: one that stayed would be read as the
selection, which a PDF never has. It sits beside the open note's own row
rather than replacing it, because the note being read is still the selection
while the marker shows. The list only moves when that row is off screen, since
scrolling the tree under a reader who can see the thing already is what reads
as losing their place.

Dragging a daily note out of its folder asks first, and an agent proposing the
same move is told while it proposes, with the review sheet repeating it in a
caution band above the buttons. Not in the description beside the standard
sentence about repointed links: a consequence written in the same grey as the
explanation is read as more explanation. Three places, one sentence, on `DailyNotes`. Accepting a
proposal asks nothing further: a drag is a slip of the hand with no stated
intent, while a proposal is deliberate, summarised and read as a diff, and a
question there is the shape that teaches people to click through questions.

A daily note is found by
its folder and its name, so moving one elsewhere quietly turns it into an
ordinary note: the calendar stops showing it and ⇧⌘T writes a new one in its
place. The question is asked once for a drop, and only about the notes
actually leaving, so an ordinary note dragged in the same gesture is not held
up by a question about another file. Which notes count is decided by where
they live rather than by reading their names, since the date format has no
parser and a vault keeping its daily notes in the root has no folder to leave.

⌘⌫ on a clicked row is the Finder's Move to Trash, and asks the same question
every other route to the Trash asks. It is a File menu command rather than
something the text view intercepts, and that is what makes it work: a menu
item's key equivalent is offered before any view sees the event, and clicking
a folder in the tree takes the keyboard off the editor, so the editor could
not answer for it. The item is disabled while nothing in the tree is clicked,
which lets the key through to the text, where it deletes to the start of the
line.

Every menu Heft builds for itself carries symbols, which is what macOS 26 does
throughout its own apps. The one rule the criticism of that change is worth
taking from: no two rows of one menu share a symbol, since an icon reused for
unrelated commands makes a menu slower to read than no icons at all. Every row
of the SwiftUI menus goes through one small view that pins the symbol to the
label's ink and dims it when the row is disabled. A row built as a plain
button with a `systemImage` inherits the window's accent instead and comes out
coloured beside its neighbours, and a pinned ink that ignores the row's state
leaves a full-strength icon beside greyed-out text.

The Trash item's enabled state is why the row the tree last clicked lives in a
small observable object of its own. A menu item settles that state when the
menu is built rather than when the key is pressed, so something has to say
when it changes, and it cannot be `AppModel`, which publishes on every
keystroke and would rebuild the menu bar with it.

A file copied into the vault keeps its own name while that is free, and
takes `Name copy`, then `Name copy 1`, when it is not, whether it arrived
through the sidebar or through a paste into the text. The two halves used to
answer the same collision differently, one counting `Name 1`.

⌘C and ⌘V arrive at the text view, always: clicking a note in the tree
leaves the keyboard with the editor on purpose, so typing can start. Giving
the tree SwiftUI focus as well ran both handlers, a file into the folder
and a link into the note. So the sidebar only records what was clicked last
(`sidebarKeyboardTarget`), and the text view asks that first: after a folder
or blank space, ⌘C copies the folder and ⌘V pastes into it, with a folder
pasted onto itself landing beside it as the Finder does; after a note, a
click in the text or a keystroke, the keys are the text's own, except that
⌘C with nothing selected copies the open note as a file. That last one needs
the Edit menu's Copy to stay enabled: a text view disables it while nothing
is selected, and a disabled item swallows its own key equivalent, so ⌘C beeped
instead of ever reaching the view.

Naming in place writes the file first, so backing out used to leave an
`Untitled.md` behind. `discardUnnamedNote` takes it back, and every guard on
it is about being certain it is that file: still called `Untitled`, still
empty on disk, and nothing typed into it since. The name check is the one that
matters, since an empty note the reader named looks abandoned to every other
test.
