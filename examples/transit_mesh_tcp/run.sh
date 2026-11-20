#!/bin/bash
# Five Silica nodes, one full mesh over (:tcp) on 127.0.0.1, five OS processes on this Mac. See README.md.
#
#   ./run.sh            build the five copies, run them, compare each node's output with expected/
#   ./run.sh --record   the same, then write the outputs to expected/ (check them by reading before you keep them)
#
# The compiler is HOST_SILICA_COMPILER (default binaries/silica-compiler of this checkout). The five copies differ in
# one line (my_node), made with sed. Nodes start in the order 5, 4, 3, 2, 1, each only after its listener accepts connections, so every listener is up before a
# node dials it (a refused dial is not retried). Each node's output is compared sorted, because the lines of one node
# interleave from run to run. Passes (exit 0) when all five nodes exit 0 and match. Needs clang and ar. Not part of make integrate.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CC="${HOST_SILICA_COMPILER:-$ROOT/binaries/silica-compiler}"
NAME=dangerous_transit_mesh_node
WORK="$HERE/build"
RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

for port in 4600 4601 4602 4603 4604; do
    if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then echo "FAIL: port $port is already in use"; exit 1; fi
done

build_node() {   # N
    local D="$WORK/node$1"
    rm -rf "$D"; mkdir -p "$D/dangerous_exposure_source/lib"
    (
        cd "$D" || exit 1
        ln -sfn "$ROOT/compiler/stdlib/net" dangerous_exposure_source/sockets
        clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$ROOT/compiler/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
        ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
        for m in Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_tcp_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
        ln -sf "$ROOT/examples/transit_common/transit_sup.silica" transit_sup.silica
        sed -e "s/^fn my_node() -> int64 { [0-9]* }/fn my_node() -> int64 { $1 }/" "$HERE/$NAME.silica" > "$NAME.silica"
        printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_sockets.silica\ndangerous_tcp_carrier.silica\ntransit_sup.silica\n%s.silica\n' "$NAME" > silica.config
        ec=0
        for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
        [ -f "$NAME.sams" ] || { echo "node $1 compile failed (exit $ec); see $D/compile.log"; grep -A10 "Compilation error" compile.log | head -14; exit 1; }
        objs=""; for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
        clang $objs dangerous_exposure_source/lib/libsilica_sockets.a -o "$NAME" -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
    ) || exit 1
    echo "built $D/$NAME"
}

for n in 1 2 3 4 5; do build_node $n || { echo "FAIL: build"; exit 1; }; done

echo "== running the five nodes (60 s limit)"
wait_listening() {   # PORT: up to 10 s
    for i in $(seq 1 100); do lsof -nP -iTCP:$1 -sTCP:LISTEN >/dev/null 2>&1 && return 0; sleep 0.1; done
    echo "FAIL: nothing listens on port $1"; return 1
}
for n in 5 4 3 2; do
    ( "$WORK/node$n/$NAME" > "$WORK/node$n.out" 2>&1; echo "exit $?" >> "$WORK/node$n.out" ) &
    PIDS="$PIDS $!"
    wait_listening $((4599 + n)) || exit 1
done
( "$WORK/node1/$NAME" > "$WORK/node1.out" 2>&1; echo "exit $?" >> "$WORK/node1.out" ) &
PIDS="$PIDS $!"
( sleep 60; for p in $PIDS; do kill "$p" 2>/dev/null; done ) & WATCH=$!
for p in $PIDS; do wait "$p" 2>/dev/null; done
kill "$WATCH" 2>/dev/null
pkill -f "$WORK/node[1-5]/$NAME" 2>/dev/null

ok=1
for n in 1 2 3 4 5; do
    echo "--- node $n:"; cat "$WORK/node$n.out"
    if [ $RECORD = 1 ]; then LC_ALL=C sort "$WORK/node$n.out" > "$HERE/expected/node$n.txt"; fi
    if diff <(LC_ALL=C sort "$WORK/node$n.out") <(LC_ALL=C sort "$HERE/expected/node$n.txt") > "$WORK/node$n.diff" 2>&1; then echo "MATCH: node $n"
    else echo "MISMATCH: node $n (< got, > expected, both sorted):"; cat "$WORK/node$n.diff"; ok=0; fi
done
left=$(pgrep -lf "$WORK/node[1-5]/$NAME"; lsof -nP -iTCP:4600-4604 -sTCP:LISTEN 2>/dev/null)
[ -z "$left" ] || { echo "LEFT OVER:"; echo "$left"; ok=0; }
[ $ok = 1 ] && { echo PASS; exit 0; } || { echo FAIL; exit 1; }
