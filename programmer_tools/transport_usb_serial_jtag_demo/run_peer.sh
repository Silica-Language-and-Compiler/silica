#!/bin/bash
# The Mac end of the USB-C demo (transport_esp32s3_wifi_plan.md §8, stages S-A / S-B). Builds
# dangerous_usb_serial_jtag_peer with the Silica compiler and runs it on the board's USB-Serial-JTAG port
# (found by USB id 303A:1001 unless --port names it); the board program
# silica_33_transport_usb_serial_jtag_etf (board/tools/run_app.sh) sends one ETF frame and reads the
# reply.
#
#   SILICA_COMPILER=<path> ./run_peer.sh [--port /dev/cu.usbmodemXXXX] [--timeout S]      Silica (:serial) peer
#   SILICA_COMPILER=<path> ./run_peer.sh --erlang [tcp_port] [--port ...]
#                        the Erlang peer of ../transport_beam_demo behind ../transport_uart1_demo/serial_to_tcp_bridge.py
#   SILICA_COMPILER=<path> ./run_peer.sh --build-only       build the Silica peer into build/ and stop
#   ./run_peer.sh --no-build [--port ...]                   run the peer built before (fast start)
#
# Order with the board: start the board program first and wait for run_app.sh's "running ... on the
# board" line (the RAM load resets the chip and the USB-Serial-JTAG node re-enumerates: a port opened
# before that goes stale), then start this peer; the board's frame waits in the controller's FIFO until
# the port is opened. The port is never opened with DTR/RTS set low (that resets the chip): the Silica
# carrier's termios open and pyserial's default open leave both high. Needs: the compiler, clang, ar;
# --erlang needs erl (OTP 26 or later) and a Python with pyserial (BOARD_PYTHON, default the ESP-IDF
# environment); the port lookup needs that Python too. The peer waits up to --timeout seconds (default
# 60) for the frame.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CC="${SILICA_COMPILER:-$ROOT/binaries/silica-compiler}"
PY="${BOARD_PYTHON:-$HOME/.espressif/python_env/idf6.1_py3.14_env/bin/python}"
[ -x "$PY" ] || PY="$HOME/.espressif/python_env/idf6.2_py3.14_env/bin/python"
[ -x "$PY" ] || PY=python3
BRIDGE="$ROOT/programmer_tools/transport_uart1_demo/serial_to_tcp_bridge.py"
PORT="" MODE=silica TCP_PORT=4041 TIMEOUT=60 BUILD=1 RUN=1
while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT=$2; shift 2 ;;
        --erlang) MODE=erlang; if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then TCP_PORT=$2; shift; fi; shift ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        --build-only) RUN=0; shift ;;
        --no-build) BUILD=0; shift ;;
        *) echo "run_peer: unknown argument $1" >&2; exit 2 ;;
    esac
done
WORK="$HERE/build"

build_peer() {
    rm -rf "$WORK"; mkdir -p "$WORK/dangerous_exposure_source/lib"
    cd "$WORK" || exit 1
    # the socket wrappers as a static archive, the stdlib modules by symlink, the program with a placeholder
    # port (patched per run below, so the build is reusable)
    ln -sfn "$ROOT/compiler/stdlib/net" dangerous_exposure_source/sockets
    clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$ROOT/compiler/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
    ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
    for m in Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_serial_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
    ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
    cp "$HERE/dangerous_usb_serial_jtag_peer.silica" dangerous_usb_serial_jtag_peer.silica
    printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_sockets.silica\ndangerous_serial_carrier.silica\ntrial_wait_int64.silica\ndangerous_usb_serial_jtag_peer.silica\n' > silica.config
    for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
    if [ ! -f dangerous_usb_serial_jtag_peer.sams ]; then echo "compile failed (exit $ec); see $WORK/compile.log"; grep -A8 "Compilation error" compile.log | head -12; exit 1; fi
    echo "run_peer: built the Silica peer in $WORK"
}

link_peer_for_port() {   # the port path is a string literal in the program: patch the assembly (the
    cd "$WORK" || exit 1    # .ascii text and the .quad length two lines above it) and relink
    python3 - "$1" dangerous_usb_serial_jtag_peer.sams dangerous_usb_serial_jtag_peer.port.sams <<'PY' || exit 1
import sys
port, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
old = "/dev/cu.usbmodem-PLACEHOLDER@115200"
new = port + "@115200"
lines = open(src).read().split("\n")
for i, line in enumerate(lines):
    if line.strip() == '.ascii "%s"' % old:
        lines[i] = '    .ascii "%s"' % new
        assert lines[i - 2].strip() == ".quad %d" % len(old), lines[i - 2]
        lines[i - 2] = "    .quad %d" % len(new)
        break
else:
    sys.exit("run_peer: placeholder not found in " + src)
open(dst, "w").write("\n".join(lines))
PY
    objs=""
    for s in *.sams; do
        case "$s" in dangerous_usb_serial_jtag_peer.sams) continue ;; esac
        clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"
    done
    clang $objs dangerous_exposure_source/lib/libsilica_sockets.a -o dangerous_usb_serial_jtag_peer -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
}

if [ "$BUILD" = 1 ] && [ "$MODE" = silica ]; then build_peer; fi
[ "$RUN" = 1 ] || exit 0

if [ -z "$PORT" ]; then
    PORT=$("$PY" "$HERE/find_usb_serial_jtag_port.py" --wait 5) || { echo "run_peer: no USB-Serial-JTAG port (303A:1001); plug the board's native USB-C jack in, or give --port" >&2; exit 2; }
fi
echo "run_peer: port $PORT"

if [ "$MODE" = erlang ]; then
    mkdir -p "$WORK"; cd "$WORK" || exit 1
    erlc -o "$WORK" "$ROOT/programmer_tools/transport_beam_demo/silica_peer.erl" || exit 1
    erl -noshell -pa "$WORK" -s silica_peer main "$TCP_PORT" > peer.out 2>&1 &
    PEER=$!; disown
    sleep 1
    "$PY" "$BRIDGE" --port "$PORT" --tcp-port "$TCP_PORT" --timeout "$TIMEOUT" --hex > bridge.out 2>&1
    rc=$?
    wait $PEER 2>/dev/null
    echo "--- bridge (exit $rc):"; cat bridge.out
    echo "--- erlang peer:"; cat peer.out
    exit $rc
fi

[ -f "$WORK/dangerous_usb_serial_jtag_peer.sams" ] || { echo "run_peer: no build in $WORK (run without --no-build first)" >&2; exit 1; }
link_peer_for_port "$PORT"
echo "run_peer: listening on $PORT for the board's frame (up to $TIMEOUT s)"
./dangerous_usb_serial_jtag_peer > silica.out 2>&1 &
PROG=$!
( sleep "$TIMEOUT"; kill $PROG 2>/dev/null ) &
WATCH=$!; disown
wait $PROG 2>/dev/null; rc=$?
kill $WATCH 2>/dev/null
echo "--- silica peer (exit $rc):"; cat silica.out
exit $rc
