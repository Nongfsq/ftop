#!/bin/bash
# Builds, signs, notarizes, and staples a release archive in build/.
# It uploads nothing to GitHub; attach the archive to a release yourself.
#
#   FTOP_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)", required
#   FTOP_NOTARY_PROFILE  notarytool keychain profile, default "ftop-notary"; create it once with
#                        xcrun notarytool store-credentials ftop-notary --apple-id <id> --team-id <TEAMID>
set -euo pipefail
cd "$(dirname "$0")/.."

: "${FTOP_SIGN_IDENTITY:?set FTOP_SIGN_IDENTITY to a Developer ID Application certificate name}"
profile="${FTOP_NOTARY_PROFILE:-ftop-notary}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
archive="build/Ftop-$version-arm64.zip"

scripts/bundle.sh
rm -f "$archive"
ditto -c -k --keepParent build/Ftop.app "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
# Attach the ticket so the app opens without a network check, then pack the stapled copy.
xcrun stapler staple build/Ftop.app
rm -f "$archive"
ditto -c -k --keepParent build/Ftop.app "$archive"
spctl --assess --type execute --verbose build/Ftop.app
echo "Wrote $archive"
