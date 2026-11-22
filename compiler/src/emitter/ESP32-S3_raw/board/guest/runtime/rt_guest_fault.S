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

// Faults of the Silica board runtime as a guest of ESP-IDF (transport_ble_plan.md §2.1): what stands
// in for ../../runtime/rt_vectors.S. The vector table is ESP-IDF's; Silica's fault handling is reached
// from it in two places:
//
//   - a CPU exception (an illegal instruction, a bad address, a division by zero, ...) raised while
//     one of Silica's scheduler tasks runs: ESP-IDF's user-exception path calls the handler guest.c
//     registers with xt_set_exception_handler, and the handler calls silica_guest_fault_enter;
//   - a stack-guard hit (the data breakpoints rt_actors.S arms): ESP-IDF's debug vector jumps to
//     xt_debugexception, a weak name this file defines.
//
// Both end in silica_guest_fault_common, which does what rt_vectors.S silica_rt_fatal_trampoline does:
// the faulting context is abandoned, only the current window stays live, the report runs on this
// core's fault stack, and rt_actors.S silica_rt_actor_fault_hook ends the actor that was running and
// resumes the core's scheduler; a fault outside an actor (main's, the scheduler's) is the process's
// and is reported with status 70. The difference from bare metal: interrupts are ESP-IDF's and stay
// on, so the stack pointer is moved to the fault stack before PS lets them in again.
//
// A fault is NOT Silica's, and goes to ESP-IDF's panic as it would without Silica, when it is raised
// in another task, in an interrupt handler, or with interrupts masked (C code inside one of
// FreeRTOS's critical sections: abandoning it would leave the kernel's lock held).

#define FAULT_STACK_SIZE 0x1000

// GUEST_FAULT_STACK_TOP r, t, u: \r = the stack pointer of the first frame on this core's fault stack
// (core 0's stack on top). The frame has no caller, and it calls with CALL8, so when it is spilled
// (the calls under it nest deeply enough, or an interrupt of ESP-IDF's arrives while they are a few
// deep) the window-overflow handler reads its caller's stack pointer from [a1 - 12] and stores a4-a7
// 32 bytes under that. Left as it is found, that word is 0 and the store is to an address near the
// top of memory: an exception inside the overflow handler, which is a double exception. So the frame
// is given a caller's stack pointer, the stack's top, 48 bytes above its own: a4-a7 then land in the
// frame's own unused bytes.
.macro GUEST_FAULT_STACK_TOP r, t, u
    movi    \r, silica_guest_fault_stack_top
    rsr     \t, prid
    extui   \t, \t, 13, 1
    neg     \t, \t
    movi    \u, FAULT_STACK_SIZE
    and     \t, \t, \u
    sub     \t, \r, \t
    addi    \r, \t, -48
    addi    \u, \r, -12
    s32i    \t, \u, 0
.endm

// GUEST_FATAL_DEPTH_SLOT r, t: \r = &silica_rt_fatal_depth[this core].
.macro GUEST_FATAL_DEPTH_SLOT r, t
    movi    \r, silica_rt_fatal_depth
    rsr     \t, prid
    extui   \t, \t, 13, 1
    addx4   \r, \t, \r
.endm

    .section .text.silica_guest_fault, "ax"
    .literal_position

// void silica_guest_fault_enter(cause, pc, vaddr): from guest.c's exception handler, with interrupts
// masked (ESP-IDF calls a handler at PS.INTLEVEL 4). Does not return.
    .align  4
    .global silica_guest_fault_enter
    .type   silica_guest_fault_enter, @function
silica_guest_fault_enter:
    entry   a1, 32
// a2 cause (EXCCAUSE, or 1006 for a stack-guard hit), a3 pc, a4 address. Interrupts are masked and
// stay masked until a1 is the fault stack.
    .global silica_guest_fault_common
silica_guest_fault_common:
    rsr     a0, windowbase
    movi    a5, 1
    ssl     a0
    sll     a5, a5
    wsr     a5, windowstart
    rsync
    GUEST_FATAL_DEPTH_SLOT a5, a6
    l32i    a6, a5, 0
    addi    a7, a6, 1
    s32i    a7, a5, 0
    GUEST_FAULT_STACK_TOP a1, a8, a9
    movi    a0, 0x40020           // PS: WOE=1, EXCM=0, UM=1, INTLEVEL=0, CALLINC=0
    wsr     a0, ps
    rsync
    movi    a0, 0
    bnez    a6, 2f                // a report was already running on this core: last resort
    // A fault raised while an actor was running on this core ends that actor only: the hook does
    // not return then, it resumes the core's scheduler.
#ifdef SILICA_GUEST_STRESS
    movi    a10, 12               // stress mode: the first frame is spilled at every fault
    call8   silica_guest_stress_nest
#endif
    mov     a10, a2
    mov     a11, a3
    mov     a12, a4
    call8   silica_rt_actor_fault_hook
    call8   silica_rt_console_fatal_reset
    mov     a10, a2
    mov     a12, a3
    mov     a14, a4
    call8   silica_rt_fatal_report
1:  call8   silica_guest_halt
    j       1b
