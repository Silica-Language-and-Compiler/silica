#!/bin/bash
# Silica on both ends of a direct UDP exchange across the Internet, no ssh tunnel: the Mac sends 15 datagrams (5
# numbered samples, three rounds) to the Linux x86-64 remote's UDP port <port>, and the remote counts the distinct
# numbers. UDP has no connection and no delivery guarantee, so the repetition (not an acknowledgement) is the loss
# tolerance. See README.md.
#
#   REMOTE=manager@aalang.org ./run_direct_udp.sh                  build both ends, run once, compare
#   REMOTE=manager@aalang.org ./run_direct_udp.sh --runs 2         ... the run (not the builds) twice in a row
#   ./run_direct_udp.sh --local                                    both ends on this Mac over lo0 (ports 45551/45552)
#
# 1. Build the Mac end (the sender) from dangerous_ethernet_direct_udp_pair.silica with SILICA_COMPILER (default
#    binaries/silica-compiler).
# 2. Wait until the remote is idle (no silica-compiler or make running there), then stage under
#    ~/silica_demo/ethernet_direct_udp on the remote the stdlib sources, silica_sockets.c and build_linux_udp.sh, and
#    build the Linux end (the receiver; the same source with sends() false) there with LINUX_COMPILER (default
#    ~/silica_demo/toolchain/silica-compiler, staged by ../ethernet_remote; only read).
# 3. For each run: start the Linux end under `timeout 90` and wait until it is bound to UDP <port>; run the Mac end;
#    wait for the Linux end to exit; compare both outputs with expected/ (sorted: the receiver prints a number when
#    it first arrives, so reordering changes the line order).
# 4. Tear down (trap and after each run): kill the remote program, then check that the remote has no program and
#    nothing bound to UDP <port> and that the Mac has no program left.
#
# Passes (exit 0) when every run has both ends exit 0 and both outputs match. Needs: ssh key access (BatchMode;
# nothing typed or printed), clang and ar on the Mac; cc and ar on the remote (no installs, no sudo); the remote
# firewall must admit UDP <port> from this Mac's public address (a rule the remote's owner makes; this script
# changes no firewall). Outside make integrate. UDP is unauthenticated: while the receiver runs, anything that can
# reach the port can send it datagrams. On a quiet LAN or Internet path the run is deterministic; a lost datagram is
# absorbed by the repeats, but a path that drops 2 copies of the same number (or the whole run) fails the run.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
REMOTE="${REMOTE:-manager@aalang.org}"
REMOTE_IP="${REMOTE_IP:-138.197.209.113}"
# The Linux end's peer is never used (it only receives), but the open string needs a dotted quad: this Mac's public address.
MAC_PUBLIC_IP="${MAC_PUBLIC_IP:-157.201.64.9}"
PORT=4551 MODE=pair RUNS=1 LOCAL_RECV_PORT=45551 LOCAL_SEND_PORT=45552
while [ $# -gt 0 ]; do
    case "$1" in
        --local) MODE=local; shift ;;
        --runs) RUNS=$2; shift 2 ;;
        --port) PORT=$2; shift 2 ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "run_direct_udp: unknown argument $1" >&2; exit 2 ;;
    esac
done
CC="${SILICA_COMPILER:-$ROOT/binaries/silica-compiler}"
# The carrier's declared link: the Mac end names the interface that carries this Mac's default route, the Linux end the
# remote's public interface, --local declares (:interface, "lo0"). Under a named link, local "<port>" binds that
# interface's first IPv4 address, so a wrong name fails at :open ((:link_down, :fault), then exit 1).
MAC_IFACE="${MAC_IFACE:-$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')}"; MAC_IFACE="${MAC_IFACE:-en0}"
LINUX_IFACE="${LINUX_IFACE:-eth0}"
LINUX_COMPILER="${LINUX_COMPILER:-\$HOME/silica_demo/toolchain/silica-compiler}"
NAME=dangerous_ethernet_direct_udp_pair
WORK="$HERE/build"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=10)
RDIR='$HOME/silica_demo/ethernet_direct_udp'
PROG_PAT="[.]/$NAME"   # the remote program and its timeout/bash wrappers, not the shell running pkill
MAC_PIDS=""
mkdir -p "$WORK"

rsh() { ssh "${SSH_OPTS[@]}" "$REMOTE" "$@"; }

remote_bound() { rsh "ss -lun | grep -E ':$PORT +'"; }
# UDP port $PORT free on the remote: true only when ssh answered and nothing is bound there.
remote_port_free() { [ "$(rsh "ss -lun | grep -E ':$PORT +'; echo checked")" = checked ]; }

