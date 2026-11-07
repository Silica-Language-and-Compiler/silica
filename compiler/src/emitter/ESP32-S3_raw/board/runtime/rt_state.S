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

// The state chain and the runtime copier on the ESP32-S3 (chunk15_stack_memory_design.md §2.6, §4,
// §5; the board re-expression of the hosted prims_actors_state_asm.silica).
//
// THE STATE CHAIN. An actor's state nodes live in a chain of heap chunks of its own, disjoint from every
// frame (ACB_SCHAIN the first, ACB_SCUR the one bumps come from): 2048 bytes first, doubling to 16 KB.
// A chunk: [0] next, [4] size, [8] bump cursor, [12] end (= chunk + size); the first chunk also holds
// the 129 free-list heads after its header (head i for nodes of 8 * (i + 1) bytes, i = 0..127; head 128
// for every size above 1,024, the node's size in its word at +4). Every node has an exact size, a
// multiple of 8, known from its descriptor; nodes never move once placed (decision 21) except by a
// compaction, which builds a fresh chain. ACB_SBYTES counts the bytes allocated and not freed.
//
// THE COPIER walks a value through the descriptors the emitter spells (terms/term_message_copy.silica:
// KIND 0 word, 1 region witness, 2 REF1, 3 REFTUP, 4 AGG, 5 SUM, 6 BUF, 7 LIST, 8 STRING, 9 closure),
// given in the ROOT-WORD form `.quad 1, -1; .quad KIND, AUX` (16-byte entries, the low word read). The
// data words are 8 bytes (lo, hi), a pointer in the low word; a value below 65536 is an atom, nil or a
// small scalar and travels as it is. Sizes: an aggregate N * 8; a REF1 cell 8; a REFTUP cell 8 plus its
// payload rounded to 16; a buffer its count word plus the elements rounded to 8; a list handle 24 and
// 24 per chunk of its spine; a run-time string 24 + bytes + 1 rounded to 8 (a literal, marker -2, a
// word). Sharing through refs is kept by one table (source -> copy, open addressing) per copy; a state
// copy empties it before each slot (a ref, list, string or buffer reached through the aggregate spine)
// so two slots never share a node afterwards (P5).
//
// The copy control block (CCB, one per core at silica_rt_ccb_blocks, its address at THREADPTR +
// VRG_CCB): [0] dest mode (0 bump, 1 chain), [4] old mode (0 none, 1 chain node = old, 2 frame rule),
// [8] bump cursor, [12] bump end, [16] delta (added to every pointer written), [20] acb, [24] p (frame
// rule: the pre-call SP), [28] C0 (frame rule: p's chunk), [32] table, [36] spine (1: empty the table
// at the next slot), [40] total (measure), [44] nodes (measure), [48] pass (0 measure, 1 copy).
//
// Entries (the emitter's and rt_actors.S's; X0-X2 = a2:a3, a4:a5, a6:a7, X3.. in the register block):
//   silica_rt_state_alloc(acb, bytes) -> node or 0      silica_rt_state_free(acb, node, bytes)
//   silica_rt_state_hole_pop(acb, bytes) -> node or 0   silica_rt_state_chain_free_all(acb)
//   silica_rt_state_contains(acb, ptr) -> 0/1
//   silica_rt_state_retire(X0 node, X1 bytes)           silica_rt_state_log_drain(acb)
//   silica_rt_state_retain_node(X0 n) -> X0 elements     silica_rt_state_area_bytes() / silica_rt_compact_state()
//   silica_rt_message_buffer(X0 value, X1 desc) -> X0 root, X1 bytes, X2 block (0, 0: inline)
//   silica_rt_message_forward(X0 value, X1 desc, X2 fn) -> the same
//   silica_rt_reply_place(X0 value, X1 desc) -> X0 the copy's root in the blocked caller's auxiliary chain
//   silica_rt_state_install(acb, value lo, value hi, desc) -> 0 (the root stored at ACB_STATE)
//   silica_rt_state_dispatch_end(acb, new lo, new hi) -> a2:a3 the root for ACB_STATE
//   silica_rt_frame_measure(value, kind, aux, p, C0) -> bytes (rounded to 16)   (rt_frame.S)
//   silica_rt_frame_copy(value lo, hi, kind, aux, dest, p) -> a2:a3 the root        (rt_frame.S)

#define VRG_VSP          112
#define VRG_ACHUNK       132
#define VRG_FLOOR        140
#define VRG_CCB          144
#define VRG_BLOCK_SIZE   192

#define CH_NEXT          0
#define CH_PREV          4
#define CH_SIZE          8
#define CH_RET           12
#define CH_LIMIT         16
#define CH_TOP           20
#define CH_INDEX         28
#define CH_USABLE_OFF    128

#define ACB_STATE        0
#define ACB_BEH          8
#define ACB_KIND         19
#define ACB_ACUR         56
#define ACB_CTX_VSP      68
#define ACB_ACTIVE_CALL  84
#define ACB_SDESC        144
#define ACB_SFLAGS       152
#define ACB_SRETAIN      160
#define ACB_RSLOT        168
#define ACB_SLOGN        176
#define ACB_SCHAIN       184
#define ACB_SCUR         188
#define ACB_SLOG         192
#define ACB_SBYTES       196
#define ACB_SPOLICY      200
#define ACB_CTX_FLOOR    204

#define MSG_KIND         4
#define MSG_PAYLOAD      8
#define MSG_CALLER       20
#define MSG_PAYLOAD_OWNED 36
#define MSG_BUF_BLOCK    40
#define MSG_BUF_BYTES    44
#define MSG_PARK_SP      48     // a call node: the caller's parked SP, floor and chunk (rt_actors.S)
#define MSG_PARK_FLOOR   52
#define MSG_PARK_CHUNK   56

#define SCH_NEXT         0
#define SCH_SIZE         4
#define SCH_CUR          8
#define SCH_END          12
#define SCH_HEADER       16
#define SCH_HEADS        16      // 129 words in the first chunk
#define SCH_HEADS_BYTES  520
#define SCH_FIRST        2048
#define SCH_CAP          16384
#define SLOG_FIRST       64

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

#define TAB_CAP          0
#define TAB_COUNT        4
#define TAB_ENTRIES      8      // (key, value) pairs

    .section .bss.silica_rt_state, "aw", @nobits
    .balign 16
silica_rt_ccb_blocks:
    .space  CCB_SIZE * 2

    .text

// ---- the CCB -------------------------------------------------------------------------------------
// rt_ccb() -> a2 = this core's CCB (published at VRG_CCB on first use).
    .align  4
    .type   rt_ccb, @function
rt_ccb:
    entry   a1, 32
    rur     a8, threadptr
    l32i    a2, a8, VRG_CCB
    bnez    a2, 1f
    movi    a2, silica_rt_ccb_blocks
    movi    a9, silica_rt_core_regs
    beq     a8, a9, 2f
    addi    a2, a2, CCB_SIZE
2:  s32i    a2, a8, VRG_CCB
1:  retw
    .size   rt_ccb, . - rt_ccb

// rt_ccb_reset(a2 = dest mode, a3 = old mode, a4 = acb, a5 = spine): a fresh control block for a measure
// (pass 0); the copy pass keeps it and sets its cursor. The table is made on the first ref.
    .align  4
    .type   rt_ccb_reset, @function
rt_ccb_reset:
    entry   a1, 32
    call8   rt_ccb
    mov     a8, a10
    s32i    a2, a8, CCB_DMODE
    s32i    a3, a8, CCB_OMODE
    s32i    a4, a8, CCB_ACB
    s32i    a5, a8, CCB_SPINE
    movi    a9, 0
    s32i    a9, a8, CCB_CUR
    s32i    a9, a8, CCB_END
    s32i    a9, a8, CCB_DELTA
    s32i    a9, a8, CCB_TAB
    s32i    a9, a8, CCB_TOTAL
    s32i    a9, a8, CCB_NODES
    s32i    a9, a8, CCB_PASS
    mov     a2, a8
    retw
    .size   rt_ccb_reset, . - rt_ccb_reset

// ---- the table: source pointer -> copy, open addressing, doubled at half load ----------------------
// rt_tab_find(a2 = key) -> a2 = value, 0 when absent.
    .align  4
    .type   rt_tab_find, @function
rt_tab_find:
    entry   a1, 32
    call8   rt_ccb
    l32i    a3, a10, CCB_TAB
    beqz    a3, 9f
    l32i    a4, a3, TAB_CAP
    addi    a5, a4, -1                  // mask
    srli    a6, a2, 3
    and     a6, a6, a5                  // slot
1:  slli    a7, a6, 3
    add     a7, a7, a3
    l32i    a8, a7, TAB_ENTRIES
    beqz    a8, 9f
    beq     a8, a2, 2f
    addi    a6, a6, 1
    and     a6, a6, a5
    j       1b
2:  l32i    a2, a7, TAB_ENTRIES + 4
    retw
9:  movi    a2, 0
    retw
    .size   rt_tab_find, . - rt_tab_find

// rt_tab_put(a2 = key, a3 = value): inserts (the key is absent). Grows the table first when half full.
    .align  4
    .type   rt_tab_put, @function
