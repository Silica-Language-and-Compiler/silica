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

// Reset entry for the bare-metal ESP32-S3 runtime (no ESP-IDF, no FreeRTOS).
//
// The image is flashed at offset 0x0 in place of the second-stage bootloader, so the ROM loads
// its segments into internal SRAM and calls _start as an ordinary windowed function on the PRO cpu
// (core 0). _start never returns to the ROM:
//   1. mask interrupts, move VECBASE to rt_vectors, drop every older register window, and point
//      THREADPTR at core 0's register block (silica_rt_core_regs, below);
//   2. switch to our own stack (the ROM's is a few KB and not ours to keep);
//   3. disable the RTC and timer-group watchdogs the ROM leaves armed, and set the super
//      watchdog to auto-feed (as the IDF bootloader does);
//   4. zero .bss, the heap and main's machine stack (zeroed so its high-water mark can be read at
//      the end: the lowest non-zero word);
//   5. arm the stack guards: data watchpoints on the lowest 64 bytes of the machine stack and of the
//      auxiliary stack, so an overflow raises a debug exception (reported as cause 1006) instead of
//      silently corrupting whatever lies below;
//   6. initialise the actor runtime and start core 1, publish main's stack limits, then call the
//      program's `main` and print the exit marker with its result (low byte, like a host process
//      exit status), followed by the two stacks' high-water marks as a diagnostic (rt_console.S).
//
// Stack budget: the machine stack holds the windowed frames; the auxiliary stack holds the emitter's
// AArch64-style pushes and slabs. Both are sized per image by the linker script (silica_esp32s3.ld:
// _silica_main_stack_size, _silica_main_aux_size) from the static bound board/tools/main_stack_bound.py
// computes over the linked image (build_image.sh links twice), with documented defaults for a `main`
// the walk cannot bound (actor_memory_budget_plan.md §4.1, item D). The emitted prologue compares a1
// with the limit published in this core's register block (VRG_MLIMIT), and every SP reservation the
// new SP with VRG_ALIMIT (rt_actors.S), so a frame larger than the 64-byte guard band cannot pass
// the band unseen; in main a limit crossed is a fatal fault, in an actor it is where the stack grows.
//
// The APP cpu (core 1) is held in reset by the ROM. Start-up starts it once the actor runtime is
// initialised (silica_rt_start_windowed -> rt_actors.S silica_rt_actors_start_cores ->
// silica_rt_start_app_cpu, below): the ESP-IDF sequence for the chip -- clear the RTC software stall,
// enable the core's clock, pulse its reset, then hand the ROM its boot address with the ROM function
// ets_set_appcpu_boot_addr. Core 1 lands in silica_rt_start_core1, which does steps 1 and 2 for that
// core (its own THREADPTR, block 1; a small boot stack), leaves the watchdogs, .bss and the guards to
// core 0, and enters its scheduler (silica_rt_core1_main).
//
// Console protocol (read by board/tools/run_on_board.py):
//   \x02SILICA:START\x03            printed before main runs
//   \x02SILICA:EXIT:<status>\x03    printed when the program ends; any diagnostic follows it
// Program output is exactly the bytes between the two markers, so the host runner can rebuild the
// same `<output><status>\n` text the trial harness writes to a .sout file. The console's receive
// side is the program's standard input (spec §15.1.2.5): a line reading "exit" makes a main waiting
// in wait_for_exit return 0 (rt_console.S, rt_actors.S); the program ends when main returns, with
// main's result as the status (silica_rt_exit, below). Whatever the loader left
// in the RX FIFO is discarded before main runs.

#define RTC_CNTL_WDTCONFIG0_REG   0x60008098
#define RTC_CNTL_WDTWPROTECT_REG  0x600080B0
#define RTC_CNTL_SWD_CONF_REG     0x600080B4
#define RTC_CNTL_SWD_WPROTECT_REG 0x600080B8
#define TIMG0_WDTCONFIG0_REG      0x6001F048
#define TIMG0_WDTWPROTECT_REG     0x6001F064
#define TIMG1_WDTCONFIG0_REG      0x60020048
#define TIMG1_WDTWPROTECT_REG     0x60020064
#define WDT_WKEY_VALUE            0x50D83AA1
#define SWD_WKEY_VALUE            0x8F1D312A
#define SWD_AUTO_FEED_EN          0x80000000

