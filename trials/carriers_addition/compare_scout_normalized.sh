#!/usr/bin/env bash
[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"   # pipefail needs bash; /bin/sh is dash on Debian and Ubuntu
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: compare_scout_normalized.sh <actual.sout> <golden.scout>" >&2
  exit 2
fi

actual="$1"
golden="$2"

normalize_pointer_lines() {
  awk '
    {
      gsub(/\r/, "", $0)
    }
    # A null pointer prints as (nil) under glibc and as 0x0 on Darwin: same value either way.
    # actor_id is the 64-bit identity in decimal on current runtimes (an address on older ones).
    /^[[:space:]]*actor_id:[[:space:]]*(0x[0-9a-fA-F]+|\(nil\)|[0-9]+)$/ {
      print "actor_id:        <PTR>"
      next
    }
    /^[[:space:]]*supervisor_acb:[[:space:]]*(0x[0-9a-fA-F]+|\(nil\))$/ {
      print "supervisor_acb:  <PTR>"
      next
    }
    /^[[:space:]]*#[0-9]+[[:space:]]+_[A-Za-z_]/ {
      # Call-stack frame naming a C symbol: Mach-O decorates it with a leading underscore and
      # ELF does not, so the same function prints two ways. Compare the undecorated name.
      # (No apostrophes in this awk program: it is inside a single-quoted shell string.)
      sub(/_/, "")
      print
      next
    }
    { print }
  ' "$1" | awk -f "$(dirname "$0")/../normalize_fatal_reports.awk"
}
# The second awk folds the process-fatal report lines of spec §15.4.5.5 (`[silica] fault at <PTR>`,
# `[silica] abort: <reason> at <PTR>`) the way every other suite does: their addresses differ between
# the host and the ESP32-S3 board (stack_policy_registered_forms has a board golden with one).

tmp_actual="$(mktemp)"
tmp_golden="$(mktemp)"
trap 'rm -f "$tmp_actual" "$tmp_golden"' EXIT

normalize_pointer_lines "$actual" > "$tmp_actual"
normalize_pointer_lines "$golden" > "$tmp_golden"

diff -Bw "$tmp_actual" "$tmp_golden"
