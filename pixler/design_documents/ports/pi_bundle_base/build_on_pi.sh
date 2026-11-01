#!/bin/sh
# On the Pi (64-bit Raspberry Pi OS, build-essential installed):
set -e
as -march=armv8.2-a+fp16 -o test.o test.sams
as -march=armv8.2-a+fp16 -o __silica_runtime.o __silica_runtime.sams
gcc -no-pie -o test test.o __silica_runtime.o -lpthread
./test; echo "exit=$? (expected 42; expected stdout is in test.scout)"
