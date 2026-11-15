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

# Route R1, Wi-Fi (transport_ble_plan.md stage 12, part 6, step 3): a Silica program with its actors
# exchanges a frame with the Mac over TCP, on the chip the bare-metal runtime owns: no ESP-IDF
# start-up, no FreeRTOS.
#
#   BOARD_PORT=<port> ./run_r1_wifi_peer.sh [--build-only] [--links <n>] [--listen] [<out_dir>]
#
# The program is programmer_tools/transport_wifi_demo/dangerous_wifi_board_peer.silica above the
# hosted (:tcp) carrier (compiler/stdlib/dangerous_tcp_carrier.silica) and dangerous_sockets, whose
# wrappers on the board are lwIP's (compiler/stdlib/wifi/silica_sockets_lwip.c). The image is the
# bare-metal runtime on core 0 for the program's actors; on core 1 the tasks of Espressif's Wi-Fi
# libraries and of lwIP, and the Wi-Fi interrupt (r1_port.c, hci_shim.c, wifi_shim.c, wifi_net.c). The
# program's own code and the libraries' run from flash.
#
# The access point's name and passphrase come from SILICA_WIFI_FILE as for run_wifi.sh. The peer is
# wifi_peer.py on this Mac, which the script starts: it sends each frame back. --links <n> exchanges,
# each on a TCP connection of its own. The Mac must be on the same network.
# --listen: the board listens (the program opens "listen:<port>" on the station's address) and the
# Mac connects for each exchange, finding the board by trying the port across its /24 network.
# The libraries' memory comes from the runtime's heap (-DSPIKE_ONE_HEAP, hci_shim.c).
# R1_CPU_MHZ=80|160|240 (160 unless given).
#
# Needs: the ESP32-S3_raw Silica compiler (SILICA_COMPILER, default the local build), the guest's
# cached ESP-IDF build, the board on BOARD_PORT.

set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BOARD="$HERE/.."
ROOT=$(cd "$BOARD/../../../../.." && pwd)
DEMO="$ROOT/programmer_tools/transport_wifi_demo"
IDF_BUILD="$BOARD/guest/.cache/idf"
IDF_PATH=${IDF_PATH:-$HOME/esp/esp-idf-v6.2}
PY=${BOARD_PYTHON:-$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/python}
CC=${SILICA_COMPILER:-$ROOT/compiler/build/ESP32-S3_raw/silica-compiler}
XT=${XTENSA_BIN:-$HOME/.espressif/tools/xtensa-esp-elf/esp-16.1.0_20260609/xtensa-esp-elf/bin}
PORT=${WIFI_PORT:-4370}
build_only=0 links=1 listen=0
while [ $# -gt 0 ]; do
    case "$1" in
        --build-only) build_only=1; shift ;;
        --links) links=$2; shift 2 ;;
        --listen) listen=1; shift ;;
        *) break ;;
    esac
done
out=${1:-$HERE/out}
mkdir -p "$out"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

secret=${SILICA_WIFI_FILE:-$ROOT/.silica_wifi}
[ -f "$secret" ] || secret=$HOME/.silica_wifi
[ -f "$secret" ] || { echo "run_r1_wifi_peer: no file with the access point's name and passphrase (see run_wifi.sh)" >&2; exit 2; }
peer=""
for i in en0 en1 en2; do
    peer=$(ipconfig getifaddr $i 2>/dev/null) && [ -n "$peer" ] && break
done
[ -n "$peer" ] || { echo "run_r1_wifi_peer: this Mac has no IPv4 address" >&2; exit 2; }
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
modules="Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_tcp_carrier"
for m in $modules; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$SRC/$m.silica"; done
ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" "$SRC/trial_wait_int64.silica"
ln -sf "$ROOT/trials/lib_trial_support/trial_support_hex.silica" "$SRC/trial_support_hex.silica"
address="$peer:$PORT" listening=false connect_to=""
[ "$listen" = 1 ] && address="listen:$PORT" listening=true connect_to=$peer
sed -e "s|^fn address() -> string { \"0.0.0.0:0\" }|fn address() -> string { \"$address\" }|" \
    -e "s|^fn listening() -> boolean { false }|fn listening() -> boolean { $listening }|" \
    -e "s|^fn links() -> int64 { 1 }|fn links() -> int64 { $links }|" "$DEMO/dangerous_wifi_board_peer.silica" > "$SRC/dangerous_wifi_board_peer.silica"
