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

// The frame's dynamic part on the ESP32-S3 (compiler/design_documents/chunk15_stack_memory_design.md
// §2.6, §3.1-§3.5; the board re-expression of the hosted emitters' L_dyn_alloc / L_adopt / L_ev_frame,
// which are emitted helpers there and runtime routines here: shared/xt_frame.silica).
//
// The emitter's SP (VRG_VSP) runs on the auxiliary stack, a chain of heap chunks (rt_actors.S
// "Growable stacks"); the fixed part of a frame is the a1 frame ENTRY allocates. The DYNAMIC part of a
// frame -- frame allocations, adopted and evacuated results -- lies on the auxiliary stack between the
// frame's FLOOR (VRG_FLOOR, one word per core like SP; saved with SP at a context switch, ACB_CTX_FLOOR)
// and its transient pushes [SP, FLOOR) (argument slabs, operand parks; addressed only relative to SP).
//
// The invariant every routine here keeps: the transient part is contiguous and lies in the current
// auxiliary chunk. Either FLOOR is in the current chunk and the transient part is [SP, FLOOR), or SP is
// in a continuation chunk this file appended (CH_MIRROR 0, CH_RET = the FLOOR it continues) and the
// transient part is [SP, CH_TOP) of that chunk (rt_transient_len).
//
// Entries (CALL8 from emitted code; X0-X2 are the caller's a10-a15 and survive unless the entry answers
// in them; the register block's X3-X8 are untouched). The caller's a10-a15 ARE this window's a2-a7
// (CALL8 rotates by eight), so an entry that uses a2-a7 as locals saves them at entry and puts them
// back at every return, as silica_rt_aux_grow does (xt_vr vsp_reserve_check: "the runtime keeps the
// caller's a2-a7 ... it never writes its own a2-a7"). Without that, a call site's result pointer
// (X0 after silica_rt_adopt), a list's head and tail across silica_rt_dyn_alloc, come back as the
// routine's scratch values.
//   silica_rt_dyn_alloc    VRG_ARG = n (a multiple of 16) -> VRG_ARG = a block of n bytes directly under
//                          the floor; the transient part moves down under it and the floor goes down by n.
//                          A block that does not fit the chunk takes a fresh chunk (the transient part
//                          moving with it); main's auxiliary stack does not grow (rt_actors.S aux_grow).
//   silica_rt_adopt        VRG_ARG = the pre-call SP p: [SP, p), the callee's frames and dynamic part,
//                          becomes the bottom of this frame's dynamic part (design §3.3 (a)); the
//                          transient part [p, FLOOR) moves below SP. Nothing left (SP == p): SP stays.
//   silica_rt_ev_frame     X0 = value, X1 = KIND, X2 = AUX of its root descriptor entry, X3 (THREADPTR
//                          +0) = the pre-call SP p -> X0 = the value with every node of it that lies in
//                          the callee's frames copied (one pass, rt_state.S copier in frame mode) into a
//                          fresh chunk appended to the chain, which becomes the bottom of this frame's
//                          dynamic part; the callee's chunks go back. A value with nothing new restores
//                          SP = p (the callee's frames are dead).
//
// Frame depth: every routine here runs on the caller's machine chunk inside the runtime reserve
// (tools/main_stack_bound.py: silica_rt_dyn_alloc__stack_bound and siblings below).

#define VRG_VSP          112
#define VRG_MLIMIT       116
#define VRG_ALIMIT       120
#define VRG_ATOP         124
#define VRG_MCHUNK       128
#define VRG_ACHUNK       132
#define VRG_ARG          136
#define VRG_FLOOR        140
#define VRG_CCB          144

#define CH_NEXT          0
#define CH_PREV          4
#define CH_SIZE          8
#define CH_RET           12
#define CH_LIMIT         16
#define CH_TOP           20
#define CH_BAND          24
#define CH_INDEX         28
#define CH_MIRROR        32
#define CH_USABLE_OFF    128
#define ACHUNK_CAP       4096
#define ACHUNK_HEADROOM  256

#define ACB_KIND         19
#define ACB_CTX_VSP      68
#define ACB_ACUR         56
#define ACB_CTX_FLOOR    204

