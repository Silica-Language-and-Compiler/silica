#!/bin/sh
# Copyright 2026 COPYRIGHT-HOLDER-PLACEHOLDER (to be decided before this is merged)
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

# Build an ESP32-S3 image in which a Silica program runs as a guest of ESP-IDF
# (transport_ble_plan.md §2.1). The interface is ../../tools/build_image.sh's, so the board trial
# driver and run_app.sh use either:
#
#   build_image.sh [-q] [-r <cache-dir>] -o <out_dir>/<name> <source>...
#   build_image.sh [-r <cache-dir>] --prepare
#
# The cache holds the ESP-IDF application (../idf_app) built once without a program, the command that
# links it, and the Silica runtime's objects (../../runtime/rt_*.S assembled with SILICA_GUEST, less
# rt_start.S and rt_vectors.S, plus ../runtime/rt_guest_*.S). --prepare fills it; an image build fills
# it first when it is empty, so prepare before any parallel use. Without -r the cache is
# ../.cache (ignored by git). An image is the application's own link with the runtime's and the
# program's objects added, so it takes a link, not an ESP-IDF build.
#
# Sources are those of the bare-metal builder: .sams emitted by the ESP32-S3_raw silica-compiler, .S/.s,
# .c foreign-call wrappers, .o objects and .a archives. A .c file is compiled as ESP-IDF compiles the
# silica_guest component's own C (its flags, include paths and sdkconfig.h, with the file's directory
# and BOARD_CFLAGS added), so a wrapper may call ESP-IDF: the Bluetooth controller, NVS, FreeRTOS. Produces <name>.elf, <name>.map, <name>.stack and <name>.bin:
# the bootloader, the partition table and the application merged, to be written to flash at offset 0
# (tools/run_on_board.py here does that).
#
# main's stacks and the runtime reserve are sized per image as on bare metal (two links around
# ../../tools/main_stack_bound.py), with what ESP-IDF needs on the running stack added to the reserve
# (silica_guest_stack_allowance, idf_app/components/silica_guest/guest_consts.S).
#
# Silica's memory is one block of GUEST_RAM bytes: main's two stacks, sized per image, and the heap,
# which gets the rest, as on bare metal the stack sizes move only the heap's end. The rest of the
# chip's RAM is ESP-IDF's (about 350 KB in all before a program is added, of which some 260 KB can
# hold a program's static data such as this block, less some 59 KB when the Bluetooth controller and
# NimBLE are linked in; the two take some 67 KB more from ESP-IDF's heap when they start, which
# leaves it 43 KB beside a block of 208 KB: transport_ble_plan.md §6, stage 6).
#
# Environment: IDF_PATH (default ~/esp/esp-idf-v6.2), XTENSA_BIN, ESPTOOL, BOARD_PYTHON as for the
# bare-metal builder; GUEST_RAM (bytes) Silica's block, by default 245760 (240 KB), or 212992 (208 KB)
# for a program whose foreign code calls a radio's API; GUEST_HEAP_SIZE the
# heap, when it is to be fixed instead; BOARD_FFI_STACK the machine stack of a foreign call (default
# 8192: a wrapper here may call into ESP-IDF).

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
RT="$HERE/../../runtime"
GRT="$HERE/../runtime"
APP="$HERE/../idf_app"
IDF_PATH=${IDF_PATH:-$HOME/esp/esp-idf-v6.2}
XTENSA_BIN=${XTENSA_BIN:-$HOME/.espressif/tools/xtensa-esp-elf/esp-16.1.0_20260609/xtensa-esp-elf/bin}
ESPTOOL=${ESPTOOL:-$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/esptool}
CC="$XTENSA_BIN/xtensa-esp32s3-elf-gcc"
NM="$XTENSA_BIN/xtensa-esp32s3-elf-nm"

