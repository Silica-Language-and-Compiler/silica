/*
   Copyright 2026 COPYRIGHT-HOLDER-PLACEHOLDER (to be decided before this is merged)

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

/* The socket wrappers of compiler/stdlib/net/silica_sockets.c for the ESP32-S3, over lwIP and
   Espressif's Wi-Fi station (transport_ble_plan.md stage 12, part 8): the same symbols with the same
   answers, so that the hosted (:tcp) carrier (compiler/stdlib/dangerous_tcp_carrier.silica) and its
   module dangerous_sockets run on the board as they are. A program declares
   `carried_on lan: (:tcp) (:wifi, 0);` and the carrier binds to the station's address as it binds to
   an interface's on a host.

   Every answer is { tag, value, error_code }: tag 0 ok, 1 error (lwIP's errno in error_code), 2
   timeout, 3 closed by the peer.

   The link. silica_sockets_link_select answers for the family Wi-Fi, instance 0, and for nothing
   else: the station's IPv4 address, or ENXIO while the station has none, which the carrier turns
   into (:link_down, :fault) and (:explicit, :link_unavailable). The first call starts the station;
   a task of this wrapper's then joins the access point, has lwIP ask for an address, and joins again
   when the access point is lost, so the link becomes available without another call. A program
   retries as it would on a host whose interface is down: by its supervisor, or by opening again.
   The access point's name and passphrase are compiled in from wifi_secret.h, a file the build script
   writes from one kept out of git (SILICA_WIFI_SSID, SILICA_WIFI_PASSPHRASE).

   Differences from the hosted wrapper:
     - one buffer and one set of arguments, not one a thread: a board's foreign calls are made one
       at a time;
     - a receive takes at most RX_MAX bytes, whatever the caller allows;
     - silica_sockets_take answers the wrapper's own buffer (the board's string-out copies it and
       frees nothing);
     - the station has no IPv6 address: an IPv6 dial from the link (set_args b 1) is ENXIO, and
       silica_sockets_link_owns6 answers 0 for every address; IPv6 sockets themselves are lwIP's, so
       "[::1]" works as lwIP's loopback interface allows;
     - no resolver: silica_sockets_tcp_listen_name checks its arguments as the hosted wrapper does,
       then answers ENXIO (the carrier's (:link_down, :fault), (:explicit, :link_unavailable)), as a
       host whose resolver knows no name;
     - UDP and the serial port are not here (ENOSYS).

   The address checks (ipv4_strict, ipv6_strict and ipv6_render, host_name_strict) are the hosted
   wrapper's, copied unchanged, so that a carrier address is accepted or refused alike on every
   target. The connect timeout is the hosted wrapper's too: silica_sockets_set_connect_timeout states
   it for the next connect, which refuses with EINVAL when none was stated.

   Outside this file: spike_wifi_event (the station's events, kept by wifi_shim.c where ESP-IDF's
   event loop would deliver them) and spike_net_start, spike_net_address (wifi_net.c, in place of
   ESP-IDF's esp_netif), and spike_coex_start (hci_shim.c: the coexistence library prepared once,
   before either radio). All are route R1's; on a guest of ESP-IDF they would be ESP-IDF's own. */

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/sockets.h"
#include "lwip/inet.h"
#include "wifi_secret.h"

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

int spike_wifi_event(int32_t *id, uint8_t data[48]);
void spike_net_core(void);
int spike_net_start(void);
uint32_t spike_net_address(void);
void spike_coex_start(void);
int psa_crypto_init(void);

#define RX_MAX 4096
#define LINK_WIFI 2

static uint8_t rx[RX_MAX];
static uint64_t rx_len;
static int64_t arg_a, arg_b;
static int64_t connect_timeout_ms;

