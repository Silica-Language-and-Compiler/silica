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

// Route R1 spike, Wi-Fi (transport_ble_plan.md stage 12, part 6): on the chip the bare-metal runtime
// owns, Espressif's Wi-Fi libraries run on hci_shim.c and wifi_shim.c with no ESP-IDF start-up and no
// FreeRTOS. This main joins an access point as a station (the name and passphrase come from
// wifi_secret.h, which run_wifi.sh writes from a file outside git) and prints the events the Wi-Fi
// library posts and the count of frames the access point delivers. No network stack is in the image:
// "connected" is the association and the WPA2 key exchange done.
//
// The Wi-Fi interrupt comes at level 3; between visits to the tasks main is busy for POLL_GAP_MS
// milliseconds, as an actor's turn would be.

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "soc/rtc.h"
#include "esp_rom_serial_output.h"
#include "esp_wifi.h"
#include "esp_private/wifi.h"
#include "wifi_secret.h"

void silica_rt_puts(const char *s);
void spike_put_dec(uint32_t n);
uint64_t spike_ticks(void);
void spike_yield(void);
int spike_flash_map(void);
uint32_t spike_arena_used(void);
int spike_wifi_event(int32_t *id, uint8_t data[48]);
extern uint32_t spike_handler_calls, spike_switches;

#ifndef POLL_GAP_MS
#define POLL_GAP_MS 0
#endif
#ifndef WATCH_SECONDS
#define WATCH_SECONDS 40
#endif
#ifndef WIFI_CPU_MHZ
#define WIFI_CPU_MHZ 160
#endif

static void say(const char *what, int64_t n)
{
    silica_rt_puts(what);
    spike_put_dec((uint32_t)n);
    silica_rt_puts("\n");
}

#ifdef WIFI_TCP
// with lwIP in the image (wifi_net.c): an address by DHCP, then WIFI_LINKS exchanges of the demo's
// 48-byte frame with the TCP peer at SILICA_WIFI_PEER (wifi_secret.h), each on a connection of its own
int spike_net_start(void);
uint32_t spike_net_address(void);
int spike_net_exchange(const char *peer, uint16_t port, const uint8_t *frame, uint32_t len, uint8_t *back);
extern uint32_t spike_net_frames_in, spike_net_bytes_in;
#define frames_in spike_net_frames_in
#define bytes_in spike_net_bytes_in
#ifndef WIFI_LINKS
#define WIFI_LINKS 1
#endif
#ifndef WIFI_PORT
#define WIFI_PORT 4370
#endif
static const uint8_t frame[48] = {
    0x83, 0x68, 0x02, 0x77, 0x05, 0x61, 0x63, 0x63, 0x65, 0x6C, 0x74, 0x00, 0x00, 0x00, 0x04, 0x77,
    0x05, 0x61, 0x74, 0x5F, 0x6D, 0x73, 0x62, 0x00, 0x00, 0x03, 0xE8, 0x77, 0x01, 0x78, 0x61, 0x01,
    0x77, 0x01, 0x79, 0x62, 0xFF, 0xFF, 0xFF, 0xFE, 0x77, 0x01, 0x7A, 0x62, 0x00, 0x00, 0x02, 0x00,
};
#else
static volatile uint32_t frames_in, bytes_in;

static esp_err_t frame_in(void *buffer, uint16_t len, void *eb)
{
    (void)buffer;
    frames_in = frames_in + 1;
    bytes_in = bytes_in + len;
    esp_wifi_internal_free_rx_buffer(eb);
    return ESP_OK;
}
#endif

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

#define STEP(call, name) do { esp_err_t e_ = (call); if (e_ != ESP_OK) { say(name " failed ", e_); return 1; } silica_rt_puts(name " done\n"); } while (0)

