#!/bin/bash
# Builds a release and assembles build/Ftop.app. It is ad-hoc signed for this machine
# unless FTOP_SIGN_IDENTITY names a Developer ID certificate in the keychain; then
# every executable is signed with it, the hardened runtime, and a secure timestamp,
# as notarization requires (scripts/release.sh does this).
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
if [ -n "${FTOP_SIGN_IDENTITY:-}" ]; then
    sign=(codesign --force --options runtime --timestamp --sign "$FTOP_SIGN_IDENTITY")
else
    sign=(codesign --force --sign -)
fi
# Inside out: the bundle's signature seals the executables signed before it.
"${sign[@]}" "$app/Contents/MacOS/ftop-helper" "$app/Contents/MacOS/ftop"
"${sign[@]}" "$app"
echo "Built $app"