// The APP cpu (esp-idf components/soc/esp32s3/register/soc/{system_reg,rtc_cntl_reg}.h and
// components/hal/esp32s3/include/hal/cpu_utility_ll.h: cpu_utility_ll_unstall_cpu,
// cpu_utility_ll_enable_clock_and_reset_app_cpu; the ROM entry from esp_rom/esp32s3/ld/esp32s3.rom.ld).
#define SYSTEM_CORE_1_CONTROL_0_REG 0x600C0000
#define SYSTEM_CORE_1_RUNSTALL      0x1
#define SYSTEM_CORE_1_CLKGATE_EN    0x2
#define SYSTEM_CORE_1_RESETING      0x4
#define RTC_CNTL_OPTIONS0_REG       0x60008000
#define RTC_CNTL_SW_STALL_APPCPU_C0 0x00000003      // bits 1:0
#define RTC_CNTL_SW_CPU_STALL_REG   0x600080BC
#define RTC_CNTL_SW_STALL_APPCPU_C1 0x03F00000      // bits 25:20
#define RTC_CNTL_SW_STALL_PROCPU_C0 0x0000000C      // bits 3:2
#define RTC_CNTL_SW_STALL_PROCPU_C0_ON 0x00000008   // 2 << 2
#define RTC_CNTL_SW_STALL_PROCPU_C1 0xFC000000      // bits 31:26
#define RTC_CNTL_SW_STALL_PROCPU_C1_ON 0x84000000   // 0x21 << 26
#define ETS_SET_APPCPU_BOOT_ADDR    0x40000720      // ROM: ets_set_appcpu_boot_addr(uint32_t)

// The per-core register block the emitted code keeps its virtual registers in (design doc §2, §8.2):
// X3-X8 at 0..47, D0-D7 at 48..111, the auxiliary stack pointer at 112, the running context's stack
// limits and chunks from 116 (rt_actors.S VRG_*). THREADPTR of each core points at its block. The
// emitter (shared/xt_vr.silica vr_vsp_off and the limit checks) and rt_actors.S / rt_heap.S use the
// same offsets.
#define VRG_BLOCK_SIZE 192
#define VRG_VSP        112
#define VRG_MLIMIT     116      // rt_actors.S: the same offsets
#define VRG_ALIMIT     120
#define VRG_ATOP       124
#define VRG_MCHUNK     128
#define VRG_ACHUNK     132

    .section .text.silica_rt_start, "ax"
    .literal_position
    .align  4
    .global _start
    .type   _start, @function
_start:
    entry   a1, 32

    // 1. No interrupts; our vectors; this window is the only live one.
    movi    a2, 0
    wsr     a2, intenable
    movi    a2, _silica_vecbase
    wsr     a2, vecbase
    rsr     a2, windowbase
    movi    a3, 1
    ssl     a2
    sll     a3, a3
    wsr     a3, windowstart
    rsync
    movi    a2, 0x40020            // PS: WOE=1, UM=1, INTLEVEL=0, EXCM=0
    wsr     a2, ps
    rsync
    movi    a2, silica_rt_core_regs // core 0's register block
    wur     a2, threadptr

    // 2. Our stack. a0 = 0 terminates backtraces; a1 must be 16-byte aligned.
    movi    a0, 0
    movi    a1, _silica_stack_top

    // 3. Watchdogs.
    movi    a4, WDT_WKEY_VALUE
    movi    a5, 0
    movi    a2, RTC_CNTL_WDTWPROTECT_REG
    s32i    a4, a2, 0
    movi    a3, RTC_CNTL_WDTCONFIG0_REG
    s32i    a5, a3, 0
    s32i    a5, a2, 0
    movi    a2, TIMG0_WDTWPROTECT_REG
    s32i    a4, a2, 0
    movi    a3, TIMG0_WDTCONFIG0_REG
    s32i    a5, a3, 0
    s32i    a5, a2, 0
    movi    a2, TIMG1_WDTWPROTECT_REG
    s32i    a4, a2, 0
    movi    a3, TIMG1_WDTCONFIG0_REG
    s32i    a5, a3, 0
    s32i    a5, a2, 0
    movi    a2, RTC_CNTL_SWD_WPROTECT_REG
    movi    a4, SWD_WKEY_VALUE
    s32i    a4, a2, 0
    movi    a3, RTC_CNTL_SWD_CONF_REG
    l32i    a4, a3, 0
    movi    a6, SWD_AUTO_FEED_EN
    or      a4, a4, a6
    s32i    a4, a3, 0
    s32i    a5, a2, 0
    memw

    // 4. Zero .bss through the fault and auxiliary stacks (up to the heap), the heap (allocations
    //    are returned zeroed) and main's machine stack: nothing lives below a1 yet, and _start's own
    //    frame is above _silica_stack_top (the ROM's area, never spilled to: _start never returns).
    movi    a2, _silica_bss_start
    movi    a3, _silica_heap_start
    call0   silica_rt_zero_words_c0
    movi    a2, _silica_heap_start
    movi    a3, _silica_heap_end
    call0   silica_rt_zero_words_c0
    movi    a2, _silica_heap_end
    movi    a3, _silica_stack_top
    call0   silica_rt_zero_words_c0

    // 5. Stack guards (Xtensa data breakpoints: DBREAKC bit 31 = break on store, mask 0 = 64-byte
    //    range; both addresses are 64-byte aligned). Armed after the zeroing above, which stores there.
    movi    a2, _silica_heap_end          // machine stack bottom
    wsr     a2, dbreaka0
    movi    a3, 0x80000000
    wsr     a3, dbreakc0
    movi    a2, silica_rt_aux_stack_bottom
    wsr     a2, dbreaka1
    wsr     a3, dbreakc1
    isync

    // 6. The program.
    call8   silica_rt_start_windowed
