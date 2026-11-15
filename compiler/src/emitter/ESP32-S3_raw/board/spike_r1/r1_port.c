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
// wrapper (compiler/stdlib/ble/silica_ble_nimble.c) on the chip the bare-metal runtime owns. The
// runtime is built for one core, core 0, where the program's actors run; core 1 is the Bluetooth
// tasks' alone, so an actor's long turn keeps nothing of Bluetooth waiting and no task ever takes a
// core from an actor.
//
//   silica_rt_board_prepare   called by the runtime's start before main (rt_start.S): maps the flash,
//                             where the program's own code and the Bluetooth libraries' are
//                             (spike_flash.c), brings the clocks up (ESP-IDF's rtc_clk_init) and
//                             starts core 1.
//   silica_rt_board_core1     core 1's entry (rt_start.S): on a stack of its own it passes control
//                             round the controller's and NimBLE's tasks and runs the timers for ever
//                             (hci_shim.c spike_bt_core_loop); the controller's handler interrupts it.

#include <stdint.h>
#include "soc/rtc.h"
#include "esp_rom_serial_output.h"

typedef struct {
    int64_t tag, value, error_code;
} tagged;
int spike_flash_map(void);
void spike_bt_core_loop(void);
void spike_co_start(uint32_t save[2], uint32_t *stack_top, void (*fn)(void *), void *arg);
void silica_rt_start_app_cpu(void);

// The processor's clock in MHz: 80, 160 or 240, all from the 480 MHz PLL; the bus the radio is on stays
// at 80 MHz. run_r1_peer.sh sets it from R1_CPU_MHZ.
#ifndef R1_CPU_MHZ
#define R1_CPU_MHZ 80
#endif

void silica_rt_board_prepare(void)
{
    if (spike_flash_map() != 0) {
        return;
    }
    esp_rom_output_tx_wait_idle(0);
    rtc_clk_config_t clk = RTC_CLK_CONFIG_DEFAULT();
    clk.cpu_freq_mhz = R1_CPU_MHZ;
    rtc_clk_init(clk);
    silica_rt_start_app_cpu();
}

static uint32_t core1_stack[2048] __attribute__((aligned(16)));

static void core1_loop(void *unused)
{
    (void)unused;
    spike_bt_core_loop();
}

// Core 1 arrives on the runtime's 2 KB boot stack: it moves to its own and does not come back.
void silica_rt_board_core1(void)
{
    static uint32_t left[2];
    spike_co_start(left, &core1_stack[2048 - 16], core1_loop, NULL);
}
