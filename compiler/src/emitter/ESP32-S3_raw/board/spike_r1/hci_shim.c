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
#include "soc/periph_defs.h"
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
static void *stack_take(uint32_t bytes);
uint32_t spike_arena_now(void);

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
#ifdef R1_BOTH_CORES
extern uint32_t silica_rt_level3_stack;
extern uint32_t silica_rt_level3_save[18];
extern volatile uint32_t silica_rt_heap_lock, silica_rt_console_lock;
static uint32_t handler_stack[2048] __attribute__((aligned(16)));
static int preempting, no_timers;
volatile int spike_in_pass;         // the scheduler of the tasks' core is in its pass of the tasks (r1_port.c)
#define VRG_FFI 148                 // rt_actors.S: 1 while a foreign call runs on this core
#ifndef R1_CPU_MHZ
#define R1_CPU_MHZ 80
#endif
#ifndef R1_TICK_US
#define R1_TICK_US 2000
#endif
static int ticking;
uint32_t spike_preempts;
static int preempt(void);
static int over_task(void);
void spike_tick_arm(int soon);
#endif

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
#ifdef R1_BOTH_CORES
    // actors run on the handlers' core: the handlers have a stack of their own (rt_vectors.S)
    silica_rt_level3_stack = (uint32_t)&handler_stack[sizeof handler_stack / 4 - 8];
#endif
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

#ifdef SPIKE_DEBUG
// Starts the watch: the processor's second cycle timer, a level-3 interrupt, reports every two
// seconds where the program is (the timer counts the processor's cycles: a longer gap at a slower clock).
void spike_debug_watch(void)
{
    uint32_t count, enabled;
    silica_rt_level3_handler = dispatch;
    __asm__ volatile("rsr.ccount %0" : "=r"(count));
    count += 480000000u;
    __asm__ volatile("wsr.ccompare1 %0\n rsync" : : "r"(count));
    __asm__ volatile("rsr.intenable %0" : "=r"(enabled));
    enabled |= 1u << 15;
    __asm__ volatile("wsr.intenable %0\n rsync" : : "r"(enabled));
}
#endif

