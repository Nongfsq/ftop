#!/bin/bash
# Run with sudo once: lists IOReport channels as root and records powermetrics gpu_power at idle,
# 2^10 threads and 2^20 threads, so root output can be compared with the normal-user output.
dir=$(cd "$(dirname "$0")" && pwd)
user=${SUDO_USER:-$USER}
"$dir/list" > "$dir/root-all.txt" 2>/dev/null
echo "== idle" > "$dir/root-powermetrics.txt"
powermetrics --samplers gpu_power -i 1000 -n 5 >> "$dir/root-powermetrics.txt" 2>&1
for n in 10 20; do
  sudo -u "$user" "$dir/stress" 12 $n > /dev/null & sleep 3
  echo "== stress2^$n" >> "$dir/root-powermetrics.txt"
  powermetrics --samplers gpu_power -i 1000 -n 5 >> "$dir/root-powermetrics.txt" 2>&1
  wait
done
echo "== all samplers, one sample, idle" >> "$dir/root-powermetrics.txt"
powermetrics -A -i 1000 -n 1 2>&1 | sed -n '/GPU/,/^$/p' >> "$dir/root-powermetrics.txt"
chown "$user" "$dir"/root-*.txt
echo "done: $(wc -l < "$dir/root-all.txt") channels as root"