rt_tab_put:
    entry   a1, 48
    s32i    a2, a1, 0
    s32i    a3, a1, 4
    call8   rt_ccb
    mov     a7, a10
    l32i    a4, a7, CCB_TAB
    bnez    a4, 1f
    movi    a10, 64
    call8   rt_tab_new
    mov     a4, a10
    s32i    a4, a7, CCB_TAB
1:  l32i    a5, a4, TAB_COUNT
    addi    a5, a5, 1
    l32i    a6, a4, TAB_CAP
    srli    a6, a6, 1
    bltu    a5, a6, 2f
    mov     a10, a4
    call8   rt_tab_grow
    mov     a4, a10
    s32i    a4, a7, CCB_TAB
2:  l32i    a10, a1, 0
    l32i    a11, a1, 4
    mov     a12, a4
    call8   rt_tab_insert
    retw
    .size   rt_tab_put, . - rt_tab_put

// rt_tab_new(a2 = capacity, a power of two) -> a2 = a zeroed table.
    .align  4
    .type   rt_tab_new, @function
rt_tab_new:
    entry   a1, 32
    mov     a3, a2
    slli    a10, a2, 3
    addi    a10, a10, TAB_ENTRIES
    call8   silica_rt_alloc
    mov     a2, a10
    slli    a11, a3, 3
    addi    a11, a11, TAB_ENTRIES
    call8   silica_rt_zero_block
    s32i    a3, a2, TAB_CAP
    retw
    .size   rt_tab_new, . - rt_tab_new

// rt_tab_insert(a2 = key, a3 = value, a4 = table): the probe and store.
    .align  4
    .type   rt_tab_insert, @function
rt_tab_insert:
    entry   a1, 32
    l32i    a5, a4, TAB_CAP
    addi    a5, a5, -1
    srli    a6, a2, 3
    and     a6, a6, a5
1:  slli    a7, a6, 3
    add     a7, a7, a4
    l32i    a8, a7, TAB_ENTRIES
    beqz    a8, 2f
    addi    a6, a6, 1
    and     a6, a6, a5
    j       1b
2:  s32i    a2, a7, TAB_ENTRIES
    s32i    a3, a7, TAB_ENTRIES + 4
    l32i    a8, a4, TAB_COUNT
    addi    a8, a8, 1
    s32i    a8, a4, TAB_COUNT
    retw
    .size   rt_tab_insert, . - rt_tab_insert

// rt_tab_grow(a2 = table) -> a2 = a table of twice the capacity holding the same entries; the old freed.
    .align  4
    .type   rt_tab_grow, @function
rt_tab_grow:
    entry   a1, 32
    mov     a3, a2
    l32i    a10, a3, TAB_CAP
    slli    a10, a10, 1
    call8   rt_tab_new
    mov     a4, a10
    l32i    a5, a3, TAB_CAP
    addi    a6, a3, TAB_ENTRIES
1:  beqz    a5, 2f
    l32i    a10, a6, 0
    beqz    a10, 3f
    l32i    a11, a6, 4
    mov     a12, a4
    call8   rt_tab_insert
3:  addi    a6, a6, 8
    addi    a5, a5, -1
    j       1b
2:  mov     a10, a3
    call8   silica_rt_free
    mov     a2, a4
    retw
    .size   rt_tab_grow, . - rt_tab_grow

// rt_tab_clear(): the next slot of a state copy starts with an empty table (the block is kept).
    .align  4
    .type   rt_tab_clear, @function
rt_tab_clear:
    entry   a1, 32
    call8   rt_ccb
    l32i    a3, a10, CCB_TAB
    beqz    a3, 9f
    l32i    a4, a3, TAB_CAP
    slli    a11, a4, 3
    addi    a10, a3, TAB_ENTRIES
    call8   silica_rt_zero_block
    movi    a8, 0
    s32i    a8, a3, TAB_COUNT
9:  retw
    .size   rt_tab_clear, . - rt_tab_clear

// rt_tab_drop(): frees the table after a measure or a copy.
    .align  4
    .type   rt_tab_drop, @function
rt_tab_drop:
    entry   a1, 32
    call8   rt_ccb
    mov     a3, a10
    l32i    a10, a3, CCB_TAB
    beqz    a10, 9f
    call8   silica_rt_free
    movi    a8, 0
    s32i    a8, a3, CCB_TAB
9:  retw
    .size   rt_tab_drop, . - rt_tab_drop

// ---- the state chain ------------------------------------------------------------------------------
// rt_schunk_new(a2 = bytes the chunk must hold beyond its header) -> a2 = a chunk (cursor at its header's
// end), 0 when the heap is exhausted. The first chunk of a chain reserves the heads after its header.
    .align  4
    .type   rt_schunk_new, @function
rt_schunk_new:
    entry   a1, 32
    mov     a3, a2
    addi    a10, a3, SCH_HEADER
    call8   silica_rt_alloc_or_null
    mov     a2, a10
    beqz    a2, 9f
    movi    a8, 0
    s32i    a8, a2, SCH_NEXT
    addi    a8, a3, SCH_HEADER
    s32i    a8, a2, SCH_SIZE
    add     a8, a8, a2
    s32i    a8, a2, SCH_END
    addi    a8, a2, SCH_HEADER
    s32i    a8, a2, SCH_CUR
9:  retw
    .size   rt_schunk_new, . - rt_schunk_new

// silica_rt_state_chain_init(a2 = acb): the first chunk with empty heads; nothing when one exists.
    .align  4
    .global silica_rt_state_chain_init
    .type   silica_rt_state_chain_init, @function
silica_rt_state_chain_init:
    entry   a1, 32
    l32i    a3, a2, ACB_SCHAIN
    bnez    a3, 9f
    movi    a10, SCH_FIRST
    call8   rt_schunk_new
    mov     a3, a10
    beqz    a3, 8f
    s32i    a3, a2, ACB_SCHAIN
    s32i    a3, a2, ACB_SCUR
    addi    a10, a3, SCH_HEADS
    movi    a11, SCH_HEADS_BYTES
    call8   silica_rt_zero_block
    addi    a8, a3, SCH_HEADS + SCH_HEADS_BYTES
    s32i    a8, a3, SCH_CUR
    movi    a8, 0
    s32i    a8, a2, ACB_SBYTES
9:  retw
8:  call8   silica_rt_abort_heap_exhausted
    j       8b
    .size   silica_rt_state_chain_init, . - silica_rt_state_chain_init

// silica_rt_state_hole_pop(a2 = acb, a3 = bytes) -> a2 = a free node of exactly that size, or 0.
    .align  4
    .global silica_rt_state_hole_pop
    .type   silica_rt_state_hole_pop, @function
silica_rt_state_hole_pop:
    entry   a1, 32
    l32i    a4, a2, ACB_SCHAIN
    beqz    a4, 9f
    movi    a5, 1024
    bltu    a5, a3, 2f
    srli    a5, a3, 3
    addi    a5, a5, -1
    addx4   a5, a5, a4
    l32i    a6, a5, SCH_HEADS           // head n/8 - 1
    beqz    a6, 9f
    l32i    a7, a6, 0
    s32i    a7, a5, SCH_HEADS
    mov     a2, a6
    j       8f
2:  addi    a5, a4, SCH_HEADS + 128 * 4 // head 128: a node of exactly n bytes, its size at +4
    l32i    a6, a5, 0
3:  beqz    a6, 9f
    l32i    a7, a6, 4
    beq     a7, a3, 4f
    mov     a5, a6
    l32i    a6, a6, 0
    j       3b
4:  l32i    a7, a6, 0
    s32i    a7, a5, 0
    mov     a2, a6
8:  l32i    a8, a2, 0                   // (the popped node's bytes are rewritten by its copier)
    retw
9:  movi    a2, 0
    retw
    .size   silica_rt_state_hole_pop, . - silica_rt_state_hole_pop

// silica_rt_state_alloc(a2 = acb, a3 = bytes) -> a2 = the node or 0: a hole of the size, else a bump
// from the current chunk, else a fresh chunk (doubling to SCH_CAP, or the node's size when larger).
    .align  4
    .global silica_rt_state_alloc
    .type   silica_rt_state_alloc, @function
silica_rt_state_alloc:
    entry   a1, 32
    mov     a10, a2
    call8   silica_rt_state_chain_init
    mov     a10, a2
    mov     a11, a3
    call8   silica_rt_state_hole_pop
    bnez    a10, 7f
    l32i    a4, a2, ACB_SCUR
    l32i    a5, a4, SCH_CUR
    l32i    a6, a4, SCH_END
    add     a7, a5, a3
    bltu    a6, a7, 2f
    s32i    a7, a4, SCH_CUR
    mov     a10, a5
    j       7f
2:  l32i    a5, a4, SCH_SIZE
    slli    a5, a5, 1
    movi    a6, SCH_CAP
    bgeu    a6, a5, 3f
    mov     a5, a6
3:  bgeu    a5, a3, 4f
    mov     a5, a3
4:  mov     a10, a5
    call8   rt_schunk_new
    beqz    a10, 9f
    s32i    a10, a4, SCH_NEXT
    s32i    a10, a2, ACB_SCUR
    mov     a4, a10
    l32i    a5, a4, SCH_CUR
    add     a7, a5, a3
    s32i    a7, a4, SCH_CUR
    mov     a10, a5
