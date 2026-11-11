#!/bin/bash
# Archives the iPhone and iPad app and uploads it to TestFlight.
#
#   Scripts/testflight.sh                    # version from Config/Heft.xcconfig
#   Scripts/testflight.sh --version 0.8.0    # a specific version
#   Scripts/testflight.sh --no-upload        # archive and export only
#
# The App Store Connect API key archives; the export and the upload use the
# Apple ID signed in to Xcode (see below). The key's path, key id and
# issuer come from the environment or from ~/.config/heft/asc.env:
#   HEFT_ASC_KEY=<path to AuthKey_XXXX.p8>  HEFT_ASC_KEY_ID=...  HEFT_ASC_ISSUER=...
# None of them belongs in the repository.
#
# The build number is the date and time, yymmddHHMM: an upload needs one
# higher than every build before it, and counting commits went backwards
# when the history was squashed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -f "$HOME/.config/heft/asc.env" ]] && source "$HOME/.config/heft/asc.env"

VERSION=""
UPLOAD=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --no-upload) UPLOAD=0; shift ;;
        *) echo "Unknown option $1" >&2; exit 2 ;;
    esac
done
if [[ -z "$VERSION" ]]; then
    VERSION="$(sed -n 's/^MARKETING_VERSION *= *\([0-9.]*\).*/\1/p' "$ROOT/Config/Heft.xcconfig" | head -1)"
fi
: "${HEFT_ASC_KEY:?set HEFT_ASC_KEY or create ~/.config/heft/asc.env}"
: "${HEFT_ASC_KEY_ID:?set HEFT_ASC_KEY_ID}"
: "${HEFT_ASC_ISSUER:?set HEFT_ASC_ISSUER}"
TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' "$ROOT/Config/Local.xcconfig" 2>/dev/null | head -1)"
: "${TEAM:?set DEVELOPMENT_TEAM in Config/Local.xcconfig}"

BUILD="$(date +%y%m%d%H%M)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/heft-testflight.XXXXXX")"
ARCHIVE="$WORK/Heft.xcarchive"
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$HEFT_ASC_KEY"
      -authenticationKeyID "$HEFT_ASC_KEY_ID"
      -authenticationKeyIssuerID "$HEFT_ASC_ISSUER")

echo "Archiving Heft $VERSION ($BUILD) for iPhone and iPad"
xcodebuild -quiet \
    -project "$ROOT/Heft.xcodeproj" -scheme HeftiOS -configuration Release \
    -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
    -derivedDataPath "$WORK/build" \
    "MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD" \
    "${AUTH[@]}" archive

cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$([[ $UPLOAD == 1 ]] && echo upload || echo export)</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "$([[ $UPLOAD == 1 ]] && echo Uploading || echo Exporting)…"
# Signed through the Apple ID in Xcode ▸ Settings ▸ Accounts, not the key:
# App Store signing uses a cloud-managed distribution certificate, which an
# App Manager key may not use and the account holder may.
#
# With the system's PATH only: Xcode packages the .ipa with /usr/bin/rsync,
# which starts its other end by name, and Homebrew's rsync first in the PATH
# answers and rejects the -E Apple's passes ("Copy failed").
env PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
xcodebuild -quiet -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" -exportPath "$WORK/export" \
    -allowProvisioningUpdates

echo
echo "Heft $VERSION ($BUILD) $([[ $UPLOAD == 1 ]] && echo "uploaded; it shows in TestFlight once Apple has processed it" || echo "exported to $WORK/export")."
