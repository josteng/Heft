#!/bin/bash
# Builds a release of Heft the way a Homebrew cask expects one: a signed,
# notarised, stapled Heft.app in a zip, with the cask file to publish it.
#
#   Scripts/release.sh                       # version from Config/Heft.xcconfig
#   Scripts/release.sh --version 0.2.0       # a specific version
#   Scripts/release.sh --notarize            # also notarise and staple
#   Scripts/release.sh --universal           # arm64 and x86_64 in one binary
#   Scripts/release.sh --resume              # staple a submission Apple has since accepted
#
# Signing: a "Developer ID Application" certificate is used when the keychain
# holds one (or name it in HEFT_DEVELOPER_ID). Without one the app is signed
# ad hoc, which is fine for trying the pipeline and useless for shipping:
# Gatekeeper refuses an ad-hoc app on any other Mac. A DEVELOPMENT_TEAM in
# Config/Local.xcconfig narrows the choice to that team's certificate.
#
# Notarising needs credentials: a keychain profile made once with
#   xcrun notarytool store-credentials heft-notary ...
# (HEFT_NOTARY_PROFILE overrides the name), or, where no keychain profile can
# exist such as a CI runner, an App Store Connect API key in
# HEFT_NOTARY_KEY (path to the .p8), HEFT_NOTARY_KEY_ID and
# HEFT_NOTARY_ISSUER. The zip is submitted, the ticket is stapled to the app,
# and the zip is made again, since the staple lives inside the bundle.
#
# Apple usually answers within minutes, but a new account's first submission
# can take days. The script waits an hour, then leaves the submission id in
# dist/ and stops; --resume picks the zip and the id back up, asks Apple, and
# staples once the answer is Accepted. Nothing is rebuilt on resume, because
# the ticket is bound to the bytes Apple scanned.
#
# Nothing here pushes, tags or publishes. The last lines say what to run for
# that, and the cask lands in dist/ for the tap repository.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION=""
NOTARIZE=0
UNIVERSAL=0
RESUME=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)   VERSION="${2:?--version needs a number}"; shift 2 ;;
        --notarize)  NOTARIZE=1; shift ;;
        --universal) UNIVERSAL=1; shift ;;
        --resume)    RESUME=1; NOTARIZE=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# MARKETING_VERSION from Config/Heft.xcconfig unless one was given. The build
# number is the commit count, so two builds of different commits never share
# one.
if [[ -z "$VERSION" ]]; then
    VERSION="$(sed -n 's/^MARKETING_VERSION *= *\([0-9.]*\).*/\1/p' "$ROOT/Config/Heft.xcconfig" | head -1)"
fi
[[ -n "$VERSION" ]] || { echo "No version: set MARKETING_VERSION in Config/Heft.xcconfig or pass --version" >&2; exit 1; }
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"

DIST="$ROOT/dist"
ZIP="$DIST/Heft-$VERSION.zip"
SUBMISSION_FILE="$DIST/Heft-$VERSION.submission"

if [[ "${HEFT_NOTARY_KEY:-}" != "" ]]; then
    NOTARY_AUTH=(--key "$HEFT_NOTARY_KEY" --key-id "${HEFT_NOTARY_KEY_ID:?HEFT_NOTARY_KEY_ID}" --issuer "${HEFT_NOTARY_ISSUER:?HEFT_NOTARY_ISSUER}")
    NOTARY_HOW="an App Store Connect API key"
else
    NOTARY_AUTH=(--keychain-profile "${HEFT_NOTARY_PROFILE:-heft-notary}")
    NOTARY_HOW="keychain profile '${HEFT_NOTARY_PROFILE:-heft-notary}'"
fi

package() {
    rm -f "$ZIP"
    # ditto keeps the resource forks and the bundle layout Gatekeeper checks;
    # a plain zip does not.
    ditto -c -k --keepParent "$APP" "$ZIP"
}

