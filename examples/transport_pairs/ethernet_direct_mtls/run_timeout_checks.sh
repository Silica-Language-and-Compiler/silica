#!/bin/bash
# The dial-timeout checks of the mutual-TLS example (the required stated timeout of "<ipv4>:<port>:<timeout_ms>").
# Self-contained and outside make integrate: it makes its own throwaway key and certificate in a scratch
# directory (SILICA_MTLS_KEY / SILICA_MTLS_DIR point there; ~/.silica_mtls and ~/.ssh are never read or written),
# builds a small Silica program of this directory (dangerous_tls_timeout_check.silica) and two tiny C helpers, runs
# everything, and removes the scratch directory.
#
#   ./run_timeout_checks.sh              all checks
#   ./run_timeout_checks.sh --c-only     only the C-level checks (no Silica compiler needed)
#   ./run_timeout_checks.sh --keep       keep the scratch directory (its path is printed)
#
# Checks (each prints PASS, FAIL or SKIP; exit status 1 if any FAIL, else 0). Carrier endings, per
# dangerous_tls_carrier.silica: event -> owner receives -> carrier exit reason.
#   c_level      silica_tls_connect without a stated timeout, with an invalid one, a second connect after one
#                statement (value consumed), a host that is not a dotted quad: all EINVAL (tag 1), nothing dialled;
#                a refused loopback port with a stated timeout: tag 1 ECONNREFUSED, quickly.
#   bad_address  "127.0.0.1:P", "...:P:", "...:P:0", "...:P:12x", a 10-digit timeout: (:link_down,:fault), nothing
#                dialled, carrier ends (:explicit,:bad_address).
#   connect_timeout  a blackholed address ("$BLACKHOLE", default 10.255.255.1) with :300: (:link_down,:timeout),
#                (:explicit,:link_timeout), elapsed 200..2000 ms. SKIP when this host rejects the address at once.
#   handshake_timeout  a plain TCP listener that accepts and stays silent, with :500: the same, 400..3000 ms.
#   refused      a closed loopback port with :1500: (:link_down,:fault) in under 1000 ms, (:explicit,:link_unavailable),
#                no "handshake" text on stderr.
#   owner_close  the dialler's owner sends :close on an up link: (:link_down,:closed), a :normal end (the runtime reports it,
#                printed "carrier ended normal"), the carrier
#                reference is dead afterwards (a throw-away probe actor's cast to it returns false), no later message.
#   peer_close   the other end of that link sees (:link_down,:closed) and a :normal end the same way; the listener
#                then closes and the server exits 0.
#   lost_link    the server is SIGKILLed while the client sends :tx pings: (:link_down,:fault)+(:explicit,:link_lost)
#                or (:link_down,:closed)+normal (reset vs EOF; both accepted); a (:tx_failed,:link_down) comes before
#                the link_down and then the end is :link_lost.
#   handshake_rejected_by_dialler    the dialler's trust directory lacks the server's certificate: (:link_down,:fault),
#                (:explicit,:link_unavailable), no :link_up, "handshake failed" on its stderr, no (:accepted,...) on the listener.
#   handshake_rejected_by_listener   the server's lacks the dialler's (TLS 1.3): the dialler sees :link_up, then
#                (:link_down,:fault) and (:explicit,:link_lost); the listener sees no (:accepted,...) and says
#                "handshake failed" on stderr.
#   no_peer_timeout  the real pair program's dialling side against a closed port redials until its own timeout:
#                "timeout: pair not complete", exit 5 (about 45 s).
#   happy_path   ./run_mtls.sh --local --runs 2 (both ends of the real pair, twice) matches expected/. macOS only
#                (run_mtls.sh builds with clang -arch arm64 and Homebrew's OpenSSL); SKIP elsewhere.
# Not checked: that a supervisor does not restart a :normal end. The probe shows the reference dead and no
# message follows, which is what the exit reason implies; a supervisor harness would be needed to count restarts.
#
# Three identities (A, B, C) are made, so every handshake outcome is real: the programs are built once each
# (timeout program, link-check program as server / client_close / client_tx, the pair) with ports and modes written
# in by sed. Each run takes about 2-4 minutes, most of it compiling (5 builds) and the 45 s no_peer_timeout.
#
# Needs: cc (clang or gcc), ar, ssh-keygen, OpenSSL 3 with headers (macOS: Homebrew openssl@3, or OPENSSL_PREFIX;
# Linux: libssl-dev). Without OpenSSL headers every check is SKIP. The Silica checks also need the compiler for
# this host: SILICA_COMPILER (default binaries/silica-compiler on macOS; binaries/silica-compiler-linux_aarch64 or
# _linux_x86_64 on Linux, by uname -m). The compiler's file name sets its target.
# Environment: BLACKHOLE (default 10.255.255.1), OPENSSL_PREFIX, SILICA_COMPILER.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
C_ONLY=0 KEEP=0
for a in "$@"; do
    case "$a" in
        --c-only) C_ONLY=1 ;;
        --keep) KEEP=1 ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "run_timeout_checks: unknown argument $a" >&2; exit 2 ;;
    esac
