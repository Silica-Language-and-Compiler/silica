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

// Console for the bare-metal STM32L476RG runtime: USART2 on PA2 (TX) / PA3 (RX), alternate function 7,
// the Nucleo's ST-LINK virtual COM port, 115200 8N1 from the 16 MHz HSI (rt_start.S). Output is
// polled (TXE before each byte); there is no FIFO, so a write of n bytes takes n * 87 us.
//
// Entries the emitted code calls (Silica pair ABI: X0 = r0:r1, X1 = r2:r3, X2 = r4:r5; every register
// but r10, r11, lr kept, r0:r1 answered where a result is named):
//   silica_rt_putc(X0 = byte)                     silica_rt_write(X0 = bytes, X1 = count)
//   silica_rt_print_i64(X0) / print_u64(X0)       silica_rt_print_bool(X0) / print_char(X0 = code point)
//   silica_rt_print_string(X0 = string handle)    silica_rt_print_string_stderr(X0): the same console
//   silica_rt_badarith() / silica_rt_case_clause(): runtime aborts (status 71), never return
//   silica_rt_abort_with(X0 = reason text) and the ABORT_ENTRY family: "[silica] abort: <reason> at
//   0x<pc>" as program output, then the exit marker with status 71, then the board-only details.
// Internal (AAPCS): silica_rt_puts(r0 = NUL-terminated), silica_rt_print_u32(r0), silica_rt_print_hex32(r0),
// silica_rt_flush(), silica_rt_console_rx_drain(), silica_rt_console_poll_exit_line() -> r0,
// silica_rt_exit_marker(r0 = status), silica_rt_exit(r0 = status), silica_rt_halt(),
// silica_rt_fatal_report(r0 = cause, r1 = pc, r2 = fault address) (spec §15.4.5.5).

#include "rt_defs.h"

    .syntax unified
    .cpu cortex-m4
    .fpu fpv4-sp-d16
    .thumb

#define USART_ISR_TXE    0x80
#define USART_ISR_TC     0x40
#define USART_ISR_RXNE   0x20
#define USART_CR1_UE     0x1
#define USART_CR1_RE     0x4
#define USART_CR1_TE     0x8
#define BRR_16MHZ_115200 139

    .section .bss.silica_rt_console, "aw", %nobits
    .balign 4
silica_rt_exit_line_state:
    .space  12                              // [0] matched length  [4] line failed  [8] CR pending

    .section .text.silica_rt_console, "ax", %progbits

