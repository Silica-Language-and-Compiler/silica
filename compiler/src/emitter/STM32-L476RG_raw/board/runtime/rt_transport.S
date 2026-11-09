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

// Transport builtins for the bare-metal STM32L476RG runtime (transport_serialization_design.md
// §9.2; the ESP32-S3 port's rt_transport.S respelled): the six of them that read or build a string
// or walk a list. The emitter calls them (terms/prims/prims_transport.silica), as it calls rt_string.S
// and rt_list.S; the scalar transport prims (float bits, conversions, widths) are register work in
// the emitter and have no routine here.
//
// Layouts are the emitter's: a string is the 24-byte header of rt_string.S (+8 data, +16 length), a
// list the handle and data chunks of rt_list.S ([0] length, [8] first chunk, [16] cursor; 8-byte
// slots, two per 16-byte chunk data area, the next chunk at [chunk + 16]). The atom tables are the
// runtime unit's silica_rt_atom_name_count and silica_rt_atom_names (a word table of pointers to
// NUL-terminated lexemes, one per atom index; weak zero defaults below for a hand-written image); a
// lexeme carries its leading colon, the name on the wire has none, so both atom routines skip it.
//
// Silica pair ABI (X0 = r0:r1, X1 = r2:r3, X2 = r4:r5; result X0; every other register kept):
//   silica_rt_tr_byte_at(s, i)           -> int64   byte i of s; i outside [0, length) fails
//   silica_rt_tr_byte_slice(s, b0, b1)   -> string  bytes [b0, b1) of s; b1 > length or b0 > b1 fails
//   silica_rt_tr_bytes_of(xs)            -> string  the low byte of each int64 of xs
//   silica_rt_tr_join_bytes(parts)       -> string  the strings of parts, concatenated once
//   silica_rt_tr_atom_name(a)            -> string  the name of atom a; an index past the table fails
//   silica_rt_tr_atom_index(s)           -> int64   the atom whose name is s, or -1
// A fresh string is built in the running frame's dynamic part (rt_tr_string_alloc below and
// silica_rt_string_from_bytes of rt_string.S, through silica_rt_frame_alloc), so the emitted function
// that holds the prim has a frame floor (emitter_core frame_allocating_prim). An empty result is the
// shared silica_rt_empty_string. A bounds failure is the string's byte range failure
// (silica_rt_buf_bounds_failed, rt_console.S: the runtime abort, status 71), where the hosted helpers
// trap with BRK #1.

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

    .section .rodata.silica_rt_transport, "a", %progbits
    .balign 4
    .weak   silica_rt_atom_name_count
silica_rt_atom_name_count:
    .word   0
    .weak   silica_rt_atom_names
silica_rt_atom_names:
    .word   0

    .section .text.silica_rt_transport, "ax", %progbits

