# Templates, placeholders and slides

Two features in Heft look like "templating" and are not the same system, plus
a third that is really just a way of reading a note. This is what each one is
and where it is configured.

## 1. Daily-note templates

The only place Heft expands a whole file. A daily note is created from a
template the *vault* configures, not the app: Heft reads Obsidian's own
`.obsidian/daily-notes.json`, so a vault that already worked in Obsidian
keeps working here untouched.

Three settings, all in **File ▸ Daily Note Settings…** (or the warning
triangle on the calendar, which offers to create them):

| Setting | Meaning | Example |
|---|---|---|
| Daily notes folder | Where notes are filed | `Daily` |
| Filename | The note's name, in moment tokens | `YYYY-MM-DD` |
| Template file | The note to copy from | `Templates/Daily Note.md` |

With no template configured, a new daily note gets a plain `# <title>`
heading. Nothing is ever overwritten: if the note for that day already
exists, it is opened as it is.

Check it without the GUI:

```bash
swift run Heft daily <vault> 2026-09-03
```

### Placeholders

Expanded when the note is created:

| Placeholder | Becomes |
|---|---|
| `{{title}}` | The note's filename, without `.md` |
| `{{date}}` | The date in the configured filename format |
| `{{date:FORMAT}}` | The date in `FORMAT` |
| `{{time}}` | The time |
| `{{time:FORMAT}}` | The time in `FORMAT` |

An unknown placeholder is left in the note exactly as written, rather than
being silently deleted, so a typo is visible instead of destructive.

### The daily-log marker

```markdown
<!-- heft:daily-log -->
```

On its own line in a template, this is where captures land. Anything filed
with **⇧⌘I**, "Add to Today's Note" from Spotlight, or the Shortcuts action is
inserted *immediately above* it, so the marker stays the insertion point and
the log stays in the order it happened. Without a marker, captures are
appended to the end of the note.

A note may end up with more than one — a pasted body or an accepted agent
proposal can bring its own. The **last** one wins, so a second marker
appearing above the first cannot split a day's log in two.

## 2. Format tokens

Filenames and every `{{date:…}}` use **moment.js** tokens, because that is
what Obsidian uses. They are *not* ICU tokens, and several mean different
things in the two systems: moment `DD` is day-of-month where ICU `DD` is
day-of-year, and moment `WW` is the ISO week where ICU `WW` is week-of-month.
Heft implements the moment tokens directly rather than routing them through
`DateFormatter`, so a format copied from an Obsidian vault means what it did
there.

| | Tokens |
|---|---|
| Year | `YYYY` `YY`, ISO week-year `GGGG` `GG` |
| Month | `MMMM` `MMM` `MM` `M` |
| Day of month | `DD` `D`, ordinal `Do` |
| Day of year | `DDDD` `DDD` |
| Weekday | `dddd` `ddd` `dd` `d` |
| ISO week | `WW` `W` (also `ww` `w`) |
| Hour | `HH` `H` (24h), `hh` `h` (12h) |
| Minute, second | `mm` `m`, `ss` `s`, `SSS` |
| Meridiem | `A` `a` |
| Unix time | `X` (seconds), `x` (milliseconds) |

Literal text goes in square brackets: `YYYY-[W]WW` gives `2026-W36`.

The same tokens answer in three places, because they go through the same
`MomentFormat`: a daily-note filename and template, the replacement text of a
typing substitution, and the startup note in **Settings ▸ Startup**, where
`Weeks/{{date:GGGG-[W]WW}}.md` opens this week's note on launch.

## 3. Typing substitutions

The other thing that looks like templating, and the one that is *not*
Obsidian's. **Settings ▸ Typing** holds a table of `trigger → replacement`
rules that fire as you type, alongside the eight built-in groups (arrows,
dashes, quotes, and so on).

A replacement goes through the same placeholder expansion as a template, so
`{{date:YYYY-MM-DD}}` means there what it means in a daily note. It has one
token of its own:

| Placeholder | Meaning |
|---|---|
| `{{caret}}` | Where the caret is left, and then removed |

That is what makes a rule a snippet rather than a second set of arrows: a
trigger can expand into a whole code fence with the caret already inside it.

Each rule chooses when it fires:

- **After a word** (the default) waits for a space, punctuation or Return,
  the way macOS text replacement does. A word-shaped trigger needs this, or
  it goes off inside longer words.
- **Immediately** replaces the moment the trigger is complete. Right for
  symbol-shaped triggers, wrong for anything that spells a word.

**Add from Library** offers ready-made rules (today's daily-note link, a
timed log entry, a code block) as ordinary editable rows. They are the
fastest way to see what the placeholders do.

Nothing fires inside code, maths, frontmatter, wiki links, link
destinations, tags or URLs.

## 4. Presenting a note

Not templating at all, but it uses `---` and that is worth saying plainly.

**Start presentation** in the command palette (⌘P) opens the current note as
a slide deck. The note is split at **top-level thematic breaks**: a `---`,
`***` or `___` on its own line starts the next slide.

The three `---` that are *not* slide breaks:

- The `---` fencing YAML frontmatter at the top of the file.
- Any `---` inside a fenced code block.
- The `---` delimiter row of a table.

All three are already distinguished by the parser, so a note with
frontmatter and a table does not open as a deck full of blank slides.

There is nothing to configure and no separate file format: any note is a
deck, and a note with no `---` in it is a deck of one slide.
