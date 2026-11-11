#!/usr/bin/env bash
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

# Runs this board's own tests (board/tests/<dir>, default pins: the board pin builtins,
# board_pin_builtins_design.md §7) on the attached board, through the trial board driver
# (trials/targets/board_suite.sh) with this tree's compiler. These tests are board specific: they are not
# in trials/ and no hosted run executes them.
#
#   run_pin_tests.sh [--dir <tests subdir>] [--work <dir>] [stem]
#
# With a stem, only that program or compile-failure trial (trials/targets/run_one_trial.sh). Without one,
# the whole directory: the programs are compiled in one run, each is built into an image, loaded into the
# board's RAM and run, and its output compared with <stem>.<target>.scout; each compile-failure trial is
# compiled alone and compared with <stem>.<target>.golden_fail. Assembly goldens are not compared. It
# takes the target's trial lock, so it refuses to start while a make integrate of this board runs.
set -u
TARGET=ESP32-S3_raw
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/../../../../../.." && pwd)
trials_root="$repo_root/trials"
targets="$trials_root/targets"
die() { printf 'run_pin_tests: %s\n' "$*" >&2; exit 2; }

dir=pins work=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dir) [ $# -ge 2 ] || die "--dir needs a name"; dir=$2; shift 2 ;;
        --work) [ $# -ge 2 ] || die "--work needs a directory"; work=$2; shift 2 ;;
        -h|--help) sed -n '16,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1" ;;
        *) break ;;
    esac
done
suite="../compiler/src/emitter/$TARGET/board/tests/$dir"
[ -d "$trials_root/$suite" ] || die "no test directory board/tests/$dir"
if [ $# -ge 1 ]; then
    exec bash "$targets/run_one_trial.sh" --no-ascomp ${work:+--work "$work"} "$TARGET" "$suite" "$1"
fi

conf="$targets/$TARGET.conf"
TARGET_BOARD_DIR=""; TARGET_PYTHON=""; TARGET_IMAGE_EXT="bin"; TARGET_PORT_DEFAULT=""
TARGET_PY_MODULES="esptool serial"; TARGET_TOOLS=""
. "$conf"
tools="$repo_root/$TARGET_BOARD_DIR/tools"
py="${BOARD_PYTHON:-$TARGET_PYTHON}"
compiler="${BOARD_SILICA_COMPILER:-$repo_root/binaries/silica-compiler-$TARGET}"
bash "$targets/trial_target.sh" lock $$ "run_pin_tests $TARGET $dir" "$TARGET" || exit 2
trap 'bash "$targets/trial_target.sh" unlock $$' EXIT
trap 'exit 130' INT TERM
[ -x "$compiler" ] || die "missing $compiler"
[ -x "$py" ] || die "no Python at $py (set BOARD_PYTHON)"
"$py" -c "import ${TARGET_PY_MODULES// /, }" 2>/dev/null || die "$py cannot import ${TARGET_PY_MODULES// /, }"
for t in $TARGET_TOOLS; do command -v "$t" > /dev/null 2>&1 || die "$t not found on PATH"; done
port=${BOARD_PORT:-}
if [ -z "$port" ] && [ -n "$TARGET_PORT_DEFAULT" ] && [ -e "$TARGET_PORT_DEFAULT" ]; then port=$TARGET_PORT_DEFAULT; fi
if [ -z "$port" ]; then
    ports=$("$py" "$tools/run_on_board.py" --list-ports)
    case "$ports" in
        "") die "no board found: no USB serial port" ;;
        *$'\n'*) die "several serial ports ($(echo $ports)); set BOARD_PORT" ;;
    esac
    port=$ports
fi
probe=$("$py" "$tools/run_on_board.py" --probe --port "$port" ${BOARD_MAC:+--expect-mac "$BOARD_MAC"} 2>&1) \
    || die "board check failed: ${probe#run_on_board: }"
if [ -z "$work" ]; then work=$(mktemp -d "${TMPDIR:-/tmp}/run_pin_tests.XXXXXX") || die "cannot make a work directory"; fi
mkdir -p "$work" && work=$(cd "$work" && pwd) || die "cannot make $work"
sh "$tools/build_image.sh" -r "$work/.rt" --prepare > "$work/.rt.log" 2>&1 \
    || die "cannot assemble the board runtime: $(head -5 "$work/.rt.log")"
: > "$work/.skip_trials"
printf 'run_pin_tests: %s board/tests/%s on %s (%s); work area %s\n' "$TARGET" "$dir" "$port" "$probe" "$work"
export TRIAL_TARGET="$TARGET" BOARD_PORT="$port" BOARD_SILICA_COMPILER="$compiler" BOARD_PYTHON="$py" \
    BOARD_TOOLS="$tools" BOARD_RT_CACHE="$work/.rt" TRIALS_ROOT="$trials_root" BOARD_ASCOMP_PLATFORM="" \
    BOARD_IMAGE_EXT="$TARGET_IMAGE_EXT" SILICA_INTEGRATE_ROOT="$work"
bash "$targets/board_suite.sh" "$TARGET" "$suite" "$work"
st=$?
read -r ok ko < "$work/.integrate_counts" 2>/dev/null || { ok=0; ko=1; }
printf 'run_pin_tests: %s passed, %s failed (work area %s)\n' "$ok" "$ko" "$work"
[ "$st" -eq 0 ]
