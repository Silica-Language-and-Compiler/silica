#!/bin/bash
# An Erlang peer on the Mac and the Silica Linux end of ../ethernet_direct on the remote, over ONE direct TCP
# connection across the Internet (no ssh tunnel). The Mac's Erlang peer dials the remote's Silica listener at
# <remote-ip>:4550, and requests flow both ways over that connection. See README.md.
#
#   REMOTE=manager@aalang.org ./run.sh                    run once, compare
#   REMOTE=manager@aalang.org ./run.sh --runs 2           the run twice in a row
#   REMOTE=manager@aalang.org ./run.sh --timeout-check    no remote end: the Erlang peer must time out (exit 5)
#   ./run.sh --local                                      both ends on this Mac (listen:any:45560, dial 127.0.0.1)
#   ./run.sh --local --timeout-check                      the Erlang peer alone on this Mac, nothing to dial: exit 5
#   REMOTE=manager@aalang.org ./run.sh --rebuild-linux    rebuild the Linux end in this example's remote directory
#
# 1. Compile accel_side_peer.erl with erlc on the Mac (into build/).
# 2. The Linux end (the status side of ../ethernet_direct/dangerous_ethernet_direct_pair.silica, listening on
#    "listen:any:4550"). By default it is NOT compiled: the program ../ethernet_direct/run_direct.sh built on the
#    remote (~/silica_demo/ethernet_direct/build/dangerous_ethernet_direct_pair) is copied into
#    ~/silica_demo/ethernet_mac_erlang_remote_silica/build, after checking that the source it was built from is
#    the Linux copy run_direct.sh makes today (same sha256). --rebuild-linux instead stages the sources in this
#    example's remote directory and builds there with ../ethernet_direct/build_linux.sh, and only when no other
#    silica-compiler or make runs on the remote.
# 3. For each run: check the remote's 1-minute load (a run is skipped, and counts as failed, above 4); start the
#    Linux end under `timeout 90` and wait until it listens on 0.0.0.0:<port>; run the Erlang peer, which dials
#    <remote-ip>:<port>; wait for the Linux end to exit; compare both outputs with expected/ (sorted: the two
#    directions' lines interleave differently from run to run; uptime_ms becomes <n>).
# 4. Tear down (trap and after each run): kill the remote program, then check that the remote has no program and
#    no listener on <port> (only a positive ssh answer counts) and that the Mac has no program left.
#
# Passes (exit 0) when every run has both ends exit 0 and both outputs match. Needs: ssh key access (BatchMode),
# erl and erlc on the Mac; for --local also clang, ar and SILICA_COMPILER (default binaries/silica-compiler); for
# --rebuild-linux, cc and ar on the remote and LINUX_COMPILER there. The remote firewall must admit TCP <port>
# from this Mac's public address (a rule the remote's owner made; this script changes no firewall). Outside make
# integrate. The (:tcp) carrier is plain, unauthenticated TCP: the listener exists only during a run.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DIRECT="$HERE/../ethernet_direct"
REMOTE="${REMOTE:-manager@aalang.org}"
REMOTE_IP="${REMOTE_IP:-138.197.209.113}"
PORT=4550 MODE=pair RUNS=1 LOCAL_PORT=45560 TCHECK=0 REBUILD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout-check) TCHECK=1; shift ;;
        --local) MODE=local; shift ;;
        --runs) RUNS=$2; shift 2 ;;
        --port) PORT=$2; shift 2 ;;
        --rebuild-linux) REBUILD=1; shift ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "run: unknown argument $1" >&2; exit 2 ;;
    esac
done
CC="${SILICA_COMPILER:-$ROOT/binaries/silica-compiler}"
LINUX_COMPILER="${LINUX_COMPILER:-\$HOME/silica_demo/toolchain/silica-compiler}"
NAME=dangerous_ethernet_direct_pair
EX=ethernet_mac_erlang_remote_silica
PEER_HOST=mac-erlang                                    # the host a status reply from the Erlang peer carries
WORK="$HERE/build"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=10)
RDIR="\$HOME/silica_demo/$EX"
DIRECT_RDIR='$HOME/silica_demo/ethernet_direct'
RPROG_PAT="${EX%a}[a]/build/$NAME"   # the remote program and its timeout/bash wrappers, not the shell running pkill
MAC_PIDS=""
mkdir -p "$WORK"

rsh() { ssh "${SSH_OPTS[@]}" "$REMOTE" "$@"; }
remote_listener() { rsh "ss -ltn | grep -E ':$PORT +'"; }
remote_port_free() { [ "$(rsh "ss -ltn | grep -E ':$PORT +'; echo checked")" = checked ]; }

