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

// Ordering identity, canonical arenas and checked int64 arithmetic for the bare-metal ESP32-S3
// runtime: the Layer 1 §7 routines the macOS emitter bundles with its actor runtime
// (terms/ordering_identity_runtime_asm.silica, canonical_arena_runtime_asm.silica,
// checked_int64_runtime_asm.silica), with the same values and layouts.
//
// Silica pair ABI: argument n in a2:a3, a4:a5, a6:a7; result in a2:a3.
//
//   silica_rt_ordering_env_fresh()             -> fresh non-zero environment instance id
//   silica_rt_ordering_identity_make(code, env) -> token = (code ^ env << 32) ^ env * K1
//   silica_rt_ordering_identity_same(a, b)     -> 0/1
//   silica_rt_ordering_bundle_make(fn, orient) -> (fn ^ orient * K2) & 0x7fff_ffff_ffff_ffff
//   silica_rt_canonical_arena_lookup(key)      -> region base for a non-zero specialization key
//                                                (a 512-entry open-addressing table; the region is a
//                                                4128-byte block laid out as prims_memory's regions,
//                                                so silica_rt_region_grow can extend it)
//   silica_rt_canonical_arena_same(a, b)       -> 0/1
//   silica_rt_checked_i64_add(a, b), _mul(a, b), _add1(a)
//                                              -> a2 = 1 when the result fits, 0 on overflow;
//                                                the result in a4:a5 (the caller's X1), 0 on overflow
//                                                (the host's convention: CSEL X1, X2, XZR, VC)
// 64-bit multiplication is libgcc's __muldi3 (windowed C ABI: pairs a10:a11, a12:a13 -> a10:a11).

    .section .bss.silica_rt_ordering, "aw", @nobits
    .balign 8
silica_rt_ordering_env_next:
    .space  8
    .global silica_rt_canonical_arena_table   // read by rt_heap.S: region_destroy leaves an arena alone
silica_rt_canonical_arena_table:        // 512 x (key: 8, region: 8)
    .space  8192
silica_rt_canonical_arena_count:
    .space  8

    .section .text.silica_rt_ordering, "ax"
    .literal_position

    .align  4
    .global silica_rt_ordering_env_fresh
    .type   silica_rt_ordering_env_fresh, @function
silica_rt_ordering_env_fresh:
    entry   a1, 32
    movi    a8, silica_rt_ordering_env_next
    l32i    a2, a8, 0
    l32i    a3, a8, 4
    addi    a9, a2, 1
    s32i    a9, a8, 0
    movi    a10, 0
    saltu   a10, a9, a2           // carry
    add     a10, a3, a10
    s32i    a10, a8, 4
    or      a9, a2, a3
    bnez    a9, 1f
    movi    a2, 1                 // never 0
1:  retw
    .size   silica_rt_ordering_env_fresh, . - silica_rt_ordering_env_fresh

    .align  4
    .global silica_rt_ordering_identity_make
    .type   silica_rt_ordering_identity_make, @function
silica_rt_ordering_identity_make:
    entry   a1, 32
    xor     a3, a3, a4            // code ^ (env << 32): only the high word changes
    mov     a10, a4               // env * K1
    mov     a11, a5
    movi    a12, 0x7f4a7c15
    movi    a13, 0x9e379b97
    call8   __muldi3
    xor     a2, a2, a10
    xor     a3, a3, a11
    retw
    .size   silica_rt_ordering_identity_make, . - silica_rt_ordering_identity_make

    .align  4
    .global silica_rt_ordering_identity_same
    .global silica_rt_canonical_arena_same
    .type   silica_rt_ordering_identity_same, @function
silica_rt_ordering_identity_same:
silica_rt_canonical_arena_same:
    entry   a1, 32
    xor     a2, a2, a4
    xor     a3, a3, a5
    or      a2, a2, a3
    movi    a3, 0
    movi    a8, 1
    moveqz  a3, a8, a2            // equal when no bit differs
    mov     a2, a3
    movi    a3, 0
    retw
    .size   silica_rt_ordering_identity_same, . - silica_rt_ordering_identity_same

    .align  4
    .global silica_rt_ordering_bundle_make
    .type   silica_rt_ordering_bundle_make, @function
silica_rt_ordering_bundle_make:
    entry   a1, 32
    mov     a10, a4               // orient * K2
    mov     a11, a5
    movi    a12, 0x27220a95
    movi    a13, 0x517cc1b7
    call8   __muldi3
    xor     a2, a2, a10
    xor     a3, a3, a11
    movi    a8, 0x7fffffff
    and     a3, a3, a8
    retw
    .size   silica_rt_ordering_bundle_make, . - silica_rt_ordering_bundle_make

// key in a2 (low word; keys are non-zero). Slot = key mod 512, linear probing over at most 512
// entries; an empty slot inserts a fresh 4128-byte region block. A zero key or a full table is a
// runtime abort (banner + status 71), with the same reasons as on the host.
//
// The table is shared by both cores (design region_memory_safety_design.md §9.4, H1). A probe
// reads keys without a lock; an insert happens under silica_rt_region_lock (rt_heap.S, the word
// region growth also takes), which stores the region first and the key last with memw between, so
// a probe that sees the key sees the region. A core that found an empty slot takes the lock and
// probes again from the start (a11 = 1 while it holds the lock): the other core may have inserted
// the same key in between, and the table changes only under the lock.
    .align  4
    .global silica_rt_canonical_arena_lookup
    .type   silica_rt_canonical_arena_lookup, @function
silica_rt_canonical_arena_lookup:
    entry   a1, 32
    beqz    a2, 8f
    movi    a11, 0                // 1 once this call holds silica_rt_region_lock
