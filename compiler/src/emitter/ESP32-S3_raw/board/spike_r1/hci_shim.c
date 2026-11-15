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

// Route R1 spike, step 3 (transport_ble_plan.md stage 12): what ESP-IDF's glue for the Bluetooth
// controller (bt/controller/esp32c3/bt.c, linked as ESP-IDF compiled it for the guest image) asks of
// FreeRTOS and of ESP-IDF, answered on the bare-metal runtime with no interrupts and no scheduler:
//
//   interrupts  esp_intr_alloc routes the source to a CPU interrupt line that stays disabled; spike_poll
//               reads the line's pending bit and calls the handler in ordinary context.
//   the task    xTaskCreatePinnedToCore makes one coroutine (spike_co.S). A call that would block polls
//               the interrupts and passes control to the other line of control until it can go on.
//   queues, semaphores, mutexes   one structure, a ring of items (none for a semaphore).
//   memory      a block handed out from the front and never taken back.
//   the radio   esp_phy_enable is phy_main.c's start.
//
// The types are written as their machine forms so that no FreeRTOS header is needed.

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "soc/soc.h"
#include "soc/rtc.h"
#include "soc/rtc_cntl_reg.h"
#include "soc/syscon_reg.h"
#include "soc/system_reg.h"
#include "soc/efuse_reg.h"
#include "soc/systimer_reg.h"
#include "esp_rom_sys.h"
#include "esp_phy_init.h"
#include "esp_private/phy.h"
#include "phy_init_data.h"

void silica_rt_puts(const char *s);
void spike_co_switch(uint32_t save[2], const uint32_t load[2]);
void spike_co_start(uint32_t save[2], uint32_t *stack_top, void (*fn)(void *), void *arg);
void intr_matrix_set(int cpu, uint32_t source, uint32_t line);

void spike_put_dec(uint32_t n)
{
    char buf[12];
    int i = 11;
    buf[i] = 0;
    do {
        buf[--i] = (char)('0' + n % 10);
        n /= 10;
    } while (n != 0);
    silica_rt_puts(&buf[i]);
}

// ---- time: the system timer, 16 MHz from the crystal ----

uint64_t spike_ticks(void)
{
    REG_WRITE(SYSTIMER_UNIT0_OP_REG, SYSTIMER_TIMER_UNIT0_UPDATE);
    while (!(REG_READ(SYSTIMER_UNIT0_OP_REG) & SYSTIMER_TIMER_UNIT0_VALUE_VALID)) {
    }
    uint32_t hi = REG_READ(SYSTIMER_UNIT0_VALUE_HI_REG);
    uint32_t lo = REG_READ(SYSTIMER_UNIT0_VALUE_LO_REG);
    return ((uint64_t)hi << 32) | lo;
}

int64_t esp_timer_get_time(void)
{
    return (int64_t)(spike_ticks() / 16);
}

// ---- interrupts, polled ----

#define MAX_IRQ 8
static struct irq {
    void (*handler)(void *);
    void *arg;
    int line;
    int enabled;
} irqs[MAX_IRQ];
static int irq_count;
static int in_handler;
uint32_t spike_handler_calls;
// CPU interrupt lines that take a level from a peripheral (level 1; they stay disabled)
static const uint8_t lines[MAX_IRQ] = { 0, 1, 2, 3, 4, 5, 8, 9 };

int esp_intr_alloc(int source, int flags, void (*handler)(void *), void *arg, void **ret_handle)
{
    (void)flags;
    if (irq_count == MAX_IRQ) {
        return 0x101;
    }
    struct irq *q = &irqs[irq_count];
    q->handler = handler;
    q->arg = arg;
    q->line = lines[irq_count];
    q->enabled = 1;
    irq_count++;
    intr_matrix_set(0, (uint32_t)source, (uint32_t)q->line);
    silica_rt_puts("shim: interrupt source ");
    spike_put_dec((uint32_t)source);
    silica_rt_puts(" on line ");
    spike_put_dec((uint32_t)q->line);
    silica_rt_puts("\n");
    if (ret_handle) {
        *ret_handle = q;
    }
    return 0;
}

int esp_intr_enable(void *handle)
{
    ((struct irq *)handle)->enabled = 1;
    return 0;
}

int esp_intr_disable(void *handle)
{
    ((struct irq *)handle)->enabled = 0;
    return 0;
}

