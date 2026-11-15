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

// Route R1 spike, Wi-Fi (transport_ble_plan.md stage 12, part 6): what Espressif's Wi-Fi libraries,
// ESP-IDF's glue for them (esp_wifi/esp32s3/esp_adapter.c, esp_coex's adapter), its WPA supplicant and
// Mbed TLS ask of FreeRTOS, ESP-IDF and the C library beyond what hci_shim.c answers:
//
//   the interrupt   the glue routes the Wi-Fi MAC's source to a level-1 line and installs a handler
//                   by Xtensa's calls; here the handler is given to hci_shim.c's esp_intr_alloc when
//                   the line is switched on, which puts the source on a level-3 line.
//   event groups    a word of bits; a waiter passes control round until its bits are set.
//   timers          the ROM's timer record (ETSTimer) on hci_shim.c's timers.
//   events          esp_event_post keeps the Wi-Fi events for main (spike_wifi_event).
//   storage         nothing is kept: every read answers "not found".
//   per-task values pthread keys, held by task handle (the glue keeps a semaphore for each task).
//   cryptography    the chip's AES, SHA and big-number hardware through ESP-IDF's own register
//                   code; the parts that need DMA or the signature peripheral stop the program.
//
// The types are written as their machine forms so that no FreeRTOS header is needed.

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdarg.h>
#include "soc/soc.h"
#include "soc/syscon_reg.h"
#include "soc/system_reg.h"

void silica_rt_puts(const char *s);
void spike_put_dec(uint32_t n);
uint64_t spike_ticks(void);
void spike_yield(void);
void abort(void);
void *malloc(size_t n);
void free(void *p);
void *heap_caps_realloc(void *p, size_t n, uint32_t caps);
size_t heap_caps_get_free_size(uint32_t caps);
int esp_intr_alloc(int source, int flags, void (*handler)(void *), void *arg, void **ret_handle);
void *xTaskGetCurrentTaskHandle(void);
void *xQueueGenericCreate(uint32_t length, uint32_t item, uint8_t type);
void *xQueueCreateMutex(uint8_t type);
int xQueueTakeMutexRecursive(void *handle, uint32_t ticks);
int xQueueGiveMutexRecursive(void *handle);
void vQueueDelete(void *handle);
int esp_timer_create(const void *args, void **handle);
int esp_timer_start_once(void *handle, uint64_t us);
int esp_timer_start_periodic(void *handle, uint64_t us);
int esp_timer_stop(void *handle);
int esp_timer_delete(void *handle);
int vsnprintf(char *out, size_t room, const char *format, va_list ap);
uint32_t esp_random(void);
void esp_wifi_bt_power_domain_on(void);
void esp_wifi_bt_power_domain_off(void);

static void stop(const char *what)
{
    silica_rt_puts("wifi shim: not provided: ");
    silica_rt_puts(what);
    silica_rt_puts("\n");
    abort();
}

// ---- the interrupt ----

#define WIFI_MAC_SOURCE 0   // ETS_WIFI_MAC_INTR_SOURCE
static void (*mac_handler)(void *);
static void *mac_arg;
static int mac_on;

void xt_set_interrupt_handler(int line, void (*handler)(void *), void *arg)
{
    (void)line;
    mac_handler = handler;
    mac_arg = arg;
}

void xt_ints_on(uint32_t mask)
{
    (void)mask;
    if (!mac_on && mac_handler) {
        mac_on = 1;
#ifdef SPIKE_DEBUG
        silica_rt_puts("wifi shim: the MAC's interrupt on\n");
#endif
        esp_intr_alloc(WIFI_MAC_SOURCE, 0, mac_handler, mac_arg, NULL);
    }
}

void xt_ints_off(uint32_t mask)
{
    (void)mask;
}

// ---- event groups ----

struct group {
    volatile uint32_t bits;
};

void *xEventGroupCreate(void)
{
    struct group *g = malloc(sizeof *g);
    g->bits = 0;
    return g;
}