#define DBREAKC_STORE_64 0x80000000

    .text

// rt_transient_len(a2 = sp, a3 = floor, a4 = the chunk sp is in) -> a2 = the transient bytes above sp:
// floor - sp when floor lies in the chunk ([limit, top]), else top - sp (a continuation chunk).
    .align  4
    .type   rt_transient_len, @function
rt_transient_len:
    entry   a1, 32
    l32i    a8, a4, CH_LIMIT
    l32i    a9, a4, CH_TOP
    bltu    a3, a8, 1f
    bltu    a9, a3, 1f
    sub     a2, a3, a2
    retw
1:  sub     a2, a9, a2
    retw
    .size   rt_transient_len, . - rt_transient_len

// rt_move_down(a2 = src, a3 = dst, a4 = bytes): copies [src, src + bytes) to [dst, dst + bytes), dst <=
// src (ascending copy, safe for an overlap in that direction). Word granularity: every SP and floor is
// 16-byte aligned and the transient part a multiple of 16.
    .align  4
    .type   rt_move_down, @function
rt_move_down:
    entry   a1, 32
    beqz    a4, 2f
    add     a5, a2, a4
1:  l32i    a8, a2, 0
    s32i    a8, a3, 0
    addi    a2, a2, 4
    addi    a3, a3, 4
    bltu    a2, a5, 1b
2:  retw
    .size   rt_move_down, . - rt_move_down

// rt_move_up(a2 = src, a3 = dst, a4 = bytes): copies [src, src + bytes) to [dst, dst + bytes), dst >=
// src (descending copy, safe for an overlap in that direction). Word granularity as rt_move_down.
    .align  4
    .type   rt_move_up, @function
rt_move_up:
    entry   a1, 32
    beqz    a4, 2f
    add     a5, a2, a4
    add     a6, a3, a4
1:  addi    a5, a5, -4
    addi    a6, a6, -4
    l32i    a8, a5, 0
    s32i    a8, a6, 0
    bltu    a2, a5, 1b
2:  retw
    .size   rt_move_up, . - rt_move_up

// silica_rt_aux_chunk_append(a2 = acb, a3 = the chunk to append after, a4 = bytes needed, a5 = the SP
// a restore to pops it (CH_RET)) -> a2 = the chunk (CH_MIRROR 0, CH_RET set), 0 when the heap is
// exhausted, -1 when the actor's lowered reservation is reached. The chain above `after` is reused or
// returned by silica_rt_chunk_next. Nothing is published in the register block: the caller does that.
    .align  4
    .global silica_rt_aux_chunk_append
    .type   silica_rt_aux_chunk_append, @function
silica_rt_aux_chunk_append:
    entry   a1, 32
    mov     a10, a2
    mov     a11, a3
    addi    a12, a4, 16
    movi    a13, ACHUNK_CAP
    movi    a14, ACHUNK_HEADROOM
    movi    a15, 0
    call8   silica_rt_chunk_next
    mov     a2, a10
    beqz    a2, 9f
    movi    a8, -1
    beq     a2, a8, 9f
    s32i    a5, a2, CH_RET
    movi    a8, 0
    s32i    a8, a2, CH_MIRROR
9:  retw
    .size   silica_rt_aux_chunk_append, . - silica_rt_aux_chunk_append

// rt_publish_chunk(a2 = chunk): the running context moves to this auxiliary chunk (VRG_ACHUNK, the
// limit, the top a release pops at, the guard band's watchpoint). SP and the floor are the caller's.
// Global as silica_rt_aux_publish_chunk: a woken caller moves into the chunk a reply was placed in
// (rt_actors.S silica_rt_actor_call).
    .align  4
    .global silica_rt_aux_publish_chunk
    .type   silica_rt_aux_publish_chunk, @function
    .type   rt_publish_chunk, @function
