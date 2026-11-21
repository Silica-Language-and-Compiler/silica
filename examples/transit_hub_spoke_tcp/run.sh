#!/bin/bash
# One hub and six spokes over (:tcp) on 127.0.0.1, seven OS processes on this Mac. See README.md.
#
#   ./run.sh            build the hub and six spoke copies, run them, compare each output with expected/
#   ./run.sh --record   the same, then write the outputs to expected/ (check them by reading before you keep them)
#
# The compiler is HOST_SILICA_COMPILER (default binaries/silica-compiler of this checkout). The six spokes differ in one
# line (my_node), made with sed. The hub starts first and the spokes only after the hub accepts connections (a refused dial is not retried). Each output is
# compared sorted, because the lines of one process interleave from run to run. Passes (exit 0) when all seven
# processes exit 0 and match. Needs clang and ar. Not part of make integrate.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CC="${HOST_SILICA_COMPILER:-$ROOT/binaries/silica-compiler}"
WORK="$HERE/build"
RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

if lsof -nP -iTCP:4610 -sTCP:LISTEN >/dev/null 2>&1; then echo "FAIL: port 4610 is already in use"; exit 1; fi

build() {   # DIR MODULE NODE (NODE empty for the hub)
    local D="$WORK/$1" NAME=$2
    rm -rf "$D"; mkdir -p "$D/dangerous_exposure_source/lib"
    (
        cd "$D" || exit 1
        ln -sfn "$ROOT/compiler/stdlib/net" dangerous_exposure_source/sockets
        clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$ROOT/compiler/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
        ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
        for m in Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_tcp_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
        ln -sf "$ROOT/examples/transit_common/transit_sup.silica" transit_sup.silica
        if [ -n "$3" ]; then sed -e "s/^fn my_node() -> int64 { [0-9]* }/fn my_node() -> int64 { $3 }/" "$HERE/$NAME.silica" > "$NAME.silica"
        else cp "$HERE/$NAME.silica" "$NAME.silica"; fi
        printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_sockets.silica\ndangerous_tcp_carrier.silica\ntransit_sup.silica\n%s.silica\n' "$NAME" > silica.config
        ec=0
        for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
        [ -f "$NAME.sams" ] || { echo "$1 compile failed (exit $ec); see $D/compile.log"; grep -A10 "Compilation error" compile.log | head -14; exit 1; }
        objs=""; for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
        clang $objs dangerous_exposure_source/lib/libsilica_sockets.a -o "$NAME" -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
    ) || exit 1
    echo "built $D/$NAME"
}

build hub dangerous_transit_hub "" || { echo "FAIL: build"; exit 1; }
for n in 1 2 3 4 5 6; do build spoke$n dangerous_transit_spoke $n || { echo "FAIL: build"; exit 1; }; done

echo "== running the hub and six spokes (60 s limit)"
( "$WORK/hub/dangerous_transit_hub" > "$WORK/hub.out" 2>&1; echo "exit $?" >> "$WORK/hub.out" ) &
PIDS="$PIDS $!"
for i in $(seq 1 100); do lsof -nP -iTCP:4610 -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.1; done
lsof -nP -iTCP:4610 -sTCP:LISTEN >/dev/null 2>&1 || { echo "FAIL: nothing listens on port 4610"; exit 1; }
for n in 1 2 3 4 5 6; do
    ( "$WORK/spoke$n/dangerous_transit_spoke" > "$WORK/spoke$n.out" 2>&1; echo "exit $?" >> "$WORK/spoke$n.out" ) &
    PIDS="$PIDS $!"
    sleep 0.2
done
( sleep 60; for p in $PIDS; do kill "$p" 2>/dev/null; done ) & WATCH=$!
for p in $PIDS; do wait "$p" 2>/dev/null; done
kill "$WATCH" 2>/dev/null
pkill -f "$WORK/(hub|spoke[1-6])/dangerous_transit_" 2>/dev/null

ok=1
for who in hub spoke1 spoke2 spoke3 spoke4 spoke5 spoke6; do
    echo "--- $who:"; cat "$WORK/$who.out"
    if [ $RECORD = 1 ]; then LC_ALL=C sort "$WORK/$who.out" > "$HERE/expected/$who.txt"; fi
    if diff <(LC_ALL=C sort "$WORK/$who.out") <(LC_ALL=C sort "$HERE/expected/$who.txt") > "$WORK/$who.diff" 2>&1; then echo "MATCH: $who"
    else echo "MISMATCH: $who (< got, > expected, both sorted):"; cat "$WORK/$who.diff"; ok=0; fi
done
left=$(pgrep -lf "$WORK/(hub|spoke[1-6])/dangerous_transit_"; lsof -nP -iTCP:4610 -sTCP:LISTEN 2>/dev/null)
[ -z "$left" ] || { echo "LEFT OVER:"; echo "$left"; ok=0; }
[ $ok = 1 ] && { echo PASS; exit 0; } || { echo FAIL; exit 1; }
