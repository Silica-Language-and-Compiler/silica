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

// String routines for the bare-metal STM32L476RG runtime (the ESP32-S3 port's rt_string.S respelled).
//
// A Silica string is a 24-byte header followed (usually) by its bytes: the layout the AArch64 helpers
// and the string literal pool agree on, kept with 8-byte fields so emitted loads at +8 and +16 work:
//     +0   tag       -1 (two words, both 0xFFFFFFFF)
//     +8   data      pointer to the UTF-8 bytes, NUL-terminated (low word; the high word is 0)
//     +16  length    byte count (low word; the high word is 0)
//
// Silica pair ABI (X0 = r0:r1, X1 = r2:r3, X2 = r4:r5; result X0; every other register kept):
//   silica_rt_string_length_bytes(s)            -> int64
//   silica_rt_string_length_chars(s)            -> int64   UTF-8 scalar count (a continuation byte
//                                                  does not count; a stray one counts as one)
//   silica_rt_string_concat(a, b)               -> string  an empty operand returns the other
//   silica_rt_string_eq(a, b)                   -> 0/1
//   silica_rt_string_cmp(a, b)                  -> -1/0/1  unsigned bytewise, shorter prefix first
//   silica_rt_string_starts_with(h, n)          -> 0/1
//   silica_rt_string_ends_with(h, n)            -> 0/1
//   silica_rt_string_contains(h, n)             -> 0/1
//   silica_rt_string_substring(s, c0, c1)       -> string  character indices [c0, c1), clamped
//   silica_rt_string_substring_until_char(s, b0, ch) -> string  from byte b0 up to (not including)
//                                                  the first occurrence of ch (len<<56 | packed bytes)
// Internal (AAPCS): silica_rt_string_from_bytes(r0 = p, r1 = n) -> r0 a fresh string in the running
// frame's dynamic part; silica_rt_empty_string, the shared empty string.

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

    .section .rodata.silica_rt_string, "a", %progbits
    .balign 8
    .global silica_rt_empty_string
silica_rt_empty_string:
    .word   -1, -1
    .word   silica_rt_empty_bytes, 0
    .word   0, 0
silica_rt_empty_bytes:
    .byte   0

    .section .text.silica_rt_string, "ax", %progbits

