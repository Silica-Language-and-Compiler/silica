#!/bin/bash
# Silica on both ends of ONE direct connection across the Internet under MUTUAL TLS 1.3: the Mac dials the Linux
# x86-64 remote's Silica listener at <remote-ip>:4550, both ends present a certificate, each accepts only the
# peer whose certificate it has been given, and requests flow both ways over that connection. See README.md.
#
#   REMOTE=manager@aalang.org ./run_mtls.sh                  build both ends, run once, compare
#   REMOTE=manager@aalang.org ./run_mtls.sh --runs 2         ... the run (not the builds) twice in a row
#   REMOTE=manager@aalang.org ./run_mtls.sh --timeout-check  no Linux end: the Mac end must time out (exit 5)
#   ./run_mtls.sh --local                                    both ends on this Mac (listen:any, dial 127.0.0.1)
#
# BEFORE the first run, by hand and not by this script (README.md, "Certificates"): each node makes its
# certificate once with make_cert.sh, and each node is given the other's certificate in ~/.silica_mtls/peers/.
# This script creates, copies and reads NO key and NO certificate. It only checks that the files are in place
# (step 0) and stops with the list of what is missing. --local runs both ends as this Mac's one identity, so
# this Mac's own certificate must be among its accepted peers.
#
# 1. Build the Mac end (the accel side, it dials) from dangerous_ethernet_mtls_pair.silica with SILICA_COMPILER
#    (default binaries/silica-compiler), the TLS wrappers of net/silica_tls.c and Homebrew's OpenSSL 3
#    (OPENSSL_PREFIX overrides its location).
# 2. Wait until the remote is idle (no silica-compiler or make running there: another build may share its two
#    CPUs and 3.9 GB), then stage under ~/silica_demo/ethernet_direct_mtls on the remote the sources and
#    build_linux.sh, and build the Linux end (the status side, it listens on "listen:any:<port>"; the same source
#    with the side blocks swapped by sed) there with LINUX_COMPILER (default
#    ~/silica_demo/toolchain/silica-compiler, staged by ../ethernet_remote; only read) and the remote's OpenSSL 3
#    (libssl-dev).
# 3. For each run: start the Linux end under `timeout 90` and wait until it listens on 0.0.0.0:<port>; run the
#    Mac end, which dials <remote-ip>:<port> directly; wait for the Linux end to exit; compare both outputs with
#    expected/ (sorted: the two directions' lines interleave differently from run to run; uptime_ms becomes <n>).
#    The expected outputs are those of ../ethernet_direct: the program says the same things over TLS.
# 4. Tear down (trap and after each run): kill the remote program, then check that the remote has no program and
#    no listener on <port> and that the Mac has no program left.
#
# Passes (exit 0) when every run has both ends exit 0 and both outputs match. Needs: ssh key access (BatchMode;
# nothing typed or printed), clang, ar and OpenSSL 3 on the Mac; cc, ar and libssl-dev on the remote (this script
# installs nothing and uses no sudo); the remote firewall must admit TCP <port> from this Mac's public address (a
# rule the remote's owner made; this script changes no firewall). Outside make integrate.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
REMOTE="${REMOTE:-manager@aalang.org}"
REMOTE_IP="${REMOTE_IP:-138.197.209.113}"
PORT=4550 MODE=pair RUNS=1 LOCAL_PORT=45550
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout-check) MODE=timeout; shift ;;
        --local) MODE=local; shift ;;
        --runs) RUNS=$2; shift 2 ;;
        --port) PORT=$2; shift 2 ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "run_mtls: unknown argument $1" >&2; exit 2 ;;
    esac
done
CC="${SILICA_COMPILER:-$ROOT/binaries/silica-compiler}"
OPENSSL_PREFIX="${OPENSSL_PREFIX:-$(brew --prefix openssl@3 2>/dev/null)}"
MTLS_DIR="${SILICA_MTLS_DIR:-$HOME/.silica_mtls}"
LINUX_COMPILER="${LINUX_COMPILER:-\$HOME/silica_demo/toolchain/silica-compiler}"
NAME=dangerous_ethernet_mtls_pair
WORK="$HERE/build"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=10)
RDIR='$HOME/silica_demo/ethernet_direct_mtls'
PROG_PAT="[.]/$NAME"   # the remote program and its timeout/bash wrappers, not the shell running pkill
MAC_PIDS=""
mkdir -p "$WORK"

