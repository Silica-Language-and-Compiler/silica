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

// Route R1 spike (transport_ble_plan.md stage 12, part 4): the host. On the chip the bare-metal runtime
// owns, NimBLE runs above the controller on hci_shim.c, and this main drives the board's own wrapper
// (compiler/stdlib/ble/silica_ble_nimble.c, unchanged) as the radio actor does in a Silica program: the
// peripheral role of the stage 7 demo. It publishes the service, advertises, and when a central has
// paired and subscribed it sends the demo's 48-byte frame in three 20-byte segments and prints the
// segments the central writes. The peer is the Mac's `run_peer.sh central`.
//
// The controller's handler comes by interrupt; between visits to the tasks main is busy for
// POLL_GAP_MS milliseconds, as an actor's turn would be.

#include <stdint.h>
#include <stddef.h>
#include "soc/rtc.h"
#include "esp_rom_serial_output.h"

typedef struct {
    int64_t tag, value, error_code;
} tagged;
typedef struct {
    int64_t tag;
    const uint8_t *text_ptr;
    uint64_t text_len;
    int64_t error_code;
} bytes;
tagged silica_nimble_start(int64_t reserved);
tagged silica_nimble_event(int64_t timeout_ms);
tagged silica_nimble_event_field(int64_t index);
tagged silica_nimble_serve(const uint8_t *uuid, uint64_t len);
tagged silica_nimble_set_args(int64_t a, int64_t b);
tagged silica_nimble_mtu(int64_t conn);
tagged silica_nimble_send(const uint8_t *data, uint64_t len);
tagged silica_nimble_recv(int64_t conn);
bytes silica_nimble_take(int64_t conn);
tagged silica_nimble_advertise(const uint8_t *uuid, uint64_t len);

void silica_rt_puts(const char *s);
void spike_put_dec(uint32_t n);
uint64_t spike_ticks(void);
void spike_yield(void);
int spike_flash_map(void);
uint32_t spike_arena_used(void);
extern uint32_t spike_handler_calls, spike_switches;

#ifndef POLL_GAP_MS
#define POLL_GAP_MS 0
#endif
#ifndef WATCH_SECONDS
#define WATCH_SECONDS 90
#endif

static const uint8_t frame[3][20] = {
    { 0x00, 0x00, 0x00, 0x00, 0x83, 0x68, 0x02, 0x77, 0x05, 0x61, 0x63, 0x63, 0x65, 0x6C, 0x74, 0x00, 0x00, 0x00, 0x04, 0x77 },
    { 0x00, 0x00, 0x00, 0x01, 0x05, 0x61, 0x74, 0x5F, 0x6D, 0x73, 0x62, 0x00, 0x00, 0x03, 0xE8, 0x77, 0x01, 0x78, 0x61, 0x01 },
    { 0x00, 0x00, 0x80, 0x02, 0x77, 0x01, 0x79, 0x62, 0xFF, 0xFF, 0xFF, 0xFE, 0x77, 0x01, 0x7A, 0x62, 0x00, 0x00, 0x02, 0x00 },
};

static void put_hex(const uint8_t *p, int n)
{
    static const char digits[] = "0123456789ABCDEF";
    char buf[3];
    buf[2] = 0;
    for (int i = 0; i < n; i++) {
        buf[0] = digits[p[i] >> 4];
        buf[1] = digits[p[i] & 15];
        silica_rt_puts(buf);
    }
}

#ifdef HCI_TRACE
// Every packet between the host and the controller, kept as it passes (the link's --wrap of ESP-IDF's
// two calls) and printed by main: > to the controller, < from it, with the time and the first bytes.
typedef struct {
    void (*notify_host_send_available)(void);
    int (*notify_host_recv)(uint8_t *data, uint16_t len);
} vhci_callbacks;
void __real_esp_vhci_host_send_packet(uint8_t *data, uint16_t len);
int __real_esp_vhci_host_register_callback(const vhci_callbacks *callbacks);

#define TRACED 96
static struct traced {
    uint32_t ms;
    uint16_t len;
    uint8_t up, head[24];
} trace[TRACED];
static volatile uint32_t trace_in;
static volatile uint32_t trace_out;
static uint64_t trace_start;
static const vhci_callbacks *host_callbacks;

static void keep(int up, const uint8_t *data, uint16_t len)
{
    if (trace_in - trace_out < TRACED) {
        struct traced *t = &trace[trace_in % TRACED];
        t->ms = (uint32_t)((spike_ticks() - trace_start) / 16000);
        t->len = len;
        t->up = (uint8_t)up;
        for (int i = 0; i < 24 && i < len; i++) {
            t->head[i] = data[i];
        }
        trace_in = trace_in + 1;
    }
}

void __wrap_esp_vhci_host_send_packet(uint8_t *data, uint16_t len)
{
    keep(0, data, len);
    __real_esp_vhci_host_send_packet(data, len);
}

static void traced_send_available(void)
{
    host_callbacks->notify_host_send_available();
}

static int traced_recv(uint8_t *data, uint16_t len)
{
    keep(1, data, len);
    return host_callbacks->notify_host_recv(data, len);
}

int __wrap_esp_vhci_host_register_callback(const vhci_callbacks *callbacks)
{
    static const vhci_callbacks mine = { traced_send_available, traced_recv };
    host_callbacks = callbacks;
    return __real_esp_vhci_host_register_callback(&mine);
}