teardown_check() {
    if [ "$MODE" != local ]; then
        rsh "pkill -u \$(id -un) -f '$PROG_PAT'" >/dev/null 2>&1
        sleep 1
        local left
        left=$(rsh "pgrep -u \$(id -un) -af '$PROG_PAT'; ss -lun | grep -E ':$PORT +'; echo checked")
        if [ "$left" = checked ]; then echo "remote: no program, nothing bound to UDP $PORT"
        elif [ -z "$left" ]; then echo "remote: NOT CHECKED (ssh failed)"; return 1
        else echo "remote: LEFT OVER:"; echo "$left" | grep -v '^checked$'; return 1; fi
    fi
    local mleft
    mleft=$(pgrep -lf "ethernet_direct_udp/build/(mac|local)/$NAME"; lsof -nP -iUDP:"$LOCAL_RECV_PORT" -iUDP:"$LOCAL_SEND_PORT" 2>/dev/null)
    [ -z "$mleft" ] && echo "mac: no program left" || { echo "mac: LEFT OVER:"; echo "$mleft"; return 1; }
}

cleanup() {
    for p in $MAC_PIDS; do kill "$p" 2>/dev/null; done
    echo "== teardown check"
    teardown_check
}
trap cleanup EXIT

side_copy() {   # SRC OUT SENDS OPEN HOST LINK: the per-host copy (SENDS true = the Mac's sender, false = the receiver)
    sed -e "s/^carried_on wire: (:udp) .*;\$/carried_on wire: (:udp) $6;/" \
        -e "s/^fn open_address() -> string { \"[^\"]*\" }/fn open_address() -> string { \"$4\" }/" \
        -e "s/^fn sends() -> boolean { [a-z]* }/fn sends() -> boolean { $3 }/" "$1" > "$2"
}

normalize() {   # sorted
    LC_ALL=C sort "$1"
}

build_mac() {   # DIR SENDS OPEN LINK
    local D=$1
    rm -rf "$D"; mkdir -p "$D/dangerous_exposure_source/lib"
    (
        cd "$D" || exit 1
        ln -sfn "$ROOT/compiler/stdlib/net" dangerous_exposure_source/sockets
        clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$ROOT/compiler/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
        ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
        for m in Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_udp_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
        ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
        side_copy "$HERE/$NAME.silica" "$NAME.silica" "$2" "$3" mac-arm64 "$4"
        printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_sockets.silica\ndangerous_udp_carrier.silica\ntrial_wait_int64.silica\n%s.silica\n' "$NAME" > silica.config
        ec=0
        for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
        [ -f "$NAME.sams" ] || { echo "Mac compile failed (exit $ec); see $D/compile.log"; grep -A10 "Compilation error" compile.log | head -14; exit 1; }
        objs=""; for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
        clang $objs dangerous_exposure_source/lib/libsilica_sockets.a -o "$NAME" -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
    ) || exit 1
    echo "built $D/$NAME"
}

run_with_watchdog() {   # EXE OUT SECONDS: runs EXE, appends "exit <code>" to OUT
    "$1" > "$2" 2>&1 &
    local pid=$!
    MAC_PIDS="$MAC_PIDS $pid"
    ( sleep "$3"; kill "$pid" 2>/dev/null ) & local watch=$!; disown $watch 2>/dev/null
    wait "$pid" 2>/dev/null; local rc=$?
    kill "$watch" 2>/dev/null
    echo "exit $rc" >> "$2"
    return $rc
}

compare_both() {   # MAC_OUT LINUX_OUT
    local ok=1
    echo "--- Mac end (sender):"; cat "$1"
    echo "--- Linux end (receiver):"; cat "$2"
    if diff <(normalize "$1") <(normalize "$HERE/expected/mac_end.txt") > "$WORK/mac_end.diff"; then echo "MATCH: mac end"
    else echo "MISMATCH: mac end (< got, > expected, both sorted):"; cat "$WORK/mac_end.diff"; ok=0; fi
    if diff <(normalize "$2") <(normalize "$HERE/expected/linux_end.txt") > "$WORK/linux_end.diff"; then echo "MATCH: linux end"
    else echo "MISMATCH: linux end (< got, > expected, both sorted):"; cat "$WORK/linux_end.diff"; ok=0; fi
    [ $ok = 1 ]
}

# ---- --local: both ends on this Mac over lo0 (each binds 127.0.0.1, the receiver on <recv port>, the sender on <send port>) ----
if [ "$MODE" = local ]; then
    echo "== local: the receiver is bound to 127.0.0.1:$LOCAL_RECV_PORT, the sender sends to it from 127.0.0.1:$LOCAL_SEND_PORT"
    busy=$(lsof -nP -iUDP:"$LOCAL_RECV_PORT" -iUDP:"$LOCAL_SEND_PORT" 2>/dev/null)
    [ -z "$busy" ] || { echo "run_direct_udp: Mac UDP port $LOCAL_RECV_PORT or $LOCAL_SEND_PORT in use"; exit 1; }
    build_mac "$WORK/local/send" true "127.0.0.1:$LOCAL_RECV_PORT@$LOCAL_SEND_PORT" '(:interface, "lo0")'
    build_mac "$WORK/local/recv" false "127.0.0.1:$LOCAL_SEND_PORT@$LOCAL_RECV_PORT" '(:interface, "lo0")'
    all=1
    for r in $(seq 1 "$RUNS"); do
        echo "== local run $r"
        run_with_watchdog "$WORK/local/recv/$NAME" "$WORK/local_linux_end.out" 80 & SPID=$!
        for i in $(seq 1 40); do lsof -nP -iUDP:"$LOCAL_RECV_PORT" >/dev/null 2>&1 && break; sleep 0.25; done
        run_with_watchdog "$WORK/local/send/$NAME" "$WORK/local_mac_end.out" 70
        wait $SPID
        compare_both "$WORK/local_mac_end.out" "$WORK/local_linux_end.out" || all=0
    done
    [ $all = 1 ] && echo "=== PASS" || echo "=== FAIL"
    [ $all = 1 ]; exit
