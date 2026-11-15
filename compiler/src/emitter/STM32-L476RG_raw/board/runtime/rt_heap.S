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

// Heap for the bare-metal STM32L476RG runtime: two ARENAS, each a first-fit heap of its own.
//   arena 0, SRAM1 [_silica_heap_start, _silica_heap_end): every runtime block (ACBs, message nodes,
//            mailbox buffers, state chunks, copier tables, supervision blocks, child rows) and the
//            stack chunks that arena 1 cannot hold;
//   arena 1, SRAM2 [_silica_sram2_heap_start, _silica_sram2_heap_end): the part of SRAM2 the fault
//            stack and main's auxiliary stack leave (silica_stm32l476rg.ld), for actor STACK CHUNKS
//            only (machine and auxiliary; Lee 2026-11-09). A chunk is one block, so it lies wholly in
//            one region and its limits, top and band compare within it; the runtime never assumes an
//            order between two chunks of a chain (silica_rt_aux_release pops on any address outside
//            the current chunk, and every emitted restore is checked on both sides), so a chain may
//            mix the two regions freely.
// The chunk allocator (silica_rt_alloc_chunk_or_null) tries arena 1 first, so SRAM1 is kept for the
// blocks only it may hold, and falls back to arena 0 when SRAM2 has no block of the size.
//
// Every block carries a 16-byte header just below the address handed out: [-16] the block's total
// size in bytes (header included, a multiple of 16), [-12] a tag, HEAP_USED while the block is
// allocated and the next free block's header address (or 0) while it sits on its arena's free list.
// Blocks are 16-byte aligned, which every stack chunk and SP needs. Allocation is first fit over an
// address-sorted free list, splitting a block whose remainder can hold another header and 16 bytes,
// and falls back to bumping the top of the arena. Freeing finds the arena by address, puts the block
// back in address order and merges it with free neighbours; a block that ends at the top lowers the
// bump pointer instead. The payload is zeroed on every allocation: reused memory is dirty and the
// emitted code reads the high words of fresh slots as zero (SRAM2 is therefore never zeroed at boot).
//
// Since chunk 15 emitted code never allocates here: a frame's values live in its dynamic part
// (rt_frame.S) and an actor's state in its state chain (rt_state.S). Exhaustion is a runtime abort
// ("[silica] abort: heap exhausted at 0x...", status 71) rather than a NULL the caller might not
// check. One core, cooperative: no lock; the tick handler allocates nothing.
//
//   silica_rt_heap_init()          both arenas empty (called once by rt_start)
//   silica_rt_alloc(r0 = size)     -> r0: arena 0, 16-byte aligned, zeroed; aborts when exhausted
//   silica_rt_alloc_or_null(r0)    the same, returning 0 instead of aborting
//   silica_rt_alloc_chunk_or_null(r0)  a stack chunk: arena 1, else arena 0; 0 when neither has room
//   silica_rt_free(r0 = ptr)       return a block to its arena; 0, a pointer outside both arenas and
//                                  a block that is not allocated (a double free) are ignored
//   silica_rt_zero_block(r0 = ptr, r1 = bytes)   zero a block (word granularity)
//   silica_rt_heap_summary()       print " heap: in use U free F sram2: in use U2 free F2" (the exit
//                                  diagnostic)
//   silica_rt_heap_in_use(X0)      emitted entry: bytes in use in both arenas, as int64 in X0

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

#define HEAP_USED 0x5A11CA1D
#define HDR 16

/* An arena. */
#define AR_START   0
#define AR_END     4
#define AR_NEXT    8        /* the bump pointer */
#define AR_FREE    12       /* the free list's head (a header address, 0 empty) */
#define AR_INUSE   16       /* bytes allocated, headers included */
#define AR_SIZE    20

    .section .bss.silica_rt_heap, "aw", %nobits
    .balign 4