void vEventGroupDelete(void *handle)
{
    free(handle);
}

uint32_t xEventGroupSetBits(void *handle, uint32_t bits)
{
    struct group *g = handle;
    __sync_fetch_and_or(&g->bits, bits);
    return g->bits;
}

uint32_t xEventGroupClearBits(void *handle, uint32_t bits)
{
    struct group *g = handle;
    return __sync_fetch_and_and(&g->bits, ~bits);
}

// ticks are milliseconds; 0xFFFFFFFF waits for ever
uint32_t xEventGroupWaitBits(void *handle, uint32_t bits, int clear, int all, uint32_t ticks)
{
    struct group *g = handle;
    uint64_t start = spike_ticks();
    for (;;) {
        uint32_t now = g->bits;
        if (all ? (now & bits) == bits : (now & bits) != 0) {
            if (clear) {
                __sync_fetch_and_and(&g->bits, ~bits);
            }
            return now;
        }
        if (ticks != 0xFFFFFFFFu && (spike_ticks() - start) / 16000 >= ticks) {
            return now;
        }
        spike_yield();
    }
}

// ---- the ROM's timers ----

typedef struct ets_timer {
    struct ets_timer *next;
    uint32_t expire, period;
    void (*func)(void *);
    void *arg;
} ets_timer;

// The record's first word holds hci_shim.c's timer once the function is set.
void ets_timer_setfn(ets_timer *t, void (*func)(void *), void *arg)
{
    t->func = func;
    t->arg = arg;
    t->expire = 0;
    t->period = 0;
    if (t->next == NULL) {
        void *args[2] = { (void *)func, arg };
        void *handle = NULL;
        if (esp_timer_create(args, &handle) != 0) {
            stop("a timer (all are in use)");
        }
        t->next = handle;
    }
}

void ets_timer_arm_us(ets_timer *t, uint32_t us, int repeat)
{
    if (t->next == NULL) {
        return;
    }
    esp_timer_stop(t->next);
    if (repeat) {
        esp_timer_start_periodic(t->next, us);
    } else {
        esp_timer_start_once(t->next, us);
    }
}

void ets_timer_arm(ets_timer *t, uint32_t ms, int repeat)
{
    ets_timer_arm_us(t, ms * 1000, repeat);
}

void ets_timer_disarm(ets_timer *t)
{
    if (t->next != NULL) {
        esp_timer_stop(t->next);
    }
}

void ets_timer_done(ets_timer *t)
{
    if (t->next != NULL) {
        esp_timer_delete(t->next);
        t->next = NULL;
    }
}

// ---- events ----

#define EVENTS 16
static struct {
    int32_t id;
    uint8_t data[48];
} events[EVENTS];
static volatile uint32_t events_in, events_out;

int esp_event_post(const char *base, int32_t id, const void *data, size_t size, uint32_t ticks)
{
    (void)base;
    (void)ticks;
    if (events_in - events_out < EVENTS) {
        uint32_t i = events_in % EVENTS;
        events[i].id = id;
        memset(events[i].data, 0, sizeof events[i].data);
        if (data != NULL) {
            memcpy(events[i].data, data, size < sizeof events[i].data ? size : sizeof events[i].data);
        }
        events_in = events_in + 1;
    }
    return 0;
}

int spike_wifi_event(int32_t *id, uint8_t data[48])
{
    if (events_out == events_in) {
        return 0;
    }
    uint32_t i = events_out % EVENTS;
    *id = events[i].id;
    memcpy(data, events[i].data, 48);
    events_out = events_out + 1;
    return 1;
}

// ---- storage: nothing is kept ----

