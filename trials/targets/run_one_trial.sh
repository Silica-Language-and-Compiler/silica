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

# Run ONE trial of a board target, the way `make integrate TRIAL_TARGET=<target>` runs it, without the
# rest of the suite (see README.md in this directory).
#
#   run_one_trial.sh [--no-ascomp] [--work <dir>] <target> <suite> <stem>
#
# It reads trials/targets/<target>.conf, then calls board_suite.sh with BOARD_ONLY_STEM=<stem>, so the
# staging (the trial, the suite's lib/ modules, the trial-support module the trial `use`s and Supervisor),
# the compile with binaries/silica-compiler-<target>, the assembly-golden check, the image build with the
# target's board/tools/build_image.sh, the load and run through the target's board/tools/run_on_board.py
# and the comparison with <stem>.scout (or <stem>.<target>.scout) with the suite's compare script are the
# suite run's own code. The diff is printed on a mismatch. A compile-failure trial (.golden_fail) works too.
#
# Work area: <dir>, else a new directory under $TMPDIR (kept; its path is printed). The board's output is
# written beside the trial as <stem>.<target>.sout, as in a suite run. --no-ascomp skips the
# <stem>.<platform>.ascomp check (output only). Refuses to start while a `make integrate` run holds the
# trial lock (trial_target.sh status). Exit status: 0 the trial passed, 1 it failed, 2 usage or setup.

set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
trials_root=$(cd "$here/.." && pwd)
repo_root=$(cd "$trials_root/.." && pwd)
die() { printf 'run_one_trial: %s\n' "$*" >&2; exit 2; }

ascomp=1 work=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-ascomp) ascomp=0; shift ;;
        --work) [ $# -ge 2 ] || die "--work needs a directory"; work=$2; shift 2 ;;
        -h|--help) sed -n '15,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option $1" ;;
        *) break ;;
    esac
done
[ $# -eq 3 ] || die "usage: run_one_trial.sh [--no-ascomp] [--work <dir>] <target> <suite> <stem>"
target=$1 suite=$2 stem=$3

conf="$here/$target.conf"
[ -f "$conf" ] || die "unknown trial target '$target' (no $conf)"
[ -d "$trials_root/$suite" ] || die "no suite $suite"
[ -f "$trials_root/$suite/$stem.silica" ] || die "no trial $suite/$stem.silica"

TARGET_DESCRIPTION=""; TARGET_BOARD_DIR=""; TARGET_PYTHON=""; TARGET_ASCOMP_PLATFORM=""
TARGET_IMAGE_EXT="bin"; TARGET_PORT_DEFAULT=""; TARGET_PY_MODULES="esptool serial"; TARGET_TOOLS=""
# shellcheck disable=SC1090
. "$conf"
tools="$repo_root/$TARGET_BOARD_DIR/tools"
py="${BOARD_PYTHON:-$TARGET_PYTHON}"
compiler="${BOARD_SILICA_COMPILER:-$repo_root/binaries/silica-compiler-$target}"

bash "$here/trial_target.sh" check "run_one_trial $target $suite/$stem" || exit 2
[ -x "$compiler" ] || die "missing $compiler (cd compiler/src && make TARGET=$target)"
[ -x "$py" ] || die "no Python at $py (set BOARD_PYTHON)"
"$py" -c "import ${TARGET_PY_MODULES// /, }" 2>/dev/null || die "$py cannot import ${TARGET_PY_MODULES// /, }"
for t in $TARGET_TOOLS; do command -v "$t" > /dev/null 2>&1 || die "$t not found on PATH"; done
[ -f "$tools/run_on_board.py" ] && [ -f "$tools/build_image.sh" ] || die "board tools missing under $tools"

# Port, as trial_target.sh chooses it (without the interactive menu).
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

if [ -z "$work" ]; then work=$(mktemp -d "${TMPDIR:-/tmp}/run_one_trial.XXXXXX") || die "cannot make a work directory"; fi
mkdir -p "$work" || die "cannot make $work"
work=$(cd "$work" && pwd)
sh "$tools/build_image.sh" -r "$work/.rt" --prepare > "$work/.rt.log" 2>&1 \
    || die "cannot assemble the board runtime: $(head -5 "$work/.rt.log")"
: > "$work/.skip_trials"

platform="$TARGET_ASCOMP_PLATFORM"
[ "$ascomp" = 1 ] || platform=""
printf 'run_one_trial: %s %s/%s on %s (%s); work area %s\n' "$target" "$suite" "$stem" "$port" "$probe" "$work"

export TRIAL_TARGET="$target" BOARD_PORT="$port" BOARD_SILICA_COMPILER="$compiler" BOARD_PYTHON="$py" \
    BOARD_TOOLS="$tools" BOARD_RT_CACHE="$work/.rt" TRIALS_ROOT="$trials_root" \
    BOARD_ASCOMP_PLATFORM="$platform" BOARD_IMAGE_EXT="$TARGET_IMAGE_EXT" \
    BOARD_ONLY_STEM="$stem" SILICA_INTEGRATE_ROOT="$work"
bash "$here/board_suite.sh" "$target" "$suite" "$work"
st=$?
if [ "$st" -eq 0 ]; then echo "run_one_trial: PASS $suite/$stem"; else echo "run_one_trial: FAIL $suite/$stem (work area $work)"; st=1; fi
exit $st
