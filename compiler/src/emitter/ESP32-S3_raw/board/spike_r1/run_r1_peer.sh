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

# Route R1 (transport_ble_plan.md stage 12, part 5): the stage 7 demo's board program, a Silica program
# with its actors, on the chip the bare-metal runtime owns: no ESP-IDF start-up, no FreeRTOS.
#
#   BOARD_PORT=<port> ./run_r1_peer.sh [--build-only] [--links <n>] [--accel] [<out_dir>]
#
# --accel: the stage 8 demo's board program instead (dangerous_ble_board_accel_led: one reading sent, one
# LED command taken, no busy actors), compiled by run_accel_led.sh --build-only; its peer is the Mac
# program that script builds, build/accel_led/mac/dangerous_ble_mac_led.
#
# The program is compiled as programmer_tools/transport_ble_demo/run_board_peer.sh compiles it (that
# script is run with --build-only and its .sams are taken). The image is the bare-metal runtime on
# core 0, the Bluetooth tasks on core 1, the program, the NimBLE wrapper, r1_port.c and hci_shim.c, NimBLE and ESP-IDF's glue from the
# guest's cached build, the closed controller and radio libraries, and ESP-IDF's clock and flash code
# from its bootloader build. The program's own code and the Bluetooth libraries' run from flash.
# The peer is the Mac: programmer_tools/transport_ble_demo/run_peer.sh central.

set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BOARD="$HERE/.."
ROOT=$(cd "$BOARD/../../../../.." && pwd)
DEMO="$ROOT/programmer_tools/transport_ble_demo"
IDF_BUILD="$BOARD/guest/.cache/idf"
IDF_PATH=${IDF_PATH:-$HOME/esp/esp-idf-v6.2}
PY=${BOARD_PYTHON:-$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/python}
build_only=0 links=1 accel=0
while [ $# -gt 0 ]; do
    case "$1" in
        --build-only) build_only=1; shift ;;
        --links) links=$2; shift 2 ;;
        --accel) accel=1; shift ;;
        *) break ;;
    esac
done
out=${1:-$HERE/out}
mkdir -p "$out"
if [ "$accel" = 1 ]; then
    ( cd "$DEMO" && ./run_accel_led.sh --build-only ) > "$out/program.log" 2>&1 || { echo "run_r1_peer: the program did not compile; see $out/program.log" >&2; exit 1; }
    SRC="$DEMO/build/accel_led/board/src"
else
    ( cd "$DEMO" && ./run_board_peer.sh --links "$links" --build-only ) > "$out/program.log" 2>&1 || { echo "run_r1_peer: the program did not compile; see $out/program.log" >&2; exit 1; }
    SRC="$DEMO/build/board_peer/src"
fi
syms=""
for s in _bt_bss_start _bt_bss_end _bt_controller_bss_start _bt_controller_bss_end _bt_data_start _bt_data_end _bt_controller_data_start _bt_controller_data_end; do
    syms="$syms -Wl,--defsym,$s=0"
done
# main's stacks: the builder cannot bound a start that calls into ESP-IDF's code (the flash mapping) and
# would give main 192 KB; the guest's builder bounds this program's main at 4.5 KB and 320 bytes
syms="$syms -Wl,--defsym,_silica_main_stack_req=0x4000 -Wl,--defsym,_silica_main_aux_req=0x400"
# HCI_TRACE=1: every packet between the host and the controller is printed while a link is up
if [ "${HCI_TRACE:-0}" = 1 ]; then
    SPIKE_CFLAGS="${SPIKE_CFLAGS:-} -DR1_HCI_TRACE"
    syms="$syms -Wl,--wrap=esp_vhci_host_send_packet -Wl,--wrap=esp_vhci_host_register_callback"
fi
C="$IDF_PATH/components"
# in flash: the Bluetooth libraries and the program's own compiled code (each .sams becomes <n>.<name>.o)
BOARD_FLASH_FILES="*libbt.a *libbtdm_app.a *libphy.a *libbtbb.a"
for f in "$SRC"/*.sams; do
    BOARD_FLASH_FILES="$BOARD_FLASH_FILES *.$(basename "$f" .sams).o"
done
export BOARD_FLASH_FILES
export SPIKE_CFLAGS="${SPIKE_CFLAGS:-} -DSPIKE_INTERRUPT -DSPIKE_BT_CORE=1 -DARENA_KB=${ARENA_KB:-96}"
# the runtime on one core, core 0, for the program's actors; core 1 is the Bluetooth tasks' (r1_port.c)
export BOARD_ASFLAGS="-DNCORES_RUN=1"
# The controller's handler interrupts core 1 only, so no actor's stack needs room for it.
export BOARD_FFI_STACK=${BOARD_FFI_STACK:-16384}
boot=$(ls "$IDF_BUILD"/bootloader/esp-idf/*/lib*.a | tr '\n' ' ')
# shellcheck disable=SC2086
SPIKE_LDFLAGS="$syms" "$HERE/build.sh" --app "$out/r1_peer" "$SRC"/*.sams \
    "$ROOT/compiler/stdlib/ble/silica_ble_nimble.c" "$HERE/r1_port.c" "$HERE/hci_shim.c" "$HERE/spike_co.S" "boot:$HERE/spike_flash.c" \
    "$IDF_BUILD/esp-idf/bt/libbt.a" "$C/bt/controller/lib_esp32c3_family/esp32s3/libbtdm_app.a" "$C/esp_phy/lib/esp32s3/libbtbb.a" \
    "$C/esp_phy/lib/esp32s3/libphy.a" "$IDF_BUILD/esp-idf/esp_phy/libesp_phy.a" $boot "$C/xtensa/esp32s3/libxt_hal.a"
[ "$build_only" = 1 ] && exit 0
"$PY" "$BOARD/tools/run_on_board.py" --flash --timeout "${SPIKE_TIMEOUT:-150}" "$out/r1_peer.bin"