silica_rt_aux_publish_chunk:
rt_publish_chunk:
    entry   a1, 32
    rur     a8, threadptr
    s32i    a2, a8, VRG_ACHUNK
    l32i    a9, a2, CH_LIMIT
    s32i    a9, a8, VRG_ALIMIT
    l32i    a9, a2, CH_TOP
    l32i    a10, a2, CH_MIRROR
    sub     a9, a9, a10
    s32i    a9, a8, VRG_ATOP
    l32i    a9, a2, CH_BAND
    wsr     a9, dbreaka1
    movi    a9, DBREAKC_STORE_64
    wsr     a9, dbreakc1
    isync
    retw
    .size   rt_publish_chunk, . - rt_publish_chunk

// No room: the running context's auxiliary stack cannot take the block (main's fixed stack, or an
// exhausted heap). Each entry calls silica_rt_region_alloc_failed (rt_console.S) at its own site, so
// the abort's address names the entry: an actor ends with (:explicit, :out_of_memory); main aborts.

// silica_rt_dyn_alloc: see the head of the file. Frame: [0..20] the caller's a2-a7 (its X0-X2 in
// a10-a15: this window's a2-a7 ARE those registers, so they are saved at entry and put back at the
// return; the emitted sites keep the head and tail of a list, a checked value, the ok flag in them).
    .align  4
    .global silica_rt_dyn_alloc
    .type   silica_rt_dyn_alloc, @function
silica_rt_dyn_alloc:
    entry   a1, 64
    s32i    a2, a1, 0
    s32i    a3, a1, 4
    s32i    a4, a1, 8
    s32i    a5, a1, 12
    s32i    a6, a1, 16
    s32i    a7, a1, 20
    rur     a8, threadptr
    l32i    a2, a8, VRG_ARG             // a2 = n
    l32i    a3, a8, VRG_VSP             // a3 = sp
    l32i    a4, a8, VRG_FLOOR           // a4 = floor
    l32i    a5, a8, VRG_ACHUNK          // a5 = chunk
    mov     a10, a3
    mov     a11, a4
    mov     a12, a5
    call8   rt_transient_len
    mov     a6, a10                     // a6 = len
    // the floor in this chunk and room for the block and the moved transient part above the limit
    l32i    a8, a5, CH_LIMIT
    l32i    a9, a5, CH_TOP
    bltu    a4, a8, 2f
    bltu    a9, a4, 2f
    sub     a7, a4, a2                  // a7 = block
    sub     a9, a7, a6
    bltu    a9, a8, 2f
    j       3f
2:  // a fresh chunk after this one: the block at its top, the transient part under it
    call8   silica_rt_current
    mov     a7, a10
    l8ui    a8, a7, ACB_KIND
    bnez    a8, 8f                      // main: no growth
    mov     a10, a7
    mov     a11, a5
    add     a12, a2, a6
    mov     a13, a3                     // a restore to the SP of entry (or above) pops the chunk
    call8   silica_rt_aux_chunk_append
    beqz    a10, 8f
    movi    a8, -1
    beq     a10, a8, 8f
    mov     a5, a10
    call8   rt_publish_chunk
    l32i    a7, a5, CH_TOP
    sub     a7, a7, a2
    movi    a8, -16
    and     a7, a7, a8                  // a7 = block (16-aligned under the top)
3:  // the transient part [sp, sp + len) goes to [block - len, block)
    mov     a10, a3
    sub     a11, a7, a6
    mov     a12, a6
    call8   rt_move_down
    rur     a8, threadptr
    sub     a9, a7, a6
    s32i    a9, a8, VRG_VSP
    s32i    a7, a8, VRG_FLOOR
    s32i    a7, a8, VRG_ARG
    l32i    a2, a1, 0                   // the caller's X0-X2 back
    l32i    a3, a1, 4
    l32i    a4, a1, 8
    l32i    a5, a1, 12
    l32i    a6, a1, 16
    l32i    a7, a1, 20
    retw
8:  call8   silica_rt_region_alloc_failed
9:  j       9b
    .size   silica_rt_dyn_alloc, . - silica_rt_dyn_alloc

