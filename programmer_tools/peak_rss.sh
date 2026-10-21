#!/bin/bash
# peak_rss.sh: measures the peak and at-rest resident set size (RSS) of the idle_actor_capacity program.
# The caller runs it in a scratch directory (it writes out.txt and err.txt there). It starts the program
# with stdin held open on a fifo, polls `ps -o rss=` every 50 ms, and when the program prints its
# "<RWI_TARGET> idle actors" line (default 1000000) records the wall time, waits 3 s, records the RSS at
# rest, and sends "exit". It kills the program if RSS passes 6 GB. Output: one line with target, wall time
# to the target line, peak RSS MB, rest RSS MB, exit code. macOS (BSD ps); on Linux use /usr/bin/time -v.
# Usage: RWI_TARGET=1000000 peak_rss.sh ./idle_actor_capacity
T=${RWI_TARGET:-1000000}
fifo=$(mktemp -u); mkfifo "$fifo"
exec 3<>"$fifo"
start=$(date +%s.%N)
"$@" <&3 > out.txt 2> err.txt &
pid=$!
peak=0; wall=""
while kill -0 $pid 2>/dev/null; do
  r=$(ps -o rss= -p $pid 2>/dev/null | tr -d ' '); r=${r:-0}
  [ "$r" -gt "$peak" ] && peak=$r
  if [ "$r" -gt 6291456 ]; then echo "RSS over 6 GB: killed" >> err.txt; kill -9 $pid; break; fi
  if [ -z "$wall" ] && grep -q "^$T idle actors" out.txt 2>/dev/null; then
    wall=$(echo "$(date +%s.%N) - $start" | bc)
    sleep 3
    rest=$(ps -o rss= -p $pid | tr -d ' ')
    echo "exit" >&3
  fi
  sleep 0.05
done
wait $pid; rc=$?
exec 3>&-; rm -f "$fifo"
printf 'target=%s wall_to_target=%.2fs peak_rss_MB=%.1f rest_rss_MB=%.1f rc=%s stderr_lines=%s\n' "$T" "${wall:-0}" "$(echo "$peak/1024" | bc -l)" "$(echo "${rest:-0}/1024" | bc -l)" "$rc" "$(wc -l < err.txt | tr -d ' ')"
