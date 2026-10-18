# The iOS app

`HeftiOS` and its two extensions, as they differ from the Mac. The live
surface itself is shared and described in `EditingSurface.md`; this is what
sits around it on a phone.

## Building and seeing it

```bash
xcodebuild -scheme HeftiOS -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme HeftiOS -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcrun devicectl device install app --device <udid> <path>/HeftiOS.app
```

Nothing can tap the simulator from a script, so DEBUG builds read launch
variables (`SIMCTL_CHILD_` prefixed for `simctl launch`) that set a screen
up for a screenshot: `HEFT_IOS_VAULT` opens a folder without the picker,
`HEFT_IOS_TAB`, `HEFT_IOS_NOTE`, `HEFT_IOS_DAY`, `HEFT_IOS_FOLDED` place the
view, `HEFT_IOS_CARET` and `HEFT_IOS_SELECT` give the editor the keyboard,
`HEFT_IOS_TYPE` types through the delegate as the keyboard does (`⏎` is
Return), `HEFT_IOS_PASTE` inserts its text at once as a paste does, `HEFT_IOS_ACTIONS` runs editor actions by name, and `HEFT_IOS_NEW`
opens New Note with a name (`HEFT_IOS_NEW_KIND=folder` switches it to a folder, `HEFT_IOS_NEW_CONFIRM`
also creates it), `HEFT_IOS_SETTINGS` opens Settings on a page (`root`,
`appearance`, `vault`), `HEFT_IOS_ITEM_ACTION=rename|move|delete:<path>`
asks for one in Files, and `HEFT_IOS_RUN` carries one out after the first
scan (`rename:<path>:<name>`, `move:<path>:<folder>`, `delete:<path>`, `duplicate:<path>`). `HEFT_IOS_OPEN=<path>` opens a note the
way the Open Note intent does. Point them at
a copy of a vault: the editor saves.

## iPad

At full width the iPad has the Mac's layout, `PadRootView`: a sidebar with
the Files, Recent and Tags pill, search and the month at its foot, and the
note beside it. Narrowed in Split View or Slide Over it has the phone's
tabs; so does an iPhone in landscape. The sidebar reuses the phone's lists:
their rows are `NavigationLink(value:)`, which in a `List(selection:)`
select instead of pushing. `HEFT_IOS_PAD_MODE` picks the pill's mode, and
`HEFT_IOS_PAD_MONTH` opens the month, `HEFT_IOS_PAD_FORMAT` the Aa popover.
The iPadOS menu bar has the Mac's File, Format and View items with the
Mac's shortcuts (`HeftMenuCommands`), acting on the focused window's note
and sidebar through focused scene values.
On a wide iPad the editor's tools are in the note's bar, and the strip
above the keyboard shows only while it has suggestions: with a hardware
keyboard it spanned the whole window, sidebar included.

## Search

The Search tab and the iPad sidebar's search are the Mac's ⌘T bar,
`UniversalSearchList`, assembled from the core's pieces: `BarScope` for
the scopes and their prefixes, `CommandMatch` and `scoredSearch` ranking
commands, tags, folders and notes on one scale, the standard start list
before anything is typed, and text only once names found fewer than ten.
Ask is left out; its agent runs on the Mac. On the iPad it is a panel over
the window, `SearchPanel`, as ⌘T is on the Mac: in the sidebar it read as
part of Files, Recent and Tags. On the phone the scope chips are a bar
under the title; above the keyboard the tab's floating field covered them. Commands are iOS's own,
`MobileCommand`, over the window's `LibraryActions`.

## The vault

The Files picker hands over a security-scoped folder, kept as a bookmark in
the App Group `group.dev.stenglein.HeftMobile`. The share extension can read
the bookmark but iOS does not let it use it, so a share it cannot file is
queued there and the app files it on its next scan. The app also publishes a
note list there after every scan, which is both the share sheet's note
search and what the app shows at launch before its own scan lands.

The colours travel in the vault too, in `.heft/appearance.json` beside the
pins: the phone has no colours of its own, and the Mac adopts the file when
it reads a vault and writes it when its Appearance settings change. A vault
the Mac opens with default colours gets no file.

Renaming and moving go through `VaultRename`, so links follow as they do
on the Mac. Deleting tries the system Trash, which for iCloud Drive is the
Files app's Recently Deleted, and falls back to the vault's `.trash`, where
Obsidian keeps what it deletes.

A photo or file added from the keyboard strip goes where the Mac's standard
attachment plan puts it, named as the Mac names a pasted picture, and is
embedded on a line of its own after the caret's line.

Notes are donated to Spotlight after a scan that changed the tree, as
`NoteEntity`s; a tap on one runs `MobileOpenNoteIntent`, which is also the
Shortcuts and Siri action. The entity query finds the vault through
`NoteEntityQuery.vaultLocator`, which the app points at its bookmark.

The Today widget cannot open the vault either: the app writes
`TodaySnapshot` to the App Group after each scan and save, and the widget
draws that. `heft://today` and `heft://open?path=` open the calendar or a
note.

There is no file watcher on iOS. The app rescans on launch, on returning to
the foreground and after its own writes, starting from the Mac's
`IndexCache` so a scan reads only what changed.

## Saving

A note saves a second after typing stops and when it is left. A save is
written only over the text it was based on; a file that changed meanwhile
stops saving and offers Use Theirs or Keep Mine, because the Mac autosaves
and iCloud delivers that late.

## Handoff

The open note is offered as `HandoffNote`: its vault-relative path and the
vault folder's name, since the two apps reach the same vault by different
paths. It needs both apps signed by the same team, and the iPhone reads
the Mac app's team from its entitlements, which on macOS need a profile:
`bundle.sh` signs with a development profile and `Config/Heft.entitlements`
when a team is set. Releases carry neither, so a released Mac app hands off
to the phone but not back. The Mac makes the activity current itself
instead of setting `window.userActivity`, which Siri's pointer uses.

## Gotchas

- Restyle after a caret move or focus on the next run-loop pass, never
  inside the delegate callback: rewriting attributes while UIKit places a
  tap's caret makes it drop the tap, and the caret lands at the end.
- A range selection keeps the caret's reveal. Revealing the lines under a
  dragged handle changed their height mid-drag, and the text view scrolled
  to chase the handle.
- The calendar folds on the reader's own scrolling only. Folding resizes
  the note, which moves its scroll offset, and reacting to that made the
  two flicker against each other.
- The folded calendar's strip replaces the grid when the fold animation
  completes, not on a timer: the spring settles past its nominal duration.
- A selection made as the keyboard rises arrives before the keyboard strip
  has a width; measure it after layout or it scrolls nowhere.
- `calendar.day` and other new SF Symbols draw nothing on older systems;
  check `UIImage(systemName:)` and fall back.
- A `UIToolbar` as the keyboard accessory moves what does not fit into a
  "…" menu; the strip is a scroll view in a glass capsule for that reason.
