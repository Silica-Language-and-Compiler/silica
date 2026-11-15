#!/bin/bash
# Builds and runs dangerous_interface_link.silica with the loopback interface named for this host (lo0 on macOS,
# lo on Linux), and compares its output with expected.txt. Host-dependent, so outside `make integrate`.
# Usage: SILICA_COMPILER=<path> ./run.sh   (macOS build commands as in ../transport_beam_demo/run_demo.sh; on Linux
# set LINUX=1 to link with -lpthread and compile silica_sockets.c with -D_GNU_SOURCE.)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
case "$(uname -s)" in Darwin) IFNAME=lo0 ;; *) IFNAME=lo ;; esac
CC="${SILICA_COMPILER:-$ROOT/compiler/build/apple_silicon_mac/silica-compiler}"
WORK="$HERE/build"
rm -rf "$WORK"; mkdir -p "$WORK/dangerous_exposure_source/lib"
cd "$WORK"
ln -sfn "$ROOT/compiler/stdlib/net" dangerous_exposure_source/sockets
if [ "$(uname -s)" = Darwin ]; then
  clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$ROOT/compiler/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
else
  cc -std=c11 -D_GNU_SOURCE -O2 -c "$ROOT/compiler/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
fi
ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
for m in Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_tcp_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
sed "s/IFNAME/$IFNAME/" "$HERE/dangerous_interface_link.silica" > dangerous_interface_link.silica
printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_sockets.silica\ndangerous_tcp_carrier.silica\ntrial_wait_int64.silica\ndangerous_interface_link.silica\n' > silica.config
for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
if [ ! -f dangerous_interface_link.sams ]; then echo "compile failed (exit $ec); see $WORK/compile.log"; grep -A8 "Compilation error" compile.log | head -12; exit 1; fi
objs=""
if [ "$(uname -s)" = Darwin ]; then
  for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
  clang $objs dangerous_exposure_source/lib/libsilica_sockets.a -o dangerous_interface_link -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
else
  for s in *.sams; do cc -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
  cc -no-pie $objs dangerous_exposure_source/lib/libsilica_sockets.a -o dangerous_interface_link -lpthread || exit 1
fi
# stdin stays open (wait_for_exit reads it) until the program ends itself with cast_exit
(sleep 15) | perl -e 'alarm 20; exec @ARGV' ./dangerous_interface_link > run.out 2> run.err
rc=${PIPESTATUS[1]}
echo "exit $rc, interface $IFNAME"
if diff -Bw run.out "$HERE/expected.txt" > /dev/null; then echo "PASS"; else echo "FAIL"; diff -Bw run.out "$HERE/expected.txt"; exit 1; fi
