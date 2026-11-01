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

// String routines for the bare-metal ESP32-S3 runtime. On macOS these are the L_*_helper bodies the
// emitter pastes into every module (terms/string_*_mmap_nomte.silica); here the emitter calls them.
//
// A Silica string is a 24-byte header followed (usually) by its bytes: the layout the AArch64 helpers
// and the string literal pool agree on, kept with 8-byte fields so emitted loads at +8 and +16 work:
//     +0   tag       -1 (two words, both 0xFFFFFFFF)
//     +8   data      pointer to the UTF-8 bytes, NUL-terminated (low word; the high word is 0)
//     +16  length    byte count (low word; the high word is 0)
// A tag other than -1 is a runtime fault (the host traps with BRK); here it aborts (status 134).
//
// Silica pair ABI: argument n is a 64-bit pair (a2:a3, a4:a5, a6:a7), result in a2:a3. Every routine
// only uses the low word of a pointer or count; a negative index (high word < 0) clamps to 0.
//
//   silica_rt_string_length_bytes(s)            -> int64
//   silica_rt_string_length_chars(s)            -> int64   UTF-8 scalar count; a byte outside a
//                                                  well-formed sequence counts as one character (spec §5.3.1)
//   silica_rt_string_concat(a, b)               -> string  an empty operand returns the other
//   silica_rt_string_eq(a, b)                   -> 0/1
//   silica_rt_string_cmp(a, b)                  -> -1/0/1  unsigned bytewise, shorter prefix first
//   silica_rt_string_starts_with(h, n)          -> 0/1
//   silica_rt_string_ends_with(h, n)            -> 0/1
//   silica_rt_string_contains(h, n)             -> 0/1
//   silica_rt_string_substring(s, c0, c1)       -> string  character indices [c0, c1), clamped
//   silica_rt_string_substring_until_char(s, b0, ch) -> string  from byte b0 up to (not including)
//                                                  the first occurrence of ch (len<<56 | packed bytes)
//   silica_rt_string_from_bytes(p, n)           -> string  fresh string holding n bytes from p
//   silica_rt_empty_string                      the shared empty string
//
// Register use: a2-a7 hold arguments and state (they survive CALL8), a8-a15 are temporaries that any
// CALL8 clobbers. Nothing here calls out except silica_rt_alloc and silica_rt_abort_not_a_string.

    .section .text.silica_rt_string, "ax"
    .literal_position

// Branch to the fault path when the word at [\r] is not -1.
.macro CHECK_TAG r, t
    l32i    \t, \r, 0
    addi    \t, \t, 1
    bnez    \t, silica_rt_string_bad
.endm

// idx += length of the UTF-8 sequence that starts at base+idx, clamped to len-idx. Uses a8-a10.
// Lead byte classes: < 0xC2 one byte (ASCII, or a stray continuation byte counted as one),
// < 0xE0 two, < 0xF0 three, < 0xF8 four, else one.
.macro UTF8_ADVANCE base, idx, len
    add     a8, \base, \idx
    l8ui    a8, a8, 0
    movi    a9, 1
    movi    a10, 0xC2
    bltu    a8, a10, 62f
    movi    a9, 2
    movi    a10, 0xE0
    bltu    a8, a10, 62f
    movi    a9, 3
    movi    a10, 0xF0
    bltu    a8, a10, 62f
    movi    a9, 4
    movi    a10, 0xF8
    bltu    a8, a10, 62f
    movi    a9, 1
62: sub     a10, \len, \idx
    bgeu    a10, a9, 63f
    mov     a9, a10
63: add     \idx, \idx, a9
.endm

// Copy \n bytes from \src to \dst; all three advance. Uses a8.
.macro COPY_BYTES src, dst, n
61: beqz    \n, 62f
    l8ui    a8, \src, 0
    s8i     a8, \dst, 0
    addi    \src, \src, 1
    addi    \dst, \dst, 1
    addi    \n, \n, -1
    j       61b
62:
.endm

    .align  4
silica_rt_string_bad:
    call8   silica_rt_abort_not_a_string
1:  j       1b

// silica_rt_string_alloc(n): a fresh string of n bytes (data at +24, zeroed, NUL after the last byte).
// Local: a2 = byte count, result a2 = string.
    .align  4
    .type   silica_rt_string_alloc, @function
