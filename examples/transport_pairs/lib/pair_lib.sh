# Shared steps of the transport pair examples (sourced by each pair's run.sh; bash).
#
# A pair is a board program (a directory with its .silica source, expected.scout and extra_sources.txt, which
# board/tools/run_app.sh builds and runs from any path) and one or more Mac peers. The steps here:
#   pair_env                         the environment defaults (see below) and the tool paths
#   build_silica_peer SRC WORK       compile a hosted Silica peer (the (:serial) carrier) into WORK
#   link_silica_peer WORK NAME PORT  patch the carried_on placeholder port into its assembly and link it
#   find_usb_port                    the board's native USB-C port, by USB id 303A:1001
#   start_board DIR LOG TIMEOUT      run_app.sh in the background (BOARD_PID); waits for "running ... on the board"
#   run_silica_peer WORK NAME OUT TIMEOUT       the peer on the port; its output in OUT; returns its exit status
#   run_erlang_peer ERL WORK OUT BRIDGE_OUT TIMEOUT   erl behind serial_to_tcp_bridge.py --hex; returns the bridge's
#   compare_file GOT EXPECTED LABEL  diff after normalisation (the port name); prints MATCH / MISMATCH
#   bridge_bytes FILE DIRECTION      the hex of every chunk the bridge moved one way, joined
#
# Environment (defaults: the development Mac, see compiler/src/emitter/ESP32-S3_raw/board/README.md):
#   BOARD_PYTHON           ~/.espressif/python_env/idf6.1_py3.14_env/bin/python (esptool, pyserial)
#   ESPTOOL                the esptool next to BOARD_PYTHON
#   BOARD_PORT             the UART0 port, for the RAM load and the console (default /dev/cu.usbserial-8310)
#   BOARD_SILICA_COMPILER  the ESP32-S3_raw compiler (default compiler/build/ESP32-S3_raw/silica-compiler)
#   HOST_SILICA_COMPILER   the Apple Silicon compiler for Silica peers (default compiler/build/apple_silicon_mac/silica-compiler)
#   PEER_DELAY             seconds between "running ... on the board" and the peer's start (default 8: the RAM
#                          load follows that line and resets the chip, and the USB node re-enumerates)
#
# The native port is never flushed at open and DTR/RTS are never set low (that resets the chip): the Silica
# carrier's termios open and the bridge's open both leave them alone.

pair_env() {
    LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ROOT="$(cd "$LIB/../../.." && pwd)"
    export BOARD_PYTHON="${BOARD_PYTHON:-$HOME/.espressif/python_env/idf6.1_py3.14_env/bin/python}"
    export ESPTOOL="${ESPTOOL:-$(dirname "$BOARD_PYTHON")/esptool}"
    export BOARD_PORT="${BOARD_PORT:-/dev/cu.usbserial-8310}"
    BOARD_CC="${BOARD_SILICA_COMPILER:-$ROOT/compiler/build/ESP32-S3_raw/silica-compiler}"
    HOST_CC="${HOST_SILICA_COMPILER:-$ROOT/compiler/build/apple_silicon_mac/silica-compiler}"
    PEER_DELAY="${PEER_DELAY:-8}"
    RUN_APP="$ROOT/compiler/src/emitter/ESP32-S3_raw/board/tools/run_app.sh"
    BRIDGE="$ROOT/programmer_tools/transport_uart1_demo/serial_to_tcp_bridge.py"
    FIND_PORT="$LIB/find_usb_serial_jtag_port.py"
}

build_silica_peer() {   # SRC WORK: the socket wrappers as an archive, the stdlib by symlink, the peer with its
    local src=$1 work=$2 name ec=0   # placeholder port (patched per run by link_silica_peer, so the build is reusable)
    name=$(basename "$src" .silica)
    rm -rf "$work"; mkdir -p "$work/dangerous_exposure_source/lib"
    (
        cd "$work" || exit 1
        ln -sfn "$ROOT/compiler/stdlib/net" dangerous_exposure_source/sockets
        clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$ROOT/compiler/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
        ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
        for m in Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_serial_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
        ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
        cp "$src" "$name.silica"
        printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_sockets.silica\ndangerous_serial_carrier.silica\ntrial_wait_int64.silica\n%s.silica\n' "$name" > silica.config
        for i in $(seq 1 12); do "$HOST_CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
        if [ ! -f "$name.sams" ]; then echo "pair: peer compile failed (exit $ec); see $work/compile.log"; grep -A8 "Compilation error" compile.log | head -12; exit 1; fi
        for s in *.sams; do
            [ "$s" = "$name.sams" ] && continue
            clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1
        done
    ) || return 1
    echo "pair: built $name in $work"
}

