/* Deliberate faults for the ESP32-S3_raw FFI trials: the board counterparts of the fault probes in
 * fixtures/src/silica_ffi_fault.c (which needs signals, files and mmap). Same symbol names, so the
 * wrapper .meta files and the Silica trials are shared with the hosts. Each probe raises a CPU
 * exception that the runtime reports as :foreign_fault (rt_ffi.S). Freestanding: stdint only.
 * The host-only unguarded probe (main_unguarded_null_deref_trial) is omitted. */
#include <stddef.h>
#include <stdint.h>

void silica_ffi_null_deref(void) {
    volatile int *p = 0;
    (void)*p;
}

void silica_ffi_past_end_of_ptr(uint8_t *base, int64_t offset) {
    if (base == 0) {
        volatile int *p = 0;
        (void)*p;
        return;
    }
    base[offset] = 1;
}

/* Illegal instruction (exception cause 0). */
void silica_ffi_sigill_probe(void) {
    __asm__ volatile("ill" ::: "memory");
}

/* Integer divide by zero (exception cause 6, the core's divide option). */
void silica_ffi_sigfpe_probe(void) {
    volatile int32_t zero = 0;
    volatile int32_t numerator = 100;
    volatile int32_t quotient = numerator / zero;
    (void)quotient;
}

/* "Bus error": a byte load from the instruction bus. The ESP32-S3 performs
 * misaligned loads and stores to internal data RAM in hardware (no
 * LoadStoreAlignment exception, unlike the ESP32), but byte and halfword
 * accesses to IRAM are not supported by the instruction bus and raise
 * LoadStoreError (exception cause 3). 0x40378000 is the image's vector base:
 * IRAM in every image the board linker script builds. */
void silica_ffi_sigbus_probe(void) {
    volatile uint8_t *p = (volatile uint8_t *)0x40378000u;
    volatile uint8_t value = *p;
    (void)value;
}
