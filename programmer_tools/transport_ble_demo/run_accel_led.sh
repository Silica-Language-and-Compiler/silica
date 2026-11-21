#!/bin/bash
# The end-to-end Bluetooth demo (transport_ble_plan.md stage 8), both ends Silica: the board, a peripheral,
# sends one accelerometer reading as an ETF frame over the (:ble_gatt) carrier; the Mac, the central, decodes
# it and answers one LED command; each end prints what it decoded. The two programs are the USB-C demo's
# (../transport_usb_serial_jtag_demo and board/apps/silica_33_transport_usb_serial_jtag_etf) on the Bluetooth
# carrier: dangerous_ble_board_accel_led.silica and dangerous_ble_mac_led.silica say what differs.
#
#   BOARD_PORT=<port> ./run_accel_led.sh [uuid] [--timeout <seconds>] [--build-only]
#
# uuid is the service's UUID (4, 8 or 36 characters); without it the service is the Nordic UART Service.
# --timeout (default 120) bounds the board's wait for the Mac. The script builds both programs, flashes and
# starts the board, starts the Mac's program when the Mac hears the board advertising, and prints both
# consoles. Exit 0 when both programs ended with status 0.
#
# Needs: both Silica compilers (SILICA_COMPILER for the Mac, BOARD_SILICA_COMPILER for the ESP32-S3; default
# the local builds), Apple's clang, ESP-IDF 6.2 and the board tools' environment (the guest's README), the
# board on BOARD_PORT. macOS may ask once to let the terminal use Bluetooth. A Mac that connected to the
# board while it ran another program may answer from the table it kept, with no characteristics: switch
# its Bluetooth off and on.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GUEST="$ROOT/compiler/src/emitter/ESP32-S3_raw/board/guest"
MCC="${SILICA_COMPILER:-$ROOT/compiler/build/apple_silicon_mac/silica-compiler}"
BCC="${BOARD_SILICA_COMPILER:-$ROOT/compiler/build/ESP32-S3_raw/silica-compiler}"
XT="${XTENSA_BIN:-$HOME/.espressif/tools/xtensa-esp-elf/esp-16.1.0_20260609/xtensa-esp-elf/bin}"
PY="${BOARD_PYTHON:-$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/python}"
CLANG=/usr/bin/clang
UUID="" TIMEOUT=120 BUILD_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --build-only) BUILD_ONLY=1; shift ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        -*) echo "run_accel_led: unknown argument $1" >&2; exit 2 ;;
        *) UUID=$1; shift ;;
    esac
done
WORK="$HERE/build/accel_led"
rm -rf "$WORK"; mkdir -p "$WORK/mac/dangerous_exposure_source/lib" "$WORK/board/src/dangerous_exposure_source/lib"

compile() {   # compile <compiler> <log>: the compiler's reclaim loop in the current directory
    local ec=0 i
    for i in $(seq 1 12); do "$1" > "$2" 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
    [ $ec -eq 0 ] || { echo "run_accel_led: compile failed; see $2"; grep -A8 "Compilation error" "$2" | head -14; }
    return $ec
}

# --- the Mac's program: the Bluetooth wrapper as a static archive, the stdlib modules by symlink
cd "$WORK/mac" || exit 1
cat > Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.silica.ble-demo</string>
<key>CFBundleName</key><string>silica-ble-demo</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>The Silica Bluetooth transport demo exchanges test frames with a nearby device.</string>
</dict></plist>
PLIST
ln -sfn "$ROOT/compiler/stdlib/ble" dangerous_exposure_source/ble
$CLANG -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=26.0 -Wall -c "$ROOT/compiler/stdlib/ble/silica_ble.m" -o silica_ble.o || exit 1
ar rcs dangerous_exposure_source/lib/libsilica_ble.a silica_ble.o
for m in Supervisor wire_etf wireframe Carrier carrier_support dangerous_ble dangerous_ble_gatt_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
sed "s|(:open, me, \"central:\")|(:open, me, \"central:$UUID\")|" "$HERE/dangerous_ble_mac_led.silica" > dangerous_ble_mac_led.silica
printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ncarrier_support.silica\ndangerous_ble.silica\ndangerous_ble_gatt_carrier.silica\ntrial_wait_int64.silica\ndangerous_ble_mac_led.silica\n' > silica.config
compile "$MCC" compile.log || exit 1
objs=""
for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
$CLANG $objs dangerous_exposure_source/lib/libsilica_ble.a -framework CoreBluetooth -framework Foundation -Wl,-sectcreate,__TEXT,__info_plist,Info.plist -o dangerous_ble_mac_led -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1

