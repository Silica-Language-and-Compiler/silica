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

// Heap for the bare-metal ESP32-S3 runtime over [_silica_heap_start, _silica_heap_end), which
// rt_start zeroes before main runs.
//
// Every block carries an 8-byte header just below the address handed out: [-8] the block's total
// size in bytes (header included, a multiple of 8, at least 16) and [-4] a tag, HEAP_USED while the
// block is allocated and the next free block's base while it sits on the free list (heap addresses
// never equal the tag). Allocation is first fit over an address-sorted free list, splitting a block
// whose remainder can hold another header, and falls back to bumping the top of the heap. Freeing
// puts the block back in address order and merges it with free neighbours; a block that ends at the
// top lowers the bump pointer instead (and pulls down any free blocks left at the new top). The
// payload is zeroed on every allocation, because reused memory is dirty and the emitted code reads
// the high words of fresh slots as zero.
//
// Since chunk 15 (chunk15_stack_memory_design.md §2.7, §9.3) emitted code never allocates here: a
// frame's values live in its dynamic part (rt_frame.S) and an actor's state in its state chain
// (rt_state.S). The heap serves the runtime's own blocks: stack chunks, state chunks, ACBs, message
// nodes, mailbox buffers, timers and tables. Exhaustion is a runtime abort ("[silica] abort: heap
// exhausted at 0x...", status 71) rather than a NULL the caller might not check.
//
// Both LX7 cores allocate (rt_actors.S runs actors on both): the free list and the bump pointer are
// guarded by one spin lock (S32C1I, the shape of rt_actors.S's FREE_LOCK). It is a leaf lock: nothing
// is called while it is held, so holding the scheduler or free-list lock around an allocation is fine.
// Free lists on top of this heap (actor stacks, ACBs, message nodes) keep their own lock in rt_actors.S.
//
//   silica_rt_heap_init()          reset the bump pointer and the free list (called once by rt_start)
//   silica_rt_alloc(size) -> ptr   8-byte aligned, zeroed; size is a 32-bit byte count; aborts when
//                                  the heap is exhausted
//   silica_rt_alloc_or_null(size)  the same, returning 0 instead of aborting
//   silica_rt_free(ptr)            return a block; 0, a pointer outside the heap and a block that is
//                                  not allocated (a double free) are ignored

#define HEAP_USED 0x5A11CA1D

    .section .bss.silica_rt_heap, "aw", @nobits
    .align  4
silica_rt_heap_next:
    .space  4
silica_rt_heap_free_head:
    .space  4
silica_rt_heap_lock:
    .space  4
    .global silica_rt_region_lock             // taken by silica_rt_region_grow (below) and by
silica_rt_region_lock:                        // rt_ordering.S's canonical arena insert
    .space  4

// The heap lock, the shape of rt_actors.S's FREE_LOCK. Its spin label is unique per expansion
// (\@), so it never captures a caller's numeric local label.
.macro HEAP_LOCK ra, rb
    movi    \ra, silica_rt_heap_lock
.Lheap_lock_spin\@:
    movi    \rb, 0
    wsr     \rb, scompare1
    movi    \rb, 1
    s32c1i  \rb, \ra, 0
    bnez    \rb, .Lheap_lock_spin\@
.endm

.macro HEAP_UNLOCK ra, rb
    memw
    movi    \ra, silica_rt_heap_lock
    movi    \rb, 0
    s32i    \rb, \ra, 0
    memw
.endm

    .section .text.silica_rt_heap, "ax"
    .literal_position

    .align  4
    .global silica_rt_heap_init
    .type   silica_rt_heap_init, @function
silica_rt_heap_init:
    entry   a1, 32
    movi    a3, silica_rt_heap_next
    movi    a4, _silica_heap_start
    s32i    a4, a3, 0
    movi    a3, silica_rt_heap_free_head
    movi    a4, 0
    s32i    a4, a3, 0
    movi    a3, silica_rt_heap_lock
    s32i    a4, a3, 0
    movi    a3, silica_rt_region_lock
    s32i    a4, a3, 0
    retw
    .size   silica_rt_heap_init, . - silica_rt_heap_init

// silica_rt_heap_take(size) -> zeroed payload, or 0 when no block can be found. Leaf: calls nothing.
// a2 = request, then the block size; a3 = the link being followed; a4 = block base; a5-a7 scratch.
    .align  4
    .type   silica_rt_heap_take, @function
silica_rt_heap_take:
    entry   a1, 32
    movi    a7, -256
    bgeu    a2, a7, 12f           // a request this large is an overflow, not a size
    addi    a2, a2, 15            // header, rounded up to 8
    movi    a5, -8
    and     a2, a2, a5
    movi    a7, 16
    bgeu    a2, a7, 1f
    mov     a2, a7                // at least a header and one slot