long long main(void)
{
    if (spike_flash_map() != 0) {
        silica_rt_puts("flash not mapped\n");
        return 1;
    }
    esp_rom_output_tx_wait_idle(0);
    rtc_clk_config_t clk = RTC_CLK_CONFIG_DEFAULT();
    clk.cpu_freq_mhz = WIFI_CPU_MHZ;
    rtc_clk_init(clk);

#ifdef SPIKE_DEBUG
    void spike_debug_watch(void);
    spike_debug_watch();
#endif
    // what ESP-IDF's start-up does for coexistence before any radio (esp_coex/src/coexist.c)
    extern void *g_coex_adapter_funcs;
    int esp_coex_adapter_register(void *funcs);
    int coex_pre_init(void);
    esp_coex_adapter_register(&g_coex_adapter_funcs);
    coex_pre_init();

    // what ESP-IDF's start-up does for Mbed TLS (mbedtls/port/esp_psa_crypto_init.c): without it every
    // key operation fails, WPA3's among them
    int psa_crypto_init(void);
    int crypto = psa_crypto_init();
    if (crypto != 0) {
        say("psa_crypto_init failed ", (uint32_t)-crypto);
        return 1;
    }

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    cfg.nvs_enable = 0;
#ifdef WIFI_NO_SAE
    // WPA2 only: an access point that offers both WPA2 and WPA3 is joined by WPA2's key exchange
    cfg.feature_caps &= ~(uint64_t)CONFIG_FEATURE_WPA3_SAE_BIT;
#endif
    STEP(esp_wifi_init(&cfg), "wifi init");
#ifdef WIFI_LOG
    // the Wi-Fi library's own log, every module
    esp_wifi_internal_set_log_level(WIFI_LOG_VERBOSE);
    esp_wifi_internal_set_log_mod(WIFI_LOG_MODULE_ALL, WIFI_LOG_SUBMODULE_ALL, true);
#endif
    STEP(esp_wifi_set_mode(WIFI_MODE_STA), "station mode");
    static wifi_config_t sta;
    strncpy((char *)sta.sta.ssid, SILICA_WIFI_SSID, sizeof sta.sta.ssid);
    strncpy((char *)sta.sta.password, SILICA_WIFI_PASSPHRASE, sizeof sta.sta.password);
    STEP(esp_wifi_set_config(WIFI_IF_STA, &sta), "station config");
#ifndef WIFI_TCP
    STEP(esp_wifi_internal_reg_rxcb(WIFI_IF_STA, frame_in), "receive callback");
#endif
#ifdef WIFI_NO_SLEEP
    // the radio stays on between the access point's beacons
    STEP(esp_wifi_set_ps(WIFI_PS_NONE), "power save off");
#endif
    STEP(esp_wifi_start(), "wifi start");

    int connected = 0, tries = 0;
    uint64_t start = spike_ticks(), connected_at = 0;
#ifdef WIFI_TCP
    int net = 0, whole = 0;     // net: 0 not started, 1 waiting for an address, 2 exchanging, 3 done
#endif
    while ((spike_ticks() - start) / 16000000 < WATCH_SECONDS) {
        turn();
#ifdef WIFI_TCP
        if (connected && net == 0) {
            int r = spike_net_start();
            if (r != 0) {
                say("network start failed ", r);
                return 1;
            }
            silica_rt_puts("network started, address asked\n");
            net = 1;
        } else if (net == 1 && spike_net_address() != 0) {
            uint32_t a = spike_net_address();
            spike_put_dec((uint32_t)((spike_ticks() - start) / 16000));
            silica_rt_puts(" ms: address ");
            for (int i = 0; i < 4; i++) {
                spike_put_dec((a >> (8 * i)) & 255);
                silica_rt_puts(i < 3 ? "." : "\n");
            }
            net = 2;
        } else if (net == 2) {
            static uint8_t back[48];
            for (int link = 0; link < WIFI_LINKS; link++) {
                uint64_t t = spike_ticks();
                int step = spike_net_exchange(SILICA_WIFI_PEER, WIFI_PORT, frame, sizeof frame, back);
                silica_rt_puts("link ");
                spike_put_dec((uint32_t)link);
                if (step == 0) {
                    whole++;
                    silica_rt_puts(": frame out 48 bytes, frame in 48 bytes: the same, ms ");
                    spike_put_dec((uint32_t)((spike_ticks() - t) / 16000));
                    silica_rt_puts("\n");
                } else {
                    say(": failed at step ", step);
                }
            }
            net = 3;
            break;
        }
#endif
        int32_t id;
        uint8_t data[48];
        if (!spike_wifi_event(&id, data)) {
            continue;
        }
        spike_put_dec((uint32_t)((spike_ticks() - start) / 16000));
        silica_rt_puts(" ms: ");
        switch (id) {
        case WIFI_EVENT_STA_START:
            silica_rt_puts("station started\n");
            STEP(esp_wifi_scan_start(NULL, false), "scan asked");
            break;
        case WIFI_EVENT_SCAN_DONE: {
            // what the access point of that name advertises (the name itself is not printed)
            static wifi_ap_record_t found[20];
            uint16_t count = 20;
            esp_wifi_scan_get_ap_records(&count, found);
            say("scan done, access points ", count);
            for (int i = 0; i < count; i++) {
                if (strcmp((const char *)found[i].ssid, SILICA_WIFI_SSID) == 0) {
                    silica_rt_puts("  the one named: channel ");
                    spike_put_dec(found[i].primary);
                    silica_rt_puts(", signal -");
                    spike_put_dec((uint32_t)-found[i].rssi);
                    silica_rt_puts(" dBm, security mode ");
                    spike_put_dec(found[i].authmode);
                    silica_rt_puts(", pairwise cipher ");
                    spike_put_dec(found[i].pairwise_cipher);
                    silica_rt_puts("\n");
                }
            }
            STEP(esp_wifi_connect(), "connect asked");
            break;
        }
        case WIFI_EVENT_STA_CONNECTED:
            say("connected, channel ", ((wifi_event_sta_connected_t *)data)->channel);
            connected = 1;
            connected_at = spike_ticks();
            break;
        case WIFI_EVENT_STA_DISCONNECTED:
            say("disconnected, reason ", ((wifi_event_sta_disconnected_t *)data)->reason);
            connected = 0;
            if (++tries < 4) {
                STEP(esp_wifi_connect(), "connect asked");
            }
            break;
        case WIFI_EVENT_STA_BEACON_TIMEOUT:
            silica_rt_puts("beacons missed\n");
            break;
        case WIFI_EVENT_HOME_CHANNEL_CHANGE:
            silica_rt_puts("channel changed\n");
            break;
        default:
            say("event ", id);
            break;
        }
    }
    say("frames in ", frames_in);
    say("bytes in ", bytes_in);
    silica_rt_puts("poll gap ");
    spike_put_dec(POLL_GAP_MS);
    silica_rt_puts(" ms, handlers called ");
    spike_put_dec(spike_handler_calls);
    silica_rt_puts(", switches ");
    spike_put_dec(spike_switches);
    silica_rt_puts(", most memory given ");
    spike_put_dec(spike_arena_used());
    silica_rt_puts(" bytes\n");
    if (connected) {
        say("connected for ms ", (int64_t)((spike_ticks() - connected_at) / 16000));
    }
    silica_rt_puts(connected ? "joined the access point\n" : "not joined\n");
#ifdef WIFI_TCP
    say("exchanges whole ", whole);
    return whole == WIFI_LINKS ? 0 : 1;
#else
    return connected ? 0 : 1;
#endif
}