silica_rt_string_alloc:
    entry   a1, 32
    addi    a10, a2, 25
    call8   silica_rt_alloc
    movi    a8, -1
    s32i    a8, a10, 0
    s32i    a8, a10, 4
    addi    a8, a10, 24
    s32i    a8, a10, 8
    s32i    a2, a10, 16
    mov     a2, a10
    movi    a3, 0
    retw
    .size   silica_rt_string_alloc, . - silica_rt_string_alloc

    .align  4
    .global silica_rt_string_from_bytes
    .type   silica_rt_string_from_bytes, @function
silica_rt_string_from_bytes:
    entry   a1, 32
    mov     a10, a4
    call8   silica_rt_string_alloc
    mov     a5, a10               // result
    addi    a6, a10, 24           // dst
    mov     a7, a4                // n
    COPY_BYTES a2, a6, a7
    mov     a2, a5
    movi    a3, 0
    retw
    .size   silica_rt_string_from_bytes, . - silica_rt_string_from_bytes

    .align  4
    .global silica_rt_string_length_bytes
    .type   silica_rt_string_length_bytes, @function
silica_rt_string_length_bytes:
    entry   a1, 32
    movi    a3, 0
    beqz    a2, 1f
    CHECK_TAG a2, a8
    l32i    a2, a2, 16
1:  retw
    .size   silica_rt_string_length_bytes, . - silica_rt_string_length_bytes

    .align  4
    .global silica_rt_string_length_chars
    .type   silica_rt_string_length_chars, @function
silica_rt_string_length_chars:
    entry   a1, 32
    movi    a3, 0
    beqz    a2, 9f
    CHECK_TAG a2, a8
    l32i    a4, a2, 8             // p (cursor)
    l32i    a5, a2, 16
    add     a5, a4, a5            // end
    movi    a2, 0                 // char count
1:  bgeu    a4, a5, 9f
    l8ui    a8, a4, 0
    addi    a2, a2, 1
    addi    a4, a4, 1
    movi    a10, 0x80
    bltu    a8, a10, 1b           // < 0x80: single byte, already advanced
    movi    a9, 0xE0
    and     a10, a8, a9
    movi    a9, 0xC0
    beq     a10, a9, 2f           // 110xxxxx: 2-byte lead
    movi    a9, 0xF0
    and     a10, a8, a9
    movi    a9, 0xE0
    beq     a10, a9, 3f           // 1110xxxx: 3-byte lead
    movi    a9, 0xF8
    and     a10, a8, a9
    movi    a9, 0xF0
    beq     a10, a9, 4f           // 11110xxx: 4-byte lead
    j       1b                    // stray continuation or invalid lead byte: one character
2:  addi    a4, a4, 1
    j       1b
3:  addi    a4, a4, 2
    j       1b
4:  addi    a4, a4, 3
    j       1b
9:  retw
    .size   silica_rt_string_length_chars, . - silica_rt_string_length_chars

    .align  4
    .global silica_rt_string_concat
    .type   silica_rt_string_concat, @function
silica_rt_string_concat:
    entry   a1, 32
    CHECK_TAG a2, a8
    CHECK_TAG a4, a8
    l32i    a6, a2, 16            // la
    l32i    a7, a4, 16            // lb
    beqz    a6, 8f
    beqz    a7, 9f
    add     a10, a6, a7
    call8   silica_rt_string_alloc
    mov     a5, a10               // result
    addi    a3, a10, 24           // dst
    l32i    a2, a2, 8             // src a
    COPY_BYTES a2, a3, a6
    l32i    a4, a4, 8             // src b
    COPY_BYTES a4, a3, a7
    mov     a2, a5
    movi    a3, 0
    retw
8:  mov     a2, a4                // a is empty: b
    movi    a3, 0
    retw
9:  movi    a3, 0                 // b is empty: a
    retw
    .size   silica_rt_string_concat, . - silica_rt_string_concat

    .align  4
    .global silica_rt_string_eq
    .type   silica_rt_string_eq, @function