static silica_sockets_tagged ok(int64_t v) { silica_sockets_tagged r = {0, v, 0}; return r; }
static silica_sockets_tagged err(void) { silica_sockets_tagged r = {1, 0, (int64_t)errno}; return r; }
static silica_sockets_tagged timeout(void) { silica_sockets_tagged r = {2, 0, 0}; return r; }
static silica_sockets_tagged closed(void) { silica_sockets_tagged r = {3, 0, 0}; return r; }
static silica_sockets_tagged fail(int code) { errno = code; return err(); }
#ifdef SOCKETS_STATION_REPORT
static void say_errno(const char *where, int e) {
    extern void spike_put_dec(uint32_t n);
    extern void silica_rt_puts(const char *s);
    silica_rt_puts("sockets: ");
    silica_rt_puts(where);
    silica_rt_puts(" errno ");
    spike_put_dec((uint32_t)e);
    silica_rt_puts("\n");
}
#else
#define say_errno(where, e) ((void)0)
#endif

/* ---- the address checks: compiler/stdlib/net/silica_sockets.c's, unchanged ------------------------- */

/* Exactly four decimal parts separated by dots, each 0 to 255, digits only, no leading zero except a
   bare "0". The address in host order. */
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

/* The canonical text of an IPv6 address (RFC 5952); out holds at least 40 bytes. */
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

/* An IPv6 text, accepted only as the canonical text of the address it names. */
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

static int ipv6_is_link_local(const uint16_t g[8]) {
    return (g[0] & 0xffc0) == 0xfe80;
}

static int ipv6_usable(const uint8_t *s, uint64_t n, uint16_t g[8]) {
    return ipv6_strict(s, n, g) && !ipv6_is_link_local(g);
}

static void ipv6_sockaddr(struct sockaddr_in6 *addr, const uint16_t g[8], int64_t port) {
    memset(addr, 0, sizeof *addr);
    addr->sin6_len = sizeof *addr;
    addr->sin6_family = AF_INET6;
    addr->sin6_port = lwip_htons((uint16_t)port);
    for (int k = 0; k < 8; k++) {
        addr->sin6_addr.s6_addr[2 * k] = (uint8_t)(g[k] >> 8);
        addr->sin6_addr.s6_addr[2 * k + 1] = (uint8_t)(g[k] & 255);
    }
}

/* 1 to 253 bytes of dot-separated labels of letters, digits and hyphens (1 to 63 each, no hyphen first
   or last), the last label starting with a letter. */
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

/* The timeout the last silica_sockets_set_connect_timeout stated, taken once. */
static int64_t take_connect_timeout(void) {
    int64_t t = connect_timeout_ms;
    connect_timeout_ms = 0;
    return t;
}

/* 1 when the descriptor is ready for reading (or, writing, for writing) within timeout_ms, 0 when
   not, -1 on an error. */
static int wait_fd(int fd, int writing, int64_t timeout_ms) {
    fd_set set;
    struct timeval t = { (long)(timeout_ms / 1000), (long)(timeout_ms % 1000) * 1000 };
    FD_ZERO(&set);
    FD_SET(fd, &set);
    return lwip_select(fd + 1, writing ? NULL : &set, writing ? &set : NULL, NULL, timeout_ms < 0 ? NULL : &t);
}

/* ---- the station: the link (:wifi, 0) ------------------------------------------------------------ */

static volatile int station_started, station_joined, net_started;

