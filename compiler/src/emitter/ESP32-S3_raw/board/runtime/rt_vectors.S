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

// Exception vector table for the bare-metal ESP32-S3 runtime. rt_start points VECBASE here.
//
// The window overflow/underflow handlers are the standard Xtensa windowed-ABI handlers, copied
// instruction for instruction from ESP-IDF components/xtensa/xtensa_vectors.S. They define the
// frame contract the emitter must honour:
//   - the 16 bytes below a function's SP receive its caller's a0-a3 on overflow, so nothing may
//     ever be stored below SP;
//   - a function that makes CALL8 calls has its own a4-a7 spilled to [caller_sp-32, caller_sp-16),
//     i.e. the top of its frame (CALL12: a4-a11 to [caller_sp-48, caller_sp-16)).
// Locals therefore live at or below [sp + frame - 32] (frame - 48 when the function uses CALL12).
//
// Every other vector reports a fatal fault the way every Silica target does (spec §15.4.5.5,
// design_documents/runtime_failure_reporting.md): the line "[silica] fault at 0x<epc>[  addr=0x<excvaddr>]"
// as program output, then the exit marker with status 70; EXCCAUSE, EPC1 and EXCVADDR follow the marker
// (so they never pollute captured program output). The stack-guard data breakpoints enter the same path
// through the debug vector. A runtime abort (silica_rt_abort_*, rt_console.S) resets the context the same
// way, through silica_rt_abort_trampoline below, and reports status 71.
//
// A fault raised while a report is being written (spec §15.4.5.5: a fault inside the fault handler) takes
// a last-resort path instead of starting the report again: silica_rt_fatal_depth counts the trampolines
// entered; the second writes only "[silica] fault at 0x<epc>" and the exit marker with status 70
// (silica_rt_fatal_last_resort, rt_console.S), and a third, a fault in that last resort, halts. Before this
// the trampoline re-ran the report from the top, so a report that faulted repeated itself forever. The
// word is in .data, not .bss, so a fault before rt_start zeroes .bss still reads 0.

// FAULT_STACK_TOP r, t, u: \r = the top of this core's fault stack. Each core has its own (the
// linker reserves two, core 0's on top), so an actor fault on one core never shares a stack with a
// fault or report on the other. \t and \u are scratch. No branch: no local label to collide with.
.macro FAULT_STACK_TOP r, t, u
    movi    \r, _silica_fault_stack_top
    rsr     \t, prid
    extui   \t, \t, 13, 1
    neg     \t, \t
    movi    \u, _silica_fault_stack_size
    and     \t, \t, \u
    sub     \r, \r, \t
.endm

// FATAL_DEPTH_SLOT r, t: \r = &silica_rt_fatal_depth[this core]. \t is scratch.
.macro FATAL_DEPTH_SLOT r, t
    movi    \r, silica_rt_fatal_depth
    rsr     \t, prid
    extui   \t, \t, 13, 1
    addx4   \r, \t, \r
.endm

    .section .WindowVectors.text, "ax"

    .org    0x0
    .global _WindowOverflow4
_WindowOverflow4:
    s32e    a0, a5, -16
    s32e    a1, a5, -12
    s32e    a2, a5,  -8
    s32e    a3, a5,  -4
    rfwo

    .org    0x40
    .global _WindowUnderflow4
_WindowUnderflow4:
    l32e    a0, a5, -16
    l32e    a1, a5, -12
    l32e    a2, a5,  -8
    l32e    a3, a5,  -4
    rfwu

// Alloca exception (EXCCAUSE 5), raised by MOVSP when the caller's base-save registers are live.
// Same code as ESP-IDF's _xt_alloca_exc with the LX7 PS.OWB field (shift 8, 4 bits) spelled out.
    .align  4
    .global silica_rt_alloca_exc
silica_rt_alloca_exc:
    rsr     a0, windowbase
    rotw    -1
    rsr     a2, ps
    extui   a3, a2, 8, 4
    xor     a3, a3, a4
    rsr     a4, excsave1
    slli    a3, a3, 8
    xor     a2, a2, a3
    wsr     a2, ps
    rsync
    bbci.l  a4, 31, _WindowUnderflow4
    rotw    -1
    bbci.l  a8, 30, _WindowUnderflow8
    rotw    -1
    j       _WindowUnderflow12

    .org    0x80
    .global _WindowOverflow8
_WindowOverflow8:
    s32e    a0, a9, -16
    l32e    a0, a1, -12
    s32e    a1, a9, -12
    s32e    a2, a9,  -8
    s32e    a3, a9,  -4
    s32e    a4, a0, -32
    s32e    a5, a0, -28
    s32e    a6, a0, -24
    s32e    a7, a0, -20
    rfwo

    .org    0xC0
    .global _WindowUnderflow8
