#!/bin/bash
# Records a game run: 180 s of 1 s samples, with spoken cues to start the game at 15 s
# and stop it at 155 s, and one `ftop probe --json` from the build under test at 110 s.
# A cold start takes about 30 s and entering a level about 20 s more, so play runs
# from about 65 s to 155 s.
# Usage: game-4k120-record.sh <ut-aggd-sample> <ftop> <out-dir>
# Writes game-4k120-samples.csv, game-4k120-markers.txt, game-4k120-probe.txt.
set -u
sampler=$1; ftop=$2; out=$3
mark() { echo "$(python3 -c "import time; print(f'{time.monotonic() - $start:.1f}')") $1" >> "$out/game-4k120-markers.txt"; }
: > "$out/game-4k120-markers.txt"
start=$(python3 -c "import time; print(time.monotonic())")
"$sampler" game-4k120 180 1000 > "$out/game-4k120-samples.csv" &
sampling=$!
mark "recording started; game not running (baseline)"
say -v Tingting "开始录制，先不要开始游戏" 2>/dev/null || say "Recording; do not start the game yet"
sleep 14
mark "cue: start the game"
say -v Tingting "现在开始游戏" 2>/dev/null || say "Start the game now"
sleep 95
mark "probe"
"$ftop" probe --json > "$out/game-4k120-probe.txt"
sleep 44
mark "cue: stop the game"
say -v Tingting "可以停止游戏了" 2>/dev/null || say "Stop the game now"
wait $sampling
mark "recording ended"
say -v Tingting "录制结束" 2>/dev/null || say "Recording ended"
