#!/bin/bash
# The board end of the Bluetooth demo, as far as advertising (transport_ble_plan.md stage 6). Builds
# dangerous_ble_board_advertise into a guest image (compiler/src/emitter/ESP32-S3_raw/board/guest),
# flashes it and prints what it prints: the radio actor advertises the service while four actors keep
# both cores busy, and every five seconds the program reports the busy actors' progress and what
# ESP-IDF's internal heap has left. A phone's scanner (nRF Connect, LightBlue) shows "Silica".
#
#   ./run_board_advertise.sh [uuid] [--seconds <n>] [--build-only]
#
# uuid is the service's UUID (4, 8 or 36 characters); without it the service is the Nordic UART
# Service. --seconds (default 60, a multiple of 5) sets how many reports the program makes before it
# exits 0: one for each five seconds. With the cores busy a report comes some 5.7 s after the last, so the
# run lasts longer than the figure, and the time limit below allows for that.
# GUEST_RAM=<bytes> sets Silica's block (the guest's README).
#
# Needs: the ESP32-S3_raw Silica compiler (SILICA_COMPILER, default the local build), ESP-IDF 6.2 and
# the board tools' environment (see the guest's README), the board on BOARD_PORT.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GUEST="$ROOT/compiler/src/emitter/ESP32-S3_raw/board/guest"
CC="${SILICA_COMPILER:-$ROOT/compiler/build/ESP32-S3_raw/silica-compiler}"
XT="${XTENSA_BIN:-$HOME/.espressif/tools/xtensa-esp-elf/esp-16.1.0_20260609/xtensa-esp-elf/bin}"
PY="${BOARD_PYTHON:-$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/python}"
UUID="" SECONDS_TO_RUN=60 BUILD_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --build-only) BUILD_ONLY=1; shift ;;
        --seconds) SECONDS_TO_RUN=$2; shift 2 ;;
        -*) echo "run_board_advertise: unknown argument $1" >&2; exit 2 ;;
        *) UUID=$1; shift ;;
    esac
done
WORK="$HERE/build/board_advertise"
rm -rf "$WORK"; mkdir -p "$WORK/src/dangerous_exposure_source/lib"
cd "$WORK/src" || exit 1

# The program and the modules it uses, compiled in a copy, with the service and the number of reports
# in place of the placeholders.
ln -sfn "$ROOT/compiler/stdlib/ble" dangerous_exposure_source/ble
for m in Supervisor dangerous_nimble dangerous_ble_radio; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
sed -e "s|^fn service() -> string { \"\" }|fn service() -> string { \"$UUID\" }|" \
    -e "s|^fn reports() -> int64 { 6 }|fn reports() -> int64 { $((SECONDS_TO_RUN / 5)) }|" \
    "$HERE/dangerous_ble_board_advertise.silica" > dangerous_ble_board_advertise.silica
printf 'Supervisor.silica\ntrial_wait_int64.silica\ndangerous_nimble.silica\ndangerous_ble_radio.silica\ndangerous_ble_board_advertise.silica\n' > silica.config
# The compiler wants the archive the .meta names; the wrapper itself is compiled into the image as
# ESP-IDF code, so the archive here holds only the symbols.
sed -n 's/^ *symbol: "\(.*\)"$/long long \1(void) { return 0; }/p' "$ROOT/compiler/stdlib/ble/silica_ble_nimble_wrapper.meta" > stub.c
"$XT/xtensa-esp32s3-elf-gcc" -c -mlongcalls -Os -ffreestanding stub.c -o stub.o || exit 1
"$XT/xtensa-esp32s3-elf-ar" rcs dangerous_exposure_source/lib/libsilica_ble_nimble.a stub.o
for i in $(seq 1 12); do "$CC" > ../compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
[ "$ec" -eq 0 ] || { echo "run_board_advertise: compile failed; see $WORK/compile.log"; grep -A8 "Compilation error" ../compile.log | head -14; exit 1; }

BOARD_PYTHON="$PY" sh "$GUEST/tools/build_image.sh" -o "$WORK/image/board_advertise" ./*.sams "$ROOT/compiler/stdlib/ble/silica_ble_nimble.c" || exit 1
[ "$BUILD_ONLY" = 1 ] && exit 0
"$PY" "$GUEST/tools/run_on_board.py" --timeout $((SECONDS_TO_RUN * 5 / 4 + 30))"$WORK/image/board_advertise.bin"