rsh() { ssh "${SSH_OPTS[@]}" "$REMOTE" "$@"; }

remote_listener() { rsh "ss -ltn | grep -E ':$PORT +'"; }
# Port $PORT free on the remote: true only when ssh answered and nothing listens there.
remote_port_free() { [ "$(rsh "ss -ltn | grep -E ':$PORT +'; echo checked")" = checked ]; }

teardown_check() {
    if [ "$MODE" != local ]; then
        rsh "pkill -u \$(id -un) -f '$PROG_PAT'" >/dev/null 2>&1
        sleep 1
        local left
        left=$(rsh "pgrep -u \$(id -un) -af '$PROG_PAT'; ss -ltn | grep -E ':$PORT +'; echo checked")
        if [ "$left" = checked ]; then echo "remote: no program, no listener on $PORT"
        elif [ -z "$left" ]; then echo "remote: NOT CHECKED (ssh failed)"; return 1
        else echo "remote: LEFT OVER:"; echo "$left" | grep -v '^checked$'; return 1; fi
    fi
    local mleft
    mleft=$(pgrep -lf "ethernet_direct_mtls/build/(mac|local)/$NAME"; lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN 2>/dev/null)
    [ -z "$mleft" ] && echo "mac: no program left" || { echo "mac: LEFT OVER:"; echo "$mleft"; return 1; }
}

cleanup() {
    for p in $MAC_PIDS; do kill "$p" 2>/dev/null; done
    echo "== teardown check"
    teardown_check
}
trap cleanup EXIT

