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

// Bring-up app 10: pin hunt. Drives every pin listed in pins.inc (next to this file, or the
// directory given to the assembler with -I) with the same 440 Hz square wave for 4 seconds, so a
// buzzer on any of them sounds and an LED on any of them glows. Used to find the red LED, the
// single LED and the buzzer after the sheet's GPIO1 / GPIO6 / GPIO48 showed nothing on the test
// unit, by bisecting groups of candidate pins. pins.inc defines `hunt_pins` (.word list) and N_PINS.
// Never list buttons, flash/PSRAM (26-32) or the console UART (43, 44).

#define HALF_PERIOD_US  1136      // 440 Hz
#define HALF_PERIODS    3520      // 4 s

    .section .text.main, "ax"
    .literal_position
    .align  4
    .global main
    .type   main, @function
main:
    entry   a1, 32
    movi    a4, 0                 // mask for pins 0..31
    movi    a5, 0                 // mask for pins 32..63
    movi    a2, 0
1:  movi    a3, hunt_pins
    addx4   a3, a2, a3
    l32i    a6, a3, 0
    mov     a10, a6
    call8   silica_rt_gpio_output
    movi    a7, 1
    extui   a8, a6, 0, 5
    ssl     a8
    sll     a7, a7
    bbsi    a6, 5, 2f
    or      a4, a4, a7
    j       3f
2:  or      a5, a5, a7
3:  addi    a2, a2, 1
    movi    a3, N_PINS
    blt     a2, a3, 1b
    movi    a10, msg_on
    call8   silica_rt_puts
    movi    a7, HALF_PERIODS
    movi    a6, 0                 // phase
4:  movi    a3, 0x60004008        // GPIO_OUT_W1TS
    movi    a2, 0x60004014        // GPIO_OUT1_W1TS
    beqz    a6, 5f
    movi    a3, 0x6000400C        // GPIO_OUT_W1TC
    movi    a2, 0x60004018        // GPIO_OUT1_W1TC
5:  s32i    a4, a3, 0
    s32i    a5, a2, 0
    memw
    movi    a3, 1
    xor     a6, a6, a3
    movi    a10, HALF_PERIOD_US
    call8   silica_rt_delay_us
    addi    a7, a7, -1
    bnez    a7, 4b
    movi    a3, 0x6000400C        // everything low at the end
    s32i    a4, a3, 0
    movi    a3, 0x60004018
    s32i    a5, a3, 0
    memw
    movi    a10, msg_off
    call8   silica_rt_puts
    movi    a2, 0
    movi    a3, 0
    retw
    .size   main, . - main

    .section .rodata.main, "a"
    .align  4
#include "pins.inc"
msg_on:  .asciz "square wave on\n"
msg_off: .asciz "done\n"
