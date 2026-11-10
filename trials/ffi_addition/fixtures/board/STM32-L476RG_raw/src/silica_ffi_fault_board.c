/* Deliberate faults for the STM32-L476RG_raw FFI trials: the board counterparts of the fault probes in
 * fixtures/src/silica_ffi_fault.c (which needs signals, files and mmap). Same symbol names, so the
 * wrapper .meta files and the Silica trials are shared with the hosts. Each probe raises a Cortex-M4
 * fault exception that the runtime reports as :foreign_fault (board/runtime/rt_ffi.S, rt_failure.S).
 * Freestanding: stdint only. The host-only unguarded probe (main_unguarded_null_deref_trial) is omitted. */
#include <stddef.h>
#include <stdint.h>

/* MemManage: the runtime's MPU null guard makes 0x0-0xFFFFF no-access (rt_start.S). */
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

/* UsageFault UNDEFINSTR: the permanently undefined encoding. */
void silica_ffi_sigill_probe(void) {
    __asm__ volatile("udf #0" ::: "memory");
}

/* UsageFault DIVBYZERO. The runtime runs with CCR.DIV_0_TRP off (a division by zero gives 0, the
 * AArch64 rule the emitted code relies on), so the probe sets the trap first; the runtime clears it
 * again when it ends the actor on the fault (rt_failure.S silica_rt_actor_fault_hook). */
void silica_ffi_sigfpe_probe(void) {
    volatile uint32_t *ccr = (volatile uint32_t *)0xE000ED14u;
    *ccr |= 0x10u;
    __asm__ volatile("dsb\n\tisb" ::: "memory");
    volatile int32_t zero = 0;
    volatile int32_t numerator = 100;
    volatile int32_t quotient = numerator / zero;
    (void)quotient;
}

/* BusFault: a load from just past SRAM1 (0x20018000), which is not mapped on this part (the reference
 * manual's SRAM2 alias there bus-faults; board/README.md "Memory map"). A precise data bus error. */
void silica_ffi_sigbus_probe(void) {
    volatile uint32_t *p = (volatile uint32_t *)0x20018000u;
    volatile uint32_t value = *p;
    (void)value;
}
