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

// Ordering identity for the bare-metal STM32L476RG runtime: the Layer 1 section 7 routines the
// macOS emitter bundles (terms/ordering_identity_runtime_asm.silica), with the same values as the
// ESP32-S3 runtime's rt_ordering.S. X0 = r0:r1, X1 = r2:r3, the result in X0 (ENTRY_RET_X0).
//
//   silica_rt_ordering_env_fresh()              -> fresh non-zero environment instance id
//   silica_rt_ordering_identity_make(code, env) -> token = (code ^ env << 32) ^ env * K1
//   silica_rt_ordering_identity_same(a, b)      -> 0/1
//   silica_rt_ordering_bundle_make(fn, orient)  -> (fn ^ orient * K2) & 0x7fff_ffff_ffff_ffff
//   K1 = 0x9e379b977f4a7c15, K2 = 0x517cc1b727220a95

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

#include "rt_defs.h"

    .section .bss.silica_rt_ordering, "aw", %nobits
    .balign 8
    .global silica_rt_ordering_env_next
silica_rt_ordering_env_next:
    .space  8

    .section .text.silica_rt_ordering, "ax", %progbits

// The counter is incremented first, so the first id is 1 and no id is 0.
    FUNC silica_rt_ordering_env_fresh
    ENTRY_SAVE
    MOV32   r4, silica_rt_ordering_env_next
    ldr     r0, [r4, #0]
    ldr     r1, [r4, #4]
    adds    r0, r0, #1
    adc     r1, r1, #0
    str     r0, [r4, #0]
    str     r1, [r4, #4]
    ENTRY_RET_X0
    .size   silica_rt_ordering_env_fresh, . - silica_rt_ordering_env_fresh

// r0:r1 * (r2 = klo, r3 = khi) low 64 bits -> r4:r5, from r6:r7 (the multiplicand) and r2:r3.
    FUNC silica_rt_ordering_identity_make
    ENTRY_SAVE
    eor     r1, r1, r2                      // code ^ (env << 32): only the high word changes
    mov     r6, r2                          // env * K1 (low 64 bits)
    mov     r7, r3
    MOV32   r2, 0x7f4a7c15
    MOV32   r3, 0x9e379b97
    umull   r4, r5, r6, r2                  // lo * klo
    mla     r5, r6, r3, r5                  // + lo * khi << 32
    mla     r5, r7, r2, r5                  // + hi * klo << 32
    eor     r0, r0, r4
    eor     r1, r1, r5
    ENTRY_RET_X0
    .size   silica_rt_ordering_identity_make, . - silica_rt_ordering_identity_make

    FUNC silica_rt_ordering_identity_same
    ENTRY_SAVE
    eor     r0, r0, r2
    eor     r1, r1, r3
    orrs    r0, r0, r1
    ite     eq
    moveq   r0, #1
    movne   r0, #0
    movs    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_ordering_identity_same, . - silica_rt_ordering_identity_same

    FUNC silica_rt_ordering_bundle_make
    ENTRY_SAVE
    mov     r6, r2                          // orient * K2 (low 64 bits)
    mov     r7, r3
    MOV32   r2, 0x27220a95
    MOV32   r3, 0x517cc1b7
    umull   r4, r5, r6, r2
    mla     r5, r6, r3, r5
    mla     r5, r7, r2, r5
    eor     r0, r0, r4
    eor     r1, r1, r5
    bic     r1, r1, #0x80000000
    ENTRY_RET_X0
    .size   silica_rt_ordering_bundle_make, . - silica_rt_ordering_bundle_make