/* On the radio's core: joins the access point, starts lwIP when it has, joins again when it is lost. */
static void station_task(void *unused) {
    (void)unused;
    for (;;) {
        int32_t id;
        uint8_t data[48];
        while (spike_wifi_event(&id, data)) {
            if (id == WIFI_EVENT_STA_START) {
                esp_wifi_connect();
            } else if (id == WIFI_EVENT_STA_CONNECTED) {
                if (!net_started) net_started = spike_net_start() == 0;
                station_joined = 1;
            } else if (id == WIFI_EVENT_STA_DISCONNECTED) {
                station_joined = 0;
#ifdef SOCKETS_STATION_REPORT
                {
                    /* why the access point was lost: wifi_event_sta_disconnected_t's reason (esp_wifi_types.h wifi_err_reason_t) */
                    extern void spike_put_dec(uint32_t n);
                    extern void silica_rt_puts(const char *s);
                    silica_rt_puts("station: lost the access point, reason ");
                    spike_put_dec(((wifi_event_sta_disconnected_t *)data)->reason);
                    silica_rt_puts("\n");
                }
#endif
                esp_wifi_connect();
            }
        }
#ifdef SOCKETS_HEAP_REPORT
        // every five seconds: how much of the heap the libraries hold (route R1's one heap); every thirty,
        // how much of its stack each task has used
        static uint32_t passes;
        if (++passes % 250 == 0) {
            extern uint32_t spike_arena_now(void);
            extern void spike_put_dec(uint32_t n);
            extern void silica_rt_puts(const char *s);
            silica_rt_puts("station: the libraries hold ");
            spike_put_dec(spike_arena_now());
            silica_rt_puts("\n");
#ifdef SOCKETS_HEAP_SUMMARY
            extern void spike_heap_report(void);
            spike_heap_report();
#endif
#ifdef SOCKETS_PREEMPT_REPORT
            extern void spike_preempt_report(void);
            spike_preempt_report();
#endif
            if (passes % 1500 == 0) {
                extern void spike_stack_report(void);
                spike_stack_report();
            }
        }
#endif
        vTaskDelay(20);
    }
}

static int station_start(void) {
    if (station_started) return 0;
    spike_net_core();
    /* what ESP-IDF's start-up does before any radio (esp_coex's coexist.c through spike_coex_start, mbedtls's esp_psa_crypto_init.c) */
    spike_coex_start();
    if (psa_crypto_init() != 0) return -1;
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    cfg.nvs_enable = 0;
#ifdef SOCKETS_WIFI_RX_BUFFERS
    /* fewer of the 1.6 KB receive buffers the station keeps for its whole life (ESP-IDF's default is
       10), where memory is short; the receive window for aggregated frames must not exceed them */
    cfg.static_rx_buf_num = SOCKETS_WIFI_RX_BUFFERS;
    if (cfg.rx_ba_win > SOCKETS_WIFI_RX_BUFFERS) cfg.rx_ba_win = SOCKETS_WIFI_RX_BUFFERS;
#endif
    static wifi_config_t sta;
    strncpy((char *)sta.sta.ssid, SILICA_WIFI_SSID, sizeof sta.sta.ssid);
    strncpy((char *)sta.sta.password, SILICA_WIFI_PASSPHRASE, sizeof sta.sta.password);
    esp_err_t e = esp_wifi_init(&cfg);
    if (e == ESP_OK) e = esp_wifi_set_mode(WIFI_MODE_STA);
    if (e == ESP_OK) e = esp_wifi_set_config(WIFI_IF_STA, &sta);
    /* the radio stays on between beacons: its power saving is not right on this route yet */
#ifdef SOCKETS_WIFI_PS
    // modem sleep: the station sleeps between the access point's beacons. Espressif's coexistence
    // needs it when the Bluetooth controller shares the radio.
    if (e == ESP_OK) e = esp_wifi_set_ps(WIFI_PS_MIN_MODEM);
#else
    if (e == ESP_OK) e = esp_wifi_set_ps(WIFI_PS_NONE);
#endif
    if (e == ESP_OK && xTaskCreatePinnedToCore(station_task, "station", 4096, NULL, 5, NULL, 1) != pdPASS) e = ESP_FAIL;
    if (e == ESP_OK) e = esp_wifi_start();
    if (e != ESP_OK) return -1;
    station_started = 1;
    return 0;
}

/* The station's address in host order, 0 while it has none. */
static uint32_t station_address(void) {
    return station_joined ? lwip_ntohl(spike_net_address()) : 0;
}

/* family: set_args a (2 Wi-Fi), instance: set_args b. ENXIO for any other link, and while the station
   has no address. */
