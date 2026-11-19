/*
   Copyright 2026 Lee Scott Barney

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

/* The Fifi socket wrappers the hosted carriers of transport_serialization_design.md §6.3 stand on
   (ROADMAP chunk 9, the part phase 2 needs): TCP connect / listen / accept, UDP bind / send / receive,
   a serial port through termios, and the read / write / close every descriptor shares. Every call is
   bounded by a timeout in milliseconds, so a carrier actor polls between its mailbox messages and
   never blocks its thread for long. A TCP connect is bounded too: the socket is non-blocking while it
   connects and the wait ends at the timeout the caller stated (silica_sockets_set_connect_timeout).
   There is no default: a connect whose timeout was not stated is refused with EINVAL. The one call
   that asks the system resolver (silica_sockets_tcp_listen_name) is bounded the same way.

   Addresses are IPv4 (dotted quad, ipv4_strict) or IPv6 (ipv6_strict); both parsers are this file's
   own and accept exactly one text for each address. An IPv6 socket is always IPV6_V6ONLY, so the two
   families never mix on one socket.

   Result conventions (FFI wrapper specification §9): a tagged result { tag, value, error_code } with
   tag 0 = ok, 1 = error (errno in error_code), 2 = timeout, 3 = closed by the peer. Received bytes
   land in a buffer private to the calling thread; silica_sockets_take answers them as a pointer plus
   length that the compiler copies into a Silica string before the next call. */

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <time.h>
#include <limits.h>
#include <termios.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <netdb.h>
#include <pthread.h>
#include <sys/ioctl.h>
#if defined(__APPLE__)
#include <sys/sockio.h>
#endif
#include <stdio.h>

typedef struct silica_sockets_tagged {
    int64_t tag;
    int64_t value;
    int64_t error_code;
} silica_sockets_tagged;

typedef struct silica_sockets_bytes {
    int64_t tag;
    const uint8_t *text_ptr;
    uint64_t text_len;
    int64_t error_code;
} silica_sockets_bytes;

#define SILICA_SOCKETS_BUF 65536

static __thread uint8_t silica_sockets_rx[SILICA_SOCKETS_BUF];
static __thread uint64_t silica_sockets_rx_len = 0;

/* The FFI carries a pointer-plus-length pair only as a wrapper's sole parameters, so a wrapper that
   needs a string and scalars takes the scalars first through silica_sockets_set_args (and a host
   name through silica_sockets_set_host), kept per thread: a dangerous actor is its own thread. */
static __thread int64_t silica_sockets_arg_a = 0;
static __thread int64_t silica_sockets_arg_b = 0;
static __thread char silica_sockets_host[256] = "127.0.0.1";

/* The connect timeout the caller stated for the next TCP connect of this thread, in milliseconds
   (silica_sockets_set_connect_timeout). 0 means "not stated": there is no default, so a connect then
   answers EINVAL. Each connect consumes the value, so one statement bounds exactly one connect. */
static __thread int64_t silica_sockets_connect_timeout_ms = 0;

static silica_sockets_tagged ok(int64_t v) { silica_sockets_tagged r = {0, v, 0}; return r; }
static silica_sockets_tagged err(void) { silica_sockets_tagged r = {1, 0, (int64_t)errno}; return r; }
static silica_sockets_tagged timeout(void) { silica_sockets_tagged r = {2, 0, 0}; return r; }
static silica_sockets_tagged closed(void) { silica_sockets_tagged r = {3, 0, 0}; return r; }

static int copy_host(const uint8_t *ptr, uint64_t len, char *out, size_t cap) {
    if (ptr == 0 || len == 0 || len >= cap) return 0;
    memcpy(out, ptr, (size_t)len);
    out[len] = 0;
    return 1;
}

/* The one IPv4 text parser of this file (Lee, 2026-11-12): exactly four decimal parts separated by dots, each 0 to
   255, digits only, no leading zero except a bare "0". Everything else is refused: "010.0.0.1", "1.02.3.4",
   "1.2.3.", "1.2.3.4.5", empty parts, signs, spaces, hex and octal forms, and a text with a NUL inside. It is the
   same on every host, where inet_aton and inet_pton are not (macOS and glibc differ on leading zeros), so no
   libc parser is used. The address is answered in host order. */
static int ipv4_strict(const uint8_t *s, uint64_t n, uint32_t *out) {
    uint32_t a = 0;
    uint64_t i = 0;
    for (int part = 0; part < 4; part++) {
        uint32_t v = 0;
        uint64_t start = i;
        if (part > 0) {
            if (i >= n || s[i] != '.') return 0;
            i++;
            start = i;
        }
        while (i < n && s[i] >= '0' && s[i] <= '9') {
            if (i - start == 3) return 0;
            v = v * 10 + (uint32_t)(s[i] - '0');
            i++;
        }
        if (i == start || v > 255) return 0;
        if (s[start] == '0' && i - start > 1) return 0;
        a = (a << 8) | v;
    }
    if (i != n) return 0;
    *out = a;
    return 1;
}

static int ipv4_strict_text(const char *s, uint32_t *out) {
    return ipv4_strict((const uint8_t *)s, (uint64_t)strlen(s), out);
}

/* The canonical text of an IPv6 address given as its eight groups (RFC 5952): lowercase hexadecimal, no leading
   zeros in a group, and "::" in place of the longest run of two or more zero groups (the first such run when two
   are equally long). out holds at least 40 bytes; the answer is the length, without a terminating NUL. */
static size_t ipv6_render(const uint16_t g[8], char *out) {
    static const char hex[] = "0123456789abcdef";
    int best_start = -1, best_len = 0;
    for (int i = 0; i < 8; ) {
        int j = i;
        while (j < 8 && g[j] == 0) j++;
        if (j - i >= 2 && j - i > best_len) { best_start = i; best_len = j - i; }
        i = j > i ? j : i + 1;
    }
    size_t o = 0;
    for (int i = 0; i < 8; ) {
        if (i == best_start) { out[o++] = ':'; out[o++] = ':'; i += best_len; continue; }
        if (o > 0 && out[o - 1] != ':') out[o++] = ':';
        uint16_t v = g[i];
        int started = 0;
        for (int shift = 12; shift >= 0; shift -= 4) {
            int d = (v >> shift) & 15;
            if (d != 0 || started || shift == 0) { out[o++] = hex[d]; started = 1; }
        }
        i++;
    }
    return o;
}

