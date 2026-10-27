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
// Regions hand back their memory here (silica_rt_region_destroy, called by the emitter's scope-exit
// release like the host's malloc/free helpers), which is what lets a loop that allocates and drops
// a region every iteration run indefinitely; before, free was a no-op and such loops exhausted the
// heap. Exhaustion is still a runtime abort ("[silica] abort: heap exhausted at 0x...", status 71)
// rather than a NULL the caller might not check.
//
// Both LX7 cores allocate (rt_actors.S runs actors on both): the free list and the bump pointer are
// guarded by one spin lock (S32C1I, the shape of rt_actors.S's FREE_LOCK). It is a leaf lock: nothing
// is called while it is held, so holding the scheduler or free-list lock around an allocation is fine.
// Free lists on top of this heap (actor stacks, ACBs, message nodes) keep their own lock in rt_actors.S.
//
//   silica_rt_heap_init()          reset the bump pointer and the free list (called once by rt_start)
//   silica_rt_alloc(size) -> ptr   8-byte aligned, zeroed; size is a 32-bit byte count; aborts when
//                                  the heap is exhausted (also silica_rt_region_alloc / _raw_alloc)
//   silica_rt_alloc_or_null(size)  the same, returning 0 instead of aborting
//   silica_rt_free(ptr)            return a block; 0, a pointer outside the heap and a block that is
//                                  not allocated (a double free) are ignored
//   silica_rt_region_destroy(r)    free a region's extension chain and its handle (also
//                                  silica_rt_region_free); a canonical arena is left alone, as on the host
//   silica_rt_heap_used() -> bytes in allocated blocks (headers included): the span below the bump
//                                  pointer less what sits on the free list; the heap_used() builtin
//   silica_rt_state_release(old, new, nbytes)   free an actor's previous state block unless the
//                                  new state still reaches it, see below
//   silica_rt_region_grow / silica_rt_region_contains   region blocks, see below

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

    .align  4
    .global silica_rt_alloc
    .global silica_rt_region_alloc
    .global silica_rt_raw_alloc
    .set    silica_rt_region_alloc, silica_rt_alloc    // the emitter's aggregate/pair allocations
    .set    silica_rt_raw_alloc, silica_rt_alloc       // alloc_region's first block
    .type   silica_rt_alloc, @function
silica_rt_alloc:
    entry   a1, 32
    mov     a10, a2
    call8   silica_rt_heap_take
    beqz    a10, 1f
    mov     a2, a10
    movi    a3, 0                 // the high word of the pair the emitter reads as X0
    retw
1:  call8   silica_rt_abort_heap_exhausted   // runtime abort, status 71; allocates nothing
    retw
    .size   silica_rt_alloc, . - silica_rt_alloc

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
    .global silica_rt_region_free
    .set    silica_rt_region_free, silica_rt_region_destroy   // region release: the whole chain
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
// silica_rt_region_destroy(region): free every extension block on the [region + 16] chain, then the
// handle. A null handle is a no-op, so a moved-out region is safe to skip. A canonical arena
// (rt_ordering.S: silica_rt_canonical_arena_lookup) is process-shared and belongs to the arena table,
// which hands the same block to every lookup of its key; a function that received one as a parameter
// destroys it like any region at scope exit, so a block registered in the table is left untouched,
// as the host's helper does.
    .align  4
    .global silica_rt_region_destroy
    .type   silica_rt_region_destroy, @function
silica_rt_region_destroy:
    entry   a1, 32
    beqz    a2, 4f
    movi    a3, silica_rt_canonical_arena_table   // 512 x (key: 8, region: 8)
    movi    a4, 512
1:  l32i    a5, a3, 8
    beq     a5, a2, 4f
    addi    a3, a3, 16
    addi    a4, a4, -1
    bnez    a4, 1b
    l32i    a3, a2, 16
2:  beqz    a3, 3f
    l32i    a4, a3, 16
    mov     a10, a3
    call8   silica_rt_free
    mov     a3, a4
    j       2b
3:  mov     a10, a2
    call8   silica_rt_free
4:  retw
    .size   silica_rt_region_destroy, . - silica_rt_region_destroy

