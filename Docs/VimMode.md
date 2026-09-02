# Vim mode

Heft's Vim mode is experimental and is an original, native Swift implementation. It initially
follows `.obsidian/app.json`'s `vimMode` value; Settings → Vim can override that
with an app-wide preference. It does not embed JavaScript, Vim, Neovim, VimR,
XVim, or Zed.

## Architecture

`HeftVimCore` is Foundation-only and portable to a future iPadOS editor. Given
the source text, selection, and one normalized key, its state machine returns a
small transaction: edits, the next selection, and an optional host action.

`VimText` answers character questions; `VimTextObjects` answers *span* questions.
Sentences, paragraphs and counted word objects are all the same shape of problem
— cut the document into an alternating run of content and separator, then ask
which run the caret is in and how many to take — so they share one walk rather
than three similar ones.
`HeftTextKit2View` applies that transaction through the normal `NSTextView`
editing API. TextKit remains the only buffer and undo owner, so modal editing
does not fork autosave, Markdown styling, input methods, or undo history.

Command and Option shortcuts bypass the Vim engine. Insert mode also delegates
ordinary input to AppKit, retaining dead-key, composed-character, dictation,
completion, smart-typography, and accessibility behavior.

Two enabled-by-default options are intentional Heft extensions, and both can be
turned off for strict Vim.

“Preserve Markdown structure in Vim edits”: `o`/`O` continue list, task,
numbered, and quote markers, while `cc`, `S`, and Visual-Line changes retain the
current marker.

“Match typographic quotes in text objects”: `i"`/`a"` also match `“…”` and
`«…»`, and `i'`/`a'` also match `‘…’`. This exists because the two features
collide: Smart Typography rewrites `"` to `“ ”` as the note is written, so by
the time the caret is inside a quotation the character `ci"` looks for is no
longer in the file, and in a note written in this editor the command simply
never works. `«…»` is included with `"` because the Typing pane produces it from
`<<`/`>>` and no other object reaches it; `` i` `` is unchanged, since backticks
are never rewritten.

Two details make it safe. The straight form is tried first, so a line mixing
both kinds still resolves to whichever quotation the caret is actually in. And
the curly forms are scanned as *open-then-close* rather than as a run of
identical characters, so the `’` in `it’s` pairs with nothing and cannot swallow
half a sentence — which is also why the option is on by default.

The flag lives on `VimEngine.options` rather than being applied by the host
afterwards, the way the Markdown-structure option is: it changes what a text
object *matches*, so it has to be in scope while the object is resolved.

## Current command surface

- Modes: Normal, Insert, Replace, Visual, Visual Line, Visual Block,
  block-insert, and operator-pending.
- Counts and motions: `h j k l`, arrows, Space, Return, `w W b B e E`, `ge gE`,
  `0 ^ $`, `gg G`, `+ - _`, `{ }`, `( )`, `%`, `f F t T`, `; ,`, `H M L`.
- Operators: `d c y`, the case operators `gu gU g~`, doubled line forms
  (including `guu`, `gUU`, `g~~` and their `gugu` spellings), and compositions
  such as `d2w`.
- Text objects: `iw aw iW aW`, quotes/backticks (straight and, by default, the
  typeset forms), parentheses, brackets, braces, angle brackets, sentences
  (`is as`), paragraphs (`ip ap`), and HTML/XML tag blocks (`it at`). All of
  them take counts, and a count that runs past what is there fails the object
  rather than doing less, the way Vim does.
- Registers: `"a`–`"z` with `"A`–`"Z` appending, the yank register `"0`, the
  shifting delete ring `"1`–`"9`, the small-delete register `"-`, and the black
  hole `"_`.
- Marks: `m{a-zA-Z}`, `` `x `` (exact) and `'x` (linewise), both usable as
  operator motions, plus ``` `` ``` and `''` for the position before the last
  mark jump.
- Macros: `q{a-z}` to record (`q{A-Z}` appends), `q` to stop, `@x` and `@@` to
  replay, with counts. Insert-mode typing is part of the recording.
- Editing: `i I a A o O R`, `x X s S D C Y`, `p P`, `r`, `~`, `J`, dot-repeat,
  and line indentation with `>>` / `<<`.
- Visual character/line delete, change, yank, paste-over-selection, case with
  `u U ~`, and indentation with `>` / `<`.
- Visual Block (`Ctrl-V`) rectangular movement, delete/change/yank, and `I` to
  insert the same text on every selected line.
