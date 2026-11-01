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

// Bring-up app 08: GPIO register read-back. Configures the LED pin (GPIO6) as an output and the
// Left button (GPIO21) as a pulled-up input through rt_board, then prints the registers that
// decide what the pads do: IO_MUX pad config, GPIO matrix output select, GPIO_ENABLE, GPIO_OUT and
// GPIO_IN, with the LED driven high and then low. Written when asm_01_blink ran to completion but
// the LED never lit and asm_03_buttons read every button as 0.

#define LED_PIN     6
#define BTN_PIN     21

    .section .text.main, "ax"
    .literal_position
    .align  4
    .type   show, @function
show:                             // show(name, address): "<name> = 0x<value>\n"
    entry   a1, 32
    mov     a6, a3
    mov     a10, a2
    call8   silica_rt_puts
    memw
    l32i    a10, a6, 0
    call8   silica_rt_print_hex32
    movi    a10, 10
    call8   silica_rt_putc
    retw
    .size   show, . - show

    .align  4
    .type   dump, @function
dump:
    entry   a1, 32
    movi    a10, n_mux6
    movi    a11, 0x60009004 + 4 * LED_PIN
    call8   show
    movi    a10, n_mux21
    movi    a11, 0x60009004 + 4 * BTN_PIN
    call8   show
    movi    a10, n_osel6
    movi    a11, 0x60004554 + 4 * LED_PIN
    call8   show
    movi    a10, n_pin6
    movi    a11, 0x60004074 + 4 * LED_PIN
    call8   show
    movi    a10, n_en
    movi    a11, 0x60004020
    call8   show
    movi    a10, n_out
    movi    a11, 0x60004004
    call8   show
    movi    a10, n_in
    movi    a11, 0x6000403C
    call8   show
    retw
    .size   dump, . - dump

    .align  4
    .global main
    .type   main, @function
main:
    entry   a1, 32
    movi    a10, h_reset
    call8   silica_rt_puts
    call8   dump
    movi    a10, LED_PIN
    call8   silica_rt_gpio_output
    movi    a10, BTN_PIN
    call8   silica_rt_gpio_input_pullup
    movi    a10, LED_PIN
    movi    a12, 1
    call8   silica_rt_gpio_write
    movi    a10, 1000
    call8   silica_rt_delay_us
    movi    a10, h_high
    call8   silica_rt_puts
    call8   dump
    movi    a10, LED_PIN
    movi    a12, 0
    call8   silica_rt_gpio_write
    movi    a10, 1000
    call8   silica_rt_delay_us
    movi    a10, h_low
    call8   silica_rt_puts
    call8   dump
    // Pad input buffer on GPIO6, so GPIO_IN bit 6 shows the level the pad really has.
    movi    a4, 0x60009004 + 4 * LED_PIN
    l32i    a5, a4, 0
    movi    a6, 0x200
    or      a5, a5, a6
    s32i    a5, a4, 0
    memw
    movi    a10, LED_PIN
    movi    a12, 1
    call8   silica_rt_gpio_write
    movi    a10, 1000
    call8   silica_rt_delay_us
    movi    a10, h_ie_high
    call8   silica_rt_puts
    call8   dump
    // Output enable forced from GPIO_ENABLE (FUNCn_OEN_SEL, bit 10).
    movi    a4, 0x60004554 + 4 * LED_PIN
    movi    a5, 0x100 | 0x400
    s32i    a5, a4, 0
    memw
    movi    a10, 1000
    call8   silica_rt_delay_us
    movi    a10, h_oen_high
    call8   silica_rt_puts
    call8   dump
    movi    a10, 3000000          // LED should now be lit (or dark, if active low) for 3 s
    call8   silica_rt_delay_us
    movi    a10, LED_PIN
    movi    a12, 0
    call8   silica_rt_gpio_write
    movi    a10, 1000
    call8   silica_rt_delay_us
    movi    a10, h_oen_low
    call8   silica_rt_puts
    call8   dump
    movi    a2, 0
    movi    a3, 0
    retw
    .size   main, . - main

    .section .rodata.main, "a"
h_reset: .asciz "-- at reset\n"
h_high:  .asciz "-- after config, LED written 1\n"
h_low:   .asciz "-- LED written 0\n"
h_ie_high: .asciz "-- input buffer on, LED written 1\n"
h_oen_high: .asciz "-- OEN_SEL=1, LED 1 (held 3 s)\n"
h_oen_low: .asciz "-- OEN_SEL=1, LED written 0\n"
n_mux6:  .asciz "IO_MUX_GPIO6      "
n_mux21: .asciz "IO_MUX_GPIO21     "
n_osel6: .asciz "FUNC6_OUT_SEL_CFG "
n_pin6:  .asciz "GPIO_PIN6         "
n_en:    .asciz "GPIO_ENABLE       "
n_out:   .asciz "GPIO_OUT          "
n_in:    .asciz "GPIO_IN           "
