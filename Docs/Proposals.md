# Proposals, and the command line behind them

The internal design. `Docs/AgentIntegration.md` is the same feature written
for whoever is using it; this is why it is shaped the way it is.

## Agent proposals

An agent does not edit the vault; it proposes, and the editor asks. `AgentCLI`
adds `propose`, `proposals`, `diff`, `drop`, `read`, `find`, `changes` and
`attachment` to the same headless dispatch in `Main.swift` that `stats` and
`render` use, so the whole integration is a CLI rather than a daemon or a port.
`heft propose` takes the **complete new body** on stdin, not a patch: an agent
already has the finished text, and a full body cannot fail to apply. Where that
would mean restating a long note to change a paragraph, `--replace` takes
anchored `old`/`new` pairs instead; `AnchoredEdit` resolves them against the
note as it is now and refuses an anchor matching more than once, so a bad anchor
fails at the command rather than at review time and what reaches the store is
still a full-body proposal.

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

An id is a **name**, not a UUID: `ProposalStore.identifier` slugs the summary,
or the note when there is no summary, because the default summary is the same
words every time. A collision **grows the name back** rather than numbering it:
the slug is cut at 40 characters between words, and five summaries written in
one batch share a long opening and differ past the cut, so `-2` carried none of
what told them apart. Colliding ids give back the words the cut took, one at a
time, and stop at the first free name; only two genuinely identical summaries
fall through to a number. It is also the filename, so the slug can produce neither a
slash, a dot nor an empty string. `ProposalStore.match` resolves it, and
answers `.missing` for an empty one — `heft drop "$ID"` from a shell that
expanded `$ID` to nothing used to delete whichever proposal was first, and
report success.

`drop` passes `exactly:`, and `diff` does not. A prefix names a *different* set
of proposals at different times: one that is unique today deletes something else
next week, and the ambiguity check only ever sees collisions that exist while it
runs. That is a fine trade where the cost of the wrong one is reading it, and
not for the verb that cannot be undone — and the reason prefixes existed at all,
that nobody can type a UUID, went away when ids became words.

`Docs/AgentIntegration.md` has the verbs and the `CLAUDE.md` snippet that makes
Claude Code reach for `propose` instead of `Write`.

#### Read before you replace

`propose` refuses a whole-body proposal for a note that changed since the agent
read it. Without that, a line typed between the read and the proposal came back
as an ordinary removal among the agent's own hunks, with nothing to say the
agent had never seen it — `base` was captured at *propose* time, so `isStale`
could not fire for that window at all.

`ReadLog` records what `heft read` handed over, and the same record answers the
question an agent could not ask before: `heft changes` diffs the last read
against the file now. One snapshot per note, replaced on each read and swept
after a week.

It lives in **Application Support, not `.heft/`**. A proposal is addressed to
the reader and belongs with their vault; a read snapshot is one machine's
scratch state, and writing a file into an iCloud vault on every `heft read`
would sync a file per note read for nobody's benefit. `HEFT_READ_LOG` moves it,
which is how the CLI checks drive the real binary without writing into the
reader's own store.

`--replace` is exempt, because its anchors are resolved against the current
note and fail if the text they named has moved, which is the stricter test.

#### Kinds, groups, and the review centre

A proposal used to be one note's new body, reviewed in a banner above that note,
and two things ran that out. A proposal for a note that **does not exist** had
no note to draw a banner above, so it could not be reached from the app at all —
found by proposing this vault's own TODO note and then having to write it by
hand. And a change across twelve notes was twelve unrelated proposals: accepting
seven left the vault half-changed, with nothing recording that they belonged
together.

So `Proposal.Kind` names edit, create, delete and move, and `Proposal.Group`
joins several into one change. The group's id is the slug of its summary, which
is what lets an agent join by repeating the same words rather than by passing an
id around; a group of one is not a group, because a heading with one row under
it is a fold with nothing in it. `ProposalStore.sort` is pure and returns the
three things a list shows.

`Proposal` decodes **by hand**. The synthesised `Codable` requires every field,
so adding these would have made every proposal written before them undecodable,
and the failure mode is somebody's pending change silently vanishing from the
list. A file from before kinds carried a body, so it is an edit — or a create
when it had no base, which is exactly what nil `base` used to mean. Same lesson
as `PDFExportOptions` and `TypingSettings`.

One note holds **one pending proposal**. `propose` refuses a second, naming
the one in the way, because both are diffed against the note as it is now:
accepting either leaves the other asking for a note it was never rebased onto,
and its hunks read as an attempt to undo what was just accepted. There is no
amend verb, deliberately. An id is a *name*, printed by `heft proposals` and
shown in the sidebar, so a name that quietly comes to mean something else makes
the review list lie about what it is asking. `--replacing <id>` is the drop and
the propose in one command: it writes the new proposal before removing the old
one, so a failed write leaves the old standing rather than neither, and it
frees the replaced id first so re-proposing under the same summary keeps the
name instead of returning `tighten-the-opening-2` beside a deleted
`tighten-the-opening`.

