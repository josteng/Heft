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
  the vault scanner, moment.js date formatting, live-mode decorations, the file
  watcher, the draft mirror, the frecency ranking, and the agent CLI.
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

## Rules

Break one of these and something goes quietly wrong rather than failing.

- **`HeftCore` and `HeftVimCore` never import AppKit or SwiftUI.** That
  boundary is what lets the whole command line run without a window, and it is
  enforced by the fact that they do not link them.
- **The buffer *is* the file.** Markup is hidden by collapsing it — the
  characters keep their place in every offset and get a hairline font — so the
  text storage always equals the file byte for byte. Nothing is ever rewritten
  to make it render. Anything that would need rewriting is not a feature Heft
  can have; a line-break setting was removed for exactly this.
- **Never point the GUI at the real vault while testing. It autosaves.** Use
  `Scripts/run.sh --sandbox` with a disposable copy, or the read-only `stats`
  and `render` verbs. Without `--sandbox` a test launch also repoints where
  Spotlight capture files things.
- **Everything reads and writes preferences through `HeftDefaults.shared`,**
  never `UserDefaults.standard`, or `--sandbox` leaks. A test fails if any call
  site reaches for the latter.
- **`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`** is needed for
  `xcodebuild`, `actool` and `swift test`: `xcode-select` points at the Command
  Line Tools on this machine. `Scripts/bundle.sh` sets it for itself.
- **Launch the app detached** (`nohup … >/dev/null 2>&1 &` then `disown`), or a
  backgrounded GUI app holds the shell's stdout open and the caller blocks
  until it quits.
- **Every assertion is proven to fail under a deliberate defect.** A test that
  cannot be made to fail is not tested; several here passed by luck until they
  were mutated.
- **Check drawing by drawing.** `heft export` writes a note to PDF headlessly
  and `heft render` reports what the surface would draw, so a claim about a
  table or a formula can be looked at. `ImageRenderer` sees layout and custom
  drawing but not AppKit-backed controls; nothing in the suite reaches a real
  toolbar or a cursor.

## Where the rest is

`CLAUDE.md` is read on every request, so it holds what is always true. The
reasoning behind each area lives beside it and is worth reading *before*
changing that area, because most of it is a record of what was tried and did
not work:

| Read | Before touching |
| --- | --- |
| [`Docs/EditingSurface.md`](Docs/EditingSurface.md) | `LiveDecorator`, `RestyleScope`, `LiveStyler`, `LiveWidgets`, typing, tables |
| [`Docs/WindowsAndSettings.md`](Docs/WindowsAndSettings.md) | `AppModel`, the sidebar, any settings pane, renaming, startup |
| [`Docs/Proposals.md`](Docs/Proposals.md) | `AgentCLI`, `ProposalStore`, the review centre, `CommandLineSpec` |
| [`Docs/Gotchas.md`](Docs/Gotchas.md) | AppKit, TextKit, printing, preferences, the icon — and when something behaves impossibly |
| [`Docs/VimMode.md`](Docs/VimMode.md) | `HeftVimCore` |
| [`Docs/AgentIntegration.md`](Docs/AgentIntegration.md) | the agent-facing surface, as a user sees it |

`Docs/Gotchas.md` also carries the **known gaps**: what is deliberately not
finished, so a rough edge is not mistaken for a regression.

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