done
BLACKHOLE="${BLACKHOLE:-10.255.255.1}"
OS="$(uname -s)"
NAME=dangerous_tls_timeout_check
SCR="$(mktemp -d "${TMPDIR:-/tmp}/silica_tls_timeout.XXXXXX")" || exit 2
PIDS=""
FAILS=0
cleanup() {
    for p in $PIDS; do kill "$p" 2>/dev/null; done
    if [ "$KEEP" = 1 ]; then echo "scratch kept: $SCR"; else rm -rf "$SCR"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; FAILS=$((FAILS + 1)); }
skip() { echo "SKIP $1: $2"; }

# ---- OpenSSL flags ----
if [ "$OS" = Darwin ]; then
    O="${OPENSSL_PREFIX:-$(brew --prefix openssl@3 2>/dev/null)}"
    export OPENSSL_PREFIX="$O"
    CFLAGS="-std=c11 -O2 -I$O/include"
    LIBS="-L$O/lib -lssl -lcrypto"
    HAVE_SSL=0; [ -n "$O" ] && [ -f "$O/include/openssl/ssl.h" ] && HAVE_SSL=1
else
    CFLAGS="-std=c11 -D_GNU_SOURCE -O2"
    LIBS="-lssl -lcrypto"
    HAVE_SSL=0
    printf '#include <openssl/ssl.h>\nint main(void){return 0;}\n' > "$SCR/probe.c"
    cc "$SCR/probe.c" -o "$SCR/probe" $LIBS >/dev/null 2>&1 && HAVE_SSL=1
fi
ALL="c_level bad_address connect_timeout handshake_timeout refused owner_close peer_close lost_link handshake_rejected_by_dialler handshake_rejected_by_listener no_peer_timeout happy_path"
if [ "$HAVE_SSL" != 1 ]; then
    for c in $ALL; do skip "$c" "OpenSSL 3 headers or libraries not found (set OPENSSL_PREFIX; Linux: libssl-dev)"; done
    echo "== 0 passed, $(echo $ALL | wc -w | tr -d ' ') skipped, 0 failed"
    exit 0
fi

# ---- C helpers: the harness (includes silica_tls.c, so it can call its static state) and the port tool ----
cat > "$SCR/harness.c" <<'EOF'
#include "silica_tls.c"
#include <sys/time.h>
static int bad = 0;
static void expect(const char *what, silica_tls_tagged r, int64_t tag, int64_t code) {
    int good = r.tag == tag && r.error_code == code;
    printf("%s %s (tag %lld error %lld)\n", good ? "ok  " : "FAIL", what, (long long)r.tag, (long long)r.error_code);
    if (!good) bad = 1;
}
static silica_tls_tagged conn(const char *host, int64_t port) {
    silica_tls_set_args(port, 0);
    return silica_tls_connect((const uint8_t *)host, (uint64_t)strlen(host));
}
int main(int argc, char **argv) {
    int64_t closed_port = argc > 1 ? atoll(argv[1]) : 1;
    /* no timeout stated: EINVAL, nothing dialled */
    expect("connect without a stated timeout", conn("127.0.0.1", closed_port), 1, EINVAL);
    expect("timeout 0 refused", silica_tls_set_connect_timeout(0), 1, EINVAL);
    expect("connect after timeout 0", conn("127.0.0.1", closed_port), 1, EINVAL);
    expect("timeout -5 refused", silica_tls_set_connect_timeout(-5), 1, EINVAL);
    expect("timeout 2147483648 refused", silica_tls_set_connect_timeout(2147483648LL), 1, EINVAL);
    expect("connect after too large a timeout", conn("127.0.0.1", closed_port), 1, EINVAL);
    expect("timeout 2147483647 accepted", silica_tls_set_connect_timeout(2147483647LL), 0, 0);
    expect("connect to a host that is not a dotted quad", conn("not.an.address", 1), 1, EINVAL);
    expect("second connect after one statement (consumed)", conn("127.0.0.1", closed_port), 1, EINVAL);
    expect("timeout 1000 accepted", silica_tls_set_connect_timeout(1000), 0, 0);
    expect("invalid statement clears an earlier one", silica_tls_set_connect_timeout(0), 1, EINVAL);
    expect("connect after the cleared statement", conn("127.0.0.1", closed_port), 1, EINVAL);
    expect("timeout 1000 accepted again", silica_tls_set_connect_timeout(1000), 0, 0);
    expect("empty host", silica_tls_connect((const uint8_t *)"", 0), 1, EINVAL);
    /* a stated timeout and a closed port: refused (not EINVAL), well within the timeout */
    struct timeval a, b;
    expect("timeout 1500 accepted", silica_tls_set_connect_timeout(1500), 0, 0);
    gettimeofday(&a, 0);
    expect("connect to a closed port", conn("127.0.0.1", closed_port), 1, ECONNREFUSED);
    gettimeofday(&b, 0);
    long ms = (b.tv_sec - a.tv_sec) * 1000 + (b.tv_usec - a.tv_usec) / 1000;
    int quick = ms < 1000;
    printf("%s refused connect took under 1000 ms\n", quick ? "ok  " : "FAIL");
    if (!quick) bad = 1;
    return bad;
}
EOF
cat > "$SCR/port_tool.c" <<'EOF'
/* port_tool free              prints a free loopback TCP port (bound, noted, closed)
   port_tool silent PORT SECS READYFILE
                               listens on 127.0.0.1:PORT, accepts every connection and never reads or writes,
                               until SECS seconds have passed; creates READYFILE once listening */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
