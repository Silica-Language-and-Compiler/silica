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

# Build a bare-metal STM32L476RG (Nucleo-L476RG) RAM image (or, by hand only, a flash image: BOARD_EXEC
# below) from program sources plus the board runtime.
#
#   build_image.sh [-q] [-r <runtime-cache-dir>] -o <out_dir>/<name> <source>...
#   build_image.sh -r <runtime-cache-dir> --prepare
#
# -r keeps the assembled runtime objects in <runtime-cache-dir> and reuses them (reassembling a
#    file only when its source is newer), instead of assembling the runtime for every image; the
#    trial driver prepares the cache once per run with --prepare, before any parallel use.
# -q prints nothing on success (the section sizes and the image path are otherwise printed).
#
# Sources are .S/.s hand-written assembly, .sams emitted by a STM32-L476RG_raw silica-compiler, .c files
# (compiled freestanding by the same toolchain's GCC; no C library in the image beyond the memory
# functions of board/runtime/rt_support.S; -ffixed-r9; BOARD_CFLAGS adds flags), and prebuilt .o objects and .a
# archives for this triple (archives are placed after every object on the link line).
# Produces <name>.elf (what the probe loads: board/tools/run_on_board.py), <name>.map and <name>.bin
# (the raw image at 0x20000000, for a loader that takes binaries; at 0x08000000 for a flash image).
#
# BOARD_EXEC=ram|flash (default ram). ram: the image runs from SRAM1 (runtime/silica_stm32l476rg.ld),
# what the trial harness builds and loads. flash: the image runs from the 1 MiB flash
# (runtime/silica_stm32l476rg_flash.ld; every source assembled with BOARD_EXEC_FLASH defined, so
# rt_start.S copies .data from flash and turns the ART on, and rt_actors.S accepts flash code addresses;
# design: compiler/design_documents/stm32_flash_execution_design.md). Loading a flash image wears the
# flash (run_on_board.py --exec flash --yes-wear-flash, by hand only), so flash is refused together with
# -r/--prepare, the runtime cache only the trial harness uses: no trial run can build a flash image.
#
# main's stacks are the linker script's defaults (6 KiB machine, 2 KiB auxiliary); BOARD_MAIN_STACK=N
# and BOARD_MAIN_AUX=N override them (the ESP32-S3 port's per-image bound is not ported yet).
# BOARD_FFI_STACK=N sets the machine stack a foreign call in an actor runs on (the link's
# _silica_ffi_stack_size; 2 KiB when unset; rt_ffi.S).
#
# Toolchain: the Arm GNU toolchain (arm-none-eabi-gcc: assembler, linker, libgcc for the soft-float
# and 64-bit division routines the emitted code calls), Homebrew's `arm-none-eabi-gcc` formula on the
# Mac. Override ARM_BIN if it lives elsewhere. The same toolchain's gcc compiles the C wrappers, as the
# ESP32-S3 port's build_image.sh uses Espressif's.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
RT="$HERE/../runtime"
ARM_BIN=${ARM_BIN:-$(dirname "$(command -v arm-none-eabi-gcc || echo /opt/homebrew/bin/arm-none-eabi-gcc)")}
CC="$ARM_BIN/arm-none-eabi-gcc"

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

# softfp, not hard: the FPU instructions are the same, but a C function's float and double arguments and
# results cross in core registers, as the foreign call block lays them out (terms/ffi_foreign.silica,
# rt_ffi.S) and as the AEABI helpers the emitted code calls take them; nothing in the image uses the VFP
# calling convention. -ffixed-r9 keeps C away from TP (rt_defs.h).
ARCH="-mcpu=cortex-m4 -mthumb -mfpu=fpv4-sp-d16 -mfloat-abi=softfp"
# The runtime sources are preprocessed (.S: rt_defs.h); emitted .sams are plain assembler.
ASFLAGS="-c $ARCH -I$RT"
LDSCRIPT="$RT/silica_stm32l476rg.ld"
case "${BOARD_EXEC:-ram}" in
    ram) ;;
    flash)
        if [ -n "$rtcache" ]; then
            echo "$0: BOARD_EXEC=flash is refused with -r/--prepare (the trial harness's runtime cache): trial runs never use flash" >&2
            exit 2
        fi
        ASFLAGS="$ASFLAGS -Wa,--defsym,BOARD_EXEC_FLASH=1"
        LDSCRIPT="$RT/silica_stm32l476rg_flash.ld" ;;
    *) echo "$0: BOARD_EXEC must be ram or flash (got '$BOARD_EXEC')" >&2; exit 2 ;;
