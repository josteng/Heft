# Heft.icon

The app icon, in the layered format macOS 26 expects.

`icon.json` describes the icon; `Assets/` holds the vector layers. The system —
not this file — draws the rounded-rect shape, the Liquid Glass specular
highlight and the shadow, which is why the SVGs contain only the notebook glyph
on a transparent canvas. Drawing our own squircle here would produce a rounded
rectangle inside a rounded rectangle.

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
