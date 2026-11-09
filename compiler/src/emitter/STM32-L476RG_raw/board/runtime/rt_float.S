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

// Floating-point printing for the bare-metal STM32L476RG runtime (the ESP32-S3 tree's rt_float.S;
// the conversions h2f / f2h / trunc_f32 / trunc_f64 live in rt_support.S here).
//
// Printing follows the macOS emitter's L_pf64/L_pf32/L_pf16 helpers digit for digit: an optional
// minus sign, the integer part (truncated toward zero) in decimal, a point, then the fraction one
// digit at a time -- frac *= 10, digit = trunc(frac), frac -= digit -- for at most 15 digits
// (float64) or 7 (float32 and float16), stopping early when the remaining fraction is exactly zero.
// So 3.0 prints "3.0" and 0.1 prints "0.100000000000000" (float64) / "0.1000000" (float32).
//
// The host's helpers start with FCMP v, #0.0; B.ge, so an unordered value (nan) takes the minus path
// and prints as -0.0...; the integer part and every digit are the host's FCVTZS (nan -> 0, saturated
// otherwise), and the fraction is v - trunc(v) with the truncation done as a float (the host's FRINTZ),
// so inf prints 2147483647.0000000 (float32: inf - inf is nan, whose digits are 0). float64 is libgcc
// soft float (IEEE, so the digits agree; the double -> int64 truncation is done here so that it
// saturates exactly like FCVTZS); float32 uses the FPU, whose VCVT.S32.F32 is FCVTZS; float16 is
// widened to float32 (nan / inf / -inf printed as words, like the host).
//
// Entries emitted code calls (rt_defs.h: every register kept except r10, r11, lr, and r0:r1 when the
// entry answers in X0):
//   silica_rt_print_f64(X0 = the double's bits, r0 low : r1 high)
//   silica_rt_print_f32(W0 = r0 = the float's bits)
//   silica_rt_print_f16(W0 = r0 = the half's bits)
//   silica_rt_f16_to_i32(W0 = half bits) -> X0: float16 -> int32 as the host's FCVTZS W0, H0 (the
//     exit code of a `main() -> float16`), sign-extended into r1

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

    .section .text.silica_rt_float, "ax", %progbits

// ---- float64 (soft float) -------------------------------------------------------------------
// r4:r5 the value (made non-negative), then the fraction; r6 the digit count; r7 a digit; r8 the
// entry sp. 16 bytes of digit buffer at [sp].
    FUNC silica_rt_print_f64
    ENTRY_SAVE
    mov     r8, sp
    sub     sp, sp, #16
    mov     r4, r0
    mov     r5, r1
    movw    r2, #0                          // 0.0 <= v ?  0 for a nan too: the host's B.ge after
    movw    r3, #0                          // FCMP takes the minus path for unordered
    bl      __aeabi_dcmpge
    cmp     r0, #0
    bne.w   1f
    movw    r0, #45
    bl      silica_rt_putc
    eor     r5, r5, #0x80000000
1:  mov     r0, r4                          // integer part: FCVTZS X0 (nan -> 0, saturated)
    mov     r1, r5
    bl      silica_rt_d2i64
    bl      silica_rt_print_i64
    mov     r0, r4                          // frac = v - trunc(v), truncated as a float (FRINTZ), not
    mov     r1, r5                          // through the int: for |v| >= 2^63 the int saturates and
    bl      silica_rt_trunc_f64             // v - (double) i would be v itself
    mov     r2, r0
    mov     r3, r1
    mov     r0, r4
    mov     r1, r5
    bl      __aeabi_dsub
    mov     r4, r0
    mov     r5, r1
    movw    r6, #0
2:  mov     r0, r4                          // frac *= 10.0
    mov     r1, r5
    movw    r2, #0
    movw    r3, #0
    movt    r3, #0x4024
    bl      __aeabi_dmul
    mov     r4, r0
    mov     r5, r1
    bl      __aeabi_d2iz                    // digit (0 for a nan)
    mov     r7, r0
    bl      __aeabi_i2d                     // frac -= digit
    mov     r2, r0
    mov     r3, r1
    mov     r0, r4
    mov     r1, r5
    bl      __aeabi_dsub
    mov     r4, r0
    mov     r5, r1
    add     r7, r7, #48
    add     r12, sp, r6
    strb    r7, [r12]
    add     r6, r6, #1
    movw    r2, #0                          // frac == 0.0 ends the digits (false for a nan)
    movw    r3, #0
    bl      __aeabi_dcmpeq
    cmp     r0, #0
    bne.w   3f
    cmp     r6, #15                         // the host's float64 helper stops after 15 digits
    blt.w   2b
3:  movw    r0, #46
    bl      silica_rt_putc
    mov     r0, sp
    mov     r2, r6
    bl      silica_rt_write
    mov     sp, r8
    ENTRY_RET
    .size   silica_rt_print_f64, . - silica_rt_print_f64

// d2i64(r0:r1 = double bits) -> r0:r1: truncation toward zero with the host's FCVTZS behaviour
// (nan -> 0, saturated to INT64_MIN / INT64_MAX). AAPCS.
    LFUNC silica_rt_d2i64
    push    {r4, lr}
    mov     r4, r1                          // the sign is bit 31 of r4
    ubfx    r2, r1, #20, #11
    movw    r3, #0x7FF
    cmp     r2, r3
    bne.w   1f
    ubfx    r3, r1, #0, #20                 // inf or nan: nan when the fraction is not zero
    orrs    r3, r3, r0
    bne.w   9f
    b.w     8f