static int bind_to(int port, int do_listen) {
    int fd = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    struct sockaddr_in a;
    if (fd < 0) return -1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) return -1;
    if (do_listen && listen(fd, 16) < 0) return -1;
    return fd;
}
int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "free") == 0) {
        int fd = bind_to(0, 0);
        struct sockaddr_in a;
        socklen_t n = sizeof a;
        if (fd < 0 || getsockname(fd, (struct sockaddr *)&a, &n) < 0) return 1;
        printf("%d\n", ntohs(a.sin_port));
        close(fd);
        return 0;
    }
    if (argc >= 5 && strcmp(argv[1], "silent") == 0) {
        int fd = bind_to(atoi(argv[2]), 1);
        if (fd < 0) return 1;
        FILE *f = fopen(argv[4], "w");
        if (f) { fputs("ready\n", f); fclose(f); }
        alarm((unsigned)atoi(argv[3]));
        for (;;) accept(fd, 0, 0);   /* the accepted descriptors stay open and silent until the alarm ends us */
    }
    return 2;
}
EOF
cc -O2 "$SCR/port_tool.c" -o "$SCR/port_tool" || { fail setup "cannot build the port tool"; exit 1; }
CLOSED_PORT="$("$SCR/port_tool" free)"
SILENT_PORT="$("$SCR/port_tool" free)"
[ "$SILENT_PORT" = "$CLOSED_PORT" ] && SILENT_PORT="$("$SCR/port_tool" free)"

# ---- 1. C level ----
if cc $CFLAGS -I"$HERE/net" "$SCR/harness.c" -o "$SCR/harness" $LIBS > "$SCR/harness.build" 2>&1; then
    if "$SCR/harness" "$CLOSED_PORT" > "$SCR/harness.out" 2>&1; then pass c_level
    else fail c_level "see below"; sed 's/^/    /' "$SCR/harness.out"; fi
else
    fail c_level "the harness did not compile"; sed 's/^/    /' "$SCR/harness.build" | head -20
fi
if [ "$C_ONLY" = 1 ]; then
    for c in $ALL; do [ "$c" = c_level ] || skip "$c" "--c-only"; done
    [ "$FAILS" = 0 ]; exit
fi

# ---- 2. throwaway identities: three keys and certificates (A, B, C) in the scratch directory only ----
# Trust directories (SILICA_MTLS_KEY is only read by make_cert):
#   okA  own A, accepts B        okB  own B, accepts A        (a working pair)
#   a_c  own A, accepts C        the dialler A does not accept the server B
#   b_c  own B, accepts C        the server B does not accept the dialler A
ID_OK=0
mkid() {   # NAME: $SCR/id_NAME/key and own.cert.pem
    mkdir -p "$SCR/id_$1"
    ssh-keygen -q -t ed25519 -N "" -C throwaway -f "$SCR/id_$1/key" >/dev/null 2>&1 \
        && SILICA_MTLS_KEY="$SCR/id_$1/key" SILICA_MTLS_DIR="$SCR/id_$1" "$SCR/make_cert" "check-$1" >/dev/null 2>&1
}
mktrust() {   # DIR OWN_ID PEER_ID
    mkdir -p "$1/peers" && cp "$SCR/id_$2/own.cert.pem" "$1/own.cert.pem" && cp "$SCR/id_$3/own.cert.pem" "$1/peers/peer.pem"
}
if cc $CFLAGS -DSILICA_TLS_MAKE_CERT "$HERE/net/silica_tls.c" -o "$SCR/make_cert" $LIBS >/dev/null 2>&1 \
   && mkid A && mkid B && mkid C \
   && mktrust "$SCR/okA" A B && mktrust "$SCR/okB" B A && mktrust "$SCR/a_c" A C && mktrust "$SCR/b_c" B C; then ID_OK=1; fi
