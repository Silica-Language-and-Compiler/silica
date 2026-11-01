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

// Bring-up app 01: GPIO output. Blinks the board LED (GPIO6) ten times, 250 ms on / 250 ms off,
// printing each step. Checks IO_MUX + GPIO matrix setup, GPIO_OUT writes and the ROM delay.
// Expected console: "blink 1" .. "blink 10", then "done", status 0. The LED visibly blinks.

#define LED_PIN 6

    .section .text.main, "ax"
    .literal_position
    .align  4
    .global main
    .type   main, @function
main:
    entry   a1, 32
    movi    a10, LED_PIN
    call8   silica_rt_gpio_output
    movi    a2, 1                 // a2 = iteration (preserved across CALL8)
1:  movi    a10, msg_blink
    call8   silica_rt_puts
    mov     a10, a2
    call8   silica_rt_print_u32
    movi    a10, 10
    call8   silica_rt_putc
    movi    a10, LED_PIN
    movi    a12, 1
    call8   silica_rt_gpio_write
    movi    a10, 250000
    call8   silica_rt_delay_us
    movi    a10, LED_PIN
    movi    a12, 0
    call8   silica_rt_gpio_write
    movi    a10, 250000
    call8   silica_rt_delay_us
    addi    a2, a2, 1
    movi    a3, 11
    blt     a2, a3, 1b
    movi    a10, msg_done
    call8   silica_rt_puts
    movi    a2, 0
    movi    a3, 0
    retw
    .size   main, . - main

    .section .rodata.main, "a"
msg_blink: .asciz "blink "
msg_done:  .asciz "done\n"