// called by the runtime's level-3 path
static void dispatch(void)
#else
void spike_poll(void)
#endif
{
#if defined(SPIKE_DEBUG) && defined(SPIKE_INTERRUPT)
    {
        // the watch (spike_debug_watch): every two seconds, where the processor was and who called it
        uint32_t fired, pc, ra, count;
        __asm__ volatile("rsr.interrupt %0" : "=r"(fired));
        if (fired & (1u << 15)) {
            __asm__ volatile("rsr.epc3 %0" : "=r"(pc));
            __asm__ volatile("rsr.excsave3 %0" : "=r"(ra));
            __asm__ volatile("rsr.ccount %0" : "=r"(count));
            count += 480000000u;
            __asm__ volatile("wsr.ccompare1 %0\n rsync" : : "r"(count));
            static const char digits[] = "0123456789abcdef";
            char text[40] = "shim: at ........ from ........\n";
            for (int i = 0; i < 8; i++) {
                text[9 + i] = digits[(pc >> (28 - 4 * i)) & 15];
                text[23 + i] = digits[(ra >> (28 - 4 * i)) & 15];
            }
            silica_rt_puts(text);
        }
    }
#endif
    if (in_handler) {
        return;
    }
    uint32_t pending;
    __asm__ volatile("rsr.interrupt %0" : "=r"(pending));
#if defined(R1_BOTH_CORES) && !defined(SPIKE_DEBUG)
    if (pending & (1u << 15)) {
        // the tick (spike_tick_start): nothing to do here but ask for the next; the tasks' turn is below.
        // Over a task the timers are not looked at: the tasks run them as they pass control on.
        spike_tick_arm(over_task() ? 2 : 0);
    }
#endif
    for (int i = 0; i < irq_count; i++) {
        if (irqs[i].enabled && (pending & (1u << irqs[i].line))) {
            in_handler = 1;
            irqs[i].handler(irqs[i].arg);
            in_handler = 0;
            spike_handler_calls++;
#ifdef SPIKE_DEBUG
            if (spike_handler_calls == 1 || spike_handler_calls % 50000 == 0) {
                silica_rt_puts("shim: handler calls ");
                spike_put_dec(spike_handler_calls);
                silica_rt_puts("\n");
            }
#endif
        }
    }
#ifdef R1_BOTH_CORES
    if (preempt()) {
        spike_tick_arm(1);      // the tasks could not have their turn here: soon again
    }
#endif
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

#define MAX_CO 8     // main, and both radios' tasks at once: the controller's, NimBLE's, Wi-Fi's, lwIP's, the station's
enum { CO_FREE, CO_NEW, CO_LIVE, CO_DEAD, CO_TAKEN };
static struct co {
    uint32_t ctx[2];
    void (*fn)(void *);
    void *arg;
    uint32_t *stack_top;
    uint32_t *stack_base;       // the lowest word of its stack, and the stack's size: spike_stack_report
    uint32_t stack_bytes;
    const char *name;
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

#ifdef R1_BOTH_CORES
// Actors run on the tasks' core, and a dispatch may run long. A handler has usually made work for a
// task, so when it interrupted the core's own line of control (the scheduler or an actor, not a task)
// the tasks have a turn before the interrupted code goes on: this frame, on the handlers' stack,
// stands for the interrupted code among the lines of control, and control comes back to it when each
// task has run until it waited.
//
// While the tasks run, the handlers interrupt them as ever: the runtime's one save area of the
// interrupted code's registers, and the three registers of the interrupt itself, are kept here
// meanwhile, and the handlers' stack is given a top under this frame.
//
// Only when the interrupted code is the program's own or the runtime's. Inside a foreign call (this
// core's VRG_FFI word, rt_ffi.S) or the scheduler's own pass of the tasks (spike_in_pass, r1_port.c)
// it is in the libraries or this shim, at a place the tasks are not written to run under: a timer's
// callback half done, a list half changed. Such code gives the tasks their turn itself when it waits.
//
// Not when the interrupted code holds the runtime's heap or console lock: a task that then asked for
// memory or printed would wait for a lock only the interrupted code can give back, or print into the
// middle of its line. (With both free the interrupted code holds neither; the other core holds one
// only for a moment.) The timers are
// left to the tasks' own passes: their callbacks are not to run at the handlers' level.
static uint32_t refused[4];     // the tasks' turn refused: in the scheduler's pass, a foreign call, the heap's lock, the console's
static uint64_t refused_since, refused_longest;
static int refused_longest_why;

void spike_preempt_report(void)
{
    silica_rt_puts("shim: turns under a handler ");
    spike_put_dec(spike_preempts);
    silica_rt_puts("; refused in the pass ");
    spike_put_dec(refused[0]);
    silica_rt_puts(", a foreign call ");
    spike_put_dec(refused[1]);
    silica_rt_puts(", the heap's lock ");
    spike_put_dec(refused[2]);
    silica_rt_puts(", the console's ");
    spike_put_dec(refused[3]);
    silica_rt_puts("; the longest wait ");
    spike_put_dec((uint32_t)(refused_longest / 16));
    silica_rt_puts(" us, kind ");
    spike_put_dec((uint32_t)refused_longest_why);
    silica_rt_puts("\n");
    refused_longest = 0;
}

static int over_task(void)
{
    return co_cur != 0 || preempting;
}

// 1 when the tasks should have had a turn and the interrupted code's place forbade it.
static int preempt(void)
{
#ifdef R1_NO_PREEMPT
    return 0;
#endif
    uint32_t *core_block;
    __asm__ volatile("rur.threadptr %0" : "=r"(core_block));
    if (co_cur != 0 || preempting) {
        return 0;       // a task was interrupted: the tasks are having their turns
    }
    int why = spike_in_pass ? 0 : core_block[VRG_FFI / 4] != 0 ? 1 : silica_rt_heap_lock != 0 ? 2 : silica_rt_console_lock != 0 ? 3 : -1;
    if (why >= 0) {
        // counted, with the longest time the tasks were kept waiting this way, for spike_preempt_report
        uint64_t now = spike_ticks();
        refused[why]++;
        if (refused_since == 0) {
            refused_since = now;
        } else if (now - refused_since > refused_longest) {
            refused_longest = now - refused_since;
            refused_longest_why = why;
        }
        return 1;
    }
    refused_since = 0;
    uint32_t save[18], epc, eps, exc, top = silica_rt_level3_stack;
    memcpy(save, silica_rt_level3_save, sizeof save);
    __asm__ volatile("rsr.epc3 %0" : "=r"(epc));
    __asm__ volatile("rsr.eps3 %0" : "=r"(eps));
    __asm__ volatile("rsr.excsave3 %0" : "=r"(exc));
    silica_rt_level3_stack = ((uint32_t)__builtin_frame_address(0) - 1024) & ~15u;
    preempting = 1;
    no_timers = 1;
    spike_preempts++;
    spike_yield();
    preempting = 0;
    silica_rt_level3_stack = top;
    __asm__ volatile("wsr.epc3 %0" : : "r"(epc));
    __asm__ volatile("wsr.eps3 %0" : : "r"(eps));
    __asm__ volatile("wsr.excsave3 %0\n rsync" : : "r"(exc));
    memcpy(silica_rt_level3_save, save, sizeof save);
    return 0;
}
#endif

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
#ifdef SPIKE_DEBUG
    // every two seconds: which line of control yields, the handlers called, the lines pending and enabled
    static uint64_t said;
    if ((spike_ticks() - said) / 16000000 >= 2) {
        uint32_t pending, enabled;
        __asm__ volatile("rsr.interrupt %0" : "=r"(pending));
        __asm__ volatile("rsr.intenable %0" : "=r"(enabled));
        said = spike_ticks();
        silica_rt_puts("shim: yield from ");
        spike_put_dec((uint32_t)co_cur);
        silica_rt_puts(", handlers ");
        spike_put_dec(spike_handler_calls);
        silica_rt_puts(", pending ");
        spike_put_dec(pending);
        silica_rt_puts(", enabled ");
        spike_put_dec(enabled);
        silica_rt_puts("\n");
    }
#endif
#ifdef R1_BOTH_CORES
    if (no_timers) {
        no_timers = 0;      // under a handler (preempt): the tasks' own passes run the timers
    } else
#endif
    {
        timers_run();
    }
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
    silica_rt_puts(", stack asked ");
    spike_put_dec(stack);
    silica_rt_puts(", the libraries hold ");
    spike_put_dec(spike_arena_now());
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
            // (SPIKE_STACK_TIGHT: what is asked for and no more, where memory is short: measured with both
            // radios at work, a task had used at most half of it; spike_stack_report prints what each has used)
#ifdef SPIKE_STACK_TIGHT
            uint32_t bytes = ((stack < 4096 ? 4096 : stack) + 15) & ~15u;
#else
            uint32_t bytes = (2 * (stack < 4096 ? 4096 : stack) + 4096 + 15) & ~15u;
#endif
            uint32_t *base = stack_take(bytes);
            if (base == NULL) {
                cos[i].state = CO_FREE;
                return 0;
            }
            cos[i].fn = fn;
            cos[i].arg = arg;
            cos[i].stack_top = base + bytes / 4 - 16;
            cos[i].stack_base = base;
            cos[i].stack_bytes = bytes;
            cos[i].name = name;
            cos[i].state = CO_NEW;
            if (handle) {
                *handle = &cos[i];
            }
            return 1;
        }
    }
    return 0;
}

