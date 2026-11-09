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

// The frame's dynamic part on the STM32L476RG (compiler/design_documents/chunk15_stack_memory_design.md
// §2.6, §3.1-§3.5; the ESP32-S3 port's rt_frame.S respelled for Thumb-2: shared/arm_frame.silica).
//
// The emitter's SP (VRG_VSP) runs on the auxiliary stack, a chain of heap chunks (rt_actors.S
// "Growable stacks"); the fixed part of a frame is the sp frame FRAME_ENTER allocates. The DYNAMIC part
// of a frame -- frame allocations, adopted and evacuated results -- lies on the auxiliary stack between
// the frame's FLOOR (VRG_FLOOR; saved with SP at a context switch, ACB_CTX_FLOOR) and its transient
// pushes [SP, FLOOR) (argument slabs, operand parks; addressed only relative to SP).
//
// The invariant every routine here keeps: the transient part is contiguous and lies in the current
// auxiliary chunk. Either FLOOR is in the current chunk and the transient part is [SP, FLOOR), or SP is
// in a continuation chunk this file appended (CH_MIRROR 0, CH_RET = the FLOOR it continues) and the
// transient part is [SP, CH_TOP) of that chunk (rt_transient_len).
//
// Entries (bl from emitted code; every register but r10, r11, lr is kept, ENTRY_SAVE / ENTRY_RET):
//   silica_rt_dyn_alloc    VRG_ARG = n (a multiple of 16) -> VRG_ARG = a block of n bytes directly under
//                          the floor; the transient part moves down under it and the floor goes down by n.
//                          A block that does not fit the chunk takes a fresh chunk (the transient part
//                          moving with it); main's auxiliary stack does not grow.
//   silica_rt_adopt        VRG_ARG = the pre-call SP p: [SP, p), the callee's frames and dynamic part,
//                          becomes the bottom of this frame's dynamic part (design §3.3 (a)); the
//                          transient part [p, FLOOR) moves below SP. Nothing left (SP == p): SP stays.
//   silica_rt_ev_frame     NOT PORTED YET: the copier (rt_state.S) is the ESP32-S3 port's next piece on
//                          this board; a program that reaches it ends with the runtime abort
//                          "runtime entry not yet ported" (status 71).
// Internal (AAPCS): silica_rt_frame_alloc(r0 = bytes) -> r0 zeroed block in the running frame's dynamic
// part; silica_rt_in_aux_chain(r0 = ptr) -> r0 0/1; silica_rt_aux_chunk_append(r0 = acb, r1 = after,
// r2 = bytes, r3 = the SP a restore to pops it) -> r0 chunk, 0 (heap exhausted) or -1 (reservation);
// silica_rt_aux_publish_chunk(r0 = chunk).

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

    .section .text.silica_rt_frame, "ax", %progbits

