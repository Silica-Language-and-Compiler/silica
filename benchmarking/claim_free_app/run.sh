#!/bin/sh
# Loads build/image/claim_free.elf into the Nucleo's RAM over its ST-LINK (nothing is written to
# flash), runs it and prints its console output. Needs the board attached and nothing else using it.
# BOARD_PORT chooses the serial port, BOARD_PYTHON a Python with pyserial, BOARD_TIMEOUT the seconds
# to wait for the program to end.
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)
BOARD="$REPO/compiler/src/emitter/STM32-L476RG_raw/board"
PYTHON="${BOARD_PYTHON:-$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/python}"
[ -f build/image/claim_free.elf ] || ./build.sh || exit $?
"$PYTHON" "$BOARD/tools/run_on_board.py" --timeout "${BOARD_TIMEOUT:-120}" build/image/claim_free.elf
