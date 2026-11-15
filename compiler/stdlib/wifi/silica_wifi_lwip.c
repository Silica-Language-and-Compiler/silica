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

/* The Fifi wrapper around Espressif's Wi-Fi station and lwIP for the ESP32-S3 (transport_ble_plan.md
   stage 12, part 6, step 3): what a board's (:tcp) carrier needs, one TCP connection at a time, in
   the shape of the NimBLE wrapper beside it (compiler/stdlib/ble/silica_ble_nimble.c) so that the
   radio actor above it is that wrapper's radio actor with the names changed. Every answer is
   { tag, value, error_code } with tag 0 ok, 1 error, 2 nothing yet. No call waits for the network:
   what happens later comes out of silica_wifi_event, which also does this wrapper's own work (the
   station's events, the connection's progress, the bytes that came), so it is to be called often.

   The access point's name and passphrase are compiled in from wifi_secret.h, a file the build script
   writes from one kept out of git (SILICA_WIFI_SSID, SILICA_WIFI_PASSPHRASE).

   Events (silica_wifi_event's value; the fields by silica_wifi_event_field), numbered as NimBLE's:
     1 ready         the station has joined and has an address: requests are accepted from now on
     2 reset         the station lost the access point; field 0 the Wi-Fi library's reason. It joins
                     again by itself, and a :ready follows
     4 connected     field 0 the connection's handle, field 1 the status: 0, or lwIP's error number
                     when the peer could not be reached
     5 disconnected  field 0 the handle, field 1 the reason in NimBLE's numbers, which the carrier
                     reads: 0x213 the peer closed, 0x216 this end did, 0x208 the connection was lost
     6 subscribed    field 0 the handle, field 1 1: follows :connected at once (a TCP connection has
                     no second step); kept so that the radio actor is the same
     7 sent          field 0 the handle, field 1 0: lwIP has taken the segment
     8 written       field 0 the handle: bytes came, and wait for silica_wifi_recv. The next bytes are
                     read from lwIP only when these are taken, so TCP holds the peer back

   silica_wifi_seek takes "a.b.c.d:port" and begins a connection; :connected says how it ended.
   A segment is at most SEG_MAX bytes (silica_wifi_mtu); a TCP connection keeps no boundaries, so
   what comes in is whatever lwIP has, up to SEG_MAX at a time. Listening (silica_wifi_serve) is not
   built: error 9.

   Outside this file: spike_wifi_event (the station's events, kept by wifi_shim.c where ESP-IDF's
   event loop would deliver them) and spike_net_start, spike_net_address (wifi_net.c, in place of
   ESP-IDF's esp_netif). Both are the R1 spike's; on a guest of ESP-IDF they would be ESP-IDF's own. */

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include "esp_wifi.h"
#include "esp_heap_caps.h"
#include "lwip/sockets.h"
#include "lwip/inet.h"
#include "wifi_secret.h"

typedef struct {
    int64_t tag, value, error_code;
} silica_wifi_tagged;
typedef struct {
    int64_t tag;
    const uint8_t *text_ptr;
    uint64_t text_len;
    int64_t error_code;
} silica_wifi_bytes;

int spike_wifi_event(int32_t *id, uint8_t data[48]);
int spike_net_start(void);
uint32_t spike_net_address(void);
uint64_t spike_ticks(void);
int esp_coex_adapter_register(void *funcs);
int coex_pre_init(void);
int psa_crypto_init(void);
extern void *g_coex_adapter_funcs;

#define SEG_MAX 1024
#define CONN 1                  /* the one connection's handle */
#define CONNECT_MS 10000

enum { EV_READY = 1, EV_RESET = 2, EV_CONNECTED = 4, EV_DISCONNECTED = 5, EV_SUBSCRIBED = 6, EV_SENT = 7, EV_WRITTEN = 8 };

static int phase;               /* 0 not started, 1 joining, 2 joined and waiting for an address, 3 ready */
static int net_started;
static int sock = -1;
static int connecting;          /* the connection is being made */
static uint64_t connect_from;
static uint8_t chunk[SEG_MAX], taken[SEG_MAX];
static int chunk_len, taken_len;
static int64_t arg_a;

#define EVENTS 16
static struct {
    int kind;
    int64_t field[2];
} events[EVENTS], last_event;
static unsigned events_in, events_out;

static silica_wifi_tagged ok(int64_t value) { return (silica_wifi_tagged){ 0, value, 0 }; }
static silica_wifi_tagged fail(int64_t code) { return (silica_wifi_tagged){ 1, 0, code }; }

static void post(int kind, int64_t a, int64_t b) {
    if (events_in - events_out < EVENTS) {
        events[events_in % EVENTS].kind = kind;
        events[events_in % EVENTS].field[0] = a;
        events[events_in % EVENTS].field[1] = b;
        events_in++;
    }
}

