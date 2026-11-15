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

# Route R1 spike, step 3 (transport_ble_plan.md stage 12): builds hci_main.c into a bare-metal image
# with Espressif's Bluetooth controller in it and runs it on the board from RAM.
#
#   BOARD_PORT=<port> ./run_hci.sh [--build-only] [<out_dir>]
#
# Linked: ESP-IDF's glue for the controller (bt.c) as the guest's cached build compiled it, the closed
# controller and radio libraries, ESP-IDF's clock code from its bootloader build, and the window-spill
# routine of Cadence's HAL. The glue's symbols for the Bluetooth libraries' data areas, which only its
# memory release uses, are set to 0.

set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BOARD="$HERE/.."
IDF_BUILD="$BOARD/guest/.cache/idf"
IDF_PATH=${IDF_PATH:-$HOME/esp/esp-idf-v6.2}
XT=${XTENSA_BIN:-$HOME/.espressif/tools/xtensa-esp-elf/esp-16.1.0_20260609/xtensa-esp-elf/bin}
PY=${BOARD_PYTHON:-$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/python}
build_only=0
[ "${1:-}" = "--build-only" ] && { build_only=1; shift; }
out=${1:-$HERE/out}
mkdir -p "$out"
( cd "$out" && "$XT/xtensa-esp32s3-elf-ar" x "$IDF_BUILD/esp-idf/bt/libbt.a" bt.c.obj && mv bt.c.obj bt_glue.o )
syms=""
for s in _bt_bss_start _bt_bss_end _bt_controller_bss_start _bt_controller_bss_end _bt_data_start _bt_data_end _bt_controller_data_start _bt_controller_data_end; do
    syms="$syms -Wl,--defsym,$s=0"
done
C="$IDF_PATH/components"
# main's stacks: the builder cannot bound a main that reaches ESP-IDF's code and would give it 192 KB
SPIKE_LDFLAGS="$syms -Wl,--defsym,_silica_main_stack_req=0x8000 -Wl,--defsym,_silica_main_aux_req=0x1000" "$HERE/build.sh" --app "$out/hci" "$HERE/hci_main.c" "$HERE/hci_shim.c" "$HERE/spike_co.S" "$out/bt_glue.o" \
    "$C/bt/controller/lib_esp32c3_family/esp32s3/libbtdm_app.a" "$C/esp_phy/lib/esp32s3/libbtbb.a" "$C/esp_phy/lib/esp32s3/libphy.a" \
    "$IDF_BUILD/esp-idf/esp_phy/libesp_phy.a" "$IDF_BUILD/bootloader/esp-idf/esp_hw_support/libesp_hw_support.a" \
    "$C/xtensa/esp32s3/libxt_hal.a"
[ "$build_only" = 1 ] && exit 0
"$PY" "$BOARD/tools/run_on_board.py" --timeout "${SPIKE_TIMEOUT:-30}" "$out/hci.bin"