1:  j       1b

// call0 leaf: zero [a2, a3), both 4-byte aligned. Clobbers a2, a4.
    .align  4
silica_rt_zero_words_c0:
    movi    a4, 0
    bgeu    a2, a3, 2f
1:  s32i    a4, a2, 0
    addi    a2, a2, 4
    bltu    a2, a3, 1b
2:  ret

// Runs on our stack in a fresh windowed frame: aux stack, heap init, the actor runtime and core 1,
// main's stack limits, start marker, main, exit marker.
    .align  4
    .global silica_rt_start_windowed
    .type   silica_rt_start_windowed, @function
silica_rt_start_windowed:
    entry   a1, 32
    rur     a2, threadptr
    movi    a3, silica_rt_aux_stack_top
    s32i    a3, a2, VRG_VSP
    movi    a3, _silica_heap_end          // main's machine-stack limit: guard top + runtime reserve
    movi    a4, _silica_rt_depth_reserve
    add     a3, a3, a4
    addi    a3, a3, 64
    s32i    a3, a2, VRG_MLIMIT
    movi    a3, silica_rt_aux_stack_bottom + 64                    // and its auxiliary limit
    s32i    a3, a2, VRG_ALIMIT
    movi    a3, -1                        // main's stacks are not chunks: a release never pops one
    s32i    a3, a2, VRG_ATOP
    movi    a3, silica_rt_main_mchunk     // the headers that describe them (rt_actors.S)
    s32i    a3, a2, VRG_MCHUNK
    movi    a3, silica_rt_main_achunk
    s32i    a3, a2, VRG_ACHUNK
    call8   silica_rt_heap_init
    call8   silica_rt_actors_init        // main's context exists before the first emitted prologue
    // Both cores start at the beginning of a line (rt_console.S, the line hold): a core that has
    // written nothing yet must not count as mid-line, or its first release with no output (a report
    // composed into the buffer and cast to a FailureReporter on the other core) would keep the
    // console lock, and the other core could never print.
    movi    a2, silica_rt_console_last
    movi    a3, 10
    s32i    a3, a2, 0
    s32i    a3, a2, 4
    memw
    call8   silica_rt_actors_start_cores
    call8   silica_rt_console_rx_drain   // standard input starts empty: nothing the loader left counts
    movi    a10, silica_rt_start_marker
    call8   silica_rt_puts
    call8   silica_rt_console_release_if_mine   // the marker has no newline: drop the line hold
    movi    a2, silica_rt_console_last  // and the marker is framing, not program output: main
    movi    a3, 10                      // starts at the beginning of a line too
    s32i    a3, a2, 0
    memw
    call8   main                   // int64 result in a10:a11
    mov     a6, a10
    call8   silica_rt_report_drain_at_exit  // reports the reporter has not printed yet (rt_actors.S)
    mov     a10, a6
    call8   silica_rt_exit         // a10 = low word = status
1:  j       1b
    .size   silica_rt_start_windowed, . - silica_rt_start_windowed

