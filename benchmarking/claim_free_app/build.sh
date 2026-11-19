#!/bin/sh
# Builds build/image/claim_free.elf, a RAM image for the ST NUCLEO-L476RG (STM32-L476RG_raw).
# Touches no board. Override the compiler with SILICA_COMPILER (keep the file name
# silica-compiler-STM32-L476RG_raw: the name sets the emit target).
set -e
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)
COMPILER="${SILICA_COMPILER:-/Volumes/2T/silica/binaries/silica-compiler-STM32-L476RG_raw}"
BOARD="$REPO/compiler/src/emitter/STM32-L476RG_raw/board"
B=build; rm -rf $B; mkdir $B
cp main.silica $B/; echo main.silica > $B/silica.config
cd $B
# The compiler handles one unit per run and exits 75 or 76 when there is more to do.
while true; do
    ec=0; "$COMPILER" || ec=$?
    [ $ec -eq 0 ] && break
    [ $ec -eq 75 ] || [ $ec -eq 76 ] || { echo "compile failed (exit $ec)" >&2; exit $ec; }
done
sh "$BOARD/tools/build_image.sh" -o image/claim_free main.sams __silica_runtime.sams