# A process reads its own key (SILICA_MTLS_KEY, set per process by start_prog) and the certificates of its trust directory.
export SILICA_MTLS_KEY="$SCR/id_A/key"

# ---- 3. build the Silica programs ----
if [ "$OS" = Darwin ]; then
    DEFAULT_COMPILER="$ROOT/binaries/silica-compiler"
else
    case "$(uname -m)" in
        aarch64|arm64) DEFAULT_COMPILER="$ROOT/binaries/silica-compiler-linux_aarch64" ;;
        *) DEFAULT_COMPILER="$ROOT/binaries/silica-compiler-linux_x86_64" ;;
    esac
fi
CC_SILICA="${SILICA_COMPILER:-$DEFAULT_COMPILER}"
STD="$ROOT/compiler/stdlib"
SILICA_OK=1
if [ "$ID_OK" != 1 ]; then SILICA_OK=0; SILICA_WHY="could not make the throwaway keys and certificates (ssh-keygen, OpenSSL)"
elif [ ! -x "$CC_SILICA" ]; then SILICA_OK=0; SILICA_WHY="no Silica compiler at $CC_SILICA (set SILICA_COMPILER)"; fi

build_prog() {   # DIR NAME MODULE_PATH...: DIR/NAME.silica is already in place; builds DIR/NAME
    local D=$1 N=$2; shift 2
    mkdir -p "$D/dangerous_exposure_source/lib"
    (
        cd "$D" || exit 1
        ln -sfn "$HERE/net" dangerous_exposure_source/tls
        if [ "$OS" = Darwin ]; then
            clang $CFLAGS -arch arm64 -mmacosx-version-min=26.0 -c "$HERE/net/silica_tls.c" -o silica_tls.o || exit 1
        else
            cc $CFLAGS -c "$HERE/net/silica_tls.c" -o silica_tls.o || exit 1
        fi
        ar rcs dangerous_exposure_source/lib/libsilica_tls.a silica_tls.o
        : > silica.config
        for m in "$@"; do ln -sf "$m" "$(basename "$m")"; basename "$m" >> silica.config; done
        echo "$N.silica" >> silica.config
        ec=0
        for i in 1 2 3 4 5 6 7 8 9 10 11 12; do "$CC_SILICA" > compile.log 2>&1; ec=$?; [ $ec -eq 0 ] && break; [ $ec -ne 75 ] && [ $ec -ne 76 ] && break; done
        [ -f "$N.sams" ] || { echo "compile of $N failed (exit $ec); see $D/compile.log"; grep -A10 "Compilation error" compile.log | head -14; exit 1; }
        objs=""
        if [ "$OS" = Darwin ]; then
            for s in *.sams; do clang -mmacosx-version-min=26.0 -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
            clang $objs dangerous_exposure_source/lib/libsilica_tls.a $LIBS -o "$N" -Wl,-e,main -Wl,-macos_version_min,26.0 || exit 1
        else
            for s in *.sams; do cc -c -x assembler "$s" -o "${s%.sams}.o" || exit 1; objs="$objs ${s%.sams}.o"; done
            cc $objs dangerous_exposure_source/lib/libsilica_tls.a -o "$N" -no-pie -rdynamic -lpthread $LIBS || exit 1
        fi
    )
}