// Each task's stack: how much of it has ever been written (a stack starts as zeros).
void spike_stack_report(void)
{
    for (int i = 1; i < MAX_CO; i++) {
        if (cos[i].state != CO_LIVE || cos[i].stack_base == NULL) {
            continue;
        }
        uint32_t words = cos[i].stack_bytes / 4, low = 0;
        while (low < words && cos[i].stack_base[low] == 0) {
            low++;
        }
        silica_rt_puts("shim: stack of ");
        silica_rt_puts(cos[i].name);
        silica_rt_puts(": used ");
        spike_put_dec(cos[i].stack_bytes - 4 * low);
        silica_rt_puts(" of ");
        spike_put_dec(cos[i].stack_bytes);
        silica_rt_puts("\n");
    }
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

// RAM the runtime's image and heap leave alone: 0x3FCF0000 to 0x3FCF8000, free while the data cache
// is 32 KB or less (spike_flash.c sets it; ESP-IDF heap/port/esp32s3/memory_layout.c). The RAM above
// the image, where the ROM has its stacks while it starts, is the heap's (runtime/silica_esp32s3.ld).
#define HIGH_RAM_START 0x3FCF0000u
#define HIGH_RAM_END   0x3FCF8000u

// The libraries' blocks: 16-byte multiples, each under a 16-byte header, in address order in one
// region; a freed block is joined to the free blocks after it when a search passes it.
struct block {
    uint32_t size;      // with the header
    uint32_t used;
    uint32_t pad[2];
};
static struct region {
    uint8_t *base;
    uint32_t bytes, given, most;
} regions[3];
static uint32_t region_count;
static uint32_t arena_given, arena_most;    // all the libraries hold, in the regions and beyond them

static struct block *next_block(struct block *b)
{
    return (struct block *)((uint8_t *)b + b->size);
}

static void region_add(uint8_t *base, uint32_t bytes)
{
    struct region *r = &regions[region_count++];
    r->base = base;
    r->bytes = bytes;
    ((struct block *)base)->size = bytes;
    ((struct block *)base)->used = 0;
}

static struct region *region_of(void *p)
{
    for (uint32_t i = 0; i < region_count; i++) {
        if ((uint8_t *)p >= regions[i].base && (uint8_t *)p < regions[i].base + regions[i].bytes) {
            return &regions[i];
        }
    }
    return NULL;
}

static void given(uint32_t bytes)
{
    arena_given += bytes;
    if (arena_given > arena_most) {
        arena_most = arena_given;
    }
}

// With the radio's interrupt masked. The first region with room.
static void *region_take(size_t n)
{
    uint32_t need = (uint32_t)((n + 15) & ~(size_t)15) + sizeof(struct block);
    for (uint32_t i = 0; i < region_count; i++) {
        struct region *r = &regions[i];
        struct block *b = (struct block *)r->base, *end = (struct block *)(r->base + r->bytes);
        if (r->bytes - r->given < need) {
            continue;
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
                r->given += b->size;
                if (r->given > r->most) {
                    r->most = r->given;
                }
                given(b->size);
                return b + 1;
            }
        }
    }
    return NULL;
}

