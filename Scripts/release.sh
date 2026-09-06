#!/bin/bash
# Builds a release of Heft the way a Homebrew cask expects one: a signed,
# notarised, stapled Heft.app in a zip, with the cask file to publish it.
#
#   Scripts/release.sh                       # version from the Xcode project
#   Scripts/release.sh --version 0.2.0       # a specific version
#   Scripts/release.sh --notarize            # also notarise and staple
#
# Signing: a "Developer ID Application" certificate is used when the keychain
# holds one (or name it in HEFT_DEVELOPER_ID). Without one the app is signed
# ad hoc, which is fine for trying the pipeline and useless for shipping:
# Gatekeeper refuses an ad-hoc app on any other Mac.
#
# Notarising needs a keychain profile made once with
#   xcrun notarytool store-credentials heft-notary ...
# (HEFT_NOTARY_PROFILE overrides the name). The zip is submitted, the ticket
# is stapled to the app, and the zip is made again, since the staple lives
# inside the bundle.
#
# Nothing here pushes, tags or publishes. The last lines say what to run for
# that, and the cask lands in dist/ for the tap repository.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION=""
NOTARIZE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)  VERSION="${2:?--version needs a number}"; shift 2 ;;
        --notarize) NOTARIZE=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# The project's MARKETING_VERSION unless one was given. The build number is
# the commit count, so two builds of different commits never share one.
if [[ -z "$VERSION" ]]; then
    VERSION="$(sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);/\1/p' "$ROOT/Heft.xcodeproj/project.pbxproj" | head -1)"
fi
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"

IDENTITY="${HEFT_DEVELOPER_ID:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/"Developer ID Application:/{print $2; exit}'
    )"
fi
if [[ -n "$IDENTITY" ]]; then
    echo "Signing as: $IDENTITY"
    SIGNING_ARGS=(
        CODE_SIGN_STYLE=Manual
        "CODE_SIGN_IDENTITY=$IDENTITY"
        OTHER_CODE_SIGN_FLAGS=--timestamp
    )
else
    echo "No Developer ID Application certificate in the keychain: signing ad hoc." >&2
    echo "This build runs here and nowhere else. See the release guide for the certificate." >&2
    SIGNING_ARGS=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY=-
    )
    if [[ "$NOTARIZE" == "1" ]]; then
        echo "Cannot notarise an ad-hoc build; dropping --notarize." >&2
        NOTARIZE=0
    fi
fi

DERIVED_DATA="$ROOT/.build/XcodeDerivedData"
SOURCE_PACKAGES="$ROOT/.build/XcodeSourcePackages"
APP="$DERIVED_DATA/Build/Products/Release/Heft.app"
DIST="$ROOT/dist"
ZIP="$DIST/Heft-$VERSION.zip"

echo "Building Heft $VERSION ($BUILD_NUMBER)"
# Hardened runtime is what notarisation requires; the app needs no
# entitlements beyond it. Both configurations build fine with it on, so it is
# set here rather than in the project, where it would make a plain debug
# build depend on a certificate.
xcodebuild \
    -quiet \
    -project "$ROOT/Heft.xcodeproj" \
    -scheme Heft \
    -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    "MARKETING_VERSION=$VERSION" \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
    ENABLE_HARDENED_RUNTIME=YES \
    "${SIGNING_ARGS[@]}" \
    build

codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'

mkdir -p "$DIST"
package() {
    rm -f "$ZIP"
    # ditto keeps the resource forks and the bundle layout Gatekeeper checks;
    # a plain zip does not.
    ditto -c -k --keepParent "$APP" "$ZIP"
}
package

if [[ "$NOTARIZE" == "1" ]]; then
    PROFILE="${HEFT_NOTARY_PROFILE:-heft-notary}"
    echo "Notarising with keychain profile '$PROFILE'"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    package
    echo "Gatekeeper: $(spctl --assess --type execute --verbose=2 "$APP" 2>&1 | tail -1)"
fi

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
CASK="$DIST/heft.rb"
cat > "$CASK" <<EOF
cask "heft" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/josteng/Heft/releases/download/v#{version}/Heft-#{version}.zip"
  name "Heft"
  desc "Markdown vault editor with a command-line interface for coding agents"
  homepage "https://github.com/josteng/Heft"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "Heft.app"
  binary "#{appdir}/Heft.app/Contents/MacOS/Heft", target: "heft"

  zap trash: [
    "~/Library/Application Support/Heft",
    "~/Library/Preferences/dev.stenglein.Heft.plist",
    "~/Library/Saved Application State/dev.stenglein.Heft.savedState",
  ]
end
EOF

echo
echo "Built:    $ZIP"
echo "sha256:   $SHA"
echo "Cask:     $CASK"
if [[ "$NOTARIZE" != "1" ]]; then
    echo "Not notarised. Gatekeeper will refuse this zip on other Macs."
fi
echo
echo "To publish:"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo "  gh release create v$VERSION '$ZIP' --title 'Heft $VERSION' --notes-file <notes.md>"
echo "  cp '$CASK' <tap checkout>/Casks/heft.rb   # the homebrew-heft repository, then commit and push"
echo "Users then run: brew install --cask josteng/heft/heft"