TLS_MODS="$HERE/dangerous_tls.silica $HERE/dangerous_tls_carrier.silica"
B1="$SCR/build_timeout"; B_SRV="$SCR/build_server"; B_CC="$SCR/build_client_close"; B_CT="$SCR/build_client_tx"; B_PAIR="$SCR/build_pair"
BUILT_TIMEOUT=0 BUILT_LINK=0 BUILT_PAIR=0
LINK_PORT="$("$SCR/port_tool" free)"
while [ "$LINK_PORT" = "$CLOSED_PORT" ] || [ "$LINK_PORT" = "$SILENT_PORT" ]; do LINK_PORT="$("$SCR/port_tool" free)"; done
if [ "$SILICA_OK" = 1 ]; then
    mkdir -p "$B1"
    sed -e "s/^fn refused_address() -> string { \"[^\"]*\" }/fn refused_address() -> string { \"127.0.0.1:$CLOSED_PORT:1500\" }/" \
        -e "s/^fn blackhole_address() -> string { \"[^\"]*\" }/fn blackhole_address() -> string { \"$BLACKHOLE:45612:300\" }/" \
        -e "s/^fn silent_address() -> string { \"[^\"]*\" }/fn silent_address() -> string { \"127.0.0.1:$SILENT_PORT:500\" }/" \
        "$HERE/dangerous_tls_timeout_check.silica" > "$B1/dangerous_tls_timeout_check.silica"
    build_prog "$B1" dangerous_tls_timeout_check $TLS_MODS && BUILT_TIMEOUT=1
    link_src() {   # DIR MODE
        mkdir -p "$1"
        sed -e "s/^fn mode() -> string { \"[^\"]*\" }/fn mode() -> string { \"$2\" }/" \
            -e "s/^fn listen_address() -> string { \"[^\"]*\" }/fn listen_address() -> string { \"listen:$LINK_PORT\" }/" \
            -e "s/^fn dial_address() -> string { \"[^\"]*\" }/fn dial_address() -> string { \"127.0.0.1:$LINK_PORT:5000\" }/" \
            "$HERE/dangerous_tls_link_check.silica" > "$1/dangerous_tls_link_check.silica"
    }
    link_src "$B_SRV" server; link_src "$B_CC" client_close; link_src "$B_CT" client_tx
    if build_prog "$B_SRV" dangerous_tls_link_check $TLS_MODS && build_prog "$B_CC" dangerous_tls_link_check $TLS_MODS \
       && build_prog "$B_CT" dangerous_tls_link_check $TLS_MODS; then BUILT_LINK=1; fi
    # the real pair's dialling side against a closed port: the no-peer timeout (regression)
    mkdir -p "$B_PAIR"
    sed -e "s/^fn dial_address() -> string { \"[^\"]*\" }/fn dial_address() -> string { \"127.0.0.1:$CLOSED_PORT:2000\" }/" \
        "$HERE/dangerous_ethernet_mtls_pair.silica" > "$B_PAIR/dangerous_ethernet_mtls_pair.silica"
    build_prog "$B_PAIR" dangerous_ethernet_mtls_pair "$STD/Supervisor.silica" "$STD/wire_etf.silica" "$STD/wireframe.silica" "$STD/Carrier.silica" \
        $TLS_MODS "$ROOT/trials/lib_trial_support/trial_wait_int64.silica" && BUILT_PAIR=1
fi
need_build() {   # CHECK FLAG: SKIP/FAIL when the build it needs is missing; returns 1 when the check cannot run
    if [ "$SILICA_OK" != 1 ]; then skip "$1" "$SILICA_WHY"; return 1; fi
    if [ "$2" != 1 ]; then fail "$1" "the program it needs did not build (see above)"; return 1; fi
    return 0
}

# ---- process helpers ----
LASTPID=""
start_prog() {   # EXE TRUSTDIR OUT ERR: runs EXE in the background with its own certificate directory
    local key="$SCR/id_A/key"   # the node's own key is read at run time too: B's for the B-side trust directories
    case "$2" in "$SCR/okB"|"$SCR/b_c") key="$SCR/id_B/key" ;; esac
    SILICA_MTLS_KEY="$key" SILICA_MTLS_DIR="$2" "$1" > "$3" 2> "$4" < /dev/null &
    LASTPID=$!
    PIDS="$PIDS $LASTPID"
}
wait_prog() {   # PID SECONDS: waits for the process, kills it after SECONDS; sets WAIT_RC (137-ish when killed)
    local pid=$1 secs=$2 i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt $((secs * 4)) ]; do sleep 0.25; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; WAIT_RC=killed
    else wait "$pid" 2>/dev/null; WAIT_RC=$?; fi
}
# Pairs of runs: SERVER_DIR CLIENT_EXE CLIENT_DIR TAG [kill]: start the server, give it 2 s to listen, start the
# client; with "kill" wait 3 s (the link is up by then) and SIGKILL the server; wait for both (outputs in $SCR/TAG.*).
run_pair_scenario() {
    local sdir=$1 cexe=$2 cdir=$3 tag=$4 kill=${5:-}
    start_prog "$B_SRV/dangerous_tls_link_check" "$sdir" "$SCR/$tag.server.out" "$SCR/$tag.server.err"; local spid=$LASTPID
    sleep 2
    start_prog "$cexe" "$cdir" "$SCR/$tag.client.out" "$SCR/$tag.client.err"; local cpid=$LASTPID
    if [ -n "$kill" ]; then sleep 3; kill -9 "$spid" 2>/dev/null; fi
    wait_prog "$cpid" 40; CRC=$WAIT_RC
    wait_prog "$spid" 40; SRC=$WAIT_RC
}
hasl() { grep -Fxq "$2" "$1"; }                       # FILE LINE: the exact line is present
lacks() { ! grep -q "$2" "$1"; }                      # FILE PATTERN: no line matches
linenr() { grep -Fxn "$2" "$1" | head -1 | cut -d: -f1; }
dump() {   # TAG: the outputs of a scenario, indented
    for f in "$SCR/$1".*.out "$SCR/$1".*.err; do [ -f "$f" ] && { echo "    -- $(basename "$f"):"; sed 's/^/    /' "$f" | head -30; }; done
}
DEAD="carrier ref dead (cast returned false)"
NOMSG="message after the end"