/* The one IPv6 text parser of this file, in the style of ipv4_strict: no libc parser, the same on every host, and
   exactly one text for each address, the canonical one of RFC 5952 (ipv6_render). The text is read as groups of
   1 to 4 lowercase hexadecimal digits separated by single colons, with at most one "::"; it is then accepted only
   if it is byte for byte the canonical text of the address it names. So these are refused: uppercase digits
   ("2001:DB8::1"), a leading zero in a group ("2001:0db8::1"), a run of zero groups written out where "::"
   belongs ("0:0:0:0:0:0:0:1" for "::1"), "::" standing for a single group, a dotted-quad tail
   ("::ffff:1.2.3.4"), a zone ("fe80::1%en0"), brackets, spaces, and a text with a NUL inside. The address is
   answered as its eight groups. (The wrappers refuse one more thing, a link-local address: ipv6_usable.) */
static int ipv6_strict(const uint8_t *s, uint64_t n, uint16_t g[8]) {
    uint16_t head[8], tail[8];
    int nh = 0, nt = 0, gap = 0;
    uint64_t i = 0;
    char canon[40];
    if (s == 0 || n < 2 || n > 39) return 0;
    if (s[0] == ':') {
        if (s[1] != ':') return 0;
        gap = 1;
        i = 2;
    }
    while (i < n) {
        uint32_t v = 0;
        uint64_t start = i;
        for (;;) {
            int d;
            if (i >= n) break;
            if (s[i] >= '0' && s[i] <= '9') d = s[i] - '0';
            else if (s[i] >= 'a' && s[i] <= 'f') d = s[i] - 'a' + 10;
            else break;
            if (i - start == 4) return 0;
            v = v * 16 + (uint32_t)d;
            i++;
        }
        if (i == start) return 0;
        if (nh + nt == 8) return 0;
        if (gap) tail[nt++] = (uint16_t)v; else head[nh++] = (uint16_t)v;
        if (i == n) break;
        if (s[i] != ':') return 0;
        i++;
        if (i == n) return 0;
        if (s[i] == ':') {
            if (gap) return 0;
            gap = 1;
            i++;
        }
    }
    if (gap ? nh + nt > 7 : nh != 8) return 0;
    for (int k = 0; k < 8; k++) g[k] = 0;
    for (int k = 0; k < nh; k++) g[k] = head[k];
    for (int k = 0; k < nt; k++) g[8 - nt + k] = tail[k];
    if (ipv6_render(g, canon) != (size_t)n || memcmp(canon, s, (size_t)n) != 0) return 0;
    return 1;
}

static int ipv6_is_loopback(const uint16_t g[8]) {
    for (int k = 0; k < 7; k++) if (g[k] != 0) return 0;
    return g[7] == 1;
}

/* fe80::/10: an address that means something only on one interface (its scope). */
static int ipv6_is_link_local(const uint16_t g[8]) {
    return (g[0] & 0xffc0) == 0xfe80;
}

static void ipv6_groups_of(const struct in6_addr *a, uint16_t g[8]) {
    for (int k = 0; k < 8; k++) g[k] = (uint16_t)((a->s6_addr[2 * k] << 8) | a->s6_addr[2 * k + 1]);
}

static void ipv6_sockaddr(struct sockaddr_in6 *addr, const uint16_t g[8], int64_t port) {
    memset(addr, 0, sizeof *addr);
#if defined(__APPLE__)
    addr->sin6_len = sizeof *addr;
#endif
    addr->sin6_family = AF_INET6;
    addr->sin6_port = htons((uint16_t)port);
    for (int k = 0; k < 8; k++) {
        addr->sin6_addr.s6_addr[2 * k] = (uint8_t)(g[k] >> 8);
        addr->sin6_addr.s6_addr[2 * k + 1] = (uint8_t)(g[k] & 255);
    }
}

/* The one host-name check of this file: what silica_sockets_tcp_listen_name hands to the system resolver. A name
   is 1 to 253 bytes of labels separated by single dots; a label is 1 to 63 letters, digits and hyphens and neither
   starts nor ends with a hyphen; the last label starts with a letter. That last rule keeps every numeric form
   away from the resolver, whose own number parsing differs between hosts ("010.0.0.1", "127.1", "0x7f000001"):
   an address is written as an address, in the forms the strict parsers accept. No trailing dot, no underscore. */
static int host_name_strict(const uint8_t *s, uint64_t n) {
    uint64_t label_start = 0;
    if (s == 0 || n == 0 || n > 253) return 0;
    for (uint64_t i = 0; i <= n; i++) {
        if (i == n || s[i] == '.') {
            uint64_t len = i - label_start;
            if (len == 0 || len > 63) return 0;
            if (s[label_start] == '-' || s[i - 1] == '-') return 0;
            if (i == n) {
                uint8_t c = s[label_start];
                if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) return 0;
            }
            label_start = i + 1;
            continue;
        }
        uint8_t c = s[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-')) return 0;
    }
    return 1;
}

/* A write to a connection whose peer has gone must fail with EPIPE, which the carrier reports to its
   owner, and must never raise SIGPIPE, which would end the whole program. Each platform's own
   per-socket mechanism is used, so the program's signal dispositions are left alone: macOS marks the
   socket (SO_NOSIGPIPE); Linux has no such socket option and marks each send instead (MSG_NOSIGNAL,
   in write_no_sigpipe below). */
static void no_sigpipe(int fd) {
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#else
    (void)fd;
#endif
}

/* One write to any descriptor. On Linux a socket is written with send(MSG_NOSIGNAL); a descriptor that
   is not a socket (a serial port) answers ENOTSOCK and is written with write(), which cannot raise
   SIGPIPE on a terminal. */
static ssize_t write_no_sigpipe(int fd, const uint8_t *ptr, size_t len) {
#if defined(MSG_NOSIGNAL) && !defined(SO_NOSIGPIPE)
    ssize_t w = send(fd, ptr, len, MSG_NOSIGNAL);
    if (w >= 0 || errno != ENOTSOCK) return w;
#endif
    return write(fd, ptr, len);
}

static int wait_fd(int fd, short events, int64_t timeout_ms) {
    struct pollfd p;
    p.fd = fd;
    p.events = events;
    p.revents = 0;
    for (;;) {
        int n = poll(&p, 1, timeout_ms < 0 ? -1 : (int)timeout_ms);
        if (n < 0 && errno == EINTR) continue;
        return n;
    }
}

