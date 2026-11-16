#!/usr/bin/env bash
# Runs the accelerometer tilt app on the attached ESP32-S3 board: forty readings, a quarter of a second
# apart, printed as "x=<n> y=<n> z=<n>" in counts of 1/1024 g. Turn the board while it runs and watch
# the large number move from axis to axis.
#
#   ./run_tilt.sh
#
# Every setting below can be overridden from the environment. The compiler must know the I2C0 window
# (board-pack window 13): until one is published in binaries/, the default is the scratch build made on
# 2026-11-16, and the published compiler is used when that build is gone.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BOARD_DIR="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$BOARD_DIR/../../../../.." && pwd)"

IDF_ENV="${IDF_ENV:-$HOME/.espressif/python_env/idf6.1_py3.14_env}"
export BOARD_PYTHON="${BOARD_PYTHON:-$IDF_ENV/bin/python}"
export ESPTOOL="${ESPTOOL:-$IDF_ENV/bin/esptool}"
export BOARD_PORT="${BOARD_PORT:-/dev/cu.usbserial-8310}"

SCRATCH_COMPILER="/private/tmp/claude-1331430978/-Users-yenrab-silica/f147c6ee-eff0-425d-92c1-4c4f5ced2624/scratchpad/xbuild/ESP32-S3_raw/silica-compiler"
if [ -z "${SILICA_COMPILER:-}" ]; then
    if [ -x "$SCRATCH_COMPILER" ]; then
        SILICA_COMPILER="$SCRATCH_COMPILER"
    else
        SILICA_COMPILER="$ROOT/binaries/silica-compiler-ESP32-S3_raw"
    fi
fi
export SILICA_COMPILER

[ -x "$BOARD_PYTHON" ] || { echo "run_tilt: no Python at $BOARD_PYTHON (set BOARD_PYTHON or IDF_ENV)"; exit 2; }
[ -e "$BOARD_PORT" ] || { echo "run_tilt: no board at $BOARD_PORT (set BOARD_PORT)"; exit 2; }
[ -x "$SILICA_COMPILER" ] || { echo "run_tilt: no compiler at $SILICA_COMPILER (set SILICA_COMPILER)"; exit 2; }

echo "run_tilt: compiler $SILICA_COMPILER"
echo "run_tilt: board    $BOARD_PORT"
exec "$BOARD_DIR/tools/run_app.sh" --timeout 60 silica_35_device_accelerometer_tilt