# ---- 4. the timeout program: bad_address, connect_timeout, handshake_timeout, refused ----
if need_build bad_address $BUILT_TIMEOUT; then
    "$SCR/port_tool" silent "$SILENT_PORT" 150 "$SCR/ready" >/dev/null 2>&1 &
    PIDS="$PIDS $!"
    for i in $(seq 1 40); do [ -f "$SCR/ready" ] && break; sleep 0.25; done
    [ -f "$SCR/ready" ] || echo "note: the silent listener did not start on port $SILENT_PORT"
    start_prog "$B1/dangerous_tls_timeout_check" "$SCR/okA" "$SCR/run.out" "$SCR/run.err"
    wait_prog "$LASTPID" 100; RC=$WAIT_RC
    sed -E 's/elapsed_ms=[0-9]+/elapsed_ms=<n>/' "$SCR/run.out" > "$SCR/run.norm"
    if [ "$RC" != 0 ] || ! grep -qx "done" "$SCR/run.out"; then
        echo "note: the timeout program ended with status $RC and did not print 'done'; its output:"
        sed 's/^/    /' "$SCR/run.out"; sed 's/^/    err: /' "$SCR/run.err" | head -20
    fi
    has() { grep -Fxq "$1" "$SCR/run.norm"; }
    ms_of() { sed -n "s/^$1: link_down $2 elapsed_ms=\\([0-9][0-9]*\\)\$/\\1/p" "$SCR/run.out" | head -1; }
    # a case's lines on standard output, and what the program wrote on standard error while it ran ("== <case>" markers)
    show_case() { grep "^$1: " "$SCR/run.out" | sed 's/^/    /'; show_err "$1"; }
    err_of() { awk -v c="== $1" '$0 ~ /^== / { on = ($0 == c); next } on' "$SCR/run.err"; }
    show_err() { err_of "$1" | sed 's/^/    err: /'; }

    # bad_address: fault, nothing dialled, ends (:explicit, :bad_address)
    ok=1
    for n in no_timeout empty_timeout zero_timeout nondigit_timeout ten_digit_timeout; do
        has "$n: link_down fault elapsed_ms=<n>" || ok=0
        has "$n: carrier ended (:explicit, :bad_address)" || ok=0
        grep -q "^$n: unexpected" "$SCR/run.out" && ok=0
        m="$(ms_of "$n" fault)"; { [ -n "$m" ] && [ "$m" -lt 1000 ]; } || ok=0
    done
    if [ $ok = 1 ]; then pass bad_address; else fail bad_address "expected (:link_down, :fault) then (:explicit, :bad_address) for all five"; grep -E "^(no|empty|zero|nondigit|ten_digit)_" "$SCR/run.out" | sed 's/^/    /'; fi

    # connect_timeout
    m="$(ms_of blackhole timeout)"; mf="$(ms_of blackhole fault)"
    if [ -n "$mf" ] && [ "$mf" -lt 150 ]; then
        skip connect_timeout "$BLACKHOLE is rejected at once on this host (link_down fault after $mf ms); set BLACKHOLE to an address that drops packets"
    elif [ -n "$m" ] && [ "$m" -ge 200 ] && [ "$m" -le 2000 ] && has "blackhole: carrier ended (:explicit, :link_timeout)"; then
        pass connect_timeout; echo "     elapsed ${m} ms (stated 300)"
    else
        fail connect_timeout "expected (:link_down, :timeout) at 200..2000 ms and (:explicit, :link_timeout)"; show_case blackhole
    fi

    # handshake_timeout
    m="$(ms_of silent timeout)"
    if [ -n "$m" ] && [ "$m" -ge 400 ] && [ "$m" -le 3000 ] && has "silent: carrier ended (:explicit, :link_timeout)"; then
        pass handshake_timeout; echo "     elapsed ${m} ms (stated 500)"
    else
        fail handshake_timeout "expected (:link_down, :timeout) at 400..3000 ms and (:explicit, :link_timeout)"; show_case silent
    fi

    # refused: a closed loopback port: fault at once (well under the stated 1500 ms), the carrier ends
    # (:explicit, :link_unavailable), and the wrapper says nothing about a handshake on standard error
    m="$(ms_of refused fault)"
    if has "refused: link_down fault elapsed_ms=<n>" && has "refused: carrier ended (:explicit, :link_unavailable)" \
       && { [ -n "$m" ] && [ "$m" -lt 1000 ]; } && [ -z "$(err_of refused | grep -i handshake)" ] && ! grep -q "^refused: unexpected" "$SCR/run.out"; then
        pass refused; echo "     elapsed ${m} ms (stated 1500)"
    else fail refused "expected (:link_down, :fault) under 1000 ms, (:explicit, :link_unavailable), no handshake text on stderr"; show_case refused; fi