silica_sockets_tagged silica_sockets_link_select(const uint8_t *name_ptr, uint64_t name_len) {
    (void)name_ptr;
    (void)name_len;
#ifdef SOCKETS_STATION_REPORT
    {
        extern void spike_put_dec(uint32_t n);
        extern void silica_rt_puts(const char *s);
        if (arg_a != LINK_WIFI || arg_b != 0 || station_address() == 0) {
            silica_rt_puts("station: link_select refused: args ");
            spike_put_dec((uint32_t)arg_a);
            silica_rt_puts(" ");
            spike_put_dec((uint32_t)arg_b);
            silica_rt_puts(", joined ");
            spike_put_dec((uint32_t)station_joined);
            silica_rt_puts(", address ");
            spike_put_dec(spike_net_address() != 0);
            silica_rt_puts(", dhcp state ");
            extern int spike_net_dhcp_state(void);
            spike_put_dec((uint32_t)spike_net_dhcp_state());
            silica_rt_puts("\n");
        }
    }
#endif
    if (arg_a != LINK_WIFI || arg_b != 0) return fail(ENXIO);
    if (station_start() != 0) return fail(ENXIO);
    uint32_t a = station_address();
    if (a == 0) return fail(ENXIO);
    return ok((int64_t)a);
}

silica_sockets_tagged silica_sockets_link_owns(int64_t addr) {
    uint32_t a = station_address();
    return ok(a != 0 && a == (uint32_t)addr);
}

/* ---- the arguments ------------------------------------------------------------------------------ */

silica_sockets_tagged silica_sockets_set_args(int64_t a, int64_t b) {
    arg_a = a;
    arg_b = b;
    return ok(0);
}

silica_sockets_tagged silica_sockets_set_host(const uint8_t *host_ptr, uint64_t host_len) {
    (void)host_ptr;
    (void)host_len;
    return ok(0);
}

/* The timeout of the next TCP connect, in milliseconds: 1 to INT32_MAX, else EINVAL. */
silica_sockets_tagged silica_sockets_set_connect_timeout(int64_t timeout_ms) {
    connect_timeout_ms = 0;
    if (timeout_ms <= 0 || timeout_ms > (int64_t)INT32_MAX) return fail(EINVAL);
    connect_timeout_ms = timeout_ms;
    return ok(0);
}

silica_sockets_tagged silica_sockets_parse_ipv4(const uint8_t *host_ptr, uint64_t host_len) {
    uint32_t a;
    if (!ipv4_strict(host_ptr, host_len, &a)) return fail(EINVAL);
    return ok((int64_t)a);
}

/* value 1 for ::1, 0 for any other usable IPv6 address, EINVAL otherwise */
silica_sockets_tagged silica_sockets_parse_ipv6(const uint8_t *host_ptr, uint64_t host_len) {
    uint16_t g[8];
    if (!ipv6_usable(host_ptr, host_len, g)) return fail(EINVAL);
    return ok(ipv6_is_loopback(g) ? 1 : 0);
}

silica_sockets_tagged silica_sockets_parse_host_name(const uint8_t *host_ptr, uint64_t host_len) {
    if (!host_name_strict(host_ptr, host_len)) return fail(EINVAL);
    return ok(0);
}

/* The station holds no IPv6 address: 0 for every usable address. */
silica_sockets_tagged silica_sockets_link_owns6(const uint8_t *host_ptr, uint64_t host_len) {
    uint16_t g[8];
    if (!ipv6_usable(host_ptr, host_len, g)) return fail(EINVAL);
    return ok(0);
}

/* ---- TCP ---------------------------------------------------------------------------------------- */

static void no_delay(int fd) {
    int one = 1;
    lwip_setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
}

/* Connects fd to addr without blocking in connect, waiting at most timeout_ms for the peer. Closes fd
   on failure. */
