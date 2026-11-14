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

/* The Fifi wrapper around NimBLE, ESP-IDF's Bluetooth host, for a Silica program that runs on the
   ESP32-S3 as a guest of ESP-IDF (transport_ble_plan.md §2.1, stage 6: as far as advertising). It is
   compiled into the guest image as ESP-IDF code (board/guest/tools/build_image.sh). One Silica actor,
   the radio actor (dangerous_ble_radio), makes every call here.

   No call waits for the radio. A request is handed to NimBLE and answers at once; what NimBLE reports
   later (the host is ready, advertising ended, a central connected or left) is an event. NimBLE's
   callbacks run in NimBLE's own task and must not call the Silica runtime, so each puts one event in a
   FreeRTOS queue, and the radio actor takes them out with silica_nimble_event.

   Result conventions (as compiler/stdlib/ble/silica_ble.m): { tag, value, error_code } with tag 0 = ok,
   1 = error, 2 = nothing yet. Error codes: 6 bad UUID text, 7 the host is not ready (no :synced event
   yet), 8 the event queue could not be made, 1000 + n NimBLE's return code n, and for silica_nimble_start
   2000 + n ESP-IDF's error n.

   Events (the value of silica_nimble_event; the two fields of the event are read with
   silica_nimble_event_field):
     1 synced          the host and the controller agree: requests are accepted from now on
     2 reset           the host lost the controller; field 0 the reason. A :synced follows when it is back
     3 advertising ended without a connection; field 0 the reason
     4 connected       field 0 the connection's handle, field 1 the status (0 when the link is up)
     5 disconnected    field 0 the connection's handle, field 1 the reason

   Advertising. The advertisement carries the flags and the service's UUID; the scan response carries
   the device's name, "Silica". The UUID text is that of the Mac's wrapper: 4, 8 or 36 characters of
   the usual hexadecimal form, or empty for the Nordic UART Service. Advertising is connectable and
   stops when a central connects. */

#include <stdint.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "esp_err.h"
#include "esp_heap_caps.h"
#include "nvs_flash.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"

typedef struct silica_nimble_tagged {
    int64_t tag;
    int64_t value;
    int64_t error_code;
} silica_nimble_tagged;

typedef struct { uint8_t kind; int32_t field[2]; } radio_event;

enum { EV_SYNCED = 1, EV_RESET = 2, EV_ADV_ENDED = 3, EV_CONNECTED = 4, EV_DISCONNECTED = 5 };

static QueueHandle_t events;         /* from NimBLE's task to the radio actor */
static volatile int synced;          /* written by NimBLE's task, read by the radio actor's calls */
static uint8_t own_addr_type;
static int started;
static radio_event last_event;       /* the event silica_nimble_event answered last */

static silica_nimble_tagged ok(int64_t value) { return (silica_nimble_tagged){ 0, value, 0 }; }
static silica_nimble_tagged fail(int64_t code) { return (silica_nimble_tagged){ 1, 0, code }; }

/* On NimBLE's task. A full queue drops the event: the radio actor has stopped taking them. */
static void post(uint8_t kind, int32_t a, int32_t b) {
    radio_event e = { kind, { a, b } };
    xQueueSend(events, &e, 0);
}

static void on_sync(void) {
    if (ble_hs_util_ensure_addr(0) != 0 || ble_hs_id_infer_auto(0, &own_addr_type) != 0) {
        post(EV_RESET, -1, 0);
        return;
    }
    synced = 1;
    post(EV_SYNCED, own_addr_type, 0);
}

static void on_reset(int reason) {
    synced = 0;
    post(EV_RESET, reason, 0);
}

static int on_gap_event(struct ble_gap_event *event, void *arg) {
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        post(EV_CONNECTED, event->connect.conn_handle, event->connect.status);
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        post(EV_DISCONNECTED, event->disconnect.conn.conn_handle, event->disconnect.reason);
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        post(EV_ADV_ENDED, event->adv_complete.reason, 0);
        break;
    default:
        break;
    }
    return 0;
}

static void host_task(void *param) {
    (void)param;
    nimble_port_run();               /* returns when nimble_port_stop is called */
    nimble_port_freertos_deinit();
}

/* Starts the controller and the host, once. The :synced event says when requests are accepted. */
silica_nimble_tagged silica_nimble_start(int64_t reserved) {
    (void)reserved;
    if (started) return ok(0);
    if (events == NULL) events = xQueueCreate(16, sizeof(radio_event));
    if (events == NULL) return fail(8);
    /* The controller keeps its calibration data in NVS. */
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        ret = nvs_flash_init();
    }
    if (ret != ESP_OK) return fail(2000 + ret);
    ret = nimble_port_init();
    if (ret != ESP_OK) return fail(2000 + ret);
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    ble_svc_gap_init();
    ble_svc_gap_device_name_set("Silica");
    ret = nimble_port_freertos_init(host_task);
    if (ret != ESP_OK) return fail(2000 + ret);
    started = 1;
    return ok(0);
}