# The remote's 1-minute load must be at most 4 (another agent's low-priority build may share the host).
remote_load_ok() {
    local up load
    up=$(rsh uptime) || { echo "remote: ssh failed"; return 1; }
    echo "remote uptime: $up"
    load=$(rsh "cut -d' ' -f1 /proc/loadavg") || return 1
    awk -v l="$load" 'BEGIN { exit !(l <= 4) }' || { echo "remote: 1-minute load $load exceeds 4"; return 1; }
}

teardown_check() {
    if [ "$MODE" != local ]; then
        rsh "pkill -u \$(id -un) -f '$RPROG_PAT'" >/dev/null 2>&1
        sleep 1
        local left
        left=$(rsh "pgrep -u \$(id -un) -af '$RPROG_PAT'; ss -ltn | grep -E ':$PORT +'; echo checked")
        if [ "$left" = checked ]; then echo "remote: no program, no listener on $PORT"
        elif [ -z "$left" ]; then echo "remote: NOT CHECKED (ssh failed)"; return 1
        else echo "remote: LEFT OVER:"; echo "$left" | grep -v '^checked$'; return 1; fi
    fi
    local mleft
    mleft=$(pgrep -lf "accel_side_peer main|$EX/build/local/$NAME"; lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN 2>/dev/null)
    [ -z "$mleft" ] && echo "mac: no program left" || { echo "mac: LEFT OVER:"; echo "$mleft"; return 1; }
}

cleanup() {
    for p in $MAC_PIDS; do kill "$p" 2>/dev/null; done
    echo "== teardown check"
    teardown_check
}
trap cleanup EXIT

# The per-host copy of ../ethernet_direct's source, exactly as its run_direct.sh makes it (SIDE linux = the
# status side). SRC OUT SIDE LISTEN DIAL HOST
side_copy() {
    local args=(-e "s/^fn listen_address() -> string { \"[^\"]*\" }/fn listen_address() -> string { \"$4\" }/"
                -e "s/^fn dial_address() -> string { \"[^\"]*\" }/fn dial_address() -> string { \"$5\" }/"
                -e "s/^fn host_name() -> string { \"[^\"]*\" }/fn host_name() -> string { \"$6\" }/")
    if [ "$3" = linux ]; then
        args+=(-e 's/^\/\/ ==== BEGIN accel side ====$/{- ==== BEGIN accel side ====/'
               -e 's/^\/\/ ==== END accel side ====$/==== END accel side ==== -}/'
               -e 's/^{- ==== status side code ====$/\/\/ ==== status side code ====/'
               -e 's/^==== END status side ==== -}$/\/\/ ==== END status side ====/')
    fi
    sed "${args[@]}" "$1" > "$2"
}

normalize() { sed -E 's/uptime_ms=[0-9]+/uptime_ms=<n>/' "$1" | LC_ALL=C sort; }

build_mac_silica() {   # DIR SIDE LISTEN DIAL HOST: the Silica end on this Mac (only for --local)
    local D=$1
    rm -rf "$D"; mkdir -p "$D/dangerous_exposure_source/lib"
    (
        cd "$D" || exit 1
        ln -sfn "$ROOT/compiler/stdlib/net" dangerous_exposure_source/sockets
        clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$ROOT/compiler/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
        ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
        for m in Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_tcp_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
        ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
        side_copy "$DIRECT/$NAME.silica" "$NAME.silica" "$2" "$3" "$4" "$5"
        printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_sockets.silica\ndangerous_tcp_carrier.silica\ntrial_wait_int64.silica\n%s.silica\n' "$NAME" > silica.config
        ec=0
        for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
        [ -f "$NAME.sams" ] || { echo "Mac compile failed (exit $ec); see $D/compile.log"; grep -A10 "Compilation error" compile.log | head -14; exit 1; }
        objs=""; for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
        clang $objs dangerous_exposure_source/lib/libsilica_sockets.a -o "$NAME" -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
    ) || exit 1
    echo "built $D/$NAME"
}

run_with_watchdog() {   # OUT SECONDS CMD...: runs CMD, appends "exit <code>" to OUT
    local out=$1 secs=$2; shift 2
    "$@" > "$out" 2>&1 &
    local pid=$!
    MAC_PIDS="$MAC_PIDS $pid"
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) & local watch=$!; disown $watch 2>/dev/null
    wait "$pid" 2>/dev/null; local rc=$?
    kill "$watch" 2>/dev/null
    echo "exit $rc" >> "$out"
    return $rc
}