7:  movi    a3, silica_rt_canonical_arena_table
    extui   a4, a2, 0, 9          // slot
    movi    a5, 0                 // probes
1:  movi    a8, 512
    bgeu    a5, a8, 9f
    slli    a6, a4, 4
    add     a6, a3, a6            // entry address
    l32i    a7, a6, 0
    beqz    a7, 3f                // empty
    bne     a7, a2, 2f
    l32i    a8, a6, 4             // same key (both words)
    beqz    a8, 4f
2:  addi    a4, a4, 1
    extui   a4, a4, 0, 9
    addi    a5, a5, 1
    j       1b
3:  bnez    a11, 5f               // under the lock already: insert here
    movi    a8, silica_rt_region_lock
6:  movi    a9, 0
    wsr     a9, scompare1
    movi    a9, 1
    s32c1i  a9, a8, 0
    bnez    a9, 6b
    movi    a11, 1
    j       7b                    // probe again, now under the lock
5:  movi    a10, 4128
    call8   silica_rt_alloc
    movi    a11, 1                // the call returned a3 = 0 into a11; 5 is reached only under the lock
    addi    a8, a10, 32           // bump
    s32i    a8, a10, 0
    movi    a9, 4128
    add     a9, a10, a9           // end, and the block's own data end
    s32i    a9, a10, 8
    s32i    a9, a10, 24
    s32i    a10, a6, 8            // region first
    memw
    s32i    a2, a6, 0             // key last (high word 0)
    movi    a8, silica_rt_canonical_arena_count
    l32i    a9, a8, 0
    addi    a9, a9, 1
    s32i    a9, a8, 0
4:  l32i    a2, a6, 8
    movi    a3, 0
    beqz    a11, 10f
    memw
    movi    a8, silica_rt_region_lock
    s32i    a3, a8, 0
    memw
10: retw
8:  call8   silica_rt_abort_arena_key
9:  call8   silica_rt_abort_arena_full
    retw
    .size   silica_rt_canonical_arena_lookup, . - silica_rt_canonical_arena_lookup

// --- checked int64 ---------------------------------------------------------------------------
// The sum overflows when both operands have the same sign and the result's sign differs.
    .align  4
    .global silica_rt_checked_i64_add
    .type   silica_rt_checked_i64_add, @function
silica_rt_checked_i64_add:
    entry   a1, 32
    add     a8, a2, a4            // low
    saltu   a9, a8, a2            // carry
    add     a10, a3, a5
    add     a10, a10, a9          // high
    xor     a11, a3, a5           // sign(a) == sign(b) ?
    xor     a12, a10, a3          // sign(sum) != sign(a) ?
    mov     a4, a8
    mov     a5, a10
    movi    a2, 1
    movi    a3, 0
    bltz    a11, 1f
    bgez    a12, 1f
    movi    a2, 0                 // overflow: not ok, value 0
    movi    a4, 0
    movi    a5, 0
1:  retw
    .size   silica_rt_checked_i64_add, . - silica_rt_checked_i64_add

    .align  4
    .global silica_rt_checked_i64_add1
    .type   silica_rt_checked_i64_add1, @function
silica_rt_checked_i64_add1:
    entry   a1, 32
    movi    a4, 1
    movi    a5, 0
    mov     a10, a2
    mov     a11, a3
    mov     a12, a4
    mov     a13, a5
    call8   silica_rt_checked_i64_add
    mov     a2, a10
    mov     a3, a11
    mov     a4, a12               // the callee's a4:a5 is our a12:a13 after the call
    mov     a5, a13
    retw
    .size   silica_rt_checked_i64_add1, . - silica_rt_checked_i64_add1

// Product via __muldi3; it fits when a == 0, or b == 0, or product / a == b -- except -1 * INT64_MIN,
// whose wrapped quotient passes that check (the host reports it as fitting; here it is an overflow,
// which is the mathematically right answer). Frame 48: [0, 16) the product.
    .align  4
    .global silica_rt_checked_i64_mul
    .type   silica_rt_checked_i64_mul, @function
silica_rt_checked_i64_mul:
    entry   a1, 48
    mov     a10, a2
    mov     a11, a3
    mov     a12, a4
    mov     a13, a5
    call8   __muldi3
    s32i    a10, a1, 0
    s32i    a11, a1, 4
    or      a8, a2, a3
    beqz    a8, 8f                // a == 0
    or      a8, a4, a5
    beqz    a8, 8f                // b == 0
    // a == -1 and b == INT64_MIN (or the other way round): the only wrap that divides back cleanly
    movi    a8, -1
    bne     a2, a8, 1f
    bne     a3, a8, 1f
    bnez    a4, 1f
    movi    a9, 0x80000000
    beq     a5, a9, 9f
1:  bne     a4, a8, 2f
    bne     a5, a8, 2f
    bnez    a2, 2f
    movi    a9, 0x80000000
    beq     a3, a9, 9f
2:  l32i    a10, a1, 0            // product / a == b ?
    l32i    a11, a1, 4
    mov     a12, a2
    mov     a13, a3
    call8   __divdi3
    bne     a10, a4, 9f
    bne     a11, a5, 9f
8:  l32i    a4, a1, 0
    l32i    a5, a1, 4
    movi    a2, 1
    movi    a3, 0
    retw
9:  movi    a4, 0                 // overflow: not ok, value 0
    movi    a5, 0
    movi    a2, 0
    movi    a3, 0
    retw
    .size   silica_rt_checked_i64_mul, . - silica_rt_checked_i64_mul