silica_rt_string_eq:
    entry   a1, 32
    beqz    a2, 7f
    beqz    a4, 8f
    CHECK_TAG a2, a8
    CHECK_TAG a4, a8
    l32i    a6, a2, 16
    l32i    a7, a4, 16
    bne     a6, a7, 8f
    l32i    a2, a2, 8
    l32i    a4, a4, 8
1:  beqz    a6, 9f
    l8ui    a8, a2, 0
    l8ui    a9, a4, 0
    bne     a8, a9, 8f
    addi    a2, a2, 1
    addi    a4, a4, 1
    addi    a6, a6, -1
    j       1b
7:  beqz    a4, 9f                // both null: equal
8:  movi    a2, 0
    movi    a3, 0
    retw
9:  movi    a2, 1
    movi    a3, 0
    retw
    .size   silica_rt_string_eq, . - silica_rt_string_eq

    .align  4
    .global silica_rt_string_cmp
    .type   silica_rt_string_cmp, @function
silica_rt_string_cmp:
    entry   a1, 32
    beqz    a2, 6f
    beqz    a4, 8f
    CHECK_TAG a2, a8
    CHECK_TAG a4, a8
    l32i    a6, a2, 16            // la
    l32i    a7, a4, 16            // lb
    mov     a5, a6                // min(la, lb)
    bgeu    a7, a6, 1f
    mov     a5, a7
1:  l32i    a2, a2, 8
    l32i    a4, a4, 8
2:  beqz    a5, 3f
    l8ui    a8, a2, 0
    l8ui    a9, a4, 0
    bltu    a8, a9, 7f
    bltu    a9, a8, 8f
    addi    a2, a2, 1
    addi    a4, a4, 1
    addi    a5, a5, -1
    j       2b
3:  beq     a6, a7, 9f            // common prefix equal: shorter first
    bltu    a6, a7, 7f
    j       8f
6:  beqz    a4, 9f                // both null: equal; null < anything
7:  movi    a2, -1
    movi    a3, -1
    retw
8:  movi    a2, 1
    movi    a3, 0
    retw
9:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_string_cmp, . - silica_rt_string_cmp

// Shared entry for the three predicates: a2 = haystack, a4 = needle. On return a2 = haystack data,
// a4 = needle data, a6 = haystack length, a7 = needle length; a null operand or a needle longer than the
// haystack jumps to the false exit, an empty needle to the true exit (these labels are the callers').
.macro PRED_PROLOGUE
    beqz    a2, 8f
    beqz    a4, 8f
    CHECK_TAG a2, a8
    CHECK_TAG a4, a8
    l32i    a6, a2, 16
    l32i    a7, a4, 16
    l32i    a2, a2, 8
    l32i    a4, a4, 8
    beqz    a7, 9f
    bltu    a6, a7, 8f
.endm

.macro PRED_EPILOGUE
8:  movi    a2, 0
    movi    a3, 0
    retw
9:  movi    a2, 1
    movi    a3, 0
    retw
.endm

// Compare a7 bytes at a2 and a4; falls through when equal, jumps to 8f on a difference.
.macro MATCH_BYTES
1:  beqz    a7, 9f
    l8ui    a8, a2, 0
    l8ui    a9, a4, 0
    bne     a8, a9, 8f
    addi    a2, a2, 1
    addi    a4, a4, 1
    addi    a7, a7, -1
    j       1b
.endm

    .align  4
    .global silica_rt_string_starts_with
    .type   silica_rt_string_starts_with, @function
silica_rt_string_starts_with:
    entry   a1, 32
    PRED_PROLOGUE
    MATCH_BYTES
    PRED_EPILOGUE
    .size   silica_rt_string_starts_with, . - silica_rt_string_starts_with

    .align  4
    .global silica_rt_string_ends_with
    .type   silica_rt_string_ends_with, @function
silica_rt_string_ends_with:
    entry   a1, 32
    PRED_PROLOGUE
    sub     a8, a6, a7
    add     a2, a2, a8            // haystack tail of needle length
    MATCH_BYTES
    PRED_EPILOGUE
    .size   silica_rt_string_ends_with, . - silica_rt_string_ends_with

    .align  4
    .global silica_rt_string_contains
    .type   silica_rt_string_contains, @function
silica_rt_string_contains:
    entry   a1, 32
    PRED_PROLOGUE
    sub     a5, a6, a7
    addi    a5, a5, 1             // candidate start positions
    mov     a3, a2
