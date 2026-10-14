#!/bin/bash
# Builds the release archive: Ftop.app signed with the Developer ID, notarized by
# Apple, the ticket stapled, zipped as build/Ftop-<version>-arm64.zip.
#
# Needs, once per Mac:
#   the "Developer ID Application" certificate in the login keychain, and
#   xcrun notarytool store-credentials ftop --apple-id <id> --team-id YHQ2HJF58N
# (asks for an app-specific password from account.apple.com and keeps it in the
# keychain). Publishing the archive is a separate, manual step.
set -euo pipefail
cd "$(dirname "$0")/.."

team="YHQ2HJF58N"
profile="${FTOP_NOTARY_PROFILE:-ftop}"
identity="$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($team)\)\"/\1/p" | head -1)"
[ -n "$identity" ] || { echo "No Developer ID Application certificate for team $team in the keychain." >&2; exit 1; }

FTOP_SIGN_IDENTITY="$identity" scripts/bundle.sh
app="build/Ftop.app"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")"
zip="build/Ftop-$version-arm64.zip"
codesign --verify --deep --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$team\"" "$app"

# Apple takes a zip; the ticket is then stapled to the app so Gatekeeper can check it
# offline, and the archive is made again from the stapled app.
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

spctl --assess --type execute --verbose "$app"
echo "Built $zip"
shasum -a 256 "$zip"