1:  HEAP_LOCK a8, a9
    movi    a3, silica_rt_heap_free_head
2:  l32i    a4, a3, 0             // first fit over the address-sorted free list
    beqz    a4, 6f
    l32i    a5, a4, 0
    bgeu    a5, a2, 3f
    addi    a3, a4, 4
    j       2b
3:  sub     a6, a5, a2            // remainder after the request
    movi    a7, 16
    bltu    a6, a7, 4f            // too small to stand alone: hand out the whole block
    add     a7, a4, a2            // split: the remainder stays in the list in the block's place
    s32i    a6, a7, 0
    l32i    a6, a4, 4
    s32i    a6, a7, 4
    s32i    a7, a3, 0
    s32i    a2, a4, 0
    j       5f
4:  l32i    a6, a4, 4             // unlink the whole block
    s32i    a6, a3, 0
    mov     a2, a5
5:  movi    a6, HEAP_USED
    s32i    a6, a4, 4
    j       7f
6:  movi    a3, silica_rt_heap_next    // nothing fits: bump the top
    l32i    a4, a3, 0
    add     a6, a4, a2
    bltu    a6, a4, 11f           // wrapped
    movi    a7, _silica_heap_end
    bltu    a7, a6, 11f           // past the end
    s32i    a6, a3, 0
    s32i    a2, a4, 0
    movi    a6, HEAP_USED
    s32i    a6, a4, 4
7:  HEAP_UNLOCK a8, a9
    addi    a5, a4, 8             // zero the payload [base + 8, base + size)
    add     a6, a4, a2
    movi    a7, 0
    mov     a4, a5
8:  bgeu    a4, a6, 10f
    s32i    a7, a4, 0
    addi    a4, a4, 4
    j       8b
10: mov     a2, a5
    movi    a3, 0
    retw
11: HEAP_UNLOCK a8, a9
12: movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_heap_take, . - silica_rt_heap_take

// The aliases silica_rt_region_alloc / silica_rt_raw_alloc (the implicit heap's allocations) are gone
// with chunk 15 (chunk15_stack_memory_design.md §9.3): emitted code allocates in its frame
// (rt_frame.S) and the heap serves only the runtime's own blocks. Note for anyone reading an abort
// address: with the aliases in place a symboliser named the "heap exhausted" site silica_rt_region_alloc
// (the same address), which read as a per-message region allocation that no longer exists.
    .align  4
    .global silica_rt_alloc
    .type   silica_rt_alloc, @function
silica_rt_alloc:
    entry   a1, 48
    mov     a10, a2
    call8   silica_rt_heap_take
    beqz    a10, 1f
    mov     a2, a10
    movi    a3, 0                 // the high word of the pair the emitter reads as X0
    retw
1:  call8   silica_rt_abort_heap_exhausted   // runtime abort, status 71; allocates nothing. The heap's
    retw                                     // state goes out after the exit marker (silica_rt_heap_summary)
    .size   silica_rt_alloc, . - silica_rt_alloc

// silica_rt_heap_summary(): the heap's state, appended to the exit diagnostic (rt_console.S
// silica_rt_exit, after the exit marker, so it is never part of the program's output and
// run_on_board.py hands it to the harness log as the board diagnostic):
//   " heap: in use U free F in N blocks largest L untouched T of S used: SxC SxC ... other K"
// U near S says the heap was eaten, F large with L small that it was fragmented, and the used
// blocks counted by size (the first 16 distinct sizes, the rest under "other") name the kind of
// block that filled it: 2064 a state chunk (rt_state.S SCH_FIRST + header), 4176 / 592 a first
// machine / auxiliary stack chunk (rt_actors.S, 80 of header and alignment slack), 56 a message
// node, a message buffer its measured size. Lock-free: at the exit the other core may have been
// stopped while it held the heap lock, so nothing here may wait for it; every walk is bounded (a
// torn or corrupt header ends the walk instead of looping).
// Frame: [0] free bytes, [4] blocks, [8] largest, [12] bump.
    .section .rodata.silica_rt_heap, "a"
silica_rt_heap_line_1:  .asciz  " heap: in use "
silica_rt_heap_line_3:  .asciz  " free "
silica_rt_heap_line_4:  .asciz  " in "
silica_rt_heap_line_5:  .asciz  " blocks largest "
silica_rt_heap_line_6:  .asciz  " untouched "
silica_rt_heap_line_7:  .asciz  " of "
silica_rt_heap_line_8:  .asciz  " used:"
silica_rt_heap_line_9:  .asciz  " other "
silica_rt_heap_line_sp: .asciz  " "
silica_rt_heap_line_x:  .asciz  "x"
    .section .bss.silica_rt_heap, "aw", @nobits
    .align  4
silica_rt_heap_hist:                      // 16 (size, count) pairs of allocated blocks
    .space  16 * 8
