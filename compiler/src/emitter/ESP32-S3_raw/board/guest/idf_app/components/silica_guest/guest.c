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

/* Silica's board runtime as a guest of ESP-IDF (transport_ble_plan.md §2.1): its two schedulers as
   two FreeRTOS tasks, one pinned to each core, and the calls the runtime makes into FreeRTOS. The
   runtime (../../../../runtime/rt_*.S built with SILICA_GUEST, ../../../runtime/rt_guest_*.S) and the
   program are linked in by tools/build_image.sh; the application also links without them, which
   is how it is built once ahead of the images, so their entry points are weak here. */

#include <stdint.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "xtensa_api.h"
#include "xtensa_context.h"
#include "esp_private/panic_reason.h"
#include "esp_timer.h"
#include "esp_rom_sys.h"
#include "soc/soc.h"
#include "soc/system_reg.h"
#include "silica_guest.h"

_Static_assert(PANIC_RSN_DEBUGEXCEPTION == 1, "rt_guest_fault.S xt_debugexception writes this value");
_Static_assert(XCHAL_DEBUGLEVEL == 6, "rt_guest_fault.S xt_debugexception reads EPS6, EPC6, EXCSAVE6");

/* One above the idle tasks: Silica runs whenever nothing of ESP-IDF's wants the core. */
#define SCHEDULER_PRIORITY 1
/* The scheduler tasks' own stacks hold only the task's start: Silica moves to its stacks at once. */
#define SCHEDULER_STACK 4096

__attribute__((weak)) void silica_guest_core0_entry(void);   /* rt_guest_start.S: do not return */
__attribute__((weak)) void silica_guest_core1_entry(void);
__attribute__((weak, noreturn)) void silica_guest_fault_enter(uint32_t cause, uint32_t pc, uint32_t vaddr);
extern uint8_t silica_rt_core_regs[] __attribute__((weak));   /* 192 bytes a core */
extern void xt_unhandled_exception(XtExcFrame *frame);

static TaskHandle_t schedulers[2];
static volatile int ended;
/* 1 once a core's scheduler has been stalled for the end of the process: it is not resumed. */
static volatile int stalled[2];
static portMUX_TYPE stall_lock = portMUX_INITIALIZER_UNLOCKED;
static int stress_on(void);     /* stress mode, below */

/* A CPU exception on this core. It is Silica's when a Silica scheduler task was running task code
   with interrupts on (THREADPTR is that core's register block; FreeRTOS keeps THREADPTR per task):
   the actor that was running is ended, not the program (rt_guest_fault.S). Anything else -- another
   task, an interrupt handler, C code inside a critical section -- is ESP-IDF's panic. */
static void silica_guest_exception(XtExcFrame *frame) {
    uint32_t tp;
    __asm__ volatile ("rur.threadptr %0" : "=r"(tp));
    if (tp == (uint32_t)(silica_rt_core_regs + 192 * xPortGetCoreID()) && (frame->ps & 0xF) == 0) {
        silica_guest_fault_enter(frame->exccause, frame->pc, frame->excvaddr);
    }
    xt_unhandled_exception(frame);
}

/* The causes ESP-IDF hands to a registered handler: every one but the system call (1), the level-1
   interrupt (4), the alloca exception (5) and the coprocessor exceptions (32 and up), which its
   vector handles itself. Registered per core, by the task that runs on it. */
static void take_exceptions(void) {
    for (int cause = 0; cause < 32; cause++) {
        if (cause != 1 && cause != 4 && cause != 5) xt_set_exception_handler(cause, silica_guest_exception);
    }
}

/* A scheduler that never goes idle would keep its core's idle task from running, and the task
   watchdog watches the idle tasks. Once a second this task, above the scheduler on the same core,
   holds a scheduler that is ready to run back for one tick. A scheduler that is blocked (nothing
   ready, or inside a foreign call that waits) is left alone: the idle task already runs. */
static void breather_task(void *arg) {
    int core = xPortGetCoreID();
    TaskHandle_t scheduler = arg;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(stress_on() ? 50 : 1000));
        if (stalled[core]) vTaskDelete(NULL);
        if (eTaskGetState(scheduler) == eReady) {
            vTaskSuspend(scheduler);
            vTaskDelay(1);
            /* not a scheduler the other core stalled meanwhile; one that halted suspends itself again */
            portENTER_CRITICAL(&stall_lock);
            int resume = !stalled[core];
            portEXIT_CRITICAL(&stall_lock);
            if (resume) vTaskResume(scheduler);
        }
    }
}

/* Stress mode (tools/build_image.sh with GUEST_STRESS=1, which links rt_guest_start.S's strong
   silica_guest_stress): what is rare in an ordinary run is made constant. A timer with an irregular
   period of 150 to 660 microseconds wakes one task on each core, above the schedulers, so a Silica
   scheduler is interrupted and switched out at points that drift across its code, each switch spilling
   its register windows onto the Silica stack it was on; and the breather holds a busy scheduler back
   every 50 ms. (The fault entry's own stress is in rt_guest_fault.S.) */