# --- the board's program: compiled in a copy; the NimBLE wrapper goes into the image as ESP-IDF code, so
# the archive the compiler wants holds only its symbols
cd "$WORK/board/src" || exit 1
ln -sfn "$ROOT/compiler/stdlib/ble" dangerous_exposure_source/ble
for m in Supervisor wire_etf wireframe Carrier carrier_support dangerous_nimble dangerous_ble_radio dangerous_ble_gatt_board_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
sed "s|(:open, me, \"peripheral:\")|(:open, me, \"peripheral:$UUID\")|" "$HERE/dangerous_ble_board_accel_led.silica" > dangerous_ble_board_accel_led.silica
printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ncarrier_support.silica\ndangerous_nimble.silica\ndangerous_ble_radio.silica\ndangerous_ble_gatt_board_carrier.silica\ndangerous_ble_board_accel_led.silica\n' > silica.config
sed -n 's/^ *symbol: "\(.*\)"$/long long \1(void) { return 0; }/p' "$ROOT/compiler/stdlib/ble/silica_ble_nimble_wrapper.meta" > stub.c
"$XT/xtensa-esp32s3-elf-gcc" -c -mlongcalls -Os -ffreestanding stub.c -o stub.o || exit 1
"$XT/xtensa-esp32s3-elf-ar" rcs dangerous_exposure_source/lib/libsilica_ble_nimble.a stub.o
compile "$BCC" ../compile.log || exit 1
BOARD_PYTHON="$PY" sh "$GUEST/tools/build_image.sh" -o "$WORK/board/image/accel_led" ./*.sams "$ROOT/compiler/stdlib/ble/silica_ble_nimble.c" || exit 1
[ "$BUILD_ONLY" = 1 ] && { echo "run_accel_led: built $WORK"; exit 0; }

# --- run: the board first; the Mac when it hears the board advertising (the flash resets the board, so
# what was on the air before is gone by then)
"$PY" "$GUEST/tools/run_on_board.py" --timeout "$TIMEOUT" "$WORK/board/image/accel_led.bin" > "$WORK/board.out" 2> "$WORK/board.err" &
BOARD=$!
sleep 12
heard=0
for i in $(seq 1 12); do
    kill -0 $BOARD 2>/dev/null || break
    if "$HERE/find_service.sh" "$UUID" 5 2>/dev/null | grep -q "advertisements from"; then heard=1; break; fi
done
if [ "$heard" = 1 ]; then
    cd "$WORK/mac" && ./dangerous_ble_mac_led > "$WORK/mac.out" 2>&1 &
    MAC=$!
    ( sleep "$TIMEOUT"; kill $MAC 2>/dev/null ) &
    WATCH=$!; disown
    wait $MAC 2>/dev/null; mrc=$?
    kill $WATCH 2>/dev/null
else
    echo "run_accel_led: the Mac did not hear the board advertising" > "$WORK/mac.out"; mrc=1
fi
wait $BOARD; brc=$?
echo "--- board (runner exit $brc)"; cat "$WORK/board.out"; [ "$brc" -eq 0 ] || head -c 1500 "$WORK/board.err"
echo "--- mac (exit $mrc)"; cat "$WORK/mac.out"
bstatus=$(tail -n 1 "$WORK/board.out" 2>/dev/null)
[ "$brc" -eq 0 ] && [ "$bstatus" = 0 ] && [ "$mrc" -eq 0 ]