else
    for c in connect_timeout handshake_timeout refused; do [ "$SILICA_OK" = 1 ] && fail "$c" "the timeout program did not build" || skip "$c" "$SILICA_WHY"; done
fi

# ---- 5. teardown between two processes (server and client of the link-check program) ----
if need_build peer_close $BUILT_LINK; then
    # peer_close / owner_close: the client's owner sends :close on the up link
    run_pair_scenario "$SCR/okB" "$B_CC/dangerous_tls_link_check" "$SCR/okA" close
    ok=1
    for l in "client: link_up 127.0.0.1:$LINK_PORT" "client: link_down closed" "client: carrier ended normal" "client: $DEAD"; do hasl "$SCR/close.client.out" "$l" || ok=0; done
    lacks "$SCR/close.client.out" "carrier ended (:explicit" || ok=0
    lacks "$SCR/close.client.out" "carrier ended other" || ok=0
    lacks "$SCR/close.client.out" "$NOMSG" || ok=0
    [ "$CRC" = 0 ] || ok=0
    if [ $ok = 1 ]; then pass owner_close; else fail owner_close "expected link_up, (:link_down, :closed), a :normal end, a dead carrier ref, no explicit end, nothing after, exit 0 (client exit $CRC)"; dump close; fi
    ok=1
    for l in "server: listening" "server: accepted" "server: session link_up" "server: session link_down closed" "server: carrier ended normal" "server: $DEAD" "server: listener link_down closed"; do hasl "$SCR/close.server.out" "$l" || ok=0; done
    lacks "$SCR/close.server.out" "carrier ended (:explicit" || ok=0
    lacks "$SCR/close.server.out" "carrier ended other" || ok=0
    lacks "$SCR/close.server.out" "$NOMSG" || ok=0
    [ "$SRC" = 0 ] || ok=0
    if [ $ok = 1 ]; then pass peer_close; else fail peer_close "the peer's owner must see (:link_down, :closed) and a :normal end (session and listener), no explicit end (server exit $SRC)"; dump close; fi

    # lost_link: SIGKILL the server while the client sends :tx pings
    run_pair_scenario "$SCR/okB" "$B_CT/dangerous_tls_link_check" "$SCR/okA" kill kill
    out="$SCR/kill.client.out"
    ok=1
    hasl "$out" "client: link_up 127.0.0.1:$LINK_PORT" || ok=0
    hasl "$out" "client: $DEAD" || ok=0
    lacks "$out" "$NOMSG" || ok=0
    [ "$CRC" = 0 ] || ok=0
    if hasl "$out" "client: link_down fault"; then
        hasl "$out" "client: carrier ended (:explicit, :link_lost)" || ok=0
    elif hasl "$out" "client: link_down closed"; then
        hasl "$out" "client: carrier ended normal" || ok=0
        lacks "$out" "carrier ended (:explicit" || ok=0
        lacks "$out" "carrier ended other" || ok=0
    else ok=0; fi
    if hasl "$out" "client: tx_failed link_down"; then
        a="$(linenr "$out" "client: tx_failed link_down")"; b="$(linenr "$out" "client: link_down fault")"
        { [ -n "$b" ] && [ "$a" -lt "$b" ]; } || ok=0   # a failed write is a fault, and comes before the link_down
    fi
    if [ $ok = 1 ]; then pass lost_link; else fail lost_link "expected (:link_down, :fault)+(:explicit, :link_lost) or (:link_down, :closed)+a :normal end, tx_failed before link_down, dead ref (client exit $CRC)"; dump kill; fi

    # handshake_failed (a): the dialler does not accept the server's certificate
    run_pair_scenario "$SCR/okB" "$B_CT/dangerous_tls_link_check" "$SCR/a_c" hsa
    out="$SCR/hsa.client.out"
    ok=1
    hasl "$out" "client: link_down fault" || ok=0
    hasl "$out" "client: carrier ended (:explicit, :link_unavailable)" || ok=0
    lacks "$out" "client: link_up" || ok=0
    lacks "$out" "$NOMSG" || ok=0
    grep -q "handshake failed" "$SCR/hsa.client.err" || ok=0
    lacks "$SCR/hsa.server.out" "^server: accepted" || ok=0
    [ "$CRC" = 0 ] || ok=0
    if [ $ok = 1 ]; then pass handshake_rejected_by_dialler; else fail handshake_rejected_by_dialler "expected (:link_down, :fault)+:link_unavailable, 'handshake failed' on stderr, no (:accepted, ...) on the listener"; dump hsa; fi

    # handshake_failed (b): the server does not accept the dialler's certificate (TLS 1.3: the dialler first sees :link_up)
    run_pair_scenario "$SCR/b_c" "$B_CT/dangerous_tls_link_check" "$SCR/okA" hsb
    out="$SCR/hsb.client.out"
    ok=1
    hasl "$out" "client: link_up 127.0.0.1:$LINK_PORT" || ok=0
    hasl "$out" "client: link_down fault" || ok=0
    hasl "$out" "client: carrier ended (:explicit, :link_lost)" || ok=0
    lacks "$out" "$NOMSG" || ok=0
    grep -q "handshake failed" "$SCR/hsb.server.err" || ok=0
    lacks "$SCR/hsb.server.out" "^server: accepted" || ok=0
    [ "$CRC" = 0 ] || ok=0
    if [ $ok = 1 ]; then pass handshake_rejected_by_listener; else fail handshake_rejected_by_listener "expected :link_up then (:link_down, :fault)+:link_lost on the dialler; no (:accepted, ...) and 'handshake failed' on the listener"; dump hsb; fi
