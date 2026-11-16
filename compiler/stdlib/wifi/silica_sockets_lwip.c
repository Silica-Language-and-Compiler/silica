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
     - a connection is given CONNECT_MS to be made, where a host waits as long as its system does;
     - UDP and the serial port are not here (ENOSYS).

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
#define CONNECT_MS 5000
#define LINK_WIFI 2

static uint8_t rx[RX_MAX];
static uint64_t rx_len;
static int64_t arg_a, arg_b;

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

static int copy_host(const uint8_t *ptr, uint64_t len, char *out, size_t cap) {
    if (len == 0 || len >= cap) return 0;
    memcpy(out, ptr, (size_t)len);
    out[len] = 0;
    return 1;
}

/* A dotted quad and nothing else, as the hosted wrapper reads one: four decimal parts 0 to 255, no
   leading zeros. The address in host order, or 0 with *good 0. */
static uint32_t dotted_quad(const char *text, int *good) {
    uint32_t a = 0;
    int parts = 0;
    const char *p = text;
    *good = 0;
    for (;;) {
        if (*p < '0' || *p > '9') return 0;
        if (*p == '0' && p[1] >= '0' && p[1] <= '9') return 0;
        uint32_t n = 0;
        int digits = 0;
        while (*p >= '0' && *p <= '9') {
            n = n * 10 + (uint32_t)(*p - '0');
            if (++digits > 3 || n > 255) return 0;
            p++;
        }
        a = (a << 8) | n;
        parts++;
        if (parts == 4) break;
        if (*p != '.') return 0;
        p++;
    }
    if (*p != 0) return 0;
    *good = 1;
    return a;
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

silica_sockets_tagged silica_sockets_parse_ipv4(const uint8_t *host_ptr, uint64_t host_len) {
    char host[64];
    int good;
    if (!copy_host(host_ptr, host_len, host, sizeof host)) return fail(EINVAL);
    uint32_t a = dotted_quad(host, &good);
    if (!good) return fail(EINVAL);
    return ok((int64_t)a);
}

/* ---- TCP ---------------------------------------------------------------------------------------- */

static void no_delay(int fd) {
    int one = 1;
    lwip_setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
}

/* from: the local address in host order, 0 for any. */
static silica_sockets_tagged connect_to(const uint8_t *host_ptr, uint64_t host_len, int64_t port, uint32_t from) {
    char host[64];
    int good;
    struct sockaddr_in addr, local;
    if (!copy_host(host_ptr, host_len, host, sizeof host)) return fail(EINVAL);
    uint32_t to = dotted_quad(host, &good);
    if (!good) return fail(EINVAL);
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
    /* made without blocking, so that a peer that does not answer costs CONNECT_MS and no more */
    lwip_fcntl(fd, F_SETFL, lwip_fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    if (lwip_connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        int e = errno;
        if (e == EINPROGRESS) {
            e = ETIMEDOUT;
            if (wait_fd(fd, 1, CONNECT_MS) > 0) {
                socklen_t size = sizeof e;
                lwip_getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &size);
            }
        }
        if (e != 0) { say_errno("connect", e); lwip_close(fd); return fail(e); }
    }
    return ok(fd);
}

/* port: set_args a */
silica_sockets_tagged silica_sockets_tcp_connect(const uint8_t *host_ptr, uint64_t host_len) {
    return connect_to(host_ptr, host_len, arg_a, 0);
}

/* port: set_args a, local address: set_args b */
silica_sockets_tagged silica_sockets_tcp_connect_from(const uint8_t *host_ptr, uint64_t host_len) {
    return connect_to(host_ptr, host_len, arg_a, (uint32_t)arg_b);
}

static silica_sockets_tagged tcp_listen_on(int64_t port, uint32_t host_order_addr) {
    struct sockaddr_in addr;
    spike_net_core();
    int fd = lwip_socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return err();
    int one = 1;
    lwip_setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = lwip_htons((uint16_t)port);
    addr.sin_addr.s_addr = lwip_htonl(host_order_addr);
    if (lwip_bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) { int e = errno; lwip_close(fd); return fail(e); }
    if (lwip_listen(fd, 4) < 0) { int e = errno; lwip_close(fd); return fail(e); }
    return ok(fd);
}

silica_sockets_tagged silica_sockets_tcp_listen(int64_t port) {
    return tcp_listen_on(port, INADDR_LOOPBACK);
}

silica_sockets_tagged silica_sockets_tcp_listen_any(int64_t port) {
    return tcp_listen_on(port, INADDR_ANY);
}

/* port: set_args a */
silica_sockets_tagged silica_sockets_tcp_listen_addr(const uint8_t *host_ptr, uint64_t host_len) {
    char host[64];
    int good;
    if (!copy_host(host_ptr, host_len, host, sizeof host)) return fail(EINVAL);
    uint32_t a = dotted_quad(host, &good);
    if (!good) return fail(EINVAL);
    return tcp_listen_on(arg_a, a);
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
