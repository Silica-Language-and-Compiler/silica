#!/bin/bash
# loop.sh <trial_binary> <runs> <parallel> [marker] [marker_count] [hang_seconds]
#
# Runs one built host trial <runs> times, <parallel> at a time, each through the trials' marker
# runner (trials/actors_addition/run_integration_exit_after_marker.py: output on a PTY, `exit`
# written to stdin after <marker_count> occurrences of <marker>, default `done` 1, as
# supervisors_addition's Makefile runs every trial). A run still going after <hang_seconds>
# (default 15) is a hang: its process is sampled with sample(1) into runs/r<i>/sample.txt, then
# killed. Run it from a scratch directory: it writes runs/ in the current directory (emptied first).
#
# At the end it prints the number of hangs and, for the finished runs, how many runs gave each
# (failure-report count, last line) pair; the last line is the exit status the runner appends. A
# race shows as a second pair or a hang.
#
# Example (after `make integrate` or `make` in trials/supervisors_addition):
#   mkdir -p /tmp/loop && cd /tmp/loop
#   bash /path/to/programmer_tools/trial_loop/loop.sh \
#       /path/to/trials/supervisors_addition/phase_e_root_restart_cap_zero_no_drain 200 8
set -u
if [ "$#" -lt 3 ]; then
    sed -n '2,8p' "$0" >&2
    exit 2
fi
exe=$1; n=$2; p=$3; marker=${4:-done}; count=${5:-1}; hang=${6:-15}
[ -x "$exe" ] || { echo "loop.sh: not an executable: $exe" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
H="$here/../../trials/actors_addition/run_integration_exit_after_marker.py"
[ -f "$H" ] || { echo "loop.sh: runner not found: $H" >&2; exit 2; }
t=$(basename "$exe")
mkdir -p runs && rm -rf runs/r*

one() {
    local i=$1 d=runs/r$1 pid cp k
    mkdir -p "$d" && cp "$exe" "$d/"
    (
        cd "$d" || exit 1
        python3 "$H" "$PWD" "$t" out.sout "$marker" "$count" > /dev/null 2>&1 &
        pid=$!
        for k in $(seq 1 $((hang * 10))); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
        if kill -0 $pid 2>/dev/null; then
            cp=$(pgrep -f "^$PWD/$t" | head -1)
            [ -z "$cp" ] && cp=$(pgrep -P $pid | head -1)
            echo "HANG run $i child=$cp"
            [ -n "$cp" ] && sample "$cp" 2 -file sample.txt > /dev/null 2>&1
            pkill -P $pid; kill $pid
        fi
        wait $pid 2>/dev/null
    )
}

for i in $(seq 1 "$n"); do
    one "$i" &
    if (( i % p == 0 )); then wait; fi
done > runs/hangs.log
wait

echo "== $t: $n runs, hangs: $(grep -c HANG runs/hangs.log)"
for f in runs/r*/out.sout; do
    [ -f "$f" ] || continue
    echo "$(grep -c 'End Silica' "$f") $(tail -1 "$f")"
done | sort | uniq -c
