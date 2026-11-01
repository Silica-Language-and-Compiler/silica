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

// Floating-point routines for the bare-metal ESP32-S3 runtime.
//
// Printing follows the macOS emitter's L_pf64/L_pf32/L_pf16 helpers digit for digit: an optional
// minus sign, the integer part (truncated toward zero) in decimal, a point, then the fraction one
// digit at a time -- frac *= 10, digit = trunc(frac), frac -= digit -- for at most 15 digits
// (float64) or 7 (float32 and float16), stopping early when the remaining fraction is exactly zero.
// So 3.0 prints "3.0" and 0.1 prints "0.100000000000000" (float64) / "0.1000000" (float32). float64
// arithmetic is libgcc soft float (IEEE, so the digits agree); float32 uses the FPU, and reproduces
// the host's FCVTZS on non-finite values (nan -> -0.0000000, inf -> 2147483647.0000000); float16 is
// widened to float32 (nan / inf / -inf printed as words, like the host).
//
// Conversions the emitter's float16 and FRINTZ paths need (shared/xt_float.silica): the toolchain
// has no _Float16, so halves convert here, round to nearest even.
//
// Silica pair ABI: silica_rt_print_f64(bits in a2:a3); the others take one word in a2 and return
// one word in a2 (a3 = 0).
//
//   silica_rt_print_f64(v)      silica_rt_print_f32(v)      silica_rt_print_f16(v)
//   silica_rt_h2f(h) -> f32     silica_rt_f2h(f) -> f16
//   silica_rt_trunc_f32(f)      silica_rt_trunc_f64(d)      round toward zero, sign kept
//   silica_rt_f16_to_i32(h)     float16 -> int32 as the host's FCVTZS (main's float16 exit code)

    .section .text.silica_rt_float, "ax"
    .literal_position

// --- float64 (soft float) -------------------------------------------------------------------
// Frame 80: [0, 16) digit buffer; top 32 reserved. a2:a3 value (made non-negative), a4:a5 work
// pair, a6 digit count.
    .align  4
    .global silica_rt_print_f64
    .type   silica_rt_print_f64, @function
silica_rt_print_f64:
    entry   a1, 80
    mov     a10, a2               // v < 0.0 ?  (-0.0 is not, as on the host)
    mov     a11, a3
    movi    a12, 0
    movi    a13, 0
    call8   __ltdf2
    bgez    a10, 1f
    movi    a10, 45
    call8   silica_rt_putc
    movi    a8, 0x80000000
    xor     a3, a3, a8
1:  mov     a10, a2               // integer part (saturates on overflow, like the host's FCVTZS)
    mov     a11, a3
    call8   __fixdfdi
    call8   silica_rt_print_i64
    mov     a10, a2               // frac = v - trunc(v), truncated as a float (the host's FRINTZ),
    mov     a11, a3               // not through the int: for |v| >= 2^63 the int saturates and
    call8   silica_rt_trunc_f64   // v - (double) i would be v itself, so every digit overflowed
    mov     a12, a10              // (1e100 printed 15 '/' where the host prints one '0')
    mov     a13, a11
    mov     a10, a2
    mov     a11, a3
    call8   __subdf3
    mov     a4, a10
    mov     a5, a11
    movi    a6, 0
2:  mov     a10, a4               // frac *= 10.0
    mov     a11, a5
    movi    a12, 0
    movi    a13, 0x40240000
    call8   __muldf3
    mov     a4, a10
    mov     a5, a11
    call8   __fixdfdi             // digit
    addi    a8, a10, 48
    add     a9, a1, a6
    s8i     a8, a9, 0
    call8   __floatdidf           // frac -= digit
    mov     a12, a10
    mov     a13, a11
    mov     a10, a4
    mov     a11, a5
    call8   __subdf3
    mov     a4, a10
    mov     a5, a11
    addi    a6, a6, 1
    movi    a12, 0                // frac == 0.0 ends the digits
    movi    a13, 0
    call8   __eqdf2
    beqz    a10, 3f
    movi    a8, 15
    blt     a6, a8, 2b
3:  movi    a10, 46
    call8   silica_rt_putc
    mov     a10, a1
    mov     a12, a6
    call8   silica_rt_write
    retw
    .size   silica_rt_print_f64, . - silica_rt_print_f64

// --- float32 (FPU) ---------------------------------------------------------------------------
// Frame 64: [0, 16) digit buffer. f0 value, f1 zero, f2 fraction, f3 ten, f4 digit. FP registers
// survive the CALL8s here (the callees do not touch them).
    .align  4
    .global silica_rt_print_f32
    .type   silica_rt_print_f32, @function
