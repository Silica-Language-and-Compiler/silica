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

// The state chain and the runtime copier on the STM32L476RG (chunk15_stack_memory_design.md §2.6, §4,
// §5): the ESP32-S3 port's rt_state.S re-expressed in Thumb-2, kept behaviour for behaviour.
//
// THE STATE CHAIN. An actor's state nodes live in a chain of heap chunks of its own (SRAM1 arena),
// disjoint from every frame (ACB_SCHAIN the first, ACB_SCUR the one bumps come from): 2048 bytes first,
// doubling to SCH_CAP (8 KB here; 16 KB on the ESP32-S3, whose heap is four times larger). A chunk: [0]
// next, [4] size, [8] bump cursor, [12] end (= chunk + size); the first chunk also holds the 129
// free-list heads after its header (head i for nodes of 8 * (i + 1) bytes, i = 0..127; head 128 for
// every size above 1,024, the node's size in its word at +4). Every node has an exact size, a multiple
// of 8, known from its descriptor; nodes never move once placed (decision 21) except by a compaction,
// which builds a fresh chain. ACB_SBYTES counts the bytes allocated and not freed. The release log
// (ACB_SLOG: [0] capacity, (node, bytes) entries from +8, ACB_SLOGN the count) starts at SLOG_FIRST
// entries and doubles.
//
// THE COPIER walks a value through the descriptors the emitter spells (terms/term_message_copy.silica:
// KIND 0 word, 1 region witness, 2 REF1, 3 REFTUP, 4 AGG, 5 SUM, 6 BUF, 7 LIST, 8 STRING, 9 closure),
// given in the ROOT-WORD form `.quad 1, -1; .quad KIND, AUX` (16-byte entries, the low word read). The
// data words are 8 bytes (lo, hi), a pointer in the low word; a value below 65536 is an atom, nil or a
// small scalar and travels as it is. Sizes: an aggregate N * 8; a REF1 cell 8; a REFTUP cell 8 plus its
// payload rounded to 16; a buffer its count word plus the elements rounded to 8; a list handle 24 and
// 24 per chunk of its spine; a run-time string 24 + bytes + 1 rounded to 8. Sharing through refs is kept
// by one table (source -> copy, open addressing, a heap block) per copy; a state copy empties it before
// each slot (a ref, list, string or buffer reached through the aggregate spine) so two slots never share
// a node afterwards (P5). Two passes: the measure (pass 0) adds the bytes of every new node to
// CCB_TOTAL; the copy (pass 1) places every node. "Old" nodes are kept as they are, not followed:
// CCB_OMODE 0 none, 1 a node of the actor's state chain (the dispatch end's evacuation), 2 the FRAME
// RULE (a node is new when it lies in [C0 limit, p) or in a chunk above C0, p being the pre-call SP and
// C0 its chunk). The destination: CCB_DMODE 0 a BUMP cursor (CCB_CUR .. CCB_END, an overrun is the abort
// "copier overrun"; every pointer is written as the cursor plus CCB_DELTA, which main's evacuation uses
// to copy into scratch and move the block up as bytes), 1 the CHAIN (a free-list hole of the node's
// size, else a bump from the state chain). Internal routines are AAPCS (r0-r3 and r12 clobbered, r4-r8
// kept; r9 is TP and r10/r11 are never touched here), locals are stack slots, and the recursion through
// the descriptors (at most 13 levels, term_message_copy caps the depth at 12) costs about 80 bytes of
// machine stack per level (rt_sc_val 56 + rt_sc_fields 20), under 1.2 KB in all with the entry's own
// frame: inside the _silica_rt_depth_reserve + MCHUNK_HEADROOM (512 + 1,024 bytes) that every machine
// chunk keeps below its limit for runtime chains.
//
// The copy control block (CCB, one on this single-core part, silica_rt_ccb_block; VRG_CCB is not
// consulted): [0] dest mode (0 bump, 1 chain), [4] old mode (0 none, 1 chain node = old, 2 frame
// rule), [8] bump cursor, [12] bump end, [16] delta (added to every pointer written), [20] acb, [24] p
// (frame rule: the pre-call SP), [28] C0 (frame rule: p's chunk), [32] table, [36] spine (1: empty the
// table at the next slot), [40] total (measure), [44] nodes (measure), [48] pass (0 measure, 1 copy).
//
// Entries emitted code calls (X0 = r0:r1, X1 = r2:r3, X2 = r4:r5; every register but r10, r11, lr and
// the results is kept: ENTRY_SAVE / ENTRY_RET):
//   silica_rt_message_buffer(X0 value, X1 desc) -> X0 root, X1 bytes, X2 block (0, 0: inline)
//   silica_rt_message_forward(X0 value, X1 desc, X2 fn) -> the same
//   silica_rt_reply_place(X0 value, X1 desc) -> X0 the copy's root in the blocked caller's auxiliary chain
//   silica_rt_state_retire(X0 node, X1 bytes)    silica_rt_state_retain_node(X0 n) -> X0 elements
//   silica_rt_state_area_bytes() -> X0           silica_rt_compact_state() -> X0 = 0
// AAPCS (rt_actors.S, rt_frame.S):
//   silica_rt_state_install(r0 = acb, r1:r2 = value, r3 = descriptor or 0)   -> r0 = 0
//   silica_rt_state_dispatch_end(r0 = acb, r1:r2 = the new state)            -> r0:r1 the root
//   silica_rt_state_alloc(r0 = acb, r1 = bytes) -> r0 node or 0   silica_rt_state_free(r0 acb, r1 node, r2 bytes)
//   silica_rt_state_hole_pop(r0 = acb, r1 = bytes) -> r0 node or 0  silica_rt_state_contains(r0 acb, r1 ptr) -> 0/1
//   silica_rt_state_chain_init(r0 = acb)   silica_rt_state_chain_free_all(r0 = acb)   silica_rt_state_log_drain(r0 = acb)
//   silica_rt_frame_measure(r0 = value lo, r1 = kind, r2 = aux, r3 = p, [sp] = C0) -> r0 = bytes
//                                                  (rounded to 16; 0: nothing new)
//   silica_rt_frame_copy_delta(r0 = delta)
//   silica_rt_frame_copy(r0:r1 = value, r2 = kind, r3 = aux, [sp] = dest low) -> r0:r1 the root

#include "rt_defs.h"

#define CCB_DMODE        0
#define CCB_OMODE        4
#define CCB_CUR          8
#define CCB_END          12
#define CCB_DELTA        16
#define CCB_ACB          20
#define CCB_P            24
#define CCB_C0           28
#define CCB_TAB          32
#define CCB_SPINE        36
#define CCB_TOTAL        40
#define CCB_NODES        44
#define CCB_PASS         48
#define CCB_SIZE         64

#define SCH_NEXT         0
#define SCH_SIZE         4
#define SCH_CUR          8
#define SCH_END          12
#define SCH_HEADER       16
#define SCH_HEADS        16      /* 129 words in the first chunk */
#define SCH_HEADS_BYTES  520
#define SCH_FIRST        2048
#define SCH_CAP          8192
#define SLOG_FIRST       16

#define TAB_CAP          0
#define TAB_COUNT        4
#define TAB_ENTRIES      8      /* (key, value) pairs */

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

    .section .bss.silica_rt_state, "aw", %nobits
    .balign 16
silica_rt_ccb_block:
    .space  CCB_SIZE

    .section .text.silica_rt_state, "ax", %progbits

