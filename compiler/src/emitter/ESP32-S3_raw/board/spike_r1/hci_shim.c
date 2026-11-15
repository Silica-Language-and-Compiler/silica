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
//               reads the line's pending bit and calls the handler in ordinary context. Built with
//               SPIKE_INTERRUPT the line is a level-3 one that is enabled, and the runtime's level-3
//               path (rt_vectors.S) calls the handler when the interrupt comes; what the handler shares
//               with the rest (the queues, the switch of control) is then done with the level masked.
//   tasks       xTaskCreatePinnedToCore makes a coroutine (spike_co.S): the controller's task, and
//               NimBLE's when the host is in the image. A call that would block passes control round
//               the lines of control, main's among them, until it can go on.
//   queues, semaphores, mutexes   one structure, a ring of items (none for a semaphore).
//   timers      ESP-IDF's one-shot timers (NimBLE's timeouts), run when a line of control yields.
//   memory      one block, first fit, freed blocks joined.
//   two cores   built with SPIKE_BT_CORE=1 the tasks, the timers and the controller's handler are core
//               1's alone (spike_bt_core_loop), and a Silica program's actors call the wrapper from core
//               0. What both touch is under one lock, taken with the level masked; a call from core 0
//               that would block waits without passing control, since the tasks run beside it.
//   the radio   esp_phy_enable is phy_main.c's start.
//
// The types are written as their machine forms so that no FreeRTOS header is needed.

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdarg.h>
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

#ifndef ARENA_KB
#define ARENA_KB 56
#endif

void *malloc(size_t n);

#define MAX_IRQ 8
static struct irq {
    void (*handler)(void *);
    void *arg;
    int line;
    int enabled;
} irqs[MAX_IRQ];
static int irq_count;
uint32_t spike_handler_calls;
// Which core this is: the processor's identity register reads 0xCDCD on core 0 and 0xABAB on core 1.
static inline int core_id(void)
{
    uint32_t prid;
    __asm__ volatile("rsr.prid %0" : "=r"(prid));
    return prid == 0xCDCD ? 0 : 1;
}

#ifdef SPIKE_BT_CORE
static inline int on_bt_core(void)
{
    return core_id() == SPIKE_BT_CORE;
}

// One lock for what the two cores share, held with level 3 masked on the holder's core; the holder may
// take it again.
static volatile uint32_t lock_owner;    // 0, or the core's number plus 1
static uint32_t lock_depth;

static inline void lock_take(void)
{
    uint32_t me = (uint32_t)core_id() + 1;
    if (lock_owner != me) {
        while (!__sync_bool_compare_and_swap(&lock_owner, 0, me)) {
        }
    }
    lock_depth++;
}

static inline void lock_give(void)
{
    if (--lock_depth == 0) {
        lock_owner = 0;
    }
}
#else
static inline int on_bt_core(void)
{
    return 1;
}

static inline void lock_take(void)
{
}

static inline void lock_give(void)
{
}
#endif

static int in_handler;
static volatile uint32_t lines_to_enable;   // asked for from the other core, enabled by the Bluetooth core

// In the controller's handler: only the Bluetooth core takes it.
static inline int in_isr(void)
{
    return on_bt_core() && in_handler;
}

#ifdef SPIKE_INTERRUPT
// the CPU's level-3 lines that take a level from a peripheral
static const uint8_t lines[MAX_IRQ] = { 23, 27, 23, 27, 23, 27, 23, 27 };
extern void (*silica_rt_level3_handler)(void);

static inline uint32_t mask_level3(void)
{
    uint32_t ps;
    __asm__ volatile("rsil %0, 3" : "=r"(ps));
    lock_take();
    return ps;
}

static inline void unmask(uint32_t ps)
{
    lock_give();
    __asm__ volatile("wsr.ps %0\n rsync" : : "r"(ps));
}

static void dispatch(void);

