#!/usr/bin/env bash
[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"   # pipefail needs bash; /bin/sh is dash on Debian and Ubuntu
set -euo pipefail

# Golden comparison for the trials of this suite marked <stem>.scout.multiset (see README.md).
#
# The order in which ready actors sharing one core are dispatched is defined only on a target whose
# runtime owns a per-core ready queue (ESP32-S3_raw). On a hosted target the actors are threads the OS
# schedules, so the same program prints the same lines in an order nobody defines. Hence two readings
# of one golden:
#   - a raw target's golden (<stem>.ESP32-S3_raw.scout, the board's reviewed expectation) is compared
#     in order, line for line, as diff -Bw does;
#   - every other golden -- the shared <stem>.scout, and a hosted target's <stem>.<target>.scout
#     (silica_compiler.mk SCOUT_FOR) -- is compared as a multiset of lines: the same lines, any order.
# The last line of both is the exit status, compared like any other line.

if [ "$#" -ne 2 ]; then
  echo "usage: compare_scout_multiset.sh <actual.sout> <golden.scout>" >&2
  exit 2
fi
actual=$1 golden=$2
case "$(basename "$golden" .scout)" in
  *.*_raw)  # <stem>.<raw target>.scout: the board's own expectation, compared in order
    diff -Bw "$actual" "$golden"
    exit $? ;;
esac
# No process substitution: when make runs this as `/bin/sh script` (bash in posix mode on macOS) the
# BASH_VERSION guard passes but <( ) is a syntax error, so sort into temp files instead.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/scout_multiset.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
grep -v '^[[:space:]]*$' "$actual" | sed 's/[[:space:]]*$//' | LC_ALL=C sort > "$tmp/actual" || true
grep -v '^[[:space:]]*$' "$golden" | sed 's/[[:space:]]*$//' | LC_ALL=C sort > "$tmp/golden" || true
diff -Bw "$tmp/actual" "$tmp/golden"
