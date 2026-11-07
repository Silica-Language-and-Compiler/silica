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

// Foreign (C) calls for the bare-metal ESP32-S3 runtime (spec §20.4; porting_for_os_free_targets.md §9.1;
// chunk15_stack_memory_design.md §7; the emitter side is terms/ffi_foreign.silica, which documents the
// CALL BLOCK every foreign call goes through).
//
// The C side is compiled by the same xtensa-esp32s3-elf GCC that assembles this file, so both sides use
// the windowed ABI: a2-a7 carry the arguments (the caller's a10-a15), 64-bit values in even-aligned pairs,
// a2-a5 the result, a struct larger than 16 bytes comes back through a hidden pointer the caller passes as
// the first argument. Emitted code lays the C argument words out in the call block and calls here.
//
//   silica_rt_ffi_call()         VRG_ARG = the call block: [+0, +24) the six argument words, [+24] the C
//                                function, [+28] the result mode (1: the a2-a5 of a struct result are
//                                stored at [+32, +48)). Calls the C function; a2:a3 = its a2:a3.
//                                In an actor the call runs on a machine-stack chunk of the actor's own
//                                chain with _silica_ffi_stack_size bytes free under it: this routine
//                                takes the chunk exactly as an emitted prologue grows (rt_actors.S
//                                silica_rt_stack_grow, the MOVSP protocol of the "Growable stacks" block),
//                                parks its empty frame under the limit, moves to the chunk's top and returns
//                                through silica_rt_chunk_return, which puts the chunk below back. The
//                                foreign frames therefore never share a chunk with the Silica frames, a C
//                                stack overflow hits the chunk's guard band (the debug exception every
//                                overflow raises), and the chunk is released by the actor's stack policy
//                                like any other. In main, whose stacks are fixed, the call runs on them.
//                                For the call this core's VRG_FFI word is 1: a CPU exception raised
//                                meanwhile ends the actor with failure_reason :foreign_fault, tag 5
//                                (rt_actors.S silica_rt_actor_fault_hook), the board's form of the hosted
//                                guarded region: no setjmp, no signal (porting §9.1 rule 2). A foreign
//                                fault in main is the fatal fault report, status 70, as on a host.
//   silica_rt_ffi_string_in(s)   a Silica string (0 = empty) -> a2 = a block of the running frame holding
//                                its bytes and a NUL (a frame allocation, popped with the frame: FFI
//                                wrapper spec §6.1), a3 = 0, a4:a5 = the byte count. The emitter reads
//                                X0 = the pointer, X1 = the length: the four result words of the ABI.
//   silica_rt_ffi_string_out(p, tag_off, ptr_off, len_off)
//                                p = the struct a wrapper returned (the call block's area), the offsets
//                                of its tag, pointer and length fields (tag_off -1: no tag) -> a2 = a fresh
//                                frame string holding the pointed-to bytes; the shared empty string for a
//                                nonzero tag or a null pointer. The wrapper's span is not freed: it is the
//                                wrapper's (static or wrapper-owned) memory, valid until the wrapper's next
//                                call; nothing here touches the heap.
//   memcpy, memmove, memset, memcmp, strlen
//                                the memory functions the board pack declares for wrappers (porting §9.1
//                                rule 1): GCC emits calls to them for struct copies and clears even under
//                                -ffreestanding, and the image links no C library. Byte loops; a wrapper
//                                that needs speed brings its own.
//
// Frame depth: silica_rt_ffi_call's own chain on the caller's chunk is its frame, silica_rt_current and
// the parked silica_rt_stack_grow chain, which the emitted prologues already charge to the runtime reserve
// (tools/main_stack_bound.py); the foreign frames run on the FFI chunk and are not charged. The declared
// bound covers the frame and silica_rt_current.

#define VRG_MLIMIT       116
#define VRG_ARG          136
#define VRG_FFI          148
#define ACB_KIND         19

    .text

    .set    silica_rt_ffi_call__stack_bound, 80
    .align  4
    .global silica_rt_ffi_call
    .type   silica_rt_ffi_call, @function
