#!/bin/bash
# The Mac end of the Bluetooth demo (transport_ble_plan.md stage 3). Builds dangerous_ble_peer with the
# Silica compiler and runs it: the hosted (:ble_gatt) carrier on the Mac's adapter sends one 48-byte ETF
# frame in 20-byte segments and prints the reading of the frame the peer sends back.
#
#   SILICA_COMPILER=<path> ./run_peer.sh peripheral [uuid]   advertise the service, wait for a central
#   SILICA_COMPILER=<path> ./run_peer.sh central [uuid]      scan for the service, connect to it
#   SILICA_COMPILER=<path> ./run_peer.sh --build-only        compile and link, run nothing
#
# uuid is the service's UUID; without it the service is the Nordic UART Service, which phone test
# applications know. --timeout <seconds> (default 300) bounds the wait for the peer.
# SILICA_BLE_TRACE=1 prints the wrapper's CoreBluetooth events.
#
# With a phone as the central (nRF Connect): connect to "Silica", enable indications on the TX
# characteristic (6E400003): the program prints the three segments it sent and the phone shows them.
# Write the same three values, as byte arrays and in order, to the RX characteristic (6E400002): the
# program prints the reading and exits 0.
#
# Needs: the compiler, Apple's clang (/usr/bin/clang), ar. macOS may ask once to let the terminal use
# Bluetooth.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CC="${SILICA_COMPILER:-$ROOT/compiler/build/apple_silicon_mac/silica-compiler}"
CLANG=/usr/bin/clang
ROLE="" UUID="" TIMEOUT=300 BUILD_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        peripheral|central) ROLE=$1; if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then UUID=$2; shift; fi; shift ;;
        --build-only) BUILD_ONLY=1; shift ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        *) echo "run_peer: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$ROLE" ] || [ "$BUILD_ONLY" = 1 ] || { echo "run_peer: peripheral | central [uuid], or --build-only" >&2; exit 2; }
[ -n "$ROLE" ] || ROLE=peripheral
WORK="$HERE/build"
rm -rf "$WORK"; mkdir -p "$WORK/dangerous_exposure_source/lib"
cd "$WORK" || exit 1

# A usage description in the binary itself, in case macOS attributes the Bluetooth permission to it.
cat > Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.silica.ble-demo</string>
<key>CFBundleName</key><string>silica-ble-demo</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>The Silica Bluetooth transport demo exchanges test frames with a nearby device.</string>
</dict></plist>
PLIST

# the Bluetooth wrapper as a static archive, the stdlib modules by symlink, the program with the role in
# place of the placeholder address
ln -sfn "$ROOT/compiler/stdlib/ble" dangerous_exposure_source/ble
$CLANG -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=26.0 -Wall -c "$ROOT/compiler/stdlib/ble/silica_ble.m" -o silica_ble.o || exit 1
ar rcs dangerous_exposure_source/lib/libsilica_ble.a silica_ble.o
for m in Supervisor wire_etf wireframe Carrier dangerous_ble dangerous_ble_gatt_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
ln -sf "$ROOT/trials/lib_trial_support/trial_support_hex.silica" trial_support_hex.silica
sed "s|^fn address() -> string { \"peripheral:\" }|fn address() -> string { \"$ROLE:$UUID\" }|" "$HERE/dangerous_ble_peer.silica" > dangerous_ble_peer.silica
printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_ble.silica\ndangerous_ble_gatt_carrier.silica\ntrial_support_hex.silica\ntrial_wait_int64.silica\ndangerous_ble_peer.silica\n' > silica.config
for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
if [ ! -f dangerous_ble_peer.sams ]; then echo "compile failed (exit $ec); see $WORK/compile.log"; grep -A8 "Compilation error" compile.log | head -12; exit 1; fi
objs=""
for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
$CLANG $objs dangerous_exposure_source/lib/libsilica_ble.a -framework CoreBluetooth -framework Foundation -Wl,-sectcreate,__TEXT,__info_plist,Info.plist -o dangerous_ble_peer -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
[ "$BUILD_ONLY" = 1 ] && { echo "run_peer: built $WORK/dangerous_ble_peer"; exit 0; }
echo "run_peer: $ROLE, waiting up to $TIMEOUT s for the peer"
./dangerous_ble_peer &
PROG=$!
( sleep "$TIMEOUT"; kill $PROG 2>/dev/null ) &
WATCH=$!; disown
wait $PROG 2>/dev/null; rc=$?
kill $WATCH 2>/dev/null
echo "--- silica peer (exit $rc)"
exit $rc
