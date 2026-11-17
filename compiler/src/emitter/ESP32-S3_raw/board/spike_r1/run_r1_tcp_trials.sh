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

# Route R1: the hosts' (:tcp) trials on the board (transport_ble_plan.md stage 12, part 13). Each trial
# program is built unchanged above the hosted (:tcp) carrier and dangerous_sockets, with lwIP's
# wrappers (compiler/stdlib/wifi/silica_sockets_lwip.c), as run_r1_wifi_peer.sh builds the Wi-Fi demo;
# it runs on the board and its console output is compared with the trial's .scout, the output the
# hosts must give. The trials' two ends are both in the program, on 127.0.0.1: lwIP's own loopback
# interface, so no access point and no peer take part (the image still holds the Wi-Fi libraries,
# and the access point's name and passphrase are compiled in as for run_r1_wifi_peer.sh).
#
#   BOARD_PORT=<port> ./run_r1_tcp_trials.sh [--build-only] [<out_dir>] [<trial>/<program> ...]
#
# Without programs named: every program of TRIALS below. Lines the shim prints ("shim: ...") are
# left out of the comparison. A program whose carried_on names a link the board's pack does not provide
# ((:interface, name), (:ethernet, n), (:wifi, n) but 0) is refused by the compiler
# (E2412), which is reported and not counted. Exit status: the number of programs that failed.
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
TRIALS="transport_addition/app_transport_tcp_listener/dangerous_tcp_listener
transport_addition/app_transport_tcp_loopback_link/dangerous_tcp_loopback_link
transport_addition/app_transport_tcp_listen_any/dangerous_tcp_listen_any
ffi_addition/app_transport_tcp_loopback/dangerous_tcp_loopback
transport_addition/app_transport_tcp_link_rules/dangerous_link_ethernet_absent
transport_addition/app_transport_tcp_link_rules/dangerous_link_interface_absent
transport_addition/app_transport_tcp_link_rules/dangerous_link_listen_any_refused_interface
transport_addition/app_transport_tcp_link_rules/dangerous_link_listen_ip
transport_addition/app_transport_tcp_link_rules/dangerous_link_listen_ip_refused_loopback
transport_addition/app_transport_tcp_link_rules/dangerous_link_wifi_absent"
build_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --build-only) build_only=1; shift ;;
        *) break ;;
    esac
