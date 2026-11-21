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

// Route R1 spike, step 2 (transport_ble_plan.md stage 12): how long may the Bluetooth controller be
// kept waiting? Added to a guest image (BOARD_EXTRA_SOURCES of transport_ble_demo/run_board_peer.sh),
// it starts a task on the controller's core, above the controller's own task, that every
// HOLD_PERIOD_MS milliseconds keeps the core for HOLD_US microseconds:
//
//   HOLD_MODE 1  by running: the controller's task and the host's wait, its interrupt handlers run;
//   HOLD_MODE 2  with interrupts masked up to level 3: the controller's handlers wait as well.
//
// The link is then watched from both ends. Set the three with BOARD_CFLAGS, as -DHOLD_US=20000.

#include <stdint.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_rom_sys.h"

#ifndef HOLD_MODE
#define HOLD_MODE 1
#endif
#ifndef HOLD_US
#define HOLD_US 1000
#endif
#ifndef HOLD_PERIOD_MS
#define HOLD_PERIOD_MS 100
#endif

static void hold_task(void *arg)
{
    (void)arg;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(HOLD_PERIOD_MS));
#if HOLD_MODE == 2
        unsigned state = portSET_INTERRUPT_MASK_FROM_ISR();
        esp_rom_delay_us(HOLD_US);
        portCLEAR_INTERRUPT_MASK_FROM_ISR(state);
#else
        esp_rom_delay_us(HOLD_US);
#endif
    }
}

static void __attribute__((constructor)) hold_start(void)
{
    esp_rom_printf("spike: hold mode %d, %d us every %d ms\n", HOLD_MODE, HOLD_US, HOLD_PERIOD_MS);
    xTaskCreatePinnedToCore(hold_task, "spike_hold", 2048, NULL, configMAX_PRIORITIES - 1, NULL, 0);
}
