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
    .align  4
    .global spike_co_start
    .type   spike_co_start, @function
spike_co_start:
    entry   a1, 48
    call8   xthal_window_spill
    s32i    a0, a2, 0
    s32i    a1, a2, 4
    mov     a1, a3
    mov     a10, a5
    callx8  a4
1:  j       1b
    .size   spike_co_start, . - spike_co_start