7:  l32i    a8, a2, ACB_SBYTES
    add     a8, a8, a3
    s32i    a8, a2, ACB_SBYTES
    mov     a2, a10
    retw
9:  movi    a2, 0
    retw
    .size   silica_rt_state_alloc, . - silica_rt_state_alloc

// silica_rt_state_free(a2 = acb, a3 = node, a4 = bytes): the node goes on the list for its size. Leaf.
    .align  4
    .global silica_rt_state_free
    .type   silica_rt_state_free, @function
silica_rt_state_free:
    entry   a1, 32
    l32i    a5, a2, ACB_SCHAIN
    beqz    a5, 9f
    beqz    a3, 9f
    movi    a6, 1024
    bltu    a6, a4, 2f
    srli    a6, a4, 3
    addi    a6, a6, -1
    addx4   a6, a6, a5
    l32i    a7, a6, SCH_HEADS
    s32i    a7, a3, 0
    s32i    a3, a6, SCH_HEADS
    j       3f
2:  addi    a6, a5, SCH_HEADS + 128 * 4
    l32i    a7, a6, 0
    s32i    a7, a3, 0
    s32i    a4, a3, 4
    s32i    a3, a6, 0
3:  l32i    a8, a2, ACB_SBYTES
    sub     a8, a8, a4
    s32i    a8, a2, ACB_SBYTES
9:  retw
    .size   silica_rt_state_free, . - silica_rt_state_free

// silica_rt_state_contains(a2 = acb, a3 = ptr) -> a2 = 1 when ptr lies in a node area of the chain.
    .align  4
    .global silica_rt_state_contains
    .type   silica_rt_state_contains, @function
silica_rt_state_contains:
    entry   a1, 32
    l32i    a4, a2, ACB_SCHAIN
1:  beqz    a4, 9f
    addi    a5, a4, SCH_HEADER
    l32i    a6, a4, SCH_END
    bltu    a3, a5, 2f
    bltu    a3, a6, 8f
2:  l32i    a4, a4, SCH_NEXT
    j       1b
8:  movi    a2, 1
    retw
9:  movi    a2, 0
    retw
    .size   silica_rt_state_contains, . - silica_rt_state_contains

// silica_rt_state_chain_free_all(a2 = acb): every chunk and the release log go back (the actor's end,
// and a compaction's old chain through rt_schain_free).
    .align  4
    .global silica_rt_state_chain_free_all
    .type   silica_rt_state_chain_free_all, @function
silica_rt_state_chain_free_all:
    entry   a1, 32
    l32i    a10, a2, ACB_SCHAIN
    call8   rt_schain_free
    movi    a8, 0
    s32i    a8, a2, ACB_SCHAIN
    s32i    a8, a2, ACB_SCUR
    s32i    a8, a2, ACB_SBYTES
    l32i    a10, a2, ACB_SLOG
    beqz    a10, 1f
    call8   silica_rt_free
    movi    a8, 0
    s32i    a8, a2, ACB_SLOG
1:  movi    a8, 0
    s32i    a8, a2, ACB_SLOGN
    s32i    a8, a2, ACB_SLOGN + 4
    retw
    .size   silica_rt_state_chain_free_all, . - silica_rt_state_chain_free_all

// rt_schain_free(a2 = first chunk)
    .align  4
    .type   rt_schain_free, @function
rt_schain_free:
    entry   a1, 32
1:  beqz    a2, 9f
    l32i    a3, a2, SCH_NEXT
    mov     a10, a2
    call8   silica_rt_free
    mov     a2, a3
    j       1b
9:  retw
    .size   rt_schain_free, . - rt_schain_free

// ---- descriptor access ----------------------------------------------------------------------------
// An entry: 16 bytes, KIND at +0, AUX at +8 (low words). A descriptor: N at +0, RIDX at +8, entries
// from +16. The root-word form has N = 1.

// rt_round8 / rt_round16 are inline: (x + 7) & ~7, (x + 15) & ~15.

// rt_is_old(a2 = ptr) -> a2 = 1 when the node must be kept as it is (old mode): a chain node (mode 1),
// or, under the frame rule (mode 2), a pointer that is neither in [C0 limit, p) nor in a chunk above C0.
    .align  4
    .type   rt_is_old, @function
rt_is_old:
    entry   a1, 32
    mov     a3, a2
    call8   rt_ccb
    mov     a4, a10
    l32i    a5, a4, CCB_OMODE
    beqz    a5, 9f
    beqi    a5, 2, 2f
    l32i    a10, a4, CCB_ACB
    mov     a11, a3
    call8   silica_rt_state_contains
    mov     a2, a10
    retw
2:  l32i    a6, a4, CCB_C0
    l32i    a7, a6, CH_LIMIT
    l32i    a8, a4, CCB_P
    bltu    a3, a7, 3f
    bgeu    a3, a8, 3f
    j       9f                          // in the callee's part of C0: new
3:  l32i    a6, a6, CH_NEXT
4:  beqz    a6, 8f
    l32i    a7, a6, CH_LIMIT
    l32i    a8, a6, CH_TOP
    bltu    a3, a7, 5f
    bltu    a3, a8, 9f                  // in a chunk above C0: new
5:  l32i    a6, a6, CH_NEXT
    j       4b
8:  movi    a2, 1
    retw
9:  movi    a2, 0
    retw
    .size   rt_is_old, . - rt_is_old

// rt_place(a2 = bytes, a multiple of 8) -> a2 = where the node's bytes are written, a3 = the address
// the copy's pointers hold (dest + delta). Bump mode: the cursor (an overrun aborts: the measure and
// the copy disagree); chain mode: a hole of the size, else a chain node.
    .align  4
    .type   rt_place, @function
rt_place:
    entry   a1, 32
    mov     a3, a2
    call8   rt_ccb
    mov     a4, a10
    l32i    a5, a4, CCB_DMODE
    bnez    a5, 2f
    l32i    a2, a4, CCB_CUR
    add     a6, a2, a3
    l32i    a7, a4, CCB_END
    bltu    a7, a6, 8f
    s32i    a6, a4, CCB_CUR
    l32i    a7, a4, CCB_DELTA
    add     a3, a2, a7
    retw
2:  l32i    a10, a4, CCB_ACB
    mov     a11, a3
    call8   silica_rt_state_alloc
    beqz    a10, 7f
    mov     a2, a10
    mov     a3, a10
    retw
7:  call8   silica_rt_region_alloc_failed
    j       7b
8:  call8   silica_rt_abort_copier_overrun
    j       8b
    .size   rt_place, . - rt_place

// rt_slot_enter() / rt_slot_leave(a2 = the saved spine flag): a state copy empties the table before a
// slot (a ref, list, string, buffer reached through the aggregate spine) and keeps it within the slot.
    .align  4
    .type   rt_slot_enter, @function
rt_slot_enter:
    entry   a1, 32
    call8   rt_ccb
    mov     a3, a10
    l32i    a2, a3, CCB_SPINE
    beqz    a2, 9f
    call8   rt_tab_clear
    movi    a8, 0
    s32i    a8, a3, CCB_SPINE
9:  retw
    .size   rt_slot_enter, . - rt_slot_enter

    .align  4
    .type   rt_slot_leave, @function
rt_slot_leave:
    entry   a1, 32
    mov     a3, a2
    call8   rt_ccb
    s32i    a3, a10, CCB_SPINE
    retw
    .size   rt_slot_leave, . - rt_slot_leave

// ---- the measure (pass 0) -------------------------------------------------------------------------
// rt_sm_val(a2 = value lo, a3 = kind, a4 = aux): adds the bytes of the value's copy to CCB_TOTAL.
    .align  4
    .type   rt_sm_val, @function
rt_sm_val:
    entry   a1, 48
    movi    a8, 65536
    bltu    a2, a8, 9f                  // an atom, nil, a small scalar: a word
    beqi    a3, 2, 2f
    beqi    a3, 3, 3f
    beqi    a3, 4, 4f
    beqi    a3, 5, 5f
    beqi    a3, 6, 6f
    beqi    a3, 7, 7f
    movi    a8, 8
    beq     a3, a8, 8f
9:  retw                                // 0 word, 1 region, 9 closure, unknown
    // every node kind: an old node is kept, not followed
2:  mov     a10, a2
    call8   rt_is_old
    bnez    a10, 9b
    call8   rt_slot_enter
    s32i    a10, a1, 0
    mov     a10, a2
    call8   rt_tab_find
    bnez    a10, 29f
    mov     a10, a2
    movi    a11, 1
    call8   rt_tab_put
    movi    a10, 8
    call8   rt_sm_add
    l32i    a10, a2, 0                  // the cell's word by the one-entry descriptor at aux
    l32i    a11, a4, 16
    l32i    a12, a4, 24
    call8   rt_sm_val
29: l32i    a10, a1, 0
    call8   rt_slot_leave
    retw
3:  mov     a10, a2
    call8   rt_is_old
    bnez    a10, 9b
    call8   rt_slot_enter
    s32i    a10, a1, 0
    mov     a10, a2
    call8   rt_tab_find
    bnez    a10, 39f
    mov     a10, a2
    movi    a11, 1
    call8   rt_tab_put
    l32i    a8, a4, 0                   // N of the payload
    slli    a8, a8, 3
    addi    a8, a8, 15
    movi    a9, -16
    and     a8, a8, a9
    addi    a10, a8, 8
    call8   rt_sm_add
    l32i    a10, a2, 0                  // the payload tuple's words
    beqz    a10, 39f
    mov     a11, a4
    call8   rt_sm_fields
