#!/bin/bash
# The Mac end of the UART1 demo (transport_esp32s3_wifi_plan.md stage 1). Builds dangerous_uart1_peer with
# the Silica compiler and runs it on a serial port; the board program silica_32_transport_uart1_etf
# (run it with board/tools/run_app.sh once this peer is listening) sends one ETF frame on UART1.
#
#   SILICA_COMPILER=<path> ./run_peer.sh --port /dev/cu.usbserial-XXXX     Silica (:serial) peer
#   SILICA_COMPILER=<path> ./run_peer.sh --port /dev/cu.usbserial-XXXX --erlang [tcp_port]
#                                   the Erlang peer of ../transport_beam_demo behind serial_to_tcp_bridge.py
#   SILICA_COMPILER=<path> ./run_peer.sh --fake-board          no hardware: fake_board.py plays the board on a pty
#
# --port is the USB-serial adapter wired to the board's UART1 header (adapter RX to GPIO35, GND to GND;
# 3.3 V levels), never the board's console port. Needs: the compiler, clang, ar; --erlang needs erl (OTP 26
# or later) and a Python with pyserial (BOARD_PYTHON, default the ESP-IDF environment); --fake-board needs
# python3 only. The peer waits up to --timeout seconds (default 60) for the frame.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CC="${SILICA_COMPILER:-$ROOT/compiler/build/apple_silicon_mac/silica-compiler}"
PY="${BOARD_PYTHON:-$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/python}"
[ -x "$PY" ] || PY=python3
PORT="" MODE=silica TCP_PORT=4041 TIMEOUT=60
while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT=$2; shift 2 ;;
        --erlang) MODE=erlang; if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then TCP_PORT=$2; shift; fi; shift ;;
        --fake-board) MODE=fake; shift ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        *) echo "run_peer: unknown argument $1" >&2; exit 2 ;;
    esac
done
WORK="$HERE/build"
rm -rf "$WORK"; mkdir -p "$WORK/dangerous_exposure_source/lib"
cd "$WORK" || exit 1

if [ "$MODE" = fake ]; then
    python3 "$HERE/fake_board.py" --delay 12 > fake.out 2>&1 &   # the peer is compiled and linked first; a frame written before the slave is opened would be echoed by the pty in cooked mode
    FAKE=$!; disown
    for i in $(seq 1 50); do PORT=$(sed -n 's/^pty //p' fake.out | head -1); [ -n "$PORT" ] && break; sleep 0.1; done
    [ -n "$PORT" ] || { echo "run_peer: fake_board.py gave no pty"; cat fake.out; exit 1; }
    echo "run_peer: fake board on $PORT"
fi
[ -n "$PORT" ] || { echo "run_peer: --port <serial device> is required (or --fake-board)" >&2; exit 2; }

if [ "$MODE" = erlang ]; then
    erlc -o "$WORK" "$ROOT/programmer_tools/transport_beam_demo/silica_peer.erl" || exit 1
    erl -noshell -pa "$WORK" -s silica_peer main "$TCP_PORT" > peer.out 2>&1 &
    PEER=$!; disown
    sleep 1
    "$PY" "$HERE/serial_to_tcp_bridge.py" --port "$PORT" --tcp-port "$TCP_PORT" --timeout "$TIMEOUT" > bridge.out 2>&1
    rc=$?
    wait $PEER 2>/dev/null
    echo "--- bridge (exit $rc):"; cat bridge.out
    echo "--- erlang peer:"; cat peer.out
    [ -n "${FAKE:-}" ] && { kill $FAKE 2>/dev/null; echo "--- fake board:"; cat fake.out; }
    exit $rc
fi

# the Silica peer: the socket wrappers as a static archive, the stdlib modules by symlink, the program with
# the port in place of the placeholder
ln -sfn "$ROOT/compiler/stdlib/net" dangerous_exposure_source/sockets
clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$ROOT/compiler/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
for m in Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_serial_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
sed "s|/dev/cu.usbserial-PLACEHOLDER|$PORT|" "$HERE/dangerous_uart1_peer.silica" > dangerous_uart1_peer.silica
printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_sockets.silica\ndangerous_serial_carrier.silica\ntrial_wait_int64.silica\ndangerous_uart1_peer.silica\n' > silica.config
for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
if [ ! -f dangerous_uart1_peer.sams ]; then echo "compile failed (exit $ec); see $WORK/compile.log"; grep -A8 "Compilation error" compile.log | head -12; exit 1; fi
objs=""
for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
clang $objs dangerous_exposure_source/lib/libsilica_sockets.a -o dangerous_uart1_peer -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
echo "run_peer: listening on $PORT for the board's frame (up to $TIMEOUT s)"
./dangerous_uart1_peer > silica.out 2>&1 &
PROG=$!
( sleep "$TIMEOUT"; kill $PROG 2>/dev/null ) &
WATCH=$!; disown
wait $PROG 2>/dev/null; rc=$?
kill $WATCH 2>/dev/null
echo "--- silica peer (exit $rc):"; cat silica.out
[ -n "${FAKE:-}" ] && { kill $FAKE 2>/dev/null; echo "--- fake board:"; cat fake.out; }
exit $rc
