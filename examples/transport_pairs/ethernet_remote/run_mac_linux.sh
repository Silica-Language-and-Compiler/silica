#!/bin/bash
# Silica on both ends, across the Internet: this Mac and a Linux x86-64 host, connections and requests from both
# sides at once. See README.md.
#
#   REMOTE=manager@aalang.org ./run_mac_linux.sh                  build both ends, run once, compare
#   REMOTE=manager@aalang.org ./run_mac_linux.sh --timeout-check  no Linux peer: the Mac end must time out (exit 5)
#
# 1. Build the Mac end (the accel side) from dangerous_ethernet_silica_pair.silica with SILICA_COMPILER
#    (default binaries/silica-compiler).
# 2. Stage the Linux toolchain under ~/silica_demo/toolchain on the remote (the Mac checkout's
#    binaries/silica-compiler-linux_x86_64, copied only when its checksum differs; the stdlib modules; silica_sockets.c;
#    build_linux.sh) and build the Linux end (the status side, the same source with the side blocks swapped by sed)
#    there, under ~/silica_demo/ethernet_pair.
# 3. Start the Linux end on the remote. It listens on 127.0.0.1:<remote-listen> only and dials 127.0.0.1:<remote-dial>.
# 4. Open one ssh connection carrying both forwards:
#      -L 127.0.0.1:<mac-dial>:127.0.0.1:<remote-listen>   the Mac's dialer reaches the remote listener
#      -R 127.0.0.1:<remote-dial>:127.0.0.1:<mac-listen>   the remote's dialer reaches the Mac listener
#    (both ends bind loopback only: no public port, no firewall change).
# 5. Run the Mac end (listener on 127.0.0.1:<mac-listen>, dialer to 127.0.0.1:<mac-dial>), wait for the Linux end
#    to finish, fetch its output, and compare both outputs with expected/ (sorted: the two connections' lines
#    interleave differently from run to run; uptime_ms is replaced by <n>).
# 6. Tear down (trap): the ssh connection and its forwards, the remote program, the local program. Then check
#    that no listener, forward or process is left on either side.
#
# Passes (exit 0) when both ends exit 0 and both outputs match. Needs: ssh key access (BatchMode, nothing is typed
# or printed), clang and ar on the Mac; cc, as, ld and ar on the remote (no installs, no sudo). Outside make
# integrate: it needs the network and the remote. Everything on the remote is under ~/silica_demo.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
REMOTE="${REMOTE:-manager@aalang.org}"
R_LISTEN=4550 R_DIAL=4561 M_LISTEN=4551 M_DIAL=4560 MODE=pair
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout-check) MODE=timeout; shift ;;
        --remote-listen) R_LISTEN=$2; shift 2 ;;
        --remote-dial) R_DIAL=$2; shift 2 ;;
        --mac-listen) M_LISTEN=$2; shift 2 ;;
        --mac-dial) M_DIAL=$2; shift 2 ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "run_mac_linux: unknown argument $1" >&2; exit 2 ;;
    esac
done
CC="${SILICA_COMPILER:-$ROOT/binaries/silica-compiler}"
LINUX_CC="${LINUX_SILICA_COMPILER:-$ROOT/binaries/silica-compiler-linux_x86_64}"
NAME=dangerous_ethernet_silica_pair
WORK="$HERE/build"; CTL="$WORK/ssh.ctl"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10)
RDIR='$HOME/silica_demo'
PROG_PAT="[.]/$NAME"   # matches the remote program and its timeout wrapper, not the shell running pkill
MAC_PID=""
mkdir -p "$WORK"; rm -f "$WORK/ssh.log"

rsh() { ssh "${SSH_OPTS[@]}" "$REMOTE" "$@"; }

cleanup() {
    [ -n "$MAC_PID" ] && kill "$MAC_PID" 2>/dev/null
    [ -S "$CTL" ] && ssh "${SSH_OPTS[@]}" -S "$CTL" -O exit "$REMOTE" >/dev/null 2>&1
    rsh "pkill -u \$(id -un) -f '$PROG_PAT'" >/dev/null 2>&1
    sleep 1
    echo "== teardown check"
    local left
    left=$(rsh "pgrep -u \$(id -un) -af '$PROG_PAT'; ss -ltn | grep -E '127.0.0.1:($R_LISTEN|$R_DIAL) '")
    [ -z "$left" ] && echo "remote: no program, no listener on $R_LISTEN or $R_DIAL" || { echo "remote: LEFT OVER:"; echo "$left"; }
    left=$(lsof -nP -iTCP:"$M_LISTEN" -iTCP:"$M_DIAL" -sTCP:LISTEN 2>/dev/null; pgrep -lf "build/mac/$NAME")
    [ -z "$left" ] && echo "mac: no program, no listener on $M_LISTEN or $M_DIAL" || { echo "mac: LEFT OVER:"; echo "$left"; }
}
trap cleanup EXIT