erlang_peer() {   # HOST PORT: the Erlang accel side (dials)
    erl -noshell -pa "$WORK" -s accel_side_peer main "$1" "$2" "$PEER_HOST"
}

compare_both() {   # MAC_OUT LINUX_OUT
    local ok=1
    echo "--- Mac end (Erlang, accel side, dials):"; cat "$1"
    echo "--- Linux end (Silica, status side, listens):"; cat "$2"
    if diff <(normalize "$1") <(normalize "$HERE/expected/mac_erlang_end.txt") > "$WORK/mac_end.diff"; then echo "MATCH: mac end (Erlang)"
    else echo "MISMATCH: mac end (< got, > expected, both sorted):"; cat "$WORK/mac_end.diff"; ok=0; fi
    if diff <(normalize "$2") <(normalize "$HERE/expected/linux_silica_end.txt") > "$WORK/linux_end.diff"; then echo "MATCH: linux end (Silica)"
    else echo "MISMATCH: linux end (< got, > expected, both sorted):"; cat "$WORK/linux_end.diff"; ok=0; fi
    [ $ok = 1 ]
}

timeout_verdict() {   # OUT RC
    echo "--- Erlang peer:"; cat "$1"
    grep -q "^timeout: pair not complete$" "$1" && [ "$2" -eq 5 ] \
        && { echo "MATCH: the Erlang peer timed out with exit 5"; return 0; } \
        || { echo "MISMATCH: expected the timeout line and exit 5"; return 1; }
}

echo "== 1. Erlang peer: erlc accel_side_peer.erl ($(erl -noshell -eval 'io:format("OTP ~s",[erlang:system_info(otp_release)]),halt().'))"
erlc -o "$WORK" "$HERE/accel_side_peer.erl" || exit 1

# ---- --local: both ends on this Mac ----
if [ "$MODE" = local ]; then
    busy=$(lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN 2>/dev/null)
    [ -z "$busy" ] || { echo "run: Mac port $LOCAL_PORT in use"; exit 1; }
    if [ $TCHECK = 1 ]; then
        echo "== local timeout check: nothing listens on 127.0.0.1:$LOCAL_PORT; the Erlang peer is refused until it times out"
        run_with_watchdog "$WORK/local_timeout.out" 70 erlang_peer 127.0.0.1 "$LOCAL_PORT"; rc=$?
        timeout_verdict "$WORK/local_timeout.out" $rc && echo "=== PASS" || { echo "=== FAIL"; exit 1; }
        exit 0
    fi
    echo "== local: the Silica status side listens on listen:any:$LOCAL_PORT, the Erlang peer dials 127.0.0.1:$LOCAL_PORT"
    build_mac_silica "$WORK/local/status" linux "listen:any:$LOCAL_PORT" "127.0.0.1:$LOCAL_PORT" linux-x86_64
    all=1
    for r in $(seq 1 "$RUNS"); do
        echo "== local run $r"
        run_with_watchdog "$WORK/local_linux_end.out" 80 "$WORK/local/status/$NAME" & SPID=$!
        for i in $(seq 1 40); do lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.25; done
        run_with_watchdog "$WORK/local_mac_end.out" 70 erlang_peer 127.0.0.1 "$LOCAL_PORT"
        wait $SPID
        compare_both "$WORK/local_mac_end.out" "$WORK/local_linux_end.out" || all=0
    done
    [ $all = 1 ] && echo "=== PASS" || echo "=== FAIL"
    [ $all = 1 ]; exit
fi

if [ $TCHECK = 1 ]; then
    echo "== timeout check: no remote end; the Erlang peer dials $REMOTE_IP:$PORT and is refused until it times out"
    remote_port_free || { echo "run: something listens on remote port $PORT (or ssh failed)"; exit 1; }
    run_with_watchdog "$WORK/mac_timeout.out" 70 erlang_peer "$REMOTE_IP" "$PORT"; rc=$?
    timeout_verdict "$WORK/mac_timeout.out" $rc && echo "=== PASS" || { echo "=== FAIL"; exit 1; }
    exit 0
fi

