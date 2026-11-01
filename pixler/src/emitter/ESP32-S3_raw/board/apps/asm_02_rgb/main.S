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

// Bring-up app 02: the RGB LED -- red GPIO2, green GPIO4, blue GPIO5. Red follows the v4.0
// netlist; the board sheet's "Red: 1" is a display-connector pin. Each colour reaches the LED only
// through its J4 jumper (1-2, 3-4, 5-6). Shows red, green, blue, white, off -- one second each --
// and names each colour on the console. The LED is active high (measured: green and blue light
// when driven 1).
// Expected console: "red", "green", "blue", "white", "off", status 0.

#define PIN_R 2
#define PIN_G 4
#define PIN_B 5

    .section .text.main, "ax"
    .literal_position
    .align  4

// set_rgb(r, g, b): drive the three pins, then name the colour and hold for one second.
    .align  4
    .type   set_rgb, @function
set_rgb:
    entry   a1, 32
    mov     a6, a5                // name
    mov     a7, a4
    mov     a5, a3
    movi    a10, PIN_R
    mov     a12, a2
    call8   silica_rt_gpio_write
    movi    a10, PIN_G
    mov     a12, a5
    call8   silica_rt_gpio_write
    movi    a10, PIN_B
    mov     a12, a7
    call8   silica_rt_gpio_write
    mov     a10, a6
    call8   silica_rt_puts
    movi    a10, 1000000
    call8   silica_rt_delay_us
    retw
    .size   set_rgb, . - set_rgb

    .align  4
    .global main
    .type   main, @function
main:
    entry   a1, 32
    movi    a10, PIN_R
    call8   silica_rt_gpio_output
    movi    a10, PIN_G
    call8   silica_rt_gpio_output
    movi    a10, PIN_B
    call8   silica_rt_gpio_output
    movi    a10, 1
    movi    a11, 0
    movi    a12, 0
    movi    a13, name_red
    call8   set_rgb
    movi    a10, 0
    movi    a11, 1
    movi    a12, 0
    movi    a13, name_green
    call8   set_rgb
    movi    a10, 0
    movi    a11, 0
    movi    a12, 1
    movi    a13, name_blue
    call8   set_rgb
    movi    a10, 1
    movi    a11, 1
    movi    a12, 1
    movi    a13, name_white
    call8   set_rgb
    movi    a10, 0
    movi    a11, 0
    movi    a12, 0
    movi    a13, name_off
    call8   set_rgb
    movi    a2, 0
    movi    a3, 0
    retw
    .size   main, . - main

    .section .rodata.main, "a"
name_red:   .asciz "red\n"
name_green: .asciz "green\n"
name_blue:  .asciz "blue\n"
name_white: .asciz "white\n"
name_off:   .asciz "off\n"
