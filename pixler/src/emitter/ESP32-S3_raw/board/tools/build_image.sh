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

# Build a bare-metal ESP32-S3 image from program sources plus the board runtime.
#
#   build_image.sh [-q] [-r <runtime-cache-dir>] -o <out_dir>/<name> <source>...
#   build_image.sh -r <runtime-cache-dir> --prepare
#
# -r keeps the assembled runtime objects in <runtime-cache-dir> and reuses them (reassembling a
#    file only when its source is newer), instead of assembling the runtime for every image; the
#    trial driver prepares the cache once per run with --prepare, before any parallel use.
# -q prints nothing on success (the section sizes and the image path are otherwise printed).
#
# Sources are .S/.s hand-written assembly or .sams emitted by an ESP32-S3_raw silica-compiler.
# Produces <name>.elf, <name>.map, <name>.bin (flash at offset 0x0 with flash_image.sh) and
# <name>.stack, the sizes chosen for main's two stacks. Actor stacks are chunks grown at run time
# (actor_memory_budget_plan.md item F) and need nothing from the build.
#
# main's stacks are sized per image (actor_memory_budget_plan.md §4.1, item D): the image is linked
# once with small main stacks (4 KB + 1 KB, only to measure), main_stack_bound.py walks the linked code from _start for
# the deepest chain of windowed frames and the deepest auxiliary-stack reservation, and the image is
# linked again with --defsym _silica_main_stack_req / _silica_main_aux_req set to those bounds plus
# margin (a quarter, at least 128 bytes, then the 64-byte guard band, rounded up to 64) and
# _silica_rt_depth_reserve set to the deepest runtime chain emitted code can call (the limit every
# emitted prologue checks against). A main the walk cannot bound keeps the script's defaults
# (128 KB + 64 KB) and the .stack file says why. The second link moves only the heap/stack boundary,
# so the bound taken from the first image holds for the second.
#
# Toolchain: Espressif's xtensa-esp-elf GCC (assembler, linker, libgcc) and esptool from the
# ESP-IDF Python environment. No ESP-IDF component, header or library is linked.
# Override XTENSA_BIN / ESPTOOL if they live elsewhere.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
RT="$HERE/../runtime"
XTENSA_BIN=${XTENSA_BIN:-$HOME/.espressif/tools/xtensa-esp-elf/esp-16.1.0_20260609/xtensa-esp-elf/bin}
ESPTOOL=${ESPTOOL:-$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/esptool}
CC="$XTENSA_BIN/xtensa-esp32s3-elf-gcc"

out=""
rtcache=""
quiet=0
prepare=0
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        -r) rtcache=$2; shift 2 ;;
        -q) quiet=1; shift ;;
        --prepare) prepare=1; shift ;;
        *) break ;;
    esac
done
if [ "$prepare" = 1 ] && [ -z "$rtcache" ]; then
    echo "usage: $0 -r <runtime-cache-dir> --prepare" >&2
    exit 2
fi
if [ "$prepare" = 0 ] && { [ -z "$out" ] || [ $# -eq 0 ]; }; then
    echo "usage: $0 [-q] [-r <runtime-cache-dir>] -o <out_dir>/<name> <source>..." >&2
    exit 2
fi

# --longcalls: CALL8 reaches +-512 KB, relaxed to L32R+CALLX8 when a target is further away.
# --auto-litpools is NOT used: literals go to .literal sections, which the link script puts in
# front of .text (L32R only reaches backwards, 256 KB).
ASFLAGS="-c -mlongcalls"

RUNTIME_SOURCES="rt_vectors.S rt_start.S rt_console.S rt_heap.S rt_board.S rt_device.S rt_string.S rt_list.S rt_float.S rt_ordering.S rt_actors.S rt_supervisors.S"

# Runtime objects: from the cache (assembled only when missing or older than the source; written
# to a temporary name and renamed, so a concurrent reader never sees a partial object), or fresh.
objs=""
if [ -n "$rtcache" ]; then
    mkdir -p "$rtcache"
    for f in $RUNTIME_SOURCES; do
        obj="$rtcache/${f%.S}.o"
        if [ ! -f "$obj" ] || [ "$RT/$f" -nt "$obj" ]; then
            "$CC" $ASFLAGS "$RT/$f" -o "$obj.tmp.$$" && mv "$obj.tmp.$$" "$obj"
        fi
        objs="$objs $obj"
    done
    [ "$prepare" = 1 ] && exit 0
fi

mkdir -p "$(dirname "$out")"
objdir="$out.objs"
rm -rf "$objdir"
mkdir -p "$objdir"

n=0
if [ -z "$rtcache" ]; then
    for f in $RUNTIME_SOURCES; do
        n=$((n + 1))
        obj="$objdir/$n.${f%.S}.o"
        "$CC" $ASFLAGS "$RT/$f" -o "$obj"
        objs="$objs $obj"
    done
fi
for src in "$@"; do
    n=$((n + 1))
    base=$(basename "$src")
    obj="$objdir/$n.${base%.*}.o"
    case "$src" in
        *.sams) "$CC" $ASFLAGS -x assembler "$src" -o "$obj" ;;
        *)      "$CC" $ASFLAGS "$src" -o "$obj" ;;
    esac
    objs="$objs $obj"
