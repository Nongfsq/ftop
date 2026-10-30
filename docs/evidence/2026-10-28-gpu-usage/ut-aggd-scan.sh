#!/bin/bash
# Runs one ut-aggd-scan per word in parallel over the same window (one combined subscription
# across these drivers sometimes comes back empty), then prints them together.
dir=$(dirname "$0"); secs=$1; shift
tmp=$(mktemp -d)
i=0; for w in "$@"; do "$dir/ut-aggd-scan" "$secs" "$w" > "$tmp/$i" & i=$((i+1)); done
wait; cat "$tmp"/* | sort -u; rm -r "$tmp"
