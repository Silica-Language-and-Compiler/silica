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

// Bring-up app 11: the addressable LED chain -- 24 WS2813B-2121 on GPIO7 (through J4 9-10),
// powered from the 5 V converter, GRB byte order, 24 bits per LED, most significant bit first.
//
// The WS2813B reads each bit from the length of its high pulse (0: 220-380 ns, 1: 580-1000 ns)
// and latches the colours after a low of more than 280 us. The stream is bit-banged through the
// GPIO set/clear registers. Measured on the test unit at the ROM's 20 MHz CPU clock (50 ns/cycle):
// a GPIO store is accepted every ~4.4 cycles, and "set; N nops; clear; memw" gives a high pulse of
// ~N+1 cycles, so a 0 is set + 4 nops (~250 ns) and a 1 is set + 14 nops (~750 ns). The memw after
// every bit drains the write buffer, so each bit starts from the same state; the low phase, where
// the next bit is chosen, is not timing-critical. Interrupts are off in this runtime, so nothing can
// stretch a pulse. The CPU clock is measured at start (the ROM handed off at 20 MHz on 2026-09-12 and
// at 40 MHz on 2026-09-29, when these pulses came out half as wide and no LED decoded them) and a
// second nop table, tuned on the hardware, is used at 40 MHz.
//
// Brightness is kept at 0x18/0xFF per channel so 24 LEDs draw little from the 5 V rail.
// Expected: all red, all green, all blue (1 s each), one white dot running along the chain, off.
// Console: "red", "green", "blue", "chase", "off", status 0.

#define LED_DATA_PIN  7
#define N_LEDS        24
#define LEVEL         0x18

    .section .bss.main, "aw", @nobits
    .align  4
frame:  .space  N_LEDS * 3

    .section .text.main, "ax"
    .literal_position

    .section .data.main, "aw"
    .align  4
g_fast: .word 0                   // 0: ~20 MHz CPU (4 / 14 nops), 1: ~40 MHz (13 / 34 nops)

    .section .text.main, "ax"
    .literal_position

// measure_clock(): CCOUNT cycles per microsecond of the ROM's ets_delay_us, which knows the real CPU
// clock; the ROM has handed off at ~20 MHz (2026-09-12) and at 40 MHz (2026-09-29), and the pulse
// widths below are nop counts, so the frame routine is chosen by what is measured.
    .align  4
    .type   measure_clock, @function
measure_clock:
    entry   a1, 32
    rsr     a2, ccount
    movi    a10, 1000
    call8   silica_rt_delay_us
    rsr     a3, ccount
    sub     a3, a3, a2
    movi    a4, 30000             // 30 MHz: the boundary between the two tables
    movi    a5, g_fast
    movi    a7, 1
    blt     a3, a4, 1f
    s32i    a7, a5, 0
    j       2f
1:  movi    a7, 0
    s32i    a7, a5, 0
2:  memw
    mov     a2, a3
    retw
    .size   measure_clock, . - measure_clock

// send_frame_20(): stream frame[] to the chain at a 20 MHz CPU clock, then hold the line low for
// the latch. A 0 is set + 4 nops (~250 ns), a 1 is set + 14 nops (~750 ns).
    .align  4
    .type   send_frame_20, @function
send_frame_20:
    entry   a1, 32
    movi    a2, frame
    movi    a3, N_LEDS * 3
    movi    a4, 1 << LED_DATA_PIN
    movi    a5, 0x60004000        // GPIO base: +8 = OUT_W1TS, +12 = OUT_W1TC
1:  l8ui    a6, a2, 0
    movi    a7, 8
2:  bbsi    a6, 7, 3f
    s32i    a4, a5, 8
    nop
    nop
    nop
    nop
    s32i    a4, a5, 12
    memw
    j       4f
3:  s32i    a4, a5, 8
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    s32i    a4, a5, 12
    memw
4:  slli    a6, a6, 1
    addi    a7, a7, -1
    bnez    a7, 2b
    addi    a2, a2, 1
    addi    a3, a3, -1
    bnez    a3, 1b
    movi    a10, 500              // latch: > 280 us low
    call8   silica_rt_delay_us
    retw
    .size   send_frame_20, . - send_frame_20

