#!/bin/bash
# Builds a hosted Silica program ON the Linux x86-64 remote (run_mac_linux.sh copies this script there and runs it).
#
#   build_linux.sh WORK NAME
#
# The toolchain is the directory holding this script: silica-compiler (the hosted Linux x86-64 compiler from the
# Mac checkout's binaries/), stdlib/*.silica (the modules a (:tcp) program needs, copied from compiler/stdlib and
# trials/lib_trial_support) and stdlib/net (silica_sockets.c and its wrapper metadata). WORK/NAME.silica is
# compiled with those modules, assembled with cc and linked with the flags of trials/linux_host.mk (-no-pie: the
# emitted data tables hold absolute addresses; -rdynamic: the actor failure banner names behaviours with dladdr;
# -lpthread). silica_sockets.c needs -D_GNU_SOURCE under -std=c11 for cfmakeraw (as trials/ffi_addition/fixtures.mk).
# Everything is written under WORK; nothing outside it and this toolchain directory is touched.
set -u
TC="$(cd "$(dirname "$0")" && pwd)"
WORK=$1 NAME=$2
cd "$WORK" || exit 1
rm -rf dangerous_exposure_source ./*.sams ./*.o ./*.iface silica.config silica.shapes silica.atoms
mkdir -p dangerous_exposure_source/lib
ln -sfn "$TC/stdlib/net" dangerous_exposure_source/sockets
cc -std=c11 -D_GNU_SOURCE -O2 -c "$TC/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
for m in Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_tcp_carrier trial_wait_int64; do ln -sf "$TC/stdlib/$m.silica" "$m.silica"; done
printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_sockets.silica\ndangerous_tcp_carrier.silica\ntrial_wait_int64.silica\n%s.silica\n' "$NAME" > silica.config
ec=0
for i in $(seq 1 12); do "$TC/silica-compiler" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
if [ ! -f "$NAME.sams" ]; then
    echo "build_linux: compile failed (exit $ec); see $WORK/compile.log"
    grep -A10 "Compilation error\|crashed" compile.log | head -20
    exit 1
fi
objs=""
for s in *.sams; do cc -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
cc $objs dangerous_exposure_source/lib/libsilica_sockets.a -o "$NAME" -no-pie -rdynamic -lpthread || exit 1
echo "build_linux: built $WORK/$NAME"