/* The next event, waiting up to timeout_ms for one (0: only look). tag 2 when there is none. */
silica_nimble_tagged silica_nimble_event(int64_t timeout_ms) {
    if (events == NULL) return (silica_nimble_tagged){ 2, 0, 0 };
    TickType_t ticks = timeout_ms <= 0 ? 0 : pdMS_TO_TICKS((uint32_t)timeout_ms);
    if (xQueueReceive(events, &last_event, ticks) != pdTRUE) return (silica_nimble_tagged){ 2, 0, 0 };
    return ok(last_event.kind);
}

/* Field 0 or 1 of the event silica_nimble_event answered last. */
silica_nimble_tagged silica_nimble_event_field(int64_t index) {
    if (index < 0 || index > 1) return fail(1);
    return ok(last_event.field[index]);
}

static int hex_digit(uint8_t c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* 4, 8 or 36 characters (8-4-4-4-12), or none for the Nordic UART Service. 0 when it reads. */
static int uuid_from_text(const uint8_t *text, uint64_t len, ble_uuid_any_t *out) {
    static const uint8_t nus[] = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
    uint8_t bytes[16];
    int n = 0;
    if (len == 0) { text = nus; len = 36; }
    if (len != 4 && len != 8 && len != 36) return -1;
    for (uint64_t i = 0; i < len; ) {
        if (len == 36 && (i == 8 || i == 13 || i == 18 || i == 23)) {
            if (text[i] != '-') return -1;
            i++;
            continue;
        }
        int hi = hex_digit(text[i]), lo = hex_digit(text[i + 1]);
        if (hi < 0 || lo < 0) return -1;
        bytes[n++] = (uint8_t)(hi << 4 | lo);
        i += 2;
    }
    if (n == 2) {
        out->u16.u.type = BLE_UUID_TYPE_16;
        out->u16.value = (uint16_t)(bytes[0] << 8 | bytes[1]);
    } else if (n == 4) {
        out->u32.u.type = BLE_UUID_TYPE_32;
        out->u32.value = (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 | (uint32_t)bytes[2] << 8 | bytes[3];
    } else {
        out->u128.u.type = BLE_UUID_TYPE_128;
        for (int i = 0; i < 16; i++) out->u128.value[i] = bytes[15 - i];   /* NimBLE keeps it low byte first */
    }
    return 0;
}

/* Advertises the service whose UUID is the text, until a central connects or silica_nimble_stop_advertising.
   Called again while advertising, it advertises the new service. */
silica_nimble_tagged silica_nimble_advertise(const uint8_t *uuid_ptr, uint64_t uuid_len) {
    static ble_uuid_any_t uuid;      /* the fields point at it until advertising starts */
    struct ble_hs_adv_fields fields, response;
    struct ble_gap_adv_params params;
    int rc;
    if (!synced) return fail(7);
    if (uuid_from_text(uuid_ptr, uuid_len, &uuid) != 0) return fail(6);
    if (ble_gap_adv_active()) ble_gap_adv_stop();

    memset(&fields, 0, sizeof fields);
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    switch (uuid.u.type) {
    case BLE_UUID_TYPE_16:  fields.uuids16 = &uuid.u16;   fields.num_uuids16 = 1;  fields.uuids16_is_complete = 1;  break;
    case BLE_UUID_TYPE_32:  fields.uuids32 = &uuid.u32;   fields.num_uuids32 = 1;  fields.uuids32_is_complete = 1;  break;
    default:                fields.uuids128 = &uuid.u128; fields.num_uuids128 = 1; fields.uuids128_is_complete = 1; break;
    }
    rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) return fail(1000 + rc);

    memset(&response, 0, sizeof response);
    response.name = (const uint8_t *)ble_svc_gap_device_name();
    response.name_len = (uint8_t)strlen(ble_svc_gap_device_name());
    response.name_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&response);
    if (rc != 0) return fail(1000 + rc);

    memset(&params, 0, sizeof params);
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    rc = ble_gap_adv_start(own_addr_type, NULL, BLE_HS_FOREVER, &params, on_gap_event, NULL);
    if (rc != 0) return fail(1000 + rc);
    return ok(0);
}

silica_nimble_tagged silica_nimble_stop_advertising(int64_t reserved) {
    (void)reserved;
    if (!synced) return fail(7);
    if (!ble_gap_adv_active()) return ok(0);
    int rc = ble_gap_adv_stop();
    if (rc != 0) return fail(1000 + rc);
    return ok(0);
}

/* ESP-IDF's internal heap, in bytes: 0 free now, 1 the least that has been free since start, 2 the
   largest block that can be taken now. What the radio leaves is what Silica's block can grow by. */
silica_nimble_tagged silica_nimble_memory(int64_t which) {
    switch (which) {
    case 0: return ok((int64_t)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    case 1: return ok((int64_t)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL));
    case 2: return ok((int64_t)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
    default: return fail(1);
    }
}
