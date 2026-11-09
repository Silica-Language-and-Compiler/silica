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

// Reset entry for the bare-metal STM32L476RG runtime (no HAL, no RTOS).
//
// The image is loaded into SRAM by the debug probe (board/tools: OpenOCD over the Nucleo's ST-LINK),
// which then sets PC = _start and resumes; nothing is written to flash. _start never returns:
//   1. interrupts off, VTOR = our table (rt_vectors.S), sp = main's machine stack top, the FPU on
//      (CPACR CP10/CP11 full access; no lazy FP context stacking, the tick handler uses no FP);
//   2. the clock: HSI16 on and selected as SYSCLK (16 MHz; the chip resets on the 4 MHz MSI); no
//      flash wait states matter, everything runs from SRAM; GPIOA and USART2 clocks on;
//   3. the console (rt_console.S): USART2 115200 8N1 on PA2/PA3, the ST-LINK virtual COM port;
//   4. zero .bss, the heap and main's machine stack (zeroed so the high-water marks can be read at
//      the end: the lowest non-zero word);
//   5. the register block (r9 = silica_rt_core_regs: main's auxiliary stack pointer, limits, chunk
//      headers, floor), the heap, the actor runtime, SysTick (1 ms);
//   6. drain whatever the loader left in the UART, print the start marker, call `main`, print the
//      exit marker with its result (low byte, like a host process exit status), halt.
//
// Memory: SRAM1 (96 KiB at 0x2000_0000) holds the image, the heap and main's machine stack; SRAM2
// (32 KiB at 0x1000_0000, a separate region on this part) holds the fault stack and main's auxiliary
// stack (silica_stm32l476rg.ld). main's two stacks are fixed per image by the linker script
// (_silica_main_stack_size, _silica_main_aux_size; defaults 6 KB and 2 KB, --defsym to override:
// build_image.sh). The emitted prologue compares its would-be sp with VRG_MLIMIT and every auxiliary
// reservation the new SP with VRG_ALIMIT; in main a limit crossed is a fatal fault (rt_actors.S), in
// an actor it is where the stack grows.
//
// Console protocol (read by board/tools/run_on_board.py, the same as the ESP32-S3 port's):
//   \x02SILICA:START\x03            printed before main runs
//   \x02SILICA:EXIT:<status>\x03    printed when the program ends; any diagnostic follows it
// The console's receive side is the program's standard input (spec §15.1.2.5): a line reading
// "exit" makes a main waiting in wait_for_exit return 0 (rt_console.S, rt_actors.S).

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

