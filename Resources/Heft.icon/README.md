# Heft.icon

The app icon, in the layered format macOS 26 expects.

`icon.json` describes the icon; `Assets/` holds the vector layers. The system —
not this file — draws the rounded-rect shape, the Liquid Glass specular
highlight and the shadow, which is why the SVGs carry only the spine and the
text rows. Drawing our own squircle here would produce a rounded rectangle
inside a rounded rectangle.

The icon is full-bleed, the shape Notes and TextEdit use: there is no inset
glyph, and **the paper is the background `fill` rather than a layer**. That
leaves the system squircle's corners as the only corners in the icon. The layers
run to the canvas edge; the system clips them.

**The rows are a single mid charcoal, and that is what makes both appearances
work.** The paper flips — cream in light, near-black in dark, because the system
paints its own dark ground — while `#45424E` stays put, so it reads as dark
writing on a white page in light and as light writing on a black page in dark.
One colour, both readings, no second artwork.

That indirection is necessary, not clever: **a layer cannot vary by appearance**
(see the note below), so pure black rows would vanish in dark and pure white
rows would vanish in light. Only a mid tone survives both grounds. The charcoal
measures 2.43 : 1 in light and 2.51 : 1 in dark — deliberately balanced, and
both better than the 2.00 : 1 an indigo managed in light. Apple ships Notes'
rules at 1.33 : 1.

Open it with Icon Composer (bundled inside Xcode, under
`Xcode.app/Contents/Applications/`) to edit it visually, or edit `icon.json` by
hand — the format is documented below well enough to do so.

## Building

`Scripts/bundle.sh` compiles this with `actool`, which produces:

- `Assets.car` — the layered icon, holding the light, dark and tinted variants
  the system switches between
- `Heft.icns` — a flat fallback, generated from the same source, for macOS
  before 26
- the `CFBundleIconName` and `CFBundleIconFile` keys, merged into `Info.plist`

Both go into the bundle: `CFBundleIconName` is what macOS 26 reads, and the
`.icns` is what everything earlier falls back to.

`actool` ships with Xcode, not with the Command Line Tools. `bundle.sh` finds it
through `DEVELOPER_DIR` without changing the machine's `xcode-select` setting,
and falls back to a bundle with no icon if Xcode is absent, rather than failing
the build.

## Format notes

Learned by reading `IconComposerFoundation` and by compiling against `actool`,
since the schema is not published:

- Colours are `<colorspace>:r,g,b,a` with components in 0…1. A bare hex string
  is rejected with "Invalid color encoding, missing ':' delimiter".
- `fill` takes one of `solid`, `linear-gradient`, `automatic-gradient`, `none`.
- Any keyed property has a `<key>-specializations` sibling, an array of
  `{ "appearance": …, "value": … }`. Appearances are `light`, `dark` and
  `tinted`; anything not specialized is derived from the base automatically.
- A maximum of four groups is allowed; each group is one depth plane.
- **Within a group, the first layer in the array is the frontmost**, not the
  last. It does not show in this icon, whose two layers do not overlap, but it
  cost a design pass in an earlier inset version: a cover listed first hid the
  page it was meant to hold, and `actool` gave no warning at all.
- **A group is a plane of glass, so a layer in a front group is tinted by the
  group behind it.** Splitting the cover and the page into two groups to buy
  them separate shadows turned the white page orange, and setting
  `translucency.enabled` to `false` on the front group did not stop it — the
  tinting is what stacking planes *means*. Anything that has to keep its own
  colour against another layer belongs in the same group as that layer.
- **Nothing renders differently for `dark` on macOS, however it is specialized.**
  `IconComposerFoundation` really does define `fill-`, `image-name-`, `hidden-`,
  `opacity-`, `blend-mode-`, `position-` and `shadow-specializations`, and
  `actool` compiles them — a layer `fill` specialized red-for-light and
  green-for-dark adds a sixth colour to the `Assets.car`. It then renders **red
  in both**. The same is true of `hidden-specializations` used to swap between
  two prepared layers, and of the background `fill`. A layer `fill` with no
  specialization *does* work, so the mechanism is live; it is only the `dark`
  branch that never arrives. macOS derives the dark appearance itself — layers
  keep their colours, the background goes near-black — and that derivation is
  not overridable. Design one artwork that works on both grounds; the
  specializations are worth keeping only for iOS.