static void region_give(struct region *r, void *p)
{
    struct block *b = (struct block *)p - 1;
    b->used = 0;
    r->given -= b->size;
    arena_given -= b->size;
}

#ifdef SPIKE_ONE_HEAP
// One heap for the whole chip: the libraries' memory comes from the runtime's heap (rt_heap.S), beside
// the actors' stacks, states and messages, so neither side keeps memory the other could use.
//
// The libraries' blocks are many, small and long held; left among the actors' they cut the heap into
// pieces too small for a stack chunk. So the libraries first fill regions of their own: the RAM
// above the heap (32 KB, above), then one block of
// SPIKE_LIB_REGION_KB taken from the heap at the first allocation. Only what fits in neither comes
// block by block from the heap, up to SPIKE_LIB_LIMIT_KB in all: beyond that the libraries are
// refused, which they report, where an exhausted heap would end the runtime.
//
// A block from the heap: the runtime's blocks are 8-byte aligned under an 8-byte header ([-8] the
// size, [-4] HEAP_USED); the libraries are given 16-byte alignment, as in the region: a block whose
// payload is not on a 16-byte boundary is handed out 8 bytes further in, with ONE_HEAP_MOVED in the
// word under it where an unmoved block has the runtime's tag. The runtime's heap lock is a spin lock
// both cores take; the radio's interrupt is masked around a call so that it never finds this core
// holding it.
#ifndef SPIKE_LIB_REGION_KB
#define SPIKE_LIB_REGION_KB 38
#endif
#ifndef SPIKE_LIB_LIMIT_KB
#define SPIKE_LIB_LIMIT_KB 160
#endif
#define HEAP_USED 0x5A11CA1D
#define ONE_HEAP_MOVED 0x16A116ED
void *silica_rt_alloc_or_null(uint32_t size);
void silica_rt_free(void *p);
extern uint8_t _silica_heap_start[], _silica_heap_end[];
#define ARENA_BYTES ((uint32_t)(_silica_heap_end - _silica_heap_start))
static uint32_t region_asked;
static void *late_free;     // heap blocks a handler freed, linked through their first word

static uint32_t *block_base(void *p)       // the runtime's payload address of a block handed out
{
    uint32_t *w = p;
    return w[-1] == ONE_HEAP_MOVED ? w - 2 : w;
}

static size_t block_room(void *p)          // the bytes the holder of p may use
{
    if (region_of(p)) {
        return ((struct block *)p - 1)->size - sizeof(struct block);
    }
    uint32_t *base = block_base(p);
    return base[-2] - 8 - (size_t)((uint8_t *)p - (uint8_t *)base);
}