side_copy() {   # SRC OUT SIDE LISTEN DIAL HOST: the per-host copy (SIDE mac = the accel side, linux = the status side)
    local args=(-e "s/^fn listen_address() -> string { \"listen:[0-9]*\" }/fn listen_address() -> string { \"listen:$4\" }/"
                -e "s/^fn dial_address() -> string { \"127.0.0.1:[0-9]*\" }/fn dial_address() -> string { \"127.0.0.1:$5\" }/"
                -e "s/^fn host_name() -> string { \"[^\"]*\" }/fn host_name() -> string { \"$6\" }/")
    if [ "$3" = linux ]; then
        args+=(-e 's/^\/\/ ==== BEGIN accel side ====$/{- ==== BEGIN accel side ====/'
               -e 's/^\/\/ ==== END accel side ====$/==== END accel side ==== -}/'
               -e 's/^{- ==== status side code ====$/\/\/ ==== status side code ====/'
               -e 's/^==== END status side ==== -}$/\/\/ ==== END status side ====/')
    fi
    sed "${args[@]}" "$1" > "$2"
}

normalize() {   # sorted, uptimes replaced
    sed -E 's/uptime_ms=[0-9]+/uptime_ms=<n>/' "$1" | LC_ALL=C sort
}

echo "== 1. Mac end (accel side): listen 127.0.0.1:$M_LISTEN, dial 127.0.0.1:$M_DIAL"
M="$WORK/mac"; rm -rf "$M"; mkdir -p "$M/dangerous_exposure_source/lib"
(
    cd "$M" || exit 1
    ln -sfn "$ROOT/compiler/stdlib/net" dangerous_exposure_source/sockets
    clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$ROOT/compiler/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
    ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
    for m in Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_tcp_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
    ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
    side_copy "$HERE/$NAME.silica" "$NAME.silica" mac "$M_LISTEN" "$M_DIAL" mac-arm64
    printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_sockets.silica\ndangerous_tcp_carrier.silica\ntrial_wait_int64.silica\n%s.silica\n' "$NAME" > silica.config
    ec=0
    for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
    [ -f "$NAME.sams" ] || { echo "Mac compile failed (exit $ec); see $M/compile.log"; grep -A10 "Compilation error" compile.log | head -14; exit 1; }
    objs=""; for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
    clang $objs dangerous_exposure_source/lib/libsilica_sockets.a -o "$NAME" -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
) || exit 1
echo "built $M/$NAME"

echo "== 2. Linux end (status side) on $REMOTE: listen 127.0.0.1:$R_LISTEN, dial 127.0.0.1:$R_DIAL"
rsh 'echo "remote: $(hostname) ($(uname -sm))"' || { echo "run_mac_linux: ssh failed"; exit 1; }
busy=$(rsh "ss -ltn | grep -E '127.0.0.1:($R_LISTEN|$R_DIAL) '")
[ -z "$busy" ] || { echo "run_mac_linux: remote port in use:"; echo "$busy"; exit 1; }
busy=$(lsof -nP -iTCP:"$M_LISTEN" -iTCP:"$M_DIAL" -sTCP:LISTEN 2>/dev/null)
[ -z "$busy" ] || { echo "run_mac_linux: Mac port in use:"; echo "$busy"; exit 1; }
rsh "mkdir -p $RDIR/toolchain/stdlib/net $RDIR/ethernet_pair" || exit 1
want=$(shasum -a 256 "$LINUX_CC" | cut -d' ' -f1)
have=$(rsh "sha256sum $RDIR/toolchain/silica-compiler 2>/dev/null | cut -d' ' -f1")
if [ "$want" != "$have" ]; then
    echo "copying $(basename "$(readlink "$LINUX_CC" || echo "$LINUX_CC")") to the remote toolchain"
    scp -q "${SSH_OPTS[@]}" "$LINUX_CC" "$REMOTE:silica_demo/toolchain/silica-compiler" || exit 1
