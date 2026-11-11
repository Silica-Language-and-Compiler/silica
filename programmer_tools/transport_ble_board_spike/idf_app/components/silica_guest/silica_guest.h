#pragma once
/* Stage 4 spike. Throwaway. */
#define SILICA_GUEST_PRIORITY 1          /* above idle, below every ESP-IDF system task */
void silica_guest_run(void);             /* start the program: main on core 0, a scheduler on each core */
int silica_guest_ended(void);            /* 1 once the program has printed its exit marker */
