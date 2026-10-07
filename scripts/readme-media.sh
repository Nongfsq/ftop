#!/bin/bash
# Regenerates the README pictures in docs/media from the panel's own drawing code with
# sample readings. Run after a change to how the panel looks. Needs Python with Pillow.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
FTOP_DEMO_DIR="$work/frames" FTOP_RENDER_DIR="$work/render" FTOP_ICON_DIR="$work/icon" swift test --filter "RenderTests|IconTests" >/dev/null
python3 scripts/readme_media.py "$work/frames" docs/media "$work/render/settings-en.png"
cp "$work/icon/icon_128x128@2x.png" docs/media/icon.png
echo "Wrote docs/media"