39: l32i    a10, a1, 0
    call8   rt_slot_leave
    retw
4:  mov     a10, a2
    call8   rt_is_old
    bnez    a10, 9b
    l32i    a10, a4, 0
    slli    a10, a10, 3
    call8   rt_sm_add
    mov     a10, a2
    mov     a11, a4
    call8   rt_sm_fields
    retw
5:  mov     a10, a2
    call8   rt_is_old
    bnez    a10, 9b
    mov     a10, a2
    mov     a11, a4
    call8   rt_sum_desc
    beqz    a10, 9b
    mov     a4, a10
    l32i    a10, a4, 0
    slli    a10, a10, 3
    call8   rt_sm_add
    mov     a10, a2
    mov     a11, a4
    call8   rt_sm_fields
    retw
6:  mov     a10, a2
    call8   rt_is_old
    bnez    a10, 9b
    call8   rt_slot_enter
    mov     a5, a10
    mov     a10, a2
    mov     a11, a4
    call8   rt_buf_bytes
    call8   rt_sm_add
    mov     a10, a5
    call8   rt_slot_leave
    retw
7:  mov     a10, a2
    call8   rt_is_old
    bnez    a10, 9b
    call8   rt_slot_enter
    s32i    a10, a1, 0
    movi    a10, 24
    call8   rt_sm_add
    l32i    a8, a4, 8                   // SLOT: the chunk slot bytes; a chunk is 2 slots, next, claim
    s32i    a8, a1, 4
    slli    a8, a8, 1
    s32i    a8, a1, 8                   // CDATA
    l32i    a5, a2, 0                   // elements left
    l32i    a6, a2, 8                   // chunk
    l32i    a7, a2, 16                  // cursor
71: beqz    a5, 79f
    beqz    a6, 79f
    l32i    a10, a1, 8
    addi    a10, a10, 16
    call8   rt_sm_add
72: l32i    a8, a1, 8
    bgeu    a7, a8, 73f
    beqz    a5, 79f
    l32i    a8, a1, 4
    movi    a9, 8
    bne     a8, a9, 74f                 // an inline aggregate slot: its words travel as they are
    add     a8, a6, a7
    l32i    a10, a8, 0
    l32i    a11, a4, 16
    l32i    a12, a4, 24
    call8   rt_sm_val
74: l32i    a8, a1, 4
    add     a7, a7, a8
    addi    a5, a5, -1
    j       72b
73: l32i    a8, a1, 8
    add     a6, a6, a8
    l32i    a6, a6, 0
    movi    a7, 0
    j       71b
79: l32i    a10, a1, 0
    call8   rt_slot_leave
    retw
8:  l32i    a8, a2, 0
    movi    a9, -2
    beq     a8, a9, 9b                  // a literal: a word
    mov     a10, a2
    call8   rt_is_old
    bnez    a10, 9b
    call8   rt_slot_enter
    mov     a5, a10
    mov     a10, a2
    call8   rt_string_bytes
    call8   rt_sm_add
    mov     a10, a5
    call8   rt_slot_leave
    retw
    .size   rt_sm_val, . - rt_sm_val

// rt_sm_fields(a2 = node, a3 = descriptor): every word of the aggregate by its entry.
    .align  4
    .type   rt_sm_fields, @function
rt_sm_fields:
    entry   a1, 32
    l32i    a4, a3, 0                   // N
    addi    a5, a3, 16                  // entry
    mov     a6, a2
1:  beqz    a4, 9f
    l32i    a10, a6, 0
    l32i    a11, a5, 0
    l32i    a12, a5, 8
    call8   rt_sm_val
    addi    a6, a6, 8
    addi    a5, a5, 16
    addi    a4, a4, -1
    j       1b
9:  retw
    .size   rt_sm_fields, . - rt_sm_fields

// rt_sm_add(a2 = bytes): one more node of that many bytes.
    .align  4
    .type   rt_sm_add, @function
rt_sm_add:
    entry   a1, 32
    mov     a3, a2
    call8   rt_ccb
    l32i    a8, a10, CCB_TOTAL
    add     a8, a8, a3
    s32i    a8, a10, CCB_TOTAL
    l32i    a8, a10, CCB_NODES
    addi    a8, a8, 1
    s32i    a8, a10, CCB_NODES
    retw
    .size   rt_sm_add, . - rt_sm_add

// rt_sum_desc(a2 = value, a3 = the sum table) -> a2 = the matching alternative's descriptor, or 0.
// The table: -1-M at +0, then M pairs (TAG at +0, DESC at +8, 16 bytes each) from +8, matched against
// the value's first word (a tuple alternative's tag atom, a record alternative's shape number).
    .align  4
    .type   rt_sum_desc, @function
rt_sum_desc:
    entry   a1, 32
    l32i    a4, a3, 0
    movi    a5, -1
    sub     a4, a5, a4                  // M
    l32i    a5, a2, 0                   // the value's first word
    addi    a6, a3, 8
1:  beqz    a4, 9f
    l32i    a7, a6, 0
    beq     a7, a5, 2f
    addi    a6, a6, 16
    addi    a4, a4, -1
    j       1b
2:  l32i    a2, a6, 8
    retw
9:  movi    a2, 0
    retw
    .size   rt_sum_desc, . - rt_sum_desc

// rt_buf_bytes(a2 = buffer elements, a3 = element bytes) -> a2 = the node's bytes: the count word at
// [buf - 8] plus count * elem rounded to 8.
    .align  4
    .type   rt_buf_bytes, @function
rt_buf_bytes:
    entry   a1, 32
    l32i    a4, a2, -8
    mull    a4, a4, a3
    addi    a4, a4, 15
    movi    a5, -8
    and     a2, a4, a5
    retw
    .size   rt_buf_bytes, . - rt_buf_bytes

// rt_string_bytes(a2 = string) -> a2 = 24 + bytes + 1 rounded to 8. The byte count is the header's
// third word ([16], rt_string.S); [8] is the pointer to the bytes (read here before: the measure
// added a pointer's worth of bytes to the total, and the evacuation of a string a function returned
// ended the actor with out_of_memory, or copied the header without its bytes).
    .align  4
    .type   rt_string_bytes, @function
rt_string_bytes:
    entry   a1, 32
    l32i    a4, a2, 16
    addi    a4, a4, 8 + 24
    movi    a5, -8
    and     a2, a4, a5
    retw
    .size   rt_string_bytes, . - rt_string_bytes

// ---- the copy (pass 1) ----------------------------------------------------------------------------
// rt_sc_val(a2 = value lo, a3 = value hi, a4 = kind, a5 = aux) -> a2:a3 the word the copy holds.
    .align  4
    .type   rt_sc_val, @function
rt_sc_val:
    entry   a1, 80                      // locals to [36]: below the window save areas ([48, 80))
    movi    a8, 65536
    bltu    a2, a8, 9f
    beqi    a4, 2, 2f
    beqi    a4, 3, 3f
    beqi    a4, 4, 4f
    beqi    a4, 5, 5f
    beqi    a4, 6, 6f
    beqi    a4, 7, 7f
    movi    a8, 8
    beq     a4, a8, 8f
9:  retw
    // REF1: a cell of one word
2:  mov     a10, a2
    call8   rt_is_old
    bnez    a10, 9b
    call8   rt_slot_enter
    s32i    a10, a1, 0
    mov     a10, a2
    call8   rt_tab_find
    bnez    a10, 29f
    movi    a10, 8
    call8   rt_place
    s32i    a10, a1, 4                  // dest
    s32i    a11, a1, 8                  // final
    mov     a10, a2
    mov     a11, a11
    l32i    a11, a1, 8
    call8   rt_tab_put                  // before the content: a cell may hold a ref to itself
    l32i    a10, a2, 0
    l32i    a11, a2, 4
    l32i    a12, a5, 16
    l32i    a13, a5, 24
    call8   rt_sc_val
    l32i    a8, a1, 4
    s32i    a10, a8, 0
    s32i    a11, a8, 4
    l32i    a10, a1, 8
29: s32i    a10, a1, 12
    l32i    a10, a1, 0
    call8   rt_slot_leave
    l32i    a2, a1, 12
    movi    a3, 0
    retw
    // REFTUP: a cell word pointing at a payload tuple; one node of 8 + the payload rounded to 16
3:  mov     a10, a2
    call8   rt_is_old
    bnez    a10, 9b
    call8   rt_slot_enter
    s32i    a10, a1, 0
    mov     a10, a2
    call8   rt_tab_find
    bnez    a10, 39f
    l32i    a8, a5, 0
    slli    a8, a8, 3
    addi    a8, a8, 15
    movi    a9, -16
    and     a8, a8, a9
    s32i    a8, a1, 16                  // payload bytes
    addi    a10, a8, 8
    call8   rt_place
    s32i    a10, a1, 4                  // dest cell
    s32i    a11, a1, 8                  // final cell
    mov     a10, a2
    l32i    a11, a1, 8
    call8   rt_tab_put
    l32i    a8, a1, 4
    l32i    a9, a1, 8
    l32i    a6, a2, 0                   // the source payload (0: an empty cell)
    beqz    a6, 31f
    addi    a9, a9, 8
    s32i    a9, a8, 0                   // the cell: the payload's final address
    movi    a9, 0
    s32i    a9, a8, 4
    mov     a10, a6
    addi    a11, a8, 8
    mov     a12, a5
    call8   rt_sc_fields
    j       32f
