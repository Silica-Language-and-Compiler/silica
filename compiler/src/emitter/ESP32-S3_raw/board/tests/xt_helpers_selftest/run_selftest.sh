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

# Hardware self-test of the Xtensa instruction helpers (shared/xt_vr, xt_isa, xt_mem).
#
#   run_selftest.sh <work_dir> [--run]
#
# 1. gen_selftest.py writes a Silica program whose main() calls the real helpers to emit one Xtensa
#    test function per case, plus the assembly header (frame-home .set block, test buffer) and main.
# 2. The seed compiler builds that program for the host; running it prints the Xtensa tests.
# 3. build_image.sh assembles header + tests + main with the board runtime into <work_dir>/selftest.bin.
# 4. With --run, run_on_board.py flashes it and prints "cases N failures M" (exit status = M).
#
# SEED overrides the compiler (default: binaries/seed-compiler, which builds src).

set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ESP=$(cd "$HERE/../../.." && pwd)                       # emitter/ESP32-S3_raw
SH=$(cd "$ESP/../.." && pwd)                            # src
BOARD=$ESP/board
SEED=${SEED:-$(cd "$SH/../.." && pwd)/binaries/seed-compiler}
PY=${PY:-$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/python}

W=${1:?usage: run_selftest.sh <work_dir> [--run]}
mkdir -p "$W"
W=$(cd "$W" && pwd)
B=$W/build
rm -rf "$B"; mkdir -p "$B"

(cd "$W" && python3 "$HERE/gen_selftest.py")
cp "$SH/data_structures/string_parse.silica" "$ESP/shared/xt_vr.silica" "$ESP/shared/xt_isa.silica" \
   "$ESP/shared/xt_mem.silica" "$W/xt_selftest.silica" "$B/"
python3 "$HERE/qualify.py" "$B/xt_selftest.silica" "$B/xt_vr.silica" "$B/xt_isa.silica" "$B/xt_mem.silica"
printf 'string_parse.silica\nxt_vr.silica\nxt_isa.silica\nxt_mem.silica\nxt_selftest.silica\n' > "$B/silica.config"

cd "$B"
# 75: a unit is done, reclaim memory; 76: the compiler crashed in a unit, the next run skips it.
ec=75
while [ $ec -eq 75 ] || [ $ec -eq 76 ]; do perl -e 'alarm 300; exec @ARGV' "$SEED" > compile.log 2>&1 && ec=0 || ec=$?; done
if [ $ec -ne 0 ]; then echo "compile failed ($ec)"; grep -B2 -A12 -i 'error' compile.log | head -60; exit 1; fi
objs=""
for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o"; objs="$objs ${s%.sams}.o"; done
clang $objs -Wl,-e,main -o gen
./gen > tests.S 2> gen.err || true
test -s tests.S || { echo "generator produced nothing"; cat gen.err; exit 1; }
cat "$W/header.S" tests.S "$W/footer.S" > selftest.S
"$BOARD/tools/build_image.sh" -o "$W/selftest" "$B/selftest.S"

if [ "${2:-}" = "--run" ]; then
    "$PY" "$BOARD/tools/run_on_board.py" --timeout 60 "$W/selftest.bin"
fi
