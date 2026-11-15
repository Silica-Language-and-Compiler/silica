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

// Route R1 (transport_ble_plan.md stage 12, part 5): a Silica program's radio actor calls the NimBLE
// wrapper (compiler/stdlib/ble/silica_ble_nimble.c) on the chip the bare-metal runtime owns.
//
//   silica_rt_board_prepare   called by the runtime's start before main (rt_start.S): maps the flash,
//                             where the program's own code and the Bluetooth libraries' are
//                             (spike_flash.c), and brings the clocks up (ESP-IDF's rtc_clk_init).
//   silica_nimble_event       the image links the program's calls to it through here (the linker's
//                             --wrap). It is the radio actor's poll, every 20 ms or less: the
//                             controller's and NimBLE's tasks and the timers get their turns here
//                             (hci_shim.c spike_yield), on the stack of the actor's foreign call.
//
// The controller's handler comes by the runtime's level-3 interrupt and needs none of this.

#include <stdint.h>
#include "soc/rtc.h"
#include "esp_rom_serial_output.h"

typedef struct {
    int64_t tag, value, error_code;
} tagged;
tagged __real_silica_nimble_event(int64_t timeout_ms);
int spike_flash_map(void);
void spike_yield(void);

static int ready;

void silica_rt_board_prepare(void)
{
    if (spike_flash_map() != 0) {
        return;
    }
    esp_rom_output_tx_wait_idle(0);
    rtc_clk_config_t clk = RTC_CLK_CONFIG_DEFAULT();
    clk.cpu_freq_mhz = 80;
    rtc_clk_init(clk);
    ready = 1;
}

tagged __wrap_silica_nimble_event(int64_t timeout_ms)
{
    if (ready) {
        for (int pass = 0; pass < 8; pass++) {
            spike_yield();
        }
    }
#ifdef R1_DEBUG
    static uint32_t polls;
    extern uint32_t spike_handler_calls, spike_switches;
    void silica_rt_puts(const char *s);
    void spike_put_dec(uint32_t n);
    uint64_t spike_ticks(void);
    tagged r = __real_silica_nimble_event(timeout_ms);
    if ((++polls & 63) == 0 || polls <= 4 || r.tag == 0) {
        silica_rt_puts("r1: ");
        spike_put_dec((uint32_t)(spike_ticks() / 16000));
        silica_rt_puts(" ms, poll ");
        spike_put_dec(polls);
        silica_rt_puts(" handlers ");
        spike_put_dec(spike_handler_calls);
        silica_rt_puts(" switches ");
        spike_put_dec(spike_switches);
        if (r.tag == 0) {
            silica_rt_puts(" event ");
            spike_put_dec((uint32_t)r.value);
        }
        silica_rt_puts("\n");
    }
    return r;
#endif
    return __real_silica_nimble_event(timeout_ms);
}

#ifdef R1_DEBUG
// the start, said on the console as it goes in and comes out (the image wraps it too when debugging)
tagged __real_silica_nimble_start(int64_t reserved);
tagged __wrap_silica_nimble_start(int64_t reserved)
{
    void silica_rt_puts(const char *s);
    silica_rt_puts("r1: start in\n");
    tagged r = __real_silica_nimble_start(reserved);
    silica_rt_puts(r.tag == 0 ? "r1: start out, ok\n" : "r1: start out, failed\n");
    return r;
}
#endif