#define NVS_NOT_FOUND 0x1102
int nvs_open(const char *name, int mode, uint32_t *handle) { (void)name; (void)mode; *handle = 1; return 0; }
void nvs_close(uint32_t handle) { (void)handle; }
int nvs_commit(uint32_t handle) { (void)handle; return 0; }
int nvs_erase_key(uint32_t handle, const char *key) { (void)handle; (void)key; return 0; }
int nvs_erase_all(uint32_t handle) { (void)handle; return 0; }
int nvs_get_blob(uint32_t handle, const char *key, void *out, size_t *len) { (void)handle; (void)key; (void)out; (void)len; return NVS_NOT_FOUND; }
int nvs_get_i8(uint32_t handle, const char *key, int8_t *out) { (void)handle; (void)key; (void)out; return NVS_NOT_FOUND; }
int nvs_get_u8(uint32_t handle, const char *key, uint8_t *out) { (void)handle; (void)key; (void)out; return NVS_NOT_FOUND; }
int nvs_get_u16(uint32_t handle, const char *key, uint16_t *out) { (void)handle; (void)key; (void)out; return NVS_NOT_FOUND; }
int nvs_get_u32(uint32_t handle, const char *key, uint32_t *out) { (void)handle; (void)key; (void)out; return NVS_NOT_FOUND; }
int nvs_set_blob(uint32_t handle, const char *key, const void *in, size_t len) { (void)handle; (void)key; (void)in; (void)len; return 0; }
int nvs_set_i8(uint32_t handle, const char *key, int8_t v) { (void)handle; (void)key; (void)v; return 0; }
int nvs_set_u8(uint32_t handle, const char *key, uint8_t v) { (void)handle; (void)key; (void)v; return 0; }
int nvs_set_u16(uint32_t handle, const char *key, uint16_t v) { (void)handle; (void)key; (void)v; return 0; }
int nvs_set_u32(uint32_t handle, const char *key, uint32_t v) { (void)handle; (void)key; (void)v; return 0; }

// ---- per-task values and the C library's locks ----

#define KEYS 4
#define TASKS 8
static int keys_used;
static struct {
    void *task;
    void *value[KEYS];
} task_values[TASKS];

int pthread_key_create(uint32_t *key, void (*destructor)(void *))
{
    (void)destructor;
    if (keys_used == KEYS) {
        return 12;
    }
    *key = (uint32_t)keys_used++;
    return 0;
}

void *pthread_getspecific(uint32_t key)
{
    void *me = xTaskGetCurrentTaskHandle();
    for (int i = 0; i < TASKS; i++) {
        if (task_values[i].task == me) {
            return task_values[i].value[key];
        }
    }
    return NULL;
}

int pthread_setspecific(uint32_t key, const void *value)
{
    void *me = xTaskGetCurrentTaskHandle();
    int spare = -1;
    for (int i = 0; i < TASKS; i++) {
        if (task_values[i].task == me) {
            task_values[i].value[key] = (void *)value;
            return 0;
        }
        if (spare < 0 && task_values[i].task == NULL && i > 0) {
            spare = i;
        }
    }
    // main's line of control has the handle NULL: it takes the first place
    if (me == NULL) {
        spare = 0;
    }
    if (spare < 0) {
        return 12;
    }
    task_values[spare].task = me;
    task_values[spare].value[key] = (void *)value;
    return 0;
}

// A lock is a word that holds a recursive mutex, made at its first use.
static void *lock_of(void **lock)
{
    // not made yet: zero, or the C library's mark of a mutex declared ready (all ones)
    if (*lock == NULL || *lock == (void *)-1) {
        *lock = xQueueCreateMutex(4);
    }
    return *lock;
}

void _lock_acquire(void **lock) { xQueueTakeMutexRecursive(lock_of(lock), 0xFFFFFFFFu); }
void _lock_release(void **lock) { xQueueGiveMutexRecursive(lock_of(lock)); }
int pthread_mutex_init(void **mutex, const void *attr) { (void)attr; *mutex = NULL; return 0; }
int pthread_mutex_destroy(void **mutex) { if (*mutex && *mutex != (void *)-1) { vQueueDelete(*mutex); *mutex = NULL; } return 0; }
int pthread_mutex_lock(void **mutex) { xQueueTakeMutexRecursive(lock_of(mutex), 0xFFFFFFFFu); return 0; }
int pthread_mutex_unlock(void **mutex) { xQueueGiveMutexRecursive(lock_of(mutex)); return 0; }

