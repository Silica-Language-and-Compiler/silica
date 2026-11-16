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
   never blocks its thread for long.

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
#include <termios.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <ifaddrs.h>
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

silica_sockets_tagged silica_sockets_set_host(const uint8_t *host_ptr, uint64_t host_len) {
    if (!copy_host(host_ptr, host_len, silica_sockets_host, sizeof silica_sockets_host)) { errno = EINVAL; return err(); }
    return ok(0);
}

/* ---- TCP ----------------------------------------------------------------------------------- */

/* port: set_args a */
silica_sockets_tagged silica_sockets_tcp_connect(const uint8_t *host_ptr, uint64_t host_len) {
    struct sockaddr_in addr;
    uint32_t to;
    int64_t port = silica_sockets_arg_a;
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
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) { int e = errno; close(fd); errno = e; return err(); }
    return ok(fd);
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
   port: set_args a, local address: set_args b */
silica_sockets_tagged silica_sockets_tcp_connect_from(const uint8_t *host_ptr, uint64_t host_len) {
    struct sockaddr_in addr;
    struct sockaddr_in local;
    uint32_t to;
    int64_t port = silica_sockets_arg_a;
    uint32_t from = (uint32_t)silica_sockets_arg_b;
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
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) { int e = errno; close(fd); errno = e; return err(); }
    return ok(fd);
}

/* A dotted-quad IPv4 text as its address in host order (value), or EINVAL (ipv4_strict): the check a carrier makes
   of every address text before anything is bound or dialled ("listen:<ipv4>:<port>", a dial host, a UDP peer and
   a UDP local address), so a malformed one ends the carrier (:explicit, :bad_address). */
silica_sockets_tagged silica_sockets_parse_ipv4(const uint8_t *host_ptr, uint64_t host_len) {
    uint32_t a;
    if (!ipv4_strict(host_ptr, host_len, &a)) { errno = EINVAL; return err(); }
    return ok((int64_t)a);
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

/* The peer of a connected descriptor: its IPv4 address in host order (silica_sockets_peer_addr) and its port
   (silica_sockets_peer_port), so a listener reports who connected ("peer:<ipv4>:<port>"). */
silica_sockets_tagged silica_sockets_peer_addr(int64_t fd) {
    struct sockaddr_in addr;
    socklen_t n = sizeof addr;
    if (getpeername((int)fd, (struct sockaddr *)&addr, &n) < 0) return err();
    if (addr.sin_family != AF_INET) { errno = EAFNOSUPPORT; return err(); }
    return ok((int64_t)ntohl(addr.sin_addr.s_addr));
}

silica_sockets_tagged silica_sockets_peer_port(int64_t fd) {
    struct sockaddr_in addr;
    socklen_t n = sizeof addr;
    if (getpeername((int)fd, (struct sockaddr *)&addr, &n) < 0) return err();
    if (addr.sin_family != AF_INET) { errno = EAFNOSUPPORT; return err(); }
    return ok((int64_t)ntohs(addr.sin_port));
}

/* The port a listener was given 0 for: the one the system chose. */
silica_sockets_tagged silica_sockets_local_port(int64_t fd) {
    struct sockaddr_in addr;
    socklen_t n = sizeof addr;
    if (getsockname((int)fd, (struct sockaddr *)&addr, &n) < 0) return err();
    return ok((int64_t)ntohs(addr.sin_port));
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