31: movi    a9, 0
    s32i    a9, a8, 0
    s32i    a9, a8, 4
32: l32i    a10, a1, 8
39: s32i    a10, a1, 12
    l32i    a10, a1, 0
    call8   rt_slot_leave
    l32i    a2, a1, 12
    movi    a3, 0
    retw
    // AGG: N words
4:  mov     a10, a2
    call8   rt_is_old
    bnez    a10, 9b
    l32i    a10, a5, 0
    slli    a10, a10, 3
    call8   rt_place
    s32i    a11, a1, 8
    mov     a11, a10
    mov     a10, a2
    mov     a12, a5
    call8   rt_sc_fields
    l32i    a2, a1, 8
    movi    a3, 0
    retw
    // SUM: the alternative's descriptor, then as AGG; an unknown alternative travels as a word
5:  mov     a10, a2
    call8   rt_is_old
    bnez    a10, 9b
    mov     a10, a2
    mov     a11, a5
    call8   rt_sum_desc
    beqz    a10, 9b
    mov     a5, a10
    j       4b
    // BUF: the count word and the elements
6:  mov     a10, a2
    call8   rt_is_old
    bnez    a10, 9b
    call8   rt_slot_enter
    s32i    a10, a1, 0
    mov     a10, a2
    mov     a11, a5
    call8   rt_buf_bytes
    s32i    a10, a1, 16
    call8   rt_place
    s32i    a11, a1, 8
    addi    a11, a2, -8                 // from the count word
    mov     a12, a10
    l32i    a13, a1, 16
    mov     a10, a11
    mov     a11, a12
    mov     a12, a13
    call8   rt_copy_bytes
    l32i    a10, a1, 0
    call8   rt_slot_leave
    l32i    a2, a1, 8
    addi    a2, a2, 8                   // the elements
    movi    a3, 0
    retw
    // LIST: the handle, then the spine chunk by chunk, each element by the element entry
7:  mov     a10, a2
    call8   rt_is_old
    bnez    a10, 9b
    call8   rt_slot_enter
    s32i    a10, a1, 0
    movi    a10, 24
    call8   rt_place
    s32i    a10, a1, 4                  // dest handle
    s32i    a11, a1, 8                  // final handle
    l32i    a8, a2, 0
    s32i    a8, a1, 20                  // elements left
    l32i    a8, a2, 4
    l32i    a9, a1, 4
    l32i    a6, a2, 0
    s32i    a6, a9, 0
    s32i    a8, a9, 4
    l32i    a8, a2, 16
    s32i    a8, a9, 16
    l32i    a8, a2, 20
    s32i    a8, a9, 20
    movi    a8, 0
    s32i    a8, a9, 8                   // first chunk: set below
    s32i    a8, a9, 12
    l32i    a6, a2, 8                   // source chunk
    l32i    a7, a2, 16                  // cursor
    addi    a8, a9, 8
    s32i    a8, a1, 24                  // where the next chunk's final address is stored
    l32i    a8, a5, 8                   // SLOT; a chunk is 2 slots, then next, then claim
    s32i    a8, a1, 32
    slli    a8, a8, 1
    s32i    a8, a1, 36                  // CDATA
71: l32i    a8, a1, 20
    beqz    a8, 79f
    beqz    a6, 79f
    l32i    a10, a1, 36
    addi    a10, a10, 16
    call8   rt_place
    s32i    a10, a1, 28                 // dest chunk
    l32i    a8, a1, 24
    s32i    a11, a8, 0
    movi    a9, 0
    s32i    a9, a8, 4
    l32i    a8, a1, 28
    l32i    a4, a1, 36
    add     a8, a8, a4
    s32i    a9, a8, 0                   // next (set when the next chunk is placed)
    s32i    a9, a8, 4
    s32i    a7, a8, 8                   // claim = the first offset in use in this copy
    s32i    a9, a8, 12
    s32i    a8, a1, 24
72: l32i    a8, a1, 36
    bgeu    a7, a8, 73f
    l32i    a8, a1, 20
    beqz    a8, 79f
    l32i    a8, a1, 32
    movi    a9, 8
    bne     a8, a9, 75f                 // an inline aggregate slot: its words copied as they are
    add     a8, a6, a7
    l32i    a10, a8, 0
    l32i    a11, a8, 4
    l32i    a12, a5, 16
    l32i    a13, a5, 24
    call8   rt_sc_val
    l32i    a8, a1, 28
    add     a8, a8, a7
    s32i    a10, a8, 0
    s32i    a11, a8, 4
    j       76f
75: add     a10, a6, a7
    l32i    a11, a1, 28
    add     a11, a11, a7
    mov     a12, a8
    call8   rt_copy_bytes
76: l32i    a8, a1, 32
    add     a7, a7, a8
    l32i    a8, a1, 20
    addi    a8, a8, -1
    s32i    a8, a1, 20
    j       72b
73: l32i    a8, a1, 36
    add     a6, a6, a8
    l32i    a6, a6, 0
    movi    a7, 0
    j       71b
79: l32i    a10, a1, 0
    call8   rt_slot_leave
    l32i    a2, a1, 8
    movi    a3, 0
    retw
    // STRING: a fresh header whose bytes are its own (at +24, the NUL after them), the bytes read
    // through the source's pointer: a run-time string keeps them inline, a literal (marker -1 on
    // this target too, L_str_n in the emitted rodata) points at its rodata bytes. The hosted
    // Lw_string / Lw_str_fix do the same; copying the header as it was left the copy's pointer at
    // the callee's dead chunk (a string returned by a function printed as "not a Silica string").
8:  l32i    a8, a2, 0
    movi    a9, -2
    beq     a8, a9, 9b
    mov     a10, a2
    call8   rt_is_old
    bnez    a10, 9b
    call8   rt_slot_enter
    s32i    a10, a1, 0
    mov     a10, a2
    call8   rt_string_bytes
    call8   rt_place
    s32i    a11, a1, 8                  // final
    movi    a8, -1
    s32i    a8, a10, 0
    s32i    a8, a10, 4
    addi    a8, a11, 24
    s32i    a8, a10, 8                  // the copy's pointer: its own bytes
    movi    a8, 0
    s32i    a8, a10, 12
    l32i    a9, a2, 16
    s32i    a9, a10, 16
    s32i    a8, a10, 20
    l32i    a6, a2, 8                   // src bytes
    addi    a7, a10, 24                 // dst bytes
    addi    a9, a9, 1                   // len + the NUL
    add     a9, a6, a9
81: bgeu    a6, a9, 82f
    l8ui    a8, a6, 0
    s8i     a8, a7, 0
    addi    a6, a6, 1
    addi    a7, a7, 1
    j       81b
82: l32i    a10, a1, 0
    call8   rt_slot_leave
    l32i    a2, a1, 8
    movi    a3, 0
    retw
    .size   rt_sc_val, . - rt_sc_val

// rt_sc_fields(a2 = source node, a3 = destination node, a4 = descriptor): every word by its entry.
    .align  4
    .type   rt_sc_fields, @function
rt_sc_fields:
    entry   a1, 32
    l32i    a5, a4, 0                   // N
    addi    a6, a4, 16                  // entry
1:  beqz    a5, 9f
    l32i    a10, a2, 0
    l32i    a11, a2, 4
    l32i    a12, a6, 0
    l32i    a13, a6, 8
    call8   rt_sc_val
    s32i    a10, a3, 0
    s32i    a11, a3, 4
    addi    a2, a2, 8
    addi    a3, a3, 8
    addi    a6, a6, 16
    addi    a5, a5, -1
    j       1b
9:  retw
    .size   rt_sc_fields, . - rt_sc_fields

// rt_copy_bytes(a2 = src, a3 = dst, a4 = bytes, a multiple of 8)
    .align  4
    .type   rt_copy_bytes, @function
rt_copy_bytes:
    entry   a1, 32
    beqz    a4, 9f
    add     a5, a2, a4
1:  l32i    a8, a2, 0
    s32i    a8, a3, 0
    addi    a2, a2, 4
    addi    a3, a3, 4
    bltu    a2, a5, 1b
9:  retw
    .size   rt_copy_bytes, . - rt_copy_bytes

// ---- the two passes over a root-word descriptor -----------------------------------------------------
// rt_measure_root(a2 = value lo, a3 = root descriptor) -> a2 = CCB_TOTAL (the CCB was reset by the
// caller). The table is dropped.
    .align  4
    .type   rt_measure_root, @function
rt_measure_root:
    entry   a1, 32
    mov     a10, a2
    l32i    a11, a3, 16
    l32i    a12, a3, 24
    call8   rt_sm_val
    call8   rt_tab_drop
    call8   rt_ccb
    l32i    a2, a10, CCB_TOTAL
    retw
    .size   rt_measure_root, . - rt_measure_root