// silica_rt_adopt: see the head of the file. [SP, p) is adopted: the transient part [p, FLOOR) (or the
// continuation form) moves below SP, which is then the bottom of the frame; the floor becomes SP.
// Frame: [0..20] the caller's a2-a7: its X0-X2 (the callee's result in a10:a11 is what the call site
// reads after this entry; design §3.3 (a), hosted L_adopt "X0-X8 are kept"), saved and put back.
    .align  4
    .global silica_rt_adopt
    .type   silica_rt_adopt, @function
silica_rt_adopt:
    entry   a1, 64
    s32i    a2, a1, 0
    s32i    a3, a1, 4
    s32i    a4, a1, 8
    s32i    a5, a1, 12
    s32i    a6, a1, 16
    s32i    a7, a1, 20
    rur     a8, threadptr
    l32i    a2, a8, VRG_ARG             // a2 = p
    l32i    a3, a8, VRG_VSP             // a3 = s
    beq     a2, a3, 9f                  // nothing placed: SP stays at p
    l32i    a4, a8, VRG_FLOOR           // a4 = floor
    l32i    a5, a8, VRG_ACHUNK          // a5 = the chunk s is in
    // the transient part is above p, in p's chunk: find it (p's chunk is at or below s's in the chain)
    mov     a6, a5
1:  l32i    a8, a6, CH_LIMIT
    l32i    a9, a6, CH_TOP
    bltu    a2, a8, 2f
    bgeu    a9, a2, 3f
2:  l32i    a6, a6, CH_PREV
    bnez    a6, 1b
    j       8f                          // p in no chunk of the chain: an invariant violation
3:  // Already adopted: a runtime routine that builds its result in THIS frame (silica_rt_frame_alloc:
    // supervisor_get_child_info, which_children, the topology records) placed it through
    // silica_rt_dyn_alloc, which moved the transient part under the block and lowered the floor, and
    // the call site then adopts [SP, p) as after a user call. The floor is then below p: in p's chunk
    // under p, or in a chunk appended after p's. SP and the floor are consistent already; nothing to
    // do. (Before this the transient length came out as floor - p, negative, and the adopt popped the
    // value or asked for a chunk main cannot have: supervisors_addition/supervisor_get_child_by_id.)
    l32i    a8, a6, CH_LIMIT
    l32i    a9, a6, CH_TOP
    bltu    a4, a8, 31f
    bltu    a9, a4, 31f
    bltu    a4, a2, 9f                  // the floor in p's chunk, below p
    j       32f
31: mov     a8, a6                      // the floor in a chunk after p's?
33: l32i    a8, a8, CH_NEXT
    beqz    a8, 32f
    l32i    a9, a8, CH_LIMIT
    bltu    a4, a9, 33b
    l32i    a9, a8, CH_TOP
    bltu    a9, a4, 33b
    j       9f
32: mov     a10, a2
    mov     a11, a4
    mov     a12, a6
    call8   rt_transient_len
    mov     a7, a10                     // a7 = len
    beqz    a7, 5f
    // room for it under s in s's chunk; else a fresh chunk holding only the transient part
    l32i    a8, a5, CH_LIMIT
    sub     a9, a3, a7
    bltu    a9, a8, 4f
    mov     a10, a2
    sub     a11, a3, a7
    mov     a12, a7
    call8   rt_move_down
    rur     a8, threadptr
    sub     a9, a3, a7
    s32i    a9, a8, VRG_VSP
    j       5f
4:  call8   silica_rt_current
    mov     a6, a10
    l8ui    a8, a6, ACB_KIND
    bnez    a8, 8f
    mov     a10, a6
    mov     a11, a5
    mov     a12, a7
    mov     a13, a3                     // the continuation of the floor s: a restore to s pops it
    call8   silica_rt_aux_chunk_append
    beqz    a10, 8f
    movi    a8, -1
    beq     a10, a8, 8f
    mov     a5, a10
    call8   rt_publish_chunk
    l32i    a9, a5, CH_TOP
    sub     a9, a9, a7
    mov     a10, a2
    mov     a11, a9
    mov     a12, a7
    call8   rt_move_down
    rur     a8, threadptr
    l32i    a9, a5, CH_TOP
    sub     a9, a9, a7
    s32i    a9, a8, VRG_VSP
5:  rur     a8, threadptr
    s32i    a3, a8, VRG_FLOOR