static void put_hex(const uint8_t *p, int n);

static void print_trace(void)
{
    while (trace_out < trace_in) {
        struct traced *t = &trace[trace_out++ % TRACED];
        silica_rt_puts("    ");
        spike_put_dec(t->ms);
        silica_rt_puts(t->up ? " < " : " > ");
        put_hex(t->head, t->len < 24 ? t->len : 24);
        silica_rt_puts("\n");
    }
}
#endif

static void say(const char *what, int64_t n)
{
    silica_rt_puts(what);
    spike_put_dec((uint32_t)n);
    silica_rt_puts("\n");
}

// One visit to the tasks, then main's own busy time.
static void turn(void)
{
    for (int pass = 0; pass < 8; pass++) {
        spike_yield();
    }
    if (POLL_GAP_MS != 0) {
        uint64_t gap = spike_ticks();
        while ((spike_ticks() - gap) / 16000 < POLL_GAP_MS) {
        }
    }
}

long long main(void)
{
#ifdef SPIKE_FLASH
    if (spike_flash_map() != 0) {
        silica_rt_puts("flash not mapped\n");
        return 1;
    }
#endif
    esp_rom_output_tx_wait_idle(0);
    rtc_clk_config_t clk = RTC_CLK_CONFIG_DEFAULT();
    clk.cpu_freq_mhz = 80;
    rtc_clk_init(clk);

    tagged r = silica_nimble_serve((const uint8_t *)"", 0);
    if (r.tag != 0) {
        say("serve failed ", r.error_code);
        return 1;
    }
    r = silica_nimble_start(0);
    if (r.tag != 0) {
        say("start failed ", r.error_code);
        return 1;
    }
    silica_rt_puts("host started\n");

    int sent = 0, confirmed = 0, received = 0, matched = 0, up = 0, down = 0;
    int64_t conn = -1;
    uint64_t start = spike_ticks(), up_at = 0;
    while ((spike_ticks() - start) / 16000000 < WATCH_SECONDS && !down) {
        turn();
#ifdef HCI_TRACE
        if (conn >= 0) {
            print_trace();
        } else {
            trace_out = trace_in;   // the start-up's and the advertising's commands are not shown
        }
#endif
        r = silica_nimble_event(0);
        if (r.tag != 0) {
            continue;
        }
        int64_t kind = r.value, a = silica_nimble_event_field(0).value, b = silica_nimble_event_field(1).value;
        uint32_t ms = (uint32_t)((spike_ticks() - start) / 16000);
        spike_put_dec(ms);
        silica_rt_puts(" ms: ");
        switch (kind) {
        case 1:
            silica_rt_puts("synced\n");
            r = silica_nimble_advertise((const uint8_t *)"", 0);
            if (r.tag != 0) {
                say("advertise failed ", r.error_code);
                return 1;
            }
            silica_rt_puts("advertising\n");
            break;
        case 4:
            say("connected, status ", b);
            conn = a;
            break;
        case 6:
            say("subscribed ", b);
            if (b == 1 && !up) {
                up = 1;
                up_at = spike_ticks();
                say("link up mtu:", silica_nimble_mtu(conn).value);
                silica_nimble_set_args(conn, 0);
                r = silica_nimble_send(frame[0], 20);
                sent = 1;
                say("tx segment 0, answer ", r.tag);
            }
            break;
        case 7:
            say("sent, status ", b);
            confirmed++;
            if (b == 0 && sent < 3) {
                r = silica_nimble_send(frame[sent], 20);
                say("tx segment, answer ", r.tag);
                sent++;
            }
            break;
        case 8: {
            silica_rt_puts("written: ");
            r = silica_nimble_recv(conn);
            bytes t = silica_nimble_take(conn);
            put_hex(t.text_ptr, (int)t.text_len);
            silica_rt_puts("\n");
            if (received < 3 && t.text_len == 20) {
                int same = 1;
                for (int i = 0; i < 20; i++) {
                    same &= t.text_ptr[i] == frame[received][i];
                }
                matched += same;
            }
            received++;
            break;
        }
        case 5:
            say("disconnected, reason ", b);
            down = 1;
            break;
        default:
            spike_put_dec((uint32_t)kind);
            say(" event, field ", b);
            break;
        }
    }
    silica_rt_puts("poll gap ");
    spike_put_dec(POLL_GAP_MS);
    silica_rt_puts(" ms, handlers called ");
    spike_put_dec(spike_handler_calls);
    silica_rt_puts(", switches ");
    spike_put_dec(spike_switches);
    silica_rt_puts(", most memory given ");
    spike_put_dec(spike_arena_used());
    silica_rt_puts(" bytes\n");
    if (up) {
        say("link up for ms ", (int64_t)((spike_ticks() - up_at) / 16000));
    }
    // The peer ends the link when it has the frame, so the last segment's confirmation can be lost to
    // the disconnection when main is slow to take events: the count is printed, not required.
    say("segments confirmed ", confirmed);
    int whole = sent == 3 && received == 3 && matched == 3;
    silica_rt_puts(whole ? "frame out 48 bytes, frame in 48 bytes: the same\n" : "the exchange was not whole\n");
    return whole ? 0 : 1;
}
