#!/bin/bash
# Stage 1 spike of transport_ble_plan.md. Builds the CoreBluetooth wrapper and either the plain C
# harness or the Silica program, and runs it.
# Usage: ./run_spike.sh [--c] scan | central | peripheral [seconds]
#   --c   run the C harness instead of the Silica program
# Needs: /usr/bin/clang (Apple's), ar, and for the Silica program the compiler
# (SILICA_COMPILER, default binaries/silica-compiler).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
USE_C=0
[ "${1:-}" = "--c" ] && { USE_C=1; shift; }
MODE="${1:-scan}"
SECONDS_TO_RUN="${2:-60}"
case "$MODE" in central) ROLE=0 ;; peripheral) ROLE=1 ;; scan) ROLE=2 ;; *) echo "mode: scan | central | peripheral" >&2; exit 2 ;; esac
CC="${SILICA_COMPILER:-$ROOT/binaries/silica-compiler}"
CLANG=/usr/bin/clang
WORK="$HERE/build"
rm -rf "$WORK"; mkdir -p "$WORK/dangerous_exposure_source/lib"
cd "$WORK" || exit 1

# A usage description in the binary itself, in case macOS attributes the Bluetooth permission to it.
cat > Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.silica.ble-spike</string>
<key>CFBundleName</key><string>silica-ble-spike</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>The Silica Bluetooth transport spike exchanges test frames with a nearby device.</string>
</dict></plist>
PLIST
LINK_BLE="dangerous_exposure_source/lib/libsilica_ble.a -framework CoreBluetooth -framework Foundation -Wl,-sectcreate,__TEXT,__info_plist,Info.plist"

$CLANG -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=26.0 -Wall -c "$HERE/silica_ble.m" -o silica_ble.o || exit 1
ar rcs dangerous_exposure_source/lib/libsilica_ble.a silica_ble.o

if [ "$USE_C" = 1 ]; then
    $CLANG -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$HERE/harness.c" -o harness.o || exit 1
    $CLANG harness.o $LINK_BLE -Wl,-e,_main -o harness || exit 1
    ./harness "$MODE" "$SECONDS_TO_RUN"
    exit $?
fi

mkdir -p dangerous_exposure_source/ble
ln -sf "$HERE/silica_ble_wrapper.meta" dangerous_exposure_source/ble/silica_ble_wrapper.meta
ln -sf "$ROOT/compiler/stdlib/Supervisor.silica" Supervisor.silica
ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
ln -sf "$HERE/dangerous_ble.silica" dangerous_ble.silica
sed "s/^fn role() -> int64 { 2 }/fn role() -> int64 { $ROLE }/" "$HERE/dangerous_ble_spike.silica" > dangerous_ble_spike.silica
printf 'Supervisor.silica\ndangerous_ble.silica\ntrial_wait_int64.silica\ndangerous_ble_spike.silica\n' > silica.config
for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
if [ ! -f dangerous_ble_spike.sams ]; then echo "compile failed (exit $ec); see $WORK/compile.log"; grep -A8 "Compilation error" compile.log | head -12; exit 1; fi
objs=""
for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
$CLANG $objs $LINK_BLE -o dangerous_ble_spike -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
./dangerous_ble_spike &
PROG=$!
( sleep "$SECONDS_TO_RUN"; kill $PROG 2>/dev/null ) &
WATCH=$!
wait $PROG 2>/dev/null; rc=$?
kill $WATCH 2>/dev/null
echo "--- silica program (exit $rc)"
exit $rc
