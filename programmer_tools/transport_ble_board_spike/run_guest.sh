#!/bin/bash
# Stage 4 spike of transport_ble_plan.md: build an ESP-IDF application that runs one Silica program on
# Silica's board runtime as a guest (two scheduler tasks, one per core), flash it and print the console.
#
#   ./run_guest.sh [--seconds N] [--no-flash] <program.silica> [more .silica sources, wrappers .c]
#
# Needs: ESP-IDF 5.3 (IDF_EXPORT, default ~/esp/esp-idf/export.sh), the ESP32-S3_raw Silica compiler
# (SILICA_COMPILER, default binaries/silica-compiler-ESP32-S3_raw), the board on BOARD_PORT.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RT="$ROOT/compiler/src/emitter/ESP32-S3_raw/board/runtime"
CC="${SILICA_COMPILER:-$ROOT/binaries/silica-compiler-ESP32-S3_raw}"
IDF_EXPORT="${IDF_EXPORT:-$HOME/esp/esp-idf/export.sh}"
PORT="${BOARD_PORT:-/dev/cu.usbserial-210}"
SECONDS_TO_READ=10 FLASH=1
while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_TO_READ=$2; shift 2 ;;
        --no-flash) FLASH=0; shift ;;
        *) break ;;
    esac
done
[ $# -ge 1 ] || { echo "usage: run_guest.sh [--seconds N] [--no-flash] <program.silica> [sources...]" >&2; exit 2; }

WORK="$HERE/build/src"; GEN="$HERE/idf_app/components/silica_guest/gen"
rm -rf "$WORK" "$GEN"; mkdir -p "$WORK" "$GEN"

# 1. The program: compiled in a copy, as run_app.sh does.
: > "$WORK/silica.config"
for src in "$@"; do
    case "$src" in
        *.silica) cp "$src" "$WORK/"; echo "$(basename "$src")" >> "$WORK/silica.config" ;;
        *.c|*.h) cp "$src" "$GEN/" ;;
        *.meta) mkdir -p "$WORK/dangerous_exposure_source/spike"; cp "$src" "$WORK/dangerous_exposure_source/spike/" ;;
    esac
done
# A wrapper's archive must exist for the compiler (it is named by the .meta); the wrapper itself is
# compiled by ESP-IDF with the component, so the archive here holds only the symbols.
XT="${XTENSA_BIN:-$HOME/.espressif/tools/xtensa-esp-elf/esp-13.2.0_20250707/xtensa-esp-elf/bin}"
for meta in "$WORK"/dangerous_exposure_source/spike/*.meta; do
    [ -f "$meta" ] || continue
    lib=$(sed -n 's/^link_library: "\(.*\)"$/\1/p' "$meta")
    mkdir -p "$WORK/dangerous_exposure_source/lib"
    sed -n 's/^ *symbol: "\(.*\)"$/long long \1(void) { return 0; }/p' "$meta" > "$WORK/stub_$lib.c"
    "$XT/xtensa-esp32s3-elf-gcc" -c -mlongcalls -Os -ffreestanding "$WORK/stub_$lib.c" -o "$WORK/stub_$lib.o" || exit 1
    "$XT/xtensa-esp32s3-elf-ar" rcs "$WORK/dangerous_exposure_source/lib/lib$lib.a" "$WORK/stub_$lib.o"
done
( cd "$WORK" && for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done; exit $ec ) \
    || { echo "run_guest: compile failed; see $WORK/compile.log"; grep -A8 "Compilation error" "$WORK/compile.log" | head -14; exit 1; }
for s in "$WORK"/*.sams; do cp "$s" "$GEN/$(basename "${s%.sams}").s"; done

# 2. The runtime: every file but the two that own the chip, with these changes (the spike's finding
#    of what a guest target replaces):
#    rt_console.S  the two places that halt a core with interrupts masked (waiti 15) hand the task
#                  back to FreeRTOS instead (guest.c silica_guest_halt)
#    rt_ffi.S      its memcpy, memmove, memset, memcmp and strlen are left out: ESP-IDF has them
for f in "$RT"/rt_*.S; do
    b=$(basename "$f")
    case "$b" in
        rt_start.S|rt_vectors.S) ;;
        rt_console.S) sed 's/^\(1:  \)\{0,1\} *waiti   15.*$/\1call8   silica_guest_halt/' "$f" > "$GEN/$b" ;;
        rt_ffi.S) sed '/^\/\/ The C memory functions/,$d' "$f" > "$GEN/$b" ;;
        *) cp "$f" "$GEN/$b" ;;
    esac
done
grep -c "silica_guest_halt" "$GEN/rt_console.S" | sed 's/^/run_guest: halts replaced in rt_console.S: /'

# 3. Build, flash, read the console.
cd "$HERE/idf_app" || exit 1
. "$IDF_EXPORT" > /dev/null 2>&1
idf.py reconfigure > "$HERE/build/reconfigure.log" 2>&1
idf.py build > "$HERE/build/idf_build.log" 2>&1 || { echo "run_guest: ESP-IDF build failed; see $HERE/build/idf_build.log"; grep -E "error|undefined reference|Error" "$HERE/build/idf_build.log" | head -30; exit 1; }
grep "binary size" "$HERE/build/idf_build.log"
[ "$FLASH" = 1 ] || exit 0
idf.py -p "$PORT" flash > "$HERE/build/flash.log" 2>&1 || { echo "run_guest: flash failed; see $HERE/build/flash.log"; tail -5 "$HERE/build/flash.log"; exit 1; }
python "$HERE/capture.py" "$PORT" "$SECONDS_TO_READ"
