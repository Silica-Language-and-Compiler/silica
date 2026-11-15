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

# Route R1 spike (transport_ble_plan.md stage 12, part 4): builds nimble_main.c into a bare-metal image
# with Espressif's controller and the NimBLE host in it, and runs it on the board from flash.
#
#   BOARD_PORT=<port> ./run_nimble.sh [--build-only] [<out_dir>]
#
# Linked: the board's own NimBLE wrapper (compiler/stdlib/ble/silica_ble_nimble.c) compiled by
# ESP-IDF's command, NimBLE and ESP-IDF's glue from the guest's cached build (libbt.a), the closed
# controller and radio libraries, ESP-IDF's clock and flash code from its bootloader build, and the
# window-spill routine of Cadence's HAL. The code and constants of the Bluetooth libraries run from
# flash. SPIKE_CFLAGS adds flags: -DPOLL_GAP_MS=<n> main's busy time between visits to the tasks.

set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BOARD="$HERE/.."
ROOT=$(cd "$BOARD/../../../../.." && pwd)
IDF_BUILD="$BOARD/guest/.cache/idf"
IDF_PATH=${IDF_PATH:-$HOME/esp/esp-idf-v6.2}
PY=${BOARD_PYTHON:-$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/python}
build_only=0
[ "${1:-}" = "--build-only" ] && { build_only=1; shift; }
out=${1:-$HERE/out}
mkdir -p "$out"
syms=""
for s in _bt_bss_start _bt_bss_end _bt_controller_bss_start _bt_controller_bss_end _bt_data_start _bt_data_end _bt_controller_data_start _bt_controller_data_end; do
    syms="$syms -Wl,--defsym,$s=0"
done
C="$IDF_PATH/components"
export BOARD_FLASH_FILES="*libbt.a *libbtdm_app.a *libphy.a *libbtbb.a"
# SPIKE_POLL=1: the controller's handler polled, not taken by interrupt
mode="-DSPIKE_INTERRUPT"; [ "${SPIKE_POLL:-0}" = 1 ] && mode=""
export SPIKE_CFLAGS="${SPIKE_CFLAGS:-} -DSPIKE_FLASH $mode -DARENA_KB=112"
boot=$(ls "$IDF_BUILD"/bootloader/esp-idf/*/lib*.a | tr '\n' ' ')
# shellcheck disable=SC2086
# HCI_TRACE=1: every packet between the host and the controller is printed while a link is up
if [ "${HCI_TRACE:-0}" = 1 ]; then
    SPIKE_CFLAGS="$SPIKE_CFLAGS -DHCI_TRACE"
    syms="$syms -Wl,--wrap=esp_vhci_host_send_packet -Wl,--wrap=esp_vhci_host_register_callback"
fi
SPIKE_LDFLAGS="$syms -Wl,--defsym,_silica_main_stack_req=0x8000 -Wl,--defsym,_silica_main_aux_req=0x1000" "$HERE/build.sh" --app "$out/nimble" \
    "$HERE/nimble_main.c" "$HERE/hci_shim.c" "$ROOT/compiler/stdlib/ble/silica_ble_nimble.c" "$HERE/spike_co.S" "boot:$HERE/spike_flash.c" \
    "$IDF_BUILD/esp-idf/bt/libbt.a" "$C/bt/controller/lib_esp32c3_family/esp32s3/libbtdm_app.a" "$C/esp_phy/lib/esp32s3/libbtbb.a" \
    "$C/esp_phy/lib/esp32s3/libphy.a" "$IDF_BUILD/esp-idf/esp_phy/libesp_phy.a" $boot "$C/xtensa/esp32s3/libxt_hal.a"
[ "$build_only" = 1 ] && exit 0
"$PY" "$BOARD/tools/run_on_board.py" --flash --timeout "${SPIKE_TIMEOUT:-120}" "$out/nimble.bin"
