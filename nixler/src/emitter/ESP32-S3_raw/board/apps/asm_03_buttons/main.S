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

// Bring-up app 03: GPIO input. Enables the pad pull-up on all seven buttons (Left 21, Right 10,
// Down 47, Up 11, Point 0, A 34, B 33), prints each button's starting level, then for 30 seconds
// prints "<button> <level>" every time a level changes and lights the LED (GPIO6) while any button
// differs from where it started. The sheet does not say whether a press reads 0 or 1; this app
// reports raw levels so the first run answers that.
// Expected console: "Left 1" .. "B 1" (idle levels), one line per press/release, "done", status 0.

#define LED_PIN     6
#define N_BUTTONS   7
#define POLL_US     10000
#define POLLS       3000        // 30 s

    .section .text.main, "ax"
    .literal_position
    .align  4

// read_mask() -> bit i = level of button i
    .align  4
    .type   read_mask, @function
read_mask:
    entry   a1, 32
    movi    a2, 0
    movi    a3, 0
1:  movi    a4, button_pins
    addx4   a4, a3, a4
    l32i    a10, a4, 0
    call8   silica_rt_gpio_read
    ssl     a3
    sll     a10, a10
    or      a2, a2, a10
    addi    a3, a3, 1
    movi    a4, N_BUTTONS
    blt     a3, a4, 1b
    retw
    .size   read_mask, . - read_mask

// print_button(i, level)
    .align  4
    .type   print_button, @function
print_button:
    entry   a1, 32
    movi    a4, button_names
    addx4   a4, a2, a4
    l32i    a10, a4, 0
    call8   silica_rt_puts
    movi    a10, 32
    call8   silica_rt_putc
    mov     a10, a3
    call8   silica_rt_print_u32
    movi    a10, 10
    call8   silica_rt_putc
    retw
    .size   print_button, . - print_button

    .align  4
    .global main
    .type   main, @function
main:
    entry   a1, 32
    movi    a4, 0
1:  movi    a6, button_pins
    addx4   a6, a4, a6
    l32i    a10, a6, 0
    call8   silica_rt_gpio_input_pullup
    addi    a4, a4, 1
    movi    a6, N_BUTTONS
    blt     a4, a6, 1b
    movi    a10, LED_PIN
    call8   silica_rt_gpio_output
    movi    a10, 1000             // let the pull-ups settle
    call8   silica_rt_delay_us
    call8   read_mask
    mov     a2, a10               // a2 = previous levels
    mov     a7, a10               // a7 = idle levels
    movi    a4, 0
2:  ssr     a4
    srl     a11, a7
    extui   a11, a11, 0, 1
    mov     a10, a4
    call8   print_button
    addi    a4, a4, 1
    movi    a6, N_BUTTONS
    blt     a4, a6, 2b
    movi    a3, 0                 // a3 = poll count
3:  call8   read_mask
    mov     a5, a10               // a5 = current levels
    xor     a6, a5, a2            // a6 = changed
    beqz    a6, 6f
    movi    a4, 0
4:  ssr     a4
    srl     a8, a6
    bbci    a8, 0, 5f
    srl     a11, a5
    extui   a11, a11, 0, 1
    mov     a10, a4
    call8   print_button
5:  addi    a4, a4, 1
    movi    a8, N_BUTTONS
    blt     a4, a8, 4b
    mov     a2, a5
    movi    a10, LED_PIN
    xor     a12, a5, a7
    call8   silica_rt_gpio_write
6:  movi    a10, POLL_US
    call8   silica_rt_delay_us
    addi    a3, a3, 1
    movi    a8, POLLS
    blt     a3, a8, 3b
    movi    a10, LED_PIN
    movi    a12, 0
    call8   silica_rt_gpio_write
    movi    a10, msg_done
    call8   silica_rt_puts
    movi    a2, 0
    movi    a3, 0
    retw
    .size   main, . - main

    .section .rodata.main, "a"
    .align  4
button_pins:
    .word   21, 10, 47, 11, 0, 34, 33
button_names:
    .word   n_left, n_right, n_down, n_up, n_point, n_a, n_b
n_left:  .asciz "Left"
n_right: .asciz "Right"
n_down:  .asciz "Down"
n_up:    .asciz "Up"
n_point: .asciz "Point"
n_a:     .asciz "A"
n_b:     .asciz "B"
msg_done: .asciz "done\n"