static silica_sockets_tagged connect_bounded(int fd, const struct sockaddr *addr, socklen_t len, int64_t timeout_ms) {
    int flags = lwip_fcntl(fd, F_GETFL, 0);
    lwip_fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    if (lwip_connect(fd, addr, len) < 0) {
        int e = errno;
        if (e == EINPROGRESS) {
            int n = wait_fd(fd, 1, timeout_ms);
            if (n == 0) { say_errno("connect", ETIMEDOUT); lwip_close(fd); return timeout(); }
            if (n < 0) { e = errno; }
            else {
                socklen_t size = sizeof e;
                if (lwip_getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &size) < 0) e = errno;
            }
        }
        if (e != 0) { say_errno("connect", e); lwip_close(fd); return fail(e); }
    }
    /* Left non-blocking, where the hosted wrapper restores blocking: a blocking send would hold the
       core, and its actors, until lwIP took the whole buffer. Every later call waits in its own select
       and takes what the descriptor accepts. */
    (void)flags;
    return ok(fd);
}

/* from: the local address in host order, 0 for any. */
static silica_sockets_tagged connect_to(const uint8_t *host_ptr, uint64_t host_len, int64_t port, uint32_t from) {
    struct sockaddr_in addr, local;
    uint32_t to;
    int64_t timeout_ms = take_connect_timeout();
    if (timeout_ms <= 0) return fail(EINVAL);
    if (!ipv4_strict(host_ptr, host_len, &to)) return fail(EINVAL);
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = lwip_htons((uint16_t)port);
    addr.sin_addr.s_addr = lwip_htonl(to);
    spike_net_core();   /* a peer on 127.0.0.1 needs no station */
    int fd = lwip_socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { say_errno("socket", errno); return err(); }
    no_delay(fd);
    if (from != 0) {
        memset(&local, 0, sizeof local);
        local.sin_family = AF_INET;
        local.sin_addr.s_addr = lwip_htonl(from);
        if (lwip_bind(fd, (struct sockaddr *)&local, sizeof local) < 0) { int e = errno; say_errno("bind", e); lwip_close(fd); return fail(e); }
    }
    return connect_bounded(fd, (struct sockaddr *)&addr, sizeof addr, timeout_ms);
}

/* port: set_args a */
silica_sockets_tagged silica_sockets_tcp_connect(const uint8_t *host_ptr, uint64_t host_len) {
    return connect_to(host_ptr, host_len, arg_a, 0);
}

/* port: set_args a, local address: set_args b */
silica_sockets_tagged silica_sockets_tcp_connect_from(const uint8_t *host_ptr, uint64_t host_len) {
    return connect_to(host_ptr, host_len, arg_a, (uint32_t)arg_b);
}

/* port: set_args a; set_args b 1: leave from the link's IPv6 address, which the station does not have
   (ENXIO) */
silica_sockets_tagged silica_sockets_tcp_connect6(const uint8_t *host_ptr, uint64_t host_len) {
    struct sockaddr_in6 addr;
    uint16_t g[8];
    int64_t timeout_ms = take_connect_timeout();
    if (timeout_ms <= 0) return fail(EINVAL);
    if (!ipv6_usable(host_ptr, host_len, g)) return fail(EINVAL);
    if (arg_b == 1) return fail(ENXIO);
    ipv6_sockaddr(&addr, g, arg_a);
    spike_net_core();
    int fd = lwip_socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) { say_errno("socket6", errno); return err(); }
    int one = 1;
    lwip_setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one);
    no_delay(fd);
    return connect_bounded(fd, (struct sockaddr *)&addr, sizeof addr, timeout_ms);
}

static silica_sockets_tagged tcp_listen_sockaddr(int family, const struct sockaddr *addr, socklen_t len) {
    spike_net_core();
    int fd = lwip_socket(family, SOCK_STREAM, 0);
    if (fd < 0) return err();
    int one = 1;
    lwip_setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (family == AF_INET6) lwip_setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one);
    if (lwip_bind(fd, addr, len) < 0) { int e = errno; lwip_close(fd); return fail(e); }
    if (lwip_listen(fd, 4) < 0) { int e = errno; lwip_close(fd); return fail(e); }
    return ok(fd);
}

