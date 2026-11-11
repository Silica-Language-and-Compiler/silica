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
    char host[256];
    struct sockaddr_in addr;
    int64_t port = silica_sockets_arg_a;
    if (!copy_host(host_ptr, host_len, host, sizeof host)) { errno = EINVAL; return err(); }
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) { errno = EINVAL; return err(); }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return err();
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
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
   the carrier address "listen:any:<port>", until interface binding ((:interface, name), links design) exists.
   Plain TCP with no authentication: anyone who can reach the port can connect, so the host's firewall is the
   only protection. */
silica_sockets_tagged silica_sockets_tcp_listen_any(int64_t port) {
    return tcp_listen_on(port, INADDR_ANY);
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
    return ok(c);
}

/* ---- UDP ----------------------------------------------------------------------------------- */

silica_sockets_tagged silica_sockets_udp_bind(int64_t port) {
    struct sockaddr_in addr;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return err();
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) { int e = errno; close(fd); errno = e; return err(); }
    return ok(fd);
}

/* fd: set_args a, port: set_args b, host: set_host */
silica_sockets_tagged silica_sockets_udp_send(const uint8_t *data_ptr, uint64_t data_len) {
    struct sockaddr_in addr;
    int64_t fd = silica_sockets_arg_a;
    int64_t port = silica_sockets_arg_b;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, silica_sockets_host, &addr.sin_addr) != 1) { errno = EINVAL; return err(); }
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
        ssize_t w = write((int)fd, data_ptr + done, (size_t)(data_len - done));
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