silica_rt_print_f32:
    entry   a1, 64
    wfr     f0, a2
    movi    a8, 0
    wfr     f1, a8
    ole.s   b0, f1, f0            // 0.0 <= v ?  false for a nan too: the host's B.ge after FCMP
    bt      b0, 1f                // takes the minus path for unordered, so nan prints as -0.0000000
    movi    a10, 45
    call8   silica_rt_putc
    neg.s   f0, f0
1:  movi    a4, 0                 // integer part, as the host's FCVTZS W0: 0 for a nan (trunc.s
    un.s    b0, f0, f0            // gives INT32_MAX), saturated for inf (trunc.s agrees)
    bt      b0, 4f
    trunc.s a4, f0, 0
4:  mov     a10, a4
    srai    a11, a4, 31
    call8   silica_rt_print_i64
    rfr     a10, f0               // fraction = v - trunc(v), truncated as a float (FRINTZ), not
    call8   silica_rt_trunc_f32   // through the int: inf - inf is nan, whose digits are 0 as on the
    wfr     f2, a10               // host (the int round trip left inf and printed INT32_MAX + 48)
    sub.s   f2, f0, f2
    movi    a8, 0x41200000        // 10.0f
    wfr     f3, a8
    movi    a6, 0
2:  mul.s   f2, f2, f3
    movi    a8, 0                 // digit: 0 for a nan (FCVTZS)
    un.s    b0, f2, f2
    bt      b0, 5f
    trunc.s a8, f2, 0
5:  float.s f4, a8, 0
    sub.s   f2, f2, f4
    addi    a8, a8, 48
    add     a9, a1, a6
    s8i     a8, a9, 0
    addi    a6, a6, 1
    oeq.s   b0, f2, f1
    bt      b0, 3f
    movi    a8, 7                 // the host's float32 helper stops after 7 fraction digits
    blt     a6, a8, 2b
3:  movi    a10, 46
    call8   silica_rt_putc
    mov     a10, a1
    mov     a12, a6
    call8   silica_rt_write
    retw
    .size   silica_rt_print_f32, . - silica_rt_print_f32

// --- float16 ---------------------------------------------------------------------------------
    .align  4
    .global silica_rt_print_f16
    .type   silica_rt_print_f16, @function
silica_rt_print_f16:
    entry   a1, 32
    extui   a4, a2, 10, 5         // exponent
    movi    a8, 31
    bne     a4, a8, 2f
    extui   a5, a2, 0, 10         // mantissa
    movi    a10, silica_rt_f16_nan
    bnez    a5, 1f
    movi    a10, silica_rt_f16_inf
    bbci    a2, 15, 1f
    movi    a10, silica_rt_f16_neg_inf
1:  call8   silica_rt_puts
    retw
2:  mov     a10, a2
    call8   silica_rt_h2f
    call8   silica_rt_print_f32
    retw
    .size   silica_rt_print_f16, . - silica_rt_print_f16

// half -> float. a2 = h; a4 sign bit, a5 exponent, a6 mantissa.
    .align  4
    .global silica_rt_h2f
    .type   silica_rt_h2f, @function
silica_rt_h2f:
    entry   a1, 32
    extui   a4, a2, 15, 1
    slli    a4, a4, 31
    extui   a5, a2, 10, 5
    extui   a6, a2, 0, 10
    movi    a3, 0
    beqz    a5, 3f
    movi    a8, 31
    beq     a5, a8, 4f
    addi    a5, a5, 112           // rebias 15 -> 127
1:  slli    a5, a5, 23
    slli    a6, a6, 13
    or      a2, a4, a5
    or      a2, a2, a6
    retw
3:  beqz    a6, 5f                // signed zero
    movi    a5, 113               // subnormal: normalise the mantissa
31: bbsi    a6, 10, 32f
    slli    a6, a6, 1
    addi    a5, a5, -1
    j       31b
32: extui   a6, a6, 0, 10
    j       1b
4:  movi    a5, 255               // inf / nan
    j       1b
5:  mov     a2, a4
    retw
    .size   silica_rt_h2f, . - silica_rt_h2f

// float -> half, round to nearest even. a2 = f; a4 sign, a5 unbiased exponent, a6 mantissa.
    .align  4
    .global silica_rt_f2h
    .type   silica_rt_f2h, @function
silica_rt_f2h:
    entry   a1, 32
    extui   a4, a2, 31, 1
    slli    a4, a4, 15
    extui   a5, a2, 23, 8
    slli    a6, a2, 9             // mantissa in the top 23 bits
    srli    a6, a6, 9
    movi    a3, 0
    movi    a8, 255
    beq     a5, a8, 6f
    addi    a5, a5, -127
    movi    a8, 16
    bge     a5, a8, 7f            // too large: inf
    movi    a8, -25
    blt     a5, a8, 5f            // too small: signed zero
    movi    a8, 0x800000
    or      a6, a6, a8            // implicit bit
    movi    a8, -15
    bge     a5, a8, 2f
    // subnormal result: shift right by (−14 − e) + 13, rounding
    movi    a8, -1
    sub     a7, a8, a5            // -1 - e  = (-14 - e) + 13
    movi    a5, 0
    j       3f