extern const int silica_guest_stress __attribute__((weak));
static TaskHandle_t stressers[2];
static esp_timer_handle_t stress_timer;
static uint32_t stress_seed = 12345;

static int stress_on(void) { return &silica_guest_stress != NULL && silica_guest_stress != 0; }

static void stress_fire(void *arg) {
    (void)arg;
    if (ended) return;
    stress_seed = stress_seed * 1103515245u + 12345u;
    for (int core = 0; core < 2; core++) if (stressers[core] != NULL) xTaskNotifyGive(stressers[core]);
    esp_timer_start_once(stress_timer, 150 + ((stress_seed >> 16) & 511));
}

static void stress_task(void *arg) {
    (void)arg;
    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        if (ended) vTaskDelete(NULL);
        esp_rom_delay_us(15);
    }
}

static void stress_start(void) {
    const esp_timer_create_args_t args = { .callback = stress_fire, .name = "silica_stress" };
    for (int core = 0; core < 2; core++) {
        xTaskCreatePinnedToCore(stress_task, core ? "silica1s" : "silica0s", 2048, NULL, SCHEDULER_PRIORITY + 2, &stressers[core], core);
    }
    if (esp_timer_create(&args, &stress_timer) == ESP_OK) esp_timer_start_once(stress_timer, 500);
}

static void core0_task(void *arg) { (void)arg; take_exceptions(); silica_guest_core0_entry(); }
/* Core 1's task exists from the start and waits to be told to run, so that starting core 1 from
   Silica's stack is one notification and not the creation of a task. */
static void core1_task(void *arg) {
    (void)arg;
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    take_exceptions();
    silica_guest_core1_entry();
}

static void start_scheduler(int core, TaskFunction_t fn, const char *name, const char *breather) {
    xTaskCreatePinnedToCore(fn, name, SCHEDULER_STACK, NULL, SCHEDULER_PRIORITY, &schedulers[core], core);
    xTaskCreatePinnedToCore(breather_task, breather, 2048, schedulers[core], SCHEDULER_PRIORITY + 1, NULL, core);
}

/* ESP-IDF's start-up turns off the clock of every peripheral it does not use itself and holds it in
   reset. The peripherals Silica's device actors drive by their registers (../../../../pack: UART1,
   SPI2, RMT, LEDC) are put back as the bare-metal runtime finds them: clocked and out of reset. */
static void peripherals_for_silica(void) {
    static portMUX_TYPE lock = portMUX_INITIALIZER_UNLOCKED;
    uint32_t clocks = SYSTEM_UART1_CLK_EN | SYSTEM_SPI2_CLK_EN | SYSTEM_RMT_CLK_EN | SYSTEM_LEDC_CLK_EN;
    uint32_t resets = SYSTEM_UART1_RST | SYSTEM_SPI2_RST | SYSTEM_RMT_RST | SYSTEM_LEDC_RST;
    portENTER_CRITICAL(&lock);
    SET_PERI_REG_MASK(SYSTEM_PERIP_CLK_EN0_REG, clocks);
    CLEAR_PERI_REG_MASK(SYSTEM_PERIP_RST_EN0_REG, resets);
    portEXIT_CRITICAL(&lock);
}

void silica_guest_run(void) {
    if (!silica_guest_core0_entry) return;      /* the application built without a program */
    peripherals_for_silica();
    start_scheduler(1, core1_task, "silica1", "silica1b");
    if (stress_on()) stress_start();
    start_scheduler(0, core0_task, "silica0", "silica0b");
}

int silica_guest_ended(void) { return ended; }

/* The calls below are made by the Silica runtime, on Silica's stacks. rt_guest_start.S declares how
   much stack each needs (<name>__stack_bound) for the per-image stack sizing; keep them shallow. */

/* rt_actors.S starts core 1 once the actor runtime is initialised (silica_rt_start_app_cpu). */
void silica_guest_start_core1(void) {
    xTaskNotifyGive(schedulers[1]);
}

/* In place of stalling the other core: its scheduler task stops being scheduled. */
void silica_guest_stall_other(void) {
    int other_core = xPortGetCoreID() == 0 ? 1 : 0;
    TaskHandle_t other = schedulers[other_core];
    portENTER_CRITICAL(&stall_lock);
    stalled[other_core] = 1;
    portEXIT_CRITICAL(&stall_lock);
    if (other != NULL) vTaskSuspend(other);
}

/* In place of the halt at the program's end. */
void silica_guest_halt(void) {
    ended = 1;
    for (;;) vTaskSuspend(NULL);
}

/* A scheduler with nothing ready (rt_actors.S silica_rt_sched_loop): block until another core
   queues work for this one (silica_guest_wake) or one tick passes. */
void silica_guest_idle_wait(void) {
    ulTaskNotifyTake(pdTRUE, 1);
}

/* Work was queued for that core while its scheduler was blocked (rt_actors.S silica_rt_rq_push). */
void silica_guest_wake(int core) {
    if (schedulers[core] != NULL) xTaskNotifyGive(schedulers[core]);
}
