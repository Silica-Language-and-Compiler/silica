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

# Route R1 spike (transport_ble_plan.md stage 12): builds a bare-metal image, a chip the Silica
# runtime owns, with ESP-IDF code linked in from the guest's cached ESP-IDF build
# (board/guest/.cache/idf: build any guest image once to make it).
#
#   ./build.sh [--app] <out_dir>/<name> <source>...
#
# A .c source is compiled by ESP-IDF's own command: that of its bootloader build, which has no
# FreeRTOS, or with --app that of the application (the guest image), whose include paths reach the
# Bluetooth headers; a source written boot:<file>.c is compiled by the bootloader's command even then.
# SPIKE_CFLAGS adds flags. Every other source (.S, .o, .a) goes to the bare-metal
# builder as it is; spike_support.c is always added. The chip's ROM symbols and the peripherals'
# addresses come from ESP-IDF's linker scripts.
#
#   clocks:  ./build.sh out/clocks clocks_main.c $B/esp_hw_support/libesp_hw_support.a
#   radio:   ./build.sh out/phy phy_main.c $B/esp_hw_support/libesp_hw_support.a $P/libphy.a $A/esp_phy/libesp_phy.a
#   hci:     see run_hci.sh
#
# with B the bootloader's libraries (.cache/idf/bootloader/esp-idf), A the application's
# (.cache/idf/esp-idf) and P ESP-IDF's components/esp_phy/lib/esp32s3.

set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BOARD="$HERE/.."
IDF_BUILD="$BOARD/guest/.cache/idf"
IDF_PATH=${IDF_PATH:-$HOME/esp/esp-idf-v6.2}
[ -f "$IDF_BUILD/bootloader/compile_commands.json" ] || { echo "build.sh: no cached ESP-IDF build at $IDF_BUILD" >&2; exit 2; }

db="$IDF_BUILD/bootloader/compile_commands.json"; like="port/esp32s3/rtc_clk.c"; cwd="$IDF_BUILD/bootloader"
if [ "$1" = "--app" ]; then
    db="$IDF_BUILD/compile_commands.json"; like="controller/esp32c3/bt.c"; cwd="$IDF_BUILD"; shift
fi
out=$1; shift
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
mkdir -p "$(dirname "$out")"

# ESP-IDF's compile command for one of its files, less that file and its output
command_like() {
    python3 - "$1" "$2" <<'PY'
import json, shlex, sys
for e in json.load(open(sys.argv[1])):
    if e['file'].endswith(sys.argv[2]):
        a = shlex.split(e['command'])
        a = a[:a.index('-o')]
        print(' '.join(shlex.quote(x) for x in a if x != '-Werror'))
        break
PY
}
cmd=$(command_like "$db" "$like")
bootcmd=$(command_like "$IDF_BUILD/bootloader/compile_commands.json" "port/esp32s3/rtc_clk.c")
inc="-I$IDF_PATH/components/esp_phy/include -I$IDF_PATH/components/esp_phy/esp32s3/include"
sources=""
n=0
for src in "$@"; do
    case "$src" in
        boot:*.c) n=$((n + 1))
             obj="$out.$n.o"
             src=${src#boot:}
             abs="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
             ( cd "$IDF_BUILD/bootloader" && eval "$bootcmd $inc ${SPIKE_CFLAGS:-} -Wno-unused-parameter -o '$obj' -c '$abs'" )
             sources="$sources $obj" ;;
        *.c) n=$((n + 1))
             obj="$out.$n.o"
             abs="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
             ( cd "$cwd" && eval "$cmd $inc ${SPIKE_CFLAGS:-} -Wno-unused-parameter -o '$obj' -c '$abs'" )
             sources="$sources $obj" ;;
        *)   sources="$sources $src" ;;
    esac
done

ld=""
for f in esp32s3.rom.ld esp32s3.rom.api.ld esp32s3.rom.libgcc.ld esp32s3.rom.libc.ld esp32s3.rom.newlib.ld esp32s3.rom.version.ld \
         esp32s3.rom.bt_funcs.ld esp32s3.rom.ble_cca.ld esp32s3.rom.ble_test.ld; do
    ld="$ld -Wl,-T,$IDF_PATH/components/esp_rom/esp32s3/ld/$f"
done
ld="$ld -Wl,-T,$IDF_PATH/components/esp_hal_regi2c/esp32s3/rom.regi2c.ld"
# the addresses of the chip's peripheral register blocks
ld="$ld -Wl,-T,$IDF_PATH/components/soc/esp32s3/ld/esp32s3.peripherals.ld"
# the runtime's number for a record no unit of this image declares
ld="$ld -Wl,--defsym,silica_registry_shape_exit_report=0"
# shellcheck disable=SC2086
BOARD_LDFLAGS="$ld ${SPIKE_LDFLAGS:-}" sh "$BOARD/tools/build_image.sh" -o "$out" $sources "$HERE/spike_support.c"
