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

// Bring-up app 04: timing. Square wave on the buzzer (GPIO48, through J4 27-28 and a DTC114E): half
// a second at 440 Hz, half a second at 880 Hz, then one second at 2730 Hz -- the MLT-5020's rated
// resonant frequency, where it is loudest. The buzzer is fed from +3.3 V through the RV1 trimmer (a
// volume control), so it is silent with the trimmer at one end. The pitch is an audible check that
// ets_delay_us agrees with the real CPU clock; the app also prints the CCOUNT cycles each tone took:
// cycles / seconds = CPU Hz (measured ~20 MHz after the ROM hand-off).
// Expected console: "440 Hz <cycles>", "880 Hz <cycles>", "2730 Hz <cycles>", status 0.

#define BUZZER_PIN 48

    .section .text.main, "ax"
    .literal_position
    .align  4

// tone(half_period_us, periods) -> elapsed CCOUNT cycles
    .align  4
    .type   tone, @function
tone:
    entry   a1, 32
    rsr     a6, ccount
    mov     a4, a2
    mov     a5, a3
1:  movi    a10, BUZZER_PIN
    movi    a12, 1
    call8   silica_rt_gpio_write
    mov     a10, a4
    call8   silica_rt_delay_us
    movi    a10, BUZZER_PIN
    movi    a12, 0
    call8   silica_rt_gpio_write
    mov     a10, a4
    call8   silica_rt_delay_us
    addi    a5, a5, -1
    bnez    a5, 1b
    rsr     a2, ccount
    sub     a2, a2, a6
    retw
    .size   tone, . - tone

    .align  4
    .global main
    .type   main, @function
main:
    entry   a1, 32
    movi    a10, BUZZER_PIN
    call8   silica_rt_gpio_output
    movi    a10, 1136             // 1e6 / 440 / 2
    movi    a11, 220              // 0.5 s
    call8   tone
    mov     a2, a10
    movi    a10, msg_440
    call8   silica_rt_puts
    mov     a10, a2
    call8   silica_rt_print_u32
    movi    a10, 10
    call8   silica_rt_putc
    movi    a10, 568
    movi    a11, 440
    call8   tone
    mov     a2, a10
    movi    a10, msg_880
    call8   silica_rt_puts
    mov     a10, a2
    call8   silica_rt_print_u32
    movi    a10, 10
    call8   silica_rt_putc
    movi    a10, 183              // 1e6 / 2730 / 2
    movi    a11, 2730             // 1 s
    call8   tone
    mov     a2, a10
    movi    a10, msg_2730
    call8   silica_rt_puts
    mov     a10, a2
    call8   silica_rt_print_u32
    movi    a10, 10
    call8   silica_rt_putc
    movi    a2, 0
    movi    a3, 0
    retw
    .size   main, . - main

    .section .rodata.main, "a"
msg_440: .asciz "440 Hz "
msg_880: .asciz "880 Hz "
msg_2730: .asciz "2730 Hz "
