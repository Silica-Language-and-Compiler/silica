#!/bin/sh
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

# Produce an app's expected.scout on the macOS host: compile the app with the host compiler, link
# and run it, and write "<stdout><exit status>\n" -- the same text the trial harness writes and the
# form run_on_board.py prints for the board. Run it once per app, before the app is tried on the board.
# A process-fatal report line (spec §15.4.5.5) is written folded, "[silica] fault at <PTR>" or
# "[silica] abort: <reason> at <PTR>" (trials/normalize_fatal_reports.awk), since its addresses and the
# fields after them differ between the host and the board; compare with tools/compare_sout.sh.
#
#   host_reference.sh <apps/silica_NN_name> [host-compiler]
#
# Default host compiler: /Volumes/2T/silica/binaries/silica-compiler. Scratch files go to a temporary
# directory. The link uses src/main_entry_alias.s (the `_main` alias) and, when the program
# needs them, silica_rt_shim.s and deviceio_link_thunks.s from the same directory.
#
# An app that uses other modules (the stdlib) lists them in <app>/extra_sources.txt, one path per
# line relative to silica-compiler/, in dependency order; they are compiled before the app's own
# files. The board flow (README) uses the same list.

set -eu
app=$1
comp=${2:-/Volumes/2T/silica/binaries/silica-compiler}
here=$(cd "$(dirname "$0")" && pwd)
selfhost=$(cd "$here/../../../.." && pwd)     # src
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
compiler_root=$(cd "$here/../../../../.." && pwd)     # compiler
normalizer=$(cd "$compiler_root/.." && pwd)/trials/normalize_fatal_reports.awk
: > "$tmp/silica.config"
if [ -f "$app/extra_sources.txt" ]; then
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        cp "$compiler_root/$rel" "$tmp"/
        basename "$rel" >> "$tmp/silica.config"
    done < "$app/extra_sources.txt"
fi
for f in "$app"/*.silica; do cp "$f" "$tmp"/; basename "$f" >> "$tmp/silica.config"; done
cd "$tmp"
"$comp" > compile.log 2>&1 || { cat compile.log; exit 1; }
for f in *.sams; do clang -c -x assembler "$f" -o "${f%.sams}.o"; done
clang -o prog ./*.o "$selfhost/main_entry_alias.s" 2>/dev/null \
  || clang -o prog ./*.o "$selfhost/main_entry_alias.s" "$selfhost/silica_rt_shim.s" 2>/dev/null \
  || clang -o prog ./*.o "$selfhost/main_entry_alias.s" "$selfhost/silica_rt_shim.s" "$selfhost/deviceio_link_thunks.s"
set +e
./prog > out.txt 2>&1
status=$?
set -e
{ cat out.txt; echo "$status"; } | awk -f "$normalizer" > "$OLDPWD/$app/expected.scout"
echo "wrote $app/expected.scout (status $status)"
