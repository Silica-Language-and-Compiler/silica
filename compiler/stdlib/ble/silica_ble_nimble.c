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
   ESP32-S3 as a guest of ESP-IDF (transport_ble_plan.md §2.1; stage 6 advertising, stage 7 the
   peripheral role, stage 9 the central role: one service and one link at a time). It is
   compiled into the guest image as ESP-IDF code (board/guest/tools/build_image.sh). One Silica actor,
   the radio actor (dangerous_ble_radio), makes every call here.

   No call waits for the radio. A request is handed to NimBLE and answers at once; what NimBLE reports
   later (the host is ready, advertising ended, a central connected or left) is an event. NimBLE's
   callbacks run in NimBLE's own task and must not call the Silica runtime, so each puts one event in a
   FreeRTOS queue, and the radio actor takes them out with silica_nimble_event.

   Result conventions (as compiler/stdlib/ble/silica_ble.m): { tag, value, error_code } with tag 0 = ok,
   1 = error, 2 = nothing yet. Error codes: 3 no central is subscribed, 4 a segment that is empty or
   longer than the link carries, 5 eight segments already wait to be sent, 6 bad UUID text, 7 the host
   is not ready (no :synced event yet), 8 a queue could not be made, 9 the host is already started
   with another service, 1000 + n NimBLE's return code n, and for silica_nimble_start 2000 + n ESP-IDF's
   error n.

   Events (the value of silica_nimble_event; the two fields of the event are read with
   silica_nimble_event_field):
     1 synced          the host and the controller agree: requests are accepted from now on
     2 reset           the host lost the controller; field 0 the reason. A :synced follows when it is back
     3 advertising ended without a connection; field 0 the reason
     4 connected       field 0 the connection's handle, field 1 the status (0 when the link is up)
     5 disconnected    field 0 the connection's handle, field 1 the reason (NimBLE's: 0x200 + the
                       controller's code, so 0x213 the peer ended the link, 0x216 this end did,
                       0x208 the link was lost)
     6 subscribed      field 0 the connection's handle, field 1 whether the central now takes
                       indications (1) or has stopped (0)
     7 sent            field 0 the connection's handle, field 1 0 when the central confirmed the
                       segment, otherwise NimBLE's code: the segment was not delivered
     8 written         field 0 the connection's handle: the peer sent a segment (a central's write, a
                       peripheral's indication), which waits for silica_nimble_recv. One event for
                       each segment, in the order things happened
     9 fault           field 0 the connection's handle, field 1 why the peripheral this end connected
                       to cannot be used: 1 it does not have the service, 2 the service lacks a
                       characteristic to write or one that indicates, 3 that one cannot be subscribed
                       to, 4 it sent a segment while eight waited untaken, 5 it requires an encrypted
                       link and the pairing failed, otherwise 1000 + NimBLE's code. The connection is
                       being ended

   Advertising. The advertisement carries the flags and the service's UUID; the scan response carries
   the device's name, "Silica". The UUID text is that of the Mac's wrapper: 4, 8 or 36 characters of
   the usual hexadecimal form, or empty for the Nordic UART Service. Advertising is connectable and
   stops when a central connects.

   The service (silica_nimble_serve, before silica_nimble_start: NimBLE takes its attribute table when
   the host starts). Two characteristics, as the Mac's wrapper publishes them: the one the central
   writes, with response, at the service's UUID plus 1 in its first group, and the one this end
   indicates on at plus 2. One central at a time: advertising stops when it connects.
     In:  a write is one segment. It is kept in a queue of eight until silica_nimble_recv takes it, and
          a :written event says it is there; a write that finds the queue full (or no room for its
          event) is refused (insufficient resources), so the central sees that segment fail and the
          others stay in order.
     Out: silica_nimble_send queues one segment, at most eight. ATT allows one indication at a time, so
          the next goes out when the central has confirmed the one before; each ends in a :sent event.
   The largest segment is the connection's ATT_MTU minus 3 (silica_nimble_mtu), never more than
   SEG_MAX, which follows NimBLE's preferred MTU (CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU, 256).

   Pairing and encryption (stage 10). The peripheral decides. As peripheral this end requires an
   encrypted link: it asks its central to pair as soon as it is connected, its characteristic refuses
   a write and its subscription until the link is encrypted, and the :subscribed event comes only
   then; a central that does not pair gets nothing, and one whose pairing fails is disconnected. As
   central this end pairs when the peripheral asks or refuses the subscription for want of
   encryption, and takes an open link from a peripheral that asks for none (a program on a Mac:
   macOS lets only an application with a window pair as peripheral). The pairing is LE Secure
   Connections with no code ("Just Works"): it keeps a listener out, and does not prove who the peer
   is. No keys are kept, so every link pairs afresh and neither end can hold keys the other has lost.
   A Mac asks its user to approve each pairing. For tests with nobody at the central,
   SILICA_BLE_OPEN_LINK (below) builds a peripheral that asks for no pairing.

   The central role (silica_nimble_seek, once the host is ready). This end scans for a peripheral that
   advertises the service, connects, exchanges the MTU, finds the service's characteristic to write
   and the one that indicates (by their properties, as the Mac's wrapper does) and subscribes; the
   :subscribed event then says the link is up. A connection that fails, or a peripheral that goes
   before that, is a :connected event with a status or a :disconnected event, and the caller seeks
   again; a peripheral without the service's characteristics is a :fault event.
     Out: silica_nimble_send queues one segment; it goes out as a write with response when the one
          before has been answered, and ends in a :sent event.
     In:  an indication is one segment, kept in the queue of eight with a :written event. NimBLE
          confirms an indication before this code sees it, so one that finds the queue full cannot
          be refused: the link is ended with a :fault event (4), and nothing is lost in silence. */

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "esp_err.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

void ble_store_config_init(void);    /* NimBLE's key store, which has no header of its own */

typedef struct silica_nimble_tagged {
    int64_t tag;
    int64_t value;
    int64_t error_code;
} silica_nimble_tagged;

/* A foreign result that carries bytes: the board's layout of the Silica "struct" result, four
   8-byte words (as trials/ffi_addition/fixtures/board/ESP32-S3_raw/src/silica_text_board.c). The
   bytes stay in a static buffer; the Silica side copies them out. */
typedef struct silica_nimble_bytes {
    int64_t tag;
    const uint8_t *text_ptr;
    uint64_t text_len;
    int64_t error_code;
} silica_nimble_bytes;
_Static_assert(offsetof(silica_nimble_bytes, text_ptr) == 8, "text_ptr at 8");
_Static_assert(offsetof(silica_nimble_bytes, text_len) == 16, "text_len at 16");
_Static_assert(sizeof(silica_nimble_bytes) == 32, "32-byte result");

typedef struct { uint8_t kind; int32_t field[2]; } radio_event;

enum { EV_SYNCED = 1, EV_RESET = 2, EV_ADV_ENDED = 3, EV_CONNECTED = 4, EV_DISCONNECTED = 5,
       EV_SUBSCRIBED = 6, EV_SENT = 7, EV_WRITTEN = 8, EV_FAULT = 9 };

#define SEG_MAX (MYNEWT_VAL(BLE_ATT_PREFERRED_MTU) - 3)
#define SEGMENTS 8
typedef struct { uint16_t len; uint8_t bytes[SEG_MAX]; } segment;

static QueueHandle_t events;         /* from NimBLE's task to the radio actor */
static volatile int synced;          /* written by NimBLE's task, read by the radio actor's calls */
static uint8_t own_addr_type;
static int started;
static radio_event last_event;       /* the event silica_nimble_event answered last */

/* The service. `link` and `subscribed` are written by NimBLE's task and read by the radio actor's calls. */
static int serving;                  /* silica_nimble_serve has named the service */
static volatile int seeking;         /* scanning for, or connecting to, a peripheral with seek_uuid */
static ble_uuid_any_t seek_uuid;
static volatile int central;         /* this end is the central of `link` */
static uint16_t peer_start, peer_end;        /* the peripheral's service */
static uint16_t peer_rx, peer_tx, peer_tx_end, peer_cccd;   /* its characteristics' value handles; the indicated one's descriptors */
static int peer_tx_indicates;
static ble_uuid_any_t service_uuid, rx_uuid, tx_uuid;
static uint16_t tx_handle;           /* the indicated characteristic's value handle */
static volatile uint16_t link = BLE_HS_CONN_HANDLE_NONE;
static volatile int subscribed;
static volatile int encrypted;       /* the link is encrypted; as peripheral nothing passes on it before */

/* A switch for tests that run with nobody at the central: compiled with SILICA_BLE_OPEN_LINK (BOARD_CFLAGS
   of the image builders) a peripheral asks for no pairing and its characteristics for no encryption. A
   Mac asks its user to approve every pairing in a dialog, and with no keys kept every link is one. */
#ifdef SILICA_BLE_OPEN_LINK
#define ENC_WRITE 0
#define ENC_INDICATE 0
#else
#define ENC_WRITE BLE_GATT_CHR_F_WRITE_ENC
#define ENC_INDICATE BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC
#endif
static int subscribe_again;          /* as central: the subscription was refused for want of encryption */
static QueueHandle_t rx_queue;       /* segments the central wrote, until silica_nimble_recv */
static QueueHandle_t tx_queue;       /* segments waiting for the indication before them */
static SemaphoreHandle_t tx_lock;    /* guards tx_in_flight and the taking of tx_queue */
static int tx_in_flight;             /* an indication waits for the central's confirmation */
static segment tx_now, rx_now;       /* under tx_lock; the radio actor's last silica_nimble_recv */
static int64_t arg_a;                /* silica_nimble_set_args, for the calls that take bytes */

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

static void send_next(void);

/* On NimBLE's task: the peripheral answered this end's write. */
static int on_written(uint16_t conn_handle, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg) {
    (void)attr; (void)arg;
    xSemaphoreTakeRecursive(tx_lock, portMAX_DELAY);
    if (tx_in_flight) {
        tx_in_flight = 0;
        post(EV_SENT, conn_handle, error->status);
        send_next();
    }
    xSemaphoreGiveRecursive(tx_lock);
    return 0;
}

/* With tx_lock held: sends the next waiting segment unless one is in flight. A segment NimBLE refuses
   ends in a :sent event with its code, and the one after it is tried. */
static void send_next(void) {
    while (!tx_in_flight && link != BLE_HS_CONN_HANDLE_NONE && xQueueReceive(tx_queue, &tx_now, 0) == pdTRUE) {
        int rc;
        if (central) {
            rc = ble_gattc_write_flat(link, peer_rx, tx_now.bytes, tx_now.len, on_written, NULL);
        } else {
            struct os_mbuf *om = ble_hs_mbuf_from_flat(tx_now.bytes, tx_now.len);
            rc = om == NULL ? BLE_HS_ENOMEM : ble_gatts_indicate_custom(link, tx_handle, om);
        }
        if (rc == 0) tx_in_flight = 1;
        else post(EV_SENT, link, rc);
    }
}

/* On NimBLE's task: the central wrote one segment. */
static int on_write(uint16_t conn_handle, uint16_t attr_handle, struct ble_gatt_access_ctxt *ctxt, void *arg) {
    static segment s;                /* NimBLE's task only */
    (void)attr_handle; (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_UNLIKELY;
    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len == 0 || len > SEG_MAX) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    /* only this task fills the two queues, so room seen here is still there below */
    if (uxQueueSpacesAvailable(rx_queue) == 0 || uxQueueSpacesAvailable(events) == 0) return BLE_ATT_ERR_INSUFFICIENT_RES;
    if (ble_hs_mbuf_to_flat(ctxt->om, s.bytes, SEG_MAX, &s.len) != 0) return BLE_ATT_ERR_UNLIKELY;
    xQueueSend(rx_queue, &s, 0);
    post(EV_WRITTEN, conn_handle, 0);
    return 0;
}

/* The indicated characteristic has no value to read or write. */
static int on_tx_access(uint16_t conn_handle, uint16_t attr_handle, struct ble_gatt_access_ctxt *ctxt, void *arg) {
    (void)conn_handle; (void)attr_handle; (void)ctxt; (void)arg;
    return BLE_ATT_ERR_UNLIKELY;
}

/* The central's way to a link, each step on NimBLE's task when the one before has answered. */
static void give_up(uint16_t conn, int why) {
    post(EV_FAULT, conn, why);
    ble_gap_terminate(conn, BLE_ERR_REM_USER_CONN_TERM);
}

static int on_subscribed(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg);

static int subscribe(uint16_t conn) {
    uint8_t value[2] = { peer_tx_indicates ? 2 : 1, 0 };
    return ble_gattc_write_flat(conn, peer_cccd, value, sizeof value, on_subscribed, NULL);
}

/* As central, the peripheral decides whether the link is encrypted. One that requires it refuses the
   subscription until the link is: a board asks for the pairing itself as soon as it is connected, a
   phone waits for this end to start it. Either way this end subscribes once more when the link is
   encrypted. A peripheral that takes the subscription on an open link (a program on a Mac, which
   macOS lets pair only from an application with a window) has an open link. */
static int on_subscribed(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg) {
    (void)attr; (void)arg;
    if (error->status == 0) {
        subscribed = 1;
        post(EV_SUBSCRIBED, conn, 1);
    } else if (!subscribe_again
               && (error->status == BLE_HS_ATT_ERR(BLE_ATT_ERR_INSUFFICIENT_AUTHEN) || error->status == BLE_HS_ATT_ERR(BLE_ATT_ERR_INSUFFICIENT_ENC))) {
        subscribe_again = 1;
        int rc = encrypted ? subscribe(conn) : ble_gap_security_initiate(conn);
        if (rc != 0 && rc != BLE_HS_EALREADY) give_up(conn, 5);
    } else {
        give_up(conn, 3);
    }
    return 0;
}

static int on_descriptor(uint16_t conn, const struct ble_gatt_error *error, uint16_t chr_val_handle, const struct ble_gatt_dsc *dsc, void *arg) {
    (void)chr_val_handle; (void)arg;
    if (error->status == 0) {
        if (ble_uuid_u16(&dsc->uuid.u) == BLE_GATT_DSC_CLT_CFG_UUID16) peer_cccd = dsc->handle;
        return 0;
    }
    if (error->status == BLE_HS_EDONE && peer_cccd != 0) {
        int rc = subscribe(conn);
        if (rc != 0) give_up(conn, 1000 + rc);
    } else {
        give_up(conn, 3);
    }
    return 0;
}

static int on_characteristic(uint16_t conn, const struct ble_gatt_error *error, const struct ble_gatt_chr *chr, void *arg) {
    (void)arg;
    if (error->status == 0) {
        if (peer_tx != 0 && peer_tx_end == 0 && chr->def_handle > peer_tx) peer_tx_end = chr->def_handle - 1;
        if (peer_rx == 0 && (chr->properties & (BLE_GATT_CHR_PROP_WRITE | BLE_GATT_CHR_PROP_WRITE_NO_RSP))) peer_rx = chr->val_handle;
        if (peer_tx == 0 && (chr->properties & (BLE_GATT_CHR_PROP_INDICATE | BLE_GATT_CHR_PROP_NOTIFY))) {
            peer_tx = chr->val_handle;
            peer_tx_indicates = (chr->properties & BLE_GATT_CHR_PROP_INDICATE) != 0;
        }
        return 0;
    }
    if (error->status == BLE_HS_EDONE && peer_rx != 0 && peer_tx != 0) {
        if (peer_tx_end == 0) peer_tx_end = peer_end;
        int rc = ble_gattc_disc_all_dscs(conn, peer_tx, peer_tx_end, on_descriptor, NULL);
        if (rc != 0) give_up(conn, 1000 + rc);
    } else {
        give_up(conn, 2);
    }
    return 0;
}

static int on_service(uint16_t conn, const struct ble_gatt_error *error, const struct ble_gatt_svc *service, void *arg) {
    (void)arg;
    if (error->status == 0) {
        peer_start = service->start_handle;
        peer_end = service->end_handle;
        return 0;
    }
    if (error->status == BLE_HS_EDONE && peer_start != 0) {
        int rc = ble_gattc_disc_all_chrs(conn, peer_start, peer_end, on_characteristic, NULL);
        if (rc != 0) give_up(conn, 1000 + rc);
    } else {
        give_up(conn, 1);
    }
    return 0;
}

/* Whatever the exchange answered, the connection has an MTU: the service is looked for next. */
static int on_mtu(uint16_t conn, const struct ble_gatt_error *error, uint16_t mtu, void *arg) {
    (void)error; (void)mtu; (void)arg;
    int rc = ble_gattc_disc_svc_by_uuid(conn, &seek_uuid.u, on_service, NULL);
    if (rc != 0) give_up(conn, 1000 + rc);
    return 0;
}

static int advertises(const struct ble_hs_adv_fields *f, const ble_uuid_any_t *uuid) {
    for (int i = 0; i < f->num_uuids16; i++) if (ble_uuid_cmp(&f->uuids16[i].u, &uuid->u) == 0) return 1;
    for (int i = 0; i < f->num_uuids32; i++) if (ble_uuid_cmp(&f->uuids32[i].u, &uuid->u) == 0) return 1;
    for (int i = 0; i < f->num_uuids128; i++) if (ble_uuid_cmp(&f->uuids128[i].u, &uuid->u) == 0) return 1;
    return 0;
}

static struct ble_gatt_chr_def characteristics[3];
static struct ble_gatt_svc_def services[2];

static int on_gap_event(struct ble_gap_event *event, void *arg) {
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_DISC: {
        /* an advertisement, or the answer to this end's scan request, of something nearby */
        struct ble_hs_adv_fields f;
        if (!seeking || link != BLE_HS_CONN_HANDLE_NONE) break;
        if (ble_hs_adv_parse_fields(&f, event->disc.data, event->disc.length_data) != 0) break;
        if (!advertises(&f, &seek_uuid)) break;
        ble_gap_disc_cancel();
        int rc = ble_gap_connect(own_addr_type, &event->disc.addr, 10000, NULL, on_gap_event, NULL);
        if (rc != 0) post(EV_CONNECTED, BLE_HS_CONN_HANDLE_NONE, rc);
        break;
    }
    case BLE_GAP_EVENT_DISC_COMPLETE:
        if (seeking && link == BLE_HS_CONN_HANDLE_NONE) post(EV_ADV_ENDED, event->disc_complete.reason, 0);
        break;
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0 && (serving || seeking)) {
            struct ble_gap_conn_desc desc;
            xQueueReset(rx_queue);   /* segments of the peer before, never taken */
            subscribed = 0;
            encrypted = 0;
            central = ble_gap_conn_find(event->connect.conn_handle, &desc) == 0 && desc.role == BLE_GAP_ROLE_MASTER;
            link = event->connect.conn_handle;
            if (central) {
                seeking = 0;
                subscribe_again = 0;
                peer_start = peer_end = peer_rx = peer_tx = peer_tx_end = peer_cccd = 0;
                int rc = ble_gattc_exchange_mtu(link, on_mtu, NULL);
                if (rc != 0) give_up(link, 1000 + rc);
            } else {
#ifdef SILICA_BLE_OPEN_LINK
                encrypted = 1;   /* the test switch: the open link passes as an encrypted one does */
#else
                /* a peripheral asks its central to pair; its attributes refuse it until then */
                ble_gap_security_initiate(link);
#endif
            }
        }
        post(EV_CONNECTED, event->connect.conn_handle, event->connect.status);
        break;
    case BLE_GAP_EVENT_ENC_CHANGE:
        if (event->enc_change.conn_handle != link) break;
        if (event->enc_change.status != 0) {
            /* no pairing, no link: a peripheral waits for its next central, a central reports it */
            if (central) give_up(link, 5);
            else ble_gap_terminate(link, BLE_ERR_AUTH_FAIL);
            break;
        }
        if (encrypted) break;
        encrypted = 1;
        if (central && subscribe_again && !subscribed) {
            int rc = subscribe(link);
            if (rc != 0) give_up(link, 1000 + rc);
        } else if (!central && subscribed) {
            post(EV_SUBSCRIBED, link, 1);
        }
        break;
    case BLE_GAP_EVENT_REPEAT_PAIRING: {
        /* the peer pairs again and this end still holds keys for it: they go, and the pairing is new */
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0) ble_store_util_delete_peer(&desc.peer_id_addr);
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }
    case BLE_GAP_EVENT_NOTIFY_RX:
        /* the peripheral's indication: one segment */
        if (central && event->notify_rx.conn_handle == link && event->notify_rx.attr_handle == peer_tx) {
            static segment in;       /* NimBLE's task only */
            uint16_t len = OS_MBUF_PKTLEN(event->notify_rx.om);
            if (len == 0 || len > SEG_MAX || uxQueueSpacesAvailable(rx_queue) == 0 || uxQueueSpacesAvailable(events) < 3
                || ble_hs_mbuf_to_flat(event->notify_rx.om, in.bytes, SEG_MAX, &in.len) != 0) {
                /* NimBLE has told the peripheral the segment arrived, and it cannot be kept: the link
                   ends with a fault, so that nothing is lost in silence (room is kept in the event
                   queue for the fault and the disconnection) */
                give_up(link, 4);
                break;
            }
            xQueueSend(rx_queue, &in, 0);
            post(EV_WRITTEN, link, 0);
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        if (event->disconnect.conn.conn_handle == link) {
            xSemaphoreTakeRecursive(tx_lock, portMAX_DELAY);
            link = BLE_HS_CONN_HANDLE_NONE;
            central = 0;
            subscribed = 0;
            encrypted = 0;
            tx_in_flight = 0;
            xQueueReset(tx_queue);
            xSemaphoreGiveRecursive(tx_lock);
        }
        post(EV_DISCONNECTED, event->disconnect.conn.conn_handle, event->disconnect.reason);
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (serving && event->subscribe.attr_handle == tx_handle && event->subscribe.conn_handle == link) {
            subscribed = event->subscribe.cur_indicate;
            /* a subscription made before the link is encrypted counts when it is */
            if (encrypted || !subscribed) post(EV_SUBSCRIBED, event->subscribe.conn_handle, event->subscribe.cur_indicate);
        }
        break;
    case BLE_GAP_EVENT_NOTIFY_TX:
        /* Status 0 says only that the indication left, and comes on the sender's task; a refusal is
           answered where it was sent (send_next). The two that come later end the segment. */
        if (serving && event->notify_tx.indication && event->notify_tx.attr_handle == tx_handle
            && (event->notify_tx.status == BLE_HS_EDONE || event->notify_tx.status == BLE_HS_ETIMEOUT)) {
            xSemaphoreTakeRecursive(tx_lock, portMAX_DELAY);
            if (tx_in_flight) {
                tx_in_flight = 0;
                post(EV_SENT, event->notify_tx.conn_handle, event->notify_tx.status == BLE_HS_EDONE ? 0 : event->notify_tx.status);
                send_next();
            }
            xSemaphoreGiveRecursive(tx_lock);
        }
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
    if (events == NULL) events = xQueueCreate(32, sizeof(radio_event));
    if (events == NULL) return fail(8);
    /* The controller keeps its calibration data in NVS. Flashing an image erases NVS, so the first start
       after it calibrates in full and ESP-IDF says so in a warning on the console, which is the
       program's standard output; only its errors are let through. */
    esp_log_level_set("phy_init", ESP_LOG_ERROR);
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
    /* Pairing without a code ("Just Works", LE Secure Connections): this end has no display and no
       keys to press. Nothing is kept: every link pairs afresh, so there are no keys for one end to
       lose while the other still has them. */
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_NO_INPUT_OUTPUT;
    ble_hs_cfg.sm_bonding = 0;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = 0;
    ble_hs_cfg.sm_their_key_dist = 0;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;
    ble_store_config_init();
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_svc_gap_device_name_set("Silica");
    if (serving) {
        int rc = ble_gatts_count_cfg(services);
        if (rc == 0) rc = ble_gatts_add_svcs(services);
        if (rc != 0) return fail(1000 + rc);
    }
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

/* The UUID whose first group is `add` more than the service's. */
static void uuid_plus(const ble_uuid_any_t *from, uint32_t add, ble_uuid_any_t *out) {
    *out = *from;
    if (from->u.type == BLE_UUID_TYPE_16) {
        out->u16.value = (uint16_t)(from->u16.value + add);
    } else if (from->u.type == BLE_UUID_TYPE_32) {
        out->u32.value = from->u32.value + add;
    } else {
        uint32_t group = (uint32_t)from->u128.value[12] | (uint32_t)from->u128.value[13] << 8
                       | (uint32_t)from->u128.value[14] << 16 | (uint32_t)from->u128.value[15] << 24;
        group += add;
        for (int i = 0; i < 4; i++) out->u128.value[12 + i] = (uint8_t)(group >> (8 * i));
    }
}

/* The two segment queues and their lock, made by the first call that needs them. */
static int link_queues(void) {
    if (rx_queue == NULL) rx_queue = xQueueCreate(SEGMENTS, sizeof(segment));
    if (tx_queue == NULL) tx_queue = xQueueCreate(SEGMENTS, sizeof(segment));
    if (tx_lock == NULL) tx_lock = xSemaphoreCreateRecursiveMutex();
    return rx_queue != NULL && tx_queue != NULL && tx_lock != NULL;
}

/* Names the service the host will publish: before silica_nimble_start. Called again with the same
   UUID it answers ok; after the start with another, error 9. */
silica_nimble_tagged silica_nimble_serve(const uint8_t *uuid_ptr, uint64_t uuid_len) {
    ble_uuid_any_t uuid;
    if (uuid_from_text(uuid_ptr, uuid_len, &uuid) != 0) return fail(6);
    if (serving && ble_uuid_cmp(&uuid.u, &service_uuid.u) == 0) return ok(0);
    if (started) return fail(9);
    if (!link_queues()) return fail(8);
    service_uuid = uuid;
    uuid_plus(&uuid, 1, &rx_uuid);
    uuid_plus(&uuid, 2, &tx_uuid);
    memset(characteristics, 0, sizeof characteristics);
    characteristics[0].uuid = &rx_uuid.u;
    characteristics[0].access_cb = on_write;
    characteristics[0].flags = BLE_GATT_CHR_F_WRITE | ENC_WRITE;
    characteristics[1].uuid = &tx_uuid.u;
    characteristics[1].access_cb = on_tx_access;
    characteristics[1].flags = BLE_GATT_CHR_F_INDICATE | ENC_INDICATE;
    characteristics[1].val_handle = &tx_handle;
    memset(services, 0, sizeof services);
    services[0].type = BLE_GATT_SVC_TYPE_PRIMARY;
    services[0].uuid = &service_uuid.u;
    services[0].characteristics = characteristics;
    serving = 1;
    return ok(0);
}

/* The FFI carries a pointer and a length only as a binding's sole parameters, so silica_nimble_send
   takes its connection from here (as silica_ble_set_args). Only the radio actor calls the wrapper. */
silica_nimble_tagged silica_nimble_set_args(int64_t a, int64_t b) {
    (void)b;
    arg_a = a;
    return ok(0);
}

/* The largest segment the connection carries: its ATT_MTU minus 3, at most SEG_MAX. */
silica_nimble_tagged silica_nimble_mtu(int64_t conn) {
    if (link == BLE_HS_CONN_HANDLE_NONE || conn != link) return fail(3);
    int mtu = (int)ble_att_mtu((uint16_t)conn) - 3;
    if (mtu < 20) mtu = 20;
    if (mtu > SEG_MAX) mtu = SEG_MAX;
    return ok(mtu);
}

/* Queues one segment for the connection of silica_nimble_set_args. A :sent event says how it ended. */
silica_nimble_tagged silica_nimble_send(const uint8_t *data_ptr, uint64_t data_len) {
    static segment s;                /* the radio actor only */
    if (link == BLE_HS_CONN_HANDLE_NONE || arg_a != link || !subscribed || (!central && !encrypted)) return fail(3);
    int mtu = (int)ble_att_mtu(link) - 3;
    if (mtu > SEG_MAX) mtu = SEG_MAX;
    if (data_len == 0 || data_len > (uint64_t)mtu) return fail(4);
    s.len = (uint16_t)data_len;
    memcpy(s.bytes, data_ptr, data_len);
    xSemaphoreTakeRecursive(tx_lock, portMAX_DELAY);
    int queued = link != BLE_HS_CONN_HANDLE_NONE && xQueueSend(tx_queue, &s, 0) == pdTRUE;
    if (queued) send_next();
    xSemaphoreGiveRecursive(tx_lock);
    return queued ? ok(0) : fail(5);
}

/* Takes the next segment the central wrote; value its length, tag 2 when there is none. The bytes
   are read with silica_nimble_take. */
silica_nimble_tagged silica_nimble_recv(int64_t conn) {
    (void)conn;
    if (rx_queue == NULL || xQueueReceive(rx_queue, &rx_now, 0) != pdTRUE) return (silica_nimble_tagged){ 2, 0, 0 };
    return ok(rx_now.len);
}

/* The bytes of the last silica_nimble_recv. */
silica_nimble_bytes silica_nimble_take(int64_t conn) {
    (void)conn;
    return (silica_nimble_bytes){ 0, rx_now.bytes, rx_now.len, 0 };
}

/* Looks for a peripheral that advertises the service and makes the link to it (the central role, in
   the header). The :subscribed event says the link is up. */
silica_nimble_tagged silica_nimble_seek(const uint8_t *uuid_ptr, uint64_t uuid_len) {
    struct ble_gap_disc_params params;
    if (!synced) return fail(7);
    if (uuid_from_text(uuid_ptr, uuid_len, &seek_uuid) != 0) return fail(6);
    if (!link_queues()) return fail(8);
    if (ble_gap_disc_active()) ble_gap_disc_cancel();
    memset(&params, 0, sizeof params);
    params.filter_duplicates = 1;    /* each device is reported once; a new scan starts afresh */
    seeking = 1;
    /* an active scan: a peripheral may give its service only in the answer to a scan request */
    int rc = ble_gap_disc(own_addr_type, BLE_HS_FOREVER, &params, on_gap_event, NULL);
    if (rc != 0) { seeking = 0; return fail(1000 + rc); }
    return ok(0);
}

/* Ends the connection; the :disconnected event follows. With no connection, ends the search for a
   peripheral. */
silica_nimble_tagged silica_nimble_drop(int64_t conn) {
    if (link == BLE_HS_CONN_HANDLE_NONE) {
        if (seeking) {
            seeking = 0;
            ble_gap_disc_cancel();
            ble_gap_conn_cancel();
        }
        return ok(0);
    }
    if (conn != link) return ok(0);
    int rc = ble_gap_terminate((uint16_t)conn, BLE_ERR_REM_USER_CONN_TERM);
    if (rc != 0 && rc != BLE_HS_EALREADY && rc != BLE_HS_ENOTCONN) return fail(1000 + rc);
    return ok(0);
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