_WindowUnderflow8:
    l32e    a0, a9, -16
    l32e    a1, a9, -12
    l32e    a2, a9,  -8
    l32e    a7, a1, -12
    l32e    a3, a9,  -4
    l32e    a4, a7, -32
    l32e    a5, a7, -28
    l32e    a6, a7, -24
    l32e    a7, a7, -20
    rfwu

    .org    0x100
    .global _WindowOverflow12
_WindowOverflow12:
    s32e    a0,  a13, -16
    l32e    a0,  a1,  -12
    s32e    a1,  a13, -12
    s32e    a2,  a13,  -8
    s32e    a3,  a13,  -4
    s32e    a4,  a0,  -48
    s32e    a5,  a0,  -44
    s32e    a6,  a0,  -40
    s32e    a7,  a0,  -36
    s32e    a8,  a0,  -32
    s32e    a9,  a0,  -28
    s32e    a10, a0,  -24
    s32e    a11, a0,  -20
    rfwo

    .org    0x140
    .global _WindowUnderflow12
_WindowUnderflow12:
    l32e    a0,  a13, -16
    l32e    a1,  a13, -12
    l32e    a2,  a13,  -8
    l32e    a11, a1,  -12
    l32e    a3,  a13,  -4
    l32e    a4,  a11, -48
    l32e    a5,  a11, -44
    l32e    a6,  a11, -40
    l32e    a7,  a11, -36
    l32e    a8,  a11, -32
    l32e    a9,  a11, -28
    l32e    a10, a11, -24
    l32e    a11, a11, -20
    rfwu

// Interrupts are never enabled by this runtime (INTENABLE = 0), so a level-2..5 vector firing means
// something went wrong; report it like any other fatal exception.
    .section .Level2InterruptVector.text, "ax"
    .global silica_rt_level2_vector
silica_rt_level2_vector:
    wsr     a0, excsave2
    movi    a0, 1002
    j       silica_rt_fatal_trampoline

    .section .Level3InterruptVector.text, "ax"
    .global silica_rt_level3_vector
silica_rt_level3_vector:
    wsr     a0, excsave3
    movi    a0, 1003
    j       silica_rt_fatal_trampoline

    .section .Level4InterruptVector.text, "ax"
    .global silica_rt_level4_vector
silica_rt_level4_vector:
    wsr     a0, excsave4
    movi    a0, 1004
    j       silica_rt_fatal_trampoline

    .section .Level5InterruptVector.text, "ax"
    .global silica_rt_level5_vector
silica_rt_level5_vector:
    wsr     a0, excsave5
    movi    a0, 1005
    j       silica_rt_fatal_trampoline

// Debug exceptions (cause 1006) come from the stack-guard watchpoints rt_start arms; the faulting PC
// is in EPC6, copied to EPC1 so the report shows it.
    .section .DebugExceptionVector.text, "ax"
    .global silica_rt_debug_vector
silica_rt_debug_vector:
    wsr     a0, excsave6
    rsr     a0, epc6
    wsr     a0, epc1
    movi    a0, 1006
    j       silica_rt_fatal_trampoline

    .section .NMIExceptionVector.text, "ax"
    .global silica_rt_nmi_vector
silica_rt_nmi_vector:
    wsr     a0, excsave7
    movi    a0, 1007
    j       silica_rt_fatal_trampoline

    .section .KernelExceptionVector.text, "ax"
    .global silica_rt_kernel_vector
silica_rt_kernel_vector:
    wsr     a0, excsave1
    movi    a0, 1001
    j       silica_rt_fatal_trampoline

// User exceptions: alloca (cause 5) is recoverable; everything else is fatal.
    .section .UserExceptionVector.text, "ax"
    .global silica_rt_user_vector
silica_rt_user_vector:
    wsr     a0, excsave1
    rsr     a0, exccause
    addi    a0, a0, -5
    beqz    a0, 1f
    rsr     a0, exccause
    j       silica_rt_fatal_trampoline
1:  j       silica_rt_alloca_exc      // EXCSAVE1 still holds the interrupted a0, as it expects

    .section .DoubleExceptionVector.text, "ax"
    .global silica_rt_double_vector
silica_rt_double_vector:
    movi    a0, 1008
    j       silica_rt_fatal_trampoline

// a0 = cause code (EXCCAUSE for user exceptions, 1001+ for the other vectors). The faulting
// context is abandoned: a fresh stack and a single live window are set up, the diagnostic is
// printed, and the CPU halts. The windowed register file is unusable in a double exception, so
// the reset of WINDOWSTART here is what makes the report safe to call from any vector.
    .section .text.silica_rt_fatal, "ax"
    .align  4
    .global silica_rt_fatal_trampoline