side_copy() {   # SRC OUT SIDE LISTEN DIAL HOST: the per-host copy (SIDE mac = the accel side, linux = the status side)
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

normalize() {   # sorted, uptimes replaced
    sed -E 's/uptime_ms=[0-9]+/uptime_ms=<n>/' "$1" | LC_ALL=C sort
}

build_mac() {   # DIR SIDE LISTEN DIAL HOST
    local D=$1
    rm -rf "$D"; mkdir -p "$D/dangerous_exposure_source/lib"
    (
        cd "$D" || exit 1
        ln -sfn "$HERE/net" dangerous_exposure_source/tls
        clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -I"$OPENSSL_PREFIX/include" -c "$HERE/net/silica_tls.c" -o silica_tls.o || exit 1
        ar rcs dangerous_exposure_source/lib/libsilica_tls.a silica_tls.o
        for m in Supervisor wire_etf wireframe Carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
        for m in dangerous_tls dangerous_tls_carrier; do ln -sf "$HERE/$m.silica" "$m.silica"; done
        ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
        side_copy "$HERE/$NAME.silica" "$NAME.silica" "$2" "$3" "$4" "$5"
        printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_tls.silica\ndangerous_tls_carrier.silica\ntrial_wait_int64.silica\n%s.silica\n' "$NAME" > silica.config
        ec=0
        for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
        [ -f "$NAME.sams" ] || { echo "Mac compile failed (exit $ec); see $D/compile.log"; grep -A10 "Compilation error" compile.log | head -14; exit 1; }
        objs=""; for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
        clang $objs dangerous_exposure_source/lib/libsilica_tls.a -L"$OPENSSL_PREFIX/lib" -lssl -lcrypto -o "$NAME" -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
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
    echo "--- Mac end (accel side, dials):"; cat "$1"
    echo "--- Linux end (status side, listens):"; cat "$2"
    if diff <(normalize "$1") <(normalize "$HERE/expected/mac_end.txt") > "$WORK/mac_end.diff"; then echo "MATCH: mac end"
    else echo "MISMATCH: mac end (< got, > expected, both sorted):"; cat "$WORK/mac_end.diff"; ok=0; fi
    if diff <(normalize "$2") <(normalize "$HERE/expected/linux_end.txt") > "$WORK/linux_end.diff"; then echo "MATCH: linux end"
    else echo "MISMATCH: linux end (< got, > expected, both sorted):"; cat "$WORK/linux_end.diff"; ok=0; fi
    [ $ok = 1 ]
}

# ---- 0. the certificates are in place (made and exchanged by hand beforehand; nothing is created or copied here) ----
# Prints the SHA-512 fingerprints, which are public, so the operator sees which certificates a run uses.
fingerprint() { "$OPENSSL_PREFIX/bin/openssl" x509 -in "$1" -noout -fingerprint -sha512 2>/dev/null | sed 's/^.*=//; s/://g' | cut -c1-16; }
[ -f "$OPENSSL_PREFIX/include/openssl/ssl.h" ] || { echo "run_mtls: OpenSSL 3 headers not found on the Mac (set OPENSSL_PREFIX)"; exit 1; }
missing=""
[ -f "$MTLS_DIR/own.cert.pem" ] || missing="$missing\n  mac: $MTLS_DIR/own.cert.pem (make it once: ./make_cert.sh <name>)"
ls "$MTLS_DIR"/peers/*.pem >/dev/null 2>&1 || missing="$missing\n  mac: no peer certificate in $MTLS_DIR/peers/"
if [ "$MODE" = pair ]; then
    rstate=$(rsh 'd=${SILICA_MTLS_DIR:-$HOME/.silica_mtls}; [ -f $d/own.cert.pem ] && echo own; ls $d/peers/*.pem >/dev/null 2>&1 && echo peers; [ -f /usr/include/openssl/ssl.h ] && echo headers; echo checked')
    case "$rstate" in *checked*) ;; *) echo "run_mtls: ssh failed"; exit 1 ;; esac
    case "$rstate" in *own*) ;; *) missing="$missing\n  remote: ~/.silica_mtls/own.cert.pem (make it once there: make_cert.sh <name>)" ;; esac
    case "$rstate" in *peers*) ;; *) missing="$missing\n  remote: no peer certificate in ~/.silica_mtls/peers/" ;; esac
    case "$rstate" in *headers*) ;; *) missing="$missing\n  remote: OpenSSL headers (libssl-dev)" ;; esac
fi
if [ -n "$missing" ]; then
    printf "run_mtls: not ready; put these in place by hand first (README.md, Certificates):$missing\n"; trap - EXIT; exit 1
fi
echo "== 0. mac certificate sha512 $(fingerprint "$MTLS_DIR/own.cert.pem")...; accepted peers: $(for p in "$MTLS_DIR"/peers/*.pem; do printf '%s (%s...) ' "$(basename "$p")" "$(fingerprint "$p")"; done)"

# ---- --local: both ends on this Mac (the listener binds 0.0.0.0:<local port>, the dialer uses 127.0.0.1) ----
if [ "$MODE" = local ]; then
    echo "== local: the status side listens on listen:any:$LOCAL_PORT, the accel side dials 127.0.0.1:$LOCAL_PORT"
    busy=$(lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN 2>/dev/null)
    [ -z "$busy" ] || { echo "run_mtls: Mac port $LOCAL_PORT in use"; exit 1; }
    build_mac "$WORK/local/accel" mac "listen:any:$LOCAL_PORT" "127.0.0.1:$LOCAL_PORT" mac-arm64
    build_mac "$WORK/local/status" linux "listen:any:$LOCAL_PORT" "127.0.0.1:$LOCAL_PORT" linux-x86_64
    all=1
    for r in $(seq 1 "$RUNS"); do
        echo "== local run $r"
        run_with_watchdog "$WORK/local/status/$NAME" "$WORK/local_linux_end.out" 80 & SPID=$!
        for i in $(seq 1 40); do lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.25; done
        run_with_watchdog "$WORK/local/accel/$NAME" "$WORK/local_mac_end.out" 70
        wait $SPID
        compare_both "$WORK/local_mac_end.out" "$WORK/local_linux_end.out" || all=0
    done
    [ $all = 1 ] && echo "=== PASS" || echo "=== FAIL"
    [ $all = 1 ]; exit
fi

echo "== 1. Mac end (accel side): dials $REMOTE_IP:$PORT"
build_mac "$WORK/mac" mac "listen:any:$PORT" "$REMOTE_IP:$PORT" mac-arm64

if [ "$MODE" = pair ]; then
    echo "== 2. Linux end (status side) on $REMOTE: listen:any:$PORT"
    rsh 'echo "remote: $(hostname) ($(uname -sm))"' || { echo "run_mtls: ssh failed"; exit 1; }
    remote_port_free || { echo "run_mtls: remote port $PORT in use (or ssh failed):"; remote_listener; exit 1; }
    # Never compile while another build runs there (two CPUs, 3.9 GB, no swap).
    for i in $(seq 1 180); do
        others=$(rsh "pgrep -af '[s]ilica-compiler|[m]ake( |\$)'; echo checked")
        [ "$others" = checked ] && { others=""; break; }
        [ -z "$others" ] && others="(ssh failed: the remote did not answer)"
        [ $i = 1 ] && { echo "remote busy, waiting: $(rsh uptime)"; echo "$others" | head -3; }
        sleep 20
    done
    [ -z "$others" ] || { echo "run_mtls: the remote stayed busy for an hour"; exit 1; }
    echo "remote idle: $(rsh uptime)"
    rsh "mkdir -p $RDIR/stdlib $RDIR/net $RDIR/build && sha256sum $LINUX_COMPILER | cut -c1-16 | sed 's/^/linux compiler sha256: /'" || exit 1
    scp -q "${SSH_OPTS[@]}" "$HERE/build_linux.sh" "$REMOTE:silica_demo/ethernet_direct_mtls/" || exit 1
    scp -q "${SSH_OPTS[@]}" "$ROOT"/compiler/stdlib/{Supervisor,wire_etf,wireframe,Carrier}.silica "$HERE"/{dangerous_tls,dangerous_tls_carrier}.silica \
        "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" "$REMOTE:silica_demo/ethernet_direct_mtls/stdlib/" || exit 1
    scp -q "${SSH_OPTS[@]}" "$HERE"/net/{silica_tls.c,silica_tls_wrapper.meta} "$REMOTE:silica_demo/ethernet_direct_mtls/net/" || exit 1
    side_copy "$HERE/$NAME.silica" "$WORK/$NAME.linux.silica" linux "listen:any:$PORT" "$REMOTE_IP:$PORT" linux-x86_64
    scp -q "${SSH_OPTS[@]}" "$WORK/$NAME.linux.silica" "$REMOTE:silica_demo/ethernet_direct_mtls/build/$NAME.silica" || exit 1
    rsh "chmod +x $RDIR/build_linux.sh && $RDIR/build_linux.sh $RDIR/build $NAME $LINUX_COMPILER" || exit 1
fi

all=1
for r in $(seq 1 "$RUNS"); do
    if [ "$MODE" = pair ]; then
        echo "== 3. run $r: start the Linux end (timeout 90), listening on 0.0.0.0:$PORT"
        rsh "cd $RDIR/build && rm -f peer.out && (setsid nohup bash -c 'timeout 90 ./$NAME > peer.out 2>&1; echo \"exit \$?\" >> peer.out' > /dev/null 2>&1 &)" || exit 1
        up=0
        for i in $(seq 1 20); do remote_listener >/dev/null && { up=1; break; }; sleep 0.5; done
        [ $up = 1 ] || { echo "run_mtls: the Linux end is not listening on $PORT"; rsh "cat $RDIR/build/peer.out"; exit 1; }
        echo "remote: $(remote_listener | awk '{print $4}') listening"
        echo "== 4. run $r: the Mac end dials $REMOTE_IP:$PORT"
        run_with_watchdog "$WORK/mac/$NAME" "$WORK/mac_end.out" 70
        for i in $(seq 1 30); do rsh "grep -q '^exit ' $RDIR/build/peer.out" && break; sleep 1; done
        rsh "cat $RDIR/build/peer.out" > "$WORK/linux_end.out"
        compare_both "$WORK/mac_end.out" "$WORK/linux_end.out" || all=0
        echo "== after run $r"; teardown_check || all=0
    else
        echo "== timeout check: no Linux end; the Mac end dials $REMOTE_IP:$PORT and is refused until it times out"
        remote_port_free || { echo "run_mtls: something listens on remote port $PORT (or ssh failed)"; exit 1; }
        run_with_watchdog "$WORK/mac/$NAME" "$WORK/mac_end.out" 70; mrc=$?
        echo "--- Mac end:"; cat "$WORK/mac_end.out"
        grep -q "^timeout: pair not complete$" "$WORK/mac_end.out" && [ $mrc -eq 5 ] \
            && echo "MATCH: the Mac end timed out with exit 5" || { echo "MISMATCH: expected the timeout line and exit 5"; all=0; }
    fi
done
[ $all = 1 ] && echo "=== PASS" || echo "=== FAIL"
[ $all = 1 ]