// silica_rt_console_init(): PA2/PA3 to AF7, USART2 115200 8N1, TX and RX on.
    FUNC silica_rt_console_init
    MOV32   r1, GPIOA_BASE
    ldr     r0, [r1, #GPIO_MODER]
    bic     r0, r0, #0xF0                   // PA2, PA3 mode bits
    orr     r0, r0, #0xA0                   // alternate function
    str     r0, [r1, #GPIO_MODER]
    ldr     r0, [r1, #GPIO_OSPEEDR]
    orr     r0, r0, #0xF0                   // very high speed
    str     r0, [r1, #GPIO_OSPEEDR]
    ldr     r0, [r1, #GPIO_PUPDR]
    bic     r0, r0, #0xF0
    orr     r0, r0, #0x50                   // pull-up on both (an idle line reads high)
    str     r0, [r1, #GPIO_PUPDR]
    ldr     r0, [r1, #GPIO_AFRL]
    bic     r0, r0, #0xFF00                 // AFRL bits 15:8 = PA2, PA3
    orr     r0, r0, #0x7700                 // AF7
    str     r0, [r1, #GPIO_AFRL]
    MOV32   r1, USART2_BASE
    movw    r0, #0
    str     r0, [r1, #USART_CR1]
    movw    r0, #BRR_16MHZ_115200
    str     r0, [r1, #USART_BRR]
    movw    r0, #(USART_CR1_UE | USART_CR1_TE | USART_CR1_RE)
    str     r0, [r1, #USART_CR1]
    bx      lr
    .size   silica_rt_console_init, . - silica_rt_console_init

// silica_rt_putc_raw(r0 = byte): one byte, polled. Clobbers r1, r2.
    LFUNC silica_rt_putc_raw
    MOV32   r1, USART2_BASE
1:  ldr     r2, [r1, #USART_ISR]
    tst     r2, #USART_ISR_TXE
    beq.w   1b
    str     r0, [r1, #USART_TDR]
    bx      lr
    .size   silica_rt_putc_raw, . - silica_rt_putc_raw

// silica_rt_puts(r0 = NUL-terminated text). Clobbers r0-r3.
    FUNC silica_rt_puts
    push    {r4, lr}
    mov     r4, r0
1:  ldrb    r0, [r4], #1
    cmp     r0, #0
    beq.w   2f
    bl      silica_rt_putc_raw
    b.w     1b
2:  pop     {r4, pc}
    .size   silica_rt_puts, . - silica_rt_puts

// silica_rt_write_raw(r0 = bytes, r1 = count). Clobbers r0-r3.
    LFUNC silica_rt_write_raw
    push    {r4, r5, lr}
    mov     r4, r0
    mov     r5, r1
1:  cmp     r5, #0
    beq.w   2f
    ldrb    r0, [r4], #1
    bl      silica_rt_putc_raw
    subs    r5, r5, #1
    b.w     1b
2:  pop     {r4, r5, pc}
    .size   silica_rt_write_raw, . - silica_rt_write_raw

// silica_rt_print_u32(r0): decimal. Clobbers r0-r3.
    FUNC silica_rt_print_u32
    push    {r4, r5, lr}
    sub     sp, sp, #16
    add     r4, sp, #16                     // digits are built downward from the buffer's end
    movw    r5, #10
1:  udiv    r1, r0, r5
    mls     r2, r1, r5, r0
    add     r2, r2, #48
    strb    r2, [r4, #-1]!
    mov     r0, r1
    cmp     r0, #0
    bne.w   1b
    mov     r0, r4
    add     r1, sp, #16
    sub     r1, r1, r4
    bl      silica_rt_write_raw
    add     sp, sp, #16
    pop     {r4, r5, pc}
    .size   silica_rt_print_u32, . - silica_rt_print_u32

// silica_rt_print_u64_raw(r0:r1): decimal, by repeated division by 10 of the 64-bit value.
    LFUNC silica_rt_print_u64_raw
    push    {r4-r7, lr}
    sub     sp, sp, #24
    add     r4, sp, #24
    mov     r6, r0                          // lo
    mov     r7, r1                          // hi
1:  // (hi:lo) / 10: hi part first, remainder carried into the low division in two 16-bit halves
    movw    r5, #10
    udiv    r0, r7, r5                      // qhi
    mls     r1, r0, r5, r7                  // rem of the high word (0..9)
    mov     r7, r0
    // low word with the carried remainder: (rem << 32 | lo) / 10 done as two 16-bit steps
    lsr     r2, r6, #16
    orr     r2, r2, r1, lsl #16             // rem:lo_hi16
    udiv    r3, r2, r5                      // q1
    mls     r1, r3, r5, r2                  // rem
    uxth    r2, r6
    orr     r2, r2, r1, lsl #16             // rem:lo_lo16
    udiv    r0, r2, r5                      // q0
    mls     r1, r0, r5, r2                  // the digit
    orr     r6, r0, r3, lsl #16             // new lo
    add     r1, r1, #48
    strb    r1, [r4, #-1]!
    orrs    r0, r6, r7
    bne.w   1b
    mov     r0, r4
    add     r1, sp, #24
    sub     r1, r1, r4
    bl      silica_rt_write_raw
    add     sp, sp, #24
    pop     {r4-r7, pc}
    .size   silica_rt_print_u64_raw, . - silica_rt_print_u64_raw

// silica_rt_print_hex32(r0): 0x and eight hex digits. Clobbers r0-r3.
    FUNC silica_rt_print_hex32
    push    {r4, r5, lr}
    mov     r4, r0
    movw    r0, #48
    bl      silica_rt_putc_raw
    movw    r0, #120
    bl      silica_rt_putc_raw
    movw    r5, #8
1:  lsr     r0, r4, #28
    cmp     r0, #10
    ite     lo
    addlo   r0, r0, #48
    addhs   r0, r0, #87
    bl      silica_rt_putc_raw
    lsl     r4, r4, #4
    subs    r5, r5, #1
    bne.w   1b
    pop     {r4, r5, pc}
    .size   silica_rt_print_hex32, . - silica_rt_print_hex32

// silica_rt_flush(): wait until the last byte has left the shifter.
    FUNC silica_rt_flush
    MOV32   r1, USART2_BASE
1:  ldr     r2, [r1, #USART_ISR]
    tst     r2, #USART_ISR_TC
    beq.w   1b
    bx      lr
    .size   silica_rt_flush, . - silica_rt_flush

// silica_rt_console_rx_drain(): discard every byte received so far and start a fresh line.
    FUNC silica_rt_console_rx_drain
    MOV32   r1, USART2_BASE
1:  ldr     r2, [r1, #USART_ISR]
    tst     r2, #USART_ISR_RXNE
    beq.w   2f
    ldr     r2, [r1, #USART_RDR]
    b.w     1b
2:  movw    r2, #0x0F                       // clear the error flags (overrun from the loader's bytes)
    str     r2, [r1, #USART_ICR]
    MOV32   r1, silica_rt_exit_line_state
    movw    r2, #0
    str     r2, [r1, #0]
    str     r2, [r1, #4]
    str     r2, [r1, #8]
    bx      lr
    .size   silica_rt_console_rx_drain, . - silica_rt_console_rx_drain

// silica_rt_console_poll_exit_line() -> r0 = 1 when a line reading exactly "exit" has just completed,
// 0 otherwise. Pops what has been received; returns at the newline that completes an "exit" line.
// Clobbers r1-r3, r12.
    FUNC silica_rt_console_poll_exit_line
    push    {r4, r5, lr}
    movw    r0, #0
    MOV32   r1, USART2_BASE
    MOV32   r4, silica_rt_exit_line_state
1:  ldr     r2, [r1, #USART_ISR]
    tst     r2, #USART_ISR_RXNE
    beq.w   9f
    ldr     r2, [r1, #USART_RDR]
    uxtb    r2, r2                          // the byte
    cmp     r2, #10
    beq.w   5f                              // newline: the line is complete
    ldr     r3, [r4, #8]
    cmp     r3, #0
    beq.w   2f
    movw    r3, #1                          // a CR followed by something other than a newline:
    str     r3, [r4, #4]                    // an ordinary byte, so this line is not "exit"
    movw    r3, #0
    str     r3, [r4, #8]
2:  cmp     r2, #13
    bne.w   3f
    movw    r3, #1
    str     r3, [r4, #8]                    // CR: decided by the next byte
    b.w     1b
3:  ldr     r3, [r4, #4]
    cmp     r3, #0
    bne.w   1b                              // this line has already failed
    ldr     r3, [r4, #0]
    cmp     r3, #4
    bhs.w   4f                              // longer than "exit"
    MOV32   r5, silica_rt_exit_word
    ldrb    r5, [r5, r3]
    cmp     r2, r5
    bne.w   4f
    add     r3, r3, #1
    str     r3, [r4, #0]
    b.w     1b
4:  movw    r3, #1
    str     r3, [r4, #4]
    b.w     1b
5:  ldr     r3, [r4, #0]                    // matched length
    ldr     r5, [r4, #4]                    // failed
    movw    r2, #0
    str     r2, [r4, #0]
    str     r2, [r4, #4]
    str     r2, [r4, #8]
    cmp     r5, #0
    bne.w   1b
    cmp     r3, #4
    bne.w   1b
    movw    r0, #1
9:  pop     {r4, r5, pc}
    .size   silica_rt_console_poll_exit_line, . - silica_rt_console_poll_exit_line

// Exit marker: \x02SILICA:EXIT:<status>\x03, status = low byte like a host exit code.
    FUNC silica_rt_exit_marker
    push    {r4, lr}
    uxtb    r4, r0
    MOV32   r0, silica_rt_exit_prefix
    bl      silica_rt_puts
    mov     r0, r4
    bl      silica_rt_print_u32
    movw    r0, #3
    bl      silica_rt_putc_raw
    pop     {r4, pc}
    .size   silica_rt_exit_marker, . - silica_rt_exit_marker

// The end of the program: nothing prints and nothing runs after the exit marker.
    FUNC silica_rt_halt
    bl      silica_rt_flush
    cpsid   i
1:  wfi
    b.w     1b
    .size   silica_rt_halt, . - silica_rt_halt

// silica_rt_exit(r0 = status): the marker, then one diagnostic line outside the program's output
// (run_on_board.py sends it to stderr):
//   [silica] stacks: machine <high-water>/<size> aux <high-water>/<size> heap: in use <U> free <F>
// The high-water mark is the distance from the top to the lowest non-zero word (both stacks start
// zeroed: rt_start.S step 4).
    FUNC silica_rt_exit
    push    {r4, lr}
    bl      silica_rt_exit_marker
    MOV32   r0, silica_rt_stacks_pre
    bl      silica_rt_puts
    MOV32   r0, _silica_heap_end
    MOV32   r1, _silica_stack_top
    bl      silica_rt_stack_high_water
    MOV32   r0, _silica_main_stack_size
    bl      silica_rt_print_u32
    MOV32   r0, silica_rt_stacks_aux
    bl      silica_rt_puts
    MOV32   r0, silica_rt_aux_stack_bottom
    MOV32   r1, silica_rt_aux_stack_top
    bl      silica_rt_stack_high_water
    MOV32   r0, _silica_main_aux_size
    bl      silica_rt_print_u32
    bl      silica_rt_heap_summary          // rt_heap.S: " heap: in use U free F"
    movw    r0, #10
    bl      silica_rt_putc_raw
    bl      silica_rt_halt
    pop     {r4, pc}
    .size   silica_rt_exit, . - silica_rt_exit

// silica_rt_stack_high_water(r0 = bottom, r1 = top): prints "<top - lowest non-zero word>/".
    LFUNC silica_rt_stack_high_water
    push    {r4, lr}
    mov     r2, r0
1:  cmp     r2, r1
    bhs.w   2f
    ldr     r3, [r2]
    cmp     r3, #0
    bne.w   2f
    add     r2, r2, #4
    b.w     1b
2:  sub     r0, r1, r2
    bl      silica_rt_print_u32
    movw    r0, #47
    bl      silica_rt_putc_raw
    pop     {r4, pc}
    .size   silica_rt_stack_high_water, . - silica_rt_stack_high_water

// ---------------------------------------------------------------------------------------------
// Entries the emitted code calls.

    FUNC silica_rt_putc
    ENTRY_SAVE
    bl      silica_rt_putc_raw
    ENTRY_RET
    .size   silica_rt_putc, . - silica_rt_putc

    FUNC silica_rt_write
    ENTRY_SAVE
    mov     r1, r2
    bl      silica_rt_write_raw
    ENTRY_RET
    .size   silica_rt_write, . - silica_rt_write

    FUNC silica_rt_print_u64
    ENTRY_SAVE
    bl      silica_rt_print_u64_raw
    ENTRY_RET
    .size   silica_rt_print_u64, . - silica_rt_print_u64

    FUNC silica_rt_print_i64
    ENTRY_SAVE
    cmp     r1, #0
    bge.w   1f
    push    {r0, r1}
    movw    r0, #45
    bl      silica_rt_putc_raw
    pop     {r0, r1}
    rsbs    r0, r0, #0
    sbc     r1, r1, r1, lsl #1
1:  bl      silica_rt_print_u64_raw
    ENTRY_RET
    .size   silica_rt_print_i64, . - silica_rt_print_i64

    FUNC silica_rt_print_bool
    ENTRY_SAVE
    orrs    r0, r0, r1
    beq.w   1f
    MOV32   r0, silica_rt_true_str
    b.w     2f
1:  MOV32   r0, silica_rt_false_str
2:  bl      silica_rt_puts
    ENTRY_RET
    .size   silica_rt_print_bool, . - silica_rt_print_bool

// print_char(X0 = Unicode scalar): UTF-8 encoded.
    FUNC silica_rt_print_char
    ENTRY_SAVE
    mov     r4, r0
    cmp     r4, #0x80
    bhs.w   1f
    bl      silica_rt_putc_raw
    b.w     9f
1:  cmp     r4, #0x800
    bhs.w   2f
    lsr     r0, r4, #6
    orr     r0, r0, #0xC0
    bl      silica_rt_putc_raw
    b.w     8f
2:  cmp     r4, #0x10000
    bhs.w   3f
    lsr     r0, r4, #12
    orr     r0, r0, #0xE0
    bl      silica_rt_putc_raw
    b.w     7f
3:  lsr     r0, r4, #18
    orr     r0, r0, #0xF0
    bl      silica_rt_putc_raw
    lsr     r0, r4, #12
    and     r0, r0, #0x3F
    orr     r0, r0, #0x80
    bl      silica_rt_putc_raw
7:  lsr     r0, r4, #6
    and     r0, r0, #0x3F
    orr     r0, r0, #0x80
    bl      silica_rt_putc_raw
8:  and     r0, r4, #0x3F
    orr     r0, r0, #0x80
    bl      silica_rt_putc_raw
9:  ENTRY_RET
    .size   silica_rt_print_char, . - silica_rt_print_char

// print_string(X0 = handle): the bytes at [handle + 8] for [handle + 16] bytes. The same console
// serves stderr.
    FUNC silica_rt_print_string
    .thumb_func
    .global silica_rt_print_string_stderr
silica_rt_print_string_stderr:
    ENTRY_SAVE
    cmp     r0, #0
    beq.w   1f
    ldr     r1, [r0, #16]
    ldr     r0, [r0, #8]
    bl      silica_rt_write_raw
1:  ENTRY_RET
    .size   silica_rt_print_string, . - silica_rt_print_string

// ---------------------------------------------------------------------------------------------
// Runtime aborts (spec §15.4.5.5, status 71). Every entry names its reason and lands in
// silica_rt_abort_body with lr still the return address into the site, so the report names the
// call's address. Nothing is allocated, so a heap-exhausted abort is safe. The report runs on the
// fault stack: the context's stack may be the thing that failed.
    FUNC silica_rt_abort_with
    b.w     silica_rt_abort_body            // r0 = the caller's reason text
    .size   silica_rt_abort_with, . - silica_rt_abort_with

.macro ABORT_ENTRY name, reason
    FUNC \name
    MOV32   r0, \reason
    b.w     silica_rt_abort_body
    .size   \name, . - \name
.endm

    ABORT_ENTRY silica_rt_abort, silica_rt_reason_check
    ABORT_ENTRY silica_rt_abort_region_overflow, silica_rt_reason_region_overflow
    ABORT_ENTRY silica_rt_abort_buf_invalid, silica_rt_reason_buf_invalid
    ABORT_ENTRY silica_rt_abort_buf_bounds, silica_rt_reason_buf_bounds
    ABORT_ENTRY silica_rt_abort_list_index, silica_rt_reason_list_index
    ABORT_ENTRY silica_rt_abort_arena_key, silica_rt_reason_arena_key
    ABORT_ENTRY silica_rt_abort_arena_full, silica_rt_reason_arena_full
    ABORT_ENTRY silica_rt_abort_not_a_string, silica_rt_reason_not_a_string
    ABORT_ENTRY silica_rt_abort_heap_exhausted, silica_rt_reason_heap_exhausted
    ABORT_ENTRY silica_rt_abort_ingress_full, silica_rt_reason_ingress_full
    ABORT_ENTRY silica_rt_region_alloc_failed, silica_rt_reason_out_of_memory
    ABORT_ENTRY silica_rt_buf_bounds_failed, silica_rt_reason_buf_bounds
    ABORT_ENTRY silica_rt_buf_invalid_failed, silica_rt_reason_buf_invalid
    ABORT_ENTRY silica_rt_badarith, silica_rt_reason_badarith
    ABORT_ENTRY silica_rt_case_clause, silica_rt_reason_case_clause
    ABORT_ENTRY silica_rt_unsupported, silica_rt_reason_unsupported
    ABORT_ENTRY silica_rt_abort_copier_overrun, silica_rt_reason_copier_overrun

// silica_rt_abort_body(r0 = reason, lr = the site's return address): the report, status 71, halt.
    FUNC silica_rt_abort_body
    cpsid   i
    mov     r4, r0
    sub     r5, lr, #4                      // the bl's own address
    bic     r5, r5, #1
    MOV32   r0, _silica_fault_stack_top
    mov     sp, r0
    MOV32   r0, silica_rt_abort_pre
    bl      silica_rt_puts
    mov     r0, r4
    bl      silica_rt_puts
    MOV32   r0, silica_rt_abort_at
    bl      silica_rt_puts
    mov     r0, r5
    bl      silica_rt_print_hex32
    movw    r0, #10
    bl      silica_rt_putc_raw
    movw    r0, #71
    bl      silica_rt_exit_marker
    MOV32   r0, silica_rt_abort_detail
    bl      silica_rt_puts
    bl      silica_rt_heap_summary
    movw    r0, #10
    bl      silica_rt_putc_raw
    bl      silica_rt_halt
    .size   silica_rt_abort_body, . - silica_rt_abort_body

// silica_rt_fatal_report(r0 = cause, r1 = pc, r2 = fault address or 0): "[silica] fault at 0x<pc>",
// "  addr=0x<a>" only when the cause has one, the exit marker with status 70, then the board-only
// details (cause, pc, address) after the marker, which run_on_board.py sends to stderr.
    FUNC silica_rt_fatal_report
    mov     r4, r0
    mov     r5, r1
    mov     r6, r2
    MOV32   r0, silica_rt_fault_pre
    bl      silica_rt_puts
    mov     r0, r5
    bl      silica_rt_print_hex32
    cmp     r6, #0
    beq.w   1f
    MOV32   r0, silica_rt_fault_addr
    bl      silica_rt_puts
    mov     r0, r6
    bl      silica_rt_print_hex32
1:  movw    r0, #10
    bl      silica_rt_putc_raw
    movw    r0, #70
    bl      silica_rt_exit_marker
    MOV32   r0, silica_rt_fault_cause
    bl      silica_rt_puts
    mov     r0, r4
    bl      silica_rt_print_u32
    MOV32   r0, silica_rt_fault_pc
    bl      silica_rt_puts
    mov     r0, r5
    bl      silica_rt_print_hex32
    MOV32   r0, silica_rt_fault_cfsr
    bl      silica_rt_puts
    MOV32   r0, SCB_CFSR
    ldr     r0, [r0]
    bl      silica_rt_print_hex32
    movw    r0, #10
    bl      silica_rt_putc_raw
    bl      silica_rt_halt
    .size   silica_rt_fatal_report, . - silica_rt_fatal_report

// silica_rt_fatal_overflow(r0 = pc): main's stack limit crossed (rt_actors.S): the fatal report with
// cause 1006, the ESP32-S3 port's stack-guard code, so the trial goldens' folded line matches.
    FUNC silica_rt_fatal_overflow
    mov     r1, r0
    movw    r0, #1006
    movw    r2, #0
    MOV32   r3, _silica_fault_stack_top
    mov     sp, r3
    b.w     silica_rt_fatal_report
    .size   silica_rt_fatal_overflow, . - silica_rt_fatal_overflow

    .ltorg

    .section .rodata.silica_rt_console, "a", %progbits
silica_rt_exit_prefix:
    .byte   0x02
    .asciz  "SILICA:EXIT:"
silica_rt_stacks_pre:
    .asciz  " [silica] stacks: machine "
silica_rt_stacks_aux:
    .asciz  " aux "
    .global silica_rt_exit_word
silica_rt_exit_word:
    .ascii  "exit"
silica_rt_fault_pre:
    .asciz  "[silica] fault at "
silica_rt_fault_addr:
    .asciz  "  addr="
silica_rt_abort_pre:
    .asciz  "[silica] abort: "
silica_rt_abort_at:
    .asciz  " at "
silica_rt_abort_detail:
    .asciz  " abort (runtime)"
silica_rt_reason_check:
    .asciz  "runtime check failed"
silica_rt_reason_region_overflow:
    .asciz  "region allocation failed"
silica_rt_reason_buf_invalid:
    .asciz  "invalid buffer size"
silica_rt_reason_buf_bounds:
    .asciz  "buffer index out of bounds"
silica_rt_reason_list_index:
    .asciz  "list index out of range"
silica_rt_reason_out_of_memory:
    .asciz  "out of memory"
silica_rt_reason_arena_key:
    .asciz  "canonical arena key is zero"
silica_rt_reason_arena_full:
    .asciz  "canonical arena table is full"
silica_rt_reason_not_a_string:
    .asciz  "not a Silica string"
silica_rt_reason_ingress_full:
    .asciz  "supervision ingress queue full"
silica_rt_reason_heap_exhausted:
    .asciz  "heap exhausted"
silica_rt_reason_badarith:
    .asciz  "badarith"
silica_rt_reason_case_clause:
    .asciz  "case_clause"
silica_rt_reason_copier_overrun:
    .asciz  "copier overrun (the measure and the copy disagree)"
    .global silica_rt_reason_unsupported
silica_rt_reason_unsupported:
    .asciz  "runtime entry not yet ported to STM32-L476RG_raw"
silica_rt_fault_cause:
    .asciz  " fault: cause="
silica_rt_fault_pc:
    .asciz  " pc="
silica_rt_fault_cfsr:
    .asciz  " cfsr="
silica_rt_true_str:
    .asciz  "true"
silica_rt_false_str:
    .asciz  "false"
