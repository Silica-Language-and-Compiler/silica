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

// Bring-up app 09: pad read-back for output pins. For each pin in the table, configures it as an
// output through rt_board, turns on its pad input buffer, drives it 1 then 0, and prints the level
// GPIO_IN/GPIO_IN1 reports each time. "pin 48: 1 0" means the chip really drives the pad; a pad
// that reads the same both times is held by something else (or the runtime drove the wrong one).
// Written after the red LED (GPIO1), the single LED (GPIO6) and the buzzer (GPIO48) stayed silent
// while green (GPIO4) and blue (GPIO5) worked.

    .section .text.main, "ax"
    .literal_position
    .align  4
    .type   probe, @function
probe:                            // probe(pin): prints "pin <n>: <level at 1> <level at 0>\n"
    entry   a1, 32
    mov     a6, a2
    mov     a10, a6
    call8   silica_rt_gpio_output
    movi    a4, 0x60009004        // IO_MUX_GPIO0_REG
    addx4   a4, a6, a4
    l32i    a5, a4, 0
    movi    a7, 0x200             // FUN_IE
    or      a5, a5, a7
    s32i    a5, a4, 0
    memw
    movi    a10, msg_pin
    call8   silica_rt_puts
    mov     a10, a6
    call8   silica_rt_print_u32
    movi    a10, 58
    call8   silica_rt_putc
    movi    a7, 1                 // level to drive: 1 then 0
1:  mov     a10, a6
    mov     a12, a7
    call8   silica_rt_gpio_write
    movi    a10, 1000
    call8   silica_rt_delay_us
    mov     a10, a6
    call8   silica_rt_gpio_read
    mov     a5, a10
    movi    a10, 32
    call8   silica_rt_putc
    mov     a10, a5
    call8   silica_rt_print_u32
    addi    a7, a7, -1
    bgez    a7, 1b
    movi    a10, 10
    call8   silica_rt_putc
    retw
    .size   probe, . - probe

    .align  4
    .global main
    .type   main, @function
main:
    entry   a1, 32
    movi    a2, 0
1:  movi    a3, pins
    addx4   a3, a2, a3
    l32i    a10, a3, 0
    call8   probe
    addi    a2, a2, 1
    movi    a3, N_PINS
    blt     a2, a3, 1b
    movi    a2, 0
    movi    a3, 0
    retw
    .size   main, . - main

    .section .rodata.main, "a"
    .align  4
pins:   .word   1, 2, 4, 5, 6, 7, 48
    .equ    N_PINS, 7
msg_pin: .asciz "pin "