// silica_rt_region_grow: called from the middle of an emitted allocation sequence when the current
// block is full. Convention inherited from the AArch64 helper: the region is X1 (here a4), the
// request is X7 (in this core's register block, THREADPTR + 32); every register the caller holds
// is preserved (a2-a7 untouched, a8-a15 are the caller's own scratch). A block holds at least 4096
// data bytes, or the 16-byte-rounded request when that is larger.
//
// Both cores may grow one canonical arena, so growth is serialized by silica_rt_region_lock (the
// shape of HEAP_LOCK; silica_rt_alloc's own heap lock nests inside it as a leaf). Under the lock
// the request is checked again, because the other core may already have attached a block this
// request fits; then the sentinel 0x80000000 (above every data address, and bump + request cannot
// wrap) is parked in the bump so no concurrent reservation (the emitted S32C1I loop,
// prims_memory@emit_region_bump_check) can land in the old block while the new one is being
// published, the block is chained, its end stored, and the bump last, with memw between so a
// reservation that reads the new bump reads the new end.
    .align  4
    .global silica_rt_region_grow
    .type   silica_rt_region_grow, @function
silica_rt_region_grow:
    entry   a1, 48
    rur     a8, threadptr
    l32i    a9, a8, 32            // X7 = the request
    addi    a9, a9, 15
    movi    a8, -16
    and     a9, a9, a8            // data bytes, rounded up to 16
    movi    a8, 4096
    bgeu    a9, a8, 1f
    mov     a9, a8
1:  s32i    a9, a1, 0             // keep the size across the call
    movi    a8, silica_rt_region_lock
2:  movi    a10, 0
    wsr     a10, scompare1
    movi    a10, 1
    s32c1i  a10, a8, 0
    bnez    a10, 2b
    rur     a8, threadptr         // under the lock: does the request fit now?
    l32i    a10, a8, 32
    l32i    a11, a4, 0            // bump
    l32i    a12, a4, 8            // end
    add     a10, a11, a10
    bgeu    a12, a10, 5f          // end >= bump + request: the other core grew it; retry
    movi    a10, 0x80000000       // sentinel: nothing reserves in the old block from here
    s32i    a10, a4, 0
    memw
    addi    a10, a9, 32
    call8   silica_rt_alloc       // never returns 0 (exhaustion aborts)
    l32i    a9, a1, 0
    addi    a8, a10, 32           // data start
    add     a9, a8, a9            // data end
    s32i    a9, a10, 24           // block's own span end
    l32i    a11, a4, 16           // chain the block in front of the region's extensions
    s32i    a11, a10, 16
    memw
    s32i    a10, a4, 16
    s32i    a9, a4, 8             // the end first
    memw
    s32i    a8, a4, 0             // then the bump: the region now reserves in the new block
5:  memw
    movi    a8, silica_rt_region_lock
    movi    a9, 0
    s32i    a9, a8, 0
    memw
    retw
    .size   silica_rt_region_grow, . - silica_rt_region_grow

// silica_rt_region_contains: ref X1 (a4), region X2 (a6) -> X5 (register block + 16) = 1 when the ref
// lies in the region's first block or any extension block; everything else preserved.
    .align  4
    .global silica_rt_region_contains
    .type   silica_rt_region_contains, @function
silica_rt_region_contains:
    entry   a1, 32
    addi    a8, a6, 32            // first block: [region + 32, [region + 24])
    l32i    a9, a6, 24
    bltu    a4, a8, 2f
    bltu    a4, a9, 3f
2:  l32i    a8, a6, 16            // extension blocks
1:  beqz    a8, 4f
    addi    a9, a8, 32
    bltu    a4, a9, 5f
    l32i    a9, a8, 24
    bltu    a4, a9, 3f
5:  l32i    a8, a8, 16
    j       1b
3:  movi    a8, 1
    j       6f
4:  movi    a8, 0
6:  rur     a9, threadptr
    s32i    a8, a9, 16
    movi    a8, 0
    s32i    a8, a9, 20
    retw
    .size   silica_rt_region_contains, . - silica_rt_region_contains

    .align  4
    .global silica_rt_heap_used
    .type   silica_rt_heap_used, @function
silica_rt_heap_used:
    entry   a1, 32
    HEAP_LOCK a8, a9
    movi    a3, silica_rt_heap_next
    l32i    a2, a3, 0
    movi    a4, _silica_heap_start
    sub     a2, a2, a4
    movi    a3, silica_rt_heap_free_head
    l32i    a4, a3, 0
1:  beqz    a4, 2f
    l32i    a5, a4, 0
    sub     a2, a2, a5
    l32i    a4, a4, 4
    j       1b