// A core enables its own interrupt lines.
static void enable_lines(void)
{
    uint32_t want = lines_to_enable, enabled;
    if (want == 0) {
        return;
    }
    __asm__ volatile("rsr.intenable %0" : "=r"(enabled));
    enabled |= want;
    __asm__ volatile("wsr.intenable %0\n rsync" : : "r"(enabled));
    lines_to_enable = 0;
}
#else
// CPU interrupt lines that take a level from a peripheral (level 1; they stay disabled)
static const uint8_t lines[MAX_IRQ] = { 0, 1, 2, 3, 4, 5, 8, 9 };

static inline uint32_t mask_level3(void)
{
    return 0;
}

static inline void unmask(uint32_t ps)
{
    (void)ps;
}
#endif

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
#ifdef SPIKE_BT_CORE
    intr_matrix_set(SPIKE_BT_CORE, (uint32_t)source, (uint32_t)q->line);
#else
    intr_matrix_set(0, (uint32_t)source, (uint32_t)q->line);
#endif
    silica_rt_puts("shim: interrupt source ");
    spike_put_dec((uint32_t)source);
    silica_rt_puts(" on line ");
    spike_put_dec((uint32_t)q->line);
    silica_rt_puts("\n");
    if (ret_handle) {
        *ret_handle = q;
    }
#ifdef SPIKE_INTERRUPT
    silica_rt_level3_handler = dispatch;
    // the Bluetooth core enables the line at its next pass when this is the other core
    lines_to_enable |= 1u << q->line;
    if (on_bt_core()) {
        enable_lines();
    } else {
        while (lines_to_enable != 0) {
        }
    }
#endif
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

#ifdef SPIKE_INTERRUPT
void spike_poll(void)
{
}

// called by the runtime's level-3 path
static void dispatch(void)
#else
void spike_poll(void)
#endif
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
    return in_isr();
}

static uint32_t critical_depth, critical_ps;

int xPortEnterCriticalTimeout(void *mux, int timeout)
{
    (void)mux;
    (void)timeout;
    uint32_t ps = mask_level3();
    if (critical_depth++ == 0) {
        critical_ps = ps;
    }
    return 1;
}

void vPortExitCritical(void *mux)
{
    (void)mux;
    if (--critical_depth == 0) {
        unmask(critical_ps);
    } else {
        lock_give();    // each entry took the lock; only the outermost exit puts the level back
    }
}

void _frxt_setup_switch(void)
{
}

// ---- the two lines of control ----

#define MAX_CO 4
enum { CO_FREE, CO_NEW, CO_LIVE, CO_DEAD, CO_TAKEN };
static struct co {
    uint32_t ctx[2];
    void (*fn)(void *);
    void *arg;
    uint32_t *stack_top;
    int state;
} cos[MAX_CO] = { { .state = CO_LIVE } };   // 0 is main's
static int co_cur;
static struct co other_core;    // stands for whoever calls from the core that is not the tasks'
uint32_t spike_switches;

static struct co *current(void)
{
    return on_bt_core() ? &cos[co_cur] : &other_core;
}

static void timers_run(void);
void spike_yield(void);

// Where a task starts: the level was masked for the switch that started it.
static void co_entry(void *arg)
{
    struct co *c = arg;
#ifdef SPIKE_INTERRUPT
    // the switch that started this left the level masked and the lock held, for this side to undo
    uint32_t ps;
    __asm__ volatile("rsr.ps %0" : "=r"(ps));
    unmask(ps & ~0xFu);
#endif
    c->fn(c->arg);
    c->state = CO_DEAD;
    for (;;) {
        spike_yield();
    }
}

// Lets the interrupts, the timers and the next line of control run once.
void spike_yield(void)
{
    if (!on_bt_core()) {
        return;
    }
    spike_poll();
#ifdef SPIKE_INTERRUPT
    enable_lines();
#endif
    if (in_handler) {
        return;
    }
    timers_run();
    int next = co_cur;
    do {
        next = (next + 1) % MAX_CO;
    } while (next != co_cur && cos[next].state != CO_NEW && cos[next].state != CO_LIVE);
    if (next == co_cur) {
        return;
    }
    spike_switches++;
    // no handler runs while the stacks and the register windows change hands
    uint32_t ps = mask_level3();
    int from = co_cur;
    co_cur = next;
    if (cos[next].state == CO_NEW) {
        cos[next].state = CO_LIVE;
        spike_co_start(cos[from].ctx, cos[next].stack_top, co_entry, &cos[next]);
    } else {
        spike_co_switch(cos[from].ctx, cos[next].ctx);
    }
    unmask(ps);
}