static void close_socket(void) {
    if (sock >= 0) {
        lwip_close(sock);
    }
    sock = -1;
    connecting = 0;
    chunk_len = 0;
}

/* Starts the station, once; :ready says when it has joined and has an address. */
silica_wifi_tagged silica_wifi_start(int64_t reserved) {
    (void)reserved;
    if (phase != 0) return ok(0);
    /* what ESP-IDF's start-up does before any radio (esp_coex's coexist.c, mbedtls's esp_psa_crypto_init.c) */
    esp_coex_adapter_register(&g_coex_adapter_funcs);
    coex_pre_init();
    if (psa_crypto_init() != 0) return fail(2);
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    cfg.nvs_enable = 0;
    static wifi_config_t sta;
    strncpy((char *)sta.sta.ssid, SILICA_WIFI_SSID, sizeof sta.sta.ssid);
    strncpy((char *)sta.sta.password, SILICA_WIFI_PASSPHRASE, sizeof sta.sta.password);
    esp_err_t e = esp_wifi_init(&cfg);
    if (e == ESP_OK) e = esp_wifi_set_mode(WIFI_MODE_STA);
    if (e == ESP_OK) e = esp_wifi_set_config(WIFI_IF_STA, &sta);
    /* the radio stays on between beacons: its power saving is not right on this route yet */
    if (e == ESP_OK) e = esp_wifi_set_ps(WIFI_PS_NONE);
    if (e == ESP_OK) e = esp_wifi_start();
    if (e != ESP_OK) return fail(1000 + e);
    phase = 1;
    return ok(0);
}

/* One step of each thing that goes on by itself. */
static void pump(void) {
    int32_t id;
    uint8_t data[48];
    if (spike_wifi_event(&id, data)) {
        if (id == WIFI_EVENT_STA_START) {
            esp_wifi_connect();
        } else if (id == WIFI_EVENT_STA_CONNECTED) {
            if (!net_started) {
                net_started = spike_net_start() == 0;
            }
            if (phase < 2) phase = 2;
        } else if (id == WIFI_EVENT_STA_DISCONNECTED) {
            if (sock >= 0) {
                int was_up = !connecting;
                close_socket();
                post(was_up ? EV_DISCONNECTED : EV_CONNECTED, CONN, was_up ? 0x208 : ENOTCONN);
            }
            if (phase == 3) post(EV_RESET, ((wifi_event_sta_disconnected_t *)data)->reason, 0);
            phase = 1;
            esp_wifi_connect();
        }
    }
    if (phase == 2 && spike_net_address() != 0) {
        phase = 3;
        post(EV_READY, 0, 0);
    }
    if (sock >= 0 && connecting) {
        fd_set writable;
        struct timeval now = { 0, 0 };
        FD_ZERO(&writable);
        FD_SET(sock, &writable);
        if (lwip_select(sock + 1, NULL, &writable, NULL, &now) > 0) {
            int error = 0;
            socklen_t size = sizeof error;
            lwip_getsockopt(sock, SOL_SOCKET, SO_ERROR, &error, &size);
            if (error == 0) {
                connecting = 0;
                post(EV_CONNECTED, CONN, 0);
                post(EV_SUBSCRIBED, CONN, 1);
            } else {
                close_socket();
                post(EV_CONNECTED, CONN, error);
            }
        } else if ((spike_ticks() - connect_from) / 16000 > CONNECT_MS) {
            close_socket();
            post(EV_CONNECTED, CONN, ETIMEDOUT);
        }
    } else if (sock >= 0 && chunk_len == 0) {
        int n = lwip_recv(sock, chunk, SEG_MAX, MSG_DONTWAIT);
        if (n > 0) {
            chunk_len = n;
            post(EV_WRITTEN, CONN, 0);
        } else if (n == 0) {
            close_socket();
            post(EV_DISCONNECTED, CONN, 0x213);
        } else if (errno != EWOULDBLOCK && errno != EAGAIN) {
            close_socket();
            post(EV_DISCONNECTED, CONN, 0x208);
        }
    }
}

silica_wifi_tagged silica_wifi_event(int64_t timeout_ms) {
    (void)timeout_ms;
    if (phase != 0) pump();
    if (events_out == events_in) return (silica_wifi_tagged){ 2, 0, 0 };
    last_event.kind = events[events_out % EVENTS].kind;
    last_event.field[0] = events[events_out % EVENTS].field[0];
    last_event.field[1] = events[events_out % EVENTS].field[1];
    events_out++;
    return ok(last_event.kind);
}

silica_wifi_tagged silica_wifi_event_field(int64_t index) {
    if (index < 0 || index > 1) return fail(1);
    return ok(last_event.field[index]);
}

