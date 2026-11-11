#!/bin/bash
# Builds the Linux end ON the Linux x86-64 remote (run_direct.sh copies this script there and runs it).
#
#   build_linux.sh WORK NAME COMPILER
#
# The stdlib sources are in the directory holding this script: stdlib/*.silica (the modules a (:tcp) program
# needs, copied from the Mac checkout's compiler/stdlib and trials/lib_trial_support) and stdlib/net
# (silica_sockets.c and its wrapper metadata). COMPILER is the hosted Linux x86-64 compiler (by default
# ~/silica_demo/toolchain/silica-compiler, staged by ../ethernet_remote; it is only read). WORK/NAME.silica is
# compiled with those modules, assembled with cc and linked with the flags of trials/linux_host.mk (-no-pie: the
# emitted data tables hold absolute addresses; -rdynamic: the actor failure banner names behaviours with dladdr;
# -lpthread). silica_sockets.c needs -D_GNU_SOURCE under -std=c11 for cfmakeraw on glibc. Everything is written
# under WORK.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK=$1 NAME=$2 COMPILER=$3
cd "$WORK" || exit 1
rm -rf dangerous_exposure_source ./*.sams ./*.o ./*.iface silica.config silica.shapes silica.atoms silica.link
mkdir -p dangerous_exposure_source/lib
ln -sfn "$HERE/stdlib/net" dangerous_exposure_source/sockets
cc -std=c11 -D_GNU_SOURCE -O2 -c "$HERE/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
MODS="Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_tcp_carrier trial_wait_int64"
for m in $MODS; do ln -sf "$HERE/stdlib/$m.silica" "$m.silica"; done
{ for m in $MODS; do echo "$m.silica"; done; echo "$NAME.silica"; } > silica.config
ec=0
for i in $(seq 1 12); do nice -n 19 ionice -c3 "$COMPILER" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
if [ ! -f "$NAME.sams" ]; then
    echo "build_linux: compile failed (exit $ec); see $WORK/compile.log"
    grep -A10 "Compilation error\|crashed" compile.log | head -20
    exit 1
fi
objs=""
for s in *.sams; do cc -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
cc $objs dangerous_exposure_source/lib/libsilica_sockets.a -o "$NAME" -no-pie -rdynamic -lpthread || exit 1
echo "build_linux: built $WORK/$NAME"
