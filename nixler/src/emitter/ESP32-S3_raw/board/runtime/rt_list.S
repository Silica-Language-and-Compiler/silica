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

// List routines for the bare-metal ESP32-S3 runtime: the L_list_*_helper bodies the macOS emitter
// pastes into each module (terms/prims/prims_list.silica), as callable routines. The data layout is
// the emitter's (list_implementation_design.md §4-§9), with 8-byte fields whose high word is 0:
//
//   handle (24 bytes; 0 = nil)      [0] length   [8] first data chunk   [16] byte cursor of the
//                                   first element inside that chunk's data area
//   data chunk (CDATA + 8 bytes)    [0, CDATA) element slots, filled back to front; [CDATA] next chunk
//
// CDATA and the slot size are compile-time constants of the element type; the emitter packs them
// into one word: slot | CDATA << 16. Handles are immutable once made; chunks are filled in place.
//
// Silica pair ABI (arguments in a2:a3, a4:a5, a6:a7; result a2:a3):
//   silica_rt_list_length(h)                 -> int64 (0 for nil)
//   silica_rt_list_tail(h, slot, cdata)      -> handle of the tail (0 for nil); h must not be nil
//   silica_rt_list_at(h, i, slot|cdata<<16)  -> address of element i; out of range aborts
//   silica_rt_list_prepend(packed, head, tail) -> new handle; packed = slot | cdata << 16 in the low
//                                   word, 1 in the high word when head is the address of an aggregate
//                                   to copy (slot bytes) rather than a scalar value

    .section .text.silica_rt_list, "ax"
    .literal_position

    .align  4
    .global silica_rt_list_length
    .type   silica_rt_list_length, @function
silica_rt_list_length:
    entry   a1, 32
    movi    a3, 0
    beqz    a2, 1f
    l32i    a2, a2, 0
1:  retw
    .size   silica_rt_list_length, . - silica_rt_list_length

    .align  4
    .global silica_rt_list_tail
    .type   silica_rt_list_tail, @function
silica_rt_list_tail:
    entry   a1, 32
    l32i    a3, a2, 0             // length
    l32i    a5, a2, 8             // chunk
    l32i    a7, a2, 16            // cursor
    add     a7, a7, a4            // cursor of the next element
    addi    a3, a3, -1
    beqz    a3, 8f
    bgeu    a7, a6, 2f            // past this chunk's data area
    movi    a10, 24
    call8   silica_rt_alloc
    s32i    a3, a10, 0
    s32i    a5, a10, 8
    s32i    a7, a10, 16
    mov     a2, a10
    movi    a3, 0
    retw
2:  add     a5, a5, a6
    l32i    a5, a5, 0             // next chunk
    beqz    a5, 8f
    movi    a10, 24
    call8   silica_rt_alloc
    s32i    a3, a10, 0
    s32i    a5, a10, 8            // cursor 0: the chunk is full from the front
    mov     a2, a10
    movi    a3, 0
    retw
8:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_list_tail, . - silica_rt_list_tail

    .align  4
    .global silica_rt_list_at
    .type   silica_rt_list_at, @function
silica_rt_list_at:
    entry   a1, 32
    beqz    a2, 9f
    bnez    a5, 9f                // index above 2^32
    l32i    a3, a2, 0
    bgeu    a4, a3, 9f            // index >= length
    l32i    a3, a2, 8             // chunk
    l32i    a2, a2, 16            // cursor
    extui   a7, a6, 0, 16         // slot bytes
    srli    a6, a6, 16            // chunk data bytes
1:  beqz    a4, 3f
    add     a2, a2, a7
    bltu    a2, a6, 2f
    add     a3, a3, a6
    l32i    a3, a3, 0             // next chunk
    movi    a2, 0
2:  addi    a4, a4, -1
    j       1b
3:  add     a2, a3, a2
    movi    a3, 0
    retw
9:  call8   silica_rt_list_index_failed   // ends the actor, or aborts in main (rt_console.S)
    retw
    .size   silica_rt_list_at, . - silica_rt_list_at

// Store the element for prepend: slot address in a9, slot bytes in a2, head in a4:a5, the aggregate
// flag at [a1 + 0]. Uses a8, a10-a13.
.macro STORE_ELEMENT
    l32i    a8, a1, 0
    beqz    a8, 71f
    mov     a10, a2               // aggregate: copy slot bytes from the address in a4
    mov     a11, a4
    mov     a12, a9
70: blti    a10, 1, 79f
    l32i    a13, a11, 0
    s32i    a13, a12, 0
    addi    a11, a11, 4
    addi    a12, a12, 4
    addi    a10, a10, -4
    j       70b
