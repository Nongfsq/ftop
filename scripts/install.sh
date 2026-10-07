#!/bin/bash
# Installs Ftop.app into ~/Applications and links the `ftop` command.
# With no argument it installs build/Ftop.app, building it first if needed;
# pass the path of an unpacked release to install that instead.
set -euo pipefail

if [ $# -gt 0 ]; then
    app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    [ -x "$app/Contents/MacOS/ftop" ] || { echo "Not an Ftop.app: $1" >&2; exit 1; }
fi
cd "$(dirname "$0")/.."
if [ $# -eq 0 ]; then
    app="build/Ftop.app"
    [ -d "$app" ] || scripts/bundle.sh
fi

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