if [[ "$RESUME" == "1" ]]; then
    [[ -f "$ZIP" && -f "$SUBMISSION_FILE" ]] || { echo "Nothing to resume for $VERSION: no $ZIP with a submission id beside it." >&2; exit 1; }
    SUBMISSION_ID="$(cat "$SUBMISSION_FILE")"
    STAGE="$(mktemp -d)"
    ditto -x -k "$ZIP" "$STAGE"
    APP="$STAGE/Heft.app"
    echo "Resuming submission $SUBMISSION_ID for $ZIP"
else

# The team comes from Config/Local.xcconfig when there is one, which is the
# same file Xcode reads, so the two never disagree. It only matters when the
# keychain holds Developer ID certificates for more than one team.
TEAM=""
if [[ -f "$ROOT/Config/Local.xcconfig" ]]; then
    TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' "$ROOT/Config/Local.xcconfig" | head -1)"
fi
IDENTITY="${HEFT_DEVELOPER_ID:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' -v team="$TEAM" '/"Developer ID Application:/ && (team == "" || index($2, "(" team ")")) {print $2; exit}'
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

if [[ "$UNIVERSAL" == "1" ]]; then
    ARCH_ARGS=(-destination "generic/platform=macOS" "ARCHS=arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
else
    ARCH_ARGS=(-destination "platform=macOS,arch=$(uname -m)")
fi

echo "Building Heft $VERSION ($BUILD_NUMBER)"
# Hardened runtime is what notarisation requires; the app needs no
# entitlements beyond it. Both configurations build fine with it on, so it is
# set here rather than in the project, where it would make a plain debug
# build depend on a certificate. The build action, unlike archive, injects a
# get-task-allow entitlement so a debugger can attach; the notary service
# rejects a binary carrying it.
xcodebuild \
    -quiet \
    -project "$ROOT/Heft.xcodeproj" \
    -scheme Heft \
    -configuration Release \
    "${ARCH_ARGS[@]}" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    "MARKETING_VERSION=$VERSION" \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    "${SIGNING_ARGS[@]}" \
    build

codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
echo "  architectures: $(lipo -archs "$APP/Contents/MacOS/Heft")"

mkdir -p "$DIST"
rm -f "$SUBMISSION_FILE"
package

if [[ "$NOTARIZE" == "1" ]]; then
    echo "Notarising with $NOTARY_HOW"
    # Waiting is bounded: a first submission can sit for days, and the ticket
    # can be stapled whenever it arrives. The exit status is ignored because
    # notarytool exits 0 on Invalid and non-zero on a timeout; the status
    # line below is what decides.
    SUBMISSION="$(xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait --timeout 1h 2>&1 | tee /dev/stderr || true)"
    SUBMISSION_ID="$(sed -n 's/^ *id: //p' <<< "$SUBMISSION" | head -1)"
    [[ -n "$SUBMISSION_ID" ]] || { echo "Submission failed before Apple gave it an id." >&2; exit 1; }
    echo "$SUBMISSION_ID" > "$SUBMISSION_FILE"
fi

fi  # not resuming

if [[ "$NOTARIZE" == "1" ]]; then
    STATUS="$(xcrun notarytool info "$SUBMISSION_ID" "${NOTARY_AUTH[@]}" 2>&1 | sed -n 's/^ *status: //p' | head -1)"
    case "$STATUS" in
        Accepted) ;;
        "In Progress")
            echo "Apple is still scanning submission $SUBMISSION_ID. Check with" >&2
            echo "  xcrun notarytool info $SUBMISSION_ID ${NOTARY_AUTH[*]}" >&2
            echo "and finish with Scripts/release.sh --resume --version $VERSION once it is Accepted." >&2
            exit 2 ;;
        *)
            echo "Notarisation ended as '$STATUS'; Apple's log:" >&2
            xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_AUTH[@]}" >&2 || true
            exit 1 ;;
    esac
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
  depends_on arch: :arm64

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
