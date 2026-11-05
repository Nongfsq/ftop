#!/bin/bash
# Makes the drag-to-Applications disk image from an already signed, notarized, and
# stapled Ftop.app: the volume holds the app and a link to /Applications. The image is
# signed with the same Developer ID, notarized, and its own ticket stapled, so it opens
# without a warning even offline. scripts/release.sh calls this after the zip.
#
# Usage: scripts/dmg.sh <Ftop.app> <output.dmg> <signing identity> <notary profile>
set -euo pipefail

app="$1"
dmg="$2"
identity="$3"
profile="$4"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
# ditto keeps the signature and the stapled ticket intact.
ditto "$app" "$stage/Ftop.app"
ln -s /Applications "$stage/Applications"

rm -f "$dmg"
# hdiutil create is deprecated; diskutil makes the same compressed, read-only image.
diskutil image create from --format ULFO --volumeName Ftop "$stage" "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"

xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