// rt_tr_string_alloc(r0 = n) -> r0 = a fresh string of n bytes (data at +24, zeroed, NUL after the
// last byte), as rt_string.S builds one. Internal (AAPCS).
    LFUNC rt_tr_string_alloc
    push    {r4, lr}
    mov     r4, r0
    add     r0, r0, #25
    bl      silica_rt_frame_alloc
    movw    r1, #0xFFFF
    movt    r1, #0xFFFF
    str     r1, [r0, #0]
    str     r1, [r0, #4]
    add     r1, r0, #24
    str     r1, [r0, #8]
    str     r4, [r0, #16]
    pop     {r4, pc}
    .size   rt_tr_string_alloc, . - rt_tr_string_alloc

    FUNC silica_rt_tr_byte_at
    ENTRY_SAVE
    cmp     r0, #0
    beq.w   9f
    cmp     r3, #0                          // index at or above 2^32, or negative
    bne.w   9f
    ldr     r6, [r0, #16]                   // length
    cmp     r2, r6
    bhs.w   9f
    ldr     r6, [r0, #8]                    // data
    ldrb    r0, [r6, r2]
    movw    r1, #0
    ENTRY_RET_X0
9:  bl      silica_rt_buf_bounds_failed
    .size   silica_rt_tr_byte_at, . - silica_rt_tr_byte_at

    FUNC silica_rt_tr_byte_slice
    ENTRY_SAVE
    cmp     r0, #0
    beq.w   9f
    cmp     r3, #0
    bne.w   9f
    cmp     r5, #0
    bne.w   9f
    ldr     r6, [r0, #16]                   // length
    cmp     r4, r6
    bhi.w   9f                              // end > length
    cmp     r2, r4
    bhi.w   9f                              // start > end
    subs    r6, r4, r2                      // n
    beq.w   8f
    ldr     r7, [r0, #8]
    add     r0, r7, r2                      // p = data + start
    mov     r1, r6
    bl      silica_rt_string_from_bytes
    movw    r1, #0
    ENTRY_RET_X0
8:  MOV32   r0, silica_rt_empty_string
    movw    r1, #0
    ENTRY_RET_X0
9:  bl      silica_rt_buf_bounds_failed
    .size   silica_rt_tr_byte_slice, . - silica_rt_tr_byte_slice

// r6 = the list handle (0 = nil), r4 = element count; the walk: r2 = chunk, r3 = cursor.
    FUNC silica_rt_tr_bytes_of
    ENTRY_SAVE
    movw    r4, #0
    cmp     r0, #0
    beq.w   1f
    ldr     r4, [r0, #0]                    // count
1:  cmp     r4, #0
    beq.w   8f
    mov     r6, r0
    mov     r0, r4
    bl      rt_tr_string_alloc
    mov     r5, r0                          // result
    add     r7, r0, #24                     // dst
    ldr     r2, [r6, #8]                    // chunk
    ldr     r3, [r6, #16]                   // cursor
2:  cmp     r4, #0
    beq.w   3f
    ldr     r8, [r2, r3]                    // the element's low word
    strb    r8, [r7], #1
    add     r3, r3, #8
    cmp     r3, #16
    blo.w   4f
    ldr     r2, [r2, #16]                   // next chunk
    movw    r3, #0
4:  sub     r4, r4, #1
    b.w     2b
3:  mov     r0, r5
    movw    r1, #0
    ENTRY_RET_X0
8:  MOV32   r0, silica_rt_empty_string
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_tr_bytes_of, . - silica_rt_tr_bytes_of

// Two walks over the parts: the byte total (r5), then the copy. A nil part contributes nothing.
    FUNC silica_rt_tr_join_bytes
    ENTRY_SAVE
    movw    r5, #0                          // total
    cmp     r0, #0
    beq.w   1f
    mov     r6, r0                          // the list
    ldr     r4, [r6, #0]                    // count
    ldr     r2, [r6, #8]                    // chunk
    ldr     r3, [r6, #16]                   // cursor
2:  cmp     r4, #0
    beq.w   1f
    ldr     r8, [r2, r3]                    // the part
    cmp     r8, #0
    beq.w   3f
    ldr     r8, [r8, #16]                   // its length
    add     r5, r5, r8
3:  add     r3, r3, #8
    cmp     r3, #16
    blo.w   4f
    ldr     r2, [r2, #16]
    movw    r3, #0
4:  sub     r4, r4, #1
    b.w     2b
1:  cmp     r5, #0
    beq.w   8f
    mov     r0, r5
    bl      rt_tr_string_alloc
    mov     r5, r0                          // result
    add     r7, r0, #24                     // dst
    ldr     r4, [r6, #0]
    ldr     r2, [r6, #8]
    ldr     r3, [r6, #16]
5:  cmp     r4, #0
    beq.w   7f
    ldr     r8, [r2, r3]                    // the part
    cmp     r8, #0
    beq.w   6f
    ldr     r12, [r8, #8]                   // src
    ldr     r8, [r8, #16]                   // n
51: cmp     r8, #0
    beq.w   6f
    ldrb    r10, [r12], #1
    strb    r10, [r7], #1
    sub     r8, r8, #1
    b.w     51b
6:  add     r3, r3, #8
    cmp     r3, #16
    blo.w   52f
    ldr     r2, [r2, #16]
    movw    r3, #0
52: sub     r4, r4, #1
    b.w     5b
7:  mov     r0, r5
    movw    r1, #0
    ENTRY_RET_X0
8:  MOV32   r0, silica_rt_empty_string
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_tr_join_bytes, . - silica_rt_tr_join_bytes

    FUNC silica_rt_tr_atom_name
    ENTRY_SAVE
    cmp     r1, #0
    bne.w   9f
    MOV32   r6, silica_rt_atom_name_count
    ldr     r6, [r6]
    cmp     r0, r6
    bhs.w   9f
    MOV32   r6, silica_rt_atom_names
    ldr     r4, [r6, r0, lsl #2]            // the lexeme
    ldrb    r6, [r4]
    cmp     r6, #58                         // ':'
    bne.w   1f
    add     r4, r4, #1
1:  movw    r5, #0                          // length
2:  ldrb    r6, [r4, r5]
    cmp     r6, #0
    beq.w   3f
    add     r5, r5, #1
    b.w     2b
3:  cmp     r5, #0
    beq.w   8f
    mov     r0, r4
    mov     r1, r5
    bl      silica_rt_string_from_bytes
    movw    r1, #0
    ENTRY_RET_X0
8:  MOV32   r0, silica_rt_empty_string
    movw    r1, #0
    ENTRY_RET_X0
9:  bl      silica_rt_buf_bounds_failed
    .size   silica_rt_tr_atom_name, . - silica_rt_tr_atom_name

// Linear over the table (the hosted helper's walk): r4 = the name's byte count, r5 = its bytes,
// r6 = the atom count, r7 = the table, r8 = the index tried.
    FUNC silica_rt_tr_atom_index
    ENTRY_SAVE
    cmp     r0, #0
    beq.w   9f
    ldr     r4, [r0, #16]
    ldr     r5, [r0, #8]
    MOV32   r6, silica_rt_atom_name_count
    ldr     r6, [r6]
    MOV32   r7, silica_rt_atom_names
    movw    r8, #0
1:  cmp     r8, r6
    bhs.w   9f
    ldr     r2, [r7, r8, lsl #2]            // the lexeme
    ldrb    r3, [r2]
    cmp     r3, #58
    bne.w   2f
    add     r2, r2, #1
2:  mov     r3, r5                          // p
    mov     r12, r4                         // bytes left
3:  cmp     r12, #0
    beq.w   4f
    ldrb    r10, [r2], #1
    ldrb    r11, [r3], #1
    cmp     r10, r11
    bne.w   5f
    cmp     r10, #0
    beq.w   5f                              // the lexeme ended inside the name
    sub     r12, r12, #1
    b.w     3b
4:  ldrb    r10, [r2]
    cmp     r10, #0
    bne.w   5f                              // the lexeme is longer
    mov     r0, r8
    movw    r1, #0
    ENTRY_RET_X0
5:  add     r8, r8, #1
    b.w     1b
9:  movw    r0, #0xFFFF
    movt    r0, #0xFFFF
    mov     r1, r0
    ENTRY_RET_X0
    .size   silica_rt_tr_atom_index, . - silica_rt_tr_atom_index