// ---- memory and the C library ----

void *calloc(size_t count, size_t n)
{
    void *p = malloc(count * n);
    if (p != NULL) {
        memset(p, 0, count * n);
    }
    return p;
}

void *realloc(void *p, size_t n) { return heap_caps_realloc(p, n, 0); }
void *heap_caps_malloc_prefer(size_t n, size_t count, ...) { (void)count; return malloc(n); }

// Aligned blocks are asked for the DMA paths only, which are not provided.
void *heap_caps_aligned_alloc(size_t align, size_t n, uint32_t caps) { (void)align; (void)n; (void)caps; stop("heap_caps_aligned_alloc"); return NULL; }
void *heap_caps_aligned_calloc(size_t align, size_t count, size_t n, uint32_t caps) { (void)align; (void)count; (void)n; (void)caps; stop("heap_caps_aligned_calloc"); return NULL; }
size_t esp_get_free_internal_heap_size(void) { return heap_caps_get_free_size(0); }

// The C library's table of character classes: 128 entries for negative indexes (the end-of-file
// mark among them), then one for each character; none above 127 has a class.
const char _ctype_b[128 + 256] = {
    [128] =
    0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x28, 0x28, 0x28, 0x28, 0x28, 0x20, 0x20,
    0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
    0x88, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
    0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x10, 0x10, 0x10, 0x10, 0x20,
};

static int error_number;
int *__errno(void) { return &error_number; }

// lwIP's sockets are used by its own calls, not through ESP-IDF's file descriptors
int esp_vfs_register_fd_range(const void *vfs, void *ctx, int min_fd, int max_fd) { (void)vfs; (void)ctx; (void)min_fd; (void)max_fd; return 0; }

// ticks are milliseconds
uint32_t xTaskGetTickCount(void) { return (uint32_t)(spike_ticks() / 16000); }

int puts(const char *s)
{
    silica_rt_puts(s);
    silica_rt_puts("\n");
    return 0;
}

int usleep(uint32_t us)
{
    uint64_t start = spike_ticks();
    do {
        spike_yield();
    } while ((spike_ticks() - start) / 16 < us);
    return 0;
}

unsigned sleep(unsigned seconds)
{
    usleep(seconds * 1000000u);
    return 0;
}

// seconds and microseconds since the start
int gettimeofday(int64_t *tv, void *zone)
{
    (void)zone;
    uint64_t us = spike_ticks() / 16;
    tv[0] = (int64_t)(us / 1000000);
    ((int32_t *)tv)[2] = (int32_t)(us % 1000000);
    return 0;
}

// ---- the log ----

void esp_log_writev(int level, const char *tag, const char *format, va_list ap)
{
    (void)level;
    (void)tag;
    char line[200];
    vsnprintf(line, sizeof line, format, ap);
    silica_rt_puts(line);
}

void esp_log_write(int level, const char *tag, const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    esp_log_writev(level, tag, format, ap);
    va_end(ap);
}

// ---- the chip ----

static int common_users, wifi_users;

void wifi_bt_common_module_enable(void)
{
    if (common_users++ == 0) {
        SET_PERI_REG_MASK(SYSTEM_WIFI_CLK_EN_REG, SYSTEM_WIFI_CLK_WIFI_BT_COMMON_M);
    }
}

void wifi_bt_common_module_disable(void)
{
    if (--common_users == 0) {
        CLEAR_PERI_REG_MASK(SYSTEM_WIFI_CLK_EN_REG, SYSTEM_WIFI_CLK_WIFI_BT_COMMON_M);
    }
}