echo "== 2. Linux end (Silica, status side) on $REMOTE: listen:any:$PORT"
rsh 'echo "remote: $(hostname) ($(uname -sm))"' || { echo "run: ssh failed"; exit 1; }
remote_port_free || { echo "run: remote port $PORT in use (or ssh failed):"; remote_listener; exit 1; }
side_copy "$DIRECT/$NAME.silica" "$WORK/$NAME.linux.silica" linux "listen:any:$PORT" "$REMOTE_IP:$PORT" linux-x86_64
want=$(shasum -a 256 "$WORK/$NAME.linux.silica" | cut -c1-64)
rsh "mkdir -p $RDIR/build" || exit 1
if [ $REBUILD = 0 ]; then
    # Reuse ../ethernet_direct's Linux end: copy the program, after checking the source it was built from.
    have=$(rsh "test -x $DIRECT_RDIR/build/$NAME && sha256sum $DIRECT_RDIR/build/$NAME.silica | cut -c1-64 || echo missing")
    [ "$have" = missing ] && { echo "run: the ethernet_direct Linux end is missing on the remote ($DIRECT_RDIR/build/$NAME); rerun with --rebuild-linux when the remote is free"; exit 1; }
    [ "$have" = "$want" ] || { echo "run: the ethernet_direct Linux end was built from another source (sha256 $have, want $want); rerun with --rebuild-linux when the remote is free"; exit 1; }
    rsh "cp -p $DIRECT_RDIR/build/$NAME $DIRECT_RDIR/build/$NAME.silica $RDIR/build/ && echo \"reused $DIRECT_RDIR/build/$NAME (source sha256 ${want:0:16}, program sha256 \$(sha256sum $RDIR/build/$NAME | cut -c1-16))\"" || exit 1
else
    # Never compile while another build runs there.
    others=$(rsh "pgrep -af '[s]ilica-compiler|[m]ake( |\$)'; echo checked")
    [ "$others" = checked ] || { echo "run: the remote is busy (or ssh failed); not building:"; echo "$others" | grep -v '^checked$' | head -3; exit 1; }
    remote_load_ok || exit 1
    rsh "mkdir -p $RDIR/stdlib/net" || exit 1
    scp -q "${SSH_OPTS[@]}" "$DIRECT/build_linux.sh" "$REMOTE:silica_demo/$EX/" || exit 1
    scp -q "${SSH_OPTS[@]}" "$ROOT"/compiler/stdlib/{Supervisor,wire_etf,wireframe,Carrier,dangerous_sockets,dangerous_tcp_carrier}.silica \
        "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" "$REMOTE:silica_demo/$EX/stdlib/" || exit 1
    scp -q "${SSH_OPTS[@]}" "$ROOT"/compiler/stdlib/net/{silica_sockets.c,silica_sockets_wrapper.meta} "$REMOTE:silica_demo/$EX/stdlib/net/" || exit 1
    scp -q "${SSH_OPTS[@]}" "$WORK/$NAME.linux.silica" "$REMOTE:silica_demo/$EX/build/$NAME.silica" || exit 1
    rsh "chmod +x $RDIR/build_linux.sh && $RDIR/build_linux.sh $RDIR/build $NAME $LINUX_COMPILER" || exit 1
fi

all=1
for r in $(seq 1 "$RUNS"); do
    echo "== 3. run $r: remote load"
    remote_load_ok || { echo "SKIPPED: run $r (remote load)"; all=0; continue; }
    echo "== 3. run $r: start the Linux end (timeout 90), listening on 0.0.0.0:$PORT"
    rsh "cd $RDIR/build && rm -f peer.out && (setsid nohup bash -c 'timeout 90 $RDIR/build/$NAME > peer.out 2>&1; echo \"exit \$?\" >> peer.out' > /dev/null 2>&1 &)" || exit 1
    up=0
    for i in $(seq 1 20); do remote_listener >/dev/null && { up=1; break; }; sleep 0.5; done
    [ $up = 1 ] || { echo "run: the Linux end is not listening on $PORT"; rsh "cat $RDIR/build/peer.out"; exit 1; }
    echo "remote: $(remote_listener | awk '{print $4}') listening"
    echo "== 4. run $r: the Erlang peer dials $REMOTE_IP:$PORT"
    run_with_watchdog "$WORK/mac_end.out" 70 erlang_peer "$REMOTE_IP" "$PORT"
    for i in $(seq 1 30); do rsh "grep -q '^exit ' $RDIR/build/peer.out" && break; sleep 1; done
    rsh "cat $RDIR/build/peer.out" > "$WORK/linux_end.out"
    compare_both "$WORK/mac_end.out" "$WORK/linux_end.out" || all=0
    echo "== after run $r"; teardown_check || all=0
done
[ $all = 1 ] && echo "=== PASS" || echo "=== FAIL"
[ $all = 1 ]
