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

// List routines for the bare-metal STM32L476RG runtime: the L_list_*_helper bodies the macOS emitter
// pastes into each module (terms/prims/prims_list.silica), as callable routines. The data layout is
// the emitter's (list_implementation_design.md §4-§9), with 8-byte fields whose high word is 0:
//
//   handle (24 bytes; 0 = nil)      [0] length   [8] first data chunk   [16] byte cursor of the
//                                   first element inside that chunk's data area
//   data chunk (CDATA + 16 bytes)   [0, CDATA) element slots, filled back to front; [CDATA] next
//                                   chunk; [CDATA + 8] claim: the lowest data offset handed out
//
// CDATA and the slot size are compile-time constants of the element type; the emitter packs them
// into one word: slot | CDATA << 16. Handles are immutable once made; chunks are filled in place.
//
// Silica pair ABI (X0 = r0:r1, X1 = r2:r3, X2 = r4:r5; result X0; every other register kept):
//   silica_rt_list_length(h)                 -> int64 (0 for nil)
//   silica_rt_list_tail(h, slot, cdata)      -> handle of the tail (0 for nil); h must not be nil
//   silica_rt_list_at(h, i, slot|cdata<<16)  -> address of element i; out of range aborts
//   silica_rt_list_prepend(packed, head, tail) -> new handle; packed = slot | cdata << 16 in the low
//                                   word, 1 in the high word when head is the address of an aggregate
//                                   to copy (slot bytes) rather than a scalar value
// Handles and chunks are built in the running frame's dynamic part (silica_rt_frame_alloc).

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

    .section .text.silica_rt_list, "ax", %progbits

    FUNC silica_rt_list_length
    ENTRY_SAVE
    movw    r1, #0
    cmp     r0, #0
    beq.w   1f
    ldr     r0, [r0, #0]
1:  ENTRY_RET_X0
    .size   silica_rt_list_length, . - silica_rt_list_length

// tail(h, slot, cdata): a fresh handle one element on; the empty tail is nil.
    FUNC silica_rt_list_tail
    ENTRY_SAVE
    ldr     r6, [r0, #0]                    // length
    ldr     r7, [r0, #8]                    // chunk
    ldr     r8, [r0, #16]                   // cursor
    add     r8, r8, r2                      // cursor of the next element
    subs    r6, r6, #1
    beq.w   8f
    cmp     r8, r4
    blo.w   1f
    ldr     r7, [r7, r4]                    // the next chunk, from its front
    movw    r8, #0
1:  movw    r0, #24
    bl      silica_rt_frame_alloc
    str     r6, [r0, #0]
    str     r7, [r0, #8]
    str     r8, [r0, #16]
    movw    r1, #0
    ENTRY_RET_X0
8:  movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_list_tail, . - silica_rt_list_tail

// at(h, i, packed) -> the element's address.
    FUNC silica_rt_list_at
    ENTRY_SAVE
    cmp     r0, #0
    beq.w   8f
    cmp     r3, #0
    bne.w   8f                              // a negative or huge index
    ldr     r6, [r0, #0]
    cmp     r2, r6
    bhs.w   8f
    uxth    r6, r4                          // slot
    lsr     r7, r4, #16                     // cdata
    ldr     r8, [r0, #8]                    // chunk
    ldr     r1, [r0, #16]                   // cursor
    mla     r1, r2, r6, r1                  // cursor + i * slot (a byte offset across chunks)
1:  cmp     r1, r7
    blo.w   2f
    sub     r1, r1, r7
    ldr     r8, [r8, r7]
    b.w     1b
2:  add     r0, r8, r1
    movw    r1, #0
    ENTRY_RET_X0
8:  bl      silica_rt_list_index_failed     // ends the actor, or aborts in main (rt_failure.S)
    .size   silica_rt_list_at, . - silica_rt_list_at

// prepend(packed, head, tail) -> handle.
    FUNC silica_rt_list_prepend
    ENTRY_SAVE
    mov     r6, r1                          // aggregate flag
    lsr     r7, r0, #16                     // r7 = chunk data bytes
    uxth    r8, r0                          // r8 = slot bytes
    cmp     r4, #0
    beq.w   5f                              // nil tail: new chunk
    ldr     r0, [r4, #16]                   // tail cursor
    cmp     r0, #0
    beq.w   5f                              // no room in front of the tail's first element
    ldr     r0, [r4, #8]                    // in place only on this context's auxiliary stack (chunk 15)
    bl      silica_rt_in_aux_chain
    cmp     r0, #0
    beq.w   8f
    ldr     r0, [r4, #16]
    ldr     r1, [r4, #8]
    add     r12, r1, r7                     // chunk + data bytes: [next chunk][claim]
    ldr     r3, [r12, #8]                   // claim = lowest data offset already handed out
    cmp     r3, r0
    bne.w   8f                              // another list already took the slot in front: copy
    sub     r3, r0, r8
    str     r3, [r12, #8]                   // claim the slot
    add     r1, r1, r0
    sub     r1, r1, r8                      // the slot just before the tail's first element
    bl      rt_list_store_element
    movw    r0, #24
    bl      silica_rt_frame_alloc
    ldr     r1, [r4, #0]
    add     r1, r1, #1
    str     r1, [r0, #0]
    ldr     r1, [r4, #8]
    str     r1, [r0, #8]
    ldr     r1, [r4, #16]
    sub     r1, r1, r8
    str     r1, [r0, #16]
    movw    r1, #0
    ENTRY_RET_X0
// Copy-on-write: copy the old list's part of its chunk (cursor .. chunk end) into a fresh chunk at
// the same offsets, inherit the old chunk's successor, and put the element just in front of it.
8:  add     r0, r7, #16
    bl      silica_rt_frame_alloc
    mov     r5, r0                          // new chunk (r5 = X2 hi is dead: the tail's hi word)
    ldr     r1, [r4, #8]                    // old chunk
    ldr     r2, [r4, #16]                   // old cursor
    mov     r3, r2
81: cmp     r3, r7
    bhs.w   82f
    ldr     r12, [r1, r3]
    str     r12, [r5, r3]
    add     r3, r3, #4
    b.w     81b
82: ldr     r12, [r1, r7]                   // the successor
    str     r12, [r5, r7]
    sub     r3, r2, r8
    str     r3, [r5, r7, lsl #0]            // (placeholder, overwritten below)
    add     r12, r5, r7
    str     r3, [r12, #8]                   // claim
    ldr     r12, [r1, r7]
    str     r12, [r5, r7]
    add     r1, r5, r3                      // the slot in front
    bl      rt_list_store_element
    movw    r0, #24
    bl      silica_rt_frame_alloc
    ldr     r1, [r4, #0]
    add     r1, r1, #1
    str     r1, [r0, #0]
    str     r5, [r0, #8]
    ldr     r1, [r4, #16]
    sub     r1, r1, r8
    str     r1, [r0, #16]
    movw    r1, #0
    ENTRY_RET_X0
// Nil tail, or a tail whose chunk is full in front: a fresh chunk with the element at its end.
5:  add     r0, r7, #16
    bl      silica_rt_frame_alloc
    mov     r5, r0
    sub     r3, r7, r8                      // the last slot
    add     r12, r5, r7
    str     r3, [r12, #8]                   // claim
    cmp     r4, #0
    beq.w   51f
    ldr     r12, [r4, #8]                   // the old first chunk becomes the successor
    str     r12, [r5, r7]
51: add     r1, r5, r3
    bl      rt_list_store_element
    movw    r0, #24
    bl      silica_rt_frame_alloc
    movw    r1, #1
    cmp     r4, #0
    beq.w   52f
    ldr     r1, [r4, #0]
    add     r1, r1, #1
52: str     r1, [r0, #0]
    str     r5, [r0, #8]
    sub     r3, r7, r8
    str     r3, [r0, #16]
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_list_prepend, . - silica_rt_list_prepend

// rt_list_store_element(r1 = slot address; r6 = aggregate flag, r8 = slot bytes): the head value X1,
// reloaded from the entry's saved r2:r3 slots (sp + 8 / 12 under ENTRY_SAVE, which bl leaves in
// place: an AAPCS call such as silica_rt_frame_alloc or silica_rt_in_aux_chain has clobbered the
// registers by now), stored as a scalar's two words, or the aggregate's bytes copied from the address
// it holds. A scalar is stored at its slot's width, as the ESP32-S3's STORE_ELEMENT does: two words
// for an 8-byte slot, one word, a halfword or a byte for the narrow ones (a 4-byte slot written as two
// words overwrote the element behind it, and the chunk's next word for the last slot: a List[uint32]
// longer than one chunk faulted at its fifth element). Clobbers r0, r2, r3, r12; keeps r1.
    LFUNC rt_list_store_element
    ldr     r2, [sp, #8]                    // X1 lo
    ldr     r3, [sp, #12]                   // X1 hi
    cmp     r6, #0
    bne.w   1f
    cmp     r8, #8
    bhs.w   4f
    cmp     r8, #4
    beq.w   5f
    cmp     r8, #2
    beq.w   6f
    strb    r2, [r1, #0]
    bx      lr
6:  strh    r2, [r1, #0]
    bx      lr
5:  str     r2, [r1, #0]
    bx      lr
4:  str     r2, [r1, #0]
    str     r3, [r1, #4]
    bx      lr
1:  movw    r0, #0
2:  cmp     r0, r8
    bhs.w   3f
    ldr     r12, [r2, r0]
    str     r12, [r1, r0]
    add     r0, r0, #4
    b.w     2b
3:  bx      lr
    .size   rt_list_store_element, . - rt_list_store_element