silica_sockets_tagged silica_sockets_set_args(int64_t a, int64_t b) {
    silica_sockets_arg_a = a;
    silica_sockets_arg_b = b;
    return ok(0);
}

/* States the timeout of the next TCP connect of this thread (or of the next name resolution,
   silica_sockets_tcp_listen_name), in milliseconds. Only 1 to INT_MAX is a timeout; anything else is
   EINVAL and leaves none stated. */
silica_sockets_tagged silica_sockets_set_connect_timeout(int64_t timeout_ms) {
    silica_sockets_connect_timeout_ms = 0;
    if (timeout_ms <= 0 || timeout_ms > (int64_t)INT_MAX) { errno = EINVAL; return err(); }
    silica_sockets_connect_timeout_ms = timeout_ms;
    return ok(0);
}

silica_sockets_tagged silica_sockets_set_host(const uint8_t *host_ptr, uint64_t host_len) {
    if (!copy_host(host_ptr, host_len, silica_sockets_host, sizeof silica_sockets_host)) { errno = EINVAL; return err(); }
    return ok(0);
}

/* ---- TCP ----------------------------------------------------------------------------------- */

static int64_t monotonic_ms(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) < 0) return -1;
    return (int64_t)t.tv_sec * 1000 + (int64_t)(t.tv_nsec / 1000000);
}

/* The stated connect timeout of this thread, taken: the next connect has none until one is stated again. */
static int64_t take_connect_timeout(void) {
    int64_t t = silica_sockets_connect_timeout_ms;
    silica_sockets_connect_timeout_ms = 0;
    return t;
}

/* Connects fd to addr without ever blocking in connect(): the socket is made non-blocking, the connect is
   started, and the wait for its end is a poll bounded by timeout_ms (1 to INT_MAX, checked by the callers)
   against a monotonic deadline, so signals (EINTR) cannot lengthen it. The answer is ok(fd) with the socket
   back in blocking mode (every later call on it is bounded by its own poll), timeout() when the peer did not
   answer in time, or err() with the connect's errno (ECONNREFUSED, EHOSTUNREACH, ...). fd is closed on every
   answer but ok. */
static silica_sockets_tagged connect_bounded(int fd, const struct sockaddr *addr, socklen_t addr_len, int64_t timeout_ms) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { int e = errno; close(fd); errno = e; return err(); }
    int64_t start = monotonic_ms();
    if (start < 0) { int e = errno; close(fd); errno = e; return err(); }
    if (connect(fd, addr, addr_len) < 0) {
        /* EINPROGRESS: the connect is under way. EINTR: a signal interrupted the call, and the connect goes
           on in the background all the same (POSIX); calling connect again would answer EALREADY. Both are
           waited for below. Any other errno is the connect's answer. */
        if (errno != EINPROGRESS && errno != EINTR) { int e = errno; close(fd); errno = e; return err(); }
        for (;;) {
            int64_t now = monotonic_ms();
            if (now < 0) { int e = errno; close(fd); errno = e; return err(); }
            int64_t left = timeout_ms - (now - start);
            if (left <= 0) { close(fd); return timeout(); }
            struct pollfd p;
            p.fd = fd;
            p.events = POLLOUT;
            p.revents = 0;
            int n = poll(&p, 1, (int)left);
            if (n > 0) break;
            if (n == 0) { close(fd); return timeout(); }
            if (errno != EINTR) { int e = errno; close(fd); errno = e; return err(); }
        }
        /* Writable, or an error or hang-up reported by poll: SO_ERROR says which. */
        int so_error = 0;
        socklen_t so_len = sizeof so_error;
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_error, &so_len) < 0) { int e = errno; close(fd); errno = e; return err(); }
        if (so_error != 0) { close(fd); errno = so_error; return err(); }
    }
    if (fcntl(fd, F_SETFL, flags) < 0) { int e = errno; close(fd); errno = e; return err(); }
    return ok(fd);
}

/* port: set_args a, timeout in milliseconds: set_connect_timeout (EINVAL when none was stated) */
silica_sockets_tagged silica_sockets_tcp_connect(const uint8_t *host_ptr, uint64_t host_len) {
    struct sockaddr_in addr;
    uint32_t to;
    int64_t port = silica_sockets_arg_a;
    int64_t timeout_ms = take_connect_timeout();
    if (timeout_ms <= 0) { errno = EINVAL; return err(); }
    if (!ipv4_strict(host_ptr, host_len, &to)) { errno = EINVAL; return err(); }
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(to);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return err();
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    no_sigpipe(fd);
    return connect_bounded(fd, (const struct sockaddr *)&addr, sizeof addr, timeout_ms);
}

static silica_sockets_tagged tcp_listen_on(int64_t port, uint32_t host_order_addr) {
    struct sockaddr_in addr;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return err();
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(host_order_addr);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) { int e = errno; close(fd); errno = e; return err(); }
    if (listen(fd, 16) < 0) { int e = errno; close(fd); errno = e; return err(); }
    return ok(fd);
}

/* Binds 127.0.0.1:port only: the default listener, reachable from this host alone. */
silica_sockets_tagged silica_sockets_tcp_listen(int64_t port) {
    return tcp_listen_on(port, INADDR_LOOPBACK);
}

/* Binds every IPv4 interface (INADDR_ANY, 0.0.0.0:port): the explicit wildcard form a program asks for with
   the carrier address "listen:any:<port>" when no link is declared (a declared link refuses it: links design
   §3.2, hosted Ethernet plan E2). Plain TCP with no authentication: anyone who can reach the port can connect, so the host's firewall is the
   only protection. */
silica_sockets_tagged silica_sockets_tcp_listen_any(int64_t port) {
    return tcp_listen_on(port, INADDR_ANY);
}

/* Binds one given IPv4 address (dotted quad, "10.0.0.5"): the carrier address "listen:<ipv4>:<port>", and the
   address of the interface a named link selected (silica_sockets_link_select). A text that is not a dotted quad is
   EINVAL (the strict parser, ipv4_strict); the carrier checks it first with silica_sockets_parse_ipv4 and refuses it
   with its own reason.
   port: set_args a */
silica_sockets_tagged silica_sockets_tcp_listen_addr(const uint8_t *host_ptr, uint64_t host_len) {
    uint32_t a;
    int64_t port = silica_sockets_arg_a;
    if (!ipv4_strict(host_ptr, host_len, &a)) { errno = EINVAL; return err(); }
    return tcp_listen_on(port, a);
}