int xTaskCreatePinnedToCore(void (*fn)(void *), const char *name, uint32_t stack, void *arg, uint32_t prio, void **handle, int core)
{
    (void)prio;
    (void)core;
    silica_rt_puts("shim: task ");
    silica_rt_puts(name);
    silica_rt_puts("\n");
    for (int i = 1; i < MAX_CO; i++) {
        uint32_t ps = mask_level3();
        int free_slot = cos[i].state == CO_FREE || cos[i].state == CO_DEAD;
        if (free_slot) {
            cos[i].state = CO_TAKEN;
        }
        unmask(ps);
        if (free_slot) {
            // twice what FreeRTOS is asked for and 4 KB more: the controller's handler runs on whichever
            // stack is current, and a switch spills the register windows onto it
            uint32_t bytes = (2 * (stack < 4096 ? 4096 : stack) + 4096 + 15) & ~15u;
            uint32_t *base = malloc(bytes);
            if (base == NULL) {
                cos[i].state = CO_FREE;
                return 0;
            }
            cos[i].fn = fn;
            cos[i].arg = arg;
            cos[i].stack_top = base + bytes / 4 - 16;
            cos[i].state = CO_NEW;
            if (handle) {
                *handle = &cos[i];
            }
            return 1;
        }
    }
    return 0;
}

void vTaskDelete(void *handle)
{
    struct co *c = handle ? handle : current();
    if (c == &other_core) {
        return;
    }
    c->state = CO_DEAD;
    while (c == current()) {
        spike_yield();
    }
}

void *xTaskGetCurrentTaskHandle(void)
{
    return current();
}

int xTaskGetSchedulerState(void)
{
    return 2;   // running
}

void vTaskDelay(uint32_t ticks)
{
    uint64_t start = spike_ticks();
    do {
        spike_yield();
    } while ((spike_ticks() - start) / 16000 < ticks);
}

void vPortYield(void)
{
    spike_yield();
}

// ---- memory ----

// Blocks of 16-byte multiples, each under a 16-byte header, in address order; a freed block is joined
// to the free blocks after it.
struct block {
    uint32_t size;      // with the header
    uint32_t used;
    uint32_t pad[2];
};
static uint8_t arena[ARENA_KB * 1024] __attribute__((aligned(16)));
static uint32_t arena_given, arena_most;

static struct block *next_block(struct block *b)
{
    return (struct block *)((uint8_t *)b + b->size);
}

void *malloc(size_t n)
{
    uint32_t need = (uint32_t)((n + 15) & ~(size_t)15) + sizeof(struct block);
    void *p = NULL;
    uint32_t ps = mask_level3();
    struct block *b = (struct block *)arena, *end = (struct block *)(arena + sizeof(arena));
    if (b->size == 0) {
        b->size = sizeof(arena);
    }
    for (; b < end; b = next_block(b)) {
        if (b->used) {
            continue;
        }
        while (next_block(b) < end && !next_block(b)->used) {
            b->size += next_block(b)->size;
        }
        if (b->size >= need) {
            if (b->size - need >= 2 * sizeof(struct block)) {
                struct block *rest = (struct block *)((uint8_t *)b + need);
                rest->size = b->size - need;
                rest->used = 0;
                b->size = need;
            }
            b->used = 1;
            arena_given += b->size;
            if (arena_given > arena_most) {
                arena_most = arena_given;
            }
            p = b + 1;
            break;
        }
    }
    unmask(ps);
    if (p == NULL) {
        silica_rt_puts("shim: out of memory\n");
    }
    return p;
}