out=""
rtcache="$HERE/../.cache"
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
if [ "$prepare" = 0 ] && { [ -z "$out" ] || [ $# -eq 0 ]; }; then
    echo "usage: $0 [-q] [-r <cache-dir>] -o <out_dir>/<name> <source>..." >&2
    echo "       $0 [-r <cache-dir>] --prepare" >&2
    exit 2
fi

ASFLAGS="-c -mlongcalls -DSILICA_GUEST"
# GUEST_STRESS=1: the stress build (../README.md); its runtime objects are kept apart in the cache.
rtsuffix=""
if [ "${GUEST_STRESS:-0}" != 0 ]; then ASFLAGS="$ASFLAGS -DSILICA_GUEST_STRESS"; rtsuffix=".stress"; fi
RUNTIME_SOURCES="rt_console.S rt_heap.S rt_frame.S rt_state.S rt_board.S rt_device.S rt_string.S rt_list.S rt_transport.S rt_float.S rt_ordering.S rt_actors.S rt_supervisors.S rt_ffi.S"
GUEST_SOURCES="rt_guest_start.S rt_guest_fault.S"

# The cache: the ESP-IDF application, its link command, the runtime objects. The application is
# rebuilt when one of its sources is newer than the recorded link command.
mkdir -p "$rtcache"
rtcache=$(cd "$rtcache" && pwd)
stale=0
[ -f "$rtcache/link.cmd" ] || stale=1
if [ "$stale" = 0 ] && [ -n "$(find "$APP" -type f -newer "$rtcache/link.cmd" | head -1)" ]; then stale=1; fi
if [ "$stale" = 1 ]; then
    [ -f "$IDF_PATH/export.sh" ] || { echo "build_image: no ESP-IDF at $IDF_PATH (set IDF_PATH)" >&2; exit 1; }
    rm -f "$rtcache/sdkconfig"      # made again from sdkconfig.defaults, which may be what changed
    (
        . "$IDF_PATH/export.sh" > /dev/null 2>&1
        idf.py -C "$APP" -B "$rtcache/idf" -D SDKCONFIG="$rtcache/sdkconfig" build > "$rtcache/idf_build.log" 2>&1
    ) || { echo "build_image: the ESP-IDF application did not build; see $rtcache/idf_build.log" >&2
           grep -m 12 -E 'error|undefined reference' "$rtcache/idf_build.log" >&2 || tail -n 12 "$rtcache/idf_build.log" >&2
           exit 1; }
    ( cd "$rtcache/idf" && ninja -t commands silica_guest_app.elf | tail -n 1 | sed -e 's/^: && //' -e 's/ && :$//' ) > "$rtcache/link.cmd.tmp.$$"
    grep -q -- ' -o silica_guest_app.elf ' "$rtcache/link.cmd.tmp.$$" || { echo "build_image: the application's link command has no '-o silica_guest_app.elf'" >&2; exit 1; }
    # how ESP-IDF compiles the component's guest.c, less its output and source: the wrappers' compile
    "${BOARD_PYTHON:-python3}" - "$rtcache/idf/compile_commands.json" > "$rtcache/cc.cmd" <<'PYEOF' || { echo "build_image: no compile command for guest.c in the application's build" >&2; exit 1; }
import json, sys
for e in json.load(open(sys.argv[1])):
    if e["file"].endswith("/silica_guest/guest.c"):
        c = e["command"]
        i = c.rindex(" -o ")
        print(c[:i])
        sys.exit(0)
sys.exit(1)
PYEOF
    # The {function address, name} records every emitted function carries (.rodata.silica_fnames) must
    # lie together between _silica_fnames_start and _silica_fnames_end, where a failure report reads
    # them (../../runtime/silica_esp32s3.ld does this for the bare-metal image). ESP-IDF's generated
    # script would scatter them among its .rodata.*, and a linker fragment cannot place a pattern
    # ahead of that one, so the images link with a copy of the script that names them first.
    awk '/_flash_rodata_start = / { inro = 1 }
         inro && !done && / \.rodata / { print "    . = ALIGN(4);"; print "    _silica_fnames_start = ABSOLUTE(.);"
                                         print "    *(.rodata.silica_fnames)"; print "    _silica_fnames_end = ABSOLUTE(.);"; done = 1 }
         { print }
         END { exit done ? 0 : 1 }' "$rtcache/idf/esp-idf/esp_system/ld/sections.ld" > "$rtcache/sections_silica.ld" \
        || { echo "build_image: ESP-IDF's sections.ld has no .rodata pattern to place the function-name records before" >&2; exit 1; }
    grep -q -- ' -T sections.ld ' "$rtcache/link.cmd.tmp.$$" || { echo "build_image: the application's link command has no '-T sections.ld'" >&2; exit 1; }
    "$NM" "$rtcache/idf/esp-idf/silica_guest/libsilica_guest.a" 2>/dev/null | awk '$3 == "silica_guest_stack_allowance" { print $1 }' > "$rtcache/stack_allowance"
    [ -s "$rtcache/stack_allowance" ] || { echo "build_image: the application has no silica_guest_stack_allowance" >&2; exit 1; }
    mv "$rtcache/link.cmd.tmp.$$" "$rtcache/link.cmd"
fi
objs=""
for f in $RUNTIME_SOURCES $GUEST_SOURCES; do
    case "$f" in rt_guest_*) src="$GRT/$f" ;; *) src="$RT/$f" ;; esac
    obj="$rtcache/${f%.S}$rtsuffix.o"
    if [ ! -f "$obj" ] || [ "$src" -nt "$obj" ]; then
        "$CC" $ASFLAGS "$src" -o "$obj.tmp.$$" && mv "$obj.tmp.$$" "$obj"
    fi
    objs="$objs $obj"