/* Connects from the given local IPv4 address (host order): the source bind of a carrier on a named link, so
   the connection leaves by that interface's address (links design §3.2, decision 10).
   port: set_args a, local address: set_args b, timeout in milliseconds: set_connect_timeout (EINVAL when none
   was stated) */
silica_sockets_tagged silica_sockets_tcp_connect_from(const uint8_t *host_ptr, uint64_t host_len) {
    struct sockaddr_in addr;
    struct sockaddr_in local;
    uint32_t to;
    int64_t port = silica_sockets_arg_a;
    uint32_t from = (uint32_t)silica_sockets_arg_b;
    int64_t timeout_ms = take_connect_timeout();
    if (timeout_ms <= 0) { errno = EINVAL; return err(); }
    if (!ipv4_strict(host_ptr, host_len, &to)) { errno = EINVAL; return err(); }
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(to);
    memset(&local, 0, sizeof local);
    local.sin_family = AF_INET;
    local.sin_port = 0;
    local.sin_addr.s_addr = htonl(from);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return err();
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    no_sigpipe(fd);
    if (bind(fd, (struct sockaddr *)&local, sizeof local) < 0) { int e = errno; close(fd); errno = e; return err(); }
    return connect_bounded(fd, (const struct sockaddr *)&addr, sizeof addr, timeout_ms);
}

/* A dotted-quad IPv4 text as its address in host order (value), or EINVAL (ipv4_strict): the check a carrier makes
   of every address text before anything is bound or dialled ("listen:<ipv4>:<port>", a dial host, a UDP peer and
   a UDP local address), so a malformed one ends the carrier (:explicit, :bad_address). */
silica_sockets_tagged silica_sockets_parse_ipv4(const uint8_t *host_ptr, uint64_t host_len) {
    uint32_t a;
    if (!ipv4_strict(host_ptr, host_len, &a)) { errno = EINVAL; return err(); }
    return ok((int64_t)a);
}

/* An IPv6 text as an address a carrier can bind or dial: the canonical text (ipv6_strict) of an address that is
   not link-local. A link-local address (fe80::/10) means something only together with its interface (its zone),
   which the address forms do not carry, so it is refused here with the malformed ones. */
static int ipv6_usable(const uint8_t *s, uint64_t n, uint16_t g[8]) {
    return ipv6_strict(s, n, g) && !ipv6_is_link_local(g);
}

/* The same check for an IPv6 text (ipv6_usable; the text is the address alone, without the brackets a carrier
   address writes around it): EINVAL when it is not the canonical text of an address or the address is link-local,
   else value 1 for the loopback address ::1 and 0 for every other address, which is all a carrier's link rules
   ask of it. */
silica_sockets_tagged silica_sockets_parse_ipv6(const uint8_t *host_ptr, uint64_t host_len) {
    uint16_t g[8];
    if (!ipv6_usable(host_ptr, host_len, g)) { errno = EINVAL; return err(); }
    return ok(ipv6_is_loopback(g) ? 1 : 0);
}

/* The check of a host name before it is resolved (host_name_strict): value 0, or EINVAL. */
silica_sockets_tagged silica_sockets_parse_host_name(const uint8_t *host_ptr, uint64_t host_len) {
    if (!host_name_strict(host_ptr, host_len)) { errno = EINVAL; return err(); }
    return ok(0);
}

/* ---- links: the interface a carrier binds to (transport_links_design.md §3.2) ------------------- */

/* The interface the last silica_sockets_link_select of this thread chose. */
static __thread char silica_sockets_link_ifname[IFNAMSIZ + 1] = "";

#define SILICA_LINK_BY_NAME 0
#define SILICA_LINK_ETHERNET 1
#define SILICA_LINK_WIFI 2

/* The family the OS gives an interface: SILICA_LINK_ETHERNET for wired, SILICA_LINK_WIFI for wireless, 0 for any
   other (loopback, tunnels, bridges, virtual interfaces, cellular). macOS answers with the interface's functional
   type (SIOCGIFFUNCTIONALTYPE, the "type:" line of ifconfig -v). Linux answers through sysfs: a wireless
   interface has /sys/class/net/<if>/wireless (or phy80211); a wired one has ARPHRD_ETHER (type 1) and a
   backing device (/sys/class/net/<if>/device), which leaves out bridges, veth pairs and other virtual links. */
static int link_family_of(const char *name) {
#if defined(__APPLE__)
    struct ifreq ifr;
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return 0;
    memset(&ifr, 0, sizeof ifr);
    strncpy(ifr.ifr_name, name, sizeof ifr.ifr_name - 1);
    int rc = ioctl(s, SIOCGIFFUNCTIONALTYPE, &ifr);
    close(s);
    if (rc < 0) return 0;
    switch (ifr.ifr_ifru.ifru_functional_type) {
        case IFRTYPE_FUNCTIONAL_WIRED: return SILICA_LINK_ETHERNET;
        case IFRTYPE_FUNCTIONAL_WIFI_INFRA: return SILICA_LINK_WIFI;
        default: return 0;
    }
#elif defined(__linux__)
    char path[96];
    char text[16];
    snprintf(path, sizeof path, "/sys/class/net/%s/wireless", name);
    if (access(path, F_OK) == 0) return SILICA_LINK_WIFI;
    snprintf(path, sizeof path, "/sys/class/net/%s/phy80211", name);
    if (access(path, F_OK) == 0) return SILICA_LINK_WIFI;
    snprintf(path, sizeof path, "/sys/class/net/%s/device", name);
    if (access(path, F_OK) != 0) return 0;
    snprintf(path, sizeof path, "/sys/class/net/%s/type", name);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    ssize_t n = read(fd, text, sizeof text - 1);
    close(fd);
    if (n <= 0) return 0;
    text[n] = 0;
    return atoi(text) == 1 ? SILICA_LINK_ETHERNET : 0;
#else
    (void)name;
    return 0;
#endif
}

/* Whether name already appears among the IPv4 entries before stop in the getifaddrs list: an interface with
   several IPv4 addresses is counted once, at its first. */
static int link_seen_before(struct ifaddrs *list, struct ifaddrs *stop, const char *name) {
    for (struct ifaddrs *p = list; p != 0 && p != stop; p = p->ifa_next) {
        if (p->ifa_addr != 0 && p->ifa_addr->sa_family == AF_INET && p->ifa_name != 0 && strcmp(p->ifa_name, name) == 0) return 1;
    }
    return 0;
}

