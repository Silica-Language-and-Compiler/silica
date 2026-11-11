#!/bin/bash
# The Silica pair (requests from both sides) on the real board, checked against the expected output. See README.md.
#
#   run.sh [--timeout S]     build the Mac peer, start the board program, start the peer once the board is running
#   run.sh --build-only      build the Mac peer and the board image, run nothing
#
# Passes when run_app.sh says the board console MATCHes silica_pair_board/expected.scout, the peer exits 0, and the
# peer's output has the lines that do not depend on timing (expected/peer_lines.txt, each found once, in any
# order: the peer prints events as they happen, and uptimes differ per run). Environment: see ../lib/pair_lib.sh.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/pair_lib.sh"
pair_env
TIMEOUT=120 MODE=board
while [ $# -gt 0 ]; do
    case "$1" in
        --build-only) MODE=build; shift ;;
        --timeout) TIMEOUT=$2; shift 2 ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "run: unknown argument $1" >&2; exit 2 ;;
    esac
done
WORK="$HERE/build" BOARD_DIR="$HERE/silica_pair_board" PEER=dangerous_usb_silica_pair_peer
mkdir -p "$WORK"
build_silica_peer "$HERE/mac_peer/$PEER.silica" "$WORK/silica" || exit 1
if [ "$MODE" = build ]; then
    SILICA_COMPILER="$BOARD_CC" "$RUN_APP" --build-only "$BOARD_DIR"; exit $?
fi

start_board "$BOARD_DIR" "$WORK/board.log" "$TIMEOUT" || exit 1
run_silica_peer "$WORK/silica" "$PEER" "$WORK/peer.out" 60; prc=$?
wait_board; brc=$?
echo "--- board console (run_app exit $brc):"; grep -v '^run_app: \(compiling\|building\)\|^    ' "$WORK/board.log"
echo "--- Mac peer (exit $prc):"; cat "$WORK/peer.out"
ok=1
[ $brc -eq 0 ] || ok=0
[ $prc -eq 0 ] || ok=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$(grep -cxF -- "$line" "$WORK/peer.out")
    [ "$n" = 1 ] || { echo "pair: MISMATCH: peer line \"$line\" found $n times"; ok=0; }
done < "$HERE/expected/peer_lines.txt"
[ $ok = 1 ] && echo "pair: MATCH: peer lines" && echo "=== PASS" && exit 0
echo "=== FAIL (run_app exit $brc, peer exit $prc)"; exit 1
