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

// The actor state at a spawn and at a dispatch end (chunk15_stack_memory_design.md §4.3-§4.7, §5.1).
//
// STAGE 1 OF THE PORT: only the scalar and undescribed paths exist here. A state whose root-word
// descriptor is 0 (an int64, an atom, a function value, a bare type parameter) is stored as given,
// which is every state the base trial suite has. The described paths -- the copier that measures a
// value through its descriptors and places it in the state chain, mailbox buffers for composite
// messages, replies placed into the caller's stack, retire and compaction -- are the ESP32-S3 port's
// rt_state.S (1,900 lines) and are not ported yet: each entry below that would need them ends the
// program with the runtime abort "runtime entry not yet ported to STM32-L476RG_raw" (status 71), so
// a program that needs them fails loudly rather than silently corrupting its state.
//
// Entries (Silica pair ABI through ENTRY_SAVE / ENTRY_RET, or AAPCS where rt_actors.S calls them):
//   silica_rt_state_install(r0 = acb, r1:r2 = value, r3 = descriptor or 0)   AAPCS, -> r0 = 0
//   silica_rt_state_dispatch_end(r0 = acb, r1:r2 = the new state)            AAPCS, -> r0:r1 the root
//   silica_rt_message_buffer / message_forward / reply_place / state_retire / state_retain_node /
//   state_area_bytes / compact_state                                        emitted entries: not ported

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

    .section .text.silica_rt_state, "ax", %progbits

    FUNC silica_rt_state_install
    cmp     r3, #0
    beq.w   1f
    cmp     r1, #65536                      // a small word is a scalar, whatever the descriptor says
    blo.w   1f
    push    {lr}
    bl      silica_rt_unsupported
1:  str     r1, [r0, #ACB_STATE]
    str     r2, [r0, #ACB_STATE + 4]
    movw    r0, #0
    bx      lr
    .size   silica_rt_state_install, . - silica_rt_state_install

// The descriptor, the flags, the retain mark and the request are cleared at the end, as the full
// routine does.
    FUNC silica_rt_state_dispatch_end
    ldr     r3, [r0, #ACB_SDESC]
    cmp     r3, #0
    beq.w   1f
    cmp     r1, #65536
    blo.w   1f
    push    {lr}
    bl      silica_rt_unsupported
1:  movw    r3, #0
    str     r3, [r0, #ACB_SDESC]
    str     r3, [r0, #ACB_SDESC + 4]
    str     r3, [r0, #ACB_SFLAGS]
    str     r3, [r0, #ACB_SRETAIN]
    ldr     r3, [r0, #ACB_SPOLICY]
    bic     r3, r3, #0x100
    str     r3, [r0, #ACB_SPOLICY]
    mov     r0, r1
    mov     r1, r2
    bx      lr
    .size   silica_rt_state_dispatch_end, . - silica_rt_state_dispatch_end

// silica_rt_state_chain_free_all(r0 = acb): nothing is held yet on this port.
    FUNC silica_rt_state_chain_free_all
    bx      lr
    .size   silica_rt_state_chain_free_all, . - silica_rt_state_chain_free_all

// Emitted entries of the copier, not ported.
.macro UNPORTED name
    FUNC \name
    bl      silica_rt_unsupported
    .size   \name, . - \name
.endm
    UNPORTED silica_rt_message_buffer
    UNPORTED silica_rt_message_forward
    UNPORTED silica_rt_reply_place
    UNPORTED silica_rt_state_retire
    UNPORTED silica_rt_state_retain_node
    UNPORTED silica_rt_compact_state
    UNPORTED silica_rt_frame_measure
    UNPORTED silica_rt_frame_copy

// state_area_bytes() -> X0: 0 (no state chain exists yet).
    FUNC silica_rt_state_area_bytes
    ENTRY_SAVE
    movw    r0, #0
    movw    r1, #0
    ENTRY_RET_X0
    .size   silica_rt_state_area_bytes, . - silica_rt_state_area_bytes