- **On macOS the dark background is a neutral ground the system paints, not the
  one you specify.** `fill-specializations` for `dark` is inert here: an icon
  compiled with a deliberately garish red-to-green dark gradient renders
  identically to this one. Apple's own icons behave the same way — in dark mode
  Notes keeps its yellow band (a layer) but its paper (the fill) goes black.
  The specialization is kept for iOS, where it is honoured. Design the dark
  variant by assuming near-black behind the layers.

## Previewing a change

`actool` is enough to see the real thing, without building the app. Compiling
any `.icon` emits both an `Assets.car` and a flat `Heft.icns`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun actool Resources/Heft.icon \
    --compile /tmp/icon --app-icon Heft --output-partial-info-plist /tmp/icon/p.plist \
    --platform macosx --minimum-deployment-target 26.0 --output-format human-readable-text
sips -s format png --resampleWidth 512 /tmp/icon/Heft.icns --out /tmp/icon/light.png
```

The `.icns` is the **light** composite. For the **dark** one, drop the compiled
`Assets.car` into a stub `.app` with `CFBundleIconName` set and ask
`NSWorkspace.icon(forFile:)` for it: that goes through IconServices and returns
what the Dock would draw, specular and shadow included. It returns the current
system appearance regardless of any `performAsCurrentDrawingAppearance` you wrap
it in, so it shows the appearance the machine is actually in. Snapshotting
`/System/Applications/Mail.app` the same way is a good check that the pipeline is
faithful before trusting it.

**IconServices caches per bundle identifier, so rebuilding the app into the same
path hands back the *old* icon** — silently, and it looks like a real render.
This wasted a comparison: two designs came back identical because the second was
the first one cached. Give each stub bundle its own `CFBundleIdentifier` when
comparing designs, and treat "the change had no effect" as a cache hit until
proven otherwise. The `.icns` route is not cached and is the tiebreaker.

The `tinted` appearance has no offline preview here; it is derived from layer
luminance, so keep the layers distinct in luminance and not only in hue.

## Judging a change

Three checks. They disagree, which is the point — each catches something the
others miss.

**Detail, at 32pt.** Downsample to 32 and blow that back up with
nearest-neighbour interpolation; anything that turns to mush there is mush in a
Finder list and in ⌘-Tab. Four text rows survive here because the full-bleed
canvas gives them length. The same four rows on an inset page did not, and had
to come down to three. Row count is not a fixed rule; it is whatever passes this
test at the size the rows actually get. Detail is cheap to add and always costs
legibility first.

**Contrast, bar against paper, in *both* appearances.** The rows sit at 2.43 : 1
in light and 2.51 : 1 in dark; a change that lifts one usually drops the other,
so judge them as a pair rather than tuning the one in front of you. Sample by
coordinate, not by luminance histogram: a histogram assumes the rows are darker
than the paper and silently inverts once they are lighter, which is how an
earlier pass produced a plausible and wrong 2.22 : 1. Note also that
`translucency` blends every layer toward the ground, so a row renders much
closer to the paper than its hex suggests — `#45424E` lands at 159 on cream.
Pick the colour by measuring the render, never by reading the SVG.

**Thickness buys nothing.** Measured at 64 and 96pt, thickening the rows leaves
the contrast ratio flat: they already reach full colour density, so more weight
only adds bulk. If the rows need to read harder, take colour, not size.

**Size, if the design ever goes inset again.** Glyph bounding box over the
squircle's: Mail is 75% wide, Music 74%. An inset mark wants to sit in that
family. The one that was tried here measured 77% wide and 81% tall — larger than
both, despite looking smaller beside Mail, because a spine splits it into two
tones where Mail's envelope is one solid block of colour. Measure before
scaling.
