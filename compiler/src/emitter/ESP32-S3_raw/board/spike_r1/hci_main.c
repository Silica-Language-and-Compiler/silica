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

// Route R1 spike, step 3 (transport_ble_plan.md stage 12): on a chip the bare-metal runtime owns, with
// every interrupt disabled, Espressif's Bluetooth controller is started and asked one question over HCI.
// The controller is the closed libbtdm_app.a under ESP-IDF's own glue (bt.c, as compiled for the guest
// image); hci_shim.c answers what the glue asks of an operating system. Sends HCI Reset and prints the
// event the controller answers with: 04 0E 04 05 03 0C 00 is "command complete, reset, status 0". It then
// advertises, for a scanner to hear.

#include <stdint.h>
#include "soc/rtc.h"
#include "esp_rom_serial_output.h"
#include "esp_bt.h"

void silica_rt_puts(const char *s);
void spike_put_dec(uint32_t n);
uint64_t spike_ticks(void);
void spike_yield(void);
uint32_t spike_arena_used(void);
extern uint32_t spike_handler_calls, spike_switches;

static void put_hex(const uint8_t *p, int n)
{
    static const char digits[] = "0123456789ABCDEF";
    char buf[4];
    for (int i = 0; i < n; i++) {
        buf[0] = digits[p[i] >> 4];
        buf[1] = digits[p[i] & 15];
        buf[2] = ' ';
        buf[3] = 0;
        silica_rt_puts(buf);
    }
}

#ifndef ADVERTISE_SECONDS
#define ADVERTISE_SECONDS 30
#endif

static uint8_t event[64];
static volatile int event_len;

static void host_send_available(void)
{
}

static int host_recv(uint8_t *data, uint16_t len)
{
    if (event_len == 0) {
        int n = len > sizeof(event) ? (int)sizeof(event) : len;
        for (int i = 0; i < n; i++) {
            event[i] = data[i];
        }
        event_len = n;
    }
    return 0;
}

static const esp_vhci_host_callback_t callbacks = { host_send_available, host_recv };

// Lets the controller work for the given time, or until an event has come.
static void run_for(uint32_t ms)
{
    uint64_t start = spike_ticks();
    while (event_len == 0 && (spike_ticks() - start) / 16000 < ms) {
        spike_yield();
    }
}

static int ask(const char *what, uint8_t *command, uint16_t len)
{
    event_len = 0;
    run_for(50);
    if (!esp_vhci_host_check_send_available()) {
        silica_rt_puts("hci: the controller will not take a command\n");
        return 1;
    }
    silica_rt_puts("hci: ");
    silica_rt_puts(what);
    silica_rt_puts(" > ");
    put_hex(command, len);
    silica_rt_puts("\n");
    esp_vhci_host_send_packet(command, len);
    run_for(3000);
    if (event_len == 0) {
        silica_rt_puts("hci: no answer in 3 s\n");
        return 1;
    }
    silica_rt_puts("hci: < ");
    put_hex(event, event_len);
    silica_rt_puts("\n");
    return 0;
}

long long main(void)
{
    esp_rom_output_tx_wait_idle(0);
    rtc_clk_config_t clk = RTC_CLK_CONFIG_DEFAULT();
    clk.cpu_freq_mhz = 80;
    rtc_clk_init(clk);
    silica_rt_puts("clocks up\n");

    esp_bt_controller_config_t cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    int rc = esp_bt_controller_init(&cfg);
    silica_rt_puts("controller init: ");
    spike_put_dec((uint32_t)rc);
    silica_rt_puts("\n");
    if (rc != 0) {
        return 1;
    }
    rc = esp_bt_controller_enable(ESP_BT_MODE_BLE);
    silica_rt_puts("controller enable: ");
    spike_put_dec((uint32_t)rc);
    silica_rt_puts("\n");
    if (rc != 0) {
        return 1;
    }
    esp_vhci_host_register_callback(&callbacks);

    static uint8_t reset[] = { 0x01, 0x03, 0x0C, 0x00 };
    static uint8_t read_address[] = { 0x01, 0x09, 0x10, 0x00 };
    int failed = ask("reset", reset, sizeof(reset));
    failed += ask("read address", read_address, sizeof(read_address));

    // Advertise the Nordic UART Service as "R1" every 100 ms for ADVERTISE_SECONDS, for a scanner to
    // hear: the radio in use, its interrupts served by polling.
    static uint8_t parameters[] = { 0x01, 0x06, 0x20, 0x0F, 0xA0, 0x00, 0xA0, 0x00, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0x07, 0x00 };
    static uint8_t data[4 + 32] = { 0x01, 0x08, 0x20, 0x20, 25,
        0x02, 0x01, 0x06,
        0x11, 0x07, 0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0, 0x93, 0xF3, 0xA3, 0xB5, 0x01, 0x00, 0x40, 0x6E,
        0x03, 0x09, 'R', '1' };
    static uint8_t enable[] = { 0x01, 0x0A, 0x20, 0x01, 0x01 };
    failed += ask("advertising parameters", parameters, sizeof(parameters));
    failed += ask("advertising data", data, sizeof(data));
    failed += ask("advertise", enable, sizeof(enable));
    uint32_t before = spike_handler_calls;
    uint64_t start = spike_ticks();
    while ((spike_ticks() - start) / 16000000 < ADVERTISE_SECONDS) {
        spike_yield();
    }
    silica_rt_puts("advertised for ");
    spike_put_dec(ADVERTISE_SECONDS);
    silica_rt_puts(" s, handlers called in that time ");
    spike_put_dec(spike_handler_calls - before);
    silica_rt_puts("\n");

    silica_rt_puts("handlers called ");
    spike_put_dec(spike_handler_calls);
    silica_rt_puts(", switches ");
    spike_put_dec(spike_switches);
    silica_rt_puts(", memory given ");
    spike_put_dec(spike_arena_used());
    silica_rt_puts(" bytes\n");
    return failed;
}
