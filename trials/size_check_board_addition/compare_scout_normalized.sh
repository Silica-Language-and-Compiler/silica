#!/usr/bin/env bash
[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"   # pipefail needs bash; /bin/sh is dash on Debian and Ubuntu
# Ordered .sout / .scout compare (diff -Bw) after folding the process-fatal report lines of
# silica-specification §15.4.5.5 with ../normalize_fatal_reports.awk: a fault line keeps only
# "[silica] fault at <PTR>", an abort line only "[silica] abort: <reason> at <PTR>". Every other line is
# compared exactly as before. The Makefile uses this for every trial in the suite; the board harness
# (../targets/board_suite.sh) uses it too.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: compare_scout_normalized.sh <actual.sout> <golden.scout>" >&2
  exit 2
fi

here="$(cd "$(dirname "$0")" && pwd)"
normalizer="$here/../normalize_fatal_reports.awk"

tmp_actual="$(mktemp)"
tmp_golden="$(mktemp)"
trap 'rm -f "$tmp_actual" "$tmp_golden"' EXIT

awk -f "$normalizer" "$1" > "$tmp_actual"
awk -f "$normalizer" "$2" > "$tmp_golden"

diff -Bw "$tmp_actual" "$tmp_golden"
