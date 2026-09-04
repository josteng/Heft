# Windows, settings, and the sidebar

What a window owns, what it only asks about, and where each preference
lives. Read this before adding a setting: the question is almost always
which of the three stores it belongs in, and that has been got wrong.

## What a window knows, and what it only asks about

`AppModel` is the largest thing in the app target and is a window's own state:
the open note, the buffer, navigation, focus, save conflicts. It is *not* where
the rules live, and the boundary is worth keeping because it has been crossed
twice already and cost something both times.

`VaultRename` in HeftCore decides which files move and what the notes pointing
at them should say. `VaultOperations` decides everything around that: cleaning
a typed name, putting back the `.md` a note is displayed without, finding a
free `Untitled 3`, and whether a rename or a move can happen at all. Both were
`guard` statements inside `AppModel` interleaved with writes to `status`, so
the only way to reach one was through a running window — and the command line
re-derived the `.md` rule by hand, in a slightly different form, which is
exactly the drift `CommandLineSpec` exists to prevent elsewhere.

So a refusal is a **value**, not a string assigned on the way out.
`VaultOperations.Refusal` carries one wording that the sidebar shows, the CLI
prints, and a test asks for without either. It conforms to `Error` only
because `Result` asks that of a failure type; nothing throws one.

`VaultHost` is the other half: everything an operation has to ask a person, or
hand to the system, before it can happen. `AppModel` used to build an `NSAlert`
or an `NSOpenPanel` in the middle of renaming and deleting, which made those
paths unreachable in a test — `runModal` blocks and has no answer to give — so
the checks around them were verified by reading. `AppKitHost` ships;
`ScriptedHost` in the test target answers from a queue and records what it was
asked, which is how the refusals are now driven end to end. `NSWorkspace` and
`NSPasteboard` are behind it for a related reason: opening an attachment in a
test does not block, it launches Preview.

Reading back what the plan decided, rather than recomputing it, is the rule in
both. `move` takes its destination URL from the plan's path, so where the file
is written and where every link is repointed to cannot disagree — the same
lesson as reading a list's indent back from the paragraph style rather than
from the marker's depth.

## Ranking the switchers

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

Those are two different uses of one number, and **both rules live in
`VaultIndex.search`** because applying one without considering the other is a
bug that reads as working. It was: Quick Open saturated the score at
`wellUsed` (4) *before* handing it over, which is right for the typed case and
wrong for the empty one — every note used four or more times arrived at the
ceiling together, and the empty list fell through to the alphabetical
tiebreak. A note opened thirty times sat below one opened five times, in a
switcher whose whole claim is to open on what you use. The caller now passes
the raw score and `search` decides.

#### What counts as a use

The reader's own opens, and the reader's own reviews. `recordRecent` is reached
from `AppModel.open` and nowhere else, so `heft open` and `heft .` count — a
person opening a note from a terminal is the same act of attention as opening
it in the window — and the agent verbs record nothing, because `AgentCLI` never
touches `AppModel`.

`VaultSession.recordReview` is the second door, and it is one only a person can
walk through: it is reachable from the review panel and nowhere else. Accepting
or rejecting a hunk is the most deliberate attention a note can get — every
change was read and answered — and it used to count for nothing, while opening
a note and looking away counted fully. It records the ranking only, never
`recentPaths`: that list is a history of what was *opened*, and the note is
already in it.

Once per **proposal**, not once per hunk, which `AppModel.countedReviews`
enforces on the id `settle` preserves. A ten-hunk proposal must not outweigh
ten mornings of opening the note.

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

## Renaming, in one place

`VaultRename` in HeftCore does the work: which files move, which notes point at
them, and what those notes should say afterwards. `AppModel` keeps only what a
window knows — whether another window has the file open, and that the note
being edited must be read from its buffer rather than from disk — and hands the
rest over. `heft rename` calls the same thing with no window at all.

A link written as a path is repointed; a bare `[[note.pdf]]` that still resolves
is left exactly as it was written. A note that changed between the plan and the
write is skipped rather than overwritten: half of somebody's edit plus half of
this is worse than neither.

## What opens when Heft starts

`StartupNote` in HeftCore, stored per vault. Per vault because "always open
`Thesis/Overview`" names a note, and a note only exists in one vault.

Five answers, and the default is to leave things alone, or an update would
change where everybody's editor opens. "Nothing" and "the note you were last
on" are not the same: the first relies on macOS restoring the window, and a
cold start with nothing to restore comes up empty. The other three are today's
daily note, one named note, and a path worked out from the date in the same
moment tokens a daily-note template uses — `Weeks/{{date:GGGG-[W]WW}}.md` for a
weekly note, which the daily-note settings cannot describe.

Three sources decide, in order of how deliberate they are: a note named on the
command line (`heft open`, `--open`) wins outright, then the startup setting,
then a restored window's own note. The setting has to outrank restoration
rather than defer to it — a launch from the Dock restores the last window, so a
setting that stepped aside for that would never do anything at all — and it is
claimed once per process, because opening a second window is not starting the
app.

