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

// Stage 4 spike: what replaces rt_start.S and rt_vectors.S when Silica's board runtime is a guest of
// ESP-IDF. Throwaway.
//
// Left to ESP-IDF, and so absent here: the reset entry, the vector table, the watchdogs, the zeroing
// of .bss, INTENABLE and PS (interrupts stay on), and starting the APP cpu.
// Kept from rt_start.S, unchanged: silica_rt_start_windowed (the program's start on core 0), the
// per-core register blocks reached through THREADPTR, core 1's boot stack.
// Changed: each core is entered from a FreeRTOS task (guest.c) instead of from the ROM; "start core 1"
// creates that task; "stall the other core" suspends its task; a runtime abort is reported on the
// stack it happened on instead of a fault stack.
// Not provided: Silica's own exception vectors. A CPU exception in Silica code is ESP-IDF's panic, so
// a fault in an actor ends the whole program here, not only that actor.

#define VRG_BLOCK_SIZE 192
#define VRG_VSP        112
#define VRG_MLIMIT     116
#define VRG_ALIMIT     120
#define VRG_ATOP       124
#define VRG_MCHUNK     128
#define VRG_ACHUNK     132
#define VRG_FLOOR      140
#define VRG_CCB        144
#define CORE1_STACK_SIZE 0x1000

    .section .text.silica_guest_start, "ax"
    .literal_position

// void silica_guest_core0_entry(void): from the core 0 task. THREADPTR becomes Silica's (FreeRTOS
// saves and restores it with the task), the stack becomes main's machine stack, and the program runs.
    .align  4
    .global silica_guest_core0_entry
    .type   silica_guest_core0_entry, @function
silica_guest_core0_entry:
    entry   a1, 32
    movi    a2, silica_rt_core_regs
    wur     a2, threadptr
    movi    a0, 0
    movi    a1, _silica_stack_top
    call8   silica_rt_start_windowed
1:  j       1b
    .size   silica_guest_core0_entry, . - silica_guest_core0_entry

// rt_start.S silica_rt_start_windowed, as it is there.
    .align  4
    .global silica_rt_start_windowed
    .type   silica_rt_start_windowed, @function
silica_rt_start_windowed:
    entry   a1, 32
    rur     a2, threadptr
    movi    a3, silica_rt_aux_stack_top
    s32i    a3, a2, VRG_VSP
    movi    a3, _silica_heap_end
    movi    a4, _silica_rt_depth_reserve
    add     a3, a3, a4
    addi    a3, a3, 64
    s32i    a3, a2, VRG_MLIMIT
    movi    a3, silica_rt_aux_stack_bottom + 64
    s32i    a3, a2, VRG_ALIMIT
    movi    a3, -1
    s32i    a3, a2, VRG_ATOP
    movi    a3, silica_rt_main_mchunk
    s32i    a3, a2, VRG_MCHUNK
    movi    a3, silica_rt_main_achunk
    s32i    a3, a2, VRG_ACHUNK
    l32i    a3, a2, VRG_VSP
    s32i    a3, a2, VRG_FLOOR
    movi    a3, 0
    s32i    a3, a2, VRG_CCB
    call8   silica_rt_heap_init
    call8   silica_rt_actors_init
    movi    a2, silica_rt_console_last
    movi    a3, 10
    s32i    a3, a2, 0
    s32i    a3, a2, 4
    memw
    call8   silica_rt_actors_start_cores
    call8   silica_rt_console_rx_drain
    call8   silica_rt_wall_clock_start
    movi    a10, silica_guest_start_marker
    call8   silica_rt_puts
    call8   silica_rt_console_release_if_mine
    movi    a2, silica_rt_console_last
    movi    a3, 10
    s32i    a3, a2, 0
    memw
    call8   main
    mov     a6, a10
    call8   silica_rt_report_drain_at_exit
    mov     a10, a6
    call8   silica_rt_exit
1:  j       1b
    .size   silica_rt_start_windowed, . - silica_rt_start_windowed

// "Start core 1": a second task, pinned to core 1 (guest.c).
    .align  4
    .global silica_rt_start_app_cpu
    .type   silica_rt_start_app_cpu, @function
silica_rt_start_app_cpu:
    entry   a1, 32
    call8   silica_guest_start_core1
    retw
    .size   silica_rt_start_app_cpu, . - silica_rt_start_app_cpu

// void silica_guest_core1_entry(void): from the core 1 task. rt_start.S silica_rt_start_core1 without
// the resets of INTENABLE, VECBASE, WINDOWSTART and PS.
    .align  4
    .global silica_guest_core1_entry
    .type   silica_guest_core1_entry, @function
silica_guest_core1_entry:
    entry   a1, 32
    movi    a2, 0
    wsr     a2, dbreakc0
    wsr     a2, dbreakc1
    movi    a2, silica_rt_core_regs + VRG_BLOCK_SIZE
    wur     a2, threadptr
    isync
    movi    a3, silica_rt_core1_stack_bottom + 64
    s32i    a3, a2, VRG_MLIMIT
    movi    a3, 0
    s32i    a3, a2, VRG_ALIMIT
    movi    a0, 0
    movi    a1, silica_rt_core1_stack_top
    call8   silica_rt_core1_main
1:  j       1b
    .size   silica_guest_core1_entry, . - silica_guest_core1_entry

// rt_actors.S names this entry for core 1; the ROM never jumps to it here.
    .align  4
    .global silica_rt_start_core1
    .type   silica_rt_start_core1, @function
silica_rt_start_core1:
    j       silica_guest_core1_entry
    .size   silica_rt_start_core1, . - silica_rt_start_core1

// "Stall the other core": suspend its scheduler task (guest.c).
    .align  4
    .global silica_rt_stall_other_cpu
    .type   silica_rt_stall_other_cpu, @function
silica_rt_stall_other_cpu:
    entry   a1, 32
    call8   silica_guest_stall_other
    retw
    .size   silica_rt_stall_other_cpu, . - silica_rt_stall_other_cpu

// Runtime abort: a2 = reason, a3 = address of the call, reached by CALL0 (rt_console.S
// silica_rt_abort_body). rt_vectors.S resets the windows and moves to a fault stack first; here the
// report is written on the stack the abort happened on.
    .align  4
    .global silica_rt_abort_trampoline
silica_rt_abort_trampoline:
    call8   silica_rt_console_fatal_reset
    mov     a10, a2
    mov     a12, a3
    call8   silica_rt_abort_report
1:  j       1b

    .section .data.silica_guest_start, "aw"
    .align  4
    .global silica_rt_fatal_depth
silica_rt_fatal_depth:
    .word   0, 0
    .global silica_rt_fatal_owner
silica_rt_fatal_owner:
    .word   0

    .section .bss.silica_guest_regs, "aw", @nobits
    .balign 16
    .global silica_rt_core_regs
silica_rt_core_regs:
    .space  VRG_BLOCK_SIZE * 2
    .balign 16
silica_rt_core1_stack_bottom:
    .space  CORE1_STACK_SIZE
silica_rt_core1_stack_top:
    .space  64

    .section .rodata.silica_guest_start, "a"
silica_guest_start_marker:
    .byte   0x02
    .ascii  "SILICA:START"
    .byte   0x03, 0