// rt_copy_root(a2 = value lo, a3 = value hi, a4 = root descriptor) -> a2:a3 the copy's root. The CCB's
// modes are the measure's; the spine flag is set again for a state copy; the table is dropped after.
    .align  4
    .type   rt_copy_root, @function
rt_copy_root:
    entry   a1, 32
    mov     a10, a2
    mov     a11, a3
    l32i    a12, a4, 16
    l32i    a13, a4, 24
    call8   rt_sc_val
    mov     a2, a10
    mov     a3, a11
    call8   rt_tab_drop
    retw
    .size   rt_copy_root, . - rt_copy_root

// rt_spine_again(): a copy pass starts with the spine flag the measure started with.
    .align  4
    .type   rt_spine_again, @function
rt_spine_again:
    entry   a1, 32
    mov     a3, a2
    call8   rt_ccb
    s32i    a3, a10, CCB_SPINE
    movi    a8, 1
    s32i    a8, a10, CCB_PASS
    retw
    .size   rt_spine_again, . - rt_spine_again

// ---- the mailbox buffer (phase 4a / 4c / 4e) --------------------------------------------------------
// silica_rt_message_buffer(a2:a3 = value, a4 = desc) -> a2:a3 root, a4 bytes, a6 block.
    .set    silica_rt_message_buffer__stack_bound, 2560   // recursive copier: see rt_frame.S silica_rt_ev_frame
    .align  4
    .global silica_rt_message_buffer
    .type   silica_rt_message_buffer, @function
silica_rt_message_buffer:
    entry   a1, 64
    s32i    a2, a1, 0
    s32i    a3, a1, 4
    s32i    a4, a1, 8
    movi    a8, 65536
    bltu    a2, a8, 9f
    movi    a10, 0
    movi    a11, 0
    movi    a12, 0
    movi    a13, 0
    call8   rt_ccb_reset
    l32i    a10, a1, 0
    l32i    a11, a1, 8
    call8   rt_measure_root
    beqz    a10, 9f
    addi    a10, a10, 15
    movi    a8, -16
    and     a10, a10, a8
    s32i    a10, a1, 12                 // bytes
    call8   silica_rt_alloc_or_null
    beqz    a10, 8f
    s32i    a10, a1, 16                 // block
    call8   rt_ccb
    l32i    a8, a1, 16
    s32i    a8, a10, CCB_CUR
    l32i    a9, a1, 12
    add     a9, a9, a8
    s32i    a9, a10, CCB_END
    movi    a10, 0
    call8   rt_spine_again
    l32i    a10, a1, 0
    l32i    a11, a1, 4
    l32i    a12, a1, 8
    call8   rt_copy_root
    mov     a2, a10
    mov     a3, a11
    l32i    a4, a1, 12
    movi    a5, 0
    l32i    a6, a1, 16
    movi    a7, 0
    retw
9:  l32i    a2, a1, 0
    l32i    a3, a1, 4
    movi    a4, 0
    movi    a5, 0
    movi    a6, 0
    movi    a7, 0
    retw
8:  call8   silica_rt_region_alloc_failed
    j       8b
    .size   silica_rt_message_buffer, . - silica_rt_message_buffer

// silica_rt_message_forward(a2:a3 = value, a4 = desc, a6 = the sending function's entry): the serving
// node's own buffer is handed on when the sender is the behaviour being dispatched, the node a plain
// cast node whose buffer root is the value, and no shallow copy ran in the dispatch (ACB_SRETAIN).
    .set    silica_rt_message_forward__stack_bound, 2560   // recursive copier: see rt_frame.S silica_rt_ev_frame
    .align  4
    .global silica_rt_message_forward
    .type   silica_rt_message_forward, @function
silica_rt_message_forward:
    entry   a1, 48
    s32i    a2, a1, 0
    s32i    a3, a1, 4
    s32i    a4, a1, 8
    s32i    a6, a1, 12
    call8   silica_rt_current_actor
    beqz    a10, 5f
    mov     a5, a10
    l32i    a7, a5, ACB_ACTIVE_CALL
    beqz    a7, 5f
    l32i    a8, a5, ACB_BEH
    l32i    a9, a1, 12
    bne     a8, a9, 5f
    l32i    a8, a7, MSG_KIND
    bnez    a8, 5f
    l32i    a8, a7, MSG_BUF_BLOCK
    beqz    a8, 5f
    l32i    a9, a7, MSG_PAYLOAD
    l32i    a4, a1, 0
    bne     a9, a4, 5f
    l32i    a9, a5, ACB_SRETAIN
    bnez    a9, 5f
    l32i    a6, a7, MSG_BUF_BYTES
    movi    a9, 0
    s32i    a9, a7, MSG_BUF_BLOCK
    s32i    a9, a7, MSG_BUF_BYTES
    s32i    a9, a7, MSG_PAYLOAD_OWNED
    l32i    a2, a1, 0
    l32i    a3, a1, 4
    mov     a4, a6
    movi    a5, 0
    mov     a6, a8
    movi    a7, 0
    retw
5:  l32i    a10, a1, 0
    l32i    a11, a1, 4
    l32i    a12, a1, 8
    call8   silica_rt_message_buffer
    mov     a2, a10
    mov     a3, a11
    mov     a4, a12
    mov     a5, a13
    mov     a6, a14
    mov     a7, a15
    retw
    .size   silica_rt_message_forward, . - silica_rt_message_forward

// ---- the reply into the caller's stack (phase 4c) ------------------------------------------------
// silica_rt_reply_place(a2:a3 = value, a4 = desc) -> a2:a3 the copy's root. The blocked caller is the
// serving node's MSG_CALLER; the copy goes directly under its parked SP (the node's MSG_PARK_SP) in its
// parked auxiliary chunk when it fits, else into a fresh chunk appended to its chain; the caller wakes
// with SP at the copy's bottom (MSG_PARK_SP written back), its floor as parked, and its call site adopts
// [SP, p) (silica_rt_adopt moves the transient part under the copy). Outside an actor, for a cast that
// reached a call-style behaviour, and for a scalar word nothing is copied.
// Frame: [0] lo, [4] hi, [8] desc, [12] caller, [16] total, [20] p, [24] floor, [28] chunk, [32] len,
// [36] dest low.
    .set    silica_rt_reply_place__stack_bound, 2560   // recursive copier: see rt_frame.S silica_rt_ev_frame
    .align  4
    .global silica_rt_reply_place
    .type   silica_rt_reply_place, @function
silica_rt_reply_place:
    entry   a1, 80
    s32i    a2, a1, 0
    s32i    a3, a1, 4
    s32i    a4, a1, 8
    movi    a8, 65536
    bltu    a2, a8, 9f
    call8   silica_rt_current_actor
    beqz    a10, 9f
    l32i    a5, a10, ACB_ACTIVE_CALL
    beqz    a5, 9f
    l32i    a8, a5, MSG_KIND
    bnei    a8, 1, 9f
    l32i    a6, a5, MSG_CALLER
    beqz    a6, 9f
    s32i    a6, a1, 12
    s32i    a5, a1, 40                  // [40] the call node
    movi    a10, 0
    movi    a11, 0
    movi    a12, 0
    movi    a13, 0
    call8   rt_ccb_reset
    l32i    a10, a1, 0
    l32i    a11, a1, 8
    call8   rt_measure_root
    beqz    a10, 9f
    addi    a10, a10, 15
    movi    a8, -16
    and     a10, a10, a8
    s32i    a10, a1, 16                 // total
    // p, the floor and the chunk as the caller parked them, from the node (rt_actors.S
    // silica_rt_actor_call writes them before the node is enqueued; the ACB's context words are
    // written by the caller's own switch-out, which may come after this on the other core)
    l32i    a6, a1, 40
    l32i    a8, a6, MSG_PARK_SP
    s32i    a8, a1, 20                  // p: the caller's SP as it blocked (= its pre-call SP)
    l32i    a8, a6, MSG_PARK_FLOOR
    s32i    a8, a1, 24
    l32i    a8, a6, MSG_PARK_CHUNK
    s32i    a8, a1, 28
    l32i    a10, a1, 20
    l32i    a11, a1, 24
    mov     a12, a8
    call8   rt_transient_len_of         // (rt_frame.S rule, this file's copy)
    s32i    a10, a1, 32                 // len
    // room under p in the caller's chunk for the copy and the moved transient part?
    l32i    a7, a1, 28
    l32i    a8, a7, CH_LIMIT
    l32i    a9, a1, 20
    l32i    a4, a1, 16
    sub     a9, a9, a4                  // dest low
    movi    a4, -16
    and     a9, a9, a4
    l32i    a4, a1, 32
    sub     a4, a9, a4
    bltu    a4, a8, 2f
    s32i    a9, a1, 36
    j       3f
2:  l32i    a6, a1, 12
    l8ui    a8, a6, ACB_KIND
    bnez    a8, 8f                      // main's stack does not grow
    mov     a10, a6
    l32i    a11, a1, 28
    l32i    a12, a1, 16
    l32i    a13, a1, 32
    add     a12, a12, a13
    l32i    a13, a1, 20                 // a restore to p pops the chunk
    call8   silica_rt_aux_chunk_append
    beqz    a10, 8f
    movi    a8, -1
    beq     a10, a8, 8f
    l32i    a6, a1, 40
    s32i    a10, a6, MSG_PARK_CHUNK     // the caller resumes in it (it publishes the chunk on waking)
    l32i    a8, a10, CH_TOP
    l32i    a9, a1, 16
    sub     a9, a8, a9
    s32i    a9, a1, 36