done
out=${1:-$HERE/out}
[ $# -gt 0 ] && shift
[ $# -gt 0 ] && TRIALS="$*"
mkdir -p "$out"
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

secret=${SILICA_WIFI_FILE:-$ROOT/.silica_wifi}
[ -f "$secret" ] || secret=$HOME/.silica_wifi
[ -f "$secret" ] || { echo "run_r1_wifi_peer: no file with the access point's name and passphrase (see run_wifi.sh)" >&2; exit 2; }
python3 - "$secret" "$out/wifi_secret.h" <<'PY'
import sys
v = dict(l.rstrip('\n').split('=', 1) for l in open(sys.argv[1]) if '=' in l)
q = lambda s: '"' + ''.join('\\x%02x' % b for b in s.encode()) + '"'
open(sys.argv[2], 'w').write('#define SILICA_WIFI_SSID %s\n#define SILICA_WIFI_PASSPHRASE %s\n' % (q(v['SILICA_WIFI_SSID']), q(v['SILICA_WIFI_PASSPHRASE'])))
PY

DEMO="$out/work"
base_cflags=${SPIKE_CFLAGS:-}
failed=0
for t in $TRIALS; do
    name=$(basename "$t")
    dir="$ROOT/trials/$(dirname "$t")"
    [ -f "$dir/$name.silica" ] && [ -f "$dir/$name.scout" ] || { echo "run_r1_tcp_trials: no $t.silica with a .scout" >&2; exit 2; }
    # The program and the stdlib modules it uses, compiled in a directory of its own.
    SRC="$DEMO/$name/src"
    rm -rf "$DEMO/$name"; mkdir -p "$SRC/dangerous_exposure_source/lib"
    ln -sfn "$ROOT/compiler/stdlib/net" "$SRC/dangerous_exposure_source/sockets"
    modules="Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_tcp_carrier"
    for m in $modules; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$SRC/$m.silica"; done
    ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" "$SRC/trial_wait_int64.silica"
    ln -sf "$dir/$name.silica" "$SRC/$name.silica"
    for m in $modules trial_wait_int64 $name; do echo "$m.silica"; done > "$SRC/silica.config"
    sed -n 's/^ *symbol: "\(.*\)"$/long long \1(void) { return 0; }/p' "$ROOT/compiler/stdlib/net/silica_sockets_wrapper.meta" > "$SRC/stub.c"
    "$XT/xtensa-esp32s3-elf-gcc" -c -mlongcalls -Os -ffreestanding "$SRC/stub.c" -o "$SRC/stub.o"
    "$XT/xtensa-esp32s3-elf-ar" rcs "$SRC/dangerous_exposure_source/lib/libsilica_sockets.a" "$SRC/stub.o"
    ec=1
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        ec=0; ( cd "$SRC" && "$CC" > ../compile.log 2>&1 ) || ec=$?
        [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break
    done
    if [ "$ec" -ne 0 ] && grep -q "is not provided by this emit target" "$DEMO/$name/compile.log"; then
        echo "$t: not for the board (E2412: $(grep -o 'link (:[^)]*) is not provided' "$DEMO/$name/compile.log" | head -1))"; continue
    fi
    if [ "$ec" -ne 0 ]; then
        echo "$t: did not compile; see $DEMO/$name/compile.log"; failed=$((failed + 1)); continue
    fi

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
    export BOARD_FLASH_FILES SPIKE_CFLAGS
    inc="-I$out -I$C/esp_wifi/include -I$C/esp_wifi/include/local -I$C/esp_event/include -I$C/esp_netif/include -I$C/esp_phy/include"
    inc="$inc -I$L/include -I$L/include/apps -I$L/include/apps/sntp -I$L/lwip/src/include -I$L/port/include -I$L/port/freertos/include -I$L/port/esp32xx/include -I$L/port/esp32xx/include/arch"
    SPIKE_CFLAGS="$base_cflags $inc -DSPIKE_WIFI -DSPIKE_INTERRUPT -DSPIKE_BT_CORE=1 -DSPIKE_ONE_HEAP -DSPIKE_LIB_REGION_KB=38 -DR1_CPU_MHZ=${R1_CPU_MHZ:-160}"
    # the runtime on one core, core 0, for the program's actors; core 1 is the radio's tasks' (r1_port.c)
    export BOARD_ASFLAGS="-DNCORES_RUN=1"
    export BOARD_FFI_STACK=${BOARD_FFI_STACK:-6144}
    boot=$(ls "$IDF_BUILD"/bootloader/esp-idf/*/lib*.a | tr '\n' ' ')
    mbed=$(find "$IDF_BUILD/esp-idf/mbedtls" -name "*.a" | tr '\n' ' ')
    # shellcheck disable=SC2086
    if ! SPIKE_LDFLAGS="$syms" "$HERE/build.sh" --app "$out/$name" "$SRC"/*.sams \
        "$ROOT/compiler/stdlib/wifi/silica_sockets_lwip.c" "$HERE/r1_port.c" "$HERE/hci_shim.c" "$HERE/wifi_shim.c" "$HERE/wifi_net.c" "$HERE/spike_co.S" "boot:$HERE/spike_flash.c" \
        "$IDF_BUILD/esp-idf/lwip/liblwip.a" "$IDF_BUILD/esp-idf/esp_wifi/libesp_wifi.a" "$W/libnet80211.a" "$W/libpp.a" "$W/libcore.a" "$IDF_BUILD/esp-idf/wpa_supplicant/libwpa_supplicant.a" $mbed \
        "$IDF_BUILD/esp-idf/esp_coex/libesp_coex.a" "$C/esp_coex/lib/esp32s3/libcoexist.a" "$IDF_BUILD/esp-idf/esp_hal_security/libesp_hal_security.a" \
        "$C/esp_phy/lib/esp32s3/libphy.a" "$IDF_BUILD/esp-idf/esp_phy/libesp_phy.a" $boot "$C/xtensa/esp32s3/libxt_hal.a" > "$out/$name.build.log" 2>&1; then
        echo "$t: the image did not build; see $out/$name.build.log"; failed=$((failed + 1)); continue
    fi
    [ "$build_only" = 1 ] && { echo "$t: built"; continue; }
    "$PY" "$BOARD/tools/run_on_board.py" --flash --timeout "${SPIKE_TIMEOUT:-60}" "$out/$name.bin" > "$out/$name.raw" 2> "$out/$name.log" || true
    grep -a -v '^shim: ' "$out/$name.raw" > "$out/$name.sout" || true
    # a .scout with an actor failure report in it holds <PTR> for the fields that differ from run to
    # run, and its suite compares with the pointer lines folded (tests/pins/compare_scout_normalized.sh)
    compare="$BOARD/tools/compare_sout.sh"
    grep -q '<PTR>' "$dir/$name.scout" && compare="$BOARD/tests/pins/compare_scout_normalized.sh"
    if "$compare" "$out/$name.sout" "$dir/$name.scout" > "$out/$name.diff" 2>&1; then
        echo "$t: pass"
    else
        echo "$t: FAIL; see $out/$name.diff"; failed=$((failed + 1))
    fi
done
exit $failed