void *malloc(size_t n)
{
    uint32_t ps = mask_level3();
    if (!region_asked) {
        region_asked = 1;
        region_add((uint8_t *)HIGH_RAM_START, HIGH_RAM_END - HIGH_RAM_START);
        uint8_t *r = silica_rt_alloc_or_null(SPIKE_LIB_REGION_KB * 1024 + 8);
        if (r) {
            region_add((uint8_t *)(((uintptr_t)r + 15) & ~(uintptr_t)15), SPIKE_LIB_REGION_KB * 1024);
        }
    }
    void *p = region_take(n);
    int zeroed = p == NULL;                 // the runtime's blocks come zeroed; a region's must be made so
    // Not from a handler: it may have interrupted an actor of its own core inside the runtime's heap,
    // which holds the heap's lock (R1_BOTH_CORES); a handler has the regions only.
    if (p == NULL && !in_isr() && arena_given + n + 16 <= SPIKE_LIB_LIMIT_KB * 1024u) {
        uint32_t *base = silica_rt_alloc_or_null((uint32_t)n + 8);
        if (base) {
            given(base[-2]);
            p = base;
            if ((uintptr_t)base & 8) {
                base[1] = ONE_HEAP_MOVED;
                p = base + 2;
            }
        }
    }
    unmask(ps);
    if (p && !zeroed) {
        memset(p, 0, n);
    }
    if (p == NULL) {
        silica_rt_puts("shim: out of memory: ");
        spike_put_dec((uint32_t)n);
        silica_rt_puts(" bytes asked, the libraries hold ");
        spike_put_dec(arena_given);
        silica_rt_puts(" (");
        spike_put_dec(regions[0].given + regions[1].given + regions[2].given);
        silica_rt_puts(" in their regions of ");
        spike_put_dec(regions[0].bytes + regions[1].bytes + regions[2].bytes);
        silica_rt_puts("), their limit ");
        spike_put_dec(SPIKE_LIB_LIMIT_KB * 1024u);
        silica_rt_puts(", the heap ");
        spike_put_dec(ARENA_BYTES);
        silica_rt_puts("\n");
    }
    return p;
}

void free(void *p)
{
    if (p == NULL) {
        return;
    }
    uint32_t ps = mask_level3();
    struct region *r = region_of(p);
    if (r) {
        region_give(r, p);
    } else if (in_isr()) {
        // the heap's lock may be held under this handler: the block waits for a task's next free
        *(void **)p = late_free;
        late_free = p;
    } else {
        for (;;) {
            uint32_t *base = block_base(p);
            arena_given -= base[-2];
            silica_rt_free(base);
            p = late_free;
            if (p == NULL) {
                break;
            }
            late_free = *(void **)p;
        }
    }
    unmask(ps);
}

#else
static uint8_t arena[ARENA_KB * 1024] __attribute__((aligned(16)));

void *malloc(size_t n)
{
    uint32_t ps = mask_level3();
    if (region_count == 0) {
        region_add(arena, sizeof(arena));
    }
    void *p = region_take(n);
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
    region_give(&regions[0], p);
    unmask(ps);
}

static size_t block_room(void *p)
{
    return ((struct block *)p - 1)->size - sizeof(struct block);
}

#define ARENA_BYTES ((uint32_t)sizeof(arena))
#endif

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
        size_t had = block_room(p);
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
    return ARENA_BYTES - arena_given;
}

size_t heap_caps_get_largest_free_block(uint32_t caps)
{
    (void)caps;
    return ARENA_BYTES - arena_given;
}

size_t heap_caps_get_minimum_free_size(uint32_t caps)
{
    (void)caps;
    return ARENA_BYTES - arena_most;
}

int heap_caps_add_region(intptr_t start, intptr_t end)
{
    (void)start;
    (void)end;
    return 0;
}

uint32_t spike_arena_now(void)
{
    return arena_given;
}

// The most the libraries held in their region and in all, for a report of what the region should be.
void spike_arena_report(void)
{
    silica_rt_puts("shim: the libraries hold ");
    spike_put_dec(arena_given);
    silica_rt_puts(", most ");
    spike_put_dec(arena_most);
    for (uint32_t i = 0; i < region_count; i++) {
        silica_rt_puts("; in a region of ");
        spike_put_dec(regions[i].bytes);
        silica_rt_puts(": ");
        spike_put_dec(regions[i].given);
        silica_rt_puts(", most ");
        spike_put_dec(regions[i].most);
    }
    silica_rt_puts("\n");
}