int esp_intr_free(void *handle)
{
    ((struct irq *)handle)->enabled = 0;
    return 0;
}

int esp_ipc_call_blocking(uint32_t cpu, void (*fn)(void *), void *arg)
{
    (void)cpu;
    fn(arg);
    return 0;
}

void spike_poll(void)
{
    if (in_handler) {
        return;
    }
    uint32_t pending;
    __asm__ volatile("rsr.interrupt %0" : "=r"(pending));
    for (int i = 0; i < irq_count; i++) {
        if (irqs[i].enabled && (pending & (1u << irqs[i].line))) {
            in_handler = 1;
            irqs[i].handler(irqs[i].arg);
            in_handler = 0;
            spike_handler_calls++;
        }
    }
}

int xPortInIsrContext(void)
{
    return in_handler;
}

int xPortEnterCriticalTimeout(void *mux, int timeout)
{
    (void)mux;
    (void)timeout;
    return 1;
}

void vPortExitCritical(void *mux)
{
    (void)mux;
}

void _frxt_setup_switch(void)
{
}

// ---- the two lines of control ----

static uint32_t co_ctx[2][2];
static uint32_t co_stack[2048] __attribute__((aligned(16)));
static void (*co_fn)(void *);
static void *co_arg;
static int co_have, co_started, co_cur;
uint32_t spike_switches;

// Lets the interrupts and the other line of control run once.
void spike_yield(void)
{
    spike_poll();
    if (!co_have || in_handler) {
        return;
    }
    spike_switches++;
    int from = co_cur;
    co_cur = 1 - co_cur;
    if (!co_started) {
        co_started = 1;
        spike_co_start(co_ctx[from], &co_stack[2048 - 16], co_fn, co_arg);
    } else {
        spike_co_switch(co_ctx[from], co_ctx[co_cur]);
    }
}

int xTaskCreatePinnedToCore(void (*fn)(void *), const char *name, uint32_t stack, void *arg, uint32_t prio, void **handle, int core)
{
    (void)stack;
    (void)prio;
    (void)core;
    silica_rt_puts("shim: task ");
    silica_rt_puts(name);
    silica_rt_puts("\n");
    if (co_have) {
        return 0;
    }
    co_fn = fn;
    co_arg = arg;
    co_have = 1;
    if (handle) {
        *handle = co_stack;
    }
    return 1;
}

void vTaskDelete(void *handle)
{
    (void)handle;
}

void vPortYield(void)
{
    spike_yield();
}

// ---- memory ----

static uint8_t arena[56 * 1024] __attribute__((aligned(16)));
static size_t arena_used;

void *malloc(size_t n)
{
    n = (n + 15) & ~(size_t)15;
    if (arena_used + n > sizeof(arena)) {
        silica_rt_puts("shim: out of memory\n");
        return NULL;
    }
    void *p = &arena[arena_used];
    arena_used += n;
    return p;
}

void free(void *p)
{
    (void)p;
}

void *heap_caps_malloc(size_t n, uint32_t caps)
{
    (void)caps;
    return malloc(n);
}

void *heap_caps_calloc(size_t count, size_t n, uint32_t caps)
{
    (void)caps;
    void *p = malloc(count * n);
    if (p) {
        memset(p, 0, count * n);
    }
    return p;
}

size_t heap_caps_get_free_size(uint32_t caps)
{
    (void)caps;
    return sizeof(arena) - arena_used;
}

int heap_caps_add_region(intptr_t start, intptr_t end)
{
    (void)start;
    (void)end;
    return 0;
}

uint32_t spike_arena_used(void)
{
    return (uint32_t)arena_used;
}

// ---- queues, semaphores and mutexes ----

struct queue {
    uint32_t length, item, count, head;
    uint8_t *items;
};

static struct queue *queue_new(uint32_t length, uint32_t item, uint32_t count)
{
    struct queue *q = malloc(sizeof *q);
    q->length = length;
    q->item = item;
    q->count = count;
    q->head = 0;
    q->items = item ? malloc(length * item) : NULL;
    return q;
}

void *xQueueGenericCreate(uint32_t length, uint32_t item, uint8_t type)
{
    (void)type;
    return queue_new(length, item, 0);
}

void *xQueueCreateCountingSemaphore(uint32_t max, uint32_t initial)
{
    return queue_new(max, 0, initial);
}

void *xQueueCreateMutex(uint8_t type)
{
    (void)type;
    return queue_new(1, 0, 1);
}