// ---------------------------------------------------------------------------------------------
// The APP cpu (core 1)

// silica_rt_start_app_cpu(): release core 1 from reset and give the ROM its entry (esp-idf
// start_other_core for the ESP32-S3, in the same order). Called once, from core 0, by
// silica_rt_actors_init after the core blocks and core 1's scheduler context exist.
    .align  4
    .global silica_rt_start_app_cpu
    .type   silica_rt_start_app_cpu, @function
silica_rt_start_app_cpu:
    entry   a1, 32
    // no software stall on the APP cpu (RTC_CNTL "c0" and "c1" fields)
    movi    a2, RTC_CNTL_OPTIONS0_REG
    l32i    a3, a2, 0
    movi    a4, ~RTC_CNTL_SW_STALL_APPCPU_C0
    and     a3, a3, a4
    s32i    a3, a2, 0
    movi    a2, RTC_CNTL_SW_CPU_STALL_REG
    l32i    a3, a2, 0
    movi    a4, ~RTC_CNTL_SW_STALL_APPCPU_C1
    and     a3, a3, a4
    s32i    a3, a2, 0
    // clock on, run stall off, reset pulsed
    movi    a2, SYSTEM_CORE_1_CONTROL_0_REG
    l32i    a3, a2, 0
    movi    a4, SYSTEM_CORE_1_CLKGATE_EN
    or      a3, a3, a4
    s32i    a3, a2, 0
    movi    a4, ~SYSTEM_CORE_1_RUNSTALL
    and     a3, a3, a4
    s32i    a3, a2, 0
    movi    a4, SYSTEM_CORE_1_RESETING
    or      a3, a3, a4
    s32i    a3, a2, 0
    movi    a4, ~SYSTEM_CORE_1_RESETING
    and     a3, a3, a4
    s32i    a3, a2, 0
    memw
    // the ROM's APP cpu loop jumps to this address once it is set
    movi    a10, silica_rt_start_core1
    movi    a8, ETS_SET_APPCPU_BOOT_ADDR
    callx8  a8
    retw
    .size   silica_rt_start_app_cpu, . - silica_rt_start_app_cpu

// silica_rt_stall_app_cpu(): freeze core 1 where it stands (RunStall). The program's end
// (rt_console.S silica_rt_halt) and a process-fatal report on core 0 (rt_vectors.S) use it so nothing
// prints after the exit marker; the chip reset before the next load clears it. Harmless when core 1
// was never started.
    .align  4
    .global silica_rt_stall_app_cpu
    .type   silica_rt_stall_app_cpu, @function
silica_rt_stall_app_cpu:
    entry   a1, 32
    movi    a2, SYSTEM_CORE_1_CONTROL_0_REG
    l32i    a3, a2, 0
    movi    a4, SYSTEM_CORE_1_RUNSTALL
    or      a3, a3, a4
    s32i    a3, a2, 0
    memw
    retw
    .size   silica_rt_stall_app_cpu, . - silica_rt_stall_app_cpu

// silica_rt_stall_pro_cpu(): freeze core 0 where it stands, from core 1. Core 0 has no RunStall bit
// of its own; the RTC software stall does it (ESP-IDF components/hal/esp32s3/include/hal/
// cpu_utility_ll.h cpu_utility_ll_stall_cpu: "c0" field = 2, then "c1" field = 0x21). A process-fatal
// fault or abort on core 1 ends the whole program (spec §15.4.5.5), so core 0 must not run on; the
// chip reset before the next load clears it.
    .align  4
    .global silica_rt_stall_pro_cpu
    .type   silica_rt_stall_pro_cpu, @function
silica_rt_stall_pro_cpu:
    entry   a1, 32
    movi    a2, RTC_CNTL_OPTIONS0_REG
    l32i    a3, a2, 0
    movi    a4, ~RTC_CNTL_SW_STALL_PROCPU_C0
    and     a3, a3, a4
    movi    a4, RTC_CNTL_SW_STALL_PROCPU_C0_ON
    or      a3, a3, a4
    s32i    a3, a2, 0
    memw
    movi    a2, RTC_CNTL_SW_CPU_STALL_REG
    l32i    a3, a2, 0
    movi    a4, ~RTC_CNTL_SW_STALL_PROCPU_C1
    and     a3, a3, a4
    movi    a4, RTC_CNTL_SW_STALL_PROCPU_C1_ON
    or      a3, a3, a4
    s32i    a3, a2, 0
    memw
    retw
    .size   silica_rt_stall_pro_cpu, . - silica_rt_stall_pro_cpu