// send_frame_40(): stream frame[] to the chain at a 40 MHz CPU clock, then hold the line low for
// the latch. A 0 is set + 13 nops, a 1 is set + 34 nops (~350 / ~875 ns if the N+1 rule holds at
// 40 MHz). Measured on the first test unit on 2026-09-29: 12/32 and 14/36 give clean frames, 9/29
// (the 20 MHz counts doubled) gives mixed colours, 16/40 reads every bit as a 1 (all white).
    .align  4
    .type   send_frame_40, @function
send_frame_40:
    entry   a1, 32
    movi    a2, frame
    movi    a3, N_LEDS * 3
    movi    a4, 1 << LED_DATA_PIN
    movi    a5, 0x60004000        // GPIO base: +8 = OUT_W1TS, +12 = OUT_W1TC
1:  l8ui    a6, a2, 0
    movi    a7, 8
2:  bbsi    a6, 7, 3f
    s32i    a4, a5, 8
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    s32i    a4, a5, 12
    memw
    j       4f
3:  s32i    a4, a5, 8
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    s32i    a4, a5, 12
    memw
4:  slli    a6, a6, 1
    addi    a7, a7, -1
    bnez    a7, 2b
    addi    a2, a2, 1
    addi    a3, a3, -1
    bnez    a3, 1b
    movi    a10, 500              // latch: > 280 us low
    call8   silica_rt_delay_us
    retw
    .size   send_frame_40, . - send_frame_40

// send_frame(): the frame routine for the measured clock.
    .align  4
    .type   send_frame, @function
send_frame:
    entry   a1, 32
    movi    a3, g_fast
    l32i    a3, a3, 0
    bnez    a3, 1f
    call8   send_frame_20
    retw
1:  call8   send_frame_40
    retw
    .size   send_frame, . - send_frame

// fill(g, r, b): every LED the same colour.
    .align  4
    .type   fill, @function
fill:
    entry   a1, 32
    movi    a5, frame
    movi    a6, N_LEDS
1:  s8i     a2, a5, 0
    s8i     a3, a5, 1
    s8i     a4, a5, 2
    addi    a5, a5, 3
    addi    a6, a6, -1
    bnez    a6, 1b
    retw
    .size   fill, . - fill

// show(g, r, b, name): fill, send, name it, hold one second.
    .align  4
    .type   show, @function
show:
    entry   a1, 32
    mov     a6, a5
    mov     a10, a2
    mov     a11, a3
    mov     a12, a4
    call8   fill
    call8   send_frame
    mov     a10, a6
    call8   silica_rt_puts
    movi    a10, 1000000
    call8   silica_rt_delay_us
    retw
    .size   show, . - show

    .align  4
    .global main
    .type   main, @function
main:
    entry   a1, 32
    call8   measure_clock
    mov     a2, a10
    movi    a10, msg_clock
    call8   silica_rt_puts
    mov     a10, a2
    call8   silica_rt_print_u32
    movi    a10, 10
    call8   silica_rt_putc
    movi    a10, LED_DATA_PIN
    call8   silica_rt_gpio_output
    movi    a10, 1000             // line low well past a reset before the first frame
    call8   silica_rt_delay_us
    movi    a10, 0
    movi    a11, LEVEL
    movi    a12, 0
    movi    a13, n_red
    call8   show
    movi    a10, LEVEL
    movi    a11, 0
    movi    a12, 0
    movi    a13, n_green
    call8   show
    movi    a10, 0
    movi    a11, 0
    movi    a12, LEVEL
    movi    a13, n_blue
    call8   show
    movi    a10, n_chase
    call8   silica_rt_puts
    movi    a2, 0                 // a2 = lit position
1:  movi    a10, 0
    movi    a11, 0
    movi    a12, 0
    call8   fill
    movi    a3, frame
    addx2   a4, a2, a2            // a4 = 3 * position
    add     a3, a3, a4
    movi    a4, LEVEL
    s8i     a4, a3, 0
    s8i     a4, a3, 1
    s8i     a4, a3, 2
    call8   send_frame
    movi    a10, 100000
    call8   silica_rt_delay_us
    addi    a2, a2, 1
    movi    a3, N_LEDS
    blt     a2, a3, 1b
    movi    a10, 0
    movi    a11, 0
    movi    a12, 0
    movi    a13, n_off
    call8   show
    movi    a2, 0
    movi    a3, 0
    retw
    .size   main, . - main

    .section .rodata.main, "a"
n_red:   .asciz "red\n"
n_green: .asciz "green\n"
n_blue:  .asciz "blue\n"
n_chase: .asciz "chase\n"
n_off:   .asciz "off\n"
msg_clock: .asciz "cycles per ms "