2:  addi    a5, a5, 14            // biased half exponent minus one: the shifted mantissa still
    movi    a7, 13                // carries the implicit bit at bit 10, which adds the other one
3:  // round a6 >> a7 to nearest even: keep the low a7 bits as the remainder
    ssr     a7
    srl     a8, a6                // truncated
    movi    a9, 1
    ssl     a7
    sll     a9, a9                // 1 << shift
    addi    a10, a9, -1
    and     a11, a6, a10          // remainder
    srli    a9, a9, 1             // half
    bltu    a11, a9, 4f           // below half: down
    bne     a11, a9, 33f          // above half: up
    bbci    a8, 0, 4f             // exactly half: up only when odd
33: addi    a8, a8, 1
4:  slli    a5, a5, 10
    add     a2, a8, a5            // implicit bit and any rounding carry land in the exponent field
    or      a2, a2, a4
    retw
5:  mov     a2, a4
    retw
6:  slli    a6, a2, 9             // mantissa (extui takes at most 16 bits)
    srli    a6, a6, 9
    movi    a2, 0x7C00            // inf, or a quiet nan keeping some payload
    beqz    a6, 61f
    movi    a2, 0x7E00
61: or      a2, a2, a4
    retw
7:  movi    a2, 0x7C00
    or      a2, a2, a4
    retw
    .size   silica_rt_f2h, . - silica_rt_f2h

// --- float16 -> int32 ------------------------------------------------------------------------
// The exit code of a `main() -> float16`: the host does FCVTZS W0, H0 (nan -> 0, saturated
// otherwise). a2 = half bits; returns the int32 in a2, sign-extended into a3.
    .align  4
    .global silica_rt_f16_to_i32
    .type   silica_rt_f16_to_i32, @function
silica_rt_f16_to_i32:
    entry   a1, 32
    mov     a10, a2
    call8   silica_rt_h2f
    wfr     f0, a10
    movi    a2, 0
    un.s    b0, f0, f0            // nan -> 0
    bt      b0, 1f
    trunc.s a2, f0, 0
1:  srai    a3, a2, 31
    retw
    .size   silica_rt_f16_to_i32, . - silica_rt_f16_to_i32

// --- truncation toward zero ------------------------------------------------------------------
// trunc_f32: values with |f| >= 2^23 are already integral (and so are inf / nan bit patterns above
// that exponent); otherwise mask the fraction bits of the mantissa. Sign is kept, so -0.5 -> -0.0.
    .align  4
    .global silica_rt_trunc_f32
    .type   silica_rt_trunc_f32, @function
silica_rt_trunc_f32:
    entry   a1, 32
    movi    a3, 0
    extui   a4, a2, 23, 8
    addi    a4, a4, -127          // unbiased exponent
    movi    a8, 23
    bge     a4, a8, 9f            // integral already
    bltz    a4, 8f                // |f| < 1: signed zero
    movi    a8, 23
    sub     a8, a8, a4            // fraction bits to clear
    movi    a9, -1
    ssl     a8
    sll     a9, a9                // mask keeps the top bits
    and     a2, a2, a9
    retw
8:  movi    a8, 0x80000000
    and     a2, a2, a8
9:  retw
    .size   silica_rt_trunc_f32, . - silica_rt_trunc_f32

// trunc_f64 on the pair a2 (low) : a3 (high).
    .align  4
    .global silica_rt_trunc_f64
    .type   silica_rt_trunc_f64, @function
silica_rt_trunc_f64:
    entry   a1, 32
    extui   a4, a3, 20, 11
    addi    a4, a4, -1023
    movi    a8, 52
    bge     a4, a8, 9f
    bltz    a4, 8f
    movi    a8, 52
    sub     a8, a8, a4            // fraction bits to clear (1..52)
    movi    a9, 32
    bge     a8, a9, 2f
    movi    a9, -1                // fewer than 32: clear low bits of the low word only
    ssl     a8
    sll     a9, a9
    and     a2, a2, a9
    retw
2:  movi    a2, 0                 // 32 or more: the whole low word, and a8-32 bits of the high word
    addi    a8, a8, -32
    movi    a9, -1
    ssl     a8
    sll     a9, a9
    and     a3, a3, a9
    retw
8:  movi    a2, 0
    movi    a8, 0x80000000
    and     a3, a3, a8
9:  retw
    .size   silica_rt_trunc_f64, . - silica_rt_trunc_f64

    .section .rodata.silica_rt_float, "a"
silica_rt_f16_nan:
    .asciz  "nan"
silica_rt_f16_inf:
    .asciz  "inf"
silica_rt_f16_neg_inf:
    .asciz  "-inf"