9:  l32i    a2, a1, 0                   // the caller's X0-X2 back
    l32i    a3, a1, 4
    l32i    a4, a1, 8
    l32i    a5, a1, 12
    l32i    a6, a1, 16
    l32i    a7, a1, 20
    retw
8:  call8   silica_rt_region_alloc_failed
    j       8b
    .size   silica_rt_adopt, . - silica_rt_adopt

// silica_rt_ev_frame: see the head of the file. Frame: [0] value lo, [4] value hi, [8] kind, [12] aux,
// [16] p, [20] s, [24] floor, [28] C0 (p's chunk), [32] len, [36] total, [40] dest chunk, [44] acb,
// [48] unused, [52..64] the caller's a4-a7 (its X1, X2: this entry answers in X0
// only, so a4-a7 go back at the return).
    // The copier recurses through the descriptors (rt_state.S rt_sm_val / rt_sc_val: at most 13 levels,
    // term_message_copy mc_entry caps the depth at 12, each level 96 bytes of frames plus the leaf's
    // placement calls, under 300), so the whole depth is declared (tools/main_stack_bound.py): 13 * 96
    // + 300 + this routine's own 112 + the two passes' 48, rounded up. The frame is 112 so that every
    // local lies below the window spill area ([frame - 32, frame): this routine's a4-a7, then its
    // caller's a0-a3); with 80, [64] overwrote the caller's spilled a0 (main's RETW faulted).
    .set    silica_rt_ev_frame__stack_bound, 2560
    .align  4
    .global silica_rt_ev_frame
    .type   silica_rt_ev_frame, @function
silica_rt_ev_frame:
    entry   a1, 112
    s32i    a2, a1, 0
    s32i    a3, a1, 4
    s32i    a4, a1, 8
    s32i    a6, a1, 12
    s32i    a4, a1, 52
    s32i    a5, a1, 56
    s32i    a6, a1, 60
    s32i    a7, a1, 64
    rur     a8, threadptr
    l32i    a9, a8, 0                   // X3 = p
    s32i    a9, a1, 16
    l32i    a9, a8, VRG_VSP
    s32i    a9, a1, 20
    l32i    a9, a8, VRG_FLOOR
    s32i    a9, a1, 24
    call8   silica_rt_current
    s32i    a10, a1, 44
    // C0: the chunk p lies in, at or below the current one
    rur     a8, threadptr
    l32i    a5, a8, VRG_ACHUNK
    l32i    a2, a1, 16
1:  l32i    a8, a5, CH_LIMIT
    l32i    a9, a5, CH_TOP
    bltu    a2, a8, 2f
    bgeu    a9, a2, 3f
2:  l32i    a5, a5, CH_PREV
    bnez    a5, 1b
    j       8f
3:  s32i    a5, a1, 28
    // measure the new part of the value (rt_state.S, frame mode: a node is new when it lies in
    // [C0 limit, p) or in a chunk above C0)
    l32i    a10, a1, 0
    l32i    a11, a1, 8
    l32i    a12, a1, 12
    l32i    a13, a1, 16
    l32i    a14, a1, 28
    call8   silica_rt_frame_measure
    s32i    a10, a1, 36                 // total (a multiple of 16), 0: nothing new
    bnez    a10, 4f
    // nothing new: the callee's frames are dead, SP goes back to p
    rur     a8, threadptr
    l32i    a9, a1, 16
    s32i    a9, a8, VRG_VSP
    call8   silica_rt_aux_release
    l32i    a2, a1, 0
    l32i    a3, a1, 4
    l32i    a4, a1, 52                  // the caller's X1, X2 back
    l32i    a5, a1, 56
    l32i    a6, a1, 60
    l32i    a7, a1, 64
    retw