silica_rt_heap_hist_other:
    .space  4
    .section .text.silica_rt_heap, "ax"
    .literal_position
    .align  4
    .global silica_rt_heap_summary
    .type   silica_rt_heap_summary, @function
silica_rt_heap_summary:
    entry   a1, 48
    movi    a3, silica_rt_heap_free_head
    l32i    a3, a3, 0
    movi    a4, 0                 // free bytes
    movi    a5, 0                 // free blocks
    movi    a6, 0                 // the largest
    movi    a2, 100000            // at most this many links (a corrupt list ends the walk)
1:  beqz    a3, 2f
    beqz    a2, 2f
    addi    a2, a2, -1
    l32i    a7, a3, 0
    add     a4, a4, a7
    addi    a5, a5, 1
    bgeu    a6, a7, 11f
    mov     a6, a7
11: l32i    a3, a3, 4
    j       1b
2:  movi    a3, silica_rt_heap_next
    l32i    a3, a3, 0
    s32i    a4, a1, 0
    s32i    a5, a1, 4
    s32i    a6, a1, 8
    s32i    a3, a1, 12
    movi    a10, silica_rt_heap_line_1
    call8   silica_rt_puts
    l32i    a10, a1, 12           // in use = bump - start - free
    movi    a8, _silica_heap_start
    sub     a10, a10, a8
    l32i    a8, a1, 0
    sub     a10, a10, a8
    call8   silica_rt_print_u32
    movi    a10, silica_rt_heap_line_3
    call8   silica_rt_puts
    l32i    a10, a1, 0
    call8   silica_rt_print_u32
    movi    a10, silica_rt_heap_line_4
    call8   silica_rt_puts
    l32i    a10, a1, 4
    call8   silica_rt_print_u32
    movi    a10, silica_rt_heap_line_5
    call8   silica_rt_puts
    l32i    a10, a1, 8
    call8   silica_rt_print_u32
    movi    a10, silica_rt_heap_line_6
    call8   silica_rt_puts
    movi    a10, _silica_heap_end  // untouched = end - bump
    l32i    a8, a1, 12
    sub     a10, a10, a8
    call8   silica_rt_print_u32
    movi    a10, silica_rt_heap_line_7
    call8   silica_rt_puts
    movi    a10, _silica_heap_end  // the heap's size
    movi    a8, _silica_heap_start
    sub     a10, a10, a8
    call8   silica_rt_print_u32
    call8   silica_rt_heap_used_by_size
    retw
    .size   silica_rt_heap_summary, . - silica_rt_heap_summary

// silica_rt_heap_used_by_size(): " used: SxC SxC ... other K" for the allocated blocks between the
// heap's start and its bump pointer, walked by their headers ([0] size, [4] HEAP_USED while
// allocated). Lock-free and bounded as silica_rt_heap_summary.
    .align  4
    .type   silica_rt_heap_used_by_size, @function
silica_rt_heap_used_by_size:
    entry   a1, 32
    movi    a10, silica_rt_heap_hist
    movi    a11, 16 * 8 + 4
    call8   silica_rt_zero_block
    movi    a2, _silica_heap_start
    movi    a3, silica_rt_heap_next
    l32i    a3, a3, 0
    movi    a7, HEAP_USED
1:  bgeu    a2, a3, 5f
    l32i    a4, a2, 0             // the block's size
    movi    a5, 16
    bltu    a4, a5, 5f            // a corrupt header (sizes are at least 16): stop
    l32i    a5, a2, 4
    bne     a5, a7, 4f            // free: skip
    movi    a6, silica_rt_heap_hist
    movi    a9, 0
2:  l32i    a5, a6, 0
    beqz    a5, 3f                // an empty entry takes this size
    beq     a5, a4, 3f
    addi    a6, a6, 8
    addi    a9, a9, 1
    movi    a5, 16
    bltu    a9, a5, 2b
    movi    a6, silica_rt_heap_hist_other
    l32i    a5, a6, 0
    addi    a5, a5, 1
    s32i    a5, a6, 0
    j       4f
3:  s32i    a4, a6, 0
    l32i    a5, a6, 4
    addi    a5, a5, 1
    s32i    a5, a6, 4
4:  add     a2, a2, a4
    j       1b
5:  movi    a10, silica_rt_heap_line_8
    call8   silica_rt_puts
    movi    a2, silica_rt_heap_hist
    movi    a3, 0
6:  l32i    a4, a2, 0
    beqz    a4, 7f
    movi    a10, silica_rt_heap_line_sp
    call8   silica_rt_puts
    l32i    a10, a2, 0
    call8   silica_rt_print_u32
    movi    a10, silica_rt_heap_line_x
    call8   silica_rt_puts
    l32i    a10, a2, 4
    call8   silica_rt_print_u32
    addi    a2, a2, 8
    addi    a3, a3, 1
    movi    a4, 16
    bltu    a3, a4, 6b
