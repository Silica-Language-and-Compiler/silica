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

// Start-up of the Silica board runtime as a guest of ESP-IDF (transport_ble_plan.md §2.1): what
// stands in for ../../runtime/rt_start.S. ESP-IDF owns the chip, so the reset entry, the vector
// table, the watchdogs, the zeroing of .bss, INTENABLE, PS and the start of the APP cpu are its
// own and absent here. Each of Silica's two schedulers is entered from a FreeRTOS task pinned to
// its core (../idf_app/components/silica_guest/guest.c): the task's THREADPTR becomes that core's
// register block (FreeRTOS saves and restores THREADPTR with the task), its stack becomes a Silica
// stack, and the runtime runs as on bare metal. "Start core 1" creates core 1's task; "stall the
// other core" suspends the other task; the halt at the program's end suspends the task
// (rt_console.S, the SILICA_GUEST sections).
//
// The console protocol is the bare-metal one (\x02SILICA:START\x03 ... \x02SILICA:EXIT:<status>\x03),
// on the same UART.

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

// What the runtime's calls into FreeRTOS (guest.c) need of the stack they are made on, declared for
// ../../tools/main_stack_bound.py, which otherwise walks into FreeRTOS and meets its hooks (calls
// through function values it cannot bound). Measured with that tool on a linked image, the hooks
// counted as nothing and the assertion-failure path left out (it ends in ESP-IDF's panic):
//   main_stack_bound.py --section .iram0.text --section .flash.text --root <name> --ignore-callx
//       --exclude __assert_func --emitted-syms <image>.emitted_syms <image>.elf
// gave 480 (wake), 416 (idle_wait), 480 (halt), 480 (stall_other) with ESP-IDF 6.2; start_core1 is
// wake's call. Measure again when the ESP-IDF version changes.
    .set    silica_guest_wake__stack_bound, 512
    .set    silica_guest_idle_wait__stack_bound, 512
    .set    silica_guest_halt__stack_bound, 512
    .set    silica_guest_stall_other__stack_bound, 512
    .set    silica_guest_start_core1__stack_bound, 512

    .section .text.silica_guest_start, "ax"
    .literal_position

// void silica_guest_core0_entry(void): from core 0's task; does not return.
    .align  4
    .global silica_guest_core0_entry
    .type   silica_guest_core0_entry, @function
silica_guest_core0_entry:
    entry   a1, 32
    movi    a2, silica_rt_core_regs
    wur     a2, threadptr
    movi    a3, silica_guest_debug_slots    // the debug handler's test for "Silica's task runs here"
    s32i    a2, a3, 8
    movi    a0, 0
    movi    a1, _silica_stack_top
    call8   silica_rt_start_windowed
1:  j       1b
    .size   silica_guest_core0_entry, . - silica_guest_core0_entry

// rt_start.S silica_rt_start_windowed, as it is there: aux stack, heap, the actor runtime and core 1,
// main's stack limits, start marker, main, exit marker.
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
    movi    a10, silica_rt_start_marker
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

// "Start core 1": core 1's scheduler task (guest.c).
    .align  4
    .global silica_rt_start_app_cpu
    .type   silica_rt_start_app_cpu, @function
silica_rt_start_app_cpu:
    entry   a1, 32
    call8   silica_guest_start_core1
    retw
    .size   silica_rt_start_app_cpu, . - silica_rt_start_app_cpu

// void silica_guest_core1_entry(void): from core 1's task; does not return. rt_start.S
// silica_rt_start_core1 without the resets of INTENABLE, VECBASE, WINDOWSTART and PS.
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
    movi    a3, silica_guest_debug_slots
    s32i    a2, a3, 12 + 8
    movi    a3, silica_rt_core1_stack_bottom + 64
    s32i    a3, a2, VRG_MLIMIT
    movi    a3, 0
    s32i    a3, a2, VRG_ALIMIT
    movi    a0, 0
    movi    a1, silica_rt_core1_stack_top
    call8   silica_rt_core1_main
1:  j       1b
    .size   silica_guest_core1_entry, . - silica_guest_core1_entry

// rt_actors.S names this entry for core 1; nothing jumps to it here.
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

#ifdef SILICA_GUEST_STRESS
// Stress mode (guest.c): its presence turns guest.c's stress tasks on.
    .section .rodata.silica_guest_stress, "a"
    .align  4
    .global silica_guest_stress
silica_guest_stress:
    .word   1
#endif

    .section .rodata.silica_guest_start, "a"
    .global silica_rt_start_marker
silica_rt_start_marker:
    .byte   0x02
    .ascii  "SILICA:START"
    .byte   0x03, 0
