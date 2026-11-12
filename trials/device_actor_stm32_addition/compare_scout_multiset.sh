#!/usr/bin/env bash
[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"   # pipefail needs bash; /bin/sh is dash on Debian and Ubuntu
set -euo pipefail

# Golden comparison for the trials of this suite marked <stem>.scout.multiset (the suite Makefile, and
# trials/targets/board_suite.sh for board runs). Every such trial prints actor failure reports, which
# the registered FailureReporter prints asynchronously (Lee, 2026-10-12), so the shared order-free
# compare applies: report blocks and other lines as multisets, the exit-status line last and exact.
# See ../compare_scout_unordered.sh.

if [ "$#" -ne 2 ]; then
  echo "usage: compare_scout_multiset.sh <actual.sout> <golden.scout>" >&2
  exit 2
fi

exec bash "$(cd "$(dirname "$0")" && pwd)/../compare_scout_unordered.sh" "$1" "$2"
