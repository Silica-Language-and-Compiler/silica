#!/usr/bin/env bash
# Item M mass conversion of one suite on the Mac (see README.md):
#   mass_suite.sh <suite> [--no-patch] [--no-train] [--no-run]
# Env: SILICA_COMPILER (a copy named silica-compiler), MASS_WORK (scratch dir for mirrors, probes,
# generator output and logs).
#   1. patch the suite Makefile for the trial-support modules (unless --no-patch)
#   2. probe the hand-written form-C trials in a mirror; convert the hand-written run trials
#   3. reshape the suite's train_* pairs through the train generator's shape stage and install them
#   4. make integrate; refresh .ascomp where .sout == .scout (MASS_RUN2=1: make integrate again; the
#      final whole-tree run confirms otherwise)
# Everything is appended to $MASS_WORK/logs/<suite>.log; a one-line summary goes to stdout.
set -uo pipefail
S="$1"; shift
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
C="${SILICA_COMPILER:?SILICA_COMPILER}"
W="${MASS_WORK:?MASS_WORK}"
NO_PATCH=0; NO_TRAIN=0; NO_RUN=0
for a in "$@"; do case "$a" in --no-patch) NO_PATCH=1;; --no-train) NO_TRAIN=1;; --no-run) NO_RUN=1;; esac; done
mkdir -p "$W/logs"
LOG="$W/logs/${S//\//_}.log"
tag="${S//\//_}"
# a suite another queue has claimed is skipped
mkdir "$W/logs/$tag.claimed" 2>/dev/null || { echo "$S: claimed by another queue"; exit 0; }
{
echo "=== $S $(date)"
if [ "$NO_PATCH" = 0 ]; then
  for mf in "$ROOT/trials/$S/Makefile" "$ROOT/trials/$S/makefile"; do
    [ -f "$mf" ] && python3 "$HERE/patch_makefile.py" "$mf"
  done
fi
rm -rf "$W/probe_$tag"
bash "$HERE/mirror.sh" "$W/probe_$tag" "$S" && \
  python3 "$HERE/probe.py" "$W/probe_$tag/trials" "$S" "$C" "$W/probe_$tag.json" --skip-train
python3 "$HERE/convert.py" "$ROOT/trials" "$S" --skip-train --probe "$W/probe_$tag.json" --report "$W/logs/$tag.convert.tsv"
rm -rf "$W/probe_$tag"
if [ "$NO_TRAIN" = 0 ] && ls "$ROOT/trials/$S"/train_*.silica >/dev/null 2>&1; then
  rm -rf "$W/gen_out/$tag"
  (cd "$ROOT/programmer_tools/train_trial_generator" && \
    SILICA_COMPILER="$C" SILICA_GEN_WORK="$W/gen_work" python3 shape_stage.py --installed "$W/gen_out/$tag" "$S" && \
    python3 install.py "$W/gen_out/$tag")
fi
if [ "$NO_RUN" = 0 ]; then
  # one integrate at a time: the outermost integrate takes trials/.integrate.lock and refuses a second
  until mkdir "$W/run.lock" 2>/dev/null; do sleep 10; done
  trap 'rmdir "$W/run.lock" 2>/dev/null' EXIT
  (cd "$ROOT/trials/$S" && make integrate TRIAL_TARGET=host SILICA_COMPILER="$C" SILICA_TARGET_PROMPT=0 > "$W/logs/$tag.run1.log" 2>&1)
  echo "run1: $(cat "$ROOT/trials/$S/.integrate_counts" 2>/dev/null)"
  grep -h '❌' $(find "$ROOT/trials/$S" -name .integrate_log) 2>/dev/null | grep -v 'differs from .ascomp' | head -40
  python3 "$HERE/refresh_ascomp.py" "$ROOT/trials/$S"
  if [ "${MASS_RUN2:-0}" = 1 ]; then
    (cd "$ROOT/trials/$S" && make integrate TRIAL_TARGET=host SILICA_COMPILER="$C" SILICA_TARGET_PROMPT=0 > "$W/logs/$tag.run2.log" 2>&1)
    echo "run2: $(cat "$ROOT/trials/$S/.integrate_counts" 2>/dev/null)"
    grep -h '❌' $(find "$ROOT/trials/$S" -name .integrate_log) 2>/dev/null | head -40
  fi
  rmdir "$W/run.lock"
fi
echo "=== end $S $(date)"
} >> "$LOG" 2>&1
echo "$S: $(grep -E '^(run1|run2):' "$LOG" | tail -2 | tr '\n' ' ') convert: $(grep "^$S {" "$LOG" | tail -1)"