// rt_transient_len(r0 = sp, r1 = floor, r2 = the chunk sp is in) -> r0 = the transient bytes above sp:
// floor - sp when floor lies in the chunk ([limit, top]), else top - sp (a continuation chunk).
    LFUNC rt_transient_len
    ldr     r3, [r2, #CH_LIMIT]
    ldr     r12, [r2, #CH_TOP]
    cmp     r1, r3
    blo.w   1f
    cmp     r12, r1
    blo.w   1f
    sub     r0, r1, r0
    bx      lr
1:  sub     r0, r12, r0
    bx      lr
    .size   rt_transient_len, . - rt_transient_len

// rt_move_down(r0 = src, r1 = dst, r2 = bytes): copies [src, src + bytes) to [dst, dst + bytes), dst <=
// src (ascending copy, safe for an overlap in that direction). Word granularity: every SP and floor is
// 16-byte aligned and the transient part a multiple of 16.
    LFUNC rt_move_down
    cmp     r2, #0
    beq.w   2f
    add     r2, r0, r2
1:  ldr     r3, [r0], #4
    str     r3, [r1], #4
    cmp     r0, r2
    blo.w   1b
2:  bx      lr
    .size   rt_move_down, . - rt_move_down

// rt_move_up(r0 = src, r1 = dst, r2 = bytes): dst >= src (descending copy).
    LFUNC rt_move_up
    cmp     r2, #0
    beq.w   2f
    add     r3, r0, r2
    add     r12, r1, r2
1:  ldr     r2, [r3, #-4]!
    str     r2, [r12, #-4]!
    cmp     r0, r3
    blo.w   1b
2:  bx      lr
    .size   rt_move_up, . - rt_move_up

// silica_rt_aux_chunk_append(r0 = acb, r1 = after, r2 = bytes needed, r3 = ret SP) -> r0 chunk / 0 / -1.
    FUNC silica_rt_aux_chunk_append
    push    {r4, lr}
    mov     r4, r3
    add     r2, r2, #16
    movw    r3, #1                          // kind 1: an auxiliary chunk (rt_actors.S silica_rt_chunk_next)
    bl      silica_rt_chunk_next
    cmp     r0, #0
    beq.w   9f
    adds    r1, r0, #1
    beq.w   9f                              // -1
    str     r4, [r0, #CH_RET]
    movw    r1, #0
    str     r1, [r0, #CH_MIRROR]
9:  pop     {r4, pc}
    .size   silica_rt_aux_chunk_append, . - silica_rt_aux_chunk_append

// silica_rt_aux_publish_chunk(r0 = chunk): the running context moves to this auxiliary chunk
// (VRG_ACHUNK, the limit, the top a release pops at). SP and the floor are the caller's.
    FUNC silica_rt_aux_publish_chunk
    str     r0, [r9, #VRG_ACHUNK]
    ldr     r1, [r0, #CH_LIMIT]
    str     r1, [r9, #VRG_ALIMIT]
    ldr     r1, [r0, #CH_TOP]
    ldr     r2, [r0, #CH_MIRROR]
    sub     r1, r1, r2
    str     r1, [r9, #VRG_ATOP]
    bx      lr
    .size   silica_rt_aux_publish_chunk, . - silica_rt_aux_publish_chunk

// silica_rt_dyn_alloc: see the head of the file.
    FUNC silica_rt_dyn_alloc
    ENTRY_SAVE
    ldr     r4, [r9, #VRG_ARG]              // r4 = n
    ldr     r5, [r9, #VRG_VSP]              // r5 = sp
    ldr     r6, [r9, #VRG_FLOOR]            // r6 = floor
    ldr     r7, [r9, #VRG_ACHUNK]           // r7 = chunk
    mov     r0, r5
    mov     r1, r6
    mov     r2, r7
    bl      rt_transient_len
    mov     r8, r0                          // r8 = len
    // the floor in this chunk and room for the block and the moved transient part above the limit
    ldr     r0, [r7, #CH_LIMIT]
    ldr     r1, [r7, #CH_TOP]
    cmp     r6, r0
    blo.w   2f
    cmp     r1, r6
    blo.w   2f
    sub     r3, r6, r4                      // r3 = block
    sub     r1, r3, r8
    cmp     r1, r0
    blo.w   2f
    b.w     3f
2:  // a fresh chunk after this one: the block at its top, the transient part under it
    bl      silica_rt_current
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #0
    bne.w   8f                              // main: no growth
    mov     r1, r7
    add     r2, r4, r8
    mov     r3, r5                          // a restore to the SP of entry (or above) pops the chunk
    bl      silica_rt_aux_chunk_append
    cmp     r0, #0
    beq.w   8f
    adds    r1, r0, #1
    beq.w   8f
    mov     r7, r0
    bl      silica_rt_aux_publish_chunk
    ldr     r3, [r7, #CH_TOP]
    sub     r3, r3, r4
    bic     r3, r3, #15                     // r3 = block (16-aligned under the top)
3:  // the transient part [sp, sp + len) goes to [block - len, block)
    mov     r0, r5
    sub     r1, r3, r8
    mov     r2, r8
    push    {r3}
    bl      rt_move_down
    pop     {r3}
    sub     r1, r3, r8
    str     r1, [r9, #VRG_VSP]
    str     r3, [r9, #VRG_FLOOR]
    str     r3, [r9, #VRG_ARG]
    ENTRY_RET
8:  bl      silica_rt_region_alloc_failed
9:  b.w     9b
    .size   silica_rt_dyn_alloc, . - silica_rt_dyn_alloc

// silica_rt_adopt: see the head of the file. [SP, p) is adopted: the transient part [p, FLOOR) (or the
// continuation form) moves below SP, which is then the bottom of the frame; the floor becomes SP.
    FUNC silica_rt_adopt
    ENTRY_SAVE
    ldr     r4, [r9, #VRG_ARG]              // r4 = p
    ldr     r5, [r9, #VRG_VSP]              // r5 = s
    cmp     r4, r5
    beq.w   9f                              // nothing placed: SP stays at p
    ldr     r6, [r9, #VRG_FLOOR]            // r6 = floor
    ldr     r7, [r9, #VRG_ACHUNK]           // r7 = the chunk s is in
    // the transient part is above p, in p's chunk: find it (p's chunk is at or below s's in the chain)
    mov     r8, r7
1:  ldr     r0, [r8, #CH_LIMIT]
    ldr     r1, [r8, #CH_TOP]
    cmp     r4, r0
    blo.w   2f
    cmp     r1, r4
    bhs.w   3f
2:  ldr     r8, [r8, #CH_PREV]
    cmp     r8, #0
    bne.w   1b
    b.w     8f                              // p in no chunk of the chain: an invariant violation
3:  // Already adopted (a runtime routine built its result in THIS frame through silica_rt_frame_alloc,
    // which lowered the floor): the floor is below p, in p's chunk under p or in a chunk after p's.
    // SP and the floor are consistent already; nothing to do.
    ldr     r0, [r8, #CH_LIMIT]
    ldr     r1, [r8, #CH_TOP]
    cmp     r6, r0
    blo.w   31f
    cmp     r1, r6
    blo.w   31f
    cmp     r6, r4
    blo.w   9f                              // the floor in p's chunk, below p
    b.w     32f
31: mov     r0, r8                          // the floor in a chunk after p's?
33: ldr     r0, [r0, #CH_NEXT]
    cmp     r0, #0
    beq.w   32f
    ldr     r1, [r0, #CH_LIMIT]
    cmp     r6, r1
    blo.w   33b
    ldr     r1, [r0, #CH_TOP]
    cmp     r1, r6
    blo.w   33b
    b.w     9f
32: mov     r0, r4
    mov     r1, r6
    mov     r2, r8
    bl      rt_transient_len
    mov     r3, r0                          // r3 = len
    cmp     r3, #0
    beq.w   5f
    // room for it under s in s's chunk; else a fresh chunk holding only the transient part
    ldr     r0, [r7, #CH_LIMIT]
    sub     r1, r5, r3
    cmp     r1, r0
    blo.w   4f
    mov     r0, r4
    sub     r1, r5, r3
    mov     r2, r3
    push    {r3}
    bl      rt_move_down
    pop     {r3}
    sub     r1, r5, r3
    str     r1, [r9, #VRG_VSP]
    b.w     5f
4:  push    {r3}
    bl      silica_rt_current
    pop     {r3}
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #0
    bne.w   8f
    mov     r1, r7
    mov     r2, r3
    push    {r3}
    mov     r3, r5                          // the continuation of the floor s: a restore to s pops it
    bl      silica_rt_aux_chunk_append
    pop     {r3}
    cmp     r0, #0
    beq.w   8f
    adds    r1, r0, #1
    beq.w   8f
    mov     r7, r0
    push    {r3}
    bl      silica_rt_aux_publish_chunk
    pop     {r3}
    ldr     r1, [r7, #CH_TOP]
    sub     r1, r1, r3
    mov     r0, r4
    mov     r2, r3
    push    {r3}
    bl      rt_move_down
    pop     {r3}
    ldr     r1, [r7, #CH_TOP]
    sub     r1, r1, r3
    str     r1, [r9, #VRG_VSP]
5:  str     r5, [r9, #VRG_FLOOR]
9:  ENTRY_RET
8:  bl      silica_rt_region_alloc_failed
    b.w     8b
    .size   silica_rt_adopt, . - silica_rt_adopt

// silica_rt_ev_frame: the copier is not ported yet (see the head of the file).
    FUNC silica_rt_ev_frame
    bl      silica_rt_unsupported
    .size   silica_rt_ev_frame, . - silica_rt_ev_frame

// silica_rt_frame_alloc(r0 = bytes) -> r0 = a zeroed block in the dynamic part of the running frame
// (the runtime's own allocations of a list, a string, a runtime-built record). Rounded to 16; through
// VRG_ARG and silica_rt_dyn_alloc. The emitted call site adopts the frame's dynamic part after the
// runtime call returns. The block comes back ZEROED: the dynamic part is reused transient memory.
    FUNC silica_rt_frame_alloc
    push    {r4, lr}
    add     r0, r0, #15
    bic     r0, r0, #15
    mov     r4, r0
    str     r0, [r9, #VRG_ARG]
    bl      silica_rt_dyn_alloc
    ldr     r0, [r9, #VRG_ARG]
    mov     r1, r4
    push    {r0}
    bl      silica_rt_zero_block
    pop     {r0}
    pop     {r4, pc}
    .size   silica_rt_frame_alloc, . - silica_rt_frame_alloc

// silica_rt_in_aux_chain(r0 = ptr) -> r0 = 1 when ptr lies in a chunk of the running context's
// auxiliary chain, 0 otherwise. Leaf.
    FUNC silica_rt_in_aux_chain
    ldr     r1, [r9, #VRG_ACHUNK]
1:  cmp     r1, #0
    beq.w   9f
    ldr     r2, [r1, #CH_LIMIT]
    ldr     r3, [r1, #CH_TOP]
    cmp     r0, r2
    blo.w   2f
    cmp     r0, r3
    blo.w   8f
2:  ldr     r1, [r1, #CH_PREV]
    b.w     1b
8:  movw    r0, #1
    bx      lr
9:  movw    r0, #0
    bx      lr
    .size   silica_rt_in_aux_chain, . - silica_rt_in_aux_chain
