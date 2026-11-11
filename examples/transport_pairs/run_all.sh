#!/bin/bash
# Runs every transport pair on the real board, one at a time, and reports PASS or FAIL per pair. See README.md.
#
#   run_all.sh            all pairs (the accel/LED and basic pairs with both Mac peers)
#
# Each pair's own run.sh does the work; its full output goes to <pair>/build/run_all.log. Exit 0 only when every
# pair passed. Environment: see lib/pair_lib.sh (BOARD_PORT, BOARD_PYTHON, the compilers).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PAIRS=(
    "usb_basic_exchange --both"
    "usb_accel_led_erlang_and_silica --both"
    "usb_silica_pair"
)
overall=0 report=""
for entry in "${PAIRS[@]}"; do
    pair=${entry%% *} args=""
    [ "$entry" = "$pair" ] || args=${entry#* }
    mkdir -p "$HERE/$pair/build"
    log="$HERE/$pair/build/run_all.log"
    echo "=== $pair"
    start=$(date +%s)
    "$HERE/$pair/run.sh" $args > "$log" 2>&1; rc=$?
    secs=$(( $(date +%s) - start ))
    grep -E '^=== |^pair: (MATCH|MISMATCH)|^run_app: (MATCH|MISMATCH)' "$log" | sed 's/^/    /'
    if [ $rc -eq 0 ]; then line="PASS  $pair (${secs}s)"; else line="FAIL  $pair (exit $rc, ${secs}s; see $log)"; overall=1; fi
    echo "$line"; report+="$line"$'\n'
done
echo "=== summary"; printf '%s' "$report"
exit $overall
