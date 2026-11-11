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

/* Stage 4 spike: Silica's two schedulers as two FreeRTOS tasks, one on each core. Throwaway. */

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "silica_guest.h"

void silica_guest_core0_entry(void);   /* rt_guest_start.S: never return */
void silica_guest_core1_entry(void);

static TaskHandle_t tasks[2];
static volatile int ended;

static void core0_task(void *arg) { (void)arg; silica_guest_core0_entry(); }
static void core1_task(void *arg) { (void)arg; silica_guest_core1_entry(); }

/* The FreeRTOS stacks are only where each task starts: Silica moves to its own stacks at once. */
void silica_guest_run(void) {
    xTaskCreatePinnedToCore(core0_task, "silica0", 4096, NULL, SILICA_GUEST_PRIORITY, &tasks[0], 0);
}

/* rt_actors.S starts core 1 once the actor runtime is initialised (silica_rt_start_app_cpu). */
void silica_guest_start_core1(void) {
    xTaskCreatePinnedToCore(core1_task, "silica1", 4096, NULL, SILICA_GUEST_PRIORITY, &tasks[1], 1);
}

/* In place of stalling the other core: its scheduler task stops being scheduled. */
void silica_guest_stall_other(void) {
    TaskHandle_t other = tasks[xPortGetCoreID() == 0 ? 1 : 0];
    if (other != NULL) vTaskSuspend(other);
}

/* In place of the halt at the program's end. */
void silica_guest_halt(void) {
    ended = 1;
    for (;;) vTaskSuspend(NULL);
}

int silica_guest_ended(void) { return ended; }