#ifdef SPIKE_ONE_HEAP
// The runtime's own summary of the heap (in use, free, the sizes of its blocks), for a debug report.
void silica_rt_heap_summary(void);
void spike_heap_report(void)
{
    uint32_t ps = mask_level3();
    silica_rt_heap_summary();
    unmask(ps);
    silica_rt_puts("\n");
    spike_arena_report();
#ifdef SPIKE_HEAP_WALK
    // every size of block in use that takes 1 KB or more in all: size x count, in the order met
    static uint32_t sizes[96], counts[96];
    uint32_t kinds = 0, other = 0;
    ps = mask_level3();
    for (uint32_t *b = (uint32_t *)_silica_heap_start; (uint8_t *)b < _silica_heap_end && b[0] >= 16 && (b[0] & 7) == 0;
         b = (uint32_t *)((uint8_t *)b + b[0])) {
        if (b[1] != HEAP_USED) {
            continue;
        }
        uint32_t k = 0;
        while (k < kinds && sizes[k] != b[0]) {
            k++;
        }
        if (k == kinds) {
            if (kinds == 96) {
                other += b[0];
                continue;
            }
            sizes[kinds] = b[0];
            counts[kinds++] = 0;
        }
        counts[k]++;
    }
    unmask(ps);
    silica_rt_puts("walk:");
    for (uint32_t k = 0; k < kinds; k++) {
        if (sizes[k] * counts[k] >= 1024) {
            silica_rt_puts(" ");
            spike_put_dec(sizes[k]);
            silica_rt_puts("x");
            spike_put_dec(counts[k]);
        }
    }
    silica_rt_puts(" other ");
    spike_put_dec(other);
    silica_rt_puts("\n");
#endif
}
#endif

uint32_t spike_arena_used(void)
{
    return arena_most;
}

// A task's stack is a block like any other of the libraries'.
static void *stack_take(uint32_t bytes)
{
    void *p = malloc(bytes);
    if (p) {
        memset(p, 0, bytes);
    }
    return p;
}

// ---- queues, semaphores and mutexes ----

struct queue {
    uint32_t length, item, count, head;
    uint8_t *items;
    struct co *owner;   // of a mutex taken through the recursive calls
    uint32_t depth;
    uint32_t given;     // the record and the items' storage are the caller's (the static calls)
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
    q->given = 0;
    q->items = item ? malloc(length * item) : NULL;
    return q;
}

// A queue in the caller's record and storage: the handle is the record's address, as FreeRTOS's is
// (its StaticQueue_t is larger than struct queue).
void *xQueueGenericCreateStatic(uint32_t length, uint32_t item, uint8_t *storage, void *record, uint8_t type)
{
    (void)type;
    struct queue *q = record;
    q->length = length;
    q->item = item;
    q->count = 0;
    q->head = 0;
    q->owner = NULL;
    q->depth = 0;
    q->given = 1;
    q->items = storage;
    return q;
}

int xQueueGenericGetStaticBuffers(void *handle, uint8_t **storage, void **record)
{
    struct queue *q = handle;
    if (!q->given) {
        return 0;
    }
    *storage = q->items;
    *record = q;
    return 1;
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
    if (!q->given) {
        free(q->items);
        free(q);
    }
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

// the task that holds a mutex taken through the recursive calls, as its handle
void *xQueueGetMutexHolder(void *handle)
{
    return ((struct queue *)handle)->owner;
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
    uint64_t period;    // in ticks; 0 when the timer runs once
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
        t->period = 0;
        t->active = 1;
#if defined(R1_BOTH_CORES) && !defined(SPIKE_DEBUG)
        spike_tick_arm(0);      // an earlier timer than the tick was asked for
#endif
    }
    unmask(ps);
    return was ? 0x103 : 0;
}

int esp_timer_start_periodic(void *handle, uint64_t us)
{
    struct timer *t = handle;
    uint32_t ps = mask_level3();
    int was = t->active;
    if (!was) {
        t->due = spike_ticks() + us * 16;
        t->period = us * 16;
        t->active = 1;
#if defined(R1_BOTH_CORES) && !defined(SPIKE_DEBUG)
        spike_tick_arm(0);      // an earlier timer than the tick was asked for
#endif
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
        if (due && timers[i].period != 0) {
            timers[i].due = now + timers[i].period;
        } else if (due) {
            timers[i].active = 0;
        }
        unmask(ps);
        if (due) {
            timers[i].callback(timers[i].arg);
        }
    }
    in_timers = 0;
}