2:  movi    a5, 1
    bne     a6, a5, 1b            // the last resort itself faulted: stop
    mov     a10, a3
    call8   silica_rt_fatal_last_resort
    j       1b
    .size   silica_guest_fault_enter, . - silica_guest_fault_enter

// Runtime abort: a2 = reason, a3 = address of the call, reached by CALL0 from rt_console.S
// silica_rt_abort_body in the aborting routine's window, in a task, interrupts on. As rt_vectors.S:
// only the current window stays live and the report runs on the fault stack, so nothing below is
// charged to the aborting context's stack.
    .set    silica_rt_abort_trampoline__stack_bound, 0
    .align  4
    .global silica_rt_abort_trampoline
silica_rt_abort_trampoline:
    rsil    a0, 3                 // no interrupt between the window reset and the new stack pointer
    rsr     a0, windowbase
    movi    a4, 1
    ssl     a0
    sll     a4, a4
    wsr     a4, windowstart
    rsync
    GUEST_FATAL_DEPTH_SLOT a4, a5
    l32i    a5, a4, 0
    addi    a6, a5, 1
    s32i    a6, a4, 0
    GUEST_FAULT_STACK_TOP a1, a8, a9
    movi    a0, 0x40020
    wsr     a0, ps
    rsync
    movi    a0, 0
    bnez    a5, 2f
#ifdef SILICA_GUEST_STRESS
    movi    a10, 12
    call8   silica_guest_stress_nest
#endif
    call8   silica_rt_console_fatal_reset
    mov     a10, a2
    mov     a12, a3
    call8   silica_rt_abort_report
1:  call8   silica_guest_halt
    j       1b
2:  movi    a4, 1
    bne     a5, a4, 1b
    mov     a10, a3               // report the abort site's call as the pc
    call8   silica_rt_fatal_last_resort
    j       1b

#ifdef SILICA_GUEST_STRESS
// silica_guest_stress_nest(n): n calls deep and back, more than the register file holds, so every
// frame above it is spilled by the window-overflow handler, the fault stack's first frame among them.
    .set    silica_guest_stress_nest__stack_bound, 448
    .align  4
silica_guest_stress_nest:
    entry   a1, 32
    beqz    a2, 1f
    addi    a10, a2, -1
    call8   silica_guest_stress_nest
1:  retw
#endif

// The debug exception, in RAM like the vector that jumps here (ESP-IDF xtensa_vectors.S
// _DebugExceptionVector: a0 is in EXCSAVE6). A hit is Silica's stack guard when this core's task is
// a Silica scheduler (THREADPTR is that core's register block), the cause is a data breakpoint, and
// the store came from task code or from a window-overflow handler spilling a frame (EXCM set, PC
// inside the window vectors); then the actor is ended as on bare metal, cause 1006. Anything else
// is ESP-IDF's own debug exception: its panic, the code of _xt_debugexception.
    .section .iram1.silica_guest_debug, "ax"
    .literal_position
    .align  4
    .global xt_debugexception
    .type   xt_debugexception, @function
xt_debugexception:
    rsr     a0, prid
    extui   a0, a0, 13, 1
    bnez    a0, 1f
    movi    a0, silica_guest_debug_slots
    j       2f
1:  movi    a0, silica_guest_debug_slots + 12
2:  s32i    a1, a0, 0
    s32i    a2, a0, 4
    l32i    a2, a0, 8             // this core's register block, 0 before its scheduler starts
    rur     a1, threadptr
    bne     a1, a2, 8f
    rsr     a1, debugcause
    bbci    a1, 2, 8f             // not a data breakpoint
    rsr     a1, eps6
    extui   a2, a1, 0, 4
    bnez    a2, 8f                // interrupts were masked: an interrupt handler or a critical section
    bbci    a1, 4, 3f             // EXCM clear: task code
    rsr     a1, epc6
    movi    a2, _WindowOverflow4
    sub     a1, a1, a2
    movi    a2, 0x180
    bgeu    a1, a2, 8f            // an exception or interrupt entry, not a window handler
3:  movi    a2, 1006
    rsr     a3, epc6
    movi    a4, 0
    movi    a0, silica_guest_fault_common
    jx      a0
8:  l32i    a2, a0, 4
    l32i    a1, a0, 0
    movi    a0, 1                 // PANIC_RSN_DEBUGEXCEPTION (guest.c asserts the value)
    wsr     a0, exccause
    rsr     a0, epc6
    wsr     a0, epc1
    rsr     a0, excsave6
    wsr     a0, excsave1
    call0   _xt_panic
    rfi     6
    .size   xt_debugexception, . - xt_debugexception

    .section .data.silica_guest_fault, "aw"
    .align  4
    .global silica_rt_fatal_depth
silica_rt_fatal_depth:
    .word   0, 0                      // one count per core
    .global silica_rt_fatal_owner
silica_rt_fatal_owner:
    .word   0
    // per core: a1 and a2 saved by xt_debugexception, then that core's register block
    .global silica_guest_debug_slots
silica_guest_debug_slots:
    .word   0, 0, 0
    .word   0, 0, 0

    .section .bss.silica_guest_fault, "aw", @nobits
    .balign 16
    .space  FAULT_STACK_SIZE * 2      // core 1's below, core 0's on top
silica_guest_fault_stack_top:
    .space  64