void free(void *p)
{
    if (p == NULL) {
        return;
    }
    uint32_t ps = mask_level3();
    struct block *b = (struct block *)p - 1;
    b->used = 0;
    arena_given -= b->size;
    unmask(ps);
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

void *heap_caps_realloc(void *p, size_t n, uint32_t caps)
{
    (void)caps;
    void *q = malloc(n);
    if (q && p) {
        size_t had = ((struct block *)p - 1)->size - sizeof(struct block);
        memcpy(q, p, had < n ? had : n);
        free(p);
    }
    return q;
}

void heap_caps_free(void *p)
{
    free(p);
}

size_t heap_caps_get_free_size(uint32_t caps)
{
    (void)caps;
    return sizeof(arena) - arena_given;
}

size_t heap_caps_get_largest_free_block(uint32_t caps)
{
    (void)caps;
    return sizeof(arena) - arena_given;
}

size_t heap_caps_get_minimum_free_size(uint32_t caps)
{
    (void)caps;
    return sizeof(arena) - arena_most;
}

int heap_caps_add_region(intptr_t start, intptr_t end)
{
    (void)start;
    (void)end;
    return 0;
}

uint32_t spike_arena_used(void)
{
    return arena_most;
}

// ---- queues, semaphores and mutexes ----

struct queue {
    uint32_t length, item, count, head;
    uint8_t *items;
    struct co *owner;   // of a mutex taken through the recursive calls
    uint32_t depth;
};

static struct queue *queue_new(uint32_t length, uint32_t item, uint32_t count)
{
    struct queue *q = malloc(sizeof *q);
    q->length = length;
    q->item = item;
    q->count = count;
    q->head = 0;
    q->owner = NULL;
    q->depth = 0;
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

void vQueueDelete(void *handle)
{
    struct queue *q = handle;
    free(q->items);
    free(q);
}

uint32_t uxQueueMessagesWaiting(void *q)
{
    return ((struct queue *)q)->count;
}

uint32_t uxQueueMessagesWaitingFromISR(void *q)
{
    return ((struct queue *)q)->count;
}

uint32_t uxQueueSpacesAvailable(void *q)
{
    return ((struct queue *)q)->length - ((struct queue *)q)->count;
}

int xQueueIsQueueEmptyFromISR(void *q)
{
    return ((struct queue *)q)->count == 0;
}

int xQueueGenericReset(void *handle, int fresh)
{
    (void)fresh;
    struct queue *q = handle;
    uint32_t ps = mask_level3();
    q->count = 0;
    q->head = 0;
    unmask(ps);
    return 1;
}

static int put(struct queue *q, const void *item)
{
    uint32_t ps = mask_level3();
    int ok = q->count != q->length;
    if (ok) {
        if (q->item) {
            memcpy(q->items + ((q->head + q->count) % q->length) * q->item, item, q->item);
        }
        q->count++;
    }
    unmask(ps);
    return ok;
}

static int get(struct queue *q, void *item)
{
    uint32_t ps = mask_level3();
    int ok = q->count != 0;
    if (ok) {
        if (q->item) {
            memcpy(item, q->items + q->head * q->item, q->item);
            q->head = (q->head + 1) % q->length;
        }
        q->count--;
    }
    unmask(ps);
    return ok;
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
        if (in_isr() || expired(start, ticks)) {
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
        if (in_isr() || expired(start, ticks)) {
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

int xQueueTakeMutexRecursive(void *handle, uint32_t ticks)
{
    struct queue *q = handle;
    if (q->owner == current()) {
        q->depth++;
        return 1;
    }
    if (!xQueueSemaphoreTake(q, ticks)) {
        return 0;
    }
    q->owner = current();
    q->depth = 1;
    return 1;
}

int xQueueGiveMutexRecursive(void *handle)
{
    struct queue *q = handle;
    if (q->owner != current()) {
        return 0;
    }
    if (--q->depth == 0) {
        q->owner = NULL;
        xQueueGenericSend(q, NULL, 0, 0);
    }
    return 1;
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

// ---- timers: ESP-IDF's one-shot timers, run when a line of control yields ----

#define MAX_TIMERS 32
static struct timer {
    void (*callback)(void *);
    void *arg;
    uint64_t due;       // in the system timer's ticks
    int used, active;
} timers[MAX_TIMERS];
static int in_timers;

int esp_timer_create(const void *args, void **handle)
{
    // esp_timer_create_args_t begins with the callback and its argument
    void *const *a = args;
    uint32_t ps = mask_level3();
    for (int i = 0; i < MAX_TIMERS; i++) {
        if (!timers[i].used) {
            timers[i].used = 1;
            timers[i].active = 0;
            timers[i].callback = (void (*)(void *))a[0];
            timers[i].arg = a[1];
            *handle = &timers[i];
            unmask(ps);
            return 0;
        }
    }
    unmask(ps);
    return 0x101;
}

int esp_timer_start_once(void *handle, uint64_t us)
{
    struct timer *t = handle;
    uint32_t ps = mask_level3();
    int was = t->active;
    if (!was) {
        t->due = spike_ticks() + us * 16;
        t->active = 1;
    }
    unmask(ps);
    return was ? 0x103 : 0;
}

int esp_timer_stop(void *handle)
{
    struct timer *t = handle;
    uint32_t ps = mask_level3();
    int was = t->active;
    t->active = 0;
    unmask(ps);
    return was ? 0 : 0x103;
}

int esp_timer_delete(void *handle)
{
    ((struct timer *)handle)->used = 0;
    ((struct timer *)handle)->active = 0;
    return 0;
}

int esp_timer_is_active(void *handle)
{
    return ((struct timer *)handle)->active;
}

int esp_timer_get_expiry_time(void *handle, uint64_t *expiry)
{
    *expiry = ((struct timer *)handle)->due / 16;
    return 0;
}

static void timers_run(void)
{
    if (in_timers) {
        return;
    }
    in_timers = 1;
    uint64_t now = spike_ticks();
    for (int i = 0; i < MAX_TIMERS; i++) {
        uint32_t ps = mask_level3();
        int due = timers[i].used && timers[i].active && timers[i].due <= now;
        if (due) {
            timers[i].active = 0;
        }
        unmask(ps);
        if (due) {
            timers[i].callback(timers[i].arg);
        }
    }
    in_timers = 0;
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

// The ROM's rand and srand keep their state through the C library's per-task record, which nothing
// here sets up (ESP-IDF's own C library replaces them): a store through a null pointer.
int rand(void)
{
    return (int)(esp_random() & 0x7FFFFFFF);
}

void srand(unsigned seed)
{
    (void)seed;
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
    return mask_level3();
}

void phy_exit_critical(uint32_t level)
{
    unmask(level);
}

int phy_printf(const char *format, ...)
{
    silica_rt_puts("phy: ");
    silica_rt_puts(format);
    return 0;
}

void phy_i2c_enter_critical(void)
{
}

void phy_i2c_exit_critical(void)
{
}

// A small formatter: %s %c %d %i %u %x %X %p %%, a width, a zero fill, and the l, ll, h, z lengths.
static int format_into(char *out, size_t room, const char *f, va_list ap)
{
    size_t n = 0;
#define PUT(ch) do { if (n + 1 < room) out[n] = (ch); n++; } while (0)
    for (; *f; f++) {
        if (*f != '%') {
            PUT(*f);
            continue;
        }
        f++;
        int zero = 0, width = 0, wide = 0, left = 0;
        while (*f == '0' || *f == '-' || *f == '+' || *f == ' ' || *f == '#') {
            zero |= *f == '0';
            left |= *f == '-';
            f++;
        }
        if (*f == '*') {
            width = va_arg(ap, int);
            f++;
        }
        while (*f >= '0' && *f <= '9') {
            width = width * 10 + (*f++ - '0');
        }
        if (*f == '.') {
            f++;
            if (*f == '*') {
                (void)va_arg(ap, int);
                f++;
            }
            while (*f >= '0' && *f <= '9') {
                f++;
            }
        }
        while (*f == 'l' || *f == 'h' || *f == 'z') {
            wide += *f == 'l';
            f++;
        }
        char digits[24];
        int count = 0, negative = 0;
        if (*f == 's') {
            const char *t = va_arg(ap, const char *);
            if (t == NULL) {
                t = "(null)";
            }
            int len = (int)strlen(t);
            for (int i = len; i < width && !left; i++) {
                PUT(' ');
            }
            while (*t) {
                PUT(*t++);
            }
            for (int i = len; i < width && left; i++) {
                PUT(' ');
            }
            continue;
        } else if (*f == 'c') {
            PUT((char)va_arg(ap, int));
            continue;
        } else if (*f == '%') {
            PUT('%');
            continue;
        } else if (*f == 'd' || *f == 'i') {
            long long v = wide >= 2 ? va_arg(ap, long long) : va_arg(ap, int);
            negative = v < 0;
            unsigned long long u = negative ? 0ull - (unsigned long long)v : (unsigned long long)v;
            do {
                digits[count++] = (char)('0' + u % 10);
                u /= 10;
            } while (u);
        } else if (*f == 'u' || *f == 'x' || *f == 'X' || *f == 'p') {
            unsigned long long u = wide >= 2 ? va_arg(ap, unsigned long long) : va_arg(ap, unsigned);
            unsigned base = *f == 'u' ? 10 : 16;
            const char *set = *f == 'X' ? "0123456789ABCDEF" : "0123456789abcdef";
            do {
                digits[count++] = set[u % base];
                u /= base;
            } while (u);
        } else {
            if (*f == 0) {
                break;
            }
            continue;
        }
        if (negative && zero) {
            PUT('-');
        }
        for (int i = count + negative; i < width; i++) {
            PUT(zero ? '0' : ' ');
        }
        if (negative && !zero) {
            PUT('-');
        }
        while (count) {
            PUT(digits[--count]);
        }
    }
#undef PUT
    if (room) {
        out[n < room ? n : room - 1] = 0;
    }
    return (int)n;
}

int snprintf(char *out, size_t room, const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    int n = format_into(out, room, format, ap);
    va_end(ap);
    return n;
}

int sprintf(char *out, const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    int n = format_into(out, 256, format, ap);
    va_end(ap);
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
    char line[160];
    va_list ap;
    va_start(ap, format);
    format_into(line, sizeof(line), format, ap);
    va_end(ap);
    silica_rt_puts("log ");
    silica_rt_puts(tag ? tag : "?");
    silica_rt_puts(": ");
    silica_rt_puts(line);
    silica_rt_puts("\n");
}

void esp_log_level_set(const char *tag, int level)
{
    (void)tag;
    (void)level;
}

// ---- storage: nothing is kept ----

int nvs_flash_init(void)
{
    return 0;
}

int nvs_flash_erase(void)
{
    return 0;
}

// ---- the Bluetooth core ----

// The core the tasks, the timers and the controller's handler belong to, when a Silica program's actors
// have the other: passes control round the tasks for ever. Called once on that core, on a stack with
// room for the handler.
void spike_bt_core_loop(void)
{
#ifdef R1_DEBUG
    uint64_t said = spike_ticks();
#endif
    for (;;) {
        spike_yield();
#ifdef R1_DEBUG
        if ((spike_ticks() - said) / 16000000 >= 2) {
            said = spike_ticks();
            silica_rt_puts("bt: handlers ");
            spike_put_dec(spike_handler_calls);
            silica_rt_puts(" switches ");
            spike_put_dec(spike_switches);
            silica_rt_puts(" lock ");
            spike_put_dec(lock_owner);
            silica_rt_puts(" tasks");
            for (int i = 1; i < MAX_CO; i++) {
                silica_rt_puts(" ");
                spike_put_dec((uint32_t)cos[i].state);
            }
            silica_rt_puts("\n");
        }
#endif
    }
}
