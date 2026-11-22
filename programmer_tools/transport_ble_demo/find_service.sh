#!/bin/bash
# The Mac's check of the board's advertising (transport_ble_plan.md stage 6): builds find_service.m and
# scans for peripherals that advertise a service, printing every five seconds how many advertisements
# of each it heard.
#
#   ./find_service.sh [uuid] [seconds]
#
# uuid: the service's UUID, by default the Nordic UART Service; seconds: by default 30. Exits 0 when the
# service was heard in every five-second window. Needs Apple's clang; macOS may ask once to let the
# terminal use Bluetooth.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/build/find_service"
mkdir -p "$WORK" && cd "$WORK" || exit 1
cat > Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.silica.ble-demo</string>
<key>CFBundleName</key><string>silica-ble-demo</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>The Silica Bluetooth transport demo exchanges test frames with a nearby device.</string>
</dict></plist>
PLIST
/usr/bin/clang -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=26.0 -Wall "$HERE/find_service.m" -framework CoreBluetooth -framework Foundation \
    -Wl,-sectcreate,__TEXT,__info_plist,Info.plist -o find_service || exit 1
./find_service "${1:-}" "${2:-30}"