2:  beqz    a5, 8f
    mov     a8, a3
    mov     a9, a4
    mov     a10, a7
3:  beqz    a10, 9f
    l8ui    a11, a8, 0
    l8ui    a12, a9, 0
    bne     a11, a12, 4f
    addi    a8, a8, 1
    addi    a9, a9, 1
    addi    a10, a10, -1
    j       3b
4:  addi    a3, a3, 1
    addi    a5, a5, -1
    j       2b
    PRED_EPILOGUE
    .size   silica_rt_string_contains, . - silica_rt_string_contains

// substring(s, c0, c1): characters [c0, c1). Byte offsets are found by walking the UTF-8 sequences from
// the start; both indices clamp to the string. An empty result is the shared empty string.
    .align  4
    .global silica_rt_string_substring
    .type   silica_rt_string_substring, @function
silica_rt_string_substring:
    entry   a1, 32
    bgez    a5, 1f
    movi    a4, 0
1:  bgez    a7, 2f
    movi    a6, 0
2:  CHECK_TAG a2, a8
    l32i    a3, a2, 8             // base
    l32i    a5, a2, 16            // len
    bgeu    a4, a6, 8f            // c0 >= c1
    movi    a7, 0                 // byte index
    movi    a2, 0                 // char index
3:  bgeu    a2, a4, 4f            // find the start
    bgeu    a7, a5, 4f
    UTF8_ADVANCE a3, a7, a5
    addi    a2, a2, 1
    j       3b
4:  mov     a4, a7                // start byte
5:  bgeu    a2, a6, 6f            // find the end
    bgeu    a7, a5, 6f
    UTF8_ADVANCE a3, a7, a5
    addi    a2, a2, 1
    j       5b
6:  sub     a6, a7, a4            // byte count
    beqz    a6, 8f
    add     a10, a3, a4
    mov     a12, a6
    call8   silica_rt_string_from_bytes
    mov     a2, a10
    movi    a3, 0
    retw
8:  movi    a2, silica_rt_empty_string
    movi    a3, 0
    retw
    .size   silica_rt_string_substring, . - silica_rt_string_substring

// substring_until_char(s, b0, ch): bytes from b0 up to the first occurrence of the encoded character
// (its byte length in bits 56..63, its bytes packed little-endian in bits 0..31), or to the end.
    .align  4
    .global silica_rt_string_substring_until_char
    .type   silica_rt_string_substring_until_char, @function
silica_rt_string_substring_until_char:
    entry   a1, 32
    bgez    a5, 1f
    movi    a4, 0
1:  CHECK_TAG a2, a8
    l32i    a3, a2, 8             // base
    l32i    a5, a2, 16            // len
    bltu    a4, a5, 2f
    mov     a4, a5                // start clamps to len
2:  srli    a7, a7, 24            // character byte length
    bnez    a7, 3f
    movi    a7, 1
3:  mov     a2, a4                // scan index
4:  bgeu    a2, a5, 7f
    add     a8, a2, a7
    bltu    a5, a8, 5f            // fewer than n bytes left: no match here
    add     a8, a3, a2
    mov     a9, a6
    mov     a10, a7
41: beqz    a10, 7f               // all n bytes matched
    l8ui    a11, a8, 0
    extui   a12, a9, 0, 8
    bne     a11, a12, 5f
    addi    a8, a8, 1
    srli    a9, a9, 8
    addi    a10, a10, -1
    j       41b
5:  UTF8_ADVANCE a3, a2, a5
    j       4b
7:  sub     a6, a2, a4
    beqz    a6, 8f
    add     a10, a3, a4
    mov     a12, a6
    call8   silica_rt_string_from_bytes
    mov     a2, a10
    movi    a3, 0
    retw
8:  movi    a2, silica_rt_empty_string
    movi    a3, 0
    retw
    .size   silica_rt_string_substring_until_char, . - silica_rt_string_substring_until_char

    .section .rodata.silica_rt_string, "a"
    .p2align 3
    .global silica_rt_empty_string
silica_rt_empty_string:
    .word   -1, -1
    .word   silica_rt_empty_string_bytes, 0
    .word   0, 0
silica_rt_empty_string_bytes:
    .byte   0