for m in $modules trial_support_hex trial_wait_int64 dangerous_wifi_board_peer; do echo "$m.silica"; done > "$SRC/silica.config"
# The compiler wants the archive the .meta names; the wrapper itself is compiled into the image, so
# the archive here holds only the symbols.
sed -n 's/^ *symbol: "\(.*\)"$/long long \1(void) { return 0; }/p' "$ROOT/compiler/stdlib/net/silica_sockets_wrapper.meta" > "$SRC/stub.c"
"$XT/xtensa-esp32s3-elf-gcc" -c -mlongcalls -Os -ffreestanding "$SRC/stub.c" -o "$SRC/stub.o"
"$XT/xtensa-esp32s3-elf-ar" rcs "$SRC/dangerous_exposure_source/lib/libsilica_sockets.a" "$SRC/stub.o"
ec=1
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    ec=0; ( cd "$SRC" && "$CC" > ../compile.log 2>&1 ) || ec=$?
    [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break
done
[ "$ec" -eq 0 ] || { echo "run_r1_wifi_peer: the program did not compile; see $DEMO/build/board_peer/compile.log" >&2; grep -A8 "Compilation error" "$SRC/../compile.log" | head -14 >&2; exit 1; }

# main's stacks: the builder cannot bound a start that calls into ESP-IDF's code (run_r1_peer.sh)
syms="-Wl,--defsym,_silica_main_stack_req=0x4000 -Wl,--defsym,_silica_main_aux_req=0x400"
C="$IDF_PATH/components"
W="$C/esp_wifi/lib/esp32s3"
L="$C/lwip"
# in flash: the libraries and the program's own compiled code (each .sams becomes <n>.<name>.o)
BOARD_FLASH_FILES="*libnet80211.a *libcoexist.a *libesp_coex.a *libpp.a *libcore.a *libphy.a *libwpa_supplicant.a *libesp_wifi.a *libmbedcrypto.a *libmbedtls.a *libmbedx509.a *libtfpsacrypto.a *libbuiltin.a *libeverest.a *libp256m.a *liblwip.a"
for f in "$SRC"/*.sams; do
    BOARD_FLASH_FILES="$BOARD_FLASH_FILES *.$(basename "$f" .sams).o"
done
export BOARD_FLASH_FILES
inc="-I$out -I$C/esp_wifi/include -I$C/esp_wifi/include/local -I$C/esp_event/include -I$C/esp_netif/include -I$C/esp_phy/include"
inc="$inc -I$L/include -I$L/include/apps -I$L/include/apps/sntp -I$L/lwip/src/include -I$L/port/include -I$L/port/freertos/include -I$L/port/esp32xx/include -I$L/port/esp32xx/include/arch"
export SPIKE_CFLAGS="${SPIKE_CFLAGS:-} $inc -DSPIKE_WIFI -DSPIKE_INTERRUPT -DSPIKE_BT_CORE=1 -DSPIKE_ONE_HEAP -DR1_CPU_MHZ=${R1_CPU_MHZ:-160}"
# the runtime on one core, core 0, for the program's actors; core 1 is the radio's tasks' (r1_port.c)
export BOARD_ASFLAGS="-DNCORES_RUN=1"
export BOARD_FFI_STACK=${BOARD_FFI_STACK:-6144}
boot=$(ls "$IDF_BUILD"/bootloader/esp-idf/*/lib*.a | tr '\n' ' ')
mbed=$(find "$IDF_BUILD/esp-idf/mbedtls" -name "*.a" | tr '\n' ' ')
# shellcheck disable=SC2086
SPIKE_LDFLAGS="$syms" "$HERE/build.sh" --app "$out/r1_wifi_peer" "$SRC"/*.sams \
    "$ROOT/compiler/stdlib/wifi/silica_sockets_lwip.c" "$HERE/r1_port.c" "$HERE/hci_shim.c" "$HERE/wifi_shim.c" "$HERE/wifi_net.c" "$HERE/spike_co.S" "boot:$HERE/spike_flash.c" \
    "$IDF_BUILD/esp-idf/lwip/liblwip.a" "$IDF_BUILD/esp-idf/esp_wifi/libesp_wifi.a" "$W/libnet80211.a" "$W/libpp.a" "$W/libcore.a" "$IDF_BUILD/esp-idf/wpa_supplicant/libwpa_supplicant.a" $mbed \
    "$IDF_BUILD/esp-idf/esp_coex/libesp_coex.a" "$C/esp_coex/lib/esp32s3/libcoexist.a" "$IDF_BUILD/esp-idf/esp_hal_security/libesp_hal_security.a" \
    "$C/esp_phy/lib/esp32s3/libphy.a" "$IDF_BUILD/esp-idf/esp_phy/libesp_phy.a" $boot "$C/xtensa/esp32s3/libxt_hal.a"
[ "$build_only" = 1 ] && exit 0
python3 "$HERE/wifi_peer.py" "$PORT" "$links" "${SPIKE_TIMEOUT:-120}" $connect_to > "$out/wifi_peer.log" 2>&1 &
peer_pid=$!
status=0
"$PY" "$BOARD/tools/run_on_board.py" --flash --timeout "${SPIKE_TIMEOUT:-120}" "$out/r1_wifi_peer.bin" || status=$?
wait "$peer_pid" || status=1
echo "the Mac's end:"
cat "$out/wifi_peer.log"
exit $status
