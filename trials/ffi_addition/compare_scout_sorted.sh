#!/usr/bin/env bash
[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"   # pipefail needs bash; /bin/sh is dash on Debian and Ubuntu
set -euo pipefail

# Golden comparison for the app trials marked <stem>.scout.sorted
# (app_supervisor_dangerous_guarded_fault_trials/Makefile). Each such trial prints an actor failure
# report, which the registered FailureReporter prints asynchronously (Lee, 2026-10-12), so the
# shared order-free compare applies: report blocks and other lines as multisets, the exit-status line
# last and exact, pointers folded. (It replaced a plain sort of the normalized lines.)
# See ../compare_scout_unordered.sh.

if [ "$#" -ne 2 ]; then
  echo "usage: compare_scout_sorted.sh <actual.sout> <golden.scout>" >&2
  exit 2
fi

exec bash "$(cd "$(dirname "$0")" && pwd)/../compare_scout_unordered.sh" "$1" "$2"
