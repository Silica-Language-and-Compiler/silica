#!/bin/bash
# The Silica Mac end of ../ethernet_direct and an Erlang peer on the remote (OTP 27), over ONE direct TCP
# connection across the Internet (no ssh tunnel). The Mac's Silica end dials the remote's Erlang listener at
# <remote-ip>:4550, and requests flow both ways over that connection. See README.md.
#
#   REMOTE=manager@aalang.org ./run.sh                    build the Mac end, run once, compare
#   REMOTE=manager@aalang.org ./run.sh --runs 2           the run twice in a row
#   REMOTE=manager@aalang.org ./run.sh --timeout-check    no remote peer: the Silica Mac end must time out (exit 5)
#   ./run.sh --local                                      both ends on this Mac (Erlang listens on 127.0.0.1:45570)
#   ./run.sh --local --timeout-check                      the Erlang peer alone on this Mac, nobody dials: exit 5
#
# 1. Build the Mac end (the accel side of ../ethernet_direct/dangerous_ethernet_direct_pair.silica, made with the
#    same sed as ../ethernet_direct/run_direct.sh; it dials) with SILICA_COMPILER (default
#    binaries/silica-compiler).
# 2. Copy status_side_peer.erl to ~/silica_demo/ethernet_mac_silica_remote_erlang on the remote and compile it
#    there with erlc (OTP 27). No Silica compile runs on the remote.
# 3. For each run: check the remote's 1-minute load (a run is skipped, and counts as failed, above 4); start the
#    Erlang peer under `timeout 90`, listening on 0.0.0.0:<port>, and wait until `ss` shows it; run the Mac end,
#    which dials <remote-ip>:<port>; wait for the peer to exit; compare both outputs with expected/ (sorted: the
#    two directions' lines interleave differently from run to run; uptime_ms becomes <n>).
# 4. Tear down (trap and after each run): kill the remote erl, then check that the remote has no peer and no
#    listener on <port> (only a positive ssh answer counts) and that the Mac has no program left.
#
# Passes (exit 0) when every run has both ends exit 0 and both outputs match. Needs: ssh key access (BatchMode),
# clang and ar on the Mac, erl and erlc on the remote (and on the Mac for --local). The remote firewall must admit
# TCP <port> from this Mac's public address (a rule the remote's owner made; this script changes no firewall).
# Outside make integrate. The peer is plain, unauthenticated TCP: its listener exists only during a run.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DIRECT="$HERE/../ethernet_direct"
REMOTE="${REMOTE:-manager@aalang.org}"
REMOTE_IP="${REMOTE_IP:-138.197.209.113}"
PORT=4550 MODE=pair RUNS=1 LOCAL_PORT=45570 TCHECK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout-check) TCHECK=1; shift ;;
        --local) MODE=local; shift ;;
        --runs) RUNS=$2; shift 2 ;;
        --port) PORT=$2; shift 2 ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "run: unknown argument $1" >&2; exit 2 ;;
    esac
done
CC="${SILICA_COMPILER:-$ROOT/binaries/silica-compiler}"
# The carrier's declared link (not enforced; see the source's "NOT ENFORCED" note): the Mac end names the interface
# that carries this Mac's default route, the Linux end the remote's public interface, --local declares (:interface, "lo0").
MAC_IFACE="${MAC_IFACE:-$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')}"; MAC_IFACE="${MAC_IFACE:-en0}"
LINUX_IFACE="${LINUX_IFACE:-eth0}"
NAME=dangerous_ethernet_direct_pair
EX=ethernet_mac_silica_remote_erlang
WORK="$HERE/build"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=10)
RDIR="\$HOME/silica_demo/$EX"
RPROG_PAT='status_side_pee[r] main'   # the remote erl and its timeout/bash wrappers, not the shell running pkill
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
        if [ "$left" = checked ]; then echo "remote: no peer, no listener on $PORT"
        elif [ -z "$left" ]; then echo "remote: NOT CHECKED (ssh failed)"; return 1
        else echo "remote: LEFT OVER:"; echo "$left" | grep -v '^checked$'; return 1; fi
    fi
    local mleft
    mleft=$(pgrep -lf "status_side_peer main|$EX/build/(mac|local)/$NAME"; lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN 2>/dev/null)
    [ -z "$mleft" ] && echo "mac: no program left" || { echo "mac: LEFT OVER:"; echo "$mleft"; return 1; }
}

