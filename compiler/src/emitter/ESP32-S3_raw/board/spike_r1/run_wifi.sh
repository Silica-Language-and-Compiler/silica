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

# Route R1 spike, Wi-Fi (transport_ble_plan.md stage 12, part 6): builds wifi_main.c into a bare-metal
# image with Espressif's Wi-Fi libraries in it, and runs it on the board from flash.
#
#   BOARD_PORT=<port> ./run_wifi.sh [--build-only] [<out_dir>]
#
# The access point's name and passphrase are read from SILICA_WIFI_FILE (by default .silica_wifi at
# the repository's root, else ~/.silica_wifi), a file kept out of git with the two lines
#
#   SILICA_WIFI_SSID=<name>
#   SILICA_WIFI_PASSPHRASE=<passphrase>
#
# and written to <out_dir>/wifi_secret.h for the compiler; neither is printed.
#
# Linked: Espressif's closed Wi-Fi and radio libraries, ESP-IDF's glue for them, its WPA supplicant and
# Mbed TLS from the guest's cached build, ESP-IDF's clock and flash code from its bootloader build, and
# the window-spill routine of Cadence's HAL. Their code and constants run from flash.
# SPIKE_CFLAGS adds flags: -DPOLL_GAP_MS=<n> main's busy time between visits to the tasks.

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
secret=${SILICA_WIFI_FILE:-$ROOT/.silica_wifi}
[ -f "$secret" ] || secret=$HOME/.silica_wifi
[ -f "$secret" ] || { echo "run_wifi: no file with the access point's name and passphrase (see the header)" >&2; exit 2; }
python3 - "$secret" "$out/wifi_secret.h" <<'PY'
import sys
v = dict(l.rstrip('\n').split('=', 1) for l in open(sys.argv[1]) if '=' in l)
q = lambda s: '"' + ''.join('\\x%02x' % b for b in s.encode()) + '"'
open(sys.argv[2], 'w').write('#define SILICA_WIFI_SSID %s\n#define SILICA_WIFI_PASSPHRASE %s\n' % (q(v['SILICA_WIFI_SSID']), q(v['SILICA_WIFI_PASSPHRASE'])))
PY
C="$IDF_PATH/components"
W="$C/esp_wifi/lib/esp32s3"
M="$IDF_BUILD/esp-idf/mbedtls/mbedtls"
export BOARD_FLASH_FILES="*libnet80211.a *libcoexist.a *libesp_coex.a *libpp.a *libcore.a *libphy.a *libwpa_supplicant.a *libesp_wifi.a *libmbedcrypto.a *libmbedtls.a *libmbedx509.a *libtfpsacrypto.a *libbuiltin.a *libeverest.a *libp256m.a"
inc="-I$out -I$C/esp_wifi/include -I$C/esp_wifi/include/local -I$C/esp_event/include -I$C/esp_netif/include -I$C/esp_phy/include"
export SPIKE_CFLAGS="${SPIKE_CFLAGS:-} $inc -DSPIKE_WIFI -DSPIKE_FLASH -DSPIKE_INTERRUPT -DARENA_KB=${ARENA_KB:-160}"
boot=$(ls "$IDF_BUILD"/bootloader/esp-idf/*/lib*.a | tr '\n' ' ')
mbed=$(find "$IDF_BUILD/esp-idf/mbedtls" -name "*.a" | tr '\n' ' ')
# shellcheck disable=SC2086
SPIKE_LDFLAGS="-Wl,--defsym,_silica_main_stack_req=0x8000 -Wl,--defsym,_silica_main_aux_req=0x1000" "$HERE/build.sh" --app "$out/wifi" \
    "$HERE/wifi_main.c" "$HERE/hci_shim.c" "$HERE/wifi_shim.c" "$HERE/spike_co.S" "boot:$HERE/spike_flash.c" \
    "$IDF_BUILD/esp-idf/esp_wifi/libesp_wifi.a" "$W/libnet80211.a" "$W/libpp.a" "$W/libcore.a" "$IDF_BUILD/esp-idf/wpa_supplicant/libwpa_supplicant.a" $mbed \
    "$IDF_BUILD/esp-idf/esp_coex/libesp_coex.a" "$C/esp_coex/lib/esp32s3/libcoexist.a" "$IDF_BUILD/esp-idf/esp_hal_security/libesp_hal_security.a" \
    "$C/esp_phy/lib/esp32s3/libphy.a" "$IDF_BUILD/esp-idf/esp_phy/libesp_phy.a" $boot "$C/xtensa/esp32s3/libxt_hal.a"
[ "$build_only" = 1 ] && exit 0
"$PY" "$BOARD/tools/run_on_board.py" --flash --timeout "${SPIKE_TIMEOUT:-90}" "$out/wifi.bin"