7:  movi    a4, silica_rt_heap_hist_other
    l32i    a4, a4, 0
    beqz    a4, 8f
    movi    a10, silica_rt_heap_line_9
    call8   silica_rt_puts
    mov     a10, a4
    call8   silica_rt_print_u32
8:  retw
    .size   silica_rt_heap_used_by_size, . - silica_rt_heap_used_by_size

// silica_rt_alloc_or_null(size) -> ptr or 0: the same allocation without the exhaustion abort, for
// the actor stack reservation, whose failure has its own rule (spec §15.1.2.2; rt_actors.S).
    .align  4
    .global silica_rt_alloc_or_null
    .type   silica_rt_alloc_or_null, @function
silica_rt_alloc_or_null:
    entry   a1, 32
    mov     a10, a2
    call8   silica_rt_heap_take
    mov     a2, a10
    movi    a3, 0
    retw
    .size   silica_rt_alloc_or_null, . - silica_rt_alloc_or_null

// silica_rt_free(ptr). a4 = block base, a5 = its size; a3 = the link being followed, a6/a7 scratch.
    .align  4
    .global silica_rt_free
    .type   silica_rt_free, @function
silica_rt_free:
    entry   a1, 32
    beqz    a2, 8f
    movi    a8, _silica_heap_start
    bltu    a2, a8, 8f            // not a heap block: ignored, where free() would crash on the host
    movi    a8, _silica_heap_end
    bgeu    a2, a8, 8f
    addi    a4, a2, -8
    l32i    a5, a4, 4
    movi    a6, HEAP_USED
    bne     a5, a6, 8f            // not allocated (a double free, or a stale pointer): ignored
    l32i    a5, a4, 0
    HEAP_LOCK a8, a9
    movi    a3, silica_rt_heap_next
    l32i    a6, a3, 0
    add     a7, a4, a5
    bne     a7, a6, 4f
    s32i    a4, a3, 0             // the block ends at the top: lower the bump pointer instead
    movi    a6, 0
    s32i    a6, a4, 4             // and drop its tag, so a double free of it is ignored above
1:  movi    a3, silica_rt_heap_free_head   // ... and pull down free blocks now at the top
    l32i    a4, a3, 0
    beqz    a4, 7f
2:  l32i    a5, a4, 4             // walk to the last (highest) free block
    beqz    a5, 3f
    addi    a3, a4, 4
    mov     a4, a5
    j       2b
3:  l32i    a5, a4, 0
    add     a5, a4, a5
    movi    a6, silica_rt_heap_next
    l32i    a7, a6, 0
    bne     a5, a7, 7f            // it does not touch the top: done
    s32i    a4, a6, 0
    movi    a5, 0
    s32i    a5, a3, 0             // unlink it
    j       1b
4:  movi    a3, silica_rt_heap_free_head   // insert in address order
5:  l32i    a6, a3, 0
    beqz    a6, 6f
    bltu    a4, a6, 6f
    addi    a3, a6, 4
    j       5b
6:  // a3 = the link that will point at the block, a6 = the free block after it (or 0)
    beqz    a6, 61f
    add     a7, a4, a5
    bne     a7, a6, 61f
    l32i    a7, a6, 0             // adjacent: absorb the next block
    add     a5, a5, a7
    l32i    a6, a6, 4
61: s32i    a5, a4, 0
    s32i    a6, a4, 4
    s32i    a4, a3, 0
    movi    a7, silica_rt_heap_free_head
    beq     a3, a7, 7f            // no previous block
    addi    a7, a3, -4            // the previous block's base
    l32i    a6, a7, 0
    add     a6, a7, a6
    bne     a6, a4, 7f
    l32i    a6, a7, 0             // adjacent: the previous block absorbs this one
    add     a6, a6, a5
    s32i    a6, a7, 0
    l32i    a6, a4, 4
    s32i    a6, a7, 4
7:  HEAP_UNLOCK a8, a9
8:  retw
    .size   silica_rt_free, . - silica_rt_free

// Regions (terms/prims/prims_memory.silica): a region is a chain of blocks, each with a 32-byte
// header: [0] bump, [8] end of the block being filled (these two only matter in the first block,
// the handle), [16] next extension block, [24] this block's own data end; data from +32. Fields
// are 8-byte slots with the high word 0, as the emitted code reads them.
//
// The region runtime of the implicit heap (region_destroy, region_grow, region_contains, heap_used,
// heap_is_block, heap_reaches, state_release) went with chunk 15: regions are lifetime witnesses
// (chunk15_stack_memory_design.md §3.2), a frame's allocations live in its dynamic part (rt_frame.S) and
// an actor's state in its state chain (rt_state.S).