silica_rt_arenas:
    .space  AR_SIZE * 2

    .section .text.silica_rt_heap, "ax", %progbits

    FUNC silica_rt_heap_init
    MOV32   r2, silica_rt_arenas
    MOV32   r0, _silica_heap_start
    MOV32   r1, _silica_heap_end
    str     r0, [r2, #AR_START]
    str     r1, [r2, #AR_END]
    str     r0, [r2, #AR_NEXT]
    MOV32   r0, _silica_sram2_heap_start
    MOV32   r1, _silica_sram2_heap_end
    str     r0, [r2, #AR_SIZE + AR_START]
    str     r1, [r2, #AR_SIZE + AR_END]
    str     r0, [r2, #AR_SIZE + AR_NEXT]
    movw    r0, #0
    str     r0, [r2, #AR_FREE]
    str     r0, [r2, #AR_INUSE]
    str     r0, [r2, #AR_SIZE + AR_FREE]
    str     r0, [r2, #AR_SIZE + AR_INUSE]
    bx      lr
    .size   silica_rt_heap_init, . - silica_rt_heap_init

// silica_rt_zero_block(r0 = ptr, r1 = bytes). Clobbers r1, r2, r3.
    FUNC silica_rt_zero_block
    movw    r2, #0
    add     r1, r0, r1
    mov     r3, r0
1:  cmp     r3, r1
    bhs.w   2f
    str     r2, [r3], #4
    b.w     1b
2:  bx      lr
    .size   silica_rt_zero_block, . - silica_rt_zero_block

// rt_arena_alloc(r0 = payload bytes, r1 = arena) -> r0 = payload or 0.
    LFUNC rt_arena_alloc
    push    {r4-r8, lr}
    mov     r8, r1                          // r8 = arena
    add     r4, r0, #(HDR + 15)
    bic     r4, r4, #15                     // r4 = block size, header included
    // first fit over the free list (r5 = prev header's tag slot or the head word, r6 = header)
    add     r5, r8, #AR_FREE
    ldr     r6, [r5]
1:  cmp     r6, #0
    beq.w   4f
    ldr     r7, [r6, #0]                    // its size
    cmp     r7, r4
    bhs.w   2f
    add     r5, r6, #4                      // the tag slot holds the next link
    ldr     r6, [r6, #4]
    b.w     1b
2:  // r6 serves: split when the remainder holds a header and a cell
    sub     r7, r7, r4
    cmp     r7, #(HDR + 16)
    blo.w   3f
    add     r0, r6, r4                      // the remainder becomes the free block in r6's place
    str     r7, [r0, #0]
    ldr     r1, [r6, #4]
    str     r1, [r0, #4]
    str     r0, [r5]
    str     r4, [r6, #0]
    b.w     5f
3:  ldr     r1, [r6, #4]                    // whole block: unlink
    str     r1, [r5]
    ldr     r4, [r6, #0]
    b.w     5f
4:  // bump
    ldr     r6, [r8, #AR_NEXT]
    add     r1, r6, r4
    ldr     r3, [r8, #AR_END]
    cmp     r1, r3
    bhi.w   9f
    str     r1, [r8, #AR_NEXT]
    str     r4, [r6, #0]
5:  MOV32   r1, HEAP_USED
    str     r1, [r6, #4]
    ldr     r1, [r8, #AR_INUSE]
    add     r1, r1, r4
    str     r1, [r8, #AR_INUSE]
    add     r0, r6, #HDR
    sub     r1, r4, #HDR
    push    {r0}
    bl      silica_rt_zero_block
    pop     {r0}
    pop     {r4-r8, pc}
9:  movw    r0, #0
    pop     {r4-r8, pc}
    .size   rt_arena_alloc, . - rt_arena_alloc

// silica_rt_alloc_or_null(r0 = payload bytes) -> r0 = payload or 0 (arena 0, SRAM1).
    FUNC silica_rt_alloc_or_null
    MOV32   r1, silica_rt_arenas
    b.w     rt_arena_alloc
    .size   silica_rt_alloc_or_null, . - silica_rt_alloc_or_null

// silica_rt_alloc_chunk_or_null(r0 = payload bytes) -> r0 = payload or 0: arena 1 (SRAM2) first.
    FUNC silica_rt_alloc_chunk_or_null
    push    {r4, lr}
    mov     r4, r0
    MOV32   r1, silica_rt_arenas + AR_SIZE
    bl      rt_arena_alloc
    cmp     r0, #0
    bne.w   9f
    mov     r0, r4
    MOV32   r1, silica_rt_arenas
    bl      rt_arena_alloc
9:  pop     {r4, pc}
    .size   silica_rt_alloc_chunk_or_null, . - silica_rt_alloc_chunk_or_null

    FUNC silica_rt_alloc
    push    {r4, lr}
    bl      silica_rt_alloc_or_null
    cmp     r0, #0
    beq.w   1f
    pop     {r4, pc}
1:  bl      silica_rt_abort_heap_exhausted
    .size   silica_rt_alloc, . - silica_rt_alloc

// silica_rt_free(r0 = payload).
    FUNC silica_rt_free
    push    {r4-r8, lr}
    cmp     r0, #0
    beq.w   9f
    sub     r4, r0, #HDR                    // r4 = header
    // its arena: the one whose [start, bump) holds the header
    MOV32   r8, silica_rt_arenas
    ldr     r1, [r8, #AR_START]
    cmp     r4, r1
    blo.w   61f
    ldr     r1, [r8, #AR_NEXT]
    cmp     r4, r1
    blo.w   62f
61: add     r8, r8, #AR_SIZE
    ldr     r1, [r8, #AR_START]
    cmp     r4, r1
    blo.w   9f
    ldr     r1, [r8, #AR_NEXT]
    cmp     r4, r1
    bhs.w   9f
62: ldr     r1, [r4, #4]
    MOV32   r2, HEAP_USED
    cmp     r1, r2
    bne.w   9f                              // not an allocated block
    ldr     r5, [r4, #0]                    // r5 = size
    ldr     r1, [r8, #AR_INUSE]
    sub     r1, r1, r5
    str     r1, [r8, #AR_INUSE]
    // the block at the top lowers the bump pointer, pulling down free blocks left at the new top
    add     r6, r8, #AR_NEXT
    ldr     r1, [r6]
    add     r2, r4, r5
    cmp     r2, r1
    bne.w   2f
1:  str     r4, [r6]                        // bump = this block's base
    // is the free block just below the new top the last on the list? find a free block ending at r4
    add     r7, r8, #AR_FREE
    ldr     r0, [r7]
    movw    r3, #0                          // r3 = previous link slot (0 = head)
11: cmp     r0, #0
    beq.w   9f
    ldr     r1, [r0, #0]
    add     r1, r0, r1
    cmp     r1, r4
    beq.w   12f
    add     r3, r0, #4
    ldr     r0, [r0, #4]
    b.w     11b
12: ldr     r1, [r0, #4]                    // unlink it and lower the bump again
    cmp     r3, #0
    ite     eq
    streq   r1, [r7]
    strne   r1, [r3]
    mov     r4, r0
    b.w     1b
2:  // insert in address order: r7 = link slot to write, r0 = the block after
    add     r7, r8, #AR_FREE
    ldr     r0, [r7]
21: cmp     r0, #0
    beq.w   3f
    cmp     r0, r4
    bhi.w   3f
    add     r7, r0, #4
    ldr     r0, [r0, #4]
    b.w     21b
3:  str     r0, [r4, #4]
    str     r4, [r7]
    // merge with the block after
    cmp     r0, #0
    beq.w   4f
    add     r1, r4, r5
    cmp     r1, r0
    bne.w   4f
    ldr     r1, [r0, #0]
    add     r5, r5, r1
    str     r5, [r4, #0]
    ldr     r1, [r0, #4]
    str     r1, [r4, #4]
4:  // merge with the block before (r7 is its tag slot when it is a free header)
    add     r1, r8, #AR_FREE
    cmp     r7, r1
    beq.w   9f
    sub     r6, r7, #4                      // the previous free header
    ldr     r1, [r6, #0]
    add     r1, r6, r1
    cmp     r1, r4
    bne.w   9f
    ldr     r1, [r6, #0]
    add     r1, r1, r5
    str     r1, [r6, #0]
    ldr     r1, [r4, #4]
    str     r1, [r6, #4]
9:  pop     {r4-r8, pc}
    .size   silica_rt_free, . - silica_rt_free

// silica_rt_heap_summary(): " heap: in use U free F sram2: in use U2 free F2" where a free count
// covers the arena's free list and its untouched top. Clobbers r0-r3.
    FUNC silica_rt_heap_summary
    push    {r4, r5, r6, lr}
    MOV32   r6, silica_rt_arenas
    MOV32   r0, silica_rt_heap_sum_pre
    bl      rt_arena_summary
    add     r6, r6, #AR_SIZE
    MOV32   r0, silica_rt_heap_sum_sram2
    bl      rt_arena_summary
    pop     {r4, r5, r6, pc}
    .size   silica_rt_heap_summary, . - silica_rt_heap_summary

// rt_arena_summary(r0 = the label, r6 = arena): "<label>U free F". Keeps r6.
    LFUNC rt_arena_summary
    push    {r4, lr}
    bl      silica_rt_puts
    ldr     r0, [r6, #AR_INUSE]
    bl      silica_rt_print_u32
    MOV32   r0, silica_rt_heap_sum_free
    bl      silica_rt_puts
    ldr     r0, [r6, #AR_END]
    ldr     r1, [r6, #AR_NEXT]
    sub     r4, r0, r1
    ldr     r1, [r6, #AR_FREE]
1:  cmp     r1, #0
    beq.w   2f
    ldr     r2, [r1, #0]
    add     r4, r4, r2
    ldr     r1, [r1, #4]
    b.w     1b
2:  mov     r0, r4
    bl      silica_rt_print_u32
    pop     {r4, pc}
    .size   rt_arena_summary, . - rt_arena_summary

// get_heap_in_use() -> X0 (emitted entry): both arenas.
    FUNC silica_rt_heap_in_use
    ENTRY_SAVE
    MOV32   r2, silica_rt_arenas
    ldr     r0, [r2, #AR_INUSE]
    ldr     r1, [r2, #AR_SIZE + AR_INUSE]
    add     r0, r0, r1
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_heap_in_use, . - silica_rt_heap_in_use

    .section .rodata.silica_rt_heap, "a", %progbits
silica_rt_heap_sum_pre:
    .asciz  " heap: in use "
silica_rt_heap_sum_free:
    .asciz  " free "
silica_rt_heap_sum_sram2:
    .asciz  " sram2: in use "