/* "a.b.c.d:port": 6 for text that is not that, 7 before :ready, 5 while a connection is held. */
silica_wifi_tagged silica_wifi_seek(const uint8_t *address, uint64_t len) {
    char text[32];
    if (len == 0 || len >= sizeof text) return fail(6);
    memcpy(text, address, len);
    text[len] = 0;
    char *colon = strchr(text, ':');
    if (colon == NULL) return fail(6);
    *colon = 0;
    int port = 0;
    for (const char *p = colon + 1; *p; p++) {
        if (*p < '0' || *p > '9') return fail(6);
        port = port * 10 + (*p - '0');
    }
    struct sockaddr_in to;
    memset(&to, 0, sizeof to);
    to.sin_family = AF_INET;
    to.sin_port = lwip_htons((uint16_t)port);
    if (port <= 0 || port > 65535 || ip4addr_aton(text, (ip4_addr_t *)&to.sin_addr) == 0) return fail(6);
    if (phase != 3) return fail(7);
    if (sock >= 0) return fail(5);
    sock = lwip_socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return fail(1000 + errno);
    lwip_fcntl(sock, F_SETFL, lwip_fcntl(sock, F_GETFL, 0) | O_NONBLOCK);
    if (lwip_connect(sock, (struct sockaddr *)&to, sizeof to) != 0 && errno != EINPROGRESS) {
        int error = errno;
        close_socket();
        post(EV_CONNECTED, CONN, error);
        return ok(0);
    }
    connecting = 1;
    connect_from = spike_ticks();
    return ok(0);
}

silica_wifi_tagged silica_wifi_set_args(int64_t a, int64_t b) {
    (void)b;
    arg_a = a;
    return ok(0);
}

silica_wifi_tagged silica_wifi_mtu(int64_t conn) {
    (void)conn;
    return ok(SEG_MAX);
}

/* One segment to the connection named by silica_wifi_set_args: 3 when there is none, 4 when it is
   empty or longer than SEG_MAX, 5 when lwIP cannot take it now. */
silica_wifi_tagged silica_wifi_send(const uint8_t *data, uint64_t len) {
    if (sock < 0 || connecting || arg_a != CONN) return fail(3);
    if (len == 0 || len > SEG_MAX) return fail(4);
    uint64_t done = 0;
    for (int tries = 0; done < len && tries < 200; tries++) {
        int n = lwip_send(sock, data + done, (size_t)(len - done), MSG_DONTWAIT);
        if (n > 0) {
            done += (uint64_t)n;
        } else if (errno != EWOULDBLOCK && errno != EAGAIN) {
            break;
        }
    }
    if (done < len) {
        /* part of a segment gone leaves the stream unreadable for the peer: the connection ends */
        int none = done == 0;
        if (!none) {
            close_socket();
            post(EV_DISCONNECTED, CONN, 0x208);
        }
        return fail(none ? 5 : 3);
    }
    post(EV_SENT, CONN, 0);
    return ok(0);
}

/* Takes the bytes that came: value their count, tag 2 when there are none. */
silica_wifi_tagged silica_wifi_recv(int64_t conn) {
    if (conn != CONN || chunk_len == 0) return (silica_wifi_tagged){ 2, 0, 0 };
    memcpy(taken, chunk, (size_t)chunk_len);
    taken_len = chunk_len;
    chunk_len = 0;
    return ok(taken_len);
}

silica_wifi_bytes silica_wifi_take(int64_t conn) {
    (void)conn;
    return (silica_wifi_bytes){ 0, taken, (uint64_t)taken_len, 0 };
}

/* Ends the connection, or the making of one; :disconnected follows a connection that was up. */
silica_wifi_tagged silica_wifi_drop(int64_t conn) {
    (void)conn;
    if (sock >= 0) {
        int was_up = !connecting;
        close_socket();
        if (was_up) post(EV_DISCONNECTED, CONN, 0x216);
    }
    return ok(0);
}

/* Not built: this end only connects. */
silica_wifi_tagged silica_wifi_serve(const uint8_t *address, uint64_t len) {
    (void)address;
    (void)len;
    return fail(9);
}

silica_wifi_tagged silica_wifi_advertise(const uint8_t *address, uint64_t len) {
    (void)address;
    (void)len;
    return fail(9);
}

silica_wifi_tagged silica_wifi_stop_advertising(int64_t reserved) {
    (void)reserved;
    return ok(0);
}

/* The memory the Wi-Fi libraries and lwIP take theirs from, in bytes: 0 free now, 1 the least free
   since start, 2 the largest free block. */
silica_wifi_tagged silica_wifi_memory(int64_t which) {
    switch (which) {
    case 0: return ok((int64_t)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    case 1: return ok((int64_t)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL));
    case 2: return ok((int64_t)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
    default: return fail(1);
    }
}
