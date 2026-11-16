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

# Route R1, both radios in one image (transport_ble_plan.md stage 12): one Silica program with a
# (:tcp) carrier on the Wi-Fi station and a (:ble_gatt) carrier on the Bluetooth radio exchanges the
# demos' frame with the Mac on both, on the chip the bare-metal runtime owns: no ESP-IDF start-up, no
# FreeRTOS.
#
#   BOARD_PORT=<port> ./run_r1_both.sh [--build-only] [--links <n>] [--only wifi|ble] [<out_dir>]
#
# The program is programmer_tools/transport_both_demo/dangerous_both_board_peer.silica: the hosted
# (:tcp) carrier above lwIP (run_r1_wifi_peer.sh) and the board's (:ble_gatt) carrier above NimBLE
# (run_r1_peer.sh), in one image. The actors run on core 0; core 1 has the tasks of the Wi-Fi
# libraries, lwIP, the Bluetooth controller and NimBLE, and both radios' interrupts. The libraries'
# memory: the RAM above the image, then a region of the runtime's heap (BOTH_LIB_REGION_KB, 64 unless
# given), then the heap (hci_shim.c). --links <n> whole exchanges on each radio.
#
# The Mac's ends are not started here: wifi_peer.py <port> <n> for Wi-Fi (the port is WIFI_PORT, 4370
# unless given) and transport_ble_demo/run_peer.sh central --links <n> for Bluetooth. The access
# point's name and passphrase come from SILICA_WIFI_FILE as for run_wifi.sh.
#
# Needs: as run_r1_wifi_peer.sh and run_r1_peer.sh.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BOARD="$HERE/.."
ROOT=$(cd "$BOARD/../../../../.." && pwd)
DEMO="$ROOT/programmer_tools/transport_both_demo"
IDF_BUILD="$BOARD/guest/.cache/idf"
IDF_PATH=${IDF_PATH:-$HOME/esp/esp-idf-v6.2}
PY=${BOARD_PYTHON:-$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/python}
CC=${SILICA_COMPILER:-$ROOT/compiler/build/ESP32-S3_raw/silica-compiler}
XT=${XTENSA_BIN:-$HOME/.espressif/tools/xtensa-esp-elf/esp-16.1.0_20260609/xtensa-esp-elf/bin}
PORT=${WIFI_PORT:-4370}
build_only=0 links=1 only=""
while [ $# -gt 0 ]; do
    case "$1" in
        --build-only) build_only=1; shift ;;
        --links) links=$2; shift 2 ;;
        --only) only=$2; shift 2 ;;
        *) break ;;
    esac
done
out=${1:-$HERE/out}
mkdir -p "$out"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

secret=${SILICA_WIFI_FILE:-$ROOT/.silica_wifi}
[ -f "$secret" ] || secret=$HOME/.silica_wifi
[ -f "$secret" ] || { echo "run_r1_both: no file with the access point's name and passphrase (see run_wifi.sh)" >&2; exit 2; }
peer=""
for i in en0 en1 en2; do
    peer=$(ipconfig getifaddr $i 2>/dev/null) && [ -n "$peer" ] && break
done
[ -n "$peer" ] || { echo "run_r1_both: this Mac has no IPv4 address" >&2; exit 2; }
python3 - "$secret" "$out/wifi_secret.h" <<'PY'
import sys
v = dict(l.rstrip('\n').split('=', 1) for l in open(sys.argv[1]) if '=' in l)
q = lambda s: '"' + ''.join('\\x%02x' % b for b in s.encode()) + '"'
open(sys.argv[2], 'w').write('#define SILICA_WIFI_SSID %s\n#define SILICA_WIFI_PASSPHRASE %s\n' % (q(v['SILICA_WIFI_SSID']), q(v['SILICA_WIFI_PASSPHRASE'])))
PY

# The program and the modules it uses, compiled in a copy, with the peer's address in place of the placeholder.
SRC="$DEMO/build/board_peer/src"
rm -rf "$DEMO/build/board_peer"; mkdir -p "$SRC/dangerous_exposure_source/lib"
ln -sfn "$ROOT/compiler/stdlib/net" "$SRC/dangerous_exposure_source/sockets"
ln -sfn "$ROOT/compiler/stdlib/ble" "$SRC/dangerous_exposure_source/ble"
modules="Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_tcp_carrier dangerous_nimble dangerous_ble_radio dangerous_ble_gatt_board_carrier"
for m in $modules; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$SRC/$m.silica"; done
ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" "$SRC/trial_wait_int64.silica"
ln -sf "$ROOT/trials/lib_trial_support/trial_support_hex.silica" "$SRC/trial_support_hex.silica"
sed -e "s|^fn address() -> string { \"0.0.0.0:0\" }|fn address() -> string { \"$peer:$PORT\" }|" \
    -e "s|^fn ble_links() -> int64 { 1 }|fn ble_links() -> int64 { $links }|" \
    -e "s|^fn links() -> int64 { 1 }|fn links() -> int64 { $links }|" "$DEMO/dangerous_both_board_peer.silica" > "$SRC/dangerous_both_board_peer.silica"
