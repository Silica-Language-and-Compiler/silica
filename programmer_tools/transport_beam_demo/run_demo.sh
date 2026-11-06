#!/bin/bash
# Builds the demo program with the Silica compiler, starts the Erlang peer on a port, runs the program
# against it and shows both ends. Usage: SILICA_COMPILER=<path> ./run_demo.sh [port]
# Needs: the compiler, clang, ar, erl (OTP 26 or later) on PATH.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PORT="${1:-4040}"
CC="${SILICA_COMPILER:-$ROOT/compiler/build/apple_silicon_mac/silica-compiler}"
WORK="$HERE/build"
rm -rf "$WORK"; mkdir -p "$WORK/dangerous_exposure_source/lib"
cd "$WORK"
ln -sfn "$ROOT/compiler/stdlib/net" dangerous_exposure_source/sockets
clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$ROOT/compiler/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
for m in Supervisor wire_etf wireframe carrier dangerous_sockets dangerous_tcp_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
sed "s/127.0.0.1:4040/127.0.0.1:$PORT/" "$HERE/dangerous_telemetry.silica" > dangerous_telemetry.silica
printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\ncarrier.silica\ndangerous_sockets.silica\ndangerous_tcp_carrier.silica\ntrial_wait_int64.silica\ndangerous_telemetry.silica\n' > silica.config
for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
if [ ! -f dangerous_telemetry.sams ]; then echo "compile failed (exit $ec); see $WORK/compile.log"; grep -A8 "Compilation error" compile.log | head -12; exit 1; fi
objs=""
for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
clang $objs dangerous_exposure_source/lib/libsilica_sockets.a -o dangerous_telemetry -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
erlc -o "$WORK" "$HERE/silica_peer.erl" || exit 1
erl -noshell -pa "$WORK" -s silica_peer main "$PORT" > peer.out 2>&1 &
PEER=$!
sleep 1
./dangerous_telemetry > silica.out 2>&1 &
PROG=$!
( sleep 20; kill $PROG 2>/dev/null; kill $PEER 2>/dev/null ) &
WATCH=$!
wait $PROG 2>/dev/null; rc=$?
wait $PEER 2>/dev/null
kill $WATCH 2>/dev/null
echo "--- erlang peer:"; cat peer.out
echo "--- silica program (exit $rc):"; cat silica.out