71: movi    a8, 8
    beq     a2, a8, 74f
    movi    a8, 4
    beq     a2, a8, 73f
    movi    a8, 2
    beq     a2, a8, 72f
    s8i     a4, a9, 0
    j       79f
72: s16i    a4, a9, 0
    j       79f
73: s32i    a4, a9, 0
    j       79f
74: s32i    a4, a9, 0
    s32i    a5, a9, 4
79:
.endm

// Frame 48: [0] aggregate flag, [4] unused, [8] new chunk; top 32 reserved.
// Chunk: [data: chunk data bytes][next chunk][claim]. The claim word is the lowest data offset
// already handed out; a prepend fills the slot in front of the old list's first element only when
// the old list owns that frontier (claim == its cursor), so two prepends onto one list no longer
// write into the same slot (the AArch64 L_list_prepend_helper in emitter/apple_silicon_mac/terms/
// prims/prims_list.silica has the same rule).
    .align  4
    .global silica_rt_list_prepend
    .type   silica_rt_list_prepend, @function
silica_rt_list_prepend:
    entry   a1, 48
    s32i    a3, a1, 0             // aggregate flag
    srli    a3, a2, 16            // a3 = chunk data bytes
    extui   a2, a2, 0, 16         // a2 = slot bytes
    beqz    a6, 5f                // nil tail: new chunk
    l32i    a8, a6, 16            // tail cursor
    beqz    a8, 5f                // no room in front of the tail's first element
    l32i    a9, a6, 8
    add     a11, a9, a3           // chunk + data bytes: [next chunk][claim]
    l32i    a10, a11, 8           // claim = lowest data offset already handed out
    bne     a10, a8, 8f           // another list already took the slot in front: copy-on-write
    sub     a10, a8, a2
    s32i    a10, a11, 8           // claim the slot
    add     a9, a9, a8
    sub     a9, a9, a2            // the slot just before the tail's first element
    STORE_ELEMENT
    movi    a10, 24
    call8   silica_rt_alloc
    l32i    a8, a6, 0
    addi    a8, a8, 1
    s32i    a8, a10, 0
    l32i    a8, a6, 8
    s32i    a8, a10, 8
    l32i    a8, a6, 16
    sub     a8, a8, a2
    s32i    a8, a10, 16
    mov     a2, a10
    movi    a3, 0
    retw
// Copy-on-write: copy the old list's part of its chunk (cursor .. chunk end) into a fresh chunk at
// the same offsets, inherit the old chunk's successor, and put the element just in front of it.
8:  addi    a10, a3, 16
    call8   silica_rt_alloc
    s32i    a10, a1, 8            // new chunk
    l32i    a9, a6, 8             // old chunk
    l32i    a8, a6, 16            // old cursor
    mov     a11, a8
81: bge     a11, a3, 82f
    add     a12, a9, a11
    l32i    a13, a12, 0
    add     a12, a10, a11
    s32i    a13, a12, 0
    addi    a11, a11, 4
    j       81b
82: add     a12, a9, a3
    l32i    a13, a12, 0           // old successor
    add     a12, a10, a3
    s32i    a13, a12, 0
    sub     a11, a8, a2           // the element's offset
    s32i    a11, a12, 8           // claim
    add     a9, a10, a11
    STORE_ELEMENT
    movi    a10, 24
    call8   silica_rt_alloc
    l32i    a8, a6, 0
    addi    a8, a8, 1
    s32i    a8, a10, 0
    l32i    a8, a1, 8
    s32i    a8, a10, 8
    l32i    a8, a6, 16
    sub     a8, a8, a2
    s32i    a8, a10, 16
    mov     a2, a10
    movi    a3, 0
    retw
5:  addi    a10, a3, 16           // a new chunk, the element in its last slot
    call8   silica_rt_alloc
    s32i    a10, a1, 8
    add     a9, a10, a3
    sub     a11, a3, a2
    s32i    a11, a9, 8            // claim = the element's offset
    sub     a9, a9, a2
    STORE_ELEMENT
    l32i    a8, a1, 8
    beqz    a6, 6f
    l32i    a9, a6, 8             // link to the tail's chunk
    add     a11, a8, a3
    s32i    a9, a11, 0
6:  movi    a10, 24
    call8   silica_rt_alloc
    movi    a8, 1
    beqz    a6, 7f
    l32i    a8, a6, 0
    addi    a8, a8, 1
7:  s32i    a8, a10, 0
    l32i    a8, a1, 8
    s32i    a8, a10, 8
    sub     a8, a3, a2
    s32i    a8, a10, 16
    mov     a2, a10
    movi    a3, 0
    retw
    .size   silica_rt_list_prepend, . - silica_rt_list_prepend