1:  movw    r3, #1023
    subs    r2, r2, r3                      // the unbiased exponent
    blt.w   9f                              // |v| < 1
    cmp     r2, #63
    bge.w   8f
    ubfx    r1, r1, #0, #20
    orr     r1, r1, #0x100000               // r0:r1 = the 53-bit significand, worth 2^(e - 52) each
    cmp     r2, #52
    blt.w   2f
    sub     r2, r2, #52
    bl      __aeabi_llsl
    b.w     3f
2:  rsb     r2, r2, #52
    bl      __aeabi_llsr
3:  cmp     r4, #0
    bge.w   7f
    rsbs    r0, r0, #0
    sbc     r1, r1, r1, lsl #1
7:  pop     {r4, pc}
8:  mvn     r0, #0                          // INT64_MAX, or INT64_MIN when negative
    mvn     r1, #0x80000000
    cmp     r4, #0
    bge.w   7b
    movw    r0, #0
    mov     r1, #0x80000000
    b.w     7b
9:  movw    r0, #0
    movw    r1, #0
    pop     {r4, pc}
    .size   silica_rt_d2i64, . - silica_rt_d2i64

// ---- float32 (FPU) --------------------------------------------------------------------------
// s0 the value, s1 the integer / digit, s2 the fraction, s3 ten (d0, d1 saved around); r5 the
// digit count; 16 bytes of digit buffer at [sp]. The callees here touch no FP register. Output goes
// through the public console entries (putc / write / print_i64 keep every register).
    FUNC silica_rt_print_f32
    ENTRY_SAVE
    vpush   {d0, d1}
    sub     sp, sp, #16
    vmov    s0, r0
    vcmp.f32 s0, #0.0                       // 0.0 <= v ?  unordered fails GE as on the host, so a
    vmrs    APSR_nzcv, fpscr                // nan prints as -0.0000000
    bge.w   1f
    movw    r0, #45
    bl      silica_rt_putc
    vneg.f32 s0, s0
1:  vcvt.s32.f32 s1, s0                     // integer part: toward zero, nan -> 0, saturated (FCVTZS W0)
    vmov    r0, s1
    asr     r1, r0, #31
    bl      silica_rt_print_i64
    vmov    r0, s0                          // fraction = v - trunc(v), truncated as a float (FRINTZ):
    bl      silica_rt_trunc_f32             // inf - inf is nan, whose digits are 0 as on the host
    vmov    s2, r0
    vsub.f32 s2, s0, s2
    vmov.f32 s3, #10.0
    movw    r5, #0
2:  vmul.f32 s2, s2, s3
    vcvt.s32.f32 s1, s2                     // digit (0 for a nan)
    vmov    r0, s1
    vcvt.f32.s32 s1, s1
    vsub.f32 s2, s2, s1
    add     r0, r0, #48
    add     r4, sp, r5
    strb    r0, [r4]
    add     r5, r5, #1
    vcmp.f32 s2, #0.0                       // frac == 0.0 ends the digits (a nan is not equal)
    vmrs    APSR_nzcv, fpscr
    beq.w   3f
    cmp     r5, #7                          // the host's float32 helper stops after 7 digits
    blt.w   2b
3:  movw    r0, #46
    bl      silica_rt_putc
    mov     r0, sp
    mov     r2, r5
    bl      silica_rt_write
    add     sp, sp, #16
    vpop    {d0, d1}
    ENTRY_RET
    .size   silica_rt_print_f32, . - silica_rt_print_f32

// ---- float16 --------------------------------------------------------------------------------
    FUNC silica_rt_print_f16
    ENTRY_SAVE
    ubfx    r1, r0, #10, #5                 // the exponent
    cmp     r1, #31
    bne.w   2f
    ubfx    r1, r0, #0, #10                 // the fraction: a nan when not zero
    MOV32   r2, silica_rt_f16_nan
    cmp     r1, #0
    bne.w   1f
    MOV32   r2, silica_rt_f16_inf
    tst     r0, #0x8000
    beq.w   1f
    MOV32   r2, silica_rt_f16_neg_inf
1:  mov     r0, r2
    bl      silica_rt_puts
    ENTRY_RET
2:  bl      silica_rt_h2f
    bl      silica_rt_print_f32
    ENTRY_RET
    .size   silica_rt_print_f16, . - silica_rt_print_f16

// ---- float16 -> int32 -----------------------------------------------------------------------
// The exit code of a `main() -> float16`: the host does FCVTZS W0, H0 (nan -> 0, saturated
// otherwise). W0 = half bits; answers the int32 in r0, sign-extended into r1.
    FUNC silica_rt_f16_to_i32
    ENTRY_SAVE
    vpush   {d0}
    bl      silica_rt_h2f
    vmov    s0, r0
    vcvt.s32.f32 s0, s0
    vmov    r0, s0
    asr     r1, r0, #31
    vpop    {d0}
    ENTRY_RET_X0
    .size   silica_rt_f16_to_i32, . - silica_rt_f16_to_i32

    .section .rodata.silica_rt_float, "a", %progbits
silica_rt_f16_nan:
    .asciz  "nan"
silica_rt_f16_inf:
    .asciz  "inf"
silica_rt_f16_neg_inf:
    .asciz  "-inf"