#if defined(R1_BOTH_CORES) && !defined(SPIKE_DEBUG)
// The tick of the tasks' core: the processor's second cycle timer, a level-3 interrupt, under which the
// tasks and the timers have a turn (preempt). The tasks wait on timers as well as on the handlers (a
// delay, the libraries' timers, lwIP's, the coexistence of the two radios, which is timed to a fraction
// of a millisecond), and an actor's dispatch on this core may run long. The next tick is asked for at
// the earliest timer's time, R1_TICK_US at the latest (soon 1: in 100 us; soon 2: R1_TICK_US whatever
// the timers), 50 us at the earliest. On the
// tasks' core only: a timer started from the other core is seen at the next tick.
void spike_tick_arm(int soon)
{
    if (!ticking || !on_bt_core()) {
        return;
    }
    uint32_t ps = mask_level3();
    uint64_t now = spike_ticks(), next = now + (soon ? 100u : (uint32_t)R1_TICK_US) * 16u;
    for (int i = 0; soon != 2 && i < MAX_TIMERS; i++) {
        if (timers[i].used && timers[i].active && timers[i].due < next) {
            next = timers[i].due;
        }
    }
    uint32_t gap = next > now + 50u * 16u ? (uint32_t)(next - now) : 50u * 16u, count;
    __asm__ volatile("rsr.ccount %0" : "=r"(count));
    count += gap * (R1_CPU_MHZ / 16u);
    __asm__ volatile("wsr.ccompare1 %0\n rsync" : : "r"(count));
    unmask(ps);
}

// Called once on the tasks' core.
void spike_tick_start(void)
{
    uint32_t enabled;
    silica_rt_level3_handler = dispatch;
    silica_rt_level3_stack = (uint32_t)&handler_stack[sizeof handler_stack / 4 - 8];
    ticking = 1;
    spike_tick_arm(0);
    __asm__ volatile("rsr.intenable %0" : "=r"(enabled));
    enabled |= 1u << 15;
    __asm__ volatile("wsr.intenable %0\n rsync" : : "r"(enabled));
}
#endif

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
        silica_rt_puts("shim: the slow clock's period, in 2^-19 us: ");
        spike_put_dec(cal);
        silica_rt_puts("\n");
    }
    return cal;
}

// The modem's power domain, for both radios: powered and reset by its first user only, as ESP-IDF
// counts them (phy_init.c). A reset at the second radio's start would take the first one's MAC and the
// radio's calibration away.
static int modem_power_users;

void esp_wifi_bt_power_domain_on(void)
{
    if (modem_power_users++ != 0) {
        return;
    }
    CLEAR_PERI_REG_MASK(RTC_CNTL_DIG_PWC_REG, RTC_CNTL_WIFI_FORCE_PD);
    esp_rom_delay_us(10);
    SET_PERI_REG_MASK(SYSTEM_WIFI_CLK_EN_REG, SYSTEM_WIFI_CLK_WIFI_BT_COMMON_M);
    SET_PERI_REG_MASK(SYSCON_WIFI_RST_EN_REG, MODEM_RESET_FIELD_WHEN_PU);
    CLEAR_PERI_REG_MASK(SYSCON_WIFI_RST_EN_REG, MODEM_RESET_FIELD_WHEN_PU);
    CLEAR_PERI_REG_MASK(RTC_CNTL_DIG_ISO_REG, RTC_CNTL_WIFI_FORCE_ISO);
}

