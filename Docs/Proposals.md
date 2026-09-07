# Proposals, and the command line behind them

The internal design. `Docs/AgentIntegration.md` is the same feature written
for whoever is using it; this is why it is shaped the way it is.

## Agent proposals

An agent does not edit the vault; it proposes, and the editor asks. `AgentCLI`
adds the agent verbs to the same headless dispatch in `Main.swift` that
`stats` and `render` use, so the integration is a CLI rather than a daemon.
`heft propose` takes the complete new body on stdin, not a patch: an agent
already has the finished text, and a full body cannot fail to apply.
`--replace` takes anchored `old`/`new` pairs where restating a long note would
be silly; `AnchoredEdit` resolves them against the note as it is now and
refuses an anchor matching more than once, and what reaches the store is still
a full-body proposal.

A proposal is one JSON file under `<vault>/.heft/proposals/`, which the vault
watcher already sees. `NoteDiff` turns it into hunks, each accepted or
rejected on its own. Three decisions carry it:

- The diff is against the note **as it is now**, never against what the agent
  read; `Proposal.isStale` says so when the note moved on.
- A partly reviewed proposal is a smaller proposal: `ProposalStore.settle`
  applies the accepted hunks, drops the rejected ones for good, and rewrites
  the rest against the updated note.
- An accepted change to the open note goes through the buffer and the normal
  autosave rather than writing the file under the editor.

An id is a **name**, not a UUID: `ProposalStore.identifier` slugs the summary,
or the note when there is none. A collision grows the name back rather than
numbering it, because five summaries from one batch share a long opening and
differ past the cut; only two identical summaries fall through to a number.
It is also the filename, so the slug can produce neither a slash, a dot nor an
empty string, and `match` answers `.missing` for an empty one, since
`heft drop "$ID"` with an empty `$ID` used to delete whichever proposal was
first. `drop` requires the whole id and `diff` accepts a prefix: a prefix
names a different set of proposals at different times, which is fine when the
cost of the wrong one is reading it and not for the verb that cannot be
undone.

#### Read before you replace

`propose` refuses a whole-body proposal for a note that changed since the
agent read it; otherwise a line typed between the read and the proposal came
back as an ordinary removal among the agent's hunks, and `isStale` could not
fire because `base` was captured at propose time. `ReadLog` records what
`heft read` handed over, one snapshot per note swept after a week, and `heft
changes` diffs it against the file now. It lives in Application Support, not
`.heft/`: a read snapshot is one machine's scratch state, and writing into an
iCloud vault on every read would sync for nobody's benefit. `HEFT_READ_LOG`
moves it for tests. `--replace` is exempt, since its anchors already fail if
the text they named has moved.

#### Kinds, groups, and the review centre

A proposal for a note that does not exist had no banner to appear in, and a
change across twelve notes was twelve unrelated proposals. So `Proposal.Kind`
names edit, create, delete and move, and `Proposal.Group` joins several into
one change, keyed by the slug of its summary so an agent joins by repeating
the words. A group of one is not a group. `Proposal` decodes by hand, because
the synthesised `Codable` would make every earlier proposal vanish from the
list; a file from before kinds is an edit, or a create when it had no base.

One note holds one pending proposal; a second is refused, because both would
be diffed against the note as it is now and accepting either leaves the
other's hunks reading as an undo. There is no amend verb: an id is a name
shown in the sidebar, and a name that quietly changes meaning makes the list
lie. `--replacing <id>` writes the new proposal before removing the old, so a
failed write leaves the old standing, and frees the id first so the name is
kept.

`createdAt` is stored to the millisecond, because five proposals from one run
land inside one second and tied on the id tiebreak; the decoder reads both
spellings.

`ReviewCenter` sits at the top of the sidebar and is the only place that can
show a change with no note behind it. Accept and discard for a group are
offered under the group when it is open, not on its row, which is the
disclosure control. The banner above a note stays, since seeing a diff where
you are reading is the part that worked, with one banner per note ever: a
grouped change points at the centre, and a delete or move never appears in a
banner. A destructive change is confirmed once, at the moment it is committed
to: a delete reviewed in its own sheet has been confirmed by that sheet; a
group's deletes are confirmed once before anything is applied, naming every
file, and cancelling cancels the whole group. Edits are applied before moves,
or an edit would be written to a path the move took away. Deliberately not
atomic: refusing eleven changes because the twelfth is stale is worse, and
what is left unanswered stays as a smaller change. `performMove` is split out
of `rename` so an accepted move repoints the same links.

#### Reading a hunk, as opposed to deciding it

`InlineDiff` marks which words moved inside a changed line. It is display
only, and separate from `NoteDiff` on purpose: the hunk stays what a person
decides about, for the reason written there, and what was missing was never a
finer decision but a way to read the one on offer. `NoteDiff.apply` never sees
a span.

Two floors decide how fine the marking goes, and both exist because the
tempting answer is worse than none. Under 35% of tokens in common, two lines
paired only by position are left unmarked rather than painted end to end,
which is how a wrong pairing costs a comparison instead of a wrong answer.
Within a stretch where one word replaced one word, the comparison drops to
letters only above 70% of letters in common: a plain character diff of `takes`
against `keeps` keeps the k, e and s and stripes both words with fragments,
which reads as noise, while `window` against `wiNdow` is one letter and is
exactly what the reader wants. A mark never begins inside a word, so a space
joins two changes only when both are whole tokens.

#### Teaching the agent

`agent-setup` writes `CLAUDE.md`, `AGENTS.md` and `.claude/settings.json`
through `AgentGuide.install`, the one place that merges, backs up and words
errors. The two guides carry the same generated section between markers,
drawn as a labelled rule in the editor so the boundary is visible; anything
typed inside is saved to `.heft/claude-md/` before the section is replaced.
`AgentPermissions` denies `Edit(**)` and allows `Bash(heft:*)`. One rule,
spelled `Edit`: Claude Code matches a path-scoped rule against the file a tool
would touch and only `Edit(path)` takes part, covering Write and NotebookEdit;
`Write(**)` is rejected as matching nothing and a settings file carrying it is
set aside whole. The rule carries a path because the workflow writes a scratch
file in `/tmp` and reads it back with `--from`. Codex has no per-project
equivalent, so for it the rule lives in `AGENTS.md`.

The guide is stamped with a version, because it is copied into the vault and
frozen there. Every agent verb writes one line to stderr when the vault is
behind, and the review centre offers a refresh; nothing rewrites the user's
file on its own. Bump `AgentGuide.version` whenever the wording an agent
depends on changes.

## One place the verbs are declared

`CommandLineSpec` in HeftCore is the only list of what the command line can
do. `heft help` prints it, `heft help --json` is what an agent reads, and
`Scripts/install.sh` asks the built binary for `help --verbs` and bakes the
answer into the shell wrapper. The wrapper's verb list was once a hand-written
copy and drifted the first time a verb was added, rewriting `heft export` to
`heft open export`. Dispatch in `Main.swift` is still hand-written, so two
tests hold the invariant: every dispatched verb is in the spec, and every
declared verb is dispatched.
