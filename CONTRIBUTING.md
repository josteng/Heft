# Contributing

Heft is the app I write my own notes in, so what helps most is hearing when
something breaks, or when something is missing. Open a
[GitHub issue](https://github.com/josteng/Heft/issues) for either. Pull
requests are welcome too.

## Reporting something

Include your macOS version, the commit you built (`git rev-parse --short HEAD`;
there is no `heft --version`), and what you did, what happened, and what you
expected instead.

For anything about the editing surface, these three are read-only and show more
than a description can:

```bash
heft render <vault> <note> [caret]   # what the surface would draw, headless
heft export <vault> <note> out.pdf   # the rendered note, as a file to attach
heft stats <vault>                   # counts, timings, link resolution
```

If the vault it happens in is private, a small one that still reproduces it is
ideal. Most surface bugs need one note and a caret position.

## Suggesting something

Feature ideas are welcome as issues. The README's *Not built yet* section and
the known gaps at the end of [`Docs/Gotchas.md`](Docs/Gotchas.md) list what is
already missing on purpose, so a look there first saves you writing up
something that is already on the pile.

## Building it

```bash
swift test                          # the full suite
Scripts/smoke.sh                    # does the app actually start?
Scripts/run.sh --sandbox [vault]    # debug build, isolated preferences
Scripts/bundle.sh debug             # build the .app without launching
```

Requires macOS 26 and Xcode. Both `xcodebuild` and `swift test` need
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if `xcode-select`
points at the Command Line Tools, which is the usual case.

The GUI autosaves, so never point it at a vault you care about. `--sandbox`
also stops a test launch rewriting your preferences.

## Pull requests

Run `swift test` first, and add a test for new behaviour. Anything structural
is worth an issue before you write it. [`Docs/`](Docs) covers why each area
works the way it does, and is the quickest way to find out whether an idea has
already been tried.

## Licensing

Heft is under the GNU General Public License, version 3 or later
([`LICENSE`](LICENSE)), and contributions come in under it. Opening a pull
request is the agreement, which is what GitHub's terms say about a public
repository anyway.

Opening one also grants me the right to use your contribution for four things,
and only these four: shipping Heft through an app store, charging for Heft in a
store or anywhere else, changing its licence, and reusing parts of the code in
my other projects. That includes distributing it without the source and under
terms other than the GPL, which is what those four need. This is just to leave
doors open, and I have no concrete plan to walk through any of them.

You keep your copyright, and the GPL version of your work stays available to
everyone whatever happens later. If you would rather not grant it, say so in
the pull request and the change can stay GPL-only or be left out.