4:  l32i    a10, a1, 16
    l32i    a11, a1, 24
    l32i    a12, a1, 28
    call8   rt_transient_len
    s32i    a10, a1, 32                 // len
    l32i    a2, a1, 44
    l8ui    a8, a2, ACB_KIND
    bnez    a8, 6f                      // main: no chunk to append, the copy is made in place
    // the destination: a fresh chunk after the current (deepest) one, so no source chunk is reused;
    // a restore to p or above pops it
    rur     a8, threadptr
    l32i    a11, a8, VRG_ACHUNK
    mov     a10, a2
    l32i    a12, a1, 36
    l32i    a13, a1, 32
    add     a12, a12, a13
    l32i    a13, a1, 16
    call8   silica_rt_aux_chunk_append
    beqz    a10, 8f
    movi    a8, -1
    beq     a10, a8, 8f
    s32i    a10, a1, 40
    // copy the new nodes into [top - total, top) of the destination chunk
    l32i    a3, a1, 40
    l32i    a4, a3, CH_TOP
    l32i    a5, a1, 36
    sub     a4, a4, a5                  // a4 = dest low
    l32i    a10, a1, 0
    l32i    a11, a1, 4
    l32i    a12, a1, 8
    l32i    a13, a1, 12
    mov     a14, a4
    l32i    a15, a1, 16
    s32i    a3, a1, 48                  // the destination chunk, read by the copier's frame rule
    call8   silica_rt_frame_copy
    s32i    a10, a1, 0
    s32i    a11, a1, 4
    // unlink the callee's chunks: C0 -> dest, the chunks between go back
    l32i    a3, a1, 28
    l32i    a5, a1, 40
    l32i    a6, a3, CH_NEXT
    beq     a6, a5, 5f
    l32i    a7, a5, CH_PREV
    movi    a8, 0
    s32i    a8, a7, CH_NEXT
    mov     a10, a6
    call8   silica_rt_chunks_free_from
5:  s32i    a5, a3, CH_NEXT
    s32i    a3, a5, CH_PREV
    l32i    a8, a3, CH_INDEX
    addi    a8, a8, 1
    s32i    a8, a5, CH_INDEX
    mov     a10, a5
    call8   rt_publish_chunk
    // the transient part [p, p + len) under the copied nodes; SP and the floor follow
    l32i    a5, a1, 40
    l32i    a4, a5, CH_TOP
    l32i    a6, a1, 36
    sub     a4, a4, a6                  // dest low
    l32i    a7, a1, 32
    l32i    a10, a1, 16
    sub     a11, a4, a7
    mov     a12, a7
    call8   rt_move_down
    rur     a8, threadptr
    sub     a9, a4, a7
    s32i    a9, a8, VRG_VSP
    s32i    a4, a8, VRG_FLOOR
    l32i    a2, a1, 0
    l32i    a3, a1, 4
    l32i    a4, a1, 52                  // the caller's X1, X2 back
    l32i    a5, a1, 56
    l32i    a6, a1, 60
    l32i    a7, a1, 64
    retw
6:  // main: its auxiliary stack is one fixed chunk (C0; rt_start.S), so the copy's final place is
    // directly under p, [p - total, p), which overlaps the callee's frames [s, p) the nodes are read
    // from. The copy pass therefore writes into SCRATCH, [scratch, scratch + total) below both s and
    // the final place (free: every deeper frame has returned), with every pointer already relocated by
    // (final - scratch) (silica_rt_frame_copy_delta, rt_state.S), and the block then moves up as bytes.
    // The transient part follows under the final place as on the chunk path. Frame: [68] final low,
    // [72] scratch low.
    l32i    a2, a1, 16                  // p
    l32i    a3, a1, 36                  // total
    sub     a4, a2, a3                  // a4 = final low (p and total are multiples of 16)
    l32i    a5, a1, 20                  // s
    bgeu    a4, a5, 1f
    mov     a5, a4
