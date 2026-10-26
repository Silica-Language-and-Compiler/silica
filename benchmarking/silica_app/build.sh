#!/bin/sh
# Builds ./actor_msgs (macOS, Apple silicon). Override the compiler with SILICA_COMPILER.
set -e
cd "$(dirname "$0")"
COMPILER="${SILICA_COMPILER:-/Volumes/2T/silica/binaries/silica-compiler}"
B=build; rm -rf $B; mkdir $B
cp main.silica $B/; echo main.silica > $B/silica.config
cd $B
"$COMPILER"
for f in main __silica_runtime; do clang -c -x assembler $f.sams -o $f.o; done
clang main.o __silica_runtime.o -o ../actor_msgs -Wl,-e,main