fi

echo "== 1. Mac end (sender): sends to $REMOTE_IP:$PORT from the $MAC_IFACE address, port $PORT"
build_mac "$WORK/mac" true "$REMOTE_IP:$PORT@$PORT" "(:interface, \"$MAC_IFACE\")"

echo "== 2. Linux end (receiver) on $REMOTE: bound to UDP $PORT on $LINUX_IFACE"
rsh 'echo "remote: $(hostname) ($(uname -sm))"' || { echo "run_direct_udp: ssh failed"; exit 1; }
remote_port_free || { echo "run_direct_udp: remote UDP port $PORT in use (or ssh failed):"; remote_bound; exit 1; }
# Never compile while another build runs there (two CPUs, 3.9 GB, no swap).
for i in $(seq 1 180); do
    others=$(rsh "pgrep -af '[s]ilica-compiler|[m]ake( |\$)'; echo checked")
    [ "$others" = checked ] && { others=""; break; }
    [ -z "$others" ] && others="(ssh failed: the remote did not answer)"
    [ $i = 1 ] && { echo "remote busy, waiting: $(rsh uptime)"; echo "$others" | head -3; }
    sleep 20
done
[ -z "$others" ] || { echo "run_direct_udp: the remote stayed busy for an hour"; exit 1; }
echo "remote idle: $(rsh uptime)"
rsh "mkdir -p $RDIR/stdlib/net $RDIR/build && sha256sum $LINUX_COMPILER | cut -c1-16 | sed 's/^/linux compiler sha256: /'" || exit 1
scp -q "${SSH_OPTS[@]}" "$HERE/build_linux_udp.sh" "$REMOTE:silica_demo/ethernet_direct_udp/" || exit 1
scp -q "${SSH_OPTS[@]}" "$ROOT"/compiler/stdlib/{Supervisor,wire_etf,wireframe,Carrier,dangerous_sockets,dangerous_udp_carrier}.silica \
    "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" "$REMOTE:silica_demo/ethernet_direct_udp/stdlib/" || exit 1
scp -q "${SSH_OPTS[@]}" "$ROOT"/compiler/stdlib/net/{silica_sockets.c,silica_sockets_wrapper.meta} "$REMOTE:silica_demo/ethernet_direct_udp/stdlib/net/" || exit 1
side_copy "$HERE/$NAME.silica" "$WORK/$NAME.linux.silica" false "$MAC_PUBLIC_IP:$PORT@$PORT" linux-x86_64 "(:interface, \"$LINUX_IFACE\")"
scp -q "${SSH_OPTS[@]}" "$WORK/$NAME.linux.silica" "$REMOTE:silica_demo/ethernet_direct_udp/build/$NAME.silica" || exit 1
rsh "chmod +x $RDIR/build_linux_udp.sh && $RDIR/build_linux_udp.sh $RDIR/build $NAME $LINUX_COMPILER" || exit 1

all=1
for r in $(seq 1 "$RUNS"); do
    echo "== 3. run $r: start the Linux end (timeout 90), bound to UDP $PORT"
    rsh "cd $RDIR/build && rm -f peer.out && (setsid nohup bash -c 'timeout 90 ./$NAME > peer.out 2>&1; echo \"exit \$?\" >> peer.out' > /dev/null 2>&1 &)" || exit 1
    up=0
    for i in $(seq 1 20); do remote_bound >/dev/null && { up=1; break; }; sleep 0.5; done
    [ $up = 1 ] || { echo "run_direct_udp: the Linux end is not bound to UDP $PORT"; rsh "cat $RDIR/build/peer.out"; exit 1; }
    echo "remote: $(remote_bound | awk '{print $5}') bound"
    echo "== 4. run $r: the Mac end sends to $REMOTE_IP:$PORT"
    run_with_watchdog "$WORK/mac/$NAME" "$WORK/mac_end.out" 70
    for i in $(seq 1 30); do rsh "grep -q '^exit ' $RDIR/build/peer.out" && break; sleep 1; done
    rsh "cat $RDIR/build/peer.out" > "$WORK/linux_end.out"
    compare_both "$WORK/mac_end.out" "$WORK/linux_end.out" || all=0
    echo "== after run $r"; teardown_check || all=0
done
[ $all = 1 ] && echo "=== PASS" || echo "=== FAIL"
[ $all = 1 ]
