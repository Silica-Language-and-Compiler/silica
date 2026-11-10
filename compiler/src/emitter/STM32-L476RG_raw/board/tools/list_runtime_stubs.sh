#!/bin/sh
# Prints the silica_rt_* entries the emitter tree references that board/runtime/*.S does not define:
# the list rt_stubs.S must carry (regenerate it when an entry is ported or the emitter grows one).
#   list_runtime_stubs.sh            the missing names, one per line
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tree="$here/../.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
grep -rhoE '_?silica_(rt_[a-z0-9_]+|pid_registry_init|dangerous_pid_registry_init|device_pid_registry_init)' --include='*.silica' "$tree" \
    | sed 's/^_//' | grep -v -e '^silica_rt_atom_name' -e '^silica_rt_string_$' -e '^silica_rt_list_$' -e '^silica_rt_tr_$' \
        -e '_tag$' -e '^silica_rt_sup_self_error_atom$' | sort -u > "$tmp/needed"
cd "$here/../runtime"
{ grep -hoE '^\s*(FUNC|LFUNC|STUB|RETURN_ZERO|UNPORTED|CAST_REGISTERED|REGISTER_NAMED|REQUIRE_FREE|ABORT_ENTRY|FAILURE_ENTRY|FAULT_VECTOR|ROW_FIELD)\s+[A-Za-z0-9_]+' *.S | awk '{print $2}'
  grep -hoE '^\s*\.global\s+\S+' *.S | awk '{print $2}'; } | sort -u > "$tmp/defined"
comm -23 "$tmp/needed" "$tmp/defined"