static silica_sockets_tagged tcp_listen_on(int64_t port, uint32_t host_order_addr) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = lwip_htons((uint16_t)port);
    addr.sin_addr.s_addr = lwip_htonl(host_order_addr);
    return tcp_listen_sockaddr(AF_INET, (struct sockaddr *)&addr, sizeof addr);
}

silica_sockets_tagged silica_sockets_tcp_listen(int64_t port) {
    return tcp_listen_on(port, INADDR_LOOPBACK);
}

silica_sockets_tagged silica_sockets_tcp_listen_any(int64_t port) {
    return tcp_listen_on(port, INADDR_ANY);
}

/* port: set_args a */
silica_sockets_tagged silica_sockets_tcp_listen_addr(const uint8_t *host_ptr, uint64_t host_len) {
    uint32_t a;
    if (!ipv4_strict(host_ptr, host_len, &a)) return fail(EINVAL);
    return tcp_listen_on(arg_a, a);
}

/* port: set_args a; "::" is every IPv6 interface */
silica_sockets_tagged silica_sockets_tcp_listen_addr6(const uint8_t *host_ptr, uint64_t host_len) {
    struct sockaddr_in6 addr;
    uint16_t g[8];
    if (!ipv6_usable(host_ptr, host_len, g)) return fail(EINVAL);
    ipv6_sockaddr(&addr, g, arg_a);
    return tcp_listen_sockaddr(AF_INET6, (struct sockaddr *)&addr, sizeof addr);
}

/* port: set_args a, link rule: set_args b, timeout: set_connect_timeout. The arguments are checked as
   the hosted wrapper checks them; then ENXIO, since route R1 has no resolver. */
silica_sockets_tagged silica_sockets_tcp_listen_name(const uint8_t *host_ptr, uint64_t host_len) {
    int64_t timeout_ms = take_connect_timeout();
    if (timeout_ms <= 0) return fail(EINVAL);
    if (!host_name_strict(host_ptr, host_len)) return fail(EINVAL);
    return fail(ENXIO);
}

silica_sockets_tagged silica_sockets_peer_addr(int64_t fd) {
    struct sockaddr_in addr;
    socklen_t n = sizeof addr;
    if (lwip_getpeername((int)fd, (struct sockaddr *)&addr, &n) < 0) return err();
    return ok((int64_t)lwip_ntohl(addr.sin_addr.s_addr));
}

silica_sockets_tagged silica_sockets_peer_port(int64_t fd) {
    struct sockaddr_in addr;
    socklen_t n = sizeof addr;
    if (lwip_getpeername((int)fd, (struct sockaddr *)&addr, &n) < 0) return err();
    return ok((int64_t)lwip_ntohs(addr.sin_port));
}

/* 4 for an IPv4 peer, 6 for an IPv6 one */
silica_sockets_tagged silica_sockets_peer_family(int64_t fd) {
    struct sockaddr_storage addr;
    socklen_t n = sizeof addr;
    if (lwip_getpeername((int)fd, (struct sockaddr *)&addr, &n) < 0) return err();
    if (addr.ss_family == AF_INET) return ok(4);
    if (addr.ss_family == AF_INET6) return ok(6);
    return fail(EAFNOSUPPORT);
}

/* word 0 to 3 of an IPv6 peer's address, its first byte highest */
silica_sockets_tagged silica_sockets_peer_addr6_word(int64_t fd, int64_t word) {
    struct sockaddr_storage addr;
    socklen_t n = sizeof addr;
    if (word < 0 || word > 3) return fail(EINVAL);
    if (lwip_getpeername((int)fd, (struct sockaddr *)&addr, &n) < 0) return err();
    if (addr.ss_family != AF_INET6) return fail(EAFNOSUPPORT);
    const uint8_t *b = ((struct sockaddr_in6 *)&addr)->sin6_addr.s6_addr + 4 * word;
    return ok(((int64_t)b[0] << 24) | ((int64_t)b[1] << 16) | ((int64_t)b[2] << 8) | (int64_t)b[3]);
}

