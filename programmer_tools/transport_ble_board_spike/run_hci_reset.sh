#!/bin/bash
# Stage 4 spike of transport_ble_plan.md, on the guest runtime that stage 5 put in the tree
# (compiler/src/emitter/ESP32-S3_raw/board/guest): a Silica program on the board sends an HCI Reset to
# Espressif's Bluetooth controller through a Fifi wrapper and prints the controller's answer,
#
#   hci reset length=7 event=040E0405030C00
#
# then exits 0.
#
#   ./run_hci_reset.sh [--build-only]
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
WORK="$HERE/build"
rm -rf "$WORK"; mkdir -p "$WORK/src/dangerous_exposure_source/spike" "$WORK/src/dangerous_exposure_source/lib"
cd "$WORK/src" || exit 1

# The program and the modules it uses, compiled in a copy.
cp "$ROOT/compiler/stdlib/Supervisor.silica" "$ROOT/trials/lib_trial_support/trial_support_hex.silica" \
   "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" "$HERE/silica/dangerous_hci.silica" \
   "$HERE/silica/dangerous_hci_reset.silica" .
printf 'Supervisor.silica\ntrial_support_hex.silica\ntrial_wait_int64.silica\ndangerous_hci.silica\ndangerous_hci_reset.silica\n' > silica.config
cp "$HERE/silica/silica_hci_wrapper.meta" dangerous_exposure_source/spike/
# The compiler wants the archive the .meta names; the wrapper itself is compiled into the image as
# ESP-IDF code, so the archive here holds only the symbols.
sed -n 's/^ *symbol: "\(.*\)"$/long long \1(void) { return 0; }/p' "$HERE/silica/silica_hci_wrapper.meta" > stub.c
"$XT/xtensa-esp32s3-elf-gcc" -c -mlongcalls -Os -ffreestanding stub.c -o stub.o || exit 1
"$XT/xtensa-esp32s3-elf-ar" rcs dangerous_exposure_source/lib/libsilica_hci.a stub.o
for i in $(seq 1 12); do "$CC" > ../compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
[ "$ec" -eq 0 ] || { echo "run_hci_reset: compile failed; see $WORK/compile.log"; grep -A8 "Compilation error" ../compile.log | head -14; exit 1; }

BOARD_PYTHON="$PY" sh "$GUEST/tools/build_image.sh" -o "$WORK/image/hci_reset" ./*.sams "$HERE/silica/silica_hci.c" || exit 1
[ "${1:-}" = "--build-only" ] && exit 0
"$PY" "$GUEST/tools/run_on_board.py" --timeout 30 "$WORK/image/hci_reset.bin"
