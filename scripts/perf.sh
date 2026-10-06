#!/bin/bash
# Prints the running panel's CPU share and memory over 15 seconds.
# Budget: under 1% of one core and under 60 MB (docs/architecture). Quit any other copy first:
# the panel is single-instance, so a stale one is what gets measured.
set -euo pipefail
pid="$(pgrep -x FtopPanel || true)"
[ -n "$pid" ] || { echo "ftop is not running; start it with: ftop" >&2; exit 1; }
echo "panel (pid $pid): cpu% and memory, one line per 3 s"
top -l 6 -s 3 -pid "$pid" -stats cpu,mem | grep -E '^[0-9]+\.[0-9]' | tail -5
helper="$(pgrep -x ftop-helper || true)"
if [ -n "$helper" ]; then
    echo "helper (pid $helper):"
    top -l 4 -s 3 -pid "$helper" -stats cpu,mem | grep -E '^[0-9]+\.[0-9]' | tail -3
fi