done
[ "$prepare" = 1 ] && exit 0

mkdir -p "$(dirname "$out")"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
objdir="$out.objs"
rm -rf "$objdir"
mkdir -p "$objdir"

n=0
libs=""
emitted=""
for src in "$@"; do
    n=$((n + 1))
    base=$(basename "$src")
    obj="$objdir/$n.${base%.*}.o"
    case "$src" in
        *.sams) "$CC" -c -mlongcalls -x assembler "$src" -o "$obj"; emitted="$emitted $obj" ;;
        *.c)    srcabs="$(cd "$(dirname "$src")" && pwd)/$base"
                printf '%s -I%s %s -o %s -c %s\n' "$(cat "$rtcache/cc.cmd")" "$(dirname "$srcabs")" "${BOARD_CFLAGS:-}" "$obj" "$srcabs" > "$obj.cmd"
                ( cd "$rtcache/idf" && sh "$obj.cmd" ) ;;
        *.o)    obj=$(cd "$(dirname "$src")" && pwd)/$base ;;
        *.a)    libs="$libs $(cd "$(dirname "$src")" && pwd)/$base"; continue ;;
        *)      "$CC" $ASFLAGS "$src" -o "$obj" ;;
    esac
    objs="$objs $obj"
done
# The emitted code's symbols, for the stack walk: in this image the code that is not emitted includes
# ESP-IDF's, which the walk's name rule would take for emitted code.
: > "$out.emitted_syms"
for o in $emitted; do "$NM" "$o" | awk '$2 ~ /^[TtWw]$/ { print $3 }' >> "$out.emitted_syms"; done