/* Chooses the interface of a link for this thread and answers its first IPv4 address in host order (value).
   family: set_args a (0 by name, 1 ethernet, 2 wifi), instance: set_args b (the n of (:ethernet, n) and
   (:wifi, n), counting from 0 in interface enumeration order); name: the interface name, read only for
   family 0. Only interfaces holding an IPv4 address are counted, since an address is what the carrier binds.
   ENXIO when the interface is absent, has no IPv4 address, or fewer than n+1 of the family hold one: the
   carrier then ends with (:explicit, :link_unavailable). */
silica_sockets_tagged silica_sockets_link_select(const uint8_t *name_ptr, uint64_t name_len) {
    char want[IFNAMSIZ + 1];
    int64_t family = silica_sockets_arg_a;
    int64_t instance = silica_sockets_arg_b;
    struct ifaddrs *list = 0;
    int64_t seen = 0;
    silica_sockets_link_ifname[0] = 0;
    if (family == SILICA_LINK_BY_NAME && !copy_host(name_ptr, name_len, want, sizeof want)) { errno = ENXIO; return err(); }
    if (getifaddrs(&list) < 0) return err();
    for (struct ifaddrs *p = list; p != 0; p = p->ifa_next) {
        if (p->ifa_addr == 0 || p->ifa_addr->sa_family != AF_INET || p->ifa_name == 0) continue;
        int match = 0;
        if (family == SILICA_LINK_BY_NAME) {
            match = strcmp(p->ifa_name, want) == 0;
        } else if ((p->ifa_flags & IFF_LOOPBACK) == 0 && !link_seen_before(list, p, p->ifa_name) && link_family_of(p->ifa_name) == family) {
            match = seen == instance;
            seen = seen + 1;
        }
        if (match && strlen(p->ifa_name) <= IFNAMSIZ) {
            uint32_t a = ntohl(((struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr);
            memcpy(silica_sockets_link_ifname, p->ifa_name, strlen(p->ifa_name) + 1);
            freeifaddrs(list);
            return ok((int64_t)a);
        }
    }
    freeifaddrs(list);
    errno = ENXIO;
    return err();
}

/* 1 when the interface the last silica_sockets_link_select chose holds the IPv4 address addr (host order),
   else 0: the check that a "listen:<ipv4>:<port>" under a named link names that interface's address. */
silica_sockets_tagged silica_sockets_link_owns(int64_t addr) {
    struct ifaddrs *list = 0;
    int64_t found = 0;
    if (silica_sockets_link_ifname[0] == 0) return ok(0);
    if (getifaddrs(&list) < 0) return err();
    for (struct ifaddrs *p = list; p != 0; p = p->ifa_next) {
        if (p->ifa_addr == 0 || p->ifa_addr->sa_family != AF_INET || p->ifa_name == 0) continue;
        if (strcmp(p->ifa_name, silica_sockets_link_ifname) != 0) continue;
        if (ntohl(((struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr) == (uint32_t)addr) { found = 1; break; }
    }
    freeifaddrs(list);
    return ok(found);
}

/* Whether the interface the last silica_sockets_link_select chose holds the IPv6 address g. */
static int link_holds_ipv6(const uint16_t g[8]) {
    struct ifaddrs *list = 0;
    int found = 0;
    if (silica_sockets_link_ifname[0] == 0) return 0;
    if (getifaddrs(&list) < 0) return 0;
    for (struct ifaddrs *p = list; p != 0; p = p->ifa_next) {
        uint16_t h[8];
        if (p->ifa_addr == 0 || p->ifa_addr->sa_family != AF_INET6 || p->ifa_name == 0) continue;
        if (strcmp(p->ifa_name, silica_sockets_link_ifname) != 0) continue;
        ipv6_groups_of(&((struct sockaddr_in6 *)p->ifa_addr)->sin6_addr, h);
        if (memcmp(h, g, sizeof h) == 0) { found = 1; break; }
    }
    freeifaddrs(list);
    return found;
}

static int link_holds_ipv4(uint32_t host_order_addr) {
    silica_sockets_tagged r = silica_sockets_link_owns((int64_t)host_order_addr);
    return r.tag == 0 && r.value == 1;
}

/* The first IPv6 address of the link's interface that is not link-local: where a connection to an IPv6 peer
   leaves from under a named link. 0 when the interface holds none. */
static int link_first_ipv6(uint16_t g[8]) {
    struct ifaddrs *list = 0;
    int found = 0;
    if (silica_sockets_link_ifname[0] == 0) return 0;
    if (getifaddrs(&list) < 0) return 0;
    for (struct ifaddrs *p = list; p != 0; p = p->ifa_next) {
        if (p->ifa_addr == 0 || p->ifa_addr->sa_family != AF_INET6 || p->ifa_name == 0) continue;
        if (strcmp(p->ifa_name, silica_sockets_link_ifname) != 0) continue;
        ipv6_groups_of(&((struct sockaddr_in6 *)p->ifa_addr)->sin6_addr, g);
        if (ipv6_is_link_local(g)) continue;
        found = 1;
        break;
    }
    freeifaddrs(list);
    return found;
}

/* 1 when the interface the last silica_sockets_link_select chose holds the IPv6 address the text names, else 0
   (EINVAL when the text is not an address): the check that a "listen:[<ipv6>]:<port>" under a named link names
   one of that interface's addresses. */
silica_sockets_tagged silica_sockets_link_owns6(const uint8_t *host_ptr, uint64_t host_len) {
    uint16_t g[8];
    if (!ipv6_usable(host_ptr, host_len, g)) { errno = EINVAL; return err(); }
    return ok(link_holds_ipv6(g) ? 1 : 0);
}

/* ---- TCP over IPv6, and a listener bound by name ---------------------------------------------- */

/* Binds and listens on one address of either family. An IPv6 socket is IPV6_V6ONLY on every host (the default
   differs between them), so "::" is every IPv6 interface and never IPv4 as well. */
static silica_sockets_tagged tcp_listen_sockaddr(const struct sockaddr *addr, socklen_t addr_len) {
    int fd = socket(addr->sa_family, SOCK_STREAM, 0);
    if (fd < 0) return err();
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (addr->sa_family == AF_INET6 && setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one) < 0) { int e = errno; close(fd); errno = e; return err(); }
    if (bind(fd, addr, addr_len) < 0) { int e = errno; close(fd); errno = e; return err(); }
    if (listen(fd, 16) < 0) { int e = errno; close(fd); errno = e; return err(); }
    return ok(fd);
}

/* Binds one given IPv6 address (canonical text, "2001:db8::5", "::1"; "::" is every IPv6 interface): the carrier
   address "listen:[<ipv6>]:<port>". A text that is not one, or a link-local address, is EINVAL (ipv6_usable); the
   carrier checks it first with silica_sockets_parse_ipv6.
   port: set_args a */
silica_sockets_tagged silica_sockets_tcp_listen_addr6(const uint8_t *host_ptr, uint64_t host_len) {
    struct sockaddr_in6 addr;
    uint16_t g[8];
    int64_t port = silica_sockets_arg_a;
    if (!ipv6_usable(host_ptr, host_len, g)) { errno = EINVAL; return err(); }
    ipv6_sockaddr(&addr, g, port);
    return tcp_listen_sockaddr((const struct sockaddr *)&addr, sizeof addr);
}

/* Connects to an IPv6 peer (canonical text, not link-local: ipv6_usable): the carrier address
   "[<ipv6>]:<port>:<timeout_ms>". Under a named link (use_link 1, after silica_sockets_link_select) the connection
   leaves by the link's interface: it is dialled from the interface's first IPv6 address that is not link-local
   (ENXIO when it holds none).
   port: set_args a, use_link: set_args b, timeout in milliseconds: set_connect_timeout (EINVAL when none was
   stated) */
silica_sockets_tagged silica_sockets_tcp_connect6(const uint8_t *host_ptr, uint64_t host_len) {
    struct sockaddr_in6 addr;
    struct sockaddr_in6 local;
    uint16_t g[8];
    uint16_t from[8];
    int64_t port = silica_sockets_arg_a;
    int bind_source = silica_sockets_arg_b == 1;
    int64_t timeout_ms = take_connect_timeout();
    if (timeout_ms <= 0) { errno = EINVAL; return err(); }
    if (!ipv6_usable(host_ptr, host_len, g)) { errno = EINVAL; return err(); }
    if (bind_source && !link_first_ipv6(from)) { errno = ENXIO; return err(); }
    ipv6_sockaddr(&addr, g, port);
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) return err();
    int one = 1;
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    no_sigpipe(fd);
    if (bind_source) {
        ipv6_sockaddr(&local, from, 0);
        if (bind(fd, (struct sockaddr *)&local, sizeof local) < 0) { int e = errno; close(fd); errno = e; return err(); }
    }
    return connect_bounded(fd, (const struct sockaddr *)&addr, sizeof addr, timeout_ms);
}

/* One resolution of a host name, made by a helper thread so that the caller's wait can end at its timeout
   (getaddrinfo itself cannot be bounded). The helper closes wfd when it has finished, which wakes the caller's
   poll. Whoever is last frees the job: the caller when the helper finished in time, the helper when the caller
   gave up (abandoned). */
struct resolve_job {
    pthread_mutex_t lock;
    int done;
    int abandoned;
    int rc;
    struct addrinfo *found;
    int wfd;
    char name[256];
};

static void *resolve_main(void *arg) {
    struct resolve_job *job = (struct resolve_job *)arg;
    struct addrinfo hints;
    struct addrinfo *found = 0;
    int wfd = job->wfd;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int rc = getaddrinfo(job->name, 0, &hints, &found);
    pthread_mutex_lock(&job->lock);
    int abandoned = job->abandoned;
    job->rc = rc;
    job->found = rc == 0 ? found : 0;
    job->done = 1;
    pthread_mutex_unlock(&job->lock);
    if (abandoned) {
        if (rc == 0 && found != 0) freeaddrinfo(found);
        pthread_mutex_destroy(&job->lock);
        free(job);
    }
    close(wfd);
    return 0;
}

/* Whether a resolved address may be bound under the link rule: 0 any address, 1 loopback addresses only
   (127.0.0.0/8 and ::1, the (:loopback) link), 2 addresses of the named link's interface only. A link-local IPv6
   address is never bound (ipv6_usable). */
static int link_rule_allows(const struct sockaddr *sa, int64_t rule) {
    if (sa->sa_family == AF_INET) {
        uint32_t a = ntohl(((const struct sockaddr_in *)sa)->sin_addr.s_addr);
        if (rule == 1) return (a >> 24) == 127;
        if (rule == 2) return link_holds_ipv4(a);
        return 1;
    }
    if (sa->sa_family == AF_INET6) {
        uint16_t g[8];
        ipv6_groups_of(&((const struct sockaddr_in6 *)sa)->sin6_addr, g);
        if (ipv6_is_link_local(g)) return 0;
        if (rule == 1) return ipv6_is_loopback(g);
        if (rule == 2) return link_holds_ipv6(g);
        return 1;
    }
    return 0;
}

/* Binds the address a host name resolves to: the carrier address "listen:name:<name>:<port>:<timeout_ms>". The
   name (host_name_strict, else EINVAL) is resolved once, now, by the system resolver (getaddrinfo: the hosts
   file, mDNS, DNS, as the host is configured), waiting at most the stated timeout: tag 2 when the resolver has
   not answered by then. Its addresses are taken in the order the resolver gives them, IPv4 and IPv6 alike; those
   the link rule does not allow are passed over, and the listener is bound to the first that binds, one address
   and one socket. ENXIO when the name does not resolve or none of its addresses is allowed; otherwise the errno
   of the last bind that failed (EADDRNOTAVAIL for an address that is not this host's).
   port: set_args a, link rule (link_rule_allows): set_args b, timeout in milliseconds: set_connect_timeout
   (EINVAL when none was stated) */
silica_sockets_tagged silica_sockets_tcp_listen_name(const uint8_t *host_ptr, uint64_t host_len) {
    int64_t port = silica_sockets_arg_a;
    int64_t rule = silica_sockets_arg_b;
    int64_t timeout_ms = take_connect_timeout();
    int pipe_fds[2];
    pthread_t helper;
    pthread_attr_t attr;
    if (timeout_ms <= 0) { errno = EINVAL; return err(); }
    if (!host_name_strict(host_ptr, host_len)) { errno = EINVAL; return err(); }
    struct resolve_job *job = (struct resolve_job *)calloc(1, sizeof *job);
    if (job == 0) { errno = ENOMEM; return err(); }
    memcpy(job->name, host_ptr, (size_t)host_len);
    job->name[host_len] = 0;
    if (pipe(pipe_fds) < 0) { int e = errno; free(job); errno = e; return err(); }
    job->wfd = pipe_fds[1];
    pthread_mutex_init(&job->lock, 0);
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int started = pthread_create(&helper, &attr, resolve_main, job);
    pthread_attr_destroy(&attr);
    if (started != 0) {
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        pthread_mutex_destroy(&job->lock);
        free(job);
        errno = started;
        return err();
    }
    /* The wait: the helper closes its end of the pipe when it has finished, against a monotonic deadline. */
    int64_t start = monotonic_ms();
    for (;;) {
        int64_t now = monotonic_ms();
        int64_t left = (start < 0 || now < 0) ? 0 : timeout_ms - (now - start);
        if (left <= 0) break;
        struct pollfd p;
        p.fd = pipe_fds[0];
        p.events = POLLIN;
        p.revents = 0;
        int n = poll(&p, 1, (int)left);
        if (n > 0) break;
        if (n < 0 && errno != EINTR) break;
    }
    close(pipe_fds[0]);
    pthread_mutex_lock(&job->lock);
    if (!job->done) {
        job->abandoned = 1;
        pthread_mutex_unlock(&job->lock);
        return timeout();
    }
    int rc = job->rc;
    struct addrinfo *found = job->found;
    pthread_mutex_unlock(&job->lock);
    pthread_mutex_destroy(&job->lock);
    free(job);
    if (rc != 0 || found == 0) { errno = ENXIO; return err(); }
    silica_sockets_tagged answer = {1, 0, (int64_t)ENXIO};
    for (struct addrinfo *a = found; a != 0; a = a->ai_next) {
        struct sockaddr_storage addr;
        if (a->ai_addr == 0 || a->ai_addrlen > sizeof addr) continue;
        if (!link_rule_allows(a->ai_addr, rule)) continue;
        memcpy(&addr, a->ai_addr, a->ai_addrlen);
        if (addr.ss_family == AF_INET) ((struct sockaddr_in *)&addr)->sin_port = htons((uint16_t)port);
        else ((struct sockaddr_in6 *)&addr)->sin6_port = htons((uint16_t)port);
        answer = tcp_listen_sockaddr((const struct sockaddr *)&addr, a->ai_addrlen);
        if (answer.tag == 0) break;
    }
    freeaddrinfo(found);
    return answer;
}

/* The peer of a connected descriptor: its IPv4 address in host order (silica_sockets_peer_addr; EAFNOSUPPORT for
   an IPv6 peer) and its port (silica_sockets_peer_port, either family), so a listener reports who connected
   ("peer:<ipv4>:<port>"). */
silica_sockets_tagged silica_sockets_peer_addr(int64_t fd) {
    struct sockaddr_storage addr;
    socklen_t n = sizeof addr;
    if (getpeername((int)fd, (struct sockaddr *)&addr, &n) < 0) return err();
    if (addr.ss_family != AF_INET) { errno = EAFNOSUPPORT; return err(); }
    return ok((int64_t)ntohl(((struct sockaddr_in *)&addr)->sin_addr.s_addr));
}

silica_sockets_tagged silica_sockets_peer_port(int64_t fd) {
    struct sockaddr_storage addr;
    socklen_t n = sizeof addr;
    if (getpeername((int)fd, (struct sockaddr *)&addr, &n) < 0) return err();
    if (addr.ss_family == AF_INET) return ok((int64_t)ntohs(((struct sockaddr_in *)&addr)->sin_port));
    if (addr.ss_family == AF_INET6) return ok((int64_t)ntohs(((struct sockaddr_in6 *)&addr)->sin6_port));
    errno = EAFNOSUPPORT;
    return err();
}

/* The family of the peer of a connected descriptor: 4 for IPv4 (silica_sockets_peer_addr then answers its
   address), 6 for IPv6 (silica_sockets_peer_addr6_word answers it). */
silica_sockets_tagged silica_sockets_peer_family(int64_t fd) {
    struct sockaddr_storage addr;
    socklen_t n = sizeof addr;
    if (getpeername((int)fd, (struct sockaddr *)&addr, &n) < 0) return err();
    if (addr.ss_family == AF_INET) return ok(4);
    if (addr.ss_family == AF_INET6) return ok(6);
    errno = EAFNOSUPPORT;
    return err();
}

/* One 32-bit word of the IPv6 address of the peer of a connected descriptor: word 0 is its first two groups,
   word 3 its last two, each 0 to 4294967295. The address crosses to the carrier as numbers, as an IPv4 peer's
   does, and the carrier writes its canonical text ("peer:[<ipv6>]:<port>"). EAFNOSUPPORT for a peer that is not
   IPv6, EINVAL for a word outside 0 to 3. */
silica_sockets_tagged silica_sockets_peer_addr6_word(int64_t fd, int64_t word) {
    struct sockaddr_storage addr;
    socklen_t n = sizeof addr;
    if (word < 0 || word > 3) { errno = EINVAL; return err(); }
    if (getpeername((int)fd, (struct sockaddr *)&addr, &n) < 0) return err();
    if (addr.ss_family != AF_INET6) { errno = EAFNOSUPPORT; return err(); }
    const uint8_t *b = ((struct sockaddr_in6 *)&addr)->sin6_addr.s6_addr + 4 * word;
    return ok(((int64_t)b[0] << 24) | ((int64_t)b[1] << 16) | ((int64_t)b[2] << 8) | (int64_t)b[3]);
}

/* The port a listener was given 0 for: the one the system chose. */
silica_sockets_tagged silica_sockets_local_port(int64_t fd) {
    struct sockaddr_storage addr;
    socklen_t n = sizeof addr;
    if (getsockname((int)fd, (struct sockaddr *)&addr, &n) < 0) return err();
    if (addr.ss_family == AF_INET6) return ok((int64_t)ntohs(((struct sockaddr_in6 *)&addr)->sin6_port));
    return ok((int64_t)ntohs(((struct sockaddr_in *)&addr)->sin_port));
}

silica_sockets_tagged silica_sockets_tcp_accept(int64_t fd, int64_t timeout_ms) {
    int n = wait_fd((int)fd, POLLIN, timeout_ms);
    if (n < 0) return err();
    if (n == 0) return timeout();
    int c = accept((int)fd, 0, 0);
    if (c < 0) return err();
    int one = 1;
    setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    no_sigpipe(c);
    return ok(c);
}

/* ---- UDP ----------------------------------------------------------------------------------- */

/* Binds a datagram socket to one local IPv4 address (host order) and port: 0x7f000001 (127.0.0.1) for the
   default endpoint, 0 (INADDR_ANY) for "any:<port>", a literal address, or the address of the interface a named
   link selected (silica_sockets_link_select). Every datagram the socket sends then leaves from that address, so
   a carrier on a named link needs no separate source bind (links design §3.2, hosted Ethernet plan E2). */
silica_sockets_tagged silica_sockets_udp_bind_on(int64_t port, int64_t host_order_addr) {
    struct sockaddr_in addr;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return err();
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl((uint32_t)host_order_addr);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) { int e = errno; close(fd); errno = e; return err(); }
    return ok(fd);
}

/* Binds 127.0.0.1:port only. */
silica_sockets_tagged silica_sockets_udp_bind(int64_t port) {
    return silica_sockets_udp_bind_on(port, (int64_t)INADDR_LOOPBACK);
}

/* fd: set_args a, port: set_args b, host: set_host */
silica_sockets_tagged silica_sockets_udp_send(const uint8_t *data_ptr, uint64_t data_len) {
    struct sockaddr_in addr;
    int64_t fd = silica_sockets_arg_a;
    int64_t port = silica_sockets_arg_b;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    uint32_t to;
    if (!ipv4_strict_text(silica_sockets_host, &to)) { errno = EINVAL; return err(); }
    addr.sin_addr.s_addr = htonl(to);
    ssize_t n = sendto((int)fd, data_ptr, (size_t)data_len, 0, (struct sockaddr *)&addr, sizeof addr);
    if (n < 0) return err();
    return ok((int64_t)n);
}

silica_sockets_tagged silica_sockets_udp_recv(int64_t fd, int64_t max, int64_t timeout_ms) {
    int n = wait_fd((int)fd, POLLIN, timeout_ms);
    if (n < 0) return err();
    if (n == 0) return timeout();
    size_t cap = (max > 0 && max < SILICA_SOCKETS_BUF) ? (size_t)max : SILICA_SOCKETS_BUF;
    ssize_t got = recvfrom((int)fd, silica_sockets_rx, cap, 0, 0, 0);
    if (got < 0) return err();
    silica_sockets_rx_len = (uint64_t)got;
    return ok((int64_t)got);
}

/* ---- serial ---------------------------------------------------------------------------------- */

static speed_t baud_of(int64_t baud) {
    switch (baud) {
        case 9600: return B9600;
        case 19200: return B19200;
        case 38400: return B38400;
        case 57600: return B57600;
        case 115200: return B115200;
        case 230400: return B230400;
        default: return B115200;
    }
}

/* baud: set_args a */
silica_sockets_tagged silica_sockets_serial_open(const uint8_t *path_ptr, uint64_t path_len) {
    char path[512];
    struct termios tio;
    int64_t baud = silica_sockets_arg_a;
    if (!copy_host(path_ptr, path_len, path, sizeof path)) { errno = EINVAL; return err(); }
    int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) return err();
    if (tcgetattr(fd, &tio) < 0) { int e = errno; close(fd); errno = e; return err(); }
    cfmakeraw(&tio);
    cfsetispeed(&tio, baud_of(baud));
    cfsetospeed(&tio, baud_of(baud));
    tio.c_cflag |= (CLOCAL | CREAD);
    tio.c_cc[VMIN] = 0;
    tio.c_cc[VTIME] = 0;
    if (tcsetattr(fd, TCSANOW, &tio) < 0) { int e = errno; close(fd); errno = e; return err(); }
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
    return ok(fd);
}

