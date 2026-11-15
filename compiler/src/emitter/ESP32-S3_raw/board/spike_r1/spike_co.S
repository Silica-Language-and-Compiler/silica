/*
   Copyright 2026 COPYRIGHT-HOLDER-PLACEHOLDER (to be decided before this is merged)

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

// Route R1 spike, step 3 (transport_ble_plan.md stage 12): two lines of control on one core without an
// operating system. spike_co_start runs fn(arg) on a stack of its own and spike_co_switch passes control
// between the two; each saves its caller in two words (return address, stack pointer) after spilling the
// register windows to the stack, and the return through the other's words takes the window underflow
// path, which reloads that caller's registers from its own stack.

    .section .text.spike_co, "ax"
    .literal_position

// void spike_co_switch(uint32_t save[2], const uint32_t load[2])
    .align  4
    .global spike_co_switch
    .type   spike_co_switch, @function
spike_co_switch:
    entry   a1, 48
    call8   xthal_window_spill
    s32i    a0, a2, 0
    s32i    a1, a2, 4
    l32i    a0, a3, 0
    l32i    a1, a3, 4
    retw
    .size   spike_co_switch, . - spike_co_switch

// void spike_co_start(uint32_t save[2], uint32_t *stack_top, void (*fn)(void *), void *arg): fn never returns
// stack_top has 16 bytes under it and 48 above it that belong to the new stack's block
    .align  4
    .global spike_co_start
    .type   spike_co_start, @function
spike_co_start:
    entry   a1, 48
    call8   xthal_window_spill
    s32i    a0, a2, 0
    s32i    a1, a2, 4
    // When this frame's window is spilled, the overflow path stores a4 to a7 at 32 to 20 bytes under
    // "the caller's stack pointer", which it reads from 12 bytes under this frame's. This frame has no
    // caller on the new stack: name a place 32 bytes above the top, inside the block, so the store
    // lands at the top's first 16 bytes. Left as found in the block it is a store to anywhere.
    addi    a8, a3, 32
    addi    a9, a3, -12
    s32i    a8, a9, 0
    mov     a1, a3
    mov     a10, a5
    callx8  a4
1:  j       1b
    .size   spike_co_start, . - spike_co_start