link_silica_peer() {   # WORK NAME PORT: the port is the string literal of the carried_on declaration (the .ascii
    local work=$1 name=$2 port=$3 objs="" s   # text and the .quad length two lines above it)
    python3 - "$port" "$work/$name.sams" "$work/$name.port.sams" <<'PY' || return 1
import sys
port, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
old = "/dev/cu.usbmodem-PLACEHOLDER"
lines = open(src).read().split("\n")
for i, line in enumerate(lines):
    if line.strip() == '.ascii "%s"' % old:
        lines[i] = '    .ascii "%s"' % port
        assert lines[i - 2].strip() == ".quad %d" % len(old), lines[i - 2]
        lines[i - 2] = "    .quad %d" % len(port)
        break
else:
    sys.exit("pair: placeholder not found in " + src)
open(dst, "w").write("\n".join(lines))
PY
    ( cd "$work" || exit 1
      clang -mmacosx-version-min=26.0 -c -x assembler "$name.port.sams" -o "$name.port.o" || exit 1
      for s in *.sams; do [ "$s" = "$name.sams" ] || objs="$objs ${s%.sams}.o"; done
      clang $objs dangerous_exposure_source/lib/libsilica_sockets.a -o "$name" -Wl,-e,main -Wl,-macos_version_min,26.0 ) || return 1
}

find_usb_port() {
    "$BOARD_PYTHON" "$FIND_PORT" --wait 5
}

start_board() {   # DIR LOG TIMEOUT: returns 1 (and prints the log) when the program never reaches the board
    local dir=$1 log=$2 timeout=$3 waited=0 rc
    SILICA_COMPILER="$BOARD_CC" BOARD_SILICA_COMPILER="$BOARD_CC" "$RUN_APP" --timeout "$timeout" "$dir" > "$log" 2>&1 &
    BOARD_PID=$!
    until grep -q "running .* on the board" "$log" 2>/dev/null; do
        kill -0 $BOARD_PID 2>/dev/null || break
        sleep 1; waited=$((waited + 1))
        [ $waited -lt 300 ] || break
    done
    if ! grep -q "running .* on the board" "$log"; then
        wait $BOARD_PID 2>/dev/null; rc=$?
        echo "pair: the board program never reached \"running ... on the board\" (run_app exit $rc):"; cat "$log"
        return 1
    fi
    sleep "$PEER_DELAY"
}

wait_board() {   # the board run's exit status (0: its console matched expected.scout)
    wait $BOARD_PID 2>/dev/null
}

run_silica_peer() {   # WORK NAME OUT TIMEOUT
    local work=$1 name=$2 out=$3 timeout=$4 port prog watch rc
    port=$(find_usb_port) || { echo "pair: no USB-Serial-JTAG port (303A:1001)" > "$out"; return 2; }
    link_silica_peer "$work" "$name" "$port" || return 1
    "$work/$name" > "$out" 2>&1 &
    prog=$!
    ( sleep "$timeout"; kill $prog 2>/dev/null ) &
    watch=$!; disown
    wait $prog 2>/dev/null; rc=$?
    kill $watch 2>/dev/null
    return $rc
}

run_erlang_peer() {   # ERL WORK OUT BRIDGE_OUT TIMEOUT [TCP_PORT]
    local erl_src=$1 work=$2 out=$3 bout=$4 timeout=$5 tcp=${6:-4041} mod port peer rc
    mod=$(basename "$erl_src" .erl)
    port=$(find_usb_port) || { echo "pair: no USB-Serial-JTAG port (303A:1001)" > "$out"; return 2; }
    mkdir -p "$work"
    erlc -o "$work" "$erl_src" || return 1
    erl -noshell -pa "$work" -s "$mod" main "$tcp" > "$out" 2>&1 &
    peer=$!
    sleep 1
    "$BOARD_PYTHON" "$BRIDGE" --port "$port" --tcp-port "$tcp" --timeout "$timeout" --hex > "$bout" 2>&1
    rc=$?
    wait $peer 2>/dev/null
    return $rc
}

normalize() {   # the port name differs between runs and Macs
    sed -E 's#serial open /dev/[^@]*@#serial open <port>@#' "$1"
}

compare_file() {   # GOT EXPECTED LABEL
    if diff <(normalize "$1") <(normalize "$2") > "$1.diff" 2>&1; then
        echo "pair: MATCH: $3"; return 0
    fi
    echo "pair: MISMATCH: $3 (< got, > expected):"; cat "$1.diff"; return 1
}

bridge_bytes() {   # FILE "serial -> tcp" | "tcp -> serial"
    grep "^$2 " "$1" | sed -E 's/.*bytes: //' | tr -d '\n'; echo
}