fi
scp -q "${SSH_OPTS[@]}" "$HERE/build_linux.sh" "$REMOTE:silica_demo/toolchain/" || exit 1
scp -q "${SSH_OPTS[@]}" "$ROOT"/compiler/stdlib/{Supervisor,wire_etf,wireframe,Carrier,dangerous_sockets,dangerous_tcp_carrier}.silica \
    "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" "$REMOTE:silica_demo/toolchain/stdlib/" || exit 1
scp -q "${SSH_OPTS[@]}" "$ROOT"/compiler/stdlib/net/{silica_sockets.c,silica_sockets_wrapper.meta} "$REMOTE:silica_demo/toolchain/stdlib/net/" || exit 1
side_copy "$HERE/$NAME.silica" "$WORK/$NAME.linux.silica" linux "$R_LISTEN" "$R_DIAL" linux-x86_64
scp -q "${SSH_OPTS[@]}" "$WORK/$NAME.linux.silica" "$REMOTE:silica_demo/ethernet_pair/$NAME.silica" || exit 1
rsh "chmod +x $RDIR/toolchain/build_linux.sh $RDIR/toolchain/silica-compiler && $RDIR/toolchain/build_linux.sh $RDIR/ethernet_pair $NAME" || exit 1

if [ "$MODE" = pair ]; then
    echo "== 3. start the Linux end (loopback only)"
    rsh "cd $RDIR/ethernet_pair && rm -f peer.out && (setsid nohup bash -c 'timeout 90 ./$NAME > peer.out 2>&1; echo \"exit \$?\" >> peer.out' > /dev/null 2>&1 &)" || exit 1
    up=0
    for i in $(seq 1 20); do
        rsh "ss -ltn | grep -q '127.0.0.1:$R_LISTEN '" && { up=1; break; }
        sleep 0.5
    done
    [ $up = 1 ] || { echo "run_mac_linux: the Linux end is not listening on 127.0.0.1:$R_LISTEN"; rsh "cat $RDIR/ethernet_pair/peer.out"; exit 1; }
    echo "remote listening on 127.0.0.1:$R_LISTEN"
else
    echo "== 3. (timeout check: the Linux end is not started)"
fi

echo "== 4. forwards: -L 127.0.0.1:$M_DIAL -> remote 127.0.0.1:$R_LISTEN, -R remote 127.0.0.1:$R_DIAL -> 127.0.0.1:$M_LISTEN"
ssh "${SSH_OPTS[@]}" -f -N -M -S "$CTL" -E "$WORK/ssh.log" -o ExitOnForwardFailure=yes \
    -L "127.0.0.1:$M_DIAL:127.0.0.1:$R_LISTEN" -R "127.0.0.1:$R_DIAL:127.0.0.1:$M_LISTEN" "$REMOTE" \
    || { echo "run_mac_linux: forward failed"; cat "$WORK/ssh.log"; exit 1; }

echo "== 5. run the Mac end"
"$M/$NAME" > "$WORK/mac_peer.out" 2>&1 &
MAC_PID=$!
( sleep 70; kill $MAC_PID 2>/dev/null ) & WATCH=$!; disown
wait $MAC_PID 2>/dev/null; mrc=$?; MAC_PID=""
kill $WATCH 2>/dev/null
echo "exit $mrc" >> "$WORK/mac_peer.out"

ok=1
if [ "$MODE" = pair ]; then
    for i in $(seq 1 30); do
        rsh "grep -q '^exit ' $RDIR/ethernet_pair/peer.out" && break
        sleep 1
    done
    rsh "cat $RDIR/ethernet_pair/peer.out" > "$WORK/linux_peer.out"
    echo "--- Mac end (accel side):"; cat "$WORK/mac_peer.out"
    echo "--- Linux end (status side):"; cat "$WORK/linux_peer.out"
    for side in mac linux; do
        if diff <(normalize "$WORK/${side}_peer.out") <(normalize "$HERE/expected/${side}_peer.txt") > "$WORK/${side}_peer.diff"; then
            echo "MATCH: $side end"
        else
            echo "MISMATCH: $side end (< got, > expected, both sorted):"; cat "$WORK/${side}_peer.diff"; ok=0
        fi
    done
else
    echo "--- Mac end:"; cat "$WORK/mac_peer.out"
    grep -q "^timeout: dialer done no listener done no$" "$WORK/mac_peer.out" && [ $mrc -eq 5 ] \
        && echo "MATCH: the Mac end timed out with exit 5" || { echo "MISMATCH: expected the timeout line and exit 5"; ok=0; }
fi
[ $ok = 1 ] && echo "=== PASS" || echo "=== FAIL"
[ $ok = 1 ]