cleanup() {
    for p in $MAC_PIDS; do kill "$p" 2>/dev/null; done
    echo "== teardown check"
    teardown_check
}
trap cleanup EXIT

# The per-host copy of ../ethernet_direct's source, exactly as its run_direct.sh makes it (SIDE mac = the accel
# side, as the source is written). SRC OUT SIDE LISTEN DIAL HOST
side_copy() {   # SRC OUT SIDE LISTEN DIAL HOST LINK
    local args=(-e "s/^carried_on wire: (:tcp) .*;\$/carried_on wire: (:tcp) $7;/"
                -e "s/^fn listen_address() -> string { \"[^\"]*\" }/fn listen_address() -> string { \"$4\" }/"
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

build_mac_silica() {   # DIR SIDE LISTEN DIAL HOST LINK: the Silica end on this Mac
    local D=$1
    rm -rf "$D"; mkdir -p "$D/dangerous_exposure_source/lib"
    (
        cd "$D" || exit 1
        ln -sfn "$ROOT/compiler/stdlib/net" dangerous_exposure_source/sockets
        clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$ROOT/compiler/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
        ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
        for m in Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_tcp_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
        ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
        side_copy "$DIRECT/$NAME.silica" "$NAME.silica" "$2" "$3" "$4" "$5" "$6"
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

compare_both() {   # MAC_OUT LINUX_OUT
    local ok=1
    echo "--- Mac end (Silica, accel side, dials):"; cat "$1"
    echo "--- remote end (Erlang, status side, listens):"; cat "$2"
    if diff <(normalize "$1") <(normalize "$HERE/expected/mac_silica_end.txt") > "$WORK/mac_end.diff"; then echo "MATCH: mac end (Silica)"
    else echo "MISMATCH: mac end (< got, > expected, both sorted):"; cat "$WORK/mac_end.diff"; ok=0; fi
    if diff <(normalize "$2") <(normalize "$HERE/expected/linux_erlang_end.txt") > "$WORK/linux_end.diff"; then echo "MATCH: remote end (Erlang)"
    else echo "MISMATCH: remote end (< got, > expected, both sorted):"; cat "$WORK/linux_end.diff"; ok=0; fi
    [ $ok = 1 ]
}

timeout_verdict() {   # WHO OUT RC
    echo "--- $1:"; cat "$2"
    grep -q "^timeout: pair not complete$" "$2" && [ "$3" -eq 5 ] \
        && { echo "MATCH: the $1 timed out with exit 5"; return 0; } \
        || { echo "MISMATCH: expected the timeout line and exit 5"; return 1; }
}

# ---- --local: both ends on this Mac (the Erlang peer listens on 127.0.0.1 only, the Mac end dials it) ----
if [ "$MODE" = local ]; then
    busy=$(lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN 2>/dev/null)
    [ -z "$busy" ] || { echo "run: Mac port $LOCAL_PORT in use"; exit 1; }
    echo "== local: erlc status_side_peer.erl ($(erl -noshell -eval 'io:format("OTP ~s",[erlang:system_info(otp_release)]),halt().'))"
    erlc -o "$WORK" "$HERE/status_side_peer.erl" || exit 1
    if [ $TCHECK = 1 ]; then
        echo "== local timeout check: the Erlang peer listens on 127.0.0.1:$LOCAL_PORT and nobody dials it"
        run_with_watchdog "$WORK/local_timeout.out" 70 erl -noshell -pa "$WORK" -s status_side_peer main loopback "$LOCAL_PORT"; rc=$?
        timeout_verdict "Erlang peer" "$WORK/local_timeout.out" $rc && echo "=== PASS" || { echo "=== FAIL"; exit 1; }
        exit 0
    fi
    echo "== local: the Erlang peer listens on 127.0.0.1:$LOCAL_PORT, the Silica accel side dials it"
    build_mac_silica "$WORK/local/accel" mac "listen:$LOCAL_PORT" "127.0.0.1:$LOCAL_PORT" mac-arm64 '(:interface, "lo0")'
    all=1
    for r in $(seq 1 "$RUNS"); do
        echo "== local run $r"
        run_with_watchdog "$WORK/local_linux_end.out" 80 erl -noshell -pa "$WORK" -s status_side_peer main loopback "$LOCAL_PORT" & SPID=$!
        for i in $(seq 1 40); do lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.25; done
        run_with_watchdog "$WORK/local_mac_end.out" 70 "$WORK/local/accel/$NAME"
        wait $SPID
        compare_both "$WORK/local_mac_end.out" "$WORK/local_linux_end.out" || all=0
    done
    [ $all = 1 ] && echo "=== PASS" || echo "=== FAIL"
    [ $all = 1 ]; exit
fi

echo "== 1. Mac end (Silica, accel side): dials $REMOTE_IP:$PORT"
build_mac_silica "$WORK/mac" mac "listen:$PORT" "$REMOTE_IP:$PORT" mac-arm64 "(:interface, \"$MAC_IFACE\")"

if [ $TCHECK = 1 ]; then
    echo "== timeout check: no remote peer; the Mac end dials $REMOTE_IP:$PORT and is refused until it times out"
    remote_port_free || { echo "run: something listens on remote port $PORT (or ssh failed)"; exit 1; }
    run_with_watchdog "$WORK/mac_timeout.out" 70 "$WORK/mac/$NAME"; rc=$?
    timeout_verdict "Silica Mac end" "$WORK/mac_timeout.out" $rc && echo "=== PASS" || { echo "=== FAIL"; exit 1; }
    exit 0
fi

echo "== 2. Erlang peer on $REMOTE: erlc status_side_peer.erl"
rsh 'echo "remote: $(hostname) ($(uname -sm)), OTP $(erl -noshell -eval "io:format(\"~s\",[erlang:system_info(otp_release)]),halt().")"' || { echo "run: ssh or erl failed"; exit 1; }
remote_port_free || { echo "run: remote port $PORT in use (or ssh failed):"; remote_listener; exit 1; }
rsh "mkdir -p $RDIR" || exit 1
scp -q "${SSH_OPTS[@]}" "$HERE/status_side_peer.erl" "$REMOTE:silica_demo/$EX/" || exit 1
rsh "cd $RDIR && erlc status_side_peer.erl && echo compiled $RDIR/status_side_peer.beam" || exit 1

all=1
for r in $(seq 1 "$RUNS"); do
    echo "== 3. run $r: remote load"
    remote_load_ok || { echo "SKIPPED: run $r (remote load)"; all=0; continue; }
    echo "== 3. run $r: start the Erlang peer (timeout 90), listening on 0.0.0.0:$PORT"
    rsh "cd $RDIR && rm -f peer.out && (setsid nohup bash -c 'timeout 90 erl -noshell -pa $RDIR -s status_side_peer main any $PORT > peer.out 2>&1; echo \"exit \$?\" >> peer.out' > /dev/null 2>&1 &)" || exit 1
    up=0
    for i in $(seq 1 30); do remote_listener >/dev/null && { up=1; break; }; sleep 0.5; done
    [ $up = 1 ] || { echo "run: the Erlang peer is not listening on $PORT"; rsh "cat $RDIR/peer.out"; exit 1; }
    echo "remote: $(remote_listener | awk '{print $4}') listening"
    echo "== 4. run $r: the Mac end dials $REMOTE_IP:$PORT"
    run_with_watchdog "$WORK/mac_end.out" 70 "$WORK/mac/$NAME"
    for i in $(seq 1 30); do rsh "grep -q '^exit ' $RDIR/peer.out" && break; sleep 1; done
    rsh "cat $RDIR/peer.out" > "$WORK/linux_end.out"
    compare_both "$WORK/mac_end.out" "$WORK/linux_end.out" || all=0
    echo "== after run $r"; teardown_check || all=0
done
[ $all = 1 ] && echo "=== PASS" || echo "=== FAIL"
[ $all = 1 ]