# --only wifi|ble: the other radio's carrier is never opened (its libraries are still in the image), and
# the program ends when the one's links are done
# BOTH_NO_BUSY=1: the busy actor is never started, so the actors' core goes idle between messages
[ "${BOTH_NO_BUSY:-0}" = 1 ] && sed -i '' -e '/cast(b0, me impl ActorMessage {});/d' "$SRC/dangerous_both_board_peer.silica"
case "$only" in
    wifi) sed -i '' -e '/cast(bcar, (:open, bme, ble_address())/d' -e 's/spawn({ left: 2, code: 0 }, both,/spawn({ left: 1, code: 0 }, both,/' \
              -e 's/cast(car, (:open, me, address()) impl ActorMessage {});/cast(car, (:open, me, address()) impl ActorMessage {})/' "$SRC/dangerous_both_board_peer.silica" ;;
    ble) sed -i '' -e '/cast(car, (:open, me, address())/d' -e '/send_after(watch_ms(), me, (:watch, 0)/d' -e 's/spawn({ left: 2, code: 0 }, both,/spawn({ left: 1, code: 0 }, both,/' "$SRC/dangerous_both_board_peer.silica" ;;
esac
for m in $modules trial_support_hex trial_wait_int64 dangerous_both_board_peer; do echo "$m.silica"; done > "$SRC/silica.config"
# The compiler wants the archive the .meta names; the wrapper itself is compiled into the image, so
# the archive here holds only the symbols.
sed -n 's/^ *symbol: "\(.*\)"$/long long \1(void) { return 0; }/p' "$ROOT/compiler/stdlib/net/silica_sockets_wrapper.meta" > "$SRC/stub.c"
"$XT/xtensa-esp32s3-elf-gcc" -c -mlongcalls -Os -ffreestanding "$SRC/stub.c" -o "$SRC/stub.o"
"$XT/xtensa-esp32s3-elf-ar" rcs "$SRC/dangerous_exposure_source/lib/libsilica_sockets.a" "$SRC/stub.o"
sed -n 's/^ *symbol: "\(.*\)"$/long long \1(void) { return 0; }/p' "$ROOT/compiler/stdlib/ble/silica_ble_nimble_wrapper.meta" > "$SRC/stub_ble.c"
"$XT/xtensa-esp32s3-elf-gcc" -c -mlongcalls -Os -ffreestanding "$SRC/stub_ble.c" -o "$SRC/stub_ble.o"
"$XT/xtensa-esp32s3-elf-ar" rcs "$SRC/dangerous_exposure_source/lib/libsilica_ble_nimble.a" "$SRC/stub_ble.o"
ec=1
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    ec=0; ( cd "$SRC" && "$CC" > ../compile.log 2>&1 ) || ec=$?
    [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break
done
[ "$ec" -eq 0 ] || { echo "run_r1_both: the program did not compile; see $DEMO/build/board_peer/compile.log" >&2; grep -A8 "Compilation error" "$SRC/../compile.log" | head -14 >&2; exit 1; }

# main's stacks: the builder cannot bound a start that calls into ESP-IDF's code (run_r1_peer.sh)
# (8 KB here, where memory is short: the guest's builder bounds a demo's main at 4.5 KB)
syms="-Wl,--defsym,_silica_main_stack_req=0x2000 -Wl,--defsym,_silica_main_aux_req=0x400"
for s in _bt_bss_start _bt_bss_end _bt_controller_bss_start _bt_controller_bss_end _bt_data_start _bt_data_end _bt_controller_data_start _bt_controller_data_end; do
    syms="$syms -Wl,--defsym,$s=0"
done
C="$IDF_PATH/components"
W="$C/esp_wifi/lib/esp32s3"
L="$C/lwip"
# in flash: the libraries and the program's own compiled code (each .sams becomes <n>.<name>.o)
BOARD_FLASH_FILES="*libbt.a *libbtdm_app.a *libbtbb.a *libnet80211.a *libcoexist.a *libesp_coex.a *libpp.a *libcore.a *libphy.a *libwpa_supplicant.a *libesp_wifi.a *libmbedcrypto.a *libmbedtls.a *libmbedx509.a *libtfpsacrypto.a *libbuiltin.a *libeverest.a *libp256m.a *liblwip.a"
for f in "$SRC"/*.sams; do
    BOARD_FLASH_FILES="$BOARD_FLASH_FILES *.$(basename "$f" .sams).o"
done
# and the wrappers, the Wi-Fi shim and the lwIP glue (the sources after the program, in the order of the
# build's command below: 1, 2, 5 and 6); r1_port.c and hci_shim.c run before the flash is mapped
BOARD_FLASH_FILES="$BOARD_FLASH_FILES *r1_both.1.o *r1_both.2.o *r1_both.5.o *r1_both.6.o"
export BOARD_FLASH_FILES
# the libraries' code that ESP-IDF keeps in RAM (.iram1) runs from flash too: nothing here takes the flash away
export BOARD_FLASH_IRAM=1
inc="-I$out -I$C/esp_wifi/include -I$C/esp_wifi/include/local -I$C/esp_event/include -I$C/esp_netif/include -I$C/esp_phy/include"
inc="$inc -I$L/include -I$L/include/apps -I$L/include/apps/sntp -I$L/lwip/src/include -I$L/port/include -I$L/port/freertos/include -I$L/port/esp32xx/include -I$L/port/esp32xx/include/arch"
export SPIKE_CFLAGS="${SPIKE_CFLAGS:-} $inc -DSPIKE_WIFI -DSOCKETS_WIFI_PS -DSOCKETS_WIFI_RX_BUFFERS=6 -DSPIKE_STACK_TIGHT -DSILICA_BLE_OPEN_LINK -DSPIKE_INTERRUPT -DSPIKE_BT_CORE=1 -DSPIKE_ONE_HEAP -DSPIKE_LIB_REGION_KB=${BOTH_LIB_REGION_KB:-64} -DR1_CPU_MHZ=${R1_CPU_MHZ:-160}"
# the runtime on one core, core 0, for the program's actors; core 1 is the radio's tasks' (r1_port.c)
export BOARD_ASFLAGS="-DNCORES_RUN=1"
export BOARD_FFI_STACK=${BOARD_FFI_STACK:-4096}
boot=$(ls "$IDF_BUILD"/bootloader/esp-idf/*/lib*.a | tr '\n' ' ')
mbed=$(find "$IDF_BUILD/esp-idf/mbedtls" -name "*.a" | tr '\n' ' ')
# shellcheck disable=SC2086
SPIKE_LDFLAGS="$syms" "$HERE/build.sh" --app "$out/r1_both" "$SRC"/*.sams \
    "$ROOT/compiler/stdlib/wifi/silica_sockets_lwip.c" "$ROOT/compiler/stdlib/ble/silica_ble_nimble.c" "$HERE/r1_port.c" "$HERE/hci_shim.c" "$HERE/wifi_shim.c" "$HERE/wifi_net.c" "$HERE/spike_co.S" "boot:$HERE/spike_flash.c" \
    "$IDF_BUILD/esp-idf/bt/libbt.a" "$C/bt/controller/lib_esp32c3_family/esp32s3/libbtdm_app.a" "$C/esp_phy/lib/esp32s3/libbtbb.a" \
    "$IDF_BUILD/esp-idf/lwip/liblwip.a" "$IDF_BUILD/esp-idf/esp_wifi/libesp_wifi.a" "$W/libnet80211.a" "$W/libpp.a" "$W/libcore.a" "$IDF_BUILD/esp-idf/wpa_supplicant/libwpa_supplicant.a" $mbed \
    "$IDF_BUILD/esp-idf/esp_coex/libesp_coex.a" "$C/esp_coex/lib/esp32s3/libcoexist.a" "$IDF_BUILD/esp-idf/esp_hal_security/libesp_hal_security.a" \
    "$C/esp_phy/lib/esp32s3/libphy.a" "$IDF_BUILD/esp-idf/esp_phy/libesp_phy.a" $boot "$C/xtensa/esp32s3/libxt_hal.a"
[ "$build_only" = 1 ] && exit 0
"$PY" "$BOARD/tools/run_on_board.py" --flash --timeout "${SPIKE_TIMEOUT:-150}" "$out/r1_both.bin"
