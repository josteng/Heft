#!/bin/bash
# Releases Heft through the GitHub workflow, end to end, from one command:
#
#   Scripts/publish.sh                        # version from Config/Heft.xcconfig
#   Scripts/publish.sh --version 0.2.0
#   Scripts/publish.sh --run 12345678         # a run already started, by id
#   Scripts/publish.sh --notes notes.md       # instead of Docs/Releases/<version>.md
#   Scripts/publish.sh --tap ~/src/homebrew-tap
#
# What it does, in order: starts the Release workflow, approves the "release"
# environment gate (the same permission as clicking Review deployments, so
# only someone with write access gets this far), follows the run, then takes
# the draft release the run created and finishes it: the release notes go on,
# the draft becomes the published latest release, and the cask the run built
# is committed and pushed to the tap. Everything before the notes happens on
# the runner; see .github/workflows/release.yml.
#
# Notes come from Docs/Releases/<version>.md when that file exists, else the
# ones GitHub generates from the commits stay. The tap checkout defaults to
# a homebrew-tap directory beside this repository (HEFT_TAP overrides it).
#
# Needs gh, logged in as someone with write access to both repositories.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="josteng/Heft"
WORKFLOW="Release"
ENVIRONMENT="release"

VERSION=""
RUN=""
NOTES=""
TAP="${HEFT_TAP:-$ROOT/../homebrew-tap}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a number}"; shift 2 ;;
        --run)     RUN="${2:?--run needs an id}"; shift 2 ;;
        --notes)   NOTES="${2:?--notes needs a file}"; shift 2 ;;
        --tap)     TAP="${2:?--tap needs a directory}"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    VERSION="$(sed -n 's/^MARKETING_VERSION *= *\([0-9.]*\).*/\1/p' "$ROOT/Config/Heft.xcconfig" | head -1)"
fi
[[ -n "$VERSION" ]] || { echo "No version: set MARKETING_VERSION in Config/Heft.xcconfig or pass --version" >&2; exit 1; }
TAG="v$VERSION"
[[ -n "$NOTES" ]] || { [[ -f "$ROOT/Docs/Releases/$VERSION.md" ]] && NOTES="$ROOT/Docs/Releases/$VERSION.md"; } || true
[[ -d "$TAP/.git" ]] || { echo "No tap checkout at $TAP; pass --tap or set HEFT_TAP" >&2; exit 1; }

# The runner builds what is on GitHub, so the release is whatever master
# holds there. Refuse to start from a checkout that is ahead or dirty, since
# the tag would then name a commit that is not the one that was built.
if [[ -z "$RUN" ]]; then
    git -C "$ROOT" fetch -q origin
    if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
        echo "The working tree has changes; commit or stash them first." >&2; exit 1
    fi
    if [[ "$(git -C "$ROOT" rev-parse HEAD)" != "$(git -C "$ROOT" rev-parse origin/master)" ]]; then
        echo "HEAD is not what origin/master holds; push first, so the build matches the tag." >&2; exit 1
    fi
    if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
        echo "Release $TAG already exists on GitHub." >&2; exit 1
    fi

    STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    gh workflow run "$WORKFLOW" -R "$REPO" -f "version=$VERSION"
    echo "Started the $WORKFLOW workflow for $VERSION; waiting for the run to appear"
    for _ in $(seq 1 30); do
        RUN="$(gh run list -R "$REPO" --workflow="$WORKFLOW" --limit 5 --json databaseId,createdAt \
            --jq "[.[] | select(.createdAt >= \"$STARTED\")] | first | .databaseId // empty")"
        [[ -n "$RUN" ]] && break
        sleep 3
    done
    [[ -n "$RUN" ]] || { echo "The run did not appear; see gh run list -R $REPO" >&2; exit 1; }
fi
echo "Run: https://github.com/$REPO/actions/runs/$RUN"

# The environment gate. A run waits here until a required reviewer approves;
# approving from the same account that may click the button is the same act.
echo "Waiting for the $ENVIRONMENT environment gate"
for _ in $(seq 1 40); do
    PENDING="$(gh api "repos/$REPO/actions/runs/$RUN/pending_deployments" --jq 'length' 2>/dev/null || echo 0)"
    if [[ "$PENDING" != "0" ]]; then
        ENV_ID="$(gh api "repos/$REPO/actions/runs/$RUN/pending_deployments" --jq '.[0].environment.id')"
        gh api -X POST "repos/$REPO/actions/runs/$RUN/pending_deployments" \
            -F "environment_ids[]=$ENV_ID" -f state=approved -f comment="Approved by Scripts/publish.sh" >/dev/null
        echo "Approved"
        break
    fi
    STATUS="$(gh run view "$RUN" -R "$REPO" --json status --jq .status)"
    [[ "$STATUS" == "queued" || "$STATUS" == "waiting" || "$STATUS" == "pending" ]] || break
    sleep 3
done

gh run watch "$RUN" -R "$REPO" --exit-status || {
    echo "The run did not succeed. If it timed out waiting for Apple, the zip is a run artifact:" >&2
    echo "  gh run download $RUN -R $REPO --dir dist/   then   Scripts/release.sh --resume --version $VERSION" >&2
    exit 1
}

# What the run left: a draft release with the zip and the cask attached.
gh release view "$TAG" -R "$REPO" --json isDraft --jq '.isDraft' | grep -q true \
    || { echo "No draft release $TAG to finish; the run may have been for another version." >&2; exit 1; }
mkdir -p "$ROOT/dist"
rm -f "$ROOT/dist/heft.rb"
gh release download "$TAG" -R "$REPO" --pattern heft.rb --dir "$ROOT/dist"
SHA="$(sed -n 's/^ *sha256 "\([0-9a-f]*\)".*/\1/p' "$ROOT/dist/heft.rb")"
echo "Cask from the run: sha256 $SHA"

if [[ -n "$NOTES" ]]; then
    gh release edit "$TAG" -R "$REPO" --notes-file "$NOTES" --draft=false --latest >/dev/null
    echo "Published $TAG with notes from $NOTES"
else
    gh release edit "$TAG" -R "$REPO" --draft=false --latest >/dev/null
    echo "Published $TAG with the generated notes"
fi

# The cask names the release's zip and its checksum, so it goes out last.
cp "$ROOT/dist/heft.rb" "$TAP/Casks/heft.rb"
git -C "$TAP" add Casks/heft.rb
if git -C "$TAP" diff --cached --quiet; then
    echo "The tap already carries this cask."
else
    git -C "$TAP" commit -q -m "Heft $VERSION"
    git -C "$TAP" push -q
    echo "Pushed the cask to the tap"
fi

echo
echo "Released Heft $VERSION: https://github.com/$REPO/releases/tag/$TAG"
echo "Check it the way a user would:"
echo "  brew update && brew audit --cask --online josteng/tap/heft"
echo "  brew install --cask josteng/tap/heft"
