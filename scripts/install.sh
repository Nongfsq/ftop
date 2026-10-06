#!/bin/bash
# Installs build/Ftop.app into ~/Applications and links the `ftop` command.
set -euo pipefail
cd "$(dirname "$0")/.."

app="build/Ftop.app"
[ -d "$app" ] || scripts/bundle.sh

target="$HOME/Applications/Ftop.app"
link="${FTOP_BIN_DIR:-$HOME/.local/bin}/ftop"

# Stop a running panel, whichever copy it was started from.
pkill -x FtopPanel 2>/dev/null || true
sleep 0.5
mkdir -p "$HOME/Applications" "$(dirname "$link")"
rm -rf "$target"
cp -R "$app" "$target"
ln -sfn "$target/Contents/MacOS/ftop" "$link"
echo "Installed $target"
echo "Linked $link"
case ":$PATH:" in *":$(dirname "$link"):"*) ;; *) echo "Note: $(dirname "$link") is not on your PATH." ;; esac