1:  sub     a6, a5, a3                  // a6 = scratch low
    l32i    a7, a1, 28                  // C0: main's chunk
    l32i    a8, a7, CH_LIMIT
    bltu    a6, a8, 8f                  // no room for the scratch
    l32i    a9, a1, 32                  // len
    sub     a9, a4, a9
    bltu    a9, a8, 8f                  // no room for the transient part under the final place
    s32i    a4, a1, 68
    s32i    a6, a1, 72
    sub     a10, a4, a6
    call8   silica_rt_frame_copy_delta
    l32i    a10, a1, 0
    l32i    a11, a1, 4
    l32i    a12, a1, 8
    l32i    a13, a1, 12
    l32i    a14, a1, 72
    l32i    a15, a1, 16
    call8   silica_rt_frame_copy
    s32i    a10, a1, 0                  // the root, already at its final address
    s32i    a11, a1, 4
    movi    a10, 0
    call8   silica_rt_frame_copy_delta
    l32i    a10, a1, 72
    l32i    a11, a1, 68
    l32i    a12, a1, 36
    call8   rt_move_up                  // scratch -> [final low, p)
    l32i    a4, a1, 68
    l32i    a7, a1, 32
    l32i    a10, a1, 16
    sub     a11, a4, a7
    mov     a12, a7
    call8   rt_move_down                // the transient part [p, p + len) -> under the final place
    rur     a8, threadptr
    sub     a9, a4, a7
    s32i    a9, a8, VRG_VSP
    s32i    a4, a8, VRG_FLOOR
    l32i    a2, a1, 0
    l32i    a3, a1, 4
    l32i    a4, a1, 52                  // the caller's X1, X2 back
    l32i    a5, a1, 56
    l32i    a6, a1, 60
    l32i    a7, a1, 64
    retw
8:  call8   silica_rt_region_alloc_failed
    j       8b
    .size   silica_rt_ev_frame, . - silica_rt_ev_frame

// silica_rt_frame_alloc(a2 = bytes) -> a2 = a block in the dynamic part of the running frame (the
// runtime's own allocations of a list, a string, a runtime-built record: chunk 15 stage 4e, design
// §9.1). Rounded to 16; through VRG_ARG and silica_rt_dyn_alloc. The emitted call site adopts the
// frame's dynamic part after the runtime call returns (prims_actors@runtime_call_asm, the string and
// list helpers' own pre-call SP record).
//
// The block comes back ZEROED, the contract silica_rt_alloc gave these sites before chunk 15
// (rt_heap.S: "the payload is zeroed on every allocation, because reused memory is dirty and the
// emitted code reads the high words of fresh slots as zero"). The runtime's builders write the low
// word of each 8-byte field and leave the high words, a list handle's cursor on the next-chunk path,
// a string's NUL and a record's absent fields to the allocator; the dynamic part is reused transient
// memory (argument slabs, operand parks, earlier frames), so without this a tail handle read a stale
// cursor and a string a stale terminator (list_addition train_list_sum: 36 for 72).
    .align  4
    .global silica_rt_frame_alloc
    .type   silica_rt_frame_alloc, @function
silica_rt_frame_alloc:
    entry   a1, 32
    addi    a2, a2, 15
    movi    a8, -16
    and     a2, a2, a8
    rur     a8, threadptr
    s32i    a2, a8, VRG_ARG
    call8   silica_rt_dyn_alloc
    rur     a8, threadptr
    l32i    a10, a8, VRG_ARG
    mov     a11, a2
    call8   silica_rt_zero_block
    rur     a8, threadptr
    l32i    a2, a8, VRG_ARG
    movi    a3, 0
    retw
    .size   silica_rt_frame_alloc, . - silica_rt_frame_alloc

// silica_rt_in_aux_chain(a2 = ptr) -> a2 = 1 when ptr lies in a chunk of the running context's
// auxiliary chain (a frame's dynamic part or transient part), 0 for the state chain, a mailbox buffer,
// the heap or the rodata. Leaf.
    .align  4
    .global silica_rt_in_aux_chain
    .type   silica_rt_in_aux_chain, @function
silica_rt_in_aux_chain:
    entry   a1, 32
    rur     a8, threadptr
    l32i    a3, a8, VRG_ACHUNK
1:  beqz    a3, 9f
    l32i    a4, a3, CH_LIMIT
    l32i    a5, a3, CH_TOP
    bltu    a2, a4, 2f
    bltu    a2, a5, 8f
2:  l32i    a3, a3, CH_PREV
    j       1b
8:  movi    a2, 1
    retw
9:  movi    a2, 0
    retw
    .size   silica_rt_in_aux_chain, . - silica_rt_in_aux_chain