void wifi_module_enable(void)
{
    static int clock_chosen;
    if (!clock_chosen) {
        // The MAC's low-power clock, which ESP-IDF's start-up chooses (esp_perip_clk_init): the slow
        // clock. With none chosen the MAC never answers its start (libpp's hal_init waits for ever).
        clock_chosen = 1;
        // every modem clock bit, as ESP-IDF's start-up sets them once
        SET_PERI_REG_MASK(SYSTEM_WIFI_CLK_EN_REG, SYSTEM_WIFI_CLK_EN);
#ifdef SPIKE_DEBUG
        silica_rt_puts("wifi shim: the MAC's clocks on\n");
#endif
        REG_SET_FIELD(SYSTEM_BT_LPCK_DIV_INT_REG, SYSTEM_BT_LPCK_DIV_NUM, 0);
        CLEAR_PERI_REG_MASK(SYSTEM_BT_LPCK_DIV_FRAC_REG, SYSTEM_LPCLK_SEL_XTAL32K | SYSTEM_LPCLK_SEL_XTAL | SYSTEM_LPCLK_SEL_8M | SYSTEM_LPCLK_SEL_RTC_SLOW);
        SET_PERI_REG_MASK(SYSTEM_BT_LPCK_DIV_FRAC_REG, SYSTEM_LPCLK_SEL_RTC_SLOW);
    }
    if (wifi_users++ == 0) {
        SET_PERI_REG_MASK(SYSTEM_WIFI_CLK_EN_REG, SYSTEM_WIFI_CLK_WIFI_EN_M);
    }
}

void wifi_module_disable(void)
{
    if (--wifi_users == 0) {
        CLEAR_PERI_REG_MASK(SYSTEM_WIFI_CLK_EN_REG, SYSTEM_WIFI_CLK_WIFI_EN_M);
    }
}

void esp_wifi_power_domain_on(void) { esp_wifi_bt_power_domain_on(); }
void esp_wifi_power_domain_off(void) { esp_wifi_bt_power_domain_off(); }
int esp_phy_update_country_info(const char *country) { (void)country; return 0; }

// The radio's noise source (readable while the radio is on) mixed with hci_shim.c's generator.
void esp_fill_random(void *out, size_t n)
{
    uint8_t *p = out;
    for (size_t i = 0; i < n; i++) {
        p[i] = (uint8_t)(esp_random() ^ REG_READ(0x6003507C));
    }
}

// the peripherals' clock switches are taken one caller at a time
static uint32_t rcc_ps;
void periph_rcc_enter(void) { __asm__ volatile("rsil %0, 3" : "=r"(rcc_ps)); }
void periph_rcc_exit(void) { __asm__ volatile("wsr.ps %0\n rsync" : : "r"(rcc_ps)); }

// ---- not in this image ----

uint8_t g_espnow_user_oui[3];
const void *_esp_err_msg_tbl_start, *_esp_err_msg_tbl_end;

// The DMA paths of the AES and SHA hardware, and the signature and HMAC peripherals.
int gdma_new_ahb_channel(void) { stop("gdma_new_ahb_channel"); return -1; }
int gdma_connect(void) { stop("gdma_connect"); return -1; }
int gdma_disconnect(void) { stop("gdma_disconnect"); return -1; }
int gdma_del_channel(void) { stop("gdma_del_channel"); return -1; }
int gdma_start(void) { stop("gdma_start"); return -1; }
int gdma_config_transfer(void) { stop("gdma_config_transfer"); return -1; }
int gdma_get_group_channel_id(void) { stop("gdma_get_group_channel_id"); return -1; }
int esp_mspi_get_alignment(void) { stop("esp_mspi_get_alignment"); return -1; }
int esp_mspi_buffer_alignment_satisfied(void) { stop("esp_mspi_buffer_alignment_satisfied"); return 0; }
int esp_ds_start_sign(void) { stop("esp_ds_start_sign"); return -1; }
int esp_ds_finish_sign(void) { stop("esp_ds_finish_sign"); return -1; }
int esp_hmac_calculate(void) { stop("esp_hmac_calculate"); return -1; }
