/*
   Copyright 2026 COPYRIGHT-HOLDER-PLACEHOLDER (to be decided before this leaves the spike)

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

/* Stage 4 spike of compiler/design_documents/transport_ble_plan.md: ESP-IDF owns the chip and runs
   the Bluetooth controller with no Bluetooth host. Step A: plain C sends one HCI Reset through the
   virtual HCI calls and prints the controller's answer. Step B: the Silica program built into the
   silica_guest component (run_guest.sh) runs on Silica's two schedulers. Throwaway. */

#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_bt.h"
#include "esp_heap_caps.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "silica_guest.h"

static SemaphoreHandle_t answered;
static uint8_t event[64];
static uint16_t event_len;

static void controller_ready(void) {}

/* Called from the controller's task: copy the packet and wake the sender. */
static int from_controller(uint8_t *data, uint16_t len) {
    event_len = len < sizeof event ? len : sizeof event;
    memcpy(event, data, event_len);
    xSemaphoreGive(answered);
    return 0;
}

static esp_vhci_host_callback_t callbacks = { controller_ready, from_controller };

static void show_heap(const char *when) {
    printf("heap %s: free %u, largest block %u, internal free %u\n", when,
           (unsigned)esp_get_free_heap_size(),
           (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DEFAULT),
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
}

void app_main(void) {
    printf("SPIKE:START\n");
    show_heap("at start");
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        ret = nvs_flash_init();
    }
    printf("nvs: %d\n", (int)ret);
    esp_bt_controller_config_t cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ret = esp_bt_controller_init(&cfg);
    printf("controller init: %d\n", (int)ret);
    ret = esp_bt_controller_enable(ESP_BT_MODE_BLE);
    printf("controller enable: %d\n", (int)ret);
    show_heap("with the controller up");

    answered = xSemaphoreCreateBinary();
    esp_vhci_host_register_callback(&callbacks);
    for (int i = 0; i < 50 && !esp_vhci_host_check_send_available(); i++) vTaskDelay(pdMS_TO_TICKS(20));
    /* HCI command packet: type 01, opcode 0x0C03 (Reset), no parameters. */
    static uint8_t reset[] = { 0x01, 0x03, 0x0C, 0x00 };
    esp_vhci_host_send_packet(reset, sizeof reset);
    printf("sent HCI Reset: 01030c00\n");
    if (xSemaphoreTake(answered, pdMS_TO_TICKS(2000)) == pdTRUE) {
        printf("controller answered: ");
        for (uint16_t i = 0; i < event_len; i++) printf("%02x", event[i]);
        printf("\n");
        /* Command Complete for Reset, status 0: 04 0e 04 xx 03 0c 00 */
        int ok = event_len == 7 && event[0] == 0x04 && event[1] == 0x0e && event[4] == 0x03 && event[5] == 0x0c && event[6] == 0x00;
        printf("SPIKE:%s\n", ok ? "RESET-OK" : "RESET-UNEXPECTED");
    } else {
        printf("SPIKE:NO-ANSWER\n");
    }
    printf("running on core %d, %d cores\n", xPortGetCoreID(), portNUM_PROCESSORS);
    fflush(stdout);
    /* Step B: the Silica program, on Silica's two schedulers, with the controller still up. */
    silica_guest_run();
    while (!silica_guest_ended()) vTaskDelay(pdMS_TO_TICKS(50));
    vTaskDelay(pdMS_TO_TICKS(200));
    printf("\nSPIKE:SILICA-ENDED\n");
    show_heap("after the Silica program");
    while (1) vTaskDelay(pdMS_TO_TICKS(5000));
}