/* ---- any descriptor ---------------------------------------------------------------------------- */

/* Writes the whole buffer, waiting up to timeout_ms for each piece the descriptor accepts.
   fd: set_args a, timeout_ms: set_args b */
silica_sockets_tagged silica_sockets_send(const uint8_t *data_ptr, uint64_t data_len) {
    int64_t fd = silica_sockets_arg_a;
    int64_t timeout_ms = silica_sockets_arg_b;
    uint64_t done = 0;
    while (done < data_len) {
        int n = wait_fd((int)fd, POLLOUT, timeout_ms);
        if (n < 0) return err();
        if (n == 0) return timeout();
        ssize_t w = write_no_sigpipe((int)fd, data_ptr + done, (size_t)(data_len - done));
        if (w < 0) { if (errno == EINTR || errno == EAGAIN) continue; return err(); }
        done += (uint64_t)w;
    }
    return ok((int64_t)done);
}

/* Reads up to max bytes into the thread's buffer; value is the count. 0 bytes on a stream means the
   peer closed (tag 3). */
silica_sockets_tagged silica_sockets_recv(int64_t fd, int64_t max, int64_t timeout_ms) {
    int n = wait_fd((int)fd, POLLIN, timeout_ms);
    if (n < 0) return err();
    if (n == 0) return timeout();
    size_t cap = (max > 0 && max < SILICA_SOCKETS_BUF) ? (size_t)max : SILICA_SOCKETS_BUF;
    ssize_t got = read((int)fd, silica_sockets_rx, cap);
    if (got < 0) { if (errno == EAGAIN) return timeout(); return err(); }
    silica_sockets_rx_len = (uint64_t)got;
    if (got == 0) return closed();
    return ok((int64_t)got);
}

/* The bytes of the last receive on this thread, as the compiler's pointer-plus-length string form:
   a malloc'd span, which the compiler's string-out helper copies into a Silica string and frees. */
silica_sockets_bytes silica_sockets_take(int64_t fd) {
    silica_sockets_bytes r;
    (void)fd;
    r.tag = 0;
    r.text_ptr = 0;
    r.text_len = 0;
    r.error_code = 0;
    if (silica_sockets_rx_len > 0) {
        uint8_t *span = (uint8_t *)malloc(silica_sockets_rx_len);
        if (span == 0) { r.tag = 1; r.error_code = ENOMEM; return r; }
        memcpy(span, silica_sockets_rx, silica_sockets_rx_len);
        r.text_ptr = span;
        r.text_len = silica_sockets_rx_len;
    }
    return r;
}

silica_sockets_tagged silica_sockets_close(int64_t fd) {
    if (close((int)fd) < 0) return err();
    return ok(0);
}
