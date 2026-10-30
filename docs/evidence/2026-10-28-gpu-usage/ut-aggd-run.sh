#!/bin/bash
# Runs the load states one after another and samples each for 35 s at 1 s.
# Needs ut-aggd-sample and stress (built from ut-aggd-stress.swift) in the given directory.
set -u
dir=$1; out=$2
FTOP=~/Applications/Ftop.app/Contents/MacOS/ftop
probe() { "$FTOP" probe --json | python3 -c 'import json,sys; d=json.load(sys.stdin); g=d["gpu"]["value"]["_0"]; p=d["power"]["value"]["_0"]; print(sys.argv[1], "ftop usage", round(g["usage"]*100), "MHz", g["frequencyMHz"]["value"].get("_0"), "gpuW", p["gpuWatts"]["value"].get("_0"))' "$1" >> "$out.probe.txt"; }
"$dir/ut-aggd-sample" idle 35 1000 > "$out"
probe idle
for n in ${STATES:-10 12 14 16 18 20}; do
  sleep 8
  "$dir/stress" 40 "$n" > /dev/null &
  sp=$!
  sleep 3
  "$dir/ut-aggd-sample" "stress2^$n" 35 1000 noheader >> "$out"
  probe "stress2^$n"
  wait $sp
done