`createdAt` is stored to the millisecond, not the second. Five proposals from
one agent run land inside one second, so every one of them tied and the id
tiebreak decided the order: a group proposed Index-first came back
alphabetically. The tiebreak stays, since it is what stops the list reshuffling
between two reads. The decoder reads both spellings, or every proposal already
waiting in somebody's vault would vanish from the list.

`ReviewCenter` sits at the top of the sidebar and is the only place that can
show a change with no note behind it. Accepting or discarding a whole group is
offered **under the group when it is open**, not on the group's own row: that
row is the disclosure control, and hanging a destructive button off a control
whose job is to toggle invites the misclick. It was reachable only from a
context menu, which is not an affordance — nobody found it, and Accept All is
the answer to the half-applied group that applying a group non-atomically
otherwise leaves. The **banner stays**, because seeing a
diff where you are reading it is the part that already worked. The rule that
keeps them from fighting is *one banner per note, ever*: a change belonging to a
group says so on its banner and points at the centre, and a delete or a move
never appears in a banner at all — a bar over the page offering to delete the
page is the wrong place to decide that.

A destructive change is confirmed **once**, at the moment it is committed to,
and never twice for the same commitment. Reviewing a delete in its own sheet
*is* that moment: the sheet names the file and says where it goes, so its
button reads "Move to Trash" rather than "Apply" and no alert follows it. A
group's deletes are confirmed once, before anything is applied, naming every
file. The per-file alert is right when a person points at a note and asks
for it to go; accepting a group is a different gesture, answered as a list, and
four identical alerts in a row is how a confirmation stops being read. It still
asks, because Accept All is one click on a row and that alert is the only place
those files are named as a consequence rather than as a proposal, and
cancelling cancels the whole group rather than leaving its edits in and its
deletes out. Deleting a note from the sidebar asks, since nothing else named
it.

Accepting a group applies its **edits before its moves**, or an edit would be
written to a path the move had already taken away. It is deliberately **not
atomic**: a half-applied rename across twelve notes is bad, but refusing to
apply eleven because the twelfth is stale is worse, and the existing rule
already covers it — what is left unanswered stays as a smaller change.

`performMove` is split out of `rename` so an accepted move takes the same road
and repoints the same links: a rename is a move whose destination happens to be
the same folder.

The two markers are **drawn as a labelled rule** rather than hidden with the
other HTML comments, and reveal their source when the caret is on their line
like any other block. Without that the boundary is invisible, and a note typed
at what looks like the end of the file lands on managed ground; with it,
pressing Return at the end of the rendered marker lands *after* it. Anything
typed inside anyway is saved to `.heft/claude-md/` before the section is
replaced.

`agent-setup` writes **three files**: `CLAUDE.md`, `AGENTS.md`, and
`.claude/settings.json`. Two guides because Claude Code reads one and Codex and
most of the rest read the other, and the same generated section in both because
generated text cannot drift; each keeps its own preamble, which is the user's.
`AgentGuide.install` is the one place that does it — `Main.swift` and `AppModel`
each carried a copy of the merge, the back-up and the error wording, and a
second file would have made that four.

`AgentPermissions` is what turns the main instruction from a request into a
rule. `Edit(**)` is denied and `Bash(heft:*)` is allowed. One rule, because
Claude Code matches a path-scoped rule against the file a tool would touch and
only `Edit(path)` takes part in that check, so it covers Write and NotebookEdit
too; `Write(**)` and `NotebookEdit(**)` are rejected as rules that match
nothing, and a settings file carrying one is set aside whole, leaving the vault
with no rule at all. `AgentPermissions.superseded` removes the two Heft wrote
until guide version 10. The deny rules carry a **path** rather than being
bare tool names, because the workflow the guide teaches writes a scratch file in
`/tmp` and reads it back with `--from`: denying the tools outright would make
the setup that enforces the contract the setup that prevents following it. The
file is merged into, never replaced, and one that is not valid JSON is left
alone. Codex has no per-project equivalent, so for it the rule lives in
`AGENTS.md` and is followed rather than enforced.

The guide is **stamped with a version**, because it is copied into the user's
vault and frozen there: an upgraded Heft cannot reach it, so a vault set up a
year ago would go on describing a command line that no longer exists. Every
agent verb checks the stamp and writes one line to *stderr* when the vault is
behind, naming `heft agent-setup` as the fix; the editor offers the same as a
refresh banner. Nothing rewrites `CLAUDE.md` on its own — it is the user's
file and may hold their own instructions, which is the same rule proposals
exist to enforce. Bump `AgentGuide.version` whenever the wording an agent
depends on changes.

## One place the verbs are declared

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
