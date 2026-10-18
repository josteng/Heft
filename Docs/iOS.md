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
Return), `HEFT_IOS_ACTIONS` runs editor actions by name, and `HEFT_IOS_NEW`
opens New Note with a name (`HEFT_IOS_NEW_KIND=folder` switches it to a folder, `HEFT_IOS_NEW_CONFIRM`
also creates it). Point them at
a copy of a vault: the editor saves.

## The vault

The Files picker hands over a security-scoped folder, kept as a bookmark in
the App Group `group.dev.stenglein.HeftMobile`. The share extension can read
the bookmark but iOS does not let it use it, so a share it cannot file is
queued there and the app files it on its next scan. The app also publishes a
note list there after every scan, which is both the share sheet's note
search and what the app shows at launch before its own scan lands.

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
paths. It needs both apps signed by the same team; a Mac build signed
ad hoc never sees the phone. The Mac makes the activity current itself
instead of setting `window.userActivity`, which Siri's pointer uses.

## Gotchas

- Restyle after a caret move or focus on the next run-loop pass, never
  inside the delegate callback: rewriting attributes while UIKit places a
  tap's caret makes it drop the tap, and the caret lands at the end.
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
