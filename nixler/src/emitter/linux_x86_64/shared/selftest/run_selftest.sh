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

# Shared-layer self-test for emitter/linux_x86_64: build x86_selftest.silica with the published macOS
# compiler, run it to print one assembler unit that exercises every x86_vr / x86_isa / x86_mem /
# x86_float helper, and assemble that unit with clang (--target=x86_64-linux-gnu) here and with GNU
# as on a Linux x86-64 host (ssh, non-interactive). The unit is never linked or run.
#
#   run_selftest.sh [host-compiler] [linux-host]
#
# Defaults: /Volumes/2T/silica/binaries/silica-compiler and lee@nix.local. Set linux-host to "" to
# skip the GNU as check. The emitted unit is left at selftest_out.s beside this script.

set -eu
here=$(cd "$(dirname "$0")" && pwd)
comp=${1:-/Volumes/2T/silica/binaries/silica-compiler}
linux=${2-lee@nix.local}
selfhost=$(cd "$here/../../../.." && pwd)     # src
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp "$selfhost/data_structures/string_parse.silica" "$tmp"/
for m in x86_vr x86_isa x86_mem x86_float; do cp "$here/../$m.silica" "$tmp"/; done
cp "$here/x86_selftest.silica.txt" "$tmp/x86_selftest.silica"
printf 'string_parse.silica\nx86_vr.silica\nx86_isa.silica\nx86_mem.silica\nx86_float.silica\nx86_selftest.silica\n' > "$tmp/silica.config"
cd "$tmp"
"$comp" > compile.log 2>&1 || { cat compile.log; exit 1; }
for f in *.sams; do clang -c -x assembler "$f" -o "${f%.sams}.o"; done
clang -o prog ./*.o "$selfhost/main_entry_alias.s" "$selfhost/silica_rt_shim.s" "$selfhost/deviceio_link_thunks.s"
./prog > "$here/selftest_out.s" || true   # the exit status is main's atom, not a failure
cd "$here"
n=$(wc -l < selftest_out.s | tr -d ' ')
clang --target=x86_64-linux-gnu -c -x assembler selftest_out.s -o "$tmp/selftest_clang.o"
echo "clang (x86_64-linux-gnu): OK, $n lines"
if [ -n "$linux" ]; then
    scp -q selftest_out.s "$linux:/tmp/silica_x86_selftest.s"
    ssh -o BatchMode=yes "$linux" 'cd /tmp && as silica_x86_selftest.s -o silica_x86_selftest.o && cc -c -x assembler silica_x86_selftest.s -o silica_x86_selftest_cc.o && echo "GNU as: OK"'
fi