Only the daily note is *created*. It is what the setting means and the vault
has a template for it. A path typed into a settings field is not a request to
litter the vault with empty files on every launch.

## Settings that are not about one vault

`GeneralSettings` holds the two app-wide preferences that are not about how
anything looks: where a new note goes, and when a window opens its calendar.
Kept apart from Startup, which answers one question **per vault** because
"always open `Thesis/Overview`" names a note and a note only exists in one
vault; and apart from Appearance, which is about the page.

`NewNoteLocation` is pure and takes every fallback as an argument, so the rule
can be shown in a pane and asked for in a test without a window. A folder
chosen in the sidebar still wins over the setting: that is somebody pointing at
a place, and a setting must not override a gesture. A named folder is the one
that may be **created**, when the first note goes in it — naming a folder is
asking for notes to go there, unlike a startup path, which is a request to open
something.

`CalendarVisibility`'s default is the old behaviour and is scope-aware: a window
focused on `Projects/` has no business showing a calendar for daily notes kept
in `Journal/`. `always` and `never` are not, because someone who says "always"
has answered that question themselves — and they outrank a restored window's own
state, or a window that disagreed once would keep overruling the setting.

Consecutive lines follow the **vault's** `strictLineBreaks`, Obsidian's own
setting in `.obsidian/app.json`, and nothing overrides it. An Appearance
setting that did was removed: the editor cannot honour one at all, since a
newline breaks the line in TextKit whatever it is styled as and the buffer *is*
the file, and PDF export renders that same surface. Presentation was the only
place it could ever have shown, which makes it a setting that changes one
hidden view while reading as though it changes the app.

`AppModel.renderContext` builds the context every rendered surface is drawn
with, and is the only thing that does. There were three hand-written copies and
`PresentationView`'s forgot `strictLineBreaks` — a field with a default, so
nothing complained — which is why the vault's own setting reached nothing for
as long as it did. A defaulted field in a struct built in several places is a
bug waiting for its third copy.

Folder disclosure arrows are a toggle in Appearance, off by default: the folder
icon already fills when the row is open, so the arrow was a second way of saying
the same thing in a column of its own down the right-hand edge of the tree.

## The sidebar: revealing, and naming a new note

Opening a note does **not** rearrange the tree. It used to expand every folder
above the note on every open, so clicking a date in the calendar unfolded
`Daily Notes` and left it unfolded, for a note nobody was browsing to. And it
was half a reveal: expanding is not `revealTarget`, so nothing scrolled and the
note was somewhere inside a folder that had just grown by a year of dailies.

Quick Open and a wikilink both open a note without touching the sidebar, so
after either it is showing somewhere else entirely. `revealCurrentInSidebar` is
the deliberate version and does both halves. It opens every folder above the
note — every one, or a note four deep is revealed
behind three closed folders — brings the column back if it is hidden, and sets
`revealTarget`.

The scroll is a **request the view answers**, because only the sidebar holds the
`ScrollViewReader` and only it knows which of its three lists is showing. It
observes the request twice for that reason: once at the top of the sidebar, to
put the file list back, and once inside the tree to scroll. The inner one is
`task(id:)` rather than `onChange`, because switching back from Tags builds the
tree *after* the request was made, and an `onChange` on a view that appears
later never sees the value it appeared because of.

`SidebarAnchor` wraps the path in a type of its own: the tree's rows come from
`ForEach` over `VaultItem`, whose `id` is that path, so a bare `.id(path)` would
put two elements under one identifier in the same scroll namespace.

A new note is **named in the sidebar**, in the row it is about to occupy.
⌘N and the sidebar's own button used to be two interactions for one act: a
modal asking for a name, and a row you type into. Only the sidebar can draw
that row, so ⌘N posts a request the view answers, the way `revealTarget`
works, and falls back to the prompt when the sidebar is hidden and there is
nowhere to type.

The row is **scrolled to**, through the same `revealTarget` request Reveal in
Sidebar uses. After ⌘N the sidebar is usually showing another folder entirely,
so a field appearing off screen reads as the note having been created nowhere.
The scroll waits for the *row*, not for a fixed delay: `reload` starts a rescan
and returns, so a note is on disk well before it is in the tree, and the
existing 60ms wait was only ever sized for the lazy stack building rows inside
folders that had just been expanded. Scrolling to an anchor that does not exist
yet scrolls nowhere and reports nothing, which is exactly how it failed.

The note is **not opened until it is named**. Opening it put a caret in the
editor while the caret that matters is in the sidebar row: two insertion
points, one of them the wrong place to type, which is also why the field went
unnoticed. Naming it opens it, at the path read back from the rename plan
rather than one rebuilt from the typed name, so where the file went and what
gets opened cannot disagree. Keeping the offered name is still naming it.

Naming in place writes the file **first**, so backing out of the field used to
leave an `Untitled.md` behind; a vault of a few months held six, in four
folders, none ever opened again. `discardUnnamedNote` takes it back, and every
guard on it is about being certain it is that file: still called `Untitled`,
still empty on disk, and, if it is the open note, nothing typed into it since.
The name check is the one that matters, because an empty note the reader named
looks like an abandoned one to every other test.