done

link() {   # the --defsym options must precede -T: the script tests DEFINED() on them
    "$CC" -nostdlib -nostartfiles -Wl,--gc-sections "$@" -Wl,-T,"$RT/silica_esp32s3.ld" \
        -Wl,-Map,"$out.map" -o "$out.elf" $objs -lgcc
}

# Pass 1: small main stacks, only to measure. Pass 2: main's stacks and the runtime reserve from
# the bound, or the script's defaults (the code's addresses must not move between the passes: the
# bound was taken from pass 1; the stack sizes move only the heap/stack boundary). Measuring with
# the 128 KB + 64 KB defaults made a large but legal image fail the linker's heap-room assertion
# before its stack bound was ever taken.
link -Wl,--defsym,_silica_main_stack_req=4096 -Wl,--defsym,_silica_main_aux_req=1024
PY=${BOARD_PYTHON:-python3}
bound=$("$PY" "$HERE/main_stack_bound.py" --objdump "$XTENSA_BIN/xtensa-esp32s3-elf-objdump" "$out.elf") || {
    echo "main_stack_bound.py failed for $out.elf" >&2; exit 1; }
main1=$("$XTENSA_BIN/xtensa-esp32s3-elf-nm" "$out.elf" | awk '$3 == "_silica_iram_end" {print $1}')
status=$(printf '%s\n' "$bound" | sed -n 's/^status //p')
machine=$(printf '%s\n' "$bound" | sed -n 's/^machine //p')
aux=$(printf '%s\n' "$bound" | sed -n 's/^aux //p')
rt_depth=$(printf '%s\n' "$bound" | sed -n 's/^rt_depth //p')
[ "$rt_depth" -lt 64 ] && rt_depth=64        # the overflow handlers' own two frames
size_with_margin() {                         # bound -> bound + max(bound/4, 128) + guard 64, up to 64
    m=$(( $1 / 4 )); [ "$m" -lt 128 ] && m=128
    echo $(( ( $1 + m + 64 + 63 ) / 64 * 64 ))
}
case "$status $aux" in
    "bounded "[0-9]*)
        stack=$(size_with_margin "$machine")
        auxsz=$(size_with_margin "$aux")
        [ "$auxsz" -lt 256 ] && auxsz=256
        link -Wl,--defsym,_silica_main_stack_req=$stack -Wl,--defsym,_silica_main_aux_req=$auxsz \
             -Wl,--defsym,_silica_rt_depth_req=$rt_depth
        printf 'main_stack %d\nmain_aux %d\nbound_machine %d\nbound_aux %d\nrt_depth %d\nstatus bounded\n' \
            "$stack" "$auxsz" "$machine" "$aux" "$rt_depth" > "$out.stack"
        ;;
    *)
        # unbounded (recursion from main, a call through a function value, or an untracked SP
        # store): the script's defaults stay; the reserve is still exact for this image
        link -Wl,--defsym,_silica_rt_depth_req=$rt_depth
        stack=$(( 0x20000 )); auxsz=$(( 0x10000 ))
        reason=$status; case "$aux" in unbounded*) [ "$status" = bounded ] && reason="aux $aux" ;; esac
        printf 'main_stack %d\nmain_aux %d\nbound_machine %s\nbound_aux %s\nrt_depth %d\nstatus %s\n' \
            "$stack" "$auxsz" "$machine" "$aux" "$rt_depth" "$reason" > "$out.stack"
        ;;
esac
main2=$("$XTENSA_BIN/xtensa-esp32s3-elf-nm" "$out.elf" | awk '$3 == "_silica_iram_end" {print $1}')
if [ "$main1" != "$main2" ]; then
    echo "build_image: the code moved between the two links ($main1 -> $main2); the bound was taken from the first" >&2
    exit 1
fi

"$ESPTOOL" --chip esp32s3 elf2image --flash-mode dio --flash-freq 80m --flash-size 2MB \
    -o "$out.bin" "$out.elf" >/dev/null

[ "$quiet" = 1 ] && exit 0
"$XTENSA_BIN/xtensa-esp32s3-elf-size" -A "$out.elf" | awk '/^\.(iram0|dram0)/ {printf "  %-16s %7d bytes @ %s\n", $1, $2, sprintf("0x%x", $3)}'
hs=$("$XTENSA_BIN/xtensa-esp32s3-elf-nm" "$out.elf" | awk '$3 == "_silica_heap_start" {print $1}')
he=$("$XTENSA_BIN/xtensa-esp32s3-elf-nm" "$out.elf" | awk '$3 == "_silica_heap_end" {print $1}')
heap=$(( 0x$he - 0x$hs ))
echo "  main stacks: machine $stack aux $auxsz ($(sed -n 's/^status //p' "$out.stack"); bound $machine/$aux, runtime reserve $rt_depth)${heap:+; heap $heap bytes}"
echo "  image: $out.bin"