// ---- the state chain ------------------------------------------------------------------------------
// rt_schunk_new(r0 = bytes the chunk must hold beyond its header) -> r0 = a zeroed chunk (cursor at its
// header's end), 0 when the heap is exhausted.
    LFUNC rt_schunk_new
    push    {r4, lr}
    mov     r4, r0
    add     r0, r4, #SCH_HEADER
    bl      silica_rt_alloc_or_null
    cmp     r0, #0
    beq.w   9f
    movw    r1, #0
    str     r1, [r0, #SCH_NEXT]
    add     r1, r4, #SCH_HEADER
    str     r1, [r0, #SCH_SIZE]
    add     r1, r1, r0
    str     r1, [r0, #SCH_END]
    add     r1, r0, #SCH_HEADER
    str     r1, [r0, #SCH_CUR]
9:  pop     {r4, pc}
    .size   rt_schunk_new, . - rt_schunk_new

// silica_rt_state_chain_init(r0 = acb): the first chunk with empty heads (the block comes zeroed);
// nothing when one exists.
    FUNC silica_rt_state_chain_init
    push    {r4, lr}
    mov     r4, r0
    ldr     r0, [r4, #ACB_SCHAIN]
    cmp     r0, #0
    bne.w   9f
    movw    r0, #SCH_FIRST
    bl      rt_schunk_new
    cmp     r0, #0
    beq.w   8f
    str     r0, [r4, #ACB_SCHAIN]
    str     r0, [r4, #ACB_SCUR]
    addw    r1, r0, #(SCH_HEADS + SCH_HEADS_BYTES)
    str     r1, [r0, #SCH_CUR]
    movw    r1, #0
    str     r1, [r4, #ACB_SBYTES]
9:  pop     {r4, pc}
8:  bl      silica_rt_abort_heap_exhausted
    .size   silica_rt_state_chain_init, . - silica_rt_state_chain_init

// silica_rt_state_hole_pop(r0 = acb, r1 = bytes) -> r0 = a free node of exactly that size, or 0. Leaf.
    FUNC silica_rt_state_hole_pop
    ldr     r2, [r0, #ACB_SCHAIN]
    cmp     r2, #0
    beq.w   9f
    cmp     r1, #1024
    bhi.w   2f
    lsr     r3, r1, #3
    sub     r3, r3, #1
    add     r3, r2, r3, lsl #2              // + SCH_HEADS: head n/8 - 1
    ldr     r0, [r3, #SCH_HEADS]
    cmp     r0, #0
    beq.w   9f
    ldr     r12, [r0, #0]
    str     r12, [r3, #SCH_HEADS]
    bx      lr
2:  addw    r3, r2, #(SCH_HEADS + 128 * 4)  // head 128: a node of exactly n bytes, its size at +4
    ldr     r0, [r3]
3:  cmp     r0, #0
    beq.w   9f
    ldr     r12, [r0, #4]
    cmp     r12, r1
    beq.w   4f
    mov     r3, r0                          // the link word of a node is its word 0, as the head's
    ldr     r0, [r0, #0]
    b.w     3b
4:  ldr     r12, [r0, #0]
    str     r12, [r3, #0]
    bx      lr
9:  movw    r0, #0
    bx      lr
    .size   silica_rt_state_hole_pop, . - silica_rt_state_hole_pop

// silica_rt_state_alloc(r0 = acb, r1 = bytes) -> r0 = the node or 0: a hole of the size, else a bump
// from the current chunk, else a fresh chunk (doubling to SCH_CAP, or the node's size when larger).
    FUNC silica_rt_state_alloc
    push    {r4-r6, lr}
    mov     r4, r0
    mov     r5, r1
    bl      silica_rt_state_chain_init
    mov     r0, r4
    mov     r1, r5
    bl      silica_rt_state_hole_pop
    cmp     r0, #0
    bne.w   7f
    ldr     r6, [r4, #ACB_SCUR]
    ldr     r0, [r6, #SCH_CUR]
    add     r1, r0, r5
    ldr     r2, [r6, #SCH_END]
    cmp     r1, r2
    bhi.w   2f
    str     r1, [r6, #SCH_CUR]
    b.w     7f
2:  ldr     r0, [r6, #SCH_SIZE]
    lsl     r0, r0, #1
    cmp     r0, #SCH_CAP
    it      hi
    movhi   r0, #SCH_CAP
    cmp     r0, r5
    it      lo
    movlo   r0, r5
    bl      rt_schunk_new
    cmp     r0, #0
    beq.w   9f
    str     r0, [r6, #SCH_NEXT]
    str     r0, [r4, #ACB_SCUR]
    ldr     r1, [r0, #SCH_CUR]
    add     r2, r1, r5
    str     r2, [r0, #SCH_CUR]
    mov     r0, r1
7:  ldr     r1, [r4, #ACB_SBYTES]
    add     r1, r1, r5
    str     r1, [r4, #ACB_SBYTES]
    pop     {r4-r6, pc}
9:  movw    r0, #0
    pop     {r4-r6, pc}
    .size   silica_rt_state_alloc, . - silica_rt_state_alloc

// silica_rt_state_free(r0 = acb, r1 = node, r2 = bytes): the node goes on the list for its size. Leaf.
    FUNC silica_rt_state_free
    ldr     r3, [r0, #ACB_SCHAIN]
    cmp     r3, #0
    beq.w   9f
    cmp     r1, #0
    beq.w   9f
    cmp     r2, #1024
    bhi.w   2f
    lsr     r12, r2, #3
    sub     r12, r12, #1
    add     r12, r3, r12, lsl #2
    ldr     r3, [r12, #SCH_HEADS]
    str     r3, [r1, #0]
    str     r1, [r12, #SCH_HEADS]
    b.w     3f
2:  addw    r12, r3, #(SCH_HEADS + 128 * 4)
    ldr     r3, [r12]
    str     r3, [r1, #0]
    str     r2, [r1, #4]
    str     r1, [r12]
3:  ldr     r3, [r0, #ACB_SBYTES]
    sub     r3, r3, r2
    str     r3, [r0, #ACB_SBYTES]
9:  bx      lr
    .size   silica_rt_state_free, . - silica_rt_state_free

// silica_rt_state_contains(r0 = acb, r1 = ptr) -> r0 = 1 when ptr lies in a node area of the chain. Leaf.
    FUNC silica_rt_state_contains
    ldr     r2, [r0, #ACB_SCHAIN]
1:  cmp     r2, #0
    beq.w   9f
    add     r3, r2, #SCH_HEADER
    ldr     r12, [r2, #SCH_END]
    cmp     r1, r3
    blo.w   2f
    cmp     r1, r12
    blo.w   8f
2:  ldr     r2, [r2, #SCH_NEXT]
    b.w     1b
8:  movw    r0, #1
    bx      lr
9:  movw    r0, #0
    bx      lr
    .size   silica_rt_state_contains, . - silica_rt_state_contains

// silica_rt_state_chain_free_all(r0 = acb): every chunk and the release log go back (the actor's end).
    FUNC silica_rt_state_chain_free_all
    push    {r4, lr}
    mov     r4, r0
    ldr     r0, [r4, #ACB_SCHAIN]
    bl      rt_schain_free
    movw    r0, #0
    str     r0, [r4, #ACB_SCHAIN]
    str     r0, [r4, #ACB_SCUR]
    str     r0, [r4, #ACB_SBYTES]
    ldr     r0, [r4, #ACB_SLOG]
    cmp     r0, #0
    beq.w   1f
    bl      silica_rt_free
    movw    r0, #0
    str     r0, [r4, #ACB_SLOG]
1:  movw    r0, #0
    str     r0, [r4, #ACB_SLOGN]
    str     r0, [r4, #ACB_SLOGN + 4]
    pop     {r4, pc}
    .size   silica_rt_state_chain_free_all, . - silica_rt_state_chain_free_all

// rt_schain_free(r0 = first chunk): the chain goes back.
    LFUNC rt_schain_free
    push    {r4, lr}
    mov     r4, r0
1:  cmp     r4, #0
    beq.w   9f
    mov     r0, r4
    ldr     r4, [r4, #SCH_NEXT]
    bl      silica_rt_free
    b.w     1b
9:  pop     {r4, pc}
    .size   rt_schain_free, . - rt_schain_free

// ==== THE COPIER (frame mode) =====================================================================
// Every routine below is AAPCS: r0-r3, r12 clobbered, r4-r8 kept, r9-r11 untouched.

// ---- the CCB -------------------------------------------------------------------------------------
// rt_ccb_reset(r0 = dest mode, r1 = old mode, r2 = acb, r3 = spine) -> r0 = the CCB: a fresh control
// block for a measure (pass 0); the copy pass keeps it and sets its cursor. The table is made on the
// first ref.
    LFUNC rt_ccb_reset
    MOV32   r12, silica_rt_ccb_block
    str     r0, [r12, #CCB_DMODE]
    str     r1, [r12, #CCB_OMODE]
    str     r2, [r12, #CCB_ACB]
    str     r3, [r12, #CCB_SPINE]
    movw    r0, #0
    str     r0, [r12, #CCB_CUR]
    str     r0, [r12, #CCB_END]
    str     r0, [r12, #CCB_DELTA]
    str     r0, [r12, #CCB_TAB]
    str     r0, [r12, #CCB_TOTAL]
    str     r0, [r12, #CCB_NODES]
    str     r0, [r12, #CCB_PASS]
    mov     r0, r12
    bx      lr
    .size   rt_ccb_reset, . - rt_ccb_reset

// ---- the table: source pointer -> copy, open addressing, doubled at half load ----------------------
// rt_tab_find(r0 = key) -> r0 = value, 0 when absent.
    LFUNC rt_tab_find
    MOV32   r12, silica_rt_ccb_block
    ldr     r1, [r12, #CCB_TAB]
    cmp     r1, #0
    beq.w   9f
    ldr     r2, [r1, #TAB_CAP]
    sub     r2, r2, #1                      // mask
    lsr     r3, r0, #3
    and     r3, r3, r2                      // slot
1:  add     r12, r1, r3, lsl #3
    ldr     r12, [r12, #TAB_ENTRIES]
    cmp     r12, #0
    beq.w   9f
    cmp     r12, r0
    beq.w   2f
    add     r3, r3, #1
    and     r3, r3, r2
    b.w     1b
2:  add     r12, r1, r3, lsl #3
    ldr     r0, [r12, #TAB_ENTRIES + 4]
    bx      lr
9:  movw    r0, #0
    bx      lr
    .size   rt_tab_find, . - rt_tab_find

// rt_tab_insert(r0 = key, r1 = value, r2 = table): the probe and store (the key is absent).
    LFUNC rt_tab_insert
    push    {r4, r5}
    ldr     r3, [r2, #TAB_CAP]
    sub     r3, r3, #1
    lsr     r4, r0, #3
    and     r4, r4, r3
1:  add     r5, r2, r4, lsl #3
    ldr     r12, [r5, #TAB_ENTRIES]
    cmp     r12, #0
    beq.w   2f
    add     r4, r4, #1
    and     r4, r4, r3
    b.w     1b
2:  str     r0, [r5, #TAB_ENTRIES]
    str     r1, [r5, #TAB_ENTRIES + 4]
    ldr     r12, [r2, #TAB_COUNT]
    add     r12, r12, #1
    str     r12, [r2, #TAB_COUNT]
    pop     {r4, r5}
    bx      lr
    .size   rt_tab_insert, . - rt_tab_insert

// rt_tab_new(r0 = capacity, a power of two) -> r0 = a zeroed table (a heap block).
    LFUNC rt_tab_new
    push    {r4, r5, lr}
    mov     r4, r0
    lsl     r5, r4, #3
    add     r5, r5, #TAB_ENTRIES
    mov     r0, r5
    bl      silica_rt_alloc
    mov     r1, r5
    mov     r5, r0
    bl      silica_rt_zero_block
    str     r4, [r5, #TAB_CAP]
    mov     r0, r5
    pop     {r4, r5, pc}
    .size   rt_tab_new, . - rt_tab_new

// rt_tab_grow(r0 = table) -> r0 = a table of twice the capacity holding the same entries; the old freed.
    LFUNC rt_tab_grow
    push    {r4-r7, lr}
    mov     r4, r0
    ldr     r0, [r4, #TAB_CAP]
    lsl     r0, r0, #1
    bl      rt_tab_new
    mov     r5, r0
    ldr     r6, [r4, #TAB_CAP]
    add     r7, r4, #TAB_ENTRIES
1:  cmp     r6, #0
    beq.w   2f
    ldr     r0, [r7, #0]
    cmp     r0, #0
    beq.w   3f
    ldr     r1, [r7, #4]
    mov     r2, r5
    bl      rt_tab_insert
3:  add     r7, r7, #8
    sub     r6, r6, #1
    b.w     1b
2:  mov     r0, r4
    bl      silica_rt_free
    mov     r0, r5
    pop     {r4-r7, pc}
    .size   rt_tab_grow, . - rt_tab_grow

// rt_tab_put(r0 = key, r1 = value): inserts (the key is absent). Grows the table first when half full.
    LFUNC rt_tab_put
    push    {r4-r6, lr}
    mov     r4, r0
    mov     r5, r1
    MOV32   r6, silica_rt_ccb_block
    ldr     r0, [r6, #CCB_TAB]
    cmp     r0, #0
    bne.w   1f
    movw    r0, #64
    bl      rt_tab_new
    str     r0, [r6, #CCB_TAB]
1:  ldr     r1, [r0, #TAB_COUNT]
    add     r1, r1, #1
    ldr     r2, [r0, #TAB_CAP]
    lsr     r2, r2, #1
    cmp     r1, r2
    blo.w   2f
    bl      rt_tab_grow
    str     r0, [r6, #CCB_TAB]
2:  mov     r2, r0
    mov     r0, r4
    mov     r1, r5
    bl      rt_tab_insert
    pop     {r4-r6, pc}
    .size   rt_tab_put, . - rt_tab_put

// rt_tab_clear(): the next slot of a state copy starts with an empty table (the block is kept).
    LFUNC rt_tab_clear
    push    {r4, lr}
    MOV32   r12, silica_rt_ccb_block
    ldr     r4, [r12, #CCB_TAB]
    cmp     r4, #0
    beq.w   9f
    ldr     r1, [r4, #TAB_CAP]
    lsl     r1, r1, #3
    add     r0, r4, #TAB_ENTRIES
    bl      silica_rt_zero_block
    movw    r0, #0
    str     r0, [r4, #TAB_COUNT]
9:  pop     {r4, pc}
    .size   rt_tab_clear, . - rt_tab_clear

// rt_tab_drop(): frees the table after a measure or a copy.
    LFUNC rt_tab_drop
    push    {r4, lr}
    MOV32   r4, silica_rt_ccb_block
    ldr     r0, [r4, #CCB_TAB]
    cmp     r0, #0
    beq.w   9f
    bl      silica_rt_free
    movw    r0, #0
    str     r0, [r4, #CCB_TAB]
9:  pop     {r4, pc}
    .size   rt_tab_drop, . - rt_tab_drop

// ---- descriptor access ----------------------------------------------------------------------------
// An entry: 16 bytes, KIND at +0, AUX at +8 (low words). A descriptor: N at +0, RIDX at +8, entries
// from +16. The root-word form has N = 1.

// rt_is_old(r0 = ptr) -> r0 = 1 when the node must be kept as it is (old mode): a chain node (mode 1),
// or, under the frame rule (mode 2), a pointer that is neither in [C0 limit, p) nor in a chunk above C0.
    LFUNC rt_is_old
    MOV32   r12, silica_rt_ccb_block
    ldr     r1, [r12, #CCB_OMODE]
    cmp     r1, #0
    beq.w   9f
    cmp     r1, #2
    beq.w   2f
    mov     r1, r0                          // mode 1: is it a node of the actor's state chain?
    ldr     r0, [r12, #CCB_ACB]
    b.w     silica_rt_state_contains
2:  ldr     r2, [r12, #CCB_C0]
    ldr     r3, [r2, #CH_LIMIT]
    ldr     r1, [r12, #CCB_P]
    cmp     r0, r3
    blo.w   3f
    cmp     r0, r1
    bhs.w   3f
    b.w     9f                              // in the callee's part of C0: new
3:  ldr     r2, [r2, #CH_NEXT]
4:  cmp     r2, #0
    beq.w   8f
    ldr     r3, [r2, #CH_LIMIT]
    ldr     r1, [r2, #CH_TOP]
    cmp     r0, r3
    blo.w   5f
    cmp     r0, r1
    blo.w   9f                              // in a chunk above C0: new
5:  ldr     r2, [r2, #CH_NEXT]
    b.w     4b
8:  movw    r0, #1
    bx      lr
9:  movw    r0, #0
    bx      lr
    .size   rt_is_old, . - rt_is_old

// rt_place(r0 = bytes, a multiple of 8) -> r0 = where the node's bytes are written, r1 = the address
// the copy's pointers hold (dest + delta). Bump mode: the cursor (an overrun aborts: the measure and
// the copy disagree); chain mode: a hole of the size, else a chain node (dest = final).
    LFUNC rt_place
    MOV32   r12, silica_rt_ccb_block
    ldr     r1, [r12, #CCB_DMODE]
    cmp     r1, #0
    bne.w   2f
    ldr     r1, [r12, #CCB_CUR]
    add     r2, r1, r0
    ldr     r3, [r12, #CCB_END]
    cmp     r3, r2
    blo.w   8f
    str     r2, [r12, #CCB_CUR]
    ldr     r3, [r12, #CCB_DELTA]
    mov     r0, r1
    add     r1, r1, r3
    bx      lr
2:  push    {r4, lr}
    mov     r1, r0
    ldr     r0, [r12, #CCB_ACB]
    bl      silica_rt_state_alloc
    cmp     r0, #0
    beq.w   7f
    mov     r1, r0
    pop     {r4, pc}
7:  bl      silica_rt_region_alloc_failed
8:  push    {lr}
    bl      silica_rt_abort_copier_overrun
    .size   rt_place, . - rt_place

// rt_slot_enter() -> r0 = the saved spine flag / rt_slot_leave(r0 = that flag): a state copy empties
// the table before a slot (a ref, list, string, buffer reached through the aggregate spine) and keeps
// it within the slot. An evacuation never sets the flag.
    LFUNC rt_slot_enter
    push    {r4, r5, lr}
    MOV32   r4, silica_rt_ccb_block
    ldr     r5, [r4, #CCB_SPINE]
    cmp     r5, #0
    beq.w   9f
    bl      rt_tab_clear
    movw    r0, #0
    str     r0, [r4, #CCB_SPINE]
9:  mov     r0, r5
    pop     {r4, r5, pc}
    .size   rt_slot_enter, . - rt_slot_enter

    LFUNC rt_slot_leave
    MOV32   r12, silica_rt_ccb_block
    str     r0, [r12, #CCB_SPINE]
    bx      lr
    .size   rt_slot_leave, . - rt_slot_leave

// rt_sm_add(r0 = bytes): one more node of that many bytes.
    LFUNC rt_sm_add
    MOV32   r12, silica_rt_ccb_block
    ldr     r1, [r12, #CCB_TOTAL]
    add     r1, r1, r0
    str     r1, [r12, #CCB_TOTAL]
    ldr     r1, [r12, #CCB_NODES]
    add     r1, r1, #1
    str     r1, [r12, #CCB_NODES]
    bx      lr
    .size   rt_sm_add, . - rt_sm_add

// rt_sum_desc(r0 = value, r1 = the sum table) -> r0 = the matching alternative's descriptor, or 0.
// The table: -1-M at +0, then M pairs (TAG at +0, DESC at +8, 16 bytes each) from +8, matched against
// the value's first word (a tuple alternative's tag atom, a record alternative's shape number).
    LFUNC rt_sum_desc
    ldr     r2, [r1, #0]
    mvn     r2, r2                          // M = -1 - word
    ldr     r3, [r0, #0]
    add     r1, r1, #8
1:  cmp     r2, #0
    beq.w   9f
    ldr     r12, [r1, #0]
    cmp     r12, r3
    beq.w   2f
    add     r1, r1, #16
    sub     r2, r2, #1
    b.w     1b
2:  ldr     r0, [r1, #8]
    bx      lr
9:  movw    r0, #0
    bx      lr
    .size   rt_sum_desc, . - rt_sum_desc

// rt_buf_bytes(r0 = buffer elements, r1 = element bytes) -> r0 = the node's bytes: the count word at
// [buf - 8] plus count * elem rounded to 8.
    LFUNC rt_buf_bytes
    ldr     r2, [r0, #-8]
    mul     r2, r2, r1
    add     r2, r2, #15
    bic     r0, r2, #7
    bx      lr
    .size   rt_buf_bytes, . - rt_buf_bytes

// rt_string_bytes(r0 = string) -> r0 = 24 + bytes + 1 rounded to 8 (the byte count is the header's
// third word, [16]).
    LFUNC rt_string_bytes
    ldr     r1, [r0, #16]
    add     r1, r1, #32
    bic     r0, r1, #7
    bx      lr
    .size   rt_string_bytes, . - rt_string_bytes

// ---- the measure (pass 0) -------------------------------------------------------------------------
// rt_sm_val(r0 = value lo, r1 = kind, r2 = aux): adds the bytes of the value's copy to CCB_TOTAL.
// Frame: push {r4-r8, lr} + 8 (a list's SLOT at [sp, #0], CDATA at [sp, #4]).
    LFUNC rt_sm_val
    cmp     r0, #65536
    blo.w   9f                              // an atom, nil, a small scalar: a word
    push    {r4-r8, lr}
    sub     sp, #8
    mov     r4, r0                          // the value
    mov     r5, r2                          // aux
    cmp     r1, #2
    beq.w   2f
    cmp     r1, #3
    beq.w   3f
    cmp     r1, #4
    beq.w   4f
    cmp     r1, #5
    beq.w   5f
    cmp     r1, #6
    beq.w   6f
    cmp     r1, #7
    beq.w   7f
    cmp     r1, #8
    beq.w   8f
    b.w     10f                             // 0 word, 1 region, 9 closure, unknown
9:  bx      lr
    // every node kind: an old node is kept, not followed
    // REF1: a cell of one word, its content by the one-entry descriptor at aux
2:  mov     r0, r4
    bl      rt_is_old
    cmp     r0, #0
    bne.w   10f
    bl      rt_slot_enter
    mov     r6, r0
    mov     r0, r4
    bl      rt_tab_find
    cmp     r0, #0
    bne.w   29f
    mov     r0, r4
    movw    r1, #1
    bl      rt_tab_put
    movw    r0, #8
    bl      rt_sm_add
    ldr     r0, [r4, #0]
    ldr     r1, [r5, #16]
    ldr     r2, [r5, #24]
    bl      rt_sm_val
29: mov     r0, r6
    bl      rt_slot_leave
    b.w     10f
    // REFTUP: a cell word pointing at a payload tuple; one node of 8 + the payload rounded to 16
3:  mov     r0, r4
    bl      rt_is_old
    cmp     r0, #0
    bne.w   10f
    bl      rt_slot_enter
    mov     r6, r0
    mov     r0, r4
    bl      rt_tab_find
    cmp     r0, #0
    bne.w   29b
    mov     r0, r4
    movw    r1, #1
    bl      rt_tab_put
    ldr     r0, [r5, #0]                    // N of the payload
    lsl     r0, r0, #3
    add     r0, r0, #15
    bic     r0, r0, #15
    add     r0, r0, #8
    bl      rt_sm_add
    ldr     r0, [r4, #0]                    // the payload tuple's words (0: an empty cell)
    cmp     r0, #0
    beq.w   29b
    mov     r1, r5
    bl      rt_sm_fields
    b.w     29b
    // AGG: N words
4:  mov     r0, r4
    bl      rt_is_old
    cmp     r0, #0
    bne.w   10f
41: ldr     r0, [r5, #0]
    lsl     r0, r0, #3
    bl      rt_sm_add
    mov     r0, r4
    mov     r1, r5
    bl      rt_sm_fields
    b.w     10f
    // SUM: the alternative's descriptor, then as AGG; an unknown alternative travels as a word
5:  mov     r0, r4
    bl      rt_is_old
    cmp     r0, #0
    bne.w   10f
    mov     r0, r4
    mov     r1, r5
    bl      rt_sum_desc
    cmp     r0, #0
    beq.w   10f
    mov     r5, r0
    b.w     41b
    // BUF: the count word and the elements
6:  mov     r0, r4
    bl      rt_is_old
    cmp     r0, #0
    bne.w   10f
    bl      rt_slot_enter
    mov     r6, r0
    mov     r0, r4
    mov     r1, r5
    bl      rt_buf_bytes
    bl      rt_sm_add
    b.w     29b
    // LIST: the handle, then the spine chunk by chunk, each element by the element entry
7:  mov     r0, r4
    bl      rt_is_old
    cmp     r0, #0
    bne.w   10f
    bl      rt_slot_enter
    mov     r6, r0
    movw    r0, #24
    bl      rt_sm_add
    ldr     r0, [r5, #8]                    // SLOT: the chunk slot bytes; a chunk is 2 slots, next, claim
    str     r0, [sp, #0]
    lsl     r0, r0, #1
    str     r0, [sp, #4]                    // CDATA
    ldr     r7, [r4, #0]                    // elements left
    ldr     r8, [r4, #8]                    // chunk
    ldr     r4, [r4, #16]                   // cursor
71: cmp     r7, #0
    beq.w   29b
    cmp     r8, #0
    beq.w   29b
    ldr     r0, [sp, #4]
    add     r0, r0, #16
    bl      rt_sm_add
72: ldr     r0, [sp, #4]
    cmp     r4, r0
    bhs.w   73f
    cmp     r7, #0
    beq.w   29b
    ldr     r0, [sp, #0]
    cmp     r0, #8
    bne.w   74f                             // an inline aggregate slot: its words travel as they are
    ldr     r0, [r8, r4]
    ldr     r1, [r5, #16]
    ldr     r2, [r5, #24]
    bl      rt_sm_val
74: ldr     r0, [sp, #0]
    add     r4, r4, r0
    sub     r7, r7, #1
    b.w     72b
73: ldr     r0, [sp, #4]
    ldr     r8, [r8, r0]                    // the next chunk
    movw    r4, #0
    b.w     71b
    // STRING: a literal (marker -2) is a word; a run-time string 24 + bytes + NUL
8:  ldr     r0, [r4, #0]
    adds    r0, r0, #2
    beq.w   10f
    mov     r0, r4
    bl      rt_is_old
    cmp     r0, #0
    bne.w   10f
    bl      rt_slot_enter
    mov     r6, r0
    mov     r0, r4
    bl      rt_string_bytes
    bl      rt_sm_add
    b.w     29b
10: add     sp, #8
    pop     {r4-r8, pc}
    .size   rt_sm_val, . - rt_sm_val

// rt_sm_fields(r0 = node, r1 = descriptor): every word of the aggregate by its entry.
    LFUNC rt_sm_fields
    push    {r4-r6, lr}
    ldr     r4, [r1, #0]                    // N
    add     r5, r1, #16                     // entry
    mov     r6, r0
1:  cmp     r4, #0
    beq.w   9f
    ldr     r0, [r6, #0]
    ldr     r1, [r5, #0]
    ldr     r2, [r5, #8]
    bl      rt_sm_val
    add     r6, r6, #8
    add     r5, r5, #16
    sub     r4, r4, #1
    b.w     1b
9:  pop     {r4-r6, pc}
    .size   rt_sm_fields, . - rt_sm_fields

// ---- the copy (pass 1) ----------------------------------------------------------------------------
// rt_sc_val(r0:r1 = value, r2 = kind, r3 = aux) -> r0:r1 the word the copy holds. Frame: push {r4-r8,
// lr} + 32: [0] dest, [4] final, [8] bytes / elements left, [12] where the next list chunk's final
// address is stored, [16] SLOT, [20] CDATA, [24] dest chunk. r4 = value lo (a list's cursor later),
// r5 = aux, r6 = the saved spine flag, r7 = a list's source chunk / a result, r8 = value hi.
    LFUNC rt_sc_val
    cmp     r0, #65536
    blo.w   9f
    push    {r4-r8, lr}
    sub     sp, #32
    mov     r4, r0
    mov     r8, r1
    mov     r5, r3
    cmp     r2, #2
    beq.w   2f
    cmp     r2, #3
    beq.w   3f
    cmp     r2, #4
    beq.w   4f
    cmp     r2, #5
    beq.w   5f
    cmp     r2, #6
    beq.w   6f
    cmp     r2, #7
    beq.w   7f
    cmp     r2, #8
    beq.w   8f
    b.w     11f                             // 0 word, 1 region, 9 closure, unknown: as it is
9:  bx      lr
    // REF1: a cell of one word
2:  mov     r0, r4
    bl      rt_is_old
    cmp     r0, #0
    bne.w   11f
    bl      rt_slot_enter
    mov     r6, r0
    mov     r0, r4
    bl      rt_tab_find
    cmp     r0, #0
    bne.w   29f
    movw    r0, #8
    bl      rt_place
    str     r0, [sp, #0]                    // dest
    str     r1, [sp, #4]                    // final
    mov     r0, r4
    bl      rt_tab_put                      // before the content: a cell may hold a ref to itself
    ldr     r0, [r4, #0]
    ldr     r1, [r4, #4]
    ldr     r2, [r5, #16]
    ldr     r3, [r5, #24]
    bl      rt_sc_val
    ldr     r2, [sp, #0]
    str     r0, [r2, #0]
    str     r1, [r2, #4]
    ldr     r0, [sp, #4]
29: mov     r7, r0                          // the word the copy holds (a pointer: high word 0)
    mov     r0, r6
    bl      rt_slot_leave
    mov     r0, r7
    movw    r1, #0
    b.w     10f
    // REFTUP: a cell word pointing at a payload tuple; one node of 8 + the payload rounded to 16
3:  mov     r0, r4
    bl      rt_is_old
    cmp     r0, #0
    bne.w   11f
    bl      rt_slot_enter
    mov     r6, r0
    mov     r0, r4
    bl      rt_tab_find
    cmp     r0, #0
    bne.w   29b
    ldr     r0, [r5, #0]
    lsl     r0, r0, #3
    add     r0, r0, #15
    bic     r0, r0, #15
    str     r0, [sp, #8]                    // payload bytes
    add     r0, r0, #8
    bl      rt_place
    str     r0, [sp, #0]                    // dest cell
    str     r1, [sp, #4]                    // final cell
    mov     r0, r4
    bl      rt_tab_put
    ldr     r2, [sp, #0]
    ldr     r3, [sp, #4]
    ldr     r0, [r4, #0]                    // the source payload (0: an empty cell)
    cmp     r0, #0
    beq.w   31f
    add     r3, r3, #8
    str     r3, [r2, #0]                    // the cell: the payload's final address
    movw    r3, #0
    str     r3, [r2, #4]
    add     r1, r2, #8
    mov     r2, r5
    bl      rt_sc_fields
    b.w     32f
31: movw    r3, #0
    str     r3, [r2, #0]
    str     r3, [r2, #4]
32: ldr     r0, [sp, #4]
    b.w     29b
    // AGG: N words
4:  mov     r0, r4
    bl      rt_is_old
    cmp     r0, #0
    bne.w   11f
41: ldr     r0, [r5, #0]
    lsl     r0, r0, #3
    bl      rt_place
    mov     r7, r1                          // final
    mov     r1, r0                          // dest
    mov     r0, r4
    mov     r2, r5
    bl      rt_sc_fields
    mov     r0, r7
    movw    r1, #0
    b.w     10f
    // SUM: the alternative's descriptor, then as AGG; an unknown alternative travels as a word
5:  mov     r0, r4
    bl      rt_is_old
    cmp     r0, #0
    bne.w   11f
    mov     r0, r4
    mov     r1, r5
    bl      rt_sum_desc
    cmp     r0, #0
    beq.w   11f
    mov     r5, r0
    b.w     41b
    // BUF: the count word and the elements
6:  mov     r0, r4
    bl      rt_is_old
    cmp     r0, #0
    bne.w   11f
    bl      rt_slot_enter
    mov     r6, r0
    mov     r0, r4
    mov     r1, r5
    bl      rt_buf_bytes
    mov     r7, r0
    bl      rt_place
    str     r1, [sp, #4]                    // final
    mov     r1, r0
    sub     r0, r4, #8                      // from the count word
    mov     r2, r7
    bl      rt_copy_bytes
    ldr     r0, [sp, #4]
    add     r0, r0, #8                      // the elements
    b.w     29b
    // LIST: the handle, then the spine chunk by chunk, each element by the element entry
7:  mov     r0, r4
    bl      rt_is_old
    cmp     r0, #0
    bne.w   11f
    bl      rt_slot_enter
    mov     r6, r0
    movw    r0, #24
    bl      rt_place
    str     r0, [sp, #0]                    // dest handle
    str     r1, [sp, #4]                    // final handle
    ldr     r2, [r4, #0]
    str     r2, [sp, #8]                    // elements left
    str     r2, [r0, #0]
    ldr     r2, [r4, #4]
    str     r2, [r0, #4]
    ldr     r2, [r4, #16]
    str     r2, [r0, #16]
    ldr     r2, [r4, #20]
    str     r2, [r0, #20]
    movw    r2, #0
    str     r2, [r0, #8]                    // first chunk: set below
    str     r2, [r0, #12]
    add     r2, r0, #8
    str     r2, [sp, #12]                   // where the next chunk's final address is stored
    ldr     r7, [r4, #8]                    // source chunk
    ldr     r4, [r4, #16]                   // cursor
    ldr     r0, [r5, #8]                    // SLOT; a chunk is 2 slots, then next, then claim
    str     r0, [sp, #16]
    lsl     r0, r0, #1
    str     r0, [sp, #20]                   // CDATA
71: ldr     r0, [sp, #8]
    cmp     r0, #0
    beq.w   79f
    cmp     r7, #0
    beq.w   79f
    ldr     r0, [sp, #20]
    add     r0, r0, #16
    bl      rt_place
    str     r0, [sp, #24]                   // dest chunk
    ldr     r2, [sp, #12]
    str     r1, [r2, #0]
    movw    r3, #0
    str     r3, [r2, #4]
    ldr     r2, [sp, #20]
    add     r2, r0, r2                      // the dest chunk's next and claim words
    str     r3, [r2, #0]                    // next (set when the next chunk is placed)
    str     r3, [r2, #4]
    str     r4, [r2, #8]                    // claim = the first offset in use in this copy
    str     r3, [r2, #12]
    str     r2, [sp, #12]
72: ldr     r0, [sp, #20]
    cmp     r4, r0
    bhs.w   73f
    ldr     r0, [sp, #8]
    cmp     r0, #0
    beq.w   79f
    ldr     r0, [sp, #16]
    cmp     r0, #8
    bne.w   75f                             // an inline aggregate slot: its words copied as they are
    add     r8, r7, r4
    ldr     r0, [r8, #0]
    ldr     r1, [r8, #4]
    ldr     r2, [r5, #16]
    ldr     r3, [r5, #24]
    bl      rt_sc_val
    ldr     r2, [sp, #24]
    add     r2, r2, r4
    str     r0, [r2, #0]
    str     r1, [r2, #4]
    b.w     76f
75: add     r0, r7, r4
    ldr     r1, [sp, #24]
    add     r1, r1, r4
    ldr     r2, [sp, #16]
    bl      rt_copy_bytes
76: ldr     r0, [sp, #16]
    add     r4, r4, r0
    ldr     r0, [sp, #8]
    sub     r0, r0, #1
    str     r0, [sp, #8]
    b.w     72b
73: ldr     r0, [sp, #20]
    ldr     r7, [r7, r0]
    movw    r4, #0
    b.w     71b
79: ldr     r0, [sp, #4]
    b.w     29b
    // STRING: a fresh header whose bytes are its own (at +24, the NUL after them), the bytes read
    // through the source's pointer (a run-time string keeps them inline, a literal points at its
    // rodata bytes); a literal marked -2 travels as a word.
8:  ldr     r0, [r4, #0]
    adds    r0, r0, #2
    beq.w   11f
    mov     r0, r4
    bl      rt_is_old
    cmp     r0, #0
    bne.w   11f
    bl      rt_slot_enter
    mov     r6, r0
    mov     r0, r4
    bl      rt_string_bytes
    bl      rt_place
    str     r1, [sp, #4]                    // final
    movw    r2, #0xFFFF
    movt    r2, #0xFFFF
    str     r2, [r0, #0]
    str     r2, [r0, #4]
    add     r2, r1, #24
    str     r2, [r0, #8]                    // the copy's pointer: its own bytes
    movw    r2, #0
    str     r2, [r0, #12]
    ldr     r3, [r4, #16]
    str     r3, [r0, #16]
    str     r2, [r0, #20]
    ldr     r1, [r4, #8]                    // src bytes
    add     r2, r0, #24                     // dst bytes
    add     r3, r1, r3                      // src end
81: cmp     r1, r3
    bhs.w   82f
    ldrb    r12, [r1], #1
    strb    r12, [r2], #1
    b.w     81b
82: movw    r12, #0
    strb    r12, [r2]                       // the NUL
    ldr     r0, [sp, #4]
    b.w     29b
11: mov     r0, r4                          // an old node, a literal, an unknown alternative: as given
    mov     r1, r8
10: add     sp, #32
    pop     {r4-r8, pc}
    .size   rt_sc_val, . - rt_sc_val

// rt_sc_fields(r0 = source node, r1 = destination node, r2 = descriptor): every word by its entry.
    LFUNC rt_sc_fields
    push    {r4-r7, lr}
    mov     r4, r0
    mov     r5, r1
    ldr     r6, [r2, #0]                    // N
    add     r7, r2, #16                     // entry
1:  cmp     r6, #0
    beq.w   9f
    ldr     r0, [r4, #0]
    ldr     r1, [r4, #4]
    ldr     r2, [r7, #0]
    ldr     r3, [r7, #8]
    bl      rt_sc_val
    str     r0, [r5, #0]
    str     r1, [r5, #4]
    add     r4, r4, #8
    add     r5, r5, #8
    add     r7, r7, #16
    sub     r6, r6, #1
    b.w     1b
9:  pop     {r4-r7, pc}
    .size   rt_sc_fields, . - rt_sc_fields

// rt_copy_bytes(r0 = src, r1 = dst, r2 = bytes, a multiple of 8). Clobbers r0-r3.
    LFUNC rt_copy_bytes
    cmp     r2, #0
    beq.w   9f
    add     r2, r0, r2
1:  ldr     r3, [r0], #4
    str     r3, [r1], #4
    cmp     r0, r2
    blo.w   1b
9:  bx      lr
    .size   rt_copy_bytes, . - rt_copy_bytes

// rt_spine_again(r0 = spine): a copy pass starts with the spine flag the measure started with.
    LFUNC rt_spine_again
    MOV32   r12, silica_rt_ccb_block
    str     r0, [r12, #CCB_SPINE]
    movw    r0, #1
    str     r0, [r12, #CCB_PASS]
    bx      lr
    .size   rt_spine_again, . - rt_spine_again

// ---- the two passes of an evacuation (rt_frame.S silica_rt_ev_frame) -------------------------------
// silica_rt_frame_measure(r0 = value lo, r1 = kind, r2 = aux, r3 = p, [sp] = C0) -> r0 = the bytes of
// the value's new part, rounded to 16 (0: nothing new). Frame mode, bump destination; the table dropped.
    FUNC silica_rt_frame_measure
    push    {r4-r8, lr}
    mov     r4, r0
    mov     r5, r1
    mov     r6, r2
    mov     r7, r3
    ldr     r8, [sp, #24]                   // C0, the fifth argument
    movw    r0, #0
    movw    r1, #2
    movw    r2, #0
    movw    r3, #0
    bl      rt_ccb_reset
    str     r7, [r0, #CCB_P]
    str     r8, [r0, #CCB_C0]
    mov     r0, r4
    mov     r1, r5
    mov     r2, r6
    bl      rt_sm_val
    bl      rt_tab_drop
    MOV32   r12, silica_rt_ccb_block
    ldr     r0, [r12, #CCB_TOTAL]
    add     r0, r0, #15
    bic     r0, r0, #15
    pop     {r4-r8, pc}
    .size   silica_rt_frame_measure, . - silica_rt_frame_measure

// silica_rt_frame_copy_delta(r0 = delta): the copy pass that follows writes its nodes at the cursor
// and every pointer (the root included) as cursor + delta. Main's evacuation copies into scratch below
// the callee's SP and moves the block up to its final place under p as bytes, so the pointers are
// written for the final place. Zero after a measure.
    FUNC silica_rt_frame_copy_delta
    MOV32   r12, silica_rt_ccb_block
    str     r0, [r12, #CCB_DELTA]
    bx      lr
    .size   silica_rt_frame_copy_delta, . - silica_rt_frame_copy_delta

// silica_rt_frame_copy(r0:r1 = value, r2 = kind, r3 = aux, [sp] = dest low) -> r0:r1 the root. The
// CCB is the measure's (modes, p, C0, total); the cursor runs over [dest low, dest low + total).
    FUNC silica_rt_frame_copy
    push    {r4-r8, lr}
    mov     r4, r0
    mov     r5, r1
    mov     r6, r2
    mov     r7, r3
    ldr     r8, [sp, #24]                   // dest low, the fifth argument
    MOV32   r12, silica_rt_ccb_block
    str     r8, [r12, #CCB_CUR]
    ldr     r0, [r12, #CCB_TOTAL]
    add     r0, r0, #15
    bic     r0, r0, #15
    add     r0, r0, r8
    str     r0, [r12, #CCB_END]
    movw    r0, #0
    bl      rt_spine_again
    mov     r0, r4
    mov     r1, r5
    mov     r2, r6
    mov     r3, r7
    bl      rt_sc_val
    mov     r4, r0
    mov     r5, r1
    bl      rt_tab_drop
    mov     r0, r4
    mov     r1, r5
    pop     {r4-r8, pc}
    .size   silica_rt_frame_copy, . - silica_rt_frame_copy

// ---- the two passes over a root-word descriptor -----------------------------------------------------
// rt_measure_root(r0 = value lo, r1 = root descriptor) -> r0 = CCB_TOTAL (the CCB was reset by the
// caller). The table is dropped.
    LFUNC rt_measure_root
    push    {r4, lr}
    ldr     r2, [r1, #24]
    ldr     r1, [r1, #16]
    bl      rt_sm_val
    bl      rt_tab_drop
    MOV32   r12, silica_rt_ccb_block
    ldr     r0, [r12, #CCB_TOTAL]
    pop     {r4, pc}
    .size   rt_measure_root, . - rt_measure_root

// rt_copy_root(r0:r1 = value, r2 = root descriptor) -> r0:r1 the copy's root. The CCB's modes are the
// measure's (or a chain copy's, which needs no measure); the table is dropped after.
    LFUNC rt_copy_root
    push    {r4-r6, lr}
    ldr     r3, [r2, #24]
    ldr     r2, [r2, #16]
    bl      rt_sc_val
    mov     r4, r0
    mov     r5, r1
    bl      rt_tab_drop
    mov     r0, r4
    mov     r1, r5
    pop     {r4-r6, pc}
    .size   rt_copy_root, . - rt_copy_root

// ---- the mailbox buffer (phase 4a / 4c / 4e) --------------------------------------------------------
// silica_rt_message_buffer(X0 value, X1 desc) -> X0 root, X1 bytes, X2 block: the message measured, a
// heap block of exactly its size, the copy into it with one table. A scalar word, or a value with no
// node to copy, answers itself with 0, 0. Frame: ENTRY_SAVE (X0 at [sp+16] once the locals are below,
// X1 at +24, X2 at +32) + 16: [0] bytes, [4] block.
    FUNC silica_rt_message_buffer
    ENTRY_SAVE
    sub     sp, #16
    ldr     r0, [sp, #16]
    cmp     r0, #65536
    blo.w   9f
    movw    r0, #0
    movw    r1, #0
    movw    r2, #0
    movw    r3, #0
    bl      rt_ccb_reset
    ldr     r0, [sp, #16]
    ldr     r1, [sp, #24]
    bl      rt_measure_root
    cmp     r0, #0
    beq.w   9f
    add     r0, r0, #15
    bic     r0, r0, #15
    str     r0, [sp, #0]
    bl      silica_rt_alloc_or_null
    cmp     r0, #0
    beq.w   8f
    str     r0, [sp, #4]
    MOV32   r12, silica_rt_ccb_block
    str     r0, [r12, #CCB_CUR]
    ldr     r1, [sp, #0]
    add     r1, r1, r0
    str     r1, [r12, #CCB_END]
    movw    r0, #0
    bl      rt_spine_again
    ldr     r0, [sp, #16]
    ldr     r1, [sp, #20]
    ldr     r2, [sp, #24]
    bl      rt_copy_root
    str     r0, [sp, #16]
    str     r1, [sp, #20]
    ldr     r2, [sp, #0]
    ldr     r3, [sp, #4]
    movw    r1, #0
    str     r2, [sp, #24]                   // X1 = bytes
    str     r1, [sp, #28]
    str     r3, [sp, #32]                   // X2 = block
    str     r1, [sp, #36]
    add     sp, #16
    ENTRY_RET
9:  movw    r1, #0                          // X0 as given; X1 = X2 = 0
    str     r1, [sp, #24]
    str     r1, [sp, #28]
    str     r1, [sp, #32]
    str     r1, [sp, #36]
    add     sp, #16
    ENTRY_RET
8:  bl      silica_rt_region_alloc_failed
    .size   silica_rt_message_buffer, . - silica_rt_message_buffer

// silica_rt_message_forward(X0 value, X1 desc, X2 the sending function's entry): the serving node's own
// buffer is handed on when the sender is the behaviour being dispatched, the node a plain cast node whose
// buffer root is the value, and no shallow copy ran in the dispatch (ACB_SRETAIN); otherwise as
// silica_rt_message_buffer. Frame: ENTRY_SAVE only (X0 at [sp], X1 at +8, X2 at +16).
    FUNC silica_rt_message_forward
    ENTRY_SAVE
    bl      silica_rt_current
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #KIND_ACTOR
    bne.w   5f
    mov     r6, r0                          // r6 = acb
    ldr     r7, [r6, #ACB_ACTIVE_CALL]      // r7 = the node being served
    cmp     r7, #0
    beq.w   5f
    ldr     r1, [r6, #ACB_BEH]
    bic     r1, r1, #1
    ldr     r2, [sp, #16]
    bic     r2, r2, #1
    cmp     r1, r2
    bne.w   5f
    ldr     r1, [r7, #MSG_KIND]
    cmp     r1, #0
    bne.w   5f
    ldr     r8, [r7, #MSG_BUF_BLOCK]
    cmp     r8, #0
    beq.w   5f
    ldr     r1, [r7, #MSG_PAYLOAD]
    ldr     r2, [sp, #0]
    cmp     r1, r2
    bne.w   5f
    ldr     r1, [r6, #ACB_SRETAIN]
    cmp     r1, #0
    bne.w   5f
    ldr     r3, [r7, #MSG_BUF_BYTES]
    movw    r1, #0
    str     r1, [r7, #MSG_BUF_BLOCK]
    str     r1, [r7, #MSG_BUF_BYTES]
    str     r1, [r7, #MSG_PAYLOAD_OWNED]
    str     r3, [sp, #8]                    // X1 = bytes
    str     r1, [sp, #12]
    str     r8, [sp, #16]                   // X2 = block
    str     r1, [sp, #20]
    ENTRY_RET
5:  pop     {r0-r8, r12, lr}                // every register as the caller had it: a buffer copy
    b.w     silica_rt_message_buffer
    .size   silica_rt_message_forward, . - silica_rt_message_forward

// ---- the reply into the caller's stack (phase 4c) ------------------------------------------------
// silica_rt_reply_place(X0 value, X1 desc) -> X0 the copy's root. The blocked caller is the serving
// node's MSG_CALLER; the copy goes directly under its parked SP (the node's MSG_PARK_SP) in its parked
// auxiliary chunk when it fits, else into a fresh chunk appended to its chain (an actor caller; main's
// stack does not grow); the caller wakes with SP at the copy's bottom (MSG_PARK_SP written back), its
// floor as parked, and its call site adopts [SP, p) (rt_frame.S silica_rt_adopt moves the transient part
// under the copy). Outside an actor, for a cast that reached a call-style behaviour, and for a scalar
// word nothing is copied. Frame: ENTRY_SAVE (X0 at [sp+16] once the locals are below, X1 at +24) + 16:
// [0] floor, [4] chunk, [8] len. r4 = the node, r5 = the caller, r6 = total, r7 = p, r8 = dest low.
    FUNC silica_rt_reply_place
    ENTRY_SAVE
    sub     sp, #16
    ldr     r0, [sp, #16]
    cmp     r0, #65536
    blo.w   9f
    bl      silica_rt_current
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #KIND_ACTOR
    bne.w   9f
    ldr     r4, [r0, #ACB_ACTIVE_CALL]
    cmp     r4, #0
    beq.w   9f
    ldr     r1, [r4, #MSG_KIND]
    cmp     r1, #1
    bne.w   9f
    ldr     r5, [r4, #MSG_CALLER]
    cmp     r5, #0
    beq.w   9f
    movw    r0, #0
    movw    r1, #0
    movw    r2, #0
    movw    r3, #0
    bl      rt_ccb_reset
    ldr     r0, [sp, #16]
    ldr     r1, [sp, #24]
    bl      rt_measure_root
    cmp     r0, #0
    beq.w   9f
    add     r0, r0, #15
    bic     r6, r0, #15                     // total
    // p, the floor and the chunk as the caller parked them, from the node (silica_rt_actor_call writes
    // them before the node is enqueued)
    ldr     r7, [r4, #MSG_PARK_SP]
    ldr     r1, [r4, #MSG_PARK_FLOOR]
    str     r1, [sp, #0]
    ldr     r2, [r4, #MSG_PARK_CHUNK]
    str     r2, [sp, #4]
    mov     r0, r7
    bl      rt_transient_len_of
    str     r0, [sp, #8]                    // len
    // room under p in the caller's chunk for the copy and the moved transient part?
    ldr     r2, [sp, #4]
    ldr     r3, [r2, #CH_LIMIT]
    sub     r8, r7, r6
    bic     r8, r8, #15                     // dest low
    sub     r1, r8, r0
    cmp     r1, r3
    bhs.w   3f
    ldrb    r0, [r5, #ACB_KIND]
    cmp     r0, #KIND_ACTOR
    bne.w   8f                              // main's stack does not grow
    mov     r0, r5
    ldr     r1, [sp, #4]
    ldr     r2, [sp, #8]
    add     r2, r2, r6
    mov     r3, r7                          // a restore to p pops the chunk
    bl      silica_rt_aux_chunk_append
    cmp     r0, #0
    beq.w   8f
    adds    r1, r0, #1
    beq.w   8f
    str     r0, [r4, #MSG_PARK_CHUNK]       // the caller resumes in it (it publishes the chunk on waking)
    ldr     r1, [r0, #CH_TOP]
    sub     r8, r1, r6
3:  // copy, bump mode, into [dest low, dest low + total)
    MOV32   r12, silica_rt_ccb_block
    str     r8, [r12, #CCB_CUR]
    add     r1, r8, r6
    str     r1, [r12, #CCB_END]
    movw    r0, #0
    bl      rt_spine_again
    ldr     r0, [sp, #16]
    ldr     r1, [sp, #20]
    ldr     r2, [sp, #24]
    bl      rt_copy_root
    str     r0, [sp, #16]
    str     r1, [sp, #20]
    // the caller wakes with SP at the copy's bottom and its floor and transient part as they were: its
    // call site then ADOPTS [SP, p) (the ESP32-S3 port's note: moving the transient part here as well
    // made every later reply land on the first)
    str     r8, [r4, #MSG_PARK_SP]
9:  add     sp, #16
    ENTRY_RET
8:  bl      silica_rt_region_alloc_failed
    .size   silica_rt_reply_place, . - silica_rt_reply_place

// rt_transient_len_of(r0 = sp, r1 = floor, r2 = chunk) -> r0: rt_frame.S's rule (file-local there).
    LFUNC rt_transient_len_of
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
    .size   rt_transient_len_of, . - rt_transient_len_of

// ---- the state at a spawn and at a dispatch end (phases 3b, 3c, §4.3-§4.7) -------------------------
// silica_rt_state_install(r0 = acb, r1:r2 = value, r3 = root descriptor or 0) -> r0 = 0. The value is
// stored at ACB_STATE; a described pointer value is copied into the child's chain first (one table per
// slot) and the copy's root stored.
    FUNC silica_rt_state_install
    push    {r4-r8, lr}
    mov     r4, r0
    mov     r5, r1
    mov     r6, r2
    mov     r7, r3
    cmp     r7, #0
    beq.w   9f
    cmp     r5, #65536
    blo.w   9f
    mov     r0, r4
    bl      silica_rt_state_chain_init
    movw    r0, #1
    movw    r1, #0
    mov     r2, r4
    movw    r3, #1
    bl      rt_ccb_reset
    movw    r0, #1
    bl      rt_spine_again
    mov     r0, r5
    mov     r1, r6
    mov     r2, r7
    bl      rt_copy_root
    mov     r5, r0
    mov     r6, r1
9:  str     r5, [r4, #ACB_STATE]
    str     r6, [r4, #ACB_STATE + 4]
    movw    r0, #0
    pop     {r4-r8, pc}
    .size   silica_rt_state_install, . - silica_rt_state_install

// silica_rt_state_dispatch_end(r0 = acb, r1:r2 = the new state as the behaviour returned it) -> r0:r1
// the root for ACB_STATE. A scalar, or a state whose descriptor is 0, is answered as given. A proven
// behaviour (ACB_SFLAGS 1 or 2) without a compaction request has its new nodes evacuated into the chain
// (old chain nodes kept, not followed), the old root shell freed when the root changed, and its release
// log drained (2) or dropped (1). An unproven behaviour, or a compaction request (ACB_SPOLICY bit 8), has
// its whole live state copied into a fresh chain and the old chain freed; the log is dropped. The
// descriptor, the flags, the retain mark and the request are cleared at the end (as on the ESP32-S3).
// Frame: [0] the old root lo, [4] pad. r4 = acb, r5:r6 = the state, r7 = desc, r8 = the old chain.
    FUNC silica_rt_state_dispatch_end
    push    {r4-r8, lr}
    sub     sp, #8
    mov     r4, r0
    mov     r5, r1
    mov     r6, r2
    ldr     r7, [r4, #ACB_SDESC]
    ldr     r0, [r4, #ACB_STATE]
    str     r0, [sp, #0]
    cmp     r7, #0
    beq.w   7f
    cmp     r5, #65536
    blo.w   7f
    ldr     r0, [r4, #ACB_SFLAGS]
    cmp     r0, #0
    beq.w   5f
    ldr     r0, [r4, #ACB_SPOLICY]
    tst     r0, #0x100
    bne.w   5f
    // the proven path: evacuate the new nodes into the chain
    mov     r0, r4
    bl      silica_rt_state_chain_init
    movw    r0, #1
    movw    r1, #1
    mov     r2, r4
    movw    r3, #1
    bl      rt_ccb_reset
    movw    r0, #1
    bl      rt_spine_again
    mov     r0, r5
    mov     r1, r6
    mov     r2, r7
    bl      rt_copy_root
    mov     r5, r0
    mov     r6, r1
    // the old root shell goes back when the root changed and it was an aggregate chain node
    ldr     r1, [sp, #0]
    cmp     r1, r5
    beq.w   4f
    mov     r0, r4
    bl      silica_rt_state_contains
    cmp     r0, #0
    beq.w   4f
    ldr     r0, [r7, #16]                   // the root entry's KIND
    cmp     r0, #4
    bne.w   4f
    ldr     r2, [r7, #24]                   // its AUX: the aggregate's descriptor
    ldr     r2, [r2, #0]
    lsl     r2, r2, #3
    mov     r0, r4
    ldr     r1, [sp, #0]
    bl      silica_rt_state_free
4:  ldr     r0, [r4, #ACB_SFLAGS]
    cmp     r0, #2
    bne.w   6f
    mov     r0, r4
    bl      silica_rt_state_log_drain
    b.w     7f
5:  // the fallback: the whole live state into a fresh chain
    ldr     r8, [r4, #ACB_SCHAIN]
    movw    r0, #0
    str     r0, [r4, #ACB_SCHAIN]
    str     r0, [r4, #ACB_SCUR]
    str     r0, [r4, #ACB_SBYTES]
    mov     r0, r4
    bl      silica_rt_state_chain_init
    movw    r0, #1
    movw    r1, #0
    mov     r2, r4
    movw    r3, #1
    bl      rt_ccb_reset
    movw    r0, #1
    bl      rt_spine_again
    mov     r0, r5
    mov     r1, r6
    mov     r2, r7
    bl      rt_copy_root
    mov     r5, r0
    mov     r6, r1
    mov     r0, r8
    bl      rt_schain_free
6:  movw    r0, #0                          // the log is dropped
    str     r0, [r4, #ACB_SLOGN]
7:  movw    r0, #0
    str     r0, [r4, #ACB_SDESC]
    str     r0, [r4, #ACB_SDESC + 4]
    str     r0, [r4, #ACB_SFLAGS]
    str     r0, [r4, #ACB_SFLAGS + 4]
    str     r0, [r4, #ACB_SRETAIN]
    str     r0, [r4, #ACB_SRETAIN + 4]
    str     r0, [r4, #ACB_SLOGN]
    str     r0, [r4, #ACB_SLOGN + 4]
    ldr     r0, [r4, #ACB_SPOLICY]
    bic     r0, r0, #0x100
    str     r0, [r4, #ACB_SPOLICY]
    mov     r0, r5
    mov     r1, r6
    add     sp, #8
    pop     {r4-r8, pc}
    .size   silica_rt_state_dispatch_end, . - silica_rt_state_dispatch_end

// ---- retire, the release log, retained nodes (§4.2, §7) ----------------------------------------------
// silica_rt_state_retire(X0 node, X1 bytes): nothing while the proof flag is 0, outside an actor, or when
// the node is not a chain node; else appended to the actor's release log (doubled when full).
// Frame: ENTRY_SAVE. r4 = log, r5 = acb, r6 = node, r7 = bytes, r8 = count.
    FUNC silica_rt_state_retire
    ENTRY_SAVE
    mov     r6, r0
    mov     r7, r2
    bl      silica_rt_current
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #KIND_ACTOR
    bne.w   9f
    mov     r5, r0
    ldr     r1, [r5, #ACB_SFLAGS]
    cmp     r1, #0
    beq.w   9f
    mov     r1, r6
    bl      silica_rt_state_contains
    cmp     r0, #0
    beq.w   9f
    ldr     r4, [r5, #ACB_SLOG]
    ldr     r8, [r5, #ACB_SLOGN]
    cmp     r4, #0
    bne.w   1f
    movw    r0, #(SLOG_FIRST * 8 + 8)
    bl      silica_rt_alloc
    mov     r4, r0
    movw    r1, #SLOG_FIRST
    str     r1, [r4, #0]
    str     r4, [r5, #ACB_SLOG]
1:  ldr     r1, [r4, #0]
    cmp     r8, r1
    blo.w   2f
    lsl     r0, r1, #4                      // twice the capacity: 2 * cap * 8 + 8
    add     r0, r0, #8
    bl      silica_rt_alloc
    ldr     r1, [r4, #0]
    lsl     r1, r1, #1
    str     r1, [r0, #0]
    push    {r0, r1}
    mov     r1, r0
    add     r1, r1, #8
    add     r0, r4, #8
    lsl     r2, r8, #3
    bl      rt_copy_bytes
    mov     r0, r4
    bl      silica_rt_free
    pop     {r0, r1}                        // the new log
    mov     r4, r0
    str     r4, [r5, #ACB_SLOG]
2:  add     r0, r4, r8, lsl #3
    str     r6, [r0, #8]
    str     r7, [r0, #12]
    add     r8, r8, #1
    str     r8, [r5, #ACB_SLOGN]
9:  ENTRY_RET
    .size   silica_rt_state_retire, . - silica_rt_state_retire

// silica_rt_state_log_drain(r0 = acb): every logged node goes to its free list; count 0.
    FUNC silica_rt_state_log_drain
    push    {r4-r6, lr}
    mov     r4, r0
    ldr     r5, [r4, #ACB_SLOG]
    cmp     r5, #0
    beq.w   9f
    ldr     r6, [r4, #ACB_SLOGN]
    add     r5, r5, #8
1:  cmp     r6, #0
    beq.w   8f
    mov     r0, r4
    ldr     r1, [r5, #0]
    ldr     r2, [r5, #4]
    bl      silica_rt_state_free
    add     r5, r5, #8
    sub     r6, r6, #1
    b.w     1b
8:  movw    r0, #0
    str     r0, [r4, #ACB_SLOGN]
9:  pop     {r4-r6, pc}
    .size   silica_rt_state_log_drain, . - silica_rt_state_log_drain

// silica_rt_state_retain_node(X0 n) -> X0 = the elements of a zeroed uint8 buffer node of the current
// actor's chain (its count at [buf - 8]); 0 outside an actor or when the chain cannot grow.
    FUNC silica_rt_state_retain_node
    ENTRY_SAVE
    mov     r6, r0
    bl      silica_rt_current
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #KIND_ACTOR
    bne.w   9f
    mov     r4, r0
    add     r5, r6, #15
    bic     r5, r5, #7                      // 8 + n rounded to 8
    mov     r1, r5
    bl      silica_rt_state_alloc
    cmp     r0, #0
    beq.w   9f
    mov     r7, r0
    mov     r1, r5
    bl      silica_rt_zero_block
    str     r6, [r7, #0]
    add     r0, r7, #8
    movw    r1, #0
    ENTRY_RET_X0
9:  movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_state_retain_node, . - silica_rt_state_retain_node

// silica_rt_state_area_bytes() -> X0 = the calling actor's state bytes live; 0 outside an actor.
    FUNC silica_rt_state_area_bytes
    ENTRY_SAVE
    bl      silica_rt_current
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #KIND_ACTOR
    ite     eq
    ldreq   r0, [r0, #ACB_SBYTES]
    movne   r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_state_area_bytes, . - silica_rt_state_area_bytes

// silica_rt_compact_state() -> X0 = 0: the request (ACB_SPOLICY bit 8) only under :compact_on_request
// (bits 4-5 = 2); the dispatch end honours it.
    FUNC silica_rt_compact_state
    ENTRY_SAVE
    bl      silica_rt_current
    ldrb    r1, [r0, #ACB_KIND]
    cmp     r1, #KIND_ACTOR
    bne.w   9f
    ldr     r1, [r0, #ACB_SPOLICY]
    ubfx    r2, r1, #4, #2
    cmp     r2, #2
    bne.w   9f
    orr     r1, r1, #0x100
    str     r1, [r0, #ACB_SPOLICY]
9:  movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_compact_state, . - silica_rt_compact_state