else
    for c in owner_close peer_close lost_link handshake_rejected_by_dialler handshake_rejected_by_listener; do [ "$SILICA_OK" = 1 ] && fail "$c" "the link-check program did not build" || skip "$c" "$SILICA_WHY"; done
fi

# ---- 6. regressions: no-peer timeout (exit 5) and the pair itself ----
if need_build no_peer_timeout $BUILT_PAIR; then
    # the pair's dialling side against a closed port redials until its own 45 s timeout: "timeout: pair not complete", exit 5
    start_prog "$B_PAIR/dangerous_ethernet_mtls_pair" "$SCR/okA" "$SCR/pair.out" "$SCR/pair.err"
    wait_prog "$LASTPID" 80; PRC=$WAIT_RC
    if [ "$PRC" = 5 ] && hasl "$SCR/pair.out" "timeout: pair not complete"; then pass no_peer_timeout
    else fail no_peer_timeout "expected the line 'timeout: pair not complete' and exit 5 (got $PRC)"; sed 's/^/    /' "$SCR/pair.out" | head -20; sed 's/^/    err: /' "$SCR/pair.err" | head -10; fi
fi

# the real pair, both ends on this host, twice in a row (macOS: run_mtls.sh builds with clang -arch arm64 and Homebrew OpenSSL)
if [ "$OS" != Darwin ]; then
    skip happy_path "run_mtls.sh --local builds with clang -arch arm64 and Homebrew OpenSSL: macOS only"
elif [ "$ID_OK" != 1 ] || [ ! -x "$CC_SILICA" ]; then
    skip happy_path "no Silica compiler or no throwaway identity"
else
    # run_mtls.sh --local runs both ends as ONE identity, so it gets a trust directory that accepts its own certificate
    mkdir -p "$SCR/self/peers" && cp "$SCR/id_A/own.cert.pem" "$SCR/self/own.cert.pem" && cp "$SCR/id_A/own.cert.pem" "$SCR/self/peers/self.pem"
    if SILICA_MTLS_KEY="$SCR/id_A/key" SILICA_MTLS_DIR="$SCR/self" SILICA_COMPILER="$CC_SILICA" "$HERE/run_mtls.sh" --local --runs 2 > "$SCR/happy.out" 2>&1; then pass happy_path
    else fail happy_path "run_mtls.sh --local --runs 2 did not pass; its output:"; sed 's/^/    /' "$SCR/happy.out" | tail -40; fi
fi

echo "== done: $FAILS failed"
[ "$FAILS" = 0 ]