3:  // copy, bump mode, into [dest low, dest low + total)
    call8   rt_ccb
    l32i    a8, a1, 36
    s32i    a8, a10, CCB_CUR
    l32i    a9, a1, 16
    add     a9, a9, a8
    s32i    a9, a10, CCB_END
    movi    a10, 0
    call8   rt_spine_again
    l32i    a10, a1, 0
    l32i    a11, a1, 4
    l32i    a12, a1, 8
    call8   rt_copy_root
    s32i    a10, a1, 0
    s32i    a11, a1, 4
    // the caller wakes with SP at the copy's bottom and its floor and transient part [p, floor) as
    // they were: its call site then ADOPTS [SP, p) (rt_frame.S silica_rt_adopt: the transient part
    // moves under the copy, the floor becomes SP). Moving the transient part and lowering the floor
    // here as well made the adopt see a floor below p, a transient length of -total, and pop the
    // reply: every later reply landed on the first (actors_addition/actor_composite_reply_outlives_
    // callee_dispatch read the third reply as the first).
    l32i    a6, a1, 40
    l32i    a8, a1, 36
    s32i    a8, a6, MSG_PARK_SP         // the caller's SP on waking (rt_actors.S silica_rt_actor_call)
9:  l32i    a2, a1, 0
    l32i    a3, a1, 4
    retw
8:  call8   silica_rt_region_alloc_failed
    j       8b
    .size   silica_rt_reply_place, . - silica_rt_reply_place

// rt_transient_len_of(a2 = sp, a3 = floor, a4 = chunk) and rt_move_down_bytes(a2 = src, a3 = dst, a4 =
// bytes): rt_frame.S's rule and move, repeated here (file-local there).
    .align  4
    .type   rt_transient_len_of, @function
rt_transient_len_of:
    entry   a1, 32
    l32i    a8, a4, CH_LIMIT
    l32i    a9, a4, CH_TOP
    bltu    a3, a8, 1f
    bltu    a9, a3, 1f
    sub     a2, a3, a2
    retw
1:  sub     a2, a9, a2
    retw
    .size   rt_transient_len_of, . - rt_transient_len_of

    .align  4
    .type   rt_move_down_bytes, @function
rt_move_down_bytes:
    entry   a1, 32
    beqz    a4, 2f
    add     a5, a2, a4
1:  l32i    a8, a2, 0
    s32i    a8, a3, 0
    addi    a2, a2, 4
    addi    a3, a3, 4
    bltu    a2, a5, 1b
2:  retw
    .size   rt_move_down_bytes, . - rt_move_down_bytes

// ---- the frame evacuation's two passes (rt_frame.S silica_rt_ev_frame) ----------------------------
// silica_rt_frame_measure(a2 = value, a3 = kind, a4 = aux, a5 = p, a6 = C0) -> a2 = bytes rounded to 16.
    .align  4
    .global silica_rt_frame_measure
    .type   silica_rt_frame_measure, @function
silica_rt_frame_measure:
    entry   a1, 48
    s32i    a2, a1, 0
    s32i    a3, a1, 4
    s32i    a4, a1, 8
    movi    a10, 0
    movi    a11, 2
    movi    a12, 0
    movi    a13, 0
    call8   rt_ccb_reset
    s32i    a5, a10, CCB_P
    s32i    a6, a10, CCB_C0
    l32i    a10, a1, 0
    l32i    a11, a1, 4
    l32i    a12, a1, 8
    call8   rt_sm_val
    call8   rt_tab_drop
    call8   rt_ccb
    l32i    a2, a10, CCB_TOTAL
    addi    a2, a2, 15
    movi    a8, -16
    and     a2, a2, a8
    retw
    .size   silica_rt_frame_measure, . - silica_rt_frame_measure

// silica_rt_frame_copy_delta(a2 = delta): the copy pass that follows writes its nodes at the cursor
// and every pointer (the root included) as cursor + delta. Main's evacuation (rt_frame.S, no chunk
// to append) copies into scratch below the callee's SP and moves the block up to its final place
// under p as bytes, so the pointers are written for the final place. Zero after a measure.
    .align  4
    .global silica_rt_frame_copy_delta
    .type   silica_rt_frame_copy_delta, @function
silica_rt_frame_copy_delta:
    entry   a1, 32
    mov     a3, a2
    call8   rt_ccb
    s32i    a3, a10, CCB_DELTA
    retw
    .size   silica_rt_frame_copy_delta, . - silica_rt_frame_copy_delta

// silica_rt_frame_copy(a2:a3 = value, a4 = kind, a5 = aux, a6 = dest low, a7 = p) -> a2:a3 the root.
    .align  4
    .global silica_rt_frame_copy
    .type   silica_rt_frame_copy, @function
silica_rt_frame_copy:
    entry   a1, 48
    s32i    a2, a1, 0
    s32i    a3, a1, 4
    s32i    a4, a1, 8
    s32i    a5, a1, 12
    call8   rt_ccb
    s32i    a6, a10, CCB_CUR
    l32i    a8, a10, CCB_TOTAL
    addi    a8, a8, 15
    movi    a9, -16
    and     a8, a8, a9
    add     a8, a8, a6
    s32i    a8, a10, CCB_END
    movi    a10, 0
    call8   rt_spine_again
    l32i    a10, a1, 0
    l32i    a11, a1, 4
    l32i    a12, a1, 8
    l32i    a13, a1, 12
    call8   rt_sc_val
    mov     a2, a10
    mov     a3, a11
    call8   rt_tab_drop
    retw
    .size   silica_rt_frame_copy, . - silica_rt_frame_copy

// ---- the state at a spawn and at a dispatch end (phases 3b, 3c, §4.3-§4.7) -------------------------
// silica_rt_state_install(a2 = acb, a3:a4 = value, a5 = root descriptor or 0) -> a2 = 0. The value is
// stored at ACB_STATE; a described pointer value is copied into the child's chain first (one table per
// slot) and the copy's root stored.
    .set    silica_rt_state_install__stack_bound, 2560   // recursive copier: see rt_frame.S silica_rt_ev_frame
    .align  4
    .global silica_rt_state_install
    .type   silica_rt_state_install, @function
silica_rt_state_install:
    entry   a1, 48
    s32i    a3, a1, 0
    s32i    a4, a1, 4
    beqz    a5, 9f
    movi    a8, 65536
    bltu    a3, a8, 9f
    s32i    a5, a1, 8
    mov     a10, a2
    call8   silica_rt_state_chain_init
    movi    a10, 1
    movi    a11, 0
    mov     a12, a2
    movi    a13, 1
    call8   rt_ccb_reset
    movi    a10, 1
    call8   rt_spine_again
    l32i    a10, a1, 0
    l32i    a11, a1, 4
    l32i    a12, a1, 8
    call8   rt_copy_root
    s32i    a10, a1, 0
    s32i    a11, a1, 4
9:  l32i    a8, a1, 0
    s32i    a8, a2, ACB_STATE
    l32i    a8, a1, 4
    s32i    a8, a2, ACB_STATE + 4
    movi    a2, 0
    retw
    .size   silica_rt_state_install, . - silica_rt_state_install

// silica_rt_state_dispatch_end(a2 = acb, a3:a4 = the new state as the behaviour returned it) -> a2:a3
// the root for ACB_STATE. A scalar, or a state whose descriptor is 0, is answered as given. A proven
// behaviour (ACB_SFLAGS 1 or 2) without a compaction request has its new nodes evacuated into the chain
// (old chain nodes kept, not followed), the old root shell freed when the root changed, and its release
// log drained (2) or dropped (1). An unproven behaviour, or a compaction request (ACB_SPOLICY bit 8), has
// its whole live state copied into a fresh chain and the old chain freed; the log is dropped. The
// descriptor, the flags, the retain mark and the request are cleared at the end.
// Frame: [0] lo, [4] hi, [8] desc, [12] old root lo, [16] old chain, [20] old cur, [24] old bytes.
// The frame is 64 bytes, not 48: a windowed frame of N bytes keeps [N-16, N) for the caller's a0-a3
// and [N-32, N-16) for this window's own a4-a7, which the overflow handler writes there whenever the
// calls below nest past the register file (the copier always does). With 48, [16] held the old chain
// of the unproven fallback inside that save area, a4 landed on it, and rt_schain_free got a pointer
// silica_rt_free ignores: one 2,072-byte chunk leaked per unproven dispatch (actors_addition/
// failure_reports_kept_and_forwarded and state_keeps_message_part_unproven exhausted the board heap
// at the 155th dispatch, 2026-11-06). Locals of a frame of N bytes must lie below N - 32.
    .set    silica_rt_state_dispatch_end__stack_bound, 2560   // recursive copier: see rt_frame.S silica_rt_ev_frame
    .align  4
    .global silica_rt_state_dispatch_end
    .type   silica_rt_state_dispatch_end, @function
