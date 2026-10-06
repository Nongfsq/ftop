#!/bin/bash
# Regenerates Support/AppIcon.icns from the drawing code in Sources/FtopUI/Logo.swift.
# Run after changing the logo; the .icns file is committed.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
FTOP_ICON_DIR="$work/AppIcon.iconset" swift test --filter IconTests >/dev/null
iconutil --convert icns --output Support/AppIcon.icns "$work/AppIcon.iconset"
echo "Wrote Support/AppIcon.icns"