silica_rt_fatal_trampoline:
    wsr     a0, excsave1          // cause code survives the window reset below
    movi    a0, 0
    wsr     a0, intenable
    rsr     a0, windowbase
    movi    a1, 1
    ssl     a0
    sll     a1, a1
    wsr     a1, windowstart
    rsync
    movi    a1, 0x40020           // PS: WOE=1, EXCM=0, UM=1, INTLEVEL=0, CALLINC=0
    wsr     a1, ps
    rsync
    FATAL_DEPTH_SLOT a2, a4
    l32i    a3, a2, 0
    addi    a4, a3, 1
    s32i    a4, a2, 0
    bnez    a3, 2f                // a report was already running on this core: last resort
    FAULT_STACK_TOP a1, a8, a9
    rsr     a5, excsave1          // cause, pc and address before the hook: its own window
    rsr     a6, epc1              // exceptions overwrite EPC1
    rsr     a7, excvaddr
    // A fault raised while an actor was running on this core ends that actor only (rt_actors.S
    // silica_rt_actor_fault_hook does not return then: it resumes the core's scheduler).
    movi    a0, 0
    mov     a10, a5
    mov     a11, a6               // EPC1 and EXCVADDR go to the hook for the ACB's fault fields
    mov     a12, a7
    call8   silica_rt_actor_fault_hook
    // The process ends, whichever core this is: the other core is stalled and the console lock
    // cleared (rt_console.S silica_rt_console_fatal_reset), so the report below can print.
    call8   silica_rt_console_fatal_reset
    mov     a2, a5
    mov     a3, a6
    mov     a4, a7
    movi    a0, 0
    call0   silica_rt_fatal_report_c0
1:  j       1b
2:  rsr     a2, epc1
    j       silica_rt_fatal_nested

// a2 = the faulting pc, a3 = silica_rt_fatal_depth before this entry (nonzero). Depth 1: a report was
// running, so write the last-resort line and exit 70 on a fresh fault stack; deeper: the last resort
// itself faulted, so halt (the bytes already in the UART FIFO still drain).
    .align  4
silica_rt_fatal_nested:
    movi    a4, 1
    bne     a3, a4, 1f
    FAULT_STACK_TOP a1, a8, a9
    movi    a0, 0
    call0   silica_rt_fatal_last_resort_c0
1:  j       1b

// call0 shim: a2 pc, passed on as argument 0.
    .align  4
silica_rt_fatal_last_resort_c0:
    mov     a10, a2
    call8   silica_rt_fatal_last_resort
1:  j       1b

// call0 shim into the windowed world: a2 cause, a3 epc, a4 excvaddr, passed on as arguments 0-2.
    .align  4
silica_rt_fatal_report_c0:
    mov     a10, a2
    mov     a12, a3
    mov     a14, a4
    call8   silica_rt_fatal_report
1:  j       1b

// Runtime abort: a2 = reason, a3 = address of the call, reached by CALL0 from silica_rt_abort_body
// (rt_console.S) in the aborting routine's window. The same reset as the fatal trampoline (only the
// current window stays live, interrupts off, the fault stack), so the report runs whatever state the
// program's stacks are in; a2 and a3 are registers of the current window and survive it.
// The report runs on the fault stack: nothing below this point is charged to the aborting
// context's stack (tools/main_stack_bound.py reads the declared bound).
    .set    silica_rt_abort_trampoline__stack_bound, 0
    .align  4
    .global silica_rt_abort_trampoline
silica_rt_abort_trampoline:
    movi    a0, 0
    wsr     a0, intenable
    rsr     a0, windowbase
    movi    a1, 1
    ssl     a0
    sll     a1, a1
    wsr     a1, windowstart
    rsync
    movi    a1, 0x40020           // PS: WOE=1, EXCM=0, UM=1, INTLEVEL=0, CALLINC=0
    wsr     a1, ps
    rsync
    FATAL_DEPTH_SLOT a4, a5       // the abort report counts as a running report (see the top)
    l32i    a5, a4, 0
    addi    a6, a5, 1
    s32i    a6, a4, 0
    bnez    a5, 2f
    FAULT_STACK_TOP a1, a8, a9
    movi    a0, 0
    call8   silica_rt_console_fatal_reset // as in the fatal trampoline; a2/a3 survive a call8
    call0   silica_rt_abort_report_c0
1:  j       1b
2:  mov     a2, a3                // report the abort site's call as the pc
    mov     a3, a5
    j       silica_rt_fatal_nested

// call0 shim: a2 reason, a3 address, passed on as arguments 0 and 1.
    .align  4
silica_rt_abort_report_c0:
    mov     a10, a2
    mov     a12, a3
    call8   silica_rt_abort_report
1:  j       1b

    .section .data.silica_rt_fatal, "aw"
    .align  4
    .global silica_rt_fatal_depth
silica_rt_fatal_depth:
    .word   0, 0                      // one count per core
    // 0, or the id + 1 of the core that ends the process (rt_console.S silica_rt_console_fatal_reset);
    // in .data with the depths, so a fault before .bss is zeroed reads 0 too
    .global silica_rt_fatal_owner
silica_rt_fatal_owner:
    .word   0