esac
CFLAGS="-c $ARCH -Os -ffreestanding -fno-builtin -ffixed-r9 -ffunction-sections -fdata-sections -Wall -Wextra ${BOARD_CFLAGS:-}"
defsyms=""
[ -n "${BOARD_MAIN_STACK:-}" ] && defsyms="$defsyms -Wl,--defsym,_silica_main_stack_req=$BOARD_MAIN_STACK"
[ -n "${BOARD_MAIN_AUX:-}" ] && defsyms="$defsyms -Wl,--defsym,_silica_main_aux_req=$BOARD_MAIN_AUX"
[ -n "${BOARD_FFI_STACK:-}" ] && defsyms="$defsyms -Wl,--defsym,_silica_ffi_stack_req=$BOARD_FFI_STACK"

RUNTIME_SOURCES="rt_vectors.S rt_start.S rt_console.S rt_heap.S rt_frame.S rt_state.S rt_string.S rt_list.S rt_transport.S rt_support.S rt_ordering.S rt_float.S rt_actors.S rt_failure.S rt_supervisors.S rt_ffi.S rt_stubs.S"

objs=""
if [ -n "$rtcache" ]; then
    mkdir -p "$rtcache"
    for f in $RUNTIME_SOURCES; do
        obj="$rtcache/${f%.S}.o"
        if [ ! -f "$obj" ] || [ "$RT/$f" -nt "$obj" ] || [ "$RT/rt_defs.h" -nt "$obj" ]; then
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
libs=""
for src in "$@"; do
    n=$((n + 1))
    base=$(basename "$src")
    obj="$objdir/$n.${base%.*}.o"
    case "$src" in
        *.sams) "$CC" $ASFLAGS -x assembler "$src" -o "$obj" ;;
        *.c)    "$CC" $CFLAGS -I"$(dirname "$src")" "$src" -o "$obj" ;;
        *.o)    obj=$src ;;
        *.a)    libs="$libs $src"; continue ;;
        *)      "$CC" $ASFLAGS "$src" -o "$obj" ;;
    esac
    objs="$objs $obj"
done

# the --defsym options must precede -T: the script tests DEFINED() on them
"$CC" -nostdlib -nostartfiles $ARCH -Wl,--gc-sections $defsyms -Wl,-T,"$LDSCRIPT" \
    -Wl,-Map,"$out.map" -o "$out.elf" $objs $libs -lgcc
"$ARM_BIN/arm-none-eabi-objcopy" -O binary "$out.elf" "$out.bin"

[ "$quiet" = 1 ] && exit 0
"$ARM_BIN/arm-none-eabi-size" -A "$out.elf" | awk '/^\.(text|data|bss)/ {printf "  %-8s %7d bytes @ %s\n", $1, $2, sprintf("0x%x", $3)}'
hs=$("$ARM_BIN/arm-none-eabi-nm" "$out.elf" | awk '$3 == "_silica_heap_start" {print $1}')
he=$("$ARM_BIN/arm-none-eabi-nm" "$out.elf" | awk '$3 == "_silica_heap_end" {print $1}')
ms=$("$ARM_BIN/arm-none-eabi-nm" "$out.elf" | awk '$3 == "_silica_main_stack_size" {print $1}')
ma=$("$ARM_BIN/arm-none-eabi-nm" "$out.elf" | awk '$3 == "_silica_main_aux_size" {print $1}')
echo "  main stacks: machine $((0x$ms)) aux $((0x$ma)); heap $((0x$he - 0x$hs)) bytes"
if [ "${BOARD_EXEC:-ram}" = flash ]; then
    fb=$("$ARM_BIN/arm-none-eabi-nm" "$out.elf" | awk '$3 == "_silica_image_start" {print $1}')
    fe=$("$ARM_BIN/arm-none-eabi-nm" "$out.elf" | awk '$3 == "_silica_flash_image_end" {print $1}')
    dl=$("$ARM_BIN/arm-none-eabi-nm" "$out.elf" | awk '$3 == "_silica_data_load" {print $1}')
    s2s=$("$ARM_BIN/arm-none-eabi-nm" "$out.elf" | awk '$3 == "_silica_sram2_heap_start" {print $1}')
    s2e=$("$ARM_BIN/arm-none-eabi-nm" "$out.elf" | awk '$3 == "_silica_sram2_heap_end" {print $1}')
    fbytes=$((0x$fe - 0x$fb))
    echo "  flash: $fbytes bytes at 0x$fb ($(( (fbytes + 2047) / 2048 )) pages of 2 KiB; .data loaded from 0x$dl); sram2 chunk arena $((0x$s2e - 0x$s2s)) bytes"
fi
echo "  image: $out.elf"
