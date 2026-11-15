#!/bin/bash
# The accel/LED pair on the real board, once per Mac peer, checked against the expected output. See README.md.
#
#   run.sh [--silica | --erlang | --both] [--timeout S]   on the board (default --both: one board run per peer)
#   run.sh --fake                                         no board: both peers against fake_board_readings.py on
#                                                         a pty, their replies checked byte for byte
#   run.sh --build-only                                   build the Silica peer and the board image, run nothing
#
# A board run passes when run_app.sh says the board console MATCHes accel_led_board/expected.scout, the peer
# exits 0 and its output matches expected/<peer>_peer.out (the port name normalised); the Erlang run also checks
# the bytes the bridge moved, both ways, against expected/to_mac.hex and expected/to_board.hex. Exit 0 only when
# every run passed. Environment: see ../lib/pair_lib.sh.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/pair_lib.sh"
pair_env
PEERS="silica erlang" TIMEOUT=120 MODE=board
while [ $# -gt 0 ]; do
    case "$1" in
        --silica) PEERS=silica; shift ;;
        --erlang) PEERS=erlang; shift ;;
        --both) PEERS="silica erlang"; shift ;;
        --fake) MODE=fake; shift ;;
        --build-only) MODE=build; shift ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "run: unknown argument $1" >&2; exit 2 ;;
    esac
done
WORK="$HERE/build" BOARD_DIR="$HERE/accel_led_board" PEER=dangerous_accel_led_peer
mkdir -p "$WORK"
if [ "$MODE" != board ] || [ "$PEERS" != erlang ]; then
    build_silica_peer "$HERE/mac_peer/$PEER.silica" "$WORK/silica" || exit 1
fi

if [ "$MODE" = build ]; then
    SILICA_COMPILER="$BOARD_CC" "$RUN_APP" --build-only "$BOARD_DIR"; exit $?
fi

if [ "$MODE" = fake ]; then   # both peers against the pty board; the replies must be expected/to_board.hex
    fail=0
    for peer in silica erlang; do
        python3 "$HERE/fake_board_readings.py" --delay 3 > "$WORK/fake_$peer.out" 2>&1 &
        fake=$!
        sleep 0.5
        pty=$(awk '/^pty/{print $2}' "$WORK/fake_$peer.out")
        if [ "$peer" = silica ]; then
            link_silica_peer "$WORK/silica" "$PEER" "$pty" && "$WORK/silica/$PEER" > "$WORK/fake_peer_$peer.out" 2>&1
        else
            mkdir -p "$WORK/erlang"; erlc -o "$WORK/erlang" "$HERE/mac_peer/accel_led_peer.erl" || exit 1
            erl -noshell -pa "$WORK/erlang" -s accel_led_peer main 4041 > "$WORK/fake_peer_$peer.out" 2>&1 &
            sleep 1
            "$BOARD_PYTHON" "$BRIDGE" --port "$pty" --tcp-port 4041 --timeout 30 --hex > "$WORK/fake_bridge.out" 2>&1
            wait
        fi
        wait $fake 2>/dev/null
        got=$(grep '^reply' "$WORK/fake_$peer.out" | awk '{print $3}' | tr -d '\n')
        if [ "$got" = "$(tr -d '\n' < "$HERE/expected/to_board.hex")" ]; then echo "pair: MATCH: $peer peer replies (fake board)"
        else echo "pair: MISMATCH: $peer peer replies (fake board):"; cat "$WORK/fake_$peer.out"; fail=1; fi
    done
    exit $fail
fi

overall=0
for peer in $PEERS; do
    echo "=== $peer peer"
    start_board "$BOARD_DIR" "$WORK/board_$peer.log" "$TIMEOUT" || { overall=1; continue; }
    ok=1
    if [ "$peer" = silica ]; then
        run_silica_peer "$WORK/silica" "$PEER" "$WORK/peer_silica.out" 60; prc=$?
    else
        run_erlang_peer "$HERE/mac_peer/accel_led_peer.erl" "$WORK/erlang" "$WORK/peer_erlang.out" "$WORK/bridge.out" 60; prc=$?
    fi
    wait_board; brc=$?
    echo "--- board console (run_app exit $brc):"; grep -v '^run_app: \(compiling\|building\)\|^    ' "$WORK/board_$peer.log"
    echo "--- $peer peer (exit $prc):"; cat "$WORK/peer_$peer.out"
    [ $brc -eq 0 ] || ok=0
    [ $prc -eq 0 ] || ok=0
    compare_file "$WORK/peer_$peer.out" "$HERE/expected/${peer}_peer.out" "$peer peer output" || ok=0
    if [ "$peer" = erlang ]; then
        echo "--- bridge:"; cat "$WORK/bridge.out"
        [ "$(bridge_bytes "$WORK/bridge.out" "serial -> tcp")" = "$(tr -d '\n' < "$HERE/expected/to_mac.hex")" ] \
            && echo "pair: MATCH: bytes board -> Mac" || { echo "pair: MISMATCH: bytes board -> Mac"; ok=0; }
        [ "$(bridge_bytes "$WORK/bridge.out" "tcp -> serial")" = "$(tr -d '\n' < "$HERE/expected/to_board.hex")" ] \
            && echo "pair: MATCH: bytes Mac -> board" || { echo "pair: MISMATCH: bytes Mac -> board"; ok=0; }
    fi
    if [ $ok = 1 ]; then echo "=== $peer peer: PASS"; else echo "=== $peer peer: FAIL (run_app exit $brc, peer exit $prc)"; overall=1; fi
done
exit $overall