- `u`, Control-R, `zz`, `zt`, `zb`, and Control-F/B/D/U host actions.
- `/`, `?`, `n`, `N`, `*`, and `#` bridge to Heft's native find model.

Two of these need the view rather than the buffer, and reach it through
`VimHostAction`: `H`/`M`/`L` ask the text view which lines are on screen, and
`@x` hands its recorded keys back to the host to feed through the engine one at
a time, because each key must see the document the one before it produced and
the engine never owns a buffer.

Not yet implemented: Ex commands, system/clipboard registers, mappings, jump
lists beyond the single previous-position mark, and full blockwise
registers/put.

Known differences from Vim, all narrow, and all with the caret somewhere it
rarely is when these commands are typed:

- Vim treats a blank line as a word and as a sentence that runs on into the next
  paragraph. Heft stops at the blank line, so `is`, `as`, `aw` and `ge` all take
  less than Vim would when the caret is sitting on one. Counted `2is`/`2as`
  likewise stop at the end of their paragraph.
- `e`, and therefore `de` and `gUe`, do not cross to the next line from the last
  word of one. This predates the objects and is shared by every operator that
  composes with `e`.
- Vim's exclusive-motion-to-column-one rule is only applied to forward motions,
  so `d(` back to the start of a line takes the preceding line break with it.
- Vim promotes a charwise range covering whole lines to linewise; Heft does not,
  which shows up as `4daw` over three whole lines leaving an empty line behind.
  This was implemented and then reverted: it also promoted `yis` on the last
  line of a buffer, which made `yisP` paste a line where Vim pastes inline, and
  the common case is worth more than the rare one.
- After a *failed* counted object (`2caw` with only one word left), the caret
  ends one character from where Vim leaves it. The object itself is right — the
  buffer is untouched — and this is only visible to a key typed straight after.
- `2i"` is not implemented; Vim reads it as "the quotation including its
  quotes". `f"`, `t"` and `;` still search for the literal character typed, so
  they do not find a curly quote the way the text objects now do.
- Between two *curly* quotations, `ci"` selects the next quotation rather than
  the gap between them. Straight quotes follow Vim exactly here (the gap); for
  the curly forms there is no Vim behaviour to match, and open/close characters
  make the next quotation the more useful reading.

## Testing and licensing

Vim's prose objects carry more folklore than any other part of this surface —
a sentence filling its line takes the line break with it while one that does not
takes the space after it instead, `2aw` on a space keeps that space in
`alpha (beta` but not in `one two three`, a single line break is stepped over
where a blank line is counted — so the differential tests for them check *every*
cursor position in each fixture rather than a chosen few. Each of those rules
was read off the oracle, not off the documentation.

The checked-in fixture suite is original project code. If `nvim` is present on
`PATH` or in a conventional Homebrew/system location, additional tests invoke
`nvim --clean --headless` as an external process and compare final buffers and
cursor positions for representative commands, motion and text-object matrices,
and a generated 216-case cross-product of delete/change/yank, word/line/vertical
motions, and counts on either side of the operator. It skips when Neovim is
absent; focused local regressions preserve every discrepancy the matrix has
found so far even on machines without Neovim.

Neovim is never linked, imported, copied, or shipped. Invoking a separately
installed GPL program during development does not make Heft a derivative work;
the test exchanges only temporary user-authored text files and process
arguments. No Zed, Vim, Neovim, VimR, XVim, or CodeMirror source or fixtures are
vendored. If third-party fixtures are ever added, their license and attribution
must be reviewed and preserved separately first.

The real-world edge corpus was planned by reviewing the behavior categories in
the MIT-licensed [CodeMirror-Vim suite at 8640966](https://github.com/replit/codemirror-vim/blob/8640966b6977f84d2197e6adfd521fb737184587/packages/codemirror-vim-core/test/vim_test.js)
and [VSCodeVim suite at f8bd0bc](https://github.com/VSCodeVim/Vim/tree/f8bd0bcb6b6fdb9f0590a6dfe0cf32aa3f543cb5/test).
Heft copies neither suite's source, fixture text, nor expected output: its 67
edge scenarios use original buffers and obtain expectations from the external
Neovim oracle. Each discrepancy also becomes a small local regression that runs
without Neovim. Zed's Vim tests remain excluded because most Zed editor source
is GPL-3.0. This keeps the shipping source and checked-in tests straightforward
to license while still benefiting from mature projects' coverage maps.
