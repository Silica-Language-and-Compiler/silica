#!/bin/bash
# peak_rss.sh: measures the peak and at-rest resident set size (RSS) of the idle_actor_capacity program.
# The caller runs it in a scratch directory (it writes out.txt and err.txt there). It starts the program
# with stdin held open on a fifo, polls the RSS every 50 ms, and when the program prints its
# "<RWI_TARGET> idle actors" line (default 1000000) records the wall time, waits 3 s, records the RSS at
# rest, and sends "exit". It kills the program if RSS passes RWI_RSS_CAP_MB (default 6144). Output: one
# line with target, wall time to the target line, peak RSS MB, rest RSS MB, peak thread count (Linux only),
# exit code.
# macOS reads the RSS with BSD `ps -o rss=`. Linux reads /proc/<pid>/status (VmRSS, Threads) and needs
# neither bc nor BSD ps; on Linux RWI_MIN_AVAIL_MB (default 0 = off) also kills the program when the
# machine's MemAvailable in /proc/meminfo falls under it.
# Usage: RWI_TARGET=1000000 peak_rss.sh ./idle_actor_capacity
T=${RWI_TARGET:-1000000}
CAP_KB=$(( ${RWI_RSS_CAP_MB:-6144} * 1024 ))
MIN_AVAIL_KB=$(( ${RWI_MIN_AVAIL_MB:-0} * 1024 ))
if [ "$(uname)" = Linux ]; then LINUX=1; else LINUX=0; fi

# rss_kb <pid>: resident set size in KB, 0 when the process is gone.
rss_kb() {
  if [ $LINUX = 1 ]; then
    awk '/^VmRSS:/ {print $2; f=1} END {if (!f) print 0}' "/proc/$1/status" 2>/dev/null || echo 0
  else
    local r; r=$(ps -o rss= -p "$1" 2>/dev/null | tr -d ' '); echo "${r:-0}"
  fi
}

fifo=$(mktemp -u); mkfifo "$fifo"
exec 3<>"$fifo"
start=$(date +%s.%N)
"$@" <&3 > out.txt 2> err.txt &
pid=$!
peak=0; wall=""; rest=0; threads=0
while kill -0 $pid 2>/dev/null; do
  r=$(rss_kb $pid); r=${r:-0}
  [ "$r" -gt "$peak" ] && peak=$r
  if [ $LINUX = 1 ]; then
    t=$(awk '/^Threads:/ {print $2}' "/proc/$pid/status" 2>/dev/null); t=${t:-0}
    [ "$t" -gt "$threads" ] && threads=$t
    if [ "$MIN_AVAIL_KB" -gt 0 ]; then
      avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
      if [ "${avail:-0}" -lt "$MIN_AVAIL_KB" ]; then echo "MemAvailable under limit: killed" >> err.txt; kill -9 $pid; break; fi
    fi
  fi
  if [ "$r" -gt "$CAP_KB" ]; then echo "RSS over cap: killed" >> err.txt; kill -9 $pid; break; fi
  if [ -z "$wall" ] && grep -q "^$T idle actors" out.txt 2>/dev/null; then
    wall=$(awk -v a="$(date +%s.%N)" -v b="$start" 'BEGIN {printf "%.3f", a - b}')
    sleep 3
    rest=$(rss_kb $pid)
    [ "$rest" -gt "$peak" ] && peak=$rest
    echo "exit" >&3
  fi
  sleep 0.05
done
wait $pid; rc=$?
[ $LINUX = 1 ] || threads=n/a
exec 3>&-; rm -f "$fifo"
awk -v t="$T" -v w="${wall:-0}" -v p="$peak" -v r="${rest:-0}" -v th="$threads" -v rc="$rc" -v e="$(wc -l < err.txt | tr -d ' ')" \
  'BEGIN {printf "target=%s wall_to_target=%.2fs peak_rss_MB=%.1f rest_rss_MB=%.1f peak_threads=%s rc=%s stderr_lines=%s\n", t, w, p/1024, r/1024, th, rc, e}'
