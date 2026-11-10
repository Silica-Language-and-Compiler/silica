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

// Foreign (C) calls for the bare-metal STM32L476RG runtime (spec §20.4; porting_for_os_free_targets.md
// §9.1; chunk15_stack_memory_design.md §7): the ESP32-S3 port's rt_ffi.S for Thumb-2 and the AAPCS. The
// emitter side is terms/ffi_foreign.silica, which documents the CALL BLOCK every foreign call goes
// through.
//
// The C side is compiled by the same arm-none-eabi GCC that assembles this file (build_image.sh: the
// image is built -mfloat-abi=softfp, so a C float or double crosses in core registers exactly as the
// call block lays it out, and -ffixed-r9, so C never touches TP). AAPCS: r0-r3 carry the first four
// argument words (a 64-bit value in an even pair), the rest go on the stack 8-byte aligned; the result
// is r0 (r0:r1 for 64 bits); a composite result larger than 4 bytes comes back through memory whose
// address the caller passes in r0 (the call block's mode 2: emitted code puts the struct area's address
// in word 0 and lays the arguments from word 1).
//
//   silica_rt_ffi_call()         VRG_ARG = the call block: [+0, +24) the six argument words in C order
//                                (words 0-3 go to r0-r3, words 4-5 to the outgoing stack), [+24] the C
//                                function (Thumb bit set by the MOVW/MOVT relocation), [+28] the result
//                                mode (1: r0-r3 are stored at [+32, +48); AAPCS returns only a composite of
//                                up to 4 bytes in r0). Calls the C function; X0 = r0:r1 = its result.
//                                Every other register is kept (r2-r8, r12; r10, r11, lr clobbered: the
//                                runtime entry convention, rt_defs.h).
//                                In an actor the call runs on a machine-stack chunk of the actor's own
//                                chain with _silica_ffi_stack_size bytes free above the chunk's limit: this
//                                routine takes the chunk exactly as an emitted prologue grows
//                                (rt_actors.S silica_rt_stack_grow), moves sp to the chunk's top and
//                                returns through silica_rt_chunk_return, which puts the chunk below back.
//                                The foreign frames therefore never share a chunk with the Silica frames;
//                                the chunk is released by the actor's stack policy like any other, and
//                                comes from the SRAM2 chunk arena first (rt_heap.S), else SRAM1. For the
//                                call, MPU region 1 makes a 32-byte window of the chunk's band (below the
//                                limit, the depth reserve and the headroom) no-access, so a C stack that
//                                runs through all of them faults (MemManage) instead of writing the heap
//                                block below. In main, whose stacks are fixed (6 KiB machine stack at the
//                                top of SRAM1), the call runs on them, unguarded.
//                                For the call VRG_FFI is 1: a CPU exception raised meanwhile in an actor
//                                ends the actor with failure_reason :foreign_fault, tag 5 (rt_failure.S
//                                silica_rt_actor_fault_hook), the board's form of the hosted guarded
//                                region: no setjmp, no signal (porting §9.1 rule 2). A foreign fault in
//                                main is the fatal fault report, status 70, as on a host.
//   silica_rt_ffi_string_in(X0 = s)
//                                a Silica string (0 = empty) -> X0 = a block of the running frame holding
//                                its bytes and a NUL (a frame allocation, popped with the frame: FFI
//                                wrapper spec §6.1), X1 = the byte count. r0-r3 are the answer.
//   silica_rt_ffi_string_out(r0 = p, r2 = tag_off, r3 = ptr_off, r4 = len_off)
//                                p = the struct a wrapper returned (the call block's area), the offsets of
//                                its tag, pointer and length fields (tag_off -1: no tag) -> X0 = a fresh
//                                frame string holding the pointed-to bytes; the shared empty string for a
//                                nonzero tag or a null pointer. The wrapper's span is not freed: it is the
//                                wrapper's (static or wrapper-owned) memory, valid until its next call.
// The memory functions a wrapper links against (memcpy, memmove, memset, memcmp, strlen) are in
// rt_support.S.

#include "rt_defs.h"