silica_rt_ffi_call:
    entry   a1, 48
    rur     a8, threadptr
    l32i    a2, a8, VRG_ARG             // a2 = the call block (kept in this window across the moves)
    call8   silica_rt_current
    l8ui    a3, a10, ACB_KIND
    bnez    a3, 5f                      // main: fixed stacks, the call runs where it is
    // An actor: the foreign frames get a chunk of their own. The frame holds nothing, so it parks 32
    // bytes under the limit (the caller's a1 is at or above it), asks for a chunk with the FFI stack
    // plus this frame above its limit, and moves to the chunk's top; a0 becomes silica_rt_chunk_return.
    // Both MOVSPs run with a windowed return address in a0 (the alloca exception reads the call size
    // from it; memory note "MOVSP/alloca a0 trap").
    rur     a8, threadptr
    l32i    a8, a8, VRG_MLIMIT
    addi    a8, a8, -32
    movsp   a1, a8
    movi    a10, _silica_ffi_stack_size
    addi    a10, a10, 48
    mov     a11, a0
    call8   silica_rt_stack_grow        // -> a10 = the frame's a1 at top - (size + 48), a11 = its a0
    mov     a0, a11
    movi    a8, _silica_ffi_stack_size
    add     a10, a10, a8                // this frame at the chunk's top: the FFI stack lies below it
    movsp   a1, a10
5:  rur     a8, threadptr
    movi    a9, 1
    s32i    a9, a8, VRG_FFI             // in foreign code: a fault now is :foreign_fault
    l32i    a10, a2, 0
    l32i    a11, a2, 4
    l32i    a12, a2, 8
    l32i    a13, a2, 12
    l32i    a14, a2, 16
    l32i    a15, a2, 20
    l32i    a8, a2, 24
    callx8  a8
    rur     a8, threadptr
    movi    a9, 0
    s32i    a9, a8, VRG_FFI
    l32i    a9, a2, 28
    beqz    a9, 6f
    addi    a9, a9, -1
    bnez    a9, 6f                      // mode 1: a struct of up to 16 bytes came back in a2-a5
    s32i    a10, a2, 32
    s32i    a11, a2, 36
    s32i    a12, a2, 40
    s32i    a13, a2, 44
6:  mov     a2, a10
    mov     a3, a11
    retw                                // to silica_rt_chunk_return in an actor: the chunk below returns
    .size   silica_rt_ffi_call, . - silica_rt_ffi_call

// silica_rt_ffi_string_in(s): see the top. A handle whose tag is not -1 is not a string (rt_string.S).
    .align  4
    .global silica_rt_ffi_string_in
    .type   silica_rt_ffi_string_in, @function
silica_rt_ffi_string_in:
    entry   a1, 32
    movi    a4, 0                       // byte count
    movi    a5, 0                       // source bytes
    beqz    a2, 1f
    l32i    a3, a2, 0
    addi    a3, a3, 1
    bnez    a3, 8f
    l32i    a5, a2, 8
    l32i    a4, a2, 16
1:  addi    a10, a4, 1                  // the bytes and a NUL (silica_rt_frame_alloc rounds to 16 and zeroes)
    call8   silica_rt_frame_alloc
    mov     a6, a10                     // the block
    mov     a7, a10
    mov     a8, a4
2:  beqz    a8, 3f
    l8ui    a9, a5, 0
    s8i     a9, a7, 0
    addi    a5, a5, 1
    addi    a7, a7, 1
    addi    a8, a8, -1
    j       2b
3:  mov     a2, a6
    movi    a3, 0
    movi    a5, 0                       // a4 = the count, a5 = its high word
    retw
8:  call8   silica_rt_abort_not_a_string
9:  j       9b
    .size   silica_rt_ffi_string_in, . - silica_rt_ffi_string_in

