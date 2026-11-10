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

// Small runtime pieces of the bare-metal STM32L476RG port that the ESP32-S3 tree keeps in rt_float.S
// (its conversions; the printing is in this tree's rt_float.S too), rt_ordering.S, rt_board.S,
// rt_device.S and rt_ffi.S:
//   checked int64 arithmetic (spec §4.2.4): silica_rt_checked_i64_add / _add1 / _mul -> X0 ok (0/1),
//     X1 the value (the emitter reads the value from X1: prims_checked_int64.silica)
//   half precision: silica_rt_h2f(r0 = bits) -> r0 float bits, silica_rt_f2h(r0) -> r0 half bits
//     (AAPCS; called from the emitted libcall staging of shared/arm_float.silica)
//   truncation: silica_rt_trunc_f32(r0) -> r0, silica_rt_trunc_f64(r0:r1) -> r0:r1 (AAPCS, exact)
//   silica_rt_map_device_check(X0 base, X1 size) -> X0 base, or the abort "illegal device map": the
//     run-time twin of board_pack.silica's window table (the same rows, the same order)
//   the memory functions a foreign C wrapper would need (memcpy, memmove, memset, memcmp, strlen)
//   GPIO helpers for the user LED (PA5) and a busy delay, for board apps
// The ordering identities are not ported yet (rt_stubs.S).

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

    .section .text.silica_rt_support, "ax", %progbits

// ---- checked int64 ---------------------------------------------------------------------------

