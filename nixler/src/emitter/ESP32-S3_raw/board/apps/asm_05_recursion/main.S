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

// Bring-up app 05: the register window under deep recursion. 1000-deep CALL8 recursion forces a
// window overflow on almost every call and an underflow on every return, so it checks the vectors
// in rt_vectors.S and the frame contract the emitter will rely on. The 64-bit variant adds with
// carry across a register pair (sum of 1000 x 0xFFFFFFFF), the idiom emitted code uses for int64.
// main also parks sentinels in a2..a7 across both recursions and checks them afterwards.
// Expected console: "sum 500500", "sum64 hi 999 lo 4294966296", "windows ok", status 0.

#define DEPTH 1000

    .section .text.main, "ax"
    .literal_position
    .align  4

    .align  4
    .type   rec_sum, @function
rec_sum:                          // n -> n + (n-1) + ... + 0
    entry   a1, 32
    beqz    a2, 1f
    addi    a10, a2, -1
    call8   rec_sum
    add     a2, a2, a10
1:  retw
    .size   rec_sum, . - rec_sum

    .align  4
    .type   rec_sum64, @function
rec_sum64:                        // n -> n * 0xFFFFFFFF as an int64 pair (a2 lo, a3 hi)
    entry   a1, 32
    beqz    a2, 1f
    addi    a10, a2, -1
    call8   rec_sum64             // a10:a11 = sum for n-1
    movi    a4, -1                // 0xFFFFFFFF
    add     a2, a10, a4
    saltu   a5, a2, a4            // carry out of the low word
    add     a3, a11, a5
    retw
1:  movi    a3, 0
    retw
    .size   rec_sum64, . - rec_sum64

    .align  4
    .global main
    .type   main, @function
main:
    entry   a1, 48                // [sp+0] sum, [sp+4] sum64 lo, [sp+8] sum64 hi; top 32 reserved
    movi    a2, 0x11
    movi    a3, 0x22
    movi    a4, 0x33
    movi    a5, 0x44
    movi    a6, 0x55
    movi    a7, 0x66
    movi    a10, DEPTH
    call8   rec_sum
    s32i    a10, a1, 0
    movi    a10, DEPTH
    call8   rec_sum64
    s32i    a10, a1, 4
    s32i    a11, a1, 8
    movi    a10, msg_sum
    call8   silica_rt_puts
    l32i    a10, a1, 0
    call8   silica_rt_print_u32
    movi    a10, 10
    call8   silica_rt_putc
    movi    a10, msg_hi
    call8   silica_rt_puts
    l32i    a10, a1, 8
    call8   silica_rt_print_u32
    movi    a10, msg_lo
    call8   silica_rt_puts
    l32i    a10, a1, 4
    call8   silica_rt_print_u32
    movi    a10, 10
    call8   silica_rt_putc
    // sentinels
    movi    a8, 0x11
    bne     a2, a8, 9f
    movi    a8, 0x22
    bne     a3, a8, 9f
    movi    a8, 0x33
    bne     a4, a8, 9f
    movi    a8, 0x44
    bne     a5, a8, 9f
    movi    a8, 0x55
    bne     a6, a8, 9f
    movi    a8, 0x66
    bne     a7, a8, 9f
    movi    a10, msg_ok
    call8   silica_rt_puts
    movi    a2, 0
    movi    a3, 0
    retw
9:  movi    a10, msg_bad
    call8   silica_rt_puts
    movi    a2, 1
    movi    a3, 0
    retw
    .size   main, . - main

    .section .rodata.main, "a"
msg_sum: .asciz "sum "
msg_hi:  .asciz "sum64 hi "
msg_lo:  .asciz " lo "
msg_ok:  .asciz "windows ok\n"
msg_bad: .asciz "windows CORRUPT: a2..a7 changed across recursion\n"