silica_sockets_tagged silica_sockets_local_port(int64_t fd) {
    struct sockaddr_in addr;
    socklen_t n = sizeof addr;
    if (lwip_getsockname((int)fd, (struct sockaddr *)&addr, &n) < 0) return err();
    return ok((int64_t)lwip_ntohs(addr.sin_port));
}

silica_sockets_tagged silica_sockets_tcp_accept(int64_t fd, int64_t timeout_ms) {
    int n = wait_fd((int)fd, 0, timeout_ms);
    if (n < 0) return err();
    if (n == 0) return timeout();
    int c = lwip_accept((int)fd, NULL, NULL);
    if (c < 0) return err();
    no_delay(c);
    return ok(c);
}

/* ---- not on the board ---------------------------------------------------------------------------- */

silica_sockets_tagged silica_sockets_udp_bind(int64_t port) { (void)port; return fail(ENOSYS); }
silica_sockets_tagged silica_sockets_udp_bind_on(int64_t port, int64_t host_order_addr) { (void)port; (void)host_order_addr; return fail(ENOSYS); }
silica_sockets_tagged silica_sockets_udp_send(const uint8_t *data_ptr, uint64_t data_len) { (void)data_ptr; (void)data_len; return fail(ENOSYS); }
silica_sockets_tagged silica_sockets_udp_recv(int64_t fd, int64_t max, int64_t timeout_ms) { (void)fd; (void)max; (void)timeout_ms; return fail(ENOSYS); }
silica_sockets_tagged silica_sockets_serial_open(const uint8_t *path_ptr, uint64_t path_len) { (void)path_ptr; (void)path_len; return fail(ENOSYS); }

/* ---- any descriptor ------------------------------------------------------------------------------ */

/* Writes the whole buffer, waiting up to timeout_ms for each piece the descriptor accepts.
   fd: set_args a, timeout_ms: set_args b */
silica_sockets_tagged silica_sockets_send(const uint8_t *data_ptr, uint64_t data_len) {
    int fd = (int)arg_a;
    int64_t timeout_ms = arg_b;
    uint64_t done = 0;
    while (done < data_len) {
        int n = wait_fd(fd, 1, timeout_ms);
        if (n < 0) return err();
        if (n == 0) return timeout();
        int w = lwip_send(fd, data_ptr + done, (size_t)(data_len - done), 0);
        if (w < 0) { if (errno == EAGAIN || errno == EWOULDBLOCK) continue; return err(); }
        done += (uint64_t)w;
    }
    return ok((int64_t)done);
}

/* Reads up to max bytes (RX_MAX at most) into the buffer; value is the count. 0 bytes means the peer
   closed (tag 3). */
silica_sockets_tagged silica_sockets_recv(int64_t fd, int64_t max, int64_t timeout_ms) {
    int n = wait_fd((int)fd, 0, timeout_ms);
    if (n < 0) return err();
    if (n == 0) return timeout();
    size_t cap = (max > 0 && max < RX_MAX) ? (size_t)max : RX_MAX;
    int got = lwip_recv((int)fd, rx, cap, 0);
    if (got < 0) { if (errno == EAGAIN || errno == EWOULDBLOCK) return timeout(); return err(); }
    rx_len = (uint64_t)got;
    if (got == 0) return closed();
    return ok((int64_t)got);
}

silica_sockets_bytes silica_sockets_take(int64_t fd) {
    (void)fd;
    silica_sockets_bytes r = { 0, rx_len > 0 ? rx : NULL, rx_len, 0 };
    return r;
}

silica_sockets_tagged silica_sockets_close(int64_t fd) {
    if (lwip_close((int)fd) < 0) return err();
    return ok(0);
}