void vQueueDelete(void *q)
{
    (void)q;
}

static int put(struct queue *q, const void *item)
{
    if (q->count == q->length) {
        return 0;
    }
    if (q->item) {
        memcpy(q->items + ((q->head + q->count) % q->length) * q->item, item, q->item);
    }
    q->count++;
    return 1;
}

static int get(struct queue *q, void *item)
{
    if (q->count == 0) {
        return 0;
    }
    if (q->item) {
        memcpy(item, q->items + q->head * q->item, q->item);
        q->head = (q->head + 1) % q->length;
    }
    q->count--;
    return 1;
}

// ticks are milliseconds (the guest's FreeRTOS runs at 1000 Hz); 0xFFFFFFFF waits for ever
static int expired(uint64_t start, uint32_t ticks)
{
    return ticks != 0xFFFFFFFFu && (spike_ticks() - start) / 16000 >= ticks;
}

int xQueueGenericSend(void *q, const void *item, uint32_t ticks, int position)
{
    (void)position;
    uint64_t start = spike_ticks();
    while (!put(q, item)) {
        if (in_handler || expired(start, ticks)) {
            return 0;
        }
        spike_yield();
    }
    return 1;
}

int xQueueReceive(void *q, void *item, uint32_t ticks)
{
    uint64_t start = spike_ticks();
    while (!get(q, item)) {
        if (in_handler || expired(start, ticks)) {
            return 0;
        }
        spike_yield();
    }
    return 1;
}

int xQueueSemaphoreTake(void *q, uint32_t ticks)
{
    return xQueueReceive(q, NULL, ticks);
}

int xQueueGenericSendFromISR(void *q, const void *item, int *woken, int position)
{
    (void)position;
    if (woken) {
        *woken = 0;
    }
    return put(q, item);
}

int xQueueGiveFromISR(void *q, int *woken)
{
    if (woken) {
        *woken = 0;
    }
    return put(q, NULL);
}

int xQueueReceiveFromISR(void *q, void *item, int *woken)
{
    if (woken) {
        *woken = 0;
    }
    return get(q, item);
}

// ---- timers: bt.c's one timer wakes the controller from sleep, which is off ----

int esp_timer_create(const void *args, void **handle)
{
    (void)args;
    *handle = (void *)1;
    return 0;
}

int esp_timer_start_once(void *handle, uint64_t us)
{
    (void)handle;
    (void)us;
    return 0;
}

int esp_timer_stop(void *handle)
{
    (void)handle;
    return 0x103;
}

int esp_timer_delete(void *handle)
{
    (void)handle;
    return 0;
}

// ---- the chip ----

int esp_read_mac(uint8_t *mac, int type)
{
    uint32_t lo = REG_READ(EFUSE_RD_MAC_SPI_SYS_0_REG);
    uint32_t hi = REG_READ(EFUSE_RD_MAC_SPI_SYS_1_REG);
    mac[0] = (uint8_t)(hi >> 8);
    mac[1] = (uint8_t)hi;
    mac[2] = (uint8_t)(lo >> 24);
    mac[3] = (uint8_t)(lo >> 16);
    mac[4] = (uint8_t)(lo >> 8);
    mac[5] = (uint8_t)(lo + (type == 2 ? 2 : 0));   // the Bluetooth address is the base address plus 2
    return 0;
}

uint32_t esp_random(void)
{
    static uint32_t x = 0x9E3779B9u;
    x ^= (uint32_t)spike_ticks();
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return x;
}

uint32_t esp_clk_xtal_freq(void)
{
    return 40000000;
}

uint32_t esp_clk_slowclk_cal_get(void)
{
    static uint32_t cal;
    if (cal == 0) {
        cal = rtc_clk_cal(CLK_CAL_RTC_SLOW, 1024);
    }
    return cal;
}

void esp_wifi_bt_power_domain_on(void)
{
    CLEAR_PERI_REG_MASK(RTC_CNTL_DIG_PWC_REG, RTC_CNTL_WIFI_FORCE_PD);
    esp_rom_delay_us(10);
    SET_PERI_REG_MASK(SYSTEM_WIFI_CLK_EN_REG, SYSTEM_WIFI_CLK_WIFI_BT_COMMON_M);
    SET_PERI_REG_MASK(SYSCON_WIFI_RST_EN_REG, MODEM_RESET_FIELD_WHEN_PU);
    CLEAR_PERI_REG_MASK(SYSCON_WIFI_RST_EN_REG, MODEM_RESET_FIELD_WHEN_PU);
    CLEAR_PERI_REG_MASK(RTC_CNTL_DIG_ISO_REG, RTC_CNTL_WIFI_FORCE_ISO);
}