// silica_rt_ffi_string_out(p, tag_off, ptr_off, len_off): see the top. a2 = p, a4 = tag_off, a5 = ptr_off,
// a6 = len_off (each a 32-bit value in its pair's low word).
    .align  4
    .global silica_rt_ffi_string_out
    .type   silica_rt_ffi_string_out, @function
silica_rt_ffi_string_out:
    entry   a1, 32
    bltz    a4, 1f                      // no tag field
    add     a8, a2, a4
    l32i    a9, a8, 0                   // the tag's low word; a 64-bit tag's high word too
    bnez    a9, 8f
    l32i    a9, a8, 4
    bnez    a9, 8f
1:  add     a8, a2, a5
    l32i    a10, a8, 0                  // the span
    beqz    a10, 8f
    movi    a11, 0
    add     a8, a2, a6
    l32i    a12, a8, 0                  // its byte count (the low word)
    movi    a13, 0
    call8   silica_rt_string_from_bytes // a fresh frame string
    mov     a2, a10
    mov     a3, a11
    retw
8:  movi    a2, silica_rt_empty_string
    movi    a3, 0
    retw
    .size   silica_rt_ffi_string_out, . - silica_rt_ffi_string_out

// ---------------------------------------------------------------------------------------------
// The C memory functions (windowed ABI, as GCC calls them).

    .align  4
    .global memcpy
    .type   memcpy, @function
memcpy:                                 // (dst, src, n) -> dst
    entry   a1, 32
    mov     a5, a2
1:  beqz    a4, 2f
    l8ui    a8, a3, 0
    s8i     a8, a5, 0
    addi    a3, a3, 1
    addi    a5, a5, 1
    addi    a4, a4, -1
    j       1b
2:  retw
    .size   memcpy, . - memcpy

    .align  4
    .global memmove
    .type   memmove, @function
memmove:                                // (dst, src, n) -> dst; overlap-safe
    entry   a1, 32
    bgeu    a3, a2, 1f                  // src >= dst: forward copy
    add     a5, a2, a4                  // src < dst: copy from the end
    add     a6, a3, a4
3:  beqz    a4, 4f
    addi    a5, a5, -1
    addi    a6, a6, -1
    l8ui    a8, a6, 0
    s8i     a8, a5, 0
    addi    a4, a4, -1
    j       3b
1:  mov     a5, a2
2:  beqz    a4, 4f
    l8ui    a8, a3, 0
    s8i     a8, a5, 0
    addi    a3, a3, 1
    addi    a5, a5, 1
    addi    a4, a4, -1
    j       2b
4:  retw
    .size   memmove, . - memmove

    .align  4
    .global memset
    .type   memset, @function
memset:                                 // (dst, c, n) -> dst
    entry   a1, 32
    mov     a5, a2
1:  beqz    a4, 2f
    s8i     a3, a5, 0
    addi    a5, a5, 1
    addi    a4, a4, -1
    j       1b
2:  retw
    .size   memset, . - memset

    .align  4
    .global memcmp
    .type   memcmp, @function
memcmp:                                 // (p, q, n) -> <0, 0, >0 (the first differing bytes, unsigned)
    entry   a1, 32
1:  beqz    a4, 3f
    l8ui    a8, a2, 0
    l8ui    a9, a3, 0
    bne     a8, a9, 2f
    addi    a2, a2, 1
    addi    a3, a3, 1
    addi    a4, a4, -1
    j       1b
2:  sub     a2, a8, a9
    retw
3:  movi    a2, 0
    retw
    .size   memcmp, . - memcmp

    .align  4
    .global strlen
    .type   strlen, @function
strlen:                                 // (s) -> the bytes before the NUL
    entry   a1, 32
    mov     a3, a2
1:  l8ui    a8, a3, 0
    beqz    a8, 2f
    addi    a3, a3, 1
    j       1b
2:  sub     a2, a3, a2
    retw
    .size   strlen, . - strlen
