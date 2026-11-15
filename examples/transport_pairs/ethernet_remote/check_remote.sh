#!/bin/bash
# Stage E0 of compiler/design_documents/transport_hosted_ethernet_plan.md: is the remote Erlang peer ready?
#
#   REMOTE=manager@aalang.org ./check_remote.sh [--remote-port N] [--local-port N]
#
# 1. ssh in batch mode (key only; nothing is typed or printed) and report the OTP release on the remote.
# 2. Put the BEAM demo's Erlang peer (../../../programmer_tools/transport_beam_demo/silica_peer.erl) under
#    ~/silica_demo on the remote, compile it there, and start it listening on the remote's LOOPBACK only
#    (127.0.0.1:<remote-port>): no firewall change, no public port (plan decision 2).
# 3. Open an ssh local forward  127.0.0.1:<local-port> -> remote 127.0.0.1:<remote-port>.
# 4. Run the hosted Silica demo program (the (:tcp) carrier) against the forwarded port: it sends the 48-byte
#    (:accel, ...) term as one ETF frame behind the 4-byte length prefix, OTP's gen_tcp {packet, 4} on the
#    remote decodes it, and the reply (:led, ...) is decoded by Silica.
# 5. Tear everything down (trap): the forward, the remote erl, nothing left running on the web host.
#
# Passes (exit 0) when the remote peer printed the accel term and 48 bytes and the Silica program printed
# "led red on". Needs: ssh key access, clang, ar, the Silica compiler (SILICA_COMPILER, default
# binaries/silica-compiler), erl is NOT needed on this Mac. Outside make integrate: it needs the network.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
REMOTE="${REMOTE:-manager@aalang.org}"
RPORT=4540 LPORT=4541
while [ $# -gt 0 ]; do
    case "$1" in
        --remote-port) RPORT=$2; shift 2 ;;
        --local-port) LPORT=$2; shift 2 ;;
        *) echo "check_remote: unknown argument $1" >&2; exit 2 ;;
    esac
done
CC="${SILICA_COMPILER:-$ROOT/binaries/silica-compiler}"
WORK="$HERE/build"; CTL="$WORK/ssh.ctl"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10)
RDIR='$HOME/silica_demo'
rm -rf "$WORK"; mkdir -p "$WORK"

cleanup() {
    [ -S "$CTL" ] && ssh "${SSH_OPTS[@]}" -S "$CTL" -O exit "$REMOTE" >/dev/null 2>&1
    ssh "${SSH_OPTS[@]}" "$REMOTE" "pkill -u \$(id -un) -f 'silica_peer main $RPORT'" >/dev/null 2>&1
}
trap cleanup EXIT

echo "== 1. remote"
ssh "${SSH_OPTS[@]}" "$REMOTE" 'echo "host: $(hostname) ($(uname -sm))"; erl -noshell -eval "io:format(\"otp: ~s~n\",[erlang:system_info(otp_release)]),halt()."' \
    || { echo "check_remote: ssh or erl failed"; exit 1; }

echo "== 2. remote peer (loopback only, port $RPORT)"
ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p $RDIR" || exit 1
scp -q "${SSH_OPTS[@]}" "$ROOT/programmer_tools/transport_beam_demo/silica_peer.erl" "$REMOTE:silica_demo/silica_peer.erl" || exit 1
ssh "${SSH_OPTS[@]}" "$REMOTE" "cd $RDIR && erlc silica_peer.erl && (nohup timeout 60 erl -noshell -pa $RDIR -s silica_peer main $RPORT > peer.out 2>&1 &) ; sleep 2; ss -ltn | grep -c '127.0.0.1:$RPORT '" | { read n; [ "$n" = 1 ] && echo "listening on remote 127.0.0.1:$RPORT" || { echo "remote peer is not listening"; exit 1; }; } || exit 1

echo "== 3. forward 127.0.0.1:$LPORT -> remote 127.0.0.1:$RPORT"
ssh "${SSH_OPTS[@]}" -f -N -M -S "$CTL" -o ExitOnForwardFailure=yes -L "127.0.0.1:$LPORT:127.0.0.1:$RPORT" "$REMOTE" || { echo "forward failed"; exit 1; }

echo "== 4. Silica program through the forward"
mkdir -p "$WORK/silica/dangerous_exposure_source/lib"; cd "$WORK/silica" || exit 1
ln -sfn "$ROOT/compiler/stdlib/net" dangerous_exposure_source/sockets
clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=26.0 -c "$ROOT/compiler/stdlib/net/silica_sockets.c" -o silica_sockets.o || exit 1
ar rcs dangerous_exposure_source/lib/libsilica_sockets.a silica_sockets.o
for m in Supervisor wire_etf wireframe Carrier dangerous_sockets dangerous_tcp_carrier; do ln -sf "$ROOT/compiler/stdlib/$m.silica" "$m.silica"; done
ln -sf "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" trial_wait_int64.silica
sed "s/127.0.0.1:4040/127.0.0.1:$LPORT/" "$ROOT/programmer_tools/transport_beam_demo/dangerous_telemetry.silica" > dangerous_telemetry.silica
printf 'Supervisor.silica\nwire_etf.silica\nwireframe.silica\nCarrier.silica\ndangerous_sockets.silica\ndangerous_tcp_carrier.silica\ntrial_wait_int64.silica\ndangerous_telemetry.silica\n' > silica.config
for i in $(seq 1 12); do "$CC" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
[ -f dangerous_telemetry.sams ] || { echo "compile failed (exit $ec); see $WORK/silica/compile.log"; grep -A8 "Compilation error" compile.log | head -12; exit 1; }
objs=""; for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
clang $objs dangerous_exposure_source/lib/libsilica_sockets.a -o dangerous_telemetry -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
./dangerous_telemetry > silica.out 2>&1 &
PROG=$!; ( sleep 25; kill $PROG 2>/dev/null ) & WATCH=$!; disown
wait $PROG 2>/dev/null; rc=$?; kill $WATCH 2>/dev/null
sleep 1
echo "--- remote peer output:"; ssh "${SSH_OPTS[@]}" "$REMOTE" "cat $RDIR/peer.out"
echo "--- silica program (exit $rc):"; cat silica.out
ssh "${SSH_OPTS[@]}" "$REMOTE" "cat $RDIR/peer.out" > "$WORK/peer.out" 2>&1
ok=1
grep -q "got {accel" "$WORK/peer.out" && grep -q "(48 bytes)" "$WORK/peer.out" || { echo "FAIL: the remote did not decode the 48-byte accel term"; ok=0; }
grep -q "led red on" silica.out || { echo "FAIL: Silica did not decode the reply"; ok=0; }
[ $rc -eq 0 ] || { echo "FAIL: program exit $rc"; ok=0; }
[ $ok = 1 ] && echo "E0: PASS" || echo "E0: FAIL"
[ $ok = 1 ]