// silica_rt_stall_other_cpu(): freeze the core this one is not (core 0 stalls core 1, core 1 core 0).
    .align  4
    .global silica_rt_stall_other_cpu
    .type   silica_rt_stall_other_cpu, @function
silica_rt_stall_other_cpu:
    entry   a1, 32
    rsr     a2, prid
    extui   a2, a2, 13, 1
    bnez    a2, 1f
    call8   silica_rt_stall_app_cpu
    retw
1:  call8   silica_rt_stall_pro_cpu
    retw
    .size   silica_rt_stall_other_cpu, . - silica_rt_stall_other_cpu

// Core 1's entry, reached from the ROM. Nothing is assumed about the ROM's window or PS state: the
// same reset as _start step 1, THREADPTR = block 1, a boot stack of its own, the stack-guard
// breakpoints of this core disarmed (the scheduler runs with them off; a switch arms them), then
// silica_rt_core1_main (rt_actors.S) switches into this core's scheduler and never returns.
    .align  4
    .global silica_rt_start_core1
    .type   silica_rt_start_core1, @function
silica_rt_start_core1:
    movi    a2, 0
    wsr     a2, intenable
    movi    a2, _silica_vecbase
    wsr     a2, vecbase
    rsr     a2, windowbase
    movi    a3, 1
    ssl     a2
    sll     a3, a3
    wsr     a3, windowstart
    rsync
    movi    a2, 0x40020            // PS: WOE=1, UM=1, INTLEVEL=0, EXCM=0
    wsr     a2, ps
    rsync
    movi    a2, 0
    wsr     a2, dbreakc0
    wsr     a2, dbreakc1
    movi    a2, silica_rt_core_regs + VRG_BLOCK_SIZE
    wur     a2, threadptr
    isync
    movi    a3, silica_rt_core1_stack_bottom + 64   // limits for the boot stack (no emitted code
    s32i    a3, a2, VRG_MLIMIT                      // runs on it; a switch publishes the actor's)
    movi    a3, 0
    s32i    a3, a2, VRG_ALIMIT
    movi    a0, 0
    movi    a1, silica_rt_core1_stack_top
    call8   silica_rt_core1_main
1:  j       1b
    .size   silica_rt_start_core1, . - silica_rt_start_core1

// Machine state the emitted code keeps in memory (design_documents/ports/esp32s3_xtensa_port.md §2):
//   silica_rt_core_regs  one register block per core (VRG_BLOCK_SIZE bytes each): the emitter's
//                  virtual registers X3-X8 (0..47) and D0-D7 (48..111), caller-saved, so one block
//                  per core shared by every frame on that core is exact; at VRG_VSP the auxiliary
//                  data stack pointer, the emitter's SP, which AArch64-style pushes and stack slabs
//                  move (the machine stack pointer a1 cannot move inside a windowed frame); at
//                  VRG_MLIMIT / VRG_ALIMIT the two stack limits of the running context, at VRG_ATOP
//                  the auxiliary chunk's top, at VRG_MCHUNK / VRG_ACHUNK its current chunks and at
//                  VRG_ARG the size of a reservation that grows (rt_actors.S). A core reaches its
//                  block through THREADPTR; a context switch saves and loads the SP word and the
//                  chunks and publishes the limits.
//   main's auxiliary stack (silica_rt_aux_stack_bottom .. silica_rt_aux_stack_top, the lowest 64
//                  bytes the guard watched by breakpoint 1) is laid out by the linker script, sized
//                  per image (_silica_main_aux_size).
#define CORE1_STACK_SIZE 0x800

    .section .bss.silica_rt_regs, "aw", @nobits
    .balign 16
    .global silica_rt_core_regs
silica_rt_core_regs:
    .space  VRG_BLOCK_SIZE * 2

    .section .bss.silica_rt_core1_stack, "aw", @nobits
    .balign 16
silica_rt_core1_stack_bottom:              // core 1's boot stack: silica_rt_core1_main and the first switch
    .space  CORE1_STACK_SIZE
silica_rt_core1_stack_top:

    .section .rodata.silica_rt_start, "a"
silica_rt_start_marker:
    .byte   0x02
    .ascii  "SILICA:START"
    .byte   0x03, 0