// checked_i64_add(X0, X1) -> X0 ok, X1 sum.
    FUNC silica_rt_checked_i64_add
    ENTRY_SAVE
    adds    r4, r0, r2
    adcs    r5, r1, r3
    ite     vs
    movvs   r0, #0
    movvc   r0, #1
    movw    r1, #0
    str     r4, [sp, #8]                    // X1 = the sum, in the saved slots of r2:r3
    str     r5, [sp, #12]
    ENTRY_RET_X0
    .size   silica_rt_checked_i64_add, . - silica_rt_checked_i64_add

// checked_i64_add1(X0) -> X0 ok, X1 the value + 1.
    FUNC silica_rt_checked_i64_add1
    ENTRY_SAVE
    adds    r4, r0, #1
    adcs    r5, r1, #0
    ite     vs
    movvs   r0, #0
    movvc   r0, #1
    movw    r1, #0
    str     r4, [sp, #8]
    str     r5, [sp, #12]
    ENTRY_RET_X0
    .size   silica_rt_checked_i64_add1, . - silica_rt_checked_i64_add1

// checked_i64_mul(X0, X1) -> X0 ok, X1 product. Exact: the 128-bit product through 32x32 partials;
// ok when the high 64 bits are the sign extension of the low 64.
    FUNC silica_rt_checked_i64_mul
    ENTRY_SAVE
    // unsigned 64x64 -> 128 of |a| and |b|, then the sign
    mov     r4, r0
    mov     r5, r1
    mov     r6, r2
    mov     r7, r3
    eor     r8, r5, r7                      // the result's sign (bit 31)
    cmp     r5, #0
    bge.w   1f
    rsbs    r4, r4, #0
    sbc     r5, r5, r5, lsl #1
1:  cmp     r7, #0
    bge.w   2f
    rsbs    r6, r6, #0
    sbc     r7, r7, r7, lsl #1
2:  umull   r0, r1, r4, r6                  // lo64 = a0*b0 (r0:r1)
    umull   r2, r3, r4, r7                  // a0*b1
    adds    r1, r1, r2
    adc     r12, r3, #0                     // r12 = carry into the high part
    umull   r2, r3, r5, r6                  // a1*b0
    adds    r1, r1, r2
    adc     r12, r12, r3
    umull   r2, r3, r5, r7                  // a1*b1
    adds    r2, r2, r12
    adc     r3, r3, #0                      // r2:r3 = hi64
    // overflow when hi64 != 0, or when the low 64 bits exceed the signed range
    orrs    r12, r2, r3
    bne.w   8f
    cmp     r8, #0
    bge.w   3f
    rsbs    r0, r0, #0                      // negative: -|p|
    sbc     r1, r1, r1, lsl #1
    cmp     r1, #0
    bgt.w   8f                              // |p| > 2^63
    b.w     4f
3:  cmp     r1, #0
    blt.w   8f                              // |p| >= 2^63
4:  str     r0, [sp, #8]
    str     r1, [sp, #12]
    movw    r0, #1
    movw    r1, #0
    ENTRY_RET_X0
8:  movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_checked_i64_mul, . - silica_rt_checked_i64_mul

// ---- half precision --------------------------------------------------------------------------

// h2f(r0 = half bits) -> r0 = float bits.
    FUNC silica_rt_h2f
    uxth    r0, r0
    lsl     r1, r0, #16
    and     r1, r1, #0x80000000             // the sign
    ubfx    r2, r0, #10, #5                 // the exponent
    ubfx    r3, r0, #0, #10                 // the fraction
    cmp     r2, #0
    beq.w   2f
    cmp     r2, #31
    beq.w   3f
    add     r2, r2, #112                    // the biased float exponent
    orr     r0, r1, r2, lsl #23
    orr     r0, r0, r3, lsl #13
    bx      lr
2:  cmp     r3, #0
    beq.w   4f                              // a zero
    movw    r2, #113                        // a subnormal: normalise
21: lsls    r3, r3, #1
    sub     r2, r2, #1
    tst     r3, #0x400
    beq.w   21b
    bic     r3, r3, #0x400
    orr     r0, r1, r2, lsl #23
    orr     r0, r0, r3, lsl #13
    bx      lr
3:  orr     r0, r1, #0x7F800000             // infinity or NaN
    orr     r0, r0, r3, lsl #13
    bx      lr
4:  mov     r0, r1
    bx      lr
    .size   silica_rt_h2f, . - silica_rt_h2f

// f2h(r0 = float bits) -> r0 = half bits, round to nearest even.
    FUNC silica_rt_f2h
    lsr     r1, r0, #16
    and     r1, r1, #0x8000                 // the sign
    ubfx    r2, r0, #23, #8                 // the exponent
    ubfx    r3, r0, #0, #23                 // the fraction
    cmp     r2, #255
    bne.w   1f
    orr     r0, r1, #0x7C00                 // infinity or NaN (a quiet payload bit kept)
    cmp     r3, #0
    it      ne
    orrne   r0, r0, #0x200
    bx      lr
1:  sub     r2, r2, #112                    // the half exponent
    cmp     r2, #31
    bge.w   5f                              // overflow: infinity
    cmp     r2, #1
    blt.w   3f
    // normal: round the fraction to 10 bits
    lsr     r0, r3, #13
    ubfx    r12, r3, #0, #13
    cmp     r12, #0x1000
    blo.w   2f
    bhi.w   11f
    tst     r0, #1                          // a tie: to even
    beq.w   2f
11: add     r0, r0, #1
    cmp     r0, #0x400
    blo.w   2f
    movw    r0, #0
    add     r2, r2, #1
    cmp     r2, #31
    bge.w   5f
2:  orr     r0, r0, r2, lsl #10
    orr     r0, r0, r1
    bx      lr
3:  // subnormal or zero in half precision
    cmp     r2, #-10
    blt.w   4f
    orr     r3, r3, #0x800000               // the hidden bit
    rsb     r12, r2, #14                    // shift = 14 - e (e <= 0): 13 + (1 - e)
    lsr     r0, r3, r12
    sub     r12, r12, #1
    movw    r2, #1
    lsl     r2, r2, r12                     // the half-way bit
    sub     r12, r2, #1
    and     r12, r3, r12                    // the bits below it
    tst     r3, r2
    beq.w   31f
    cmp     r12, #0
    bne.w   32f
    tst     r0, #1
    beq.w   31f
32: add     r0, r0, #1
31: orr     r0, r0, r1
    bx      lr
4:  mov     r0, r1                          // too small: a signed zero
    bx      lr
5:  orr     r0, r1, #0x7C00
    bx      lr
    .size   silica_rt_f2h, . - silica_rt_f2h

// trunc_f32(r0) -> r0: toward zero, exact for every input.
    FUNC silica_rt_trunc_f32
    ubfx    r1, r0, #23, #8
    cmp     r1, #150
    bhs.w   9f                              // |x| >= 2^23: integral already (or inf/NaN)
    cmp     r1, #127
    blo.w   8f                              // |x| < 1: a signed zero
    rsb     r1, r1, #150                    // the fraction bits below the point
    lsr     r0, r0, r1
    lsl     r0, r0, r1
9:  bx      lr
8:  and     r0, r0, #0x80000000
    bx      lr
    .size   silica_rt_trunc_f32, . - silica_rt_trunc_f32

// trunc_f64(r0:r1) -> r0:r1.
    FUNC silica_rt_trunc_f64
    ubfx    r2, r1, #20, #11
    movw    r3, #1075
    cmp     r2, r3
    bhs.w   9f                              // |x| >= 2^52: integral
    movw    r3, #1023
    cmp     r2, r3
    blo.w   8f
    movw    r3, #1075
    sub     r2, r3, r2                      // the fraction bits below the point (1..52)
    cmp     r2, #32
    blo.w   1f
    sub     r2, r2, #32
    lsr     r1, r1, r2
    lsl     r1, r1, r2
    movw    r0, #0
    bx      lr
1:  lsr     r0, r0, r2
    lsl     r0, r0, r2
9:  bx      lr
8:  and     r1, r1, #0x80000000
    movw    r0, #0
    bx      lr
    .size   silica_rt_trunc_f64, . - silica_rt_trunc_f64

// ---- device windows ---------------------------------------------------------------------------

// map_device_check(X0 base, X1 size) -> X0 base when [base, base + size) lies in one window of the
// board pack (board_pack.silica window_base / window_size: the same rows), else the abort.
    FUNC silica_rt_map_device_check
    ENTRY_SAVE
    MOV32   r4, silica_rt_windows
    movw    r5, #12
1:  cmp     r5, #0
    beq.w   8f
    ldr     r6, [r4], #4                    // base
    ldr     r7, [r4], #4                    // size
    cmp     r2, r7
    bhi.w   2f
    cmp     r0, r6
    blo.w   2f
    sub     r8, r0, r6
    sub     r7, r7, r2
    cmp     r8, r7
    bls.w   9f
2:  sub     r5, r5, #1
    b.w     1b
8:  MOV32   r0, silica_rt_reason_device_map
    bl      silica_rt_abort_body
9:  movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_map_device_check, . - silica_rt_map_device_check

// ---- memory functions (AAPCS, for foreign C code) ----------------------------------------------

    FUNC memcpy
    push    {r4, lr}
    mov     r3, r0
1:  cmp     r2, #0
    beq.w   2f
    ldrb    r4, [r1], #1
    strb    r4, [r3], #1
    sub     r2, r2, #1
    b.w     1b
2:  pop     {r4, pc}
    .size   memcpy, . - memcpy

    FUNC memmove
    push    {r4, lr}
    cmp     r0, r1
    bls.w   3f
    add     r3, r0, r2
    add     r1, r1, r2
1:  cmp     r2, #0
    beq.w   2f
    ldrb    r4, [r1, #-1]!
    strb    r4, [r3, #-1]!
    sub     r2, r2, #1
    b.w     1b
2:  pop     {r4, pc}
3:  mov     r3, r0
4:  cmp     r2, #0
    beq.w   2b
    ldrb    r4, [r1], #1
    strb    r4, [r3], #1
    sub     r2, r2, #1
    b.w     4b
    .size   memmove, . - memmove

    FUNC memset
    mov     r3, r0
1:  cmp     r2, #0
    beq.w   2f
    strb    r1, [r3], #1
    sub     r2, r2, #1
    b.w     1b
2:  bx      lr
    .size   memset, . - memset

    FUNC memcmp
    push    {r4, r5, lr}
1:  cmp     r2, #0
    beq.w   3f
    ldrb    r4, [r0], #1
    ldrb    r5, [r1], #1
    cmp     r4, r5
    bne.w   2f
    sub     r2, r2, #1
    b.w     1b
2:  sub     r0, r4, r5
    pop     {r4, r5, pc}
3:  movw    r0, #0
    pop     {r4, r5, pc}
    .size   memcmp, . - memcmp

    FUNC strlen
    mov     r1, r0
1:  ldrb    r2, [r1], #1
    cmp     r2, #0
    bne.w   1b
    sub     r0, r1, r0
    sub     r0, r0, #1
    bx      lr
    .size   strlen, . - strlen

// ---- board helpers (AAPCS) ---------------------------------------------------------------------

// silica_rt_gpio_led_init(): PA5 (LD2) as a push-pull output.
    FUNC silica_rt_gpio_led_init
    MOV32   r1, GPIOA_BASE
    ldr     r0, [r1, #GPIO_MODER]
    bic     r0, r0, #0xC00
    orr     r0, r0, #0x400
    str     r0, [r1, #GPIO_MODER]
    bx      lr
    .size   silica_rt_gpio_led_init, . - silica_rt_gpio_led_init

// silica_rt_gpio_led_write(r0 = 0/1).
    FUNC silica_rt_gpio_led_write
    MOV32   r1, GPIOA_BASE
    cmp     r0, #0
    ite     ne
    movne   r2, #0x20
    moveq   r2, #0x200000
    str     r2, [r1, #GPIO_BSRR]
    bx      lr
    .size   silica_rt_gpio_led_write, . - silica_rt_gpio_led_write

// silica_rt_delay_ms(r0 = ms): busy wait on the millisecond count.
    FUNC silica_rt_delay_ms
    push    {r4, r5, lr}
    mov     r4, r0
    bl      silica_rt_now_ms
    mov     r5, r0
1:  bl      silica_rt_now_ms
    sub     r0, r0, r5
    cmp     r0, r4
    blo.w   1b
    pop     {r4, r5, pc}
    .size   silica_rt_delay_ms, . - silica_rt_delay_ms

    .section .rodata.silica_rt_support, "a", %progbits
    .balign 4
// (base, size) per window, the order of board_pack.silica window_tag
silica_rt_windows:
    .word   0x40004400, 0x400               // usart2
    .word   0x48000000, 0x400               // gpioa
    .word   0x48000400, 0x400               // gpiob
    .word   0x48000800, 0x400               // gpioc
    .word   0x40021000, 0x400               // rcc
    .word   0x40013800, 0x400               // usart1
    .word   0x40004800, 0x400               // usart3
    .word   0x40000000, 0x400               // tim2
    .word   0x40000400, 0x400               // tim3
    .word   0xE000E010, 0x10                // systick
    .word   0xE000ED00, 0x90                // scb
    .word   0x40007000, 0x400               // pwr
silica_rt_reason_device_map:
    .asciz  "illegal device map"