void esp_wifi_bt_power_domain_off(void)
{
}

// The one module bt.c names is Bluetooth's: its clock, and its blocks' resets.
#define BT_RESETS (SYSTEM_BTBB_RST | SYSTEM_BTBB_REG_RST | SYSTEM_RW_BTMAC_RST | SYSTEM_RW_BTLP_RST | SYSTEM_RW_BTMAC_REG_RST | SYSTEM_RW_BTLP_REG_RST)

void periph_module_enable(int module)
{
    (void)module;
    // ESP-IDF's start-up sets every modem clock bit once (esp_perip_clk_init), Bluetooth's among them,
    // and its mask for Bluetooth alone is empty; the ROM leaves Bluetooth's bits clear.
    SET_PERI_REG_MASK(SYSTEM_WIFI_CLK_EN_REG, SYSTEM_WIFI_CLK_EN);
    CLEAR_PERI_REG_MASK(SYSTEM_CORE_RST_EN_REG, BT_RESETS);
}

void periph_module_disable(int module)
{
    (void)module;
}

void periph_module_reset(int module)
{
    (void)module;
    SET_PERI_REG_MASK(SYSTEM_CORE_RST_EN_REG, BT_RESETS);
    CLEAR_PERI_REG_MASK(SYSTEM_CORE_RST_EN_REG, BT_RESETS);
}

// ---- the radio ----

uint32_t phy_enter_critical(void)
{
    return 0;
}

void phy_exit_critical(uint32_t level)
{
    (void)level;
}

int phy_printf(const char *format, ...)
{
    silica_rt_puts("phy: ");
    silica_rt_puts(format);
    return 0;
}

int sprintf(char *out, const char *format, ...)
{
    int n = 0;
    while (format[n] != 0) {
        out[n] = format[n];
        n++;
    }
    out[n] = 0;
    return n;
}

void esp_phy_modem_init(uint8_t modem)
{
    (void)modem;
}

void esp_phy_modem_deinit(uint8_t modem)
{
    (void)modem;
}

void esp_phy_enable(esp_phy_modem_t modem)
{
    static esp_phy_calibration_data_t cal;
    static int done;
    (void)modem;
    if (done) {
        return;
    }
    done = 1;
    SET_PERI_REG_MASK(SYSTEM_WIFI_CLK_EN_REG, SYSTEM_WIFI_CLK_WIFI_BT_COMMON_M | SYSTEM_WIFI_CLK_PHY_EN_M | SYSTEM_WIFI_CLK_RNG_EN | SYSTEM_WIFI_CLK_WIFI_EN_M);
    phy_init_param_set(1);
    esp_read_mac(cal.mac, 0);
    int answer = register_chipv7_phy(&phy_init_data, &cal, PHY_RF_CAL_FULL);
    silica_rt_puts("shim: radio started, answer ");
    spike_put_dec((uint32_t)answer);
    silica_rt_puts("\n");
}

void esp_phy_disable(esp_phy_modem_t modem)
{
    (void)modem;
}

// ---- coexistence with Wi-Fi: there is none ----

int coex_init(void) { return 0; }
int coex_enable(void) { return 0; }
void coex_disable(void) { }
int coex_schm_register_callback(int type, void *callback) { (void)type; (void)callback; return 0; }
int coex_schm_status_bit_set(uint32_t type, uint32_t status) { (void)type; (void)status; return 0; }
int coex_schm_status_bit_clear(uint32_t type, uint32_t status) { (void)type; (void)status; return 0; }
uint32_t coex_schm_interval_get(void) { return 0; }
uint8_t coex_schm_curr_period_get(void) { return 1; }
void *coex_schm_curr_phase_get(void) { return NULL; }
void coex_update_lpclk_interval(void) { }

// ---- the log ----

void esp_log(uint32_t config, const char *tag, const char *format, ...)
{
    (void)config;
    silica_rt_puts("log ");
    silica_rt_puts(tag ? tag : "?");
    silica_rt_puts(": ");
    silica_rt_puts(format);
    silica_rt_puts("\n");
}