2:  HEAP_UNLOCK a8, a9
    movi    a3, 0
    retw
    .size   silica_rt_heap_used, . - silica_rt_heap_used

// silica_rt_heap_is_block(p) -> 1 when p is the payload of an allocated block. Leaf.
    .align  4
silica_rt_heap_is_block:
    entry   a1, 32
    movi    a4, 0
    beqz    a2, 9f
    movi    a3, _silica_heap_start
    bltu    a2, a3, 9f
    movi    a3, _silica_heap_end
    bgeu    a2, a3, 9f
    addi    a5, a2, -8
    l32i    a3, a5, 4
    movi    a6, HEAP_USED
    bne     a3, a6, 9f
    movi    a4, 1
9:  mov     a2, a4
    retw
    .size   silica_rt_heap_is_block, . - silica_rt_heap_is_block

// silica_rt_heap_reaches(target, block, nbytes, depth) -> 1 when target is one of the 8-byte
// slots of block, or of a heap block one of those slots names, up to depth levels further down.
// A heap block is scanned over its whole payload; anything else over nbytes (0: not at all), so
// a word that is a scalar or an address outside the heap is never followed. Slots hold a 32-bit
// address in the low word with the high word zero, as the emitted code lays composites out.
// Recursion bounded by `depth` (silica_rt_state_release passes 4): at most five frames of this
// function plus silica_rt_heap_is_block below the deepest. tools/main_stack_bound.py reads the
// declared bound instead of walking the recursion.
    .set    silica_rt_heap_reaches__stack_bound, 5 * 32 + 32
    .align  4
    .global silica_rt_heap_reaches             // rt_supervisors.S silica_rt_init_owners_reach
silica_rt_heap_reaches:
    entry   a1, 32
    movi    a6, 65536
    bltu    a3, a6, 8f            // an atom index or a small scalar names nothing
    mov     a10, a3
    call8   silica_rt_heap_is_block
    beqz    a10, 1f
    addi    a6, a3, -8
    l32i    a4, a6, 0
    addi    a4, a4, -8            // the payload
1:  beqz    a4, 8f
    add     a7, a3, a4            // a7 = end
    mov     a6, a3                // a6 = cursor
2:  bgeu    a6, a7, 8f
    l32i    a8, a6, 0
    beq     a8, a2, 9f
    beqz    a5, 3f
    mov     a10, a2
    mov     a11, a8
    movi    a12, 0
    addi    a13, a5, -1
    call8   silica_rt_heap_reaches
    bnez    a10, 9f
3:  addi    a6, a6, 8
    j       2b
8:  movi    a2, 0
    retw
9:  movi    a2, 1
    retw
    .size   silica_rt_heap_reaches, . - silica_rt_heap_reaches

// silica_rt_state_release(X0 old, X1 new, X2 nbytes): called by the emitted behaviour epilogue
// after it installed `new` as the actor's state (nbytes = the shell size of new's type, used
// when new is not a heap block), and by rt_actors.S for a message copy once the behaviour has
// read it (nbytes 0). `old` goes back to the heap unless it is not an allocated block (an atom,
// a frame-region or rodata address, a block already freed), is `new` itself, is still reachable
// from new -- its slots, and the slots of the blocks they name, four levels down; the emitter
// moves one level, so a state that packs its predecessor keeps it alive -- or is the spec init
// a supervised child's row keeps for restarts (rt_supervisors.S ROW_INIT).
#define ACB_ROW  76
#define ROW_INIT 24
    .align  4
    .global silica_rt_state_release
    .type   silica_rt_state_release, @function
silica_rt_state_release:
    entry   a1, 32
    beqz    a2, 9f
    beq     a2, a4, 9f
    mov     a10, a2
    call8   silica_rt_heap_is_block
    beqz    a10, 9f
    call8   silica_rt_current_actor
    beqz    a10, 1f
    l32i    a5, a10, ACB_ROW
    beqz    a5, 1f
    l32i    a5, a5, ROW_INIT
    beq     a5, a2, 9f
1:  mov     a10, a2
    mov     a11, a4
    mov     a12, a6
    movi    a13, 4
    call8   silica_rt_heap_reaches
    bnez    a10, 9f
    mov     a10, a2
    call8   silica_rt_free
9:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_state_release, . - silica_rt_state_release
