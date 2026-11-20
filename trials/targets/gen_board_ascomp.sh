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

# Write the assembly goldens <trial>.<platform>.ascomp of a board target (compile only; the board is not used).
#
#   gen_board_ascomp.sh [--dry-run] [--suite <suite>]... [--trial <stem>] [--work <dir>] <target>
#
# <platform> is TARGET_ASCOMP_PLATFORM of trials/targets/<target>.conf (esp32_s3, later st_nucleo, ...).
# Each suite is compiled with the target's cross compiler exactly as board_suite.sh does (same layout rules,
# same skip list); a golden is written only for a trial whose last board result, <trial>.<target>.sout beside
# the trial, matches its .scout (or <trial>.<target>.scout) by the board run's own comparison
# (board_suite.sh scout_matches: compare_scout_{sorted,multiset,normalized}.sh or diff -Bw). A support module
# gets its golden when its compile unit has an eligible program. An existing golden is never overwritten.
# --dry-run lists what would be written and why each other trial is skipped (GEN-* lines), writes nothing
# in the trials tree. --suite may repeat; --trial limits to one stem (all suites, or those named by --suite).
# BOARD_SILICA_COMPILER overrides binaries/silica-compiler-<target>; TRIALS_ROOT (default: this tree's trials/)
# can point at a copy of the trials for experiments.

set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
trials_root=${TRIALS_ROOT:-$(cd "$here/.." && pwd)}
repo_root=$(cd "$here/../.." && pwd)
die() { echo "gen_board_ascomp: $*" >&2; exit 2; }

mode=write suites=() trial="" work="" target=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) mode=dry ;;
        --suite)   suites+=("${2:?--suite needs a name}"); shift ;;
        --trial)   trial=${2:?--trial needs a stem}; shift ;;
        --work)    work=${2:?--work needs a directory}; shift ;;
        -*)        die "unknown option $1" ;;
        *)         target=$1 ;;
    esac
    shift
done
[ -n "$target" ] || die "usage: gen_board_ascomp.sh [--dry-run] [--suite S]... [--trial T] [--work DIR] <target>"
conf="$here/$target.conf"
[ -f "$conf" ] || die "no $conf"
TARGET_ASCOMP_PLATFORM=""
# shellcheck disable=SC1090
. "$conf"
[ -n "$TARGET_ASCOMP_PLATFORM" ] || die "$conf sets no TARGET_ASCOMP_PLATFORM"
compiler="${BOARD_SILICA_COMPILER:-$repo_root/binaries/silica-compiler-$target}"
[ -x "$compiler" ] || die "missing compiler $compiler"

if [ "${#suites[@]}" -eq 0 ]; then
    for d in "$trials_root"/*/; do
        d=${d%/}; [ -f "$d/Makefile" ] || [ -f "$d/makefile" ] || continue
        suites+=("$(basename "$d")")
    done
fi
[ -n "$work" ] || work=$(mktemp -d)
mkdir -p "$work"
skipfile="$here/$target.skip"
log="$work/gen.log"; : > "$log"

for s in "${suites[@]}"; do
    [ -d "$trials_root/$s" ] || die "no suite $s"
    reason=""
    if [ -f "$skipfile" ]; then
        reason=$(awk -v s="$s" '!/^[[:space:]]*#/ && NF >= 1 && $1 == s { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }' "$skipfile")
        [ -n "$reason" ] || reason=$(awk -v s="$s" '!/^[[:space:]]*#/ && NF == 1 && $1 == s { print "listed in skip file"; exit }' "$skipfile")
    fi
    if [ -n "$reason" ]; then printf 'GEN-SKIP\t%s/\tsuite skipped: %s\n' "$s" "$reason" | tee -a "$log"; continue; fi
    sw="$work/$s"; rm -rf "$sw"; mkdir -p "$sw"
    awk -v s="$s" '!/^[[:space:]]*#/ && index($1, s "/") == 1 { stem = substr($1, length(s) + 2); $1 = ""; sub(/^[[:space:]]+/, ""); printf "%s\t%s\n", stem, $0 }' \
        "$skipfile" > "$sw/.skip_trials" 2>/dev/null
    mkdir -p "$work/.marks"
    TRIALS_ROOT="$trials_root" BOARD_SILICA_COMPILER="$compiler" SILICA_INTEGRATE_ROOT="$work/.marks" \
        BOARD_ASCOMP_PLATFORM="$TARGET_ASCOMP_PLATFORM" BOARD_ASCOMP_GEN="$mode" BOARD_GEN_TRIAL="$trial" \
        BOARD_TOOLS=/nonexistent BOARD_RT_CACHE=/nonexistent BOARD_PYTHON=/nonexistent \
        bash "$here/board_suite.sh" "$target" "$s" "$sw" 2>&1 | tee -a "$log"
done

echo
echo "gen_board_ascomp ($mode, platform $TARGET_ASCOMP_PLATFORM): $(grep -c '^GEN-\(WRITE\|WOULD-WRITE\)' "$log") to write, $(grep -c '^GEN-KEEP' "$log") kept, $(grep -c '^GEN-SKIP' "$log") skipped (work dir $work)"