#define RCC_CR_HSION     0x100
#define RCC_CR_HSIRDY    0x400
#define RCC_CFGR_SW_HSI  0x1
#define RCC_CFGR_SWS_MASK 0xC
#define RCC_CFGR_SWS_HSI 0x4

    .section .text.silica_rt_start, "ax", %progbits
    FUNC _start
    // 1. No interrupts; our vectors; our stack; the FPU.
    cpsid   i
    MOV32   r0, silica_rt_vectors
    MOV32   r1, SCB_VTOR
    str     r0, [r1]
    MOV32   r0, _silica_stack_top
    mov     sp, r0
    MOV32   r1, SCB_CPACR
    ldr     r0, [r1]
    orr     r0, r0, #0x00F00000             // CP10, CP11 full access
    str     r0, [r1]
    dsb     sy
    isb     sy
    MOV32   r1, FPU_FPCCR
    movw    r0, #0                          // ASPEN = LSPEN = 0: no FP state on exception entry
    str     r0, [r1]
    MOV32   r1, SCB_CCR
    ldr     r0, [r1]
    orr     r0, r0, #0x200                  // STKALIGN: 8-byte aligned exception frames
    bic     r0, r0, #0x10                   // DIV_0_TRP off: SDIV/UDIV by zero give 0 (AArch64 semantics)
    str     r0, [r1]
    MOV32   r1, SCB_SHCSR
    ldr     r0, [r1]
    orr     r0, r0, #0x70000                // MemManage, BusFault, UsageFault enabled as separate vectors
    str     r0, [r1]

    // 2. Clock: HSI16 as SYSCLK.
    MOV32   r1, RCC_BASE
    ldr     r0, [r1, #RCC_CR]
    orr     r0, r0, #RCC_CR_HSION
    str     r0, [r1, #RCC_CR]
1:  ldr     r0, [r1, #RCC_CR]
    tst     r0, #RCC_CR_HSIRDY
    beq.w   1b
    ldr     r0, [r1, #RCC_CFGR]
    bic     r0, r0, #0x3
    orr     r0, r0, #RCC_CFGR_SW_HSI
    str     r0, [r1, #RCC_CFGR]
2:  ldr     r0, [r1, #RCC_CFGR]
    and     r0, r0, #RCC_CFGR_SWS_MASK
    cmp     r0, #RCC_CFGR_SWS_HSI
    bne.w   2b
    ldr     r0, [r1, #RCC_AHB2ENR]
    orr     r0, r0, #0x1                    // GPIOAEN
    str     r0, [r1, #RCC_AHB2ENR]
    ldr     r0, [r1, #RCC_APB1ENR1]
    orr     r0, r0, #0x20000                // USART2EN
    str     r0, [r1, #RCC_APB1ENR1]
    dsb     sy

    // 3. The console.
    bl      silica_rt_console_init

    // 4. Zero .bss, the heap and main's machine stack in SRAM1 (nothing lives below sp yet: _start
    //    has pushed nothing, and the zeroing stops at the stack top), then the SRAM2 range the image
    //    uses: the fault stack and main's auxiliary stack (silica_stm32l476rg.ld .sram2).
    MOV32   r0, _silica_bss_start
    MOV32   r1, _silica_stack_top
    bl      silica_rt_zero_words
    MOV32   r0, _silica_sram2_used_start
    MOV32   r1, _silica_sram2_used_end
    bl      silica_rt_zero_words

    // 5. The register block and the runtime.
    MOV32   r9, silica_rt_core_regs
    MOV32   r0, silica_rt_aux_stack_top
    str     r0, [r9, #VRG_VSP]
    str     r0, [r9, #VRG_FLOOR]            // main's first frame: an empty dynamic part
    MOV32   r0, _silica_heap_end            // main's machine-stack limit: the stack's bottom plus the runtime reserve
    MOV32   r1, _silica_rt_depth_reserve
    add     r0, r0, r1
    add     r0, r0, #64
    str     r0, [r9, #VRG_MLIMIT]
    MOV32   r0, silica_rt_aux_stack_bottom
    add     r0, r0, #64                     // and its auxiliary limit
    str     r0, [r9, #VRG_ALIMIT]
    movw    r0, #0xFFFF
    movt    r0, #0xFFFF                     // main's stacks are not chunks: a release never pops one
    str     r0, [r9, #VRG_ATOP]
    MOV32   r0, silica_rt_main_mchunk
    str     r0, [r9, #VRG_MCHUNK]
    MOV32   r0, silica_rt_main_achunk
    str     r0, [r9, #VRG_ACHUNK]
    movw    r0, #0
    str     r0, [r9, #VRG_CCB]
    bl      silica_rt_heap_init
    bl      silica_rt_actors_init           // main's context exists before the first emitted prologue
    // SysTick: 1 ms at 16 MHz, processor clock, interrupt on
    MOV32   r1, SYSTICK_RVR
    movw    r0, #15999
    str     r0, [r1]
    MOV32   r1, SYSTICK_CVR
    movw    r0, #0
    str     r0, [r1]
    MOV32   r1, SYSTICK_CSR
    movw    r0, #7
    str     r0, [r1]
    cpsie   i

    // 6. The program.
    bl      silica_rt_console_rx_drain      // standard input starts empty: nothing the loader left counts
    bl      silica_rt_wall_clock_start      // the ms counter the loader's Unix time stands for (rt_actors.S)
    MOV32   r0, silica_rt_start_marker
    bl      silica_rt_puts
    bl      main                            // int64 result in r0:r1
    mov     r4, r0
    bl      silica_rt_report_drain_at_exit  // reports the reporter has not printed yet (rt_actors.S)
    mov     r0, r4
    bl      silica_rt_exit                  // r0 = low word = status
3:  b.w     3b
    .size   _start, . - _start

// silica_rt_zero_words(r0 = from, r1 = to): zero [from, to), both 4-byte aligned. Clobbers r0, r2.
    FUNC silica_rt_zero_words
    movw    r2, #0
    cmp     r0, r1
    bhs.w   2f
1:  str     r2, [r0], #4
    cmp     r0, r1
    blo.w   1b
2:  bx      lr
    .size   silica_rt_zero_words, . - silica_rt_zero_words

// Machine state the emitted code keeps in memory (shared/arm_vr.silica): the register block, one
// core. X3-X8 at 0..47, D0-D7 at 48..111, the auxiliary stack pointer at VRG_VSP, the running
// context's limits and chunks from VRG_MLIMIT, the frame floor at VRG_FLOOR. r9 points at it for the
// whole program; a context switch saves and loads the SP, floor and chunk words and publishes the
// limits (rt_actors.S).
    .section .bss.silica_rt_regs, "aw", %nobits
    .balign 16
    .global silica_rt_core_regs
silica_rt_core_regs:
    .space  VRG_BLOCK_SIZE

    .section .rodata.silica_rt_start, "a", %progbits
silica_rt_start_marker:
    .byte   0x02
    .ascii  "SILICA:START"
    .byte   0x03, 0
