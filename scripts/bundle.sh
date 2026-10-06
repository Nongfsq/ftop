#!/bin/bash
# Builds a release and assembles build/Ftop.app, ad-hoc signed for this machine.
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
codesign --force --sign - "$app/Contents/MacOS/ftop-helper" "$app/Contents/MacOS/ftop"
codesign --force --sign - "$app"
echo "Built $app"
