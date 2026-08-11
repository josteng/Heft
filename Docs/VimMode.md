# Vim mode

Heft's Vim mode is experimental and is an original, native Swift implementation. It initially
follows `.obsidian/app.json`'s `vimMode` value; Settings → Vim can override that
with an app-wide preference. It does not embed JavaScript, Vim, Neovim, VimR,
XVim, or Zed.

## Architecture

`HeftVimCore` is Foundation-only and portable to a future iPadOS editor. Given
the source text, selection, and one normalized key, its state machine returns a
small transaction: edits, the next selection, and an optional host action.
`HeftTextKit2View` applies that transaction through the normal `NSTextView`
editing API. TextKit remains the only buffer and undo owner, so modal editing
does not fork autosave, Markdown styling, input methods, or undo history.

Command and Option shortcuts bypass the Vim engine. Insert mode also delegates
ordinary input to AppKit, retaining dead-key, composed-character, dictation,
completion, smart-typography, and accessibility behavior.

The enabled-by-default “Preserve Markdown structure in Vim edits” option is an
intentional Heft extension: `o`/`O` continue list, task, numbered, and quote
markers, while `cc`, `S`, and Visual-Line changes retain the current marker.
Turn it off for strict Vim line-opening and line-change behavior.

## Current command surface

- Modes: Normal, Insert, Replace, Visual, Visual Line, Visual Block,
  block-insert, and operator-pending.
- Counts and motions: `h j k l`, arrows, Space, Return, `w W b B e E`, `0 ^ $`,
  `gg G`, `+ - _`, `{ }`, `%`, `f F t T`, `; ,`.
- Operators: `d c y`, doubled line forms, and compositions such as `d2w`.
- Text objects: `iw aw iW aW`, quotes/backticks, parentheses, brackets, braces,
  and angle brackets.
- Editing: `i I a A o O R`, `x X s S D C Y`, `p P`, `r`, `~`, `J`, dot-repeat,
  and line indentation with `>>` / `<<`.
- Visual character/line delete, change, yank, paste-over-selection, and
  indentation with `>` / `<`.
- Visual Block (`Ctrl-V`) rectangular movement, delete/change/yank, and `I` to
  insert the same text on every selected line.
- `u`, Control-R, `zz`, `zt`, `zb`, and Control-F/B/D/U host actions.
- `/`, `?`, `n`, `N`, `*`, and `#` bridge to Heft's native find model.

Not yet implemented: Ex commands, named and system registers, mappings, macros,
marks/jump lists, full blockwise registers/put, and viewport-relative `H M L`
motions.

## Testing and licensing

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
