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

// Bring-up app 06: the heap. Allocates 2000 24-byte nodes, checks each comes back zeroed and
// 8-byte aligned, links them into a list (word 0 = value, word 1 = next), walks the list and
// sums the values. Checks rt_heap and that .bss/heap zeroing in rt_start happened.
// Expected console: "heap used 64000" (2000 x (24 + the 8-byte block header of rt_heap.S)),
// "list sum 1999000", status 0 (1 on a bad allocation).

#define NODES 2000

    .section .text.main, "ax"
    .literal_position
    .align  4
    .global main
    .type   main, @function
main:
    entry   a1, 32
    movi    a2, 0                 // a2 = list head
    movi    a3, 0                 // a3 = i
    movi    a6, 0                 // a6 = bad allocations
1:  movi    a10, 24
    call8   silica_rt_alloc
    extui   a8, a10, 0, 3
    bnez    a8, 2f                // misaligned
    l32i    a8, a10, 0
    bnez    a8, 2f                // not zeroed
    l32i    a8, a10, 20
    beqz    a8, 3f
2:  addi    a6, a6, 1
3:  s32i    a3, a10, 0
    s32i    a2, a10, 4
    mov     a2, a10
    addi    a3, a3, 1
    movi    a8, NODES
    blt     a3, a8, 1b
    movi    a10, msg_used
    call8   silica_rt_puts
    call8   silica_rt_heap_used
    call8   silica_rt_print_u32
    movi    a10, 10
    call8   silica_rt_putc
    movi    a4, 0                 // a4 = sum
4:  beqz    a2, 5f
    l32i    a8, a2, 0
    add     a4, a4, a8
    l32i    a2, a2, 4
    j       4b
5:  movi    a10, msg_sum
    call8   silica_rt_puts
    mov     a10, a4
    call8   silica_rt_print_u32
    movi    a10, 10
    call8   silica_rt_putc
    movi    a2, 0
    movi    a3, 0
    beqz    a6, 6f
    movi    a10, msg_bad
    call8   silica_rt_puts
    movi    a2, 1
6:  retw
    .size   main, . - main

    .section .rodata.main, "a"
msg_used: .asciz "heap used "
msg_sum:  .asciz "list sum "
msg_bad:  .asciz "bad allocation (misaligned or not zeroed)\n"
