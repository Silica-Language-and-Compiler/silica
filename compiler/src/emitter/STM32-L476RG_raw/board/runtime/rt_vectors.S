/*
   Copyright 2026 Lee Scott Barney

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

// Vector table and exception handlers for the bare-metal STM32L476RG runtime.
//
// The image runs from SRAM: the table is the first thing in the image (linker script
// silica_stm32l476rg.ld, .vectors), and _start (rt_start.S) writes its address into VTOR, so the
// loader only has to set PC = _start and SP (the first word) and resume. Every fault vector lands in
// the fatal path of spec §15.4.5.5 (rt_console.S silica_rt_fatal_report: "[silica] fault at 0x<pc>",
// exit status 70), on the fault stack; SysTick keeps the millisecond clock (rt_actors.S
// silica_rt_ticks_ms) and is the only interrupt the runtime enables. Nothing is preempted: the
// scheduler switches actors only where the specification allows (spec §15.1.2), so the tick handler
// touches nothing but its counter.

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

    .section .vectors, "a", %progbits
    .align  7
    .global silica_rt_vectors
silica_rt_vectors:
    .word   _silica_stack_top               // 0  initial sp (main's machine stack top)
    .word   _start                          // 1  reset
    .word   silica_rt_vec_nmi               // 2
    .word   silica_rt_vec_hardfault         // 3
    .word   silica_rt_vec_memmanage         // 4
    .word   silica_rt_vec_busfault          // 5
    .word   silica_rt_vec_usagefault        // 6
    .word   0, 0, 0, 0                      // 7-10 reserved
    .word   silica_rt_vec_svc               // 11
    .word   silica_rt_vec_debugmon          // 12
    .word   0                               // 13 reserved
    .word   silica_rt_vec_pendsv            // 14
    .word   silica_rt_vec_systick           // 15
    .rept   82                              // 16.. the STM32L476 peripheral IRQs: none enabled
    .word   silica_rt_vec_unused
    .endr

    .text

// SysTick: 1 ms tick. silica_rt_ticks_ms (rt_actors.S) is a 64-bit count read with a retry loop.
    FUNC silica_rt_vec_systick
    push    {r0-r3}
    MOV32   r0, silica_rt_ticks_ms
    ldrd    r2, r3, [r0]
    adds    r2, r2, #1
    adc     r3, r3, #0
    strd    r2, r3, [r0]
    pop     {r0-r3}
    bx      lr
    .size   silica_rt_vec_systick, . - silica_rt_vec_systick

// Faults. The exception entry stacked r0-r3, r12, lr, pc, xPSR on the active stack (MSP: the
// runtime uses one stack pointer). The stacked pc names the faulting instruction (0 when the stacking
// itself failed, CFSR STKERR / MSTKERR); the report runs on the fault stack in SRAM2, switched to
// before anything else, with interrupts masked, and never returns (the chip is reset before the next
// load). r0 = cause code (1 NMI, 3 HardFault, 4 MemManage, 5 BusFault, 6 UsageFault, 11 SVC,
// 12 DebugMon, 14 PendSV, 1000 an unused IRQ), r1 = the stacked pc, r2 = the fault address when
// the cause has one (MMFAR for MemManage, BFAR for BusFault when valid), else 0.
.macro FAULT_VECTOR name, code
    FUNC \name
    movw    r0, #\code
    b.w     silica_rt_fault_common
    .size   \name, . - \name
.endm
    FAULT_VECTOR silica_rt_vec_nmi, 1
    FAULT_VECTOR silica_rt_vec_hardfault, 3
    FAULT_VECTOR silica_rt_vec_memmanage, 4
    FAULT_VECTOR silica_rt_vec_busfault, 5
    FAULT_VECTOR silica_rt_vec_usagefault, 6
    FAULT_VECTOR silica_rt_vec_svc, 11
    FAULT_VECTOR silica_rt_vec_debugmon, 12
    FAULT_VECTOR silica_rt_vec_pendsv, 14
    FAULT_VECTOR silica_rt_vec_unused, 1000

    LFUNC silica_rt_fault_common
    cpsid   i
    mrs     r1, msp                         // the stacked frame (the runtime runs on MSP throughout)
    MOV32   r3, _silica_fault_stack_top     // the report runs on the fault stack (SRAM2): from here
    mov     sp, r3                          // on nothing depends on the stack that may have failed
    MOV32   r3, SCB_CFSR                    // the stacked pc, unless the stacking itself failed
    ldr     r3, [r3]                        // (STKERR / MSTKERR: the frame is not there)
    movw    r12, #0x1010
    tst     r3, r12
    bne.w   4f
    ldr     r1, [r1, #24]
    b.w     5f
4:  movw    r1, #0
5:  movw    r2, #0
    cmp     r0, #4
    bne.w   1f
    MOV32   r3, SCB_CFSR
    ldr     r3, [r3]
    tst     r3, #0x80                       // MMARVALID
    beq.w   2f
    MOV32   r3, SCB_MMFAR
    ldr     r2, [r3]
    b.w     2f
1:  cmp     r0, #5
    bne.w   2f
    MOV32   r3, SCB_CFSR
    ldr     r3, [r3]
    tst     r3, #0x8000                     // BFARVALID
    beq.w   2f
    MOV32   r3, SCB_BFAR
    ldr     r2, [r3]
2:  bl      silica_rt_fatal_report          // never returns
3:  b.w     3b
    .size   silica_rt_fault_common, . - silica_rt_fault_common