#define MPU_RNR          0xE000ED98
#define MPU_RBAR         0xE000ED9C
#define MPU_RASR         0xE000EDA0
#define FFI_BAND_RASR    0x10000009     /* XN, AP 000 (no access), SIZE 4 (2^5 = 32 bytes), ENABLE */

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

    .section .text.silica_rt_ffi, "ax", %progbits

    FUNC silica_rt_ffi_call
    push    {r2-r7, r12, lr}                // what the C call clobbers that the entry convention keeps
    ldr     r4, [r9, #VRG_ARG]              // r4 = the call block (callee-saved across the C call)
    movw    r5, #0                          // r5 = silica_rt_chunk_return in an actor, 0 in main
    mov     r6, sp                          // main: the sp to restore
    MOV32   r0, silica_rt_cores
    ldr     r0, [r0, #CORE_CURRENT]
    ldrb    r0, [r0, #ACB_KIND]
    cmp     r0, #KIND_ACTOR
    bne.w   2f
    // An actor: the foreign frames get a chunk of their own. silica_rt_stack_grow takes a chunk with
    // r10 bytes above its limit and answers sp = its top - r10 and r11 = silica_rt_chunk_return; the
    // real return address (label 6) and this sp stay in the chunk header.
    MOV32   r10, _silica_ffi_stack_size
    add     r10, r10, #64
    adr     r11, 6f
    orr     r11, r11, #1
    bl      silica_rt_stack_grow
    mov     r5, r11
    MOV32   r12, _silica_ffi_stack_size
    add     sp, sp, r12                     // sp = the chunk's top - 64: the FFI stack lies below
    // the band guard: MPU region 1 over the 32-byte aligned window inside the chunk's band [+64, +128)
    ldr     r0, [r9, #VRG_MCHUNK]
    ldr     r0, [r0, #CH_BAND]              // the band's address (chunk + 64, 16-aligned)
    add     r0, r0, #31
    bic     r0, r0, #31
    orr     r0, r0, #0x11                   // VALID, region 1
    MOV32   r1, MPU_RBAR
    str     r0, [r1]
    MOV32   r0, FFI_BAND_RASR
    str     r0, [r1, #4]
    dsb     sy
    isb     sy
2:  mov     r0, sp                          // AAPCS: sp 8-byte aligned at the call
    bic     r0, r0, #7
    mov     sp, r0
    movw    r0, #1
    str     r0, [r9, #VRG_FFI]              // in foreign code: a fault now is :foreign_fault
    ldr     r0, [r4, #16]
    ldr     r1, [r4, #20]
    push    {r0, r1}                        // argument words 4 and 5: the outgoing stack
    ldm     r4, {r0-r3}
    ldr     r12, [r4, #24]
    blx     r12
    add     sp, sp, #8
    ldr     r12, [r4, #28]
    cmp     r12, #1
    bne.w   3f
    str     r0, [r4, #32]                   // mode 1: a composite of up to 4 bytes came back in r0
    str     r1, [r4, #36]
    str     r2, [r4, #40]
    str     r3, [r4, #44]
3:  movw    r2, #0
    str     r2, [r9, #VRG_FFI]
    cmp     r5, #0
    beq.w   4f
    MOV32   r2, MPU_RNR                     // the band guard off
    movw    r3, #1
    str     r3, [r2]
    movw    r3, #0
    str     r3, [r2, #8]
    dsb     sy
    isb     sy
    bx      r5                              // silica_rt_chunk_return: the chunk below, this sp, label 6
4:  mov     sp, r6
6:  pop     {r2-r7, r12, pc}
    .size   silica_rt_ffi_call, . - silica_rt_ffi_call

// silica_rt_ffi_string_in(X0 = s): see the top. A handle whose tag is not -1 is not a string.
    FUNC silica_rt_ffi_string_in
    push    {r4-r8, r12, lr}
    movw    r4, #0                          // r4 = the byte count
    movw    r5, #0                          // r5 = the source bytes
    cmp     r0, #0
    beq.w   1f
    ldr     r1, [r0, #0]
    adds    r1, r1, #1
    bne.w   8f
    ldr     r5, [r0, #8]
    ldr     r4, [r0, #16]
1:  add     r0, r4, #1                      // the bytes and a NUL (silica_rt_frame_alloc rounds and zeroes)
    bl      silica_rt_frame_alloc
    mov     r6, r0
    movw    r2, #0
2:  cmp     r2, r4
    bhs.w   3f
    ldrb    r3, [r5, r2]
    strb    r3, [r6, r2]
    add     r2, r2, #1
    b.w     2b
3:  mov     r0, r6
    movw    r1, #0
    mov     r2, r4
    movw    r3, #0
    pop     {r4-r8, r12, pc}
8:  bl      silica_rt_abort_not_a_string
9:  b.w     9b
    .size   silica_rt_ffi_string_in, . - silica_rt_ffi_string_in

// silica_rt_ffi_string_out(r0 = p, r2 = tag_off, r3 = ptr_off, r4 = len_off): see the top.
    FUNC silica_rt_ffi_string_out
    ENTRY_SAVE
    cmp     r2, #0
    blt.w   1f                              // no tag field
    add     r12, r0, r2
    ldr     r1, [r12, #0]                   // the tag's low word; a 64-bit tag's high word too
    cmp     r1, #0
    bne.w   8f
    ldr     r1, [r12, #4]
    cmp     r1, #0
    bne.w   8f
1:  ldr     r1, [r0, r4]                    // the byte count (the low word)
    ldr     r0, [r0, r3]                    // the span
    cmp     r0, #0
    beq.w   8f
    bl      silica_rt_string_from_bytes     // a fresh frame string (the empty string for 0 bytes)
    movw    r1, #0
    ENTRY_RET_X0
8:  MOV32   r0, silica_rt_empty_string
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_ffi_string_out, . - silica_rt_ffi_string_out
