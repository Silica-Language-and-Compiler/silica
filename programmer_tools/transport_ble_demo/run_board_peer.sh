#!/bin/sh
# The board end of the Bluetooth demo (transport_ble_plan.md stage 7). Builds dangerous_ble_board_peer
# with the ESP32-S3 Silica compiler, makes a guest image with the NimBLE wrapper in it and runs it on
# the board: the (:ble_gatt) carrier on the chip's radio advertises the service as a peripheral, sends
# one 48-byte ETF frame in 20-byte segments to the central that subscribes, and prints the reading of
# the frame the central sends back, with a busy actor on each of the two cores throughout.
#
#   ./run_board_peer.sh [uuid] [--central] [--timeout <seconds>] [--build-only]
#
# --links <n> (default 1) and --cut <k>: as run_peer.sh's: n whole exchanges, each on a link of its own;
# on link k this end sends only its first segment and closes. --hold <seconds>: the link is kept that
# long after the exchange.
# --central: the board scans for a peripheral offering the service and connects to it (the plan's stage
# 9); the peripheral is then the Mac (./run_peer.sh peripheral [uuid], started first).
# uuid is the service's UUID (4, 8 or 36 characters); without it the service is the Nordic UART
# Service. --timeout (default 300) bounds the wait for the central. GUEST_RAM=<bytes> sets Silica's
# block (the guest's README).
#
# The central is the Mac (./run_peer.sh central [uuid], in another terminal) or a phone (nRF
# Connect): connect to "Silica", enable indications on the TX characteristic (6E400003) and accept the
# phone's pairing request (the board requires an encrypted link): the board
# prints the three segments it sent and the phone shows them. Write the same three values, as byte
# arrays and in order, to the RX characteristic (6E400002): the board prints the reading and exits 0.
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
UUID="" TIMEOUT=300 BUILD_ONLY=0 ROLE=peripheral LINKS=1 CUT=-1 HOLD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --build-only) BUILD_ONLY=1; shift ;;
        --links) LINKS=$2; shift 2 ;;
        --cut) CUT=$2; shift 2 ;;
        --hold) HOLD=$2; shift 2 ;;
        --central) ROLE=central; shift ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        -*) echo "run_board_peer: unknown argument $1" >&2; exit 2 ;;
        *) UUID=$1; shift ;;
    esac
done
WORK="$HERE/build/board_peer"
rm -rf "$WORK"; mkdir -p "$WORK/src/dangerous_exposure_source/lib"
cd "$WORK/src" || exit 1

# The program and the modules it uses, compiled in a copy, with the service in place of the placeholder.
ln -sfn "$ROOT/compiler/stdlib/ble" dangerous_exposure_source/ble
for m in Supervisor wire_etf wireframe Carrier dangerous_nimble dangerous_ble_radio dangerous_ble_gatt_board_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
ln -sf "$ROOT/trials/lib_trial_support/trial_support_hex.silica" trial_support_hex.silica
sed -e "s|^fn address() -> string { \"peripheral:\" }|fn address() -> string { \"$ROLE:$UUID\" }|" \
    -e "s|^fn links() -> int64 { 1 }|fn links() -> int64 { $LINKS }|" -e "s|^fn cut_link() -> int64 { 0 - 1 }|fn cut_link() -> int64 { 0 - 1 + 1 + $CUT }|" \
    -e "s|^fn hold_ms() -> uint64 { 0 }|fn hold_ms() -> uint64 { ${HOLD}000 }|" "$HERE/dangerous_ble_board_peer.silica" > dangerous_ble_board_peer.silica
printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_nimble.silica\ndangerous_ble_radio.silica\ndangerous_ble_gatt_board_carrier.silica\ntrial_support_hex.silica\ntrial_wait_int64.silica\ndangerous_ble_board_peer.silica\n' > silica.config
# The compiler wants the archive the .meta names; the wrapper itself is compiled into the image as
# ESP-IDF code, so the archive here holds only the symbols.
sed -n 's/^ *symbol: "\(.*\)"$/long long \1(void) { return 0; }/p' "$ROOT/compiler/stdlib/ble/silica_ble_nimble_wrapper.meta" > stub.c
"$XT/xtensa-esp32s3-elf-gcc" -c -mlongcalls -Os -ffreestanding stub.c -o stub.o || exit 1
"$XT/xtensa-esp32s3-elf-ar" rcs dangerous_exposure_source/lib/libsilica_ble_nimble.a stub.o
for i in $(seq 1 12); do "$CC" > ../compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
[ "$ec" -eq 0 ] || { echo "run_board_peer: compile failed; see $WORK/compile.log"; grep -A8 "Compilation error" ../compile.log | head -14; exit 1; }

BOARD_PYTHON="$PY" sh "$GUEST/tools/build_image.sh" -o "$WORK/image/board_peer" ./*.sams "$ROOT/compiler/stdlib/ble/silica_ble_nimble.c" || exit 1
[ "$BUILD_ONLY" = 1 ] && exit 0
"$PY" "$GUEST/tools/run_on_board.py" --timeout "$TIMEOUT" "$WORK/image/board_peer.bin"
