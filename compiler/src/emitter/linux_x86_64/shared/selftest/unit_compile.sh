#!/bin/bash
# Copyright 2026 Lee Scott Barney
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Compile ONE emitter/linux_x86_64 module (plus its transitive `use` closure inside src, in
# dependency order) with the published compiler, in a scratch directory. Nothing in the tree is
# built or written; this only answers "does this unit still compile" during the port.
#
#   unit_compile.sh <path/to/module.silica> [scratch-dir] [compiler]
#
# Defaults: scratch = ${TMPDIR:-/tmp}/silica_x86_unit, compiler = /Volumes/2T/silica/binaries/silica-compiler.
# Modules are resolved by basename in src/ (excluding the other emitter targets and the
# retired _struct_parse_test / btree_set_nodeid units). Exit status is the compiler's; on failure the
# compiler's log is printed.

set -eu
mod=$1
scratch=${2:-${TMPDIR:-/tmp}/silica_x86_unit}
comp=${3:-/Volumes/2T/silica/binaries/silica-compiler}
here=$(cd "$(dirname "$0")" && pwd)
selfhost=$(cd "$here/../../../.." && pwd)
mod=$(cd "$(dirname "$mod")" && pwd)/$(basename "$mod")

# index: basename -> path
index=$(mktemp)
( cd "$selfhost" && find . \( -path './_wd_probe' -o -path './emitter' \) -prune -o -type f -name '*.silica' -print; find ./emitter -maxdepth 1 -type f -name '*.silica'; find ./emitter/linux_x86_64 -type f -name '*.silica'; find ./lib -type f -name '*.silica' 2>/dev/null ) \
  | sed 's|^\./||' | grep -v '_struct_parse_test' | grep -v 'btree_set_nodeid\.silica' | grep -v '/selftest/' | LC_ALL=C sort -u \
  | while IFS= read -r p; do printf '%s %s\n' "$(basename "$p" .silica)" "$selfhost/$p"; done > "$index"

path_of() { awk -v n="$1" '$1 == n { print $2; exit }' "$index"; }
uses_of() { grep -E '^use [A-Za-z0-9_]+;' "$1" | sed 's/^use //; s/;.*//'; }

# depth-first post-order over the closure
order=$(mktemp)
seen=$(mktemp)
visit() {
    local name p u
    name=$1
    grep -qx "$name" "$seen" && return 0
    echo "$name" >> "$seen"
    p=$(path_of "$name")
    [ -n "$p" ] || { echo "unit_compile: cannot resolve module '$name'" >&2; return 0; }
    for u in $(uses_of "$p"); do visit "$u"; done
    echo "$p" >> "$order"
}
visit "$(basename "$mod" .silica)"

rm -rf "$scratch"; mkdir -p "$scratch"
: > "$scratch/silica.config"
while IFS= read -r p; do
    cp "$p" "$scratch"/
    basename "$p" >> "$scratch/silica.config"
done < "$order"
n=$(wc -l < "$scratch/silica.config" | tr -d ' ')
cd "$scratch"
# The compiler exits 75 after each unit of a large batch to reclaim memory; re-invoke until it
# finishes (src/Makefile does the same). 76 means it crashed inside a unit; the next run reports
# that unit as failed, skips it and compiles the rest.
: > compile.log
while true; do
    nice -n 19 "$comp" >> compile.log 2>&1 && ec=0 || ec=$?
    [ "$ec" -eq 75 ] && continue
    [ "$ec" -eq 76 ] && continue
    break
done
if [ "$ec" -eq 0 ]; then
    echo "OK   $(basename "$mod") ($n units in closure; scratch $scratch)"
else
    echo "FAIL $(basename "$mod") -- compiler log:"
    grep -v 'Lexing\|Parsing\|checking\|FFI\|Generating\|Emitting\|Finished\|^Compiling\|^Parsing\|^Files\|^[0-9]*$\|reclaim memory\|Compile order' compile.log | tail -30
    exit 1
fi
rm -f "$index" "$order" "$seen"
