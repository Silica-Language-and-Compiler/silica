#!/bin/bash
# Two sub-graphs, A and B, each with one hub and three spokes, joined by one hub-to-hub TCP connection: eight OS
# processes over (:tcp) on 127.0.0.1 on this Mac. See README.md.
#
#   ./run.sh            build the two hub and six spoke copies, run them, compare each output with expected/
#   ./run.sh --record   the same, then write the outputs to expected/ (check them by reading before you keep them)
#
# The compiler is HOST_SILICA_COMPILER (default binaries/silica-compiler of this checkout). The two hubs differ in one
# line (my_hub), the six spokes in one line (my_node), made with sed. Start order: hub B, hub A (it dials hub B), then
# the six spokes; each process is started only after the listener it needs accepts connections (a refused dial is not
# retried in this example). Each output is compared sorted, because the lines of one process interleave from run to
# run. Passes (exit 0) when all eight processes exit 0 and match. Needs clang and ar. Not part of make integrate.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CC="${HOST_SILICA_COMPILER:-$ROOT/binaries/silica-compiler}"
WORK="$HERE/build"
HUBM=dangerous_transit_two_hubs_hub
SPOKEM=dangerous_transit_two_hubs_spoke
RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

for port in 4620 4621; do
    if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then echo "FAIL: port $port is already in use"; exit 1; fi
done

build() {   # DIR MODULE SETTING (a sed script that sets the node)
    local D="$WORK/$1" NAME=$2
    rm -rf "$D"; mkdir -p "$D/dangerous_exposure_source/lib"
    (
        cd "$D" || exit 1
        ln -sfn "$ROOT/compiler/stdlib/net" dangerous_exposure_source/sockets
        clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$ROOT/compiler/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
        ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
        for m in Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_tcp_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
        ln -sf "$ROOT/examples/transit_common/transit_sup.silica" transit_sup.silica
        sed -e "$3" "$HERE/$NAME.silica" > "$NAME.silica"
        printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_sockets.silica\ndangerous_tcp_carrier.silica\ntransit_sup.silica\n%s.silica\n' "$NAME" > silica.config
        ec=0
        for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
        [ -f "$NAME.sams" ] || { echo "$1 compile failed (exit $ec); see $D/compile.log"; grep -A10 "Compilation error" compile.log | head -14; exit 1; }
        objs=""; for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
        clang $objs dangerous_exposure_source/lib/libsilica_sockets.a -o "$NAME" -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
    ) || exit 1
    echo "built $D/$NAME"
}

for h in 1 2; do
    build hub$h $HUBM "s/^fn my_hub() -> int64 { [0-9]* }/fn my_hub() -> int64 { $h }/" || { echo "FAIL: build"; exit 1; }
done
for n in 11 12 13 21 22 23; do
    build spoke$n $SPOKEM "s/^fn my_node() -> int64 { [0-9]* }/fn my_node() -> int64 { $n }/" || { echo "FAIL: build"; exit 1; }
done

start() {   # DIR MODULE OUT
    ( "$WORK/$1/$2" > "$WORK/$3.out" 2>&1; echo "exit $?" >> "$WORK/$3.out" ) &
    PIDS="$PIDS $!"
}
wait_listening() {   # PORT: up to 10 s
    for i in $(seq 1 100); do lsof -nP -iTCP:$1 -sTCP:LISTEN >/dev/null 2>&1 && return 0; sleep 0.1; done
    echo "FAIL: nothing listens on port $1"; return 1
}

echo "== running hub B, hub A and six spokes (60 s limit)"
start hub2 $HUBM hub2;  wait_listening 4621 || exit 1
start hub1 $HUBM hub1;  wait_listening 4620 || exit 1
sleep 0.5   # hub A's dial to hub B
for n in 11 12 13 21 22 23; do start spoke$n $SPOKEM spoke$n; sleep 0.2; done
( sleep 60; for p in $PIDS; do kill "$p" 2>/dev/null; done ) & WATCH=$!
for p in $PIDS; do wait "$p" 2>/dev/null; done
kill "$WATCH" 2>/dev/null
pkill -f "$WORK/(hub[12]|spoke[12][123])/dangerous_transit_two_hubs_" 2>/dev/null

ok=1
for who in hub1 hub2 spoke11 spoke12 spoke13 spoke21 spoke22 spoke23; do
    echo "--- $who:"; cat "$WORK/$who.out"
    if [ $RECORD = 1 ]; then LC_ALL=C sort "$WORK/$who.out" > "$HERE/expected/$who.txt"; fi
    if diff <(LC_ALL=C sort "$WORK/$who.out") <(LC_ALL=C sort "$HERE/expected/$who.txt") > "$WORK/$who.diff" 2>&1; then echo "MATCH: $who"
    else echo "MISMATCH: $who (< got, > expected, both sorted):"; cat "$WORK/$who.diff"; ok=0; fi
done
left=$(pgrep -lf "$WORK/(hub[12]|spoke[12][123])/dangerous_transit_two_hubs_"; lsof -nP -iTCP:4620-4621 -sTCP:LISTEN 2>/dev/null)
[ -z "$left" ] || { echo "LEFT OVER:"; echo "$left"; ok=0; }
[ $ok = 1 ] && { echo PASS; exit 0; } || { echo FAIL; exit 1; }