void esp_wifi_bt_power_domain_off(void)
{
    // the domain stays powered
    if (modem_power_users > 0) {
        modem_power_users--;
    }
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
    // the Wi-Fi MAC's reset when its glue asks (soc/periph_defs.h PERIPH_WIFI_MODULE), else Bluetooth's
    uint32_t resets = module == PERIPH_WIFI_MODULE ? SYSTEM_WIFIMAC_RST : BT_RESETS;
    SET_PERI_REG_MASK(SYSTEM_CORE_RST_EN_REG, resets);
    CLEAR_PERI_REG_MASK(SYSTEM_CORE_RST_EN_REG, resets);
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

int vsnprintf(char *out, size_t room, const char *format, va_list ap)
{
    return format_into(out, room, format, ap);
}

int sprintf(char *out, const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    int n = format_into(out, 256, format, ap);
    va_end(ap);
    return n;
}

#ifdef SPIKE_WIFI
// What ESP-IDF's start-up does once before either radio (esp_coex's coexist.c): Espressif's
// coexistence library is given its adapter and prepared. Called by whichever radio starts first.
extern void *g_coex_adapter_funcs;
int esp_coex_adapter_register(void *funcs);
int coex_pre_init(void);
void spike_coex_start(void)
{
    static int done;
    if (!done) {
        done = 1;
        esp_coex_adapter_register(&g_coex_adapter_funcs);
        coex_pre_init();
    }
}
#endif

// The Bluetooth controller's first call into the platform (esp_bt_controller_init).
void esp_phy_modem_init(uint8_t modem)
{
    (void)modem;
#ifdef SPIKE_WIFI
    spike_coex_start();
#endif
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

// with Wi-Fi in the image Espressif's own coexistence library is linked (run_wifi.sh)
#ifndef SPIKE_WIFI
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
#endif

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

// ---- a trace of the packets between the host and the controller ----

#ifdef R1_HCI_TRACE
// Built with R1_HCI_TRACE, and the image's calls to ESP-IDF's two functions linked through here (the
// linker's --wrap): every packet is kept as it passes and printed by the Bluetooth core's loop while a
// link is up, > to the controller and < from it, with the time and the first bytes.
typedef struct {
    void (*notify_host_send_available)(void);
    int (*notify_host_recv)(uint8_t *data, uint16_t len);
} vhci_callbacks;
void __real_esp_vhci_host_send_packet(uint8_t *data, uint16_t len);
int __real_esp_vhci_host_register_callback(const vhci_callbacks *callbacks);

#define TRACED 128
static struct traced {
    uint32_t ms;
    uint16_t len;
    uint8_t up, head[28];
} trace[TRACED];
static volatile uint32_t trace_in, trace_out;
static volatile int trace_link;
static const vhci_callbacks *host_callbacks;

static void keep(int up, const uint8_t *data, uint16_t len)
{
    // a link begins with an LE meta event "connection complete" (plain or enhanced) and ends with a
    // disconnection complete, which is still printed
    if (up && len > 3 && data[0] == 0x04 && data[1] == 0x3E && (data[3] == 0x01 || data[3] == 0x0A)) {
        trace_link = 1;
    }
    if (!trace_link) {
        return;
    }
    uint32_t ps = mask_level3();
    if (trace_in - trace_out < TRACED) {
        struct traced *t = &trace[trace_in % TRACED];
        t->ms = (uint32_t)(spike_ticks() / 16000);
        t->len = len;
        t->up = (uint8_t)up;
        for (int i = 0; i < 28 && i < len; i++) {
            t->head[i] = data[i];
        }
        trace_in = trace_in + 1;
    }
    unmask(ps);
    if (up && len > 1 && data[0] == 0x04 && data[1] == 0x05) {
        trace_link = 0;
    }
}

void __wrap_esp_vhci_host_send_packet(uint8_t *data, uint16_t len)
{
    keep(0, data, len);
    __real_esp_vhci_host_send_packet(data, len);
}

static void traced_send_available(void)
{
    host_callbacks->notify_host_send_available();
}

static int traced_recv(uint8_t *data, uint16_t len)
{
    keep(1, data, len);
    return host_callbacks->notify_host_recv(data, len);
}

int __wrap_esp_vhci_host_register_callback(const vhci_callbacks *callbacks)
{
    static const vhci_callbacks mine = { traced_send_available, traced_recv };
    host_callbacks = callbacks;
    return __real_esp_vhci_host_register_callback(&mine);
}

static void trace_print(void)
{
    static const char digits[] = "0123456789ABCDEF";
    while (trace_out != trace_in) {
        struct traced *t = &trace[trace_out % TRACED];
        // the number of completed packets says only that the radio sent something
        if (!(t->up && t->head[0] == 0x04 && t->head[1] == 0x13)) {
            char line[80];
            int n = 0;
            for (int i = 0; i < 28 && i < t->len; i++) {
                line[n++] = digits[t->head[i] >> 4];
                line[n++] = digits[t->head[i] & 15];
            }
            line[n] = 0;
            silica_rt_puts("    ");
            spike_put_dec(t->ms);
            silica_rt_puts(t->up ? " < " : " > ");
            silica_rt_puts(line);
            silica_rt_puts("\n");
        }
        trace_out = trace_out + 1;
    }
}
#endif

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
#ifdef R1_HCI_TRACE
        trace_print();
#endif
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