silica_rt_state_dispatch_end:
    entry   a1, 64
    s32i    a3, a1, 0
    s32i    a4, a1, 4
    l32i    a5, a2, ACB_SDESC
    s32i    a5, a1, 8
    l32i    a8, a2, ACB_STATE
    s32i    a8, a1, 12
    beqz    a5, 7f
    movi    a8, 65536
    bltu    a3, a8, 7f
    l32i    a6, a2, ACB_SFLAGS
    beqz    a6, 5f
    l32i    a8, a2, ACB_SPOLICY
    bbsi    a8, 8, 5f
    // the proven path: evacuate the new nodes into the chain
    mov     a10, a2
    call8   silica_rt_state_chain_init
    movi    a10, 1
    movi    a11, 1
    mov     a12, a2
    movi    a13, 1
    call8   rt_ccb_reset
    movi    a10, 1
    call8   rt_spine_again
    l32i    a10, a1, 0
    l32i    a11, a1, 4
    l32i    a12, a1, 8
    call8   rt_copy_root
    s32i    a10, a1, 0
    s32i    a11, a1, 4
    // the old root shell goes back when the root changed and it was an aggregate chain node
    l32i    a8, a1, 12
    beq     a8, a10, 4f
    mov     a10, a2
    mov     a11, a8
    call8   silica_rt_state_contains
    beqz    a10, 4f
    l32i    a5, a1, 8
    l32i    a8, a5, 16                  // the root entry's KIND
    bnei    a8, 4, 4f
    l32i    a9, a5, 24                  // its AUX: the aggregate's descriptor
    l32i    a9, a9, 0
    slli    a12, a9, 3
    mov     a10, a2
    l32i    a11, a1, 12
    call8   silica_rt_state_free
4:  l32i    a6, a2, ACB_SFLAGS
    bnei    a6, 2, 6f
    mov     a10, a2
    call8   silica_rt_state_log_drain
    j       7f
5:  // the fallback: the whole live state into a fresh chain
    l32i    a8, a2, ACB_SCHAIN
    s32i    a8, a1, 16
    movi    a8, 0
    s32i    a8, a2, ACB_SCHAIN
    s32i    a8, a2, ACB_SCUR
    s32i    a8, a2, ACB_SBYTES
    mov     a10, a2
    call8   silica_rt_state_chain_init
    movi    a10, 1
    movi    a11, 0
    mov     a12, a2
    movi    a13, 1
    call8   rt_ccb_reset
    movi    a10, 1
    call8   rt_spine_again
    l32i    a10, a1, 0
    l32i    a11, a1, 4
    l32i    a12, a1, 8
    call8   rt_copy_root
    s32i    a10, a1, 0
    s32i    a11, a1, 4
    l32i    a10, a1, 16
    call8   rt_schain_free
6:  movi    a8, 0                       // the log is dropped
    s32i    a8, a2, ACB_SLOGN
7:  movi    a8, 0
    s32i    a8, a2, ACB_SDESC
    s32i    a8, a2, ACB_SDESC + 4
    s32i    a8, a2, ACB_SFLAGS
    s32i    a8, a2, ACB_SFLAGS + 4
    s32i    a8, a2, ACB_SRETAIN
    s32i    a8, a2, ACB_SRETAIN + 4
    s32i    a8, a2, ACB_SLOGN
    s32i    a8, a2, ACB_SLOGN + 4
    l32i    a9, a2, ACB_SPOLICY
    movi    a8, ~0x100
    and     a9, a9, a8
    s32i    a9, a2, ACB_SPOLICY
    l32i    a2, a1, 0
    l32i    a3, a1, 4
    retw
    .size   silica_rt_state_dispatch_end, . - silica_rt_state_dispatch_end

// ---- retire, the release log, retained nodes (§4.2, §7) ----------------------------------------------
// silica_rt_state_retire(a2 = node, a4 = bytes): nothing while the proof flag is 0 or the node is not a
// chain node; else appended to the actor's release log (ACB_SLOG: [0] capacity, entries (node, bytes)
// from +8; doubled when full, SLOG_FIRST entries first; ACB_SLOGN the count).
    .align  4
    .global silica_rt_state_retire
    .type   silica_rt_state_retire, @function
silica_rt_state_retire:
    entry   a1, 48
    s32i    a2, a1, 0
    s32i    a4, a1, 4
    call8   silica_rt_current_actor
    beqz    a10, 9f
    mov     a5, a10
    l32i    a8, a5, ACB_SFLAGS
    beqz    a8, 9f
    mov     a10, a5
    l32i    a11, a1, 0
    call8   silica_rt_state_contains
    beqz    a10, 9f
    l32i    a6, a5, ACB_SLOG
    l32i    a7, a5, ACB_SLOGN
    bnez    a6, 1f
    movi    a10, SLOG_FIRST * 8 + 8
    call8   silica_rt_alloc
    mov     a6, a10
    movi    a8, SLOG_FIRST
    s32i    a8, a6, 0
    s32i    a6, a5, ACB_SLOG
1:  l32i    a8, a6, 0
    bltu    a7, a8, 2f
    slli    a10, a8, 4
    addi    a10, a10, 8
    call8   silica_rt_alloc
    l32i    a8, a6, 0
    slli    a8, a8, 1
    s32i    a8, a10, 0
    mov     a4, a10
    addi    a10, a6, 8
    addi    a11, a4, 8
    slli    a12, a7, 3
    call8   rt_copy_bytes
    mov     a10, a6
    call8   silica_rt_free
    mov     a6, a4
    s32i    a6, a5, ACB_SLOG
2:  slli    a8, a7, 3
    add     a8, a8, a6
    l32i    a9, a1, 0
    s32i    a9, a8, 8
    l32i    a9, a1, 4
    s32i    a9, a8, 12
    addi    a7, a7, 1
    s32i    a7, a5, ACB_SLOGN
9:  retw
    .size   silica_rt_state_retire, . - silica_rt_state_retire

// silica_rt_state_log_drain(a2 = acb): every logged node goes to its free list; count 0.
    .align  4
    .global silica_rt_state_log_drain
    .type   silica_rt_state_log_drain, @function
silica_rt_state_log_drain:
    entry   a1, 32
    l32i    a3, a2, ACB_SLOG
    beqz    a3, 9f
    l32i    a4, a2, ACB_SLOGN
    addi    a5, a3, 8
1:  beqz    a4, 8f
    mov     a10, a2
    l32i    a11, a5, 0
    l32i    a12, a5, 4
    call8   silica_rt_state_free
    addi    a5, a5, 8
    addi    a4, a4, -1
    j       1b
8:  movi    a8, 0
    s32i    a8, a2, ACB_SLOGN
9:  retw
    .size   silica_rt_state_log_drain, . - silica_rt_state_log_drain

// silica_rt_state_retain_node(a2 = n) -> a2 = the elements of a zeroed uint8 buffer node of the current
// actor's chain (its count at [buf - 8]); 0 outside an actor or when the chain cannot grow.
    .align  4
    .global silica_rt_state_retain_node
    .type   silica_rt_state_retain_node, @function
silica_rt_state_retain_node:
    entry   a1, 32
    mov     a3, a2
    call8   silica_rt_current_actor
    beqz    a10, 9f
    mov     a4, a10
    addi    a5, a3, 15
    movi    a8, -8
    and     a5, a5, a8                  // 8 + n rounded to 8
    mov     a10, a4
    mov     a11, a5
    call8   silica_rt_state_alloc
    beqz    a10, 9f
    mov     a6, a10
    mov     a11, a5
    call8   silica_rt_zero_block
    s32i    a3, a6, 0
    addi    a2, a6, 8
    movi    a3, 0
    retw
9:  movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_state_retain_node, . - silica_rt_state_retain_node

// silica_rt_state_area_bytes() -> X0 = the calling actor's state bytes live; 0 outside an actor.
    .align  4
    .global silica_rt_state_area_bytes
    .type   silica_rt_state_area_bytes, @function
silica_rt_state_area_bytes:
    entry   a1, 32
    call8   silica_rt_current_actor
    movi    a2, 0
    movi    a3, 0
    beqz    a10, 9f
    l32i    a2, a10, ACB_SBYTES
9:  retw
    .size   silica_rt_state_area_bytes, . - silica_rt_state_area_bytes

// silica_rt_compact_state(): the request (ACB_SPOLICY bit 8) only under :compact_on_request (bits 4-5
// = 2); the dispatch end honours it.
    .align  4
    .global silica_rt_compact_state
    .type   silica_rt_compact_state, @function
silica_rt_compact_state:
    entry   a1, 32
    call8   silica_rt_current_actor
    movi    a2, 0
    movi    a3, 0
    beqz    a10, 9f
    l32i    a8, a10, ACB_SPOLICY
    extui   a9, a8, 4, 2
    bnei    a9, 2, 9f
    movi    a9, 0x100
    or      a8, a8, a9
    s32i    a8, a10, ACB_SPOLICY
9:  retw
    .size   silica_rt_compact_state, . - silica_rt_compact_state

// silica_rt_abort_copier_overrun: the measure and the copy disagreed (an invariant violation).
    .align  4
    .type   silica_rt_abort_copier_overrun, @function
silica_rt_abort_copier_overrun:
    entry   a1, 32
    call8   silica_rt_abort_heap_exhausted
1:  j       1b
    .size   silica_rt_abort_copier_overrun, . - silica_rt_abort_copier_overrun
