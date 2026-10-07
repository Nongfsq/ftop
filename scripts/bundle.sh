#!/bin/bash
# Builds a release and assembles build/Ftop.app. By default it is ad-hoc signed, which
# only suits this machine; set FTOP_SIGN_IDENTITY to a "Developer ID Application: ..."
# certificate name to sign a copy that can be notarized (see scripts/release.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
bin="$(swift build -c release --show-bin-path)"
app="build/Ftop.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Support/Info.plist "$app/Contents/Info.plist"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# The panel is named FtopPanel because "Ftop" and "ftop" are the same file on a
# case-insensitive disk.
cp "$bin/FtopApp" "$app/Contents/MacOS/FtopPanel"
cp "$bin/ftop" "$bin/ftop-helper" "$app/Contents/MacOS/"
identity="${FTOP_SIGN_IDENTITY:--}"
options=()
# Notarization requires the hardened runtime and a secure timestamp.
[ "$identity" = "-" ] || options=(--options runtime --timestamp)
codesign --force --sign "$identity" ${options[@]+"${options[@]}"} "$app/Contents/MacOS/ftop-helper" "$app/Contents/MacOS/ftop"
codesign --force --sign "$identity" ${options[@]+"${options[@]}"} "$app"
echo "Built $app"
