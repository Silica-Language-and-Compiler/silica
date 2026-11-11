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

/* Stage 4 spike: the Fifi wrapper between a Silica program and ESP-IDF's virtual HCI calls. One
   command out, one event back, bounded by a timeout. The board's emitter does not yet take a record
   back from a foreign call (only a scalar, or the text record a string is made from), so the result
   is one integer: the event's length, or -1 error, -2 timeout. Throwaway. */

#include <stdint.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "esp_bt.h"

typedef struct { int64_t tag; const uint8_t *text_ptr; uint64_t text_len; int64_t error_code; } silica_hci_bytes;

static SemaphoreHandle_t answered;
static uint8_t event[260];
static uint16_t event_len;

static void controller_ready(void) {}

/* On the controller's task: keep the packet, wake the caller. */
static int from_controller(uint8_t *data, uint16_t len) {
    event_len = len < sizeof event ? len : sizeof event;
    memcpy(event, data, event_len);
    xSemaphoreGive(answered);
    return 0;
}

static esp_vhci_host_callback_t callbacks = { controller_ready, from_controller };

/* Sends HCI Reset and waits up to timeout_ms for the controller's event; answers its length. */
int64_t silica_hci_reset(int64_t timeout_ms) {
    static uint8_t reset[] = { 0x01, 0x03, 0x0C, 0x00 };
    if (answered == NULL) {
        answered = xSemaphoreCreateBinary();
        if (answered == NULL) return -1;
    }
    esp_vhci_host_register_callback(&callbacks);
    xSemaphoreTake(answered, 0);
    event_len = 0;
    if (!esp_vhci_host_check_send_available()) return -1;
    esp_vhci_host_send_packet(reset, sizeof reset);
    if (xSemaphoreTake(answered, pdMS_TO_TICKS(timeout_ms < 0 ? 0 : (uint32_t)timeout_ms)) != pdTRUE) return -2;
    return event_len;
}

/* The bytes of the last event: the wrapper's own memory, valid until its next call (the board's
   string-out rule, rt_ffi.S). */
silica_hci_bytes silica_hci_take(int64_t handle) {
    silica_hci_bytes r = { 0, event, event_len, 0 };
    (void)handle;
    return r;
}