# Silica's block: 240 KB, or 208 KB when the program's foreign code calls a radio's API (ESP-IDF's
# Bluetooth or Wi-Fi), since the radio's code then takes static memory and heap of its own.
radio=0
for o in $objs $libs; do
    case " $emitted " in *" $o "*) continue ;; esac
    case "$o" in "$rtcache"/*) continue ;; esac
    if "$NM" -u "$o" 2>/dev/null | grep -q -E ' (esp_bt_|esp_vhci_|esp_nimble_|nimble_|ble_|esp_wifi_|esp_netif_)'; then radio=1; fi
done
if [ "$radio" = 1 ]; then ram=${GUEST_RAM:-212992}; else ram=${GUEST_RAM:-245760}; fi
ffi=${BOARD_FFI_STACK:-8192}
allowance=$(( 0x$(cat "$rtcache/stack_allowance") ))

# link <main stack> <aux stack> <reserve>: the memory block with those sizes, then the application's
# own link command with the output renamed and the Silica objects and archives added after its first
# object. The command names its linker scripts relative to the application's build directory.
link() {
    heap=${GUEST_HEAP_SIZE:-$(( (ram - $1 - $2) / 64 * 64 ))}
    [ "$heap" -ge 16384 ] || { echo "build_image: main's stacks ($1 + $2 bytes) leave no heap in GUEST_RAM=$ram" >&2; exit 1; }
    "$CC" $ASFLAGS -DGUEST_HEAP_SIZE="$heap" -DGUEST_MAIN_STACK_SIZE="$1" -DGUEST_AUX_SIZE="$2" \
        -DGUEST_DEPTH_RESERVE="$3" -DGUEST_FFI_STACK="$ffi" "$GRT/rt_guest_mem.S" -o "$objdir/rt_guest_mem.o"
    sed -e "s| -o silica_guest_app.elf | -o $out.elf $objs $objdir/rt_guest_mem.o $libs |" \
        -e "s|-Wl,--Map=[^ ]*|-Wl,--Map=$out.map|" -e "s| -T sections.ld | -T $rtcache/sections_silica.ld |" \
        "$rtcache/link.cmd" > "$objdir/link.cmd"
    ( cd "$rtcache/idf" && sh "$objdir/link.cmd" ) > "$out.link.log" 2>&1 || {
        grep -m 12 -E 'error|undefined reference|orphan' "$out.link.log" >&2 || tail -n 12 "$out.link.log" >&2
        echo "build_image: link failed; see $out.link.log" >&2; exit 1; }
}

# Pass 1 measures, pass 2 uses the bound (see the bare-metal builder). The sizes move only data.
link 4096 1024 $(( 1024 + allowance ))
PY=${BOARD_PYTHON:-python3}
bound=$("$PY" "$HERE/../../tools/main_stack_bound.py" --objdump "$XTENSA_BIN/xtensa-esp32s3-elf-objdump" \
        --section .iram0.text --section .flash.text --emitted-syms "$out.emitted_syms" --root silica_guest_core0_entry "$out.elf") || {
    echo "main_stack_bound.py failed for $out.elf" >&2; exit 1; }
status=$(printf '%s\n' "$bound" | sed -n 's/^status //p')
machine=$(printf '%s\n' "$bound" | sed -n 's/^machine //p')
aux=$(printf '%s\n' "$bound" | sed -n 's/^aux //p')
rt_depth=$(printf '%s\n' "$bound" | sed -n 's/^rt_depth //p')
[ "$rt_depth" -lt 64 ] && rt_depth=64
reserve=$(( (rt_depth + allowance + 15) / 16 * 16 ))
# An emitted function opens its frame and then checks the stack limit (moving to a new chunk when it is
# below it), so for two instructions the stack pointer is one frame below where the check will leave
# it. An interrupt taken there puts its frame under that: the reserve also covers the largest emitted
# frame, so that point is still above the guard band.
maxframe=0
for o in $emitted; do
    f=$("$XTENSA_BIN/xtensa-esp32s3-elf-objdump" -d "$o" | awk '$3 == "entry" { v = $5; n = (v ~ /^0x/) ? strtonum_hex(substr(v, 3)) : v + 0; if (n > m) m = n }
        function strtonum_hex(h,   i, c, r) { r = 0; h = tolower(h); for (i = 1; i <= length(h); i++) { c = index("0123456789abcdef", substr(h, i, 1)) - 1; r = r * 16 + c } return r }
        END { print m + 0 }')
    [ "$f" -gt "$maxframe" ] && maxframe=$f
done
frame_reserve=$(( (maxframe + allowance + 15) / 16 * 16 ))
frame_extra=0       # what the larger reserve adds to main's machine stack, whose bound has the runtime's depth in it
if [ "$frame_reserve" -gt "$reserve" ]; then frame_extra=$(( frame_reserve - reserve )); reserve=$frame_reserve; fi
size_with_margin() {
    m=$(( $1 / 4 )); [ "$m" -lt 128 ] && m=128
    echo $(( ( $1 + m + 64 + 63 ) / 64 * 64 ))
}
# Each of main's two stacks is sized from its own bound when the walk has one, and gets the default
# when it has none (recursion from main, a call through a function value, an untracked stack
# pointer): the bare-metal default for the machine stack, half of it for the auxiliary stack (the
# bare-metal 64 KB would leave too little heap in the block). The bare-metal builder gives both the
# default when either is unbounded; here that would take 160 KB of the block from the heap.
# When the walk stops without a bound, its auxiliary figure covers only the part it walked, so the
# auxiliary stack gets the default as well.
reason=bounded
case "$status" in
    bounded) stack=$(size_with_margin $(( machine + allowance + frame_extra ))) ;;
    *)       stack=$(( 0x20000 )); reason=$status ;;
esac
case "$status:$aux" in
    bounded:[0-9]*)  auxsz=$(size_with_margin "$aux"); [ "$auxsz" -lt 256 ] && auxsz=256 ;;
    *)               auxsz=$(( 0x8000 )); [ "$reason" = bounded ] && reason="aux $aux" ;;
esac
link "$stack" "$auxsz" "$reserve"
printf 'main_stack %d\nmain_aux %d\nbound_machine %s\nbound_aux %s\nrt_depth %d\nreserve %d\nstatus %s\nram %d\nradio %d\nmax_frame %d\n' \
    "$stack" "$auxsz" "$machine" "$aux" "$rt_depth" "$reserve" "$reason" "$ram" "$radio" "$maxframe" > "$out.stack"

"$ESPTOOL" --chip esp32s3 elf2image --flash-mode dio --flash-freq 80m --flash-size 4MB --elf-sha256-offset 0xb0 \
    --flash-mmu-page-size 64KB --min-rev-full 0 --max-rev-full 99 -o "$out.app.bin" "$out.elf" > /dev/null
"$ESPTOOL" --chip esp32s3 merge-bin -o "$out.bin" --flash-mode dio --flash-freq 80m --flash-size 4MB \
    0x0 "$rtcache/idf/bootloader/bootloader.bin" 0x8000 "$rtcache/idf/partition_table/partition-table.bin" \
    0x10000 "$out.app.bin" > /dev/null

[ "$quiet" = 1 ] && exit 0
"$XTENSA_BIN/xtensa-esp32s3-elf-size" "$out.elf" | tail -n 1 | awk '{ printf "  application: text %d data %d bss %d\n", $1, $2, $3 }'
echo "  main stacks: machine $stack aux $auxsz ($reason; bound $machine/$aux, reserve $reserve: runtime $rt_depth or largest frame $maxframe, + ESP-IDF $allowance); heap $heap bytes"
echo "  image: $out.bin"