// rt_str_check(r0 = handle): a tag other than -1 aborts (not a Silica string). Keeps every register.
    LFUNC rt_str_check
    push    {r1, lr}
    ldr     r1, [r0, #0]
    adds    r1, r1, #1
    bne.w   1f
    pop     {r1, pc}
1:  bl      silica_rt_abort_not_a_string
    .size   rt_str_check, . - rt_str_check

// silica_rt_string_from_bytes(r0 = p, r1 = n) -> r0 = string. The header and the bytes (plus a NUL) in
// one frame block.
    FUNC silica_rt_string_from_bytes
    push    {r4-r6, lr}
    mov     r4, r0
    mov     r5, r1
    cmp     r5, #0
    bne.w   1f
    MOV32   r0, silica_rt_empty_string
    pop     {r4-r6, pc}
1:  add     r0, r5, #25
    bl      silica_rt_frame_alloc
    mov     r6, r0
    movw    r1, #0xFFFF
    movt    r1, #0xFFFF
    str     r1, [r6, #0]
    str     r1, [r6, #4]
    add     r1, r6, #24
    str     r1, [r6, #8]
    str     r5, [r6, #16]
    movw    r2, #0
2:  cmp     r2, r5
    bhs.w   3f
    ldrb    r3, [r4, r2]
    strb    r3, [r1, r2]
    add     r2, r2, #1
    b.w     2b
3:  movw    r3, #0
    strb    r3, [r1, r2]
    mov     r0, r6
    pop     {r4-r6, pc}
    .size   silica_rt_string_from_bytes, . - silica_rt_string_from_bytes

    FUNC silica_rt_string_length_bytes
    ENTRY_SAVE
    bl      rt_str_check
    ldr     r0, [r0, #16]
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_string_length_bytes, . - silica_rt_string_length_bytes

    FUNC silica_rt_string_length_chars
    ENTRY_SAVE
    bl      rt_str_check
    ldr     r1, [r0, #16]
    ldr     r2, [r0, #8]
    movw    r0, #0
1:  cmp     r1, #0
    beq.w   3f
    ldrb    r3, [r2], #1
    sub     r1, r1, #1
    and     r3, r3, #0xC0
    cmp     r3, #0x80
    beq.w   1b                              // a continuation byte
    add     r0, r0, #1
    b.w     1b
3:  movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_string_length_chars, . - silica_rt_string_length_chars

    FUNC silica_rt_string_concat
    ENTRY_SAVE
    bl      rt_str_check
    mov     r4, r0                          // a
    mov     r5, r2                          // b
    mov     r0, r5
    bl      rt_str_check
    ldr     r6, [r4, #16]
    ldr     r7, [r5, #16]
    cmp     r6, #0
    bne.w   1f
    mov     r0, r5
    b.w     9f
1:  cmp     r7, #0
    bne.w   2f
    mov     r0, r4
    b.w     9f
2:  add     r0, r6, r7
    add     r0, r0, #25
    bl      silica_rt_frame_alloc
    mov     r8, r0
    movw    r1, #0xFFFF
    movt    r1, #0xFFFF
    str     r1, [r8, #0]
    str     r1, [r8, #4]
    add     r1, r8, #24
    str     r1, [r8, #8]
    add     r2, r6, r7
    str     r2, [r8, #16]
    ldr     r2, [r4, #8]
    mov     r3, r6
    bl      rt_copy_bytes_fwd
    ldr     r2, [r5, #8]
    mov     r3, r7
    bl      rt_copy_bytes_fwd
    movw    r2, #0
    strb    r2, [r1]
    mov     r0, r8
9:  movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_string_concat, . - silica_rt_string_concat

// rt_copy_bytes_fwd(r1 = dst, r2 = src, r3 = n): copies and advances r1 past the copy. Clobbers r2, r3, r12.
    LFUNC rt_copy_bytes_fwd
1:  cmp     r3, #0
    beq.w   2f
    ldrb    r12, [r2], #1
    strb    r12, [r1], #1
    sub     r3, r3, #1
    b.w     1b
2:  bx      lr
    .size   rt_copy_bytes_fwd, . - rt_copy_bytes_fwd

// rt_bytes_eq(r0 = p, r1 = q, r2 = n) -> r0 = 1 when the n bytes match. Clobbers r1-r3, r12.
    LFUNC rt_bytes_eq
1:  cmp     r2, #0
    beq.w   2f
    ldrb    r3, [r0], #1
    ldrb    r12, [r1], #1
    cmp     r3, r12
    bne.w   3f
    sub     r2, r2, #1
    b.w     1b
2:  movw    r0, #1
    bx      lr
3:  movw    r0, #0
    bx      lr
    .size   rt_bytes_eq, . - rt_bytes_eq

    FUNC silica_rt_string_eq
    ENTRY_SAVE
    bl      rt_str_check
    mov     r4, r0
    mov     r0, r2
    bl      rt_str_check
    ldr     r6, [r4, #16]
    ldr     r7, [r2, #16]
    cmp     r6, r7
    bne.w   8f
    ldr     r0, [r4, #8]
    ldr     r1, [r2, #8]
    mov     r2, r6
    bl      rt_bytes_eq
    b.w     9f
8:  movw    r0, #0
9:  movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_string_eq, . - silica_rt_string_eq

    FUNC silica_rt_string_cmp
    ENTRY_SAVE
    bl      rt_str_check
    mov     r4, r0
    mov     r0, r2
    bl      rt_str_check
    ldr     r6, [r4, #16]
    ldr     r7, [r2, #16]
    ldr     r0, [r4, #8]
    ldr     r1, [r2, #8]
    cmp     r6, r7
    ite     lo
    movlo   r3, r6
    movhs   r3, r7                          // r3 = the shorter length
1:  cmp     r3, #0
    beq.w   4f
    ldrb    r8, [r0], #1
    ldrb    r12, [r1], #1
    cmp     r8, r12
    blo.w   5f
    bhi.w   6f
    sub     r3, r3, #1
    b.w     1b
4:  cmp     r6, r7
    blo.w   5f
    bhi.w   6f
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
5:  movw    r0, #0xFFFF
    movt    r0, #0xFFFF
    mov     r1, r0
    ENTRY_RET_X0
6:  movw    r0, #1
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_string_cmp, . - silica_rt_string_cmp

    FUNC silica_rt_string_starts_with
    ENTRY_SAVE
    bl      rt_str_check
    mov     r4, r0
    mov     r0, r2
    bl      rt_str_check
    ldr     r6, [r4, #16]
    ldr     r7, [r2, #16]
    cmp     r7, r6
    bhi.w   8f
    ldr     r0, [r4, #8]
    ldr     r1, [r2, #8]
    mov     r2, r7
    bl      rt_bytes_eq
    b.w     9f
8:  movw    r0, #0
9:  movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_string_starts_with, . - silica_rt_string_starts_with

    FUNC silica_rt_string_ends_with
    ENTRY_SAVE
    bl      rt_str_check
    mov     r4, r0
    mov     r0, r2
    bl      rt_str_check
    ldr     r6, [r4, #16]
    ldr     r7, [r2, #16]
    cmp     r7, r6
    bhi.w   8f
    ldr     r0, [r4, #8]
    add     r0, r0, r6
    sub     r0, r0, r7
    ldr     r1, [r2, #8]
    mov     r2, r7
    bl      rt_bytes_eq
    b.w     9f
8:  movw    r0, #0
9:  movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_string_ends_with, . - silica_rt_string_ends_with

    FUNC silica_rt_string_contains
    ENTRY_SAVE
    bl      rt_str_check
    mov     r4, r0
    mov     r0, r2
    bl      rt_str_check
    mov     r5, r2
    ldr     r6, [r4, #16]                   // haystack length
    ldr     r7, [r5, #16]                   // needle length
    cmp     r7, r6
    bhi.w   8f
    sub     r8, r6, r7
    add     r8, r8, #1                      // candidate start positions
    ldr     r4, [r4, #8]
1:  cmp     r8, #0
    beq.w   8f
    mov     r0, r4
    ldr     r1, [r5, #8]
    mov     r2, r7
    bl      rt_bytes_eq
    cmp     r0, #0
    bne.w   9f
    add     r4, r4, #1
    sub     r8, r8, #1
    b.w     1b
8:  movw    r0, #0
9:  movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_string_contains, . - silica_rt_string_contains

// rt_char_offset(r0 = bytes, r1 = byte length, r2 = character index) -> r0 = the byte offset of
// character r2 (clamped to the length). Clobbers r2, r3, r12.
    LFUNC rt_char_offset
    movw    r3, #0                          // byte offset
1:  cmp     r2, #0
    beq.w   9f
    cmp     r3, r1
    bhs.w   9f
    ldrb    r12, [r0, r3]
    add     r3, r3, #1
    cmp     r12, #0x80
    blo.w   2f
    cmp     r12, #0xE0
    blo.w   3f
    cmp     r12, #0xF0
    blo.w   4f
    add     r3, r3, #3
    b.w     2f
4:  add     r3, r3, #2
    b.w     2f
3:  add     r3, r3, #1
2:  sub     r2, r2, #1
    b.w     1b
9:  cmp     r3, r1
    it      hi
    movhi   r3, r1
    mov     r0, r3
    bx      lr
    .size   rt_char_offset, . - rt_char_offset

// substring(s, c0, c1): characters [c0, c1). A negative index (high word set) clamps to 0.
    FUNC silica_rt_string_substring
    ENTRY_SAVE
    bl      rt_str_check
    mov     r6, r0
    cmp     r3, #0
    it      ne
    movne   r2, #0
    cmp     r5, #0
    it      ne
    movne   r4, #0
    ldr     r0, [r6, #8]
    ldr     r1, [r6, #16]
    bl      rt_char_offset                  // r0 = byte offset of c0
    mov     r7, r0
    ldr     r0, [r6, #8]
    ldr     r1, [r6, #16]
    mov     r2, r4
    bl      rt_char_offset                  // r0 = byte offset of c1
    cmp     r0, r7
    bls.w   8f
    sub     r1, r0, r7
    ldr     r0, [r6, #8]
    add     r0, r0, r7
    bl      silica_rt_string_from_bytes
    b.w     9f
8:  MOV32   r0, silica_rt_empty_string
9:  movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_string_substring, . - silica_rt_string_substring

// substring_until_char(s, b0, ch): from byte b0 up to the first occurrence of the character whose
// UTF-8 bytes are packed in X2 (length in the top byte of the high word, bytes from the low end).
    FUNC silica_rt_string_substring_until_char
    ENTRY_SAVE
    bl      rt_str_check
    mov     r6, r0
    cmp     r3, #0
    it      ne
    movne   r2, #0
    ldr     r7, [r6, #16]
    cmp     r2, r7
    it      hi
    movhi   r2, r7
    mov     r8, r2                          // start
    lsr     r12, r5, #24                    // the character's byte count
    bic     r5, r5, #0xFF000000
    ldr     r0, [r6, #8]
    mov     r1, r8
1:  add     r2, r1, r12
    cmp     r2, r7
    bhi.w   3f                              // not found: to the end
    // compare the r12 bytes at r0 + r1 with the packed character (byte 0 in the low byte of r4)
    movw    r2, #0
2:  cmp     r2, r12
    bhs.w   4f                              // all matched
    add     r3, r0, r1
    ldrb    r3, [r3, r2]
    cmp     r2, #4
    blo.w   21f
    sub     lr, r2, #4
    lsl     lr, lr, #3
    lsr     lr, r5, lr
    b.w     22f
21: lsl     lr, r2, #3
    lsr     lr, r4, lr
22: uxtb    lr, lr
    cmp     r3, lr
    bne.w   23f
    add     r2, r2, #1
    b.w     2b
23: add     r1, r1, #1
    b.w     1b
3:  mov     r1, r7
4:  sub     r1, r1, r8
    add     r0, r0, r8
    bl      silica_rt_string_from_bytes
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_string_substring_until_char, . - silica_rt_string_substring_until_char
