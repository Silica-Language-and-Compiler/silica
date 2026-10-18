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

// Console and process-end routines for the bare-metal ESP32-S3 runtime.
//
// All output goes to UART0 (GPIO43 TX on the port test board), which the ROM has already set up at
// 115200 8N1. Bytes are written raw to the TX FIFO: no CR/LF translation, no dropped bytes, so the
// captured stream is byte-for-byte what the program printed. (The ROM's ets_write_char_uart turns
// '\n' into "\r\n" and swallows '\r', which would make output differ from the host.)
//
// Every routine is a normal windowed (CALL8) function following the Silica convention on this target:
// argument n is a 64-bit pair (arg0 in a2:a3, arg1 in a4:a5, arg2 in a6:a7; a 32-bit value uses the low
// register), result in a2. That is what emitted code passes, with X0-X2 in the caller's a10-a15.
//
// Both LX7 cores print (rt_actors.S runs actors on both). One console lock, owned by a core and
// re-entrant on the owning core, keeps every routine's output in one piece, and a core that ends a
// routine mid-line keeps the lock until it writes a newline or yields, so a println (two routine
// calls: the string, then the newline) and a print_string followed by print_int64 come out as one
// line; see "The console lock" below.
//
//   silica_rt_putc(c)                  one byte
//   silica_rt_write(ptr, len)          len bytes (len is a 32-bit count)
//   silica_rt_puts(cstr)               NUL-terminated
//   silica_rt_print_u32(v)             unsigned decimal
//   silica_rt_print_hex32(v)           0x-prefixed, 8 digits
//   silica_rt_flush()                  wait until the TX FIFO has drained
//   silica_rt_console_rx_drain()       discard whatever waits in the RX FIFO (program start)
//   silica_rt_console_poll_exit_line() read what waits in the RX FIFO; 1 when a line reading exactly
//                                      "exit" (a trailing CR ignored) has just completed, else 0. The
//                                      console is standard input on this target (spec §15.1.2.5): core
//                                      0's scheduler polls it, and rt_actors.S ends the program
//   silica_rt_exit(status)             exit marker with (status & 0xFF), then halt
//   silica_rt_abort_with(reason)       runtime abort: "[silica] abort: <reason> at 0x<pc>" as program output,
//                                      then exit status 71 (spec §15.4.5.5); pc is the CALL8 that got here
//   silica_rt_abort_<site>()           the same with the site's reason (region_overflow, buf_invalid,
//                                      buf_bounds, list_index, arena_key, arena_full, not_a_string,
//                                      heap_exhausted); silica_rt_abort() is "runtime check failed", for
//                                      code compiled before the per-site entries existed
//   silica_rt_fatal_report(cause, epc, excvaddr)   fatal fault: "[silica] fault at 0x<epc>" (plus
//                                      "  addr=0x<excvaddr>" for the causes that set EXCVADDR) as program
//                                      output, exit status 70, then the board-only details after the marker
//   silica_rt_fatal_last_resort(epc)   a fault raised while a report was being written (rt_vectors.S):
//                                      "[silica] fault at 0x<epc>" and exit status 70, nothing else
// How these meet the contract on every target: design_documents/runtime_failure_reporting.md.
//   silica_rt_badarith()               "badarith\n", exit status 1 (division by zero; the host prints
//                                      this on stderr, which the trial harness merges into .sout)
//   silica_rt_case_clause()            "case_clause\n", exit status 1 (no case arm matched)
//   silica_rt_print_i64(v) / _u64(v)   signed / unsigned 64-bit decimal (the emitter's print_int64 etc.)
//   silica_rt_print_bool(v)            "true" / "false"
//   silica_rt_print_string(s)          the bytes of a Silica string (tag -1, data +8, length +16);
//                                      _stderr is the same routine (one console)
// The host runtime's helpers for these live in the emitter (terms/print_*_inline.silica); this target
// calls the routines here instead. 64-bit division is libgcc's __udivdi3 / __umoddi3, which follow the
// windowed C ABI (pairs in a10:a11 and a12:a13, result in a10:a11).

#define UART0_FIFO_REG    0x60000000
#define UART0_STATUS_REG  0x6000001C
#define UART_TXFIFO_MAX   120          // FIFO holds 128; leave slack
// UART_STATUS_REG: bits 9:0 rxfifo_cnt, bits 25:16 txfifo_cnt. UART_FIFO_REG: a read pops one RX byte
// (bits 7:0), a write pushes one TX byte (ESP-IDF uart_ll.h for the ESP32-S3).

// \r = this core's id (0 or 1) from PRID (0xCDCD on the PRO cpu, 0xABAB on the APP cpu: bit 13).
.macro THIS_CORE r
    rsr     \r, prid
    extui   \r, \r, 13, 1
.endm

// EXCCAUSE values for which the processor sets EXCVADDR (Xtensa ISA: instruction fetch error 2,
// load/store error 3, alignment 9, PIF errors 12-15, TLB/privilege/prohibited 16-18, 20, 24-26, 28, 29).
#define EXCVADDR_CAUSES   0x3717F20C

// ---------------------------------------------------------------------------------------------
// The console lock. The word is 0 when free, else the owning core's id + 1; a depth per core makes
// it re-entrant on the owner, so a routine that takes it and calls another that takes it again
// (print_i64 -> print_u64 -> write -> putc) nests without deadlocking and each public routine can
// take it at its entry. S32C1I is the compare-and-swap, as in the scheduler lock. The lock is never
// held across a context switch: nothing here yields or calls user code. A context abandoned by a
// fault may hold it, so the fatal paths release it (silica_rt_actor_fault_hook calls
// silica_rt_console_release_if_mine; the trampolines call silica_rt_console_fatal_reset).
//
// The line hold: when the depth returns to 0 and the last byte this core wrote was not a newline, the
// lock stays owned (depth 0). The next output routine on this core nests into it; the other core
// waits until this core writes the newline, or yields (silica_rt_ctx_switch releases the hold: a
// context that parks or suspends mid-line does not keep the other core quiet), faults, or ends. So
// two cores never split each other's lines, only whole lines interleave, and a line can only wait for
// straight-line code on the other core, never for a message. The runtime never takes the scheduler
// lock while wanting the console, so the two locks cannot form a cycle.
    .section .bss.silica_rt_console_lock, "aw", @nobits
    .align  4
silica_rt_console_lock:
    .space  4
silica_rt_console_depth:
    .space  8                          // one word per core
    .global silica_rt_console_last
silica_rt_console_last:
    .space  8                          // the last byte each core wrote

    .section .text.silica_rt_console, "ax"
    .literal_position

    .align  4
    .global silica_rt_console_acquire
    .type   silica_rt_console_acquire, @function
silica_rt_console_acquire:
    entry   a1, 32
    THIS_CORE a2
    addi    a3, a2, 1                  // owner tag
    movi    a4, silica_rt_console_lock
    movi    a6, silica_rt_console_depth
    addx4   a6, a2, a6                 // &depth[core]
    l32i    a5, a4, 0
    beq     a5, a3, 2f                 // already ours: nest
1:  movi    a5, 0
    wsr     a5, scompare1
    mov     a5, a3
    s32c1i  a5, a4, 0
    bnez    a5, 1b
    movi    a5, 1
    s32i    a5, a6, 0
    retw
2:  l32i    a5, a6, 0
    addi    a5, a5, 1
    s32i    a5, a6, 0
    retw
    .size   silica_rt_console_acquire, . - silica_rt_console_acquire

    .align  4
    .global silica_rt_console_release
    .type   silica_rt_console_release, @function
silica_rt_console_release:
    entry   a1, 32
    THIS_CORE a2
    movi    a6, silica_rt_console_depth
    addx4   a6, a2, a6
    l32i    a5, a6, 0
    addi    a5, a5, -1
    s32i    a5, a6, 0
    bnez    a5, 1f
    movi    a3, silica_rt_console_last
    addx4   a3, a2, a3
    l32i    a3, a3, 0
    movi    a4, 10
    bne     a3, a4, 1f                 // mid-line: the line hold keeps the lock
    memw
    movi    a4, silica_rt_console_lock
    movi    a5, 0
    s32i    a5, a4, 0
    memw
1:  retw
    .size   silica_rt_console_release, . - silica_rt_console_release

// Release the lock whatever its depth when this core owns it: the context that held it is gone.
    .align  4
    .global silica_rt_console_release_if_mine
    .type   silica_rt_console_release_if_mine, @function
silica_rt_console_release_if_mine:
    entry   a1, 32
    THIS_CORE a2
    addi    a3, a2, 1
    movi    a4, silica_rt_console_lock
    l32i    a5, a4, 0
    bne     a5, a3, 1f
    movi    a6, silica_rt_console_depth
    addx4   a6, a2, a6
    movi    a5, 0
    s32i    a5, a6, 0
    memw
    s32i    a5, a4, 0
    memw
1:  retw
    .size   silica_rt_console_release_if_mine, . - silica_rt_console_release_if_mine

// A fatal fault or abort: the process ends (spec §15.4.5.5), whichever core raised it (rt_vectors.S).
// The first core to get here owns the end (silica_rt_fatal_owner, core id + 1, by compare-and-swap):
// it stalls the other core (rt_start.S silica_rt_stall_other_cpu: core 1 by RunStall, core 0 by the
// RTC software stall), so nothing else runs or prints while the report is written, and clears the
// console lock whoever held it. A core that loses the claim (both cores failing at once) halts here;
// the owner stalls it. A second entry by the owner (a fault in its own report) carries on.
    .align  4
    .global silica_rt_console_fatal_reset
    .type   silica_rt_console_fatal_reset, @function
silica_rt_console_fatal_reset:
    entry   a1, 32
    THIS_CORE a2
    addi    a3, a2, 1
    movi    a4, silica_rt_fatal_owner
    l32i    a5, a4, 0
    beq     a5, a3, 2f                 // already ours
    movi    a5, 0
    wsr     a5, scompare1
    mov     a5, a3
    s32c1i  a5, a4, 0
    beqz    a5, 2f                     // claimed
    beq     a5, a3, 2f
1:  waiti   15                         // the other core owns the end and stalls this one
    j       1b
2:  call8   silica_rt_stall_other_cpu
    movi    a4, silica_rt_console_lock
    movi    a5, 0
    s32i    a5, a4, 0
    movi    a4, silica_rt_console_depth
    s32i    a5, a4, 0
    s32i    a5, a4, 4
    memw
    retw
    .size   silica_rt_console_fatal_reset, . - silica_rt_console_fatal_reset

// ---------------------------------------------------------------------------------------------
// Output

    .align  4
    .global silica_rt_putc
    .type   silica_rt_putc, @function
silica_rt_putc:
    entry   a1, 32
    call8   silica_rt_console_acquire
    movi    a3, UART0_STATUS_REG
    movi    a5, UART_TXFIFO_MAX
1:  l32i    a4, a3, 0
    extui   a4, a4, 16, 10
    bgeu    a4, a5, 1b
    movi    a3, UART0_FIFO_REG
    extui   a2, a2, 0, 8
    s32i    a2, a3, 0
    memw
    THIS_CORE a4
    movi    a5, silica_rt_console_last
    addx4   a5, a4, a5
    s32i    a2, a5, 0
    call8   silica_rt_console_release
    retw
    .size   silica_rt_putc, . - silica_rt_putc

    .align  4
    .global silica_rt_write
    .type   silica_rt_write, @function
silica_rt_write:
    entry   a1, 32
    beqz    a4, 2f
    call8   silica_rt_console_acquire
    add     a3, a2, a4            // a3 = end
    mov     a6, a2
1:  l8ui    a10, a6, 0
    call8   silica_rt_putc
    addi    a6, a6, 1
    bltu    a6, a3, 1b
    call8   silica_rt_console_release
2:  retw
    .size   silica_rt_write, . - silica_rt_write

    .align  4
    .global silica_rt_puts
    .type   silica_rt_puts, @function
silica_rt_puts:
    entry   a1, 32
    call8   silica_rt_console_acquire
    mov     a6, a2
1:  l8ui    a10, a6, 0
    beqz    a10, 2f
    call8   silica_rt_putc
    addi    a6, a6, 1
    j       1b
2:  call8   silica_rt_console_release
    retw
    .size   silica_rt_puts, . - silica_rt_puts

// Unsigned decimal. Digits are produced least significant first into a 12-byte buffer at the
// bottom of the frame, then written forwards. Frame 48: [sp+0, sp+12) buffer, top 32 reserved.
    .align  4
    .global silica_rt_print_u32
    .type   silica_rt_print_u32, @function
silica_rt_print_u32:
    entry   a1, 48
    addi    a6, a1, 12            // one past the buffer end
    mov     a7, a6
    movi    a5, 10
1:  remu    a4, a2, a5
    quou    a2, a2, a5
    addi    a4, a4, 48
    addi    a7, a7, -1
    s8i     a4, a7, 0
    bnez    a2, 1b
    mov     a10, a7
    sub     a12, a6, a7
    call8   silica_rt_write
    retw
    .size   silica_rt_print_u32, . - silica_rt_print_u32

    .align  4
    .global silica_rt_print_hex32
    .type   silica_rt_print_hex32, @function
silica_rt_print_hex32:
    entry   a1, 32
    call8   silica_rt_console_acquire
    mov     a6, a2
    movi    a10, 48               // '0'
    call8   silica_rt_putc
    movi    a10, 120              // 'x'
    call8   silica_rt_putc
    movi    a7, 28
1:  ssr     a7
    srl     a10, a6
    extui   a10, a10, 0, 4
    movi    a4, 10
    bltu    a10, a4, 2f
    addi    a10, a10, 39          // 'a' - '0' - 10
2:  addi    a10, a10, 48
    call8   silica_rt_putc
    addi    a7, a7, -4
    bgez    a7, 1b
    call8   silica_rt_console_release
    retw
    .size   silica_rt_print_hex32, . - silica_rt_print_hex32

    .align  4
    .global silica_rt_flush
    .type   silica_rt_flush, @function
silica_rt_flush:
    entry   a1, 32
    movi    a3, UART0_STATUS_REG
1:  l32i    a4, a3, 0
    extui   a4, a4, 16, 10
    bnez    a4, 1b
    retw
    .size   silica_rt_flush, . - silica_rt_flush

// ---------------------------------------------------------------------------------------------
// Input: the exit line (spec §15.1.2.5). The ROM left UART0's receive side running at the baud the
// loader chose; nothing else reads it. The runtime takes no interrupts, so the FIFO (128 bytes) is
// polled: silica_rt_console_poll_exit_line pops every byte that waits and feeds it to a matcher for
// the one line that means anything, "exit" (optionally followed by one carriage return) ended by a
// newline. Every other line is discarded byte by byte; no line is buffered. The matcher's state is
// three words: bytes of "exit" matched so far, whether the current line has already failed to match,
// and whether the last byte was a carriage return (a CR that is not followed by the newline is an
// ordinary byte, so "ex\rit" is not "exit").

    .section .bss.silica_rt_console_rx, "aw", @nobits
    .align  4
silica_rt_exit_line_state:
    .space  12                         // [0] matched length  [4] line failed  [8] CR pending

    .section .text.silica_rt_console, "ax"

// silica_rt_console_rx_drain(): pop and discard every byte in the RX FIFO, and start a fresh line.
    .align  4
    .global silica_rt_console_rx_drain
    .type   silica_rt_console_rx_drain, @function
silica_rt_console_rx_drain:
    entry   a1, 32
    movi    a3, UART0_STATUS_REG
    movi    a4, UART0_FIFO_REG
1:  l32i    a5, a3, 0
    extui   a5, a5, 0, 10
    beqz    a5, 2f
    l32i    a5, a4, 0
    j       1b
2:  movi    a5, silica_rt_exit_line_state
    movi    a6, 0
    s32i    a6, a5, 0
    s32i    a6, a5, 4
    s32i    a6, a5, 8
    retw
    .size   silica_rt_console_rx_drain, . - silica_rt_console_rx_drain

// silica_rt_console_poll_exit_line() -> 1 when a line reading exactly "exit" has just completed, 0
// otherwise. Pops what waits in the RX FIFO; returns at the newline that completes an "exit" line,
// leaving any later bytes for the next poll (the program ends before they matter).
    .align  4
    .global silica_rt_console_poll_exit_line
    .type   silica_rt_console_poll_exit_line, @function
silica_rt_console_poll_exit_line:
    entry   a1, 32
    movi    a2, 0
    movi    a3, UART0_STATUS_REG
    movi    a4, UART0_FIFO_REG
    movi    a5, silica_rt_exit_line_state
1:  l32i    a6, a3, 0
    extui   a6, a6, 0, 10              // rxfifo_cnt
    beqz    a6, 9f
    l32i    a6, a4, 0
    extui   a6, a6, 0, 8               // the byte
    movi    a7, 10
    beq     a6, a7, 5f                 // newline: the line is complete
    l32i    a7, a5, 8
    beqz    a7, 2f
    movi    a7, 1                      // a CR followed by something other than a newline: an
    s32i    a7, a5, 4                  // ordinary byte, so this line is not "exit"
    movi    a7, 0
    s32i    a7, a5, 8
2:  movi    a7, 13
    bne     a6, a7, 3f
    movi    a7, 1
    s32i    a7, a5, 8                  // CR: decided by the next byte
    j       1b
3:  l32i    a7, a5, 4
    bnez    a7, 1b                     // this line has already failed
    l32i    a7, a5, 0
    movi    a8, 4
    bgeu    a7, a8, 4f                 // longer than "exit"
    movi    a8, silica_rt_exit_word
    add     a8, a8, a7
    l8ui    a8, a8, 0
    bne     a6, a8, 4f
    addi    a7, a7, 1
    s32i    a7, a5, 0
    j       1b
4:  movi    a7, 1
    s32i    a7, a5, 4
    j       1b
5:  l32i    a7, a5, 0                  // matched length
    l32i    a8, a5, 4                  // failed
    movi    a9, 0
    s32i    a9, a5, 0
    s32i    a9, a5, 4
    s32i    a9, a5, 8
    bnez    a8, 1b
    movi    a9, 4
    bne     a7, a9, 1b
    movi    a2, 1
9:  retw
    .size   silica_rt_console_poll_exit_line, . - silica_rt_console_poll_exit_line

// Exit marker: \x02SILICA:EXIT:<status>\x03, status = low byte like a host exit code.
    .align  4
    .global silica_rt_exit_marker
    .type   silica_rt_exit_marker, @function
silica_rt_exit_marker:
    entry   a1, 32
    call8   silica_rt_console_acquire
    extui   a6, a2, 0, 8
    movi    a10, silica_rt_exit_prefix
    call8   silica_rt_puts
    mov     a10, a6
    call8   silica_rt_print_u32
    movi    a10, 3
    call8   silica_rt_putc
    call8   silica_rt_console_release
    retw
    .size   silica_rt_exit_marker, . - silica_rt_exit_marker

// The end of the program. The other core is stalled too, once the output has drained, so an idle or
// still-running core prints nothing and does nothing after the exit marker (core 1 ends the program
// after its own fatal report).
    .align  4
    .global silica_rt_halt
    .type   silica_rt_halt, @function
silica_rt_halt:
    entry   a1, 32
    call8   silica_rt_flush
    call8   silica_rt_stall_other_cpu
1:  waiti   15
    j       1b
    .size   silica_rt_halt, . - silica_rt_halt

// The lock is taken for the marker and its newline together and never released: this core halts.
// After the marker on its line (so outside the program's output, where the fault report puts its
// details too; run_on_board.py passes that text to its stderr) one diagnostic reports how deep
// main's two stacks went, against their per-image sizes:
//   [silica] stacks: machine <high-water>/<size> aux <high-water>/<size> actors <n> actor-max
//   machine <bytes> aux <bytes> sup-max machine <bytes> aux <bytes>
// The high-water mark is the distance from the top to the lowest non-zero word (both stacks start
// zeroed: rt_start.S step 4, .bss); the actor figures are rt_actors.S silica_rt_actor_stacks_report.
    .align  4
    .global silica_rt_exit
    .type   silica_rt_exit, @function
silica_rt_exit:
    entry   a1, 48
    call8   silica_rt_console_acquire
    mov     a10, a2
    call8   silica_rt_exit_marker
    movi    a10, silica_rt_stacks_pre
    call8   silica_rt_puts
    movi    a10, _silica_heap_end
    movi    a11, _silica_stack_top
    call8   silica_rt_stack_high_water
    movi    a10, _silica_main_stack_size
    call8   silica_rt_print_u32
    movi    a10, silica_rt_stacks_aux
    call8   silica_rt_puts
    movi    a10, silica_rt_aux_stack_bottom
    movi    a11, silica_rt_aux_stack_top
    call8   silica_rt_stack_high_water
    movi    a10, _silica_main_aux_size
    call8   silica_rt_print_u32
    call8   silica_rt_actor_stacks_report   // rt_actors.S: the actors' deepest stacks
    movi    a10, 10
    call8   silica_rt_putc
    call8   silica_rt_halt
    retw
    .size   silica_rt_exit, . - silica_rt_exit

// silica_rt_stack_high_water(bottom, top): prints "<top - lowest non-zero word>/".
    .align  4
silica_rt_stack_high_water:
    entry   a1, 32
    mov     a4, a2
1:  bgeu    a4, a3, 2f
    l32i    a5, a4, 0
    bnez    a5, 2f
    addi    a4, a4, 4
    j       1b
2:  sub     a10, a3, a4
    call8   silica_rt_print_u32
    movi    a10, 47                   // '/'
    call8   silica_rt_putc
    retw
    .size   silica_rt_stack_high_water, . - silica_rt_stack_high_water

// Runtime abort. Every entry is a windowed function reached with CALL8: it names its reason in a2 and
// jumps to silica_rt_abort_body in the same window, where a0 still holds the return address into the
// site. The body turns that into the address of the CALL8 (bits 31:30 of a0 hold the window increment,
// not the address; the real top bits are those of this code) and hands reason and address to
// silica_rt_abort_trampoline (rt_vectors.S), which abandons the context the way the fatal path does and
// prints the report on the fault stack. Nothing is allocated, so a heap-exhausted abort is safe.
    .align  4
    .global silica_rt_abort_with
    .type   silica_rt_abort_with, @function
silica_rt_abort_with:
    entry   a1, 32
    j       silica_rt_abort_body       // a2 = the caller's reason
    .size   silica_rt_abort_with, . - silica_rt_abort_with

.macro ABORT_ENTRY name, reason
    .align  4
    .global \name
    .type   \name, @function
\name:
    entry   a1, 32
    movi    a2, \reason
    j       silica_rt_abort_body
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

// a2 = reason, a0 = return address of the CALL8 into the entry. Never returns.
    .align  4
silica_rt_abort_body:
    movi    a8, 0x3fffffff
    and     a3, a0, a8
    movi    a9, silica_rt_abort_body
    extui   a9, a9, 30, 2
    slli    a9, a9, 30
    or      a3, a3, a9
    addi    a3, a3, -3                // CALL8 is three bytes
    call0   silica_rt_abort_trampoline
1:  j       1b

// a2 reason, a4 address of the call (arguments 0 and 1). Runs on the fault stack in a fresh window.
    .align  4
    .global silica_rt_abort_report
    .type   silica_rt_abort_report, @function
silica_rt_abort_report:
    entry   a1, 32
    mov     a6, a2
    mov     a7, a4
    movi    a10, silica_rt_abort_pre
    call8   silica_rt_puts
    mov     a10, a6
    call8   silica_rt_puts
    movi    a10, silica_rt_abort_at
    call8   silica_rt_puts
    mov     a10, a7
    call8   silica_rt_print_hex32
    movi    a10, 10
    call8   silica_rt_putc
    movi    a10, 71
    call8   silica_rt_exit
    retw
    .size   silica_rt_abort_report, . - silica_rt_abort_report

    .align  4
    .global silica_rt_badarith
    .type   silica_rt_badarith, @function
silica_rt_badarith:
    entry   a1, 32
    call8   silica_rt_current_actor        // inside an actor: the actor fails, the program goes on
    beqz    a10, 1f
    movi    a10, 1
    call8   silica_rt_actor_trap
1:  movi    a10, silica_rt_badarith_msg
    call8   silica_rt_main_fail_exit      // rt_actors.S: the name, the pending reports, status 1
    retw
    .size   silica_rt_badarith, . - silica_rt_badarith

    .align  4
    .global silica_rt_case_clause
    .type   silica_rt_case_clause, @function
silica_rt_case_clause:
    entry   a1, 32
    call8   silica_rt_current_actor
    beqz    a10, 1f
    movi    a10, 2                         // reason tag 2 (:language_error), as the host's
    call8   silica_rt_actor_trap
1:  movi    a10, silica_rt_case_clause_msg
    call8   silica_rt_main_fail_exit      // rt_actors.S: the name, the pending reports, status 1
    retw
    .size   silica_rt_case_clause, . - silica_rt_case_clause

// Unsigned 64-bit decimal: digits least significant first into a 24-byte buffer at the bottom of
// the frame, written forwards. Frame 64: [sp+0, sp+24) buffer, top 32 reserved.
    .align  4
    .global silica_rt_print_u64
    .type   silica_rt_print_u64, @function
silica_rt_print_u64:
    entry   a1, 64
    call8   silica_rt_console_acquire
    addi    a6, a1, 24            // one past the buffer end
    mov     a7, a6
    mov     a4, a2
    mov     a5, a3
1:  mov     a10, a4
    mov     a11, a5
    movi    a12, 10
    movi    a13, 0
    call8   __umoddi3
    addi    a10, a10, 48
    addi    a7, a7, -1
    s8i     a10, a7, 0
    mov     a10, a4
    mov     a11, a5
    movi    a12, 10
    movi    a13, 0
    call8   __udivdi3
    mov     a4, a10
    mov     a5, a11
    or      a8, a4, a5
    bnez    a8, 1b
    mov     a10, a7
    sub     a12, a6, a7
    call8   silica_rt_write
    call8   silica_rt_console_release
    retw
    .size   silica_rt_print_u64, . - silica_rt_print_u64

// Signed: a minus sign, then the magnitude (two's-complement negation of the pair; INT64_MIN negates
// to itself, which as an unsigned value is its own magnitude).
    .align  4
    .global silica_rt_print_i64
    .type   silica_rt_print_i64, @function
silica_rt_print_i64:
    entry   a1, 32
    call8   silica_rt_console_acquire
    bgez    a3, 1f
    movi    a8, 0
    saltu   a9, a8, a2            // borrow: low word non-zero
    sub     a2, a8, a2
    sub     a3, a8, a3
    sub     a3, a3, a9
    movi    a10, 45               // '-'
    call8   silica_rt_putc
1:  mov     a10, a2
    mov     a11, a3
    call8   silica_rt_print_u64
    call8   silica_rt_console_release
    retw
    .size   silica_rt_print_i64, . - silica_rt_print_i64

    .align  4
    .global silica_rt_print_bool
    .type   silica_rt_print_bool, @function
silica_rt_print_bool:
    entry   a1, 32
    movi    a10, silica_rt_true_str
    bnez    a2, 1f
    movi    a10, silica_rt_false_str
1:  call8   silica_rt_puts
    retw
    .size   silica_rt_print_bool, . - silica_rt_print_bool

// silica_rt_print_char(X0 = the encoded char: a2 low word, a3 high word). The UTF-8 bytes sit
// lowest first in the word and the count is its top byte (sir_generator char_lexeme_to_utf8_encoded),
// so both words are stored to the frame and written from there. Frame 48: [sp+0, sp+8) the word.
    .align  4
    .global silica_rt_print_char
    .type   silica_rt_print_char, @function
silica_rt_print_char:
    entry   a1, 48
    s32i    a2, a1, 0
    s32i    a3, a1, 4
    extui   a12, a3, 24, 8
    mov     a10, a1
    call8   silica_rt_write
    retw
    .size   silica_rt_print_char, . - silica_rt_print_char

    .align  4
    .global silica_rt_print_string
    .global silica_rt_print_string_stderr
    .type   silica_rt_print_string, @function
silica_rt_print_string:
silica_rt_print_string_stderr:
    entry   a1, 32
    l32i    a8, a2, 0
    addi    a8, a8, 1
    bnez    a8, 1f
    l32i    a10, a2, 8
    l32i    a12, a2, 16
    call8   silica_rt_write               // one write: the lock keeps the bytes together
    retw
1:  call8   silica_rt_abort_not_a_string
    retw
    .size   silica_rt_print_string, . - silica_rt_print_string

// a2 cause (EXCCAUSE, or 1001.. for a non-user vector), a4 EPC1, a6 EXCVADDR.
// The fatal fault report (spec §15.4.5.5): "[silica] fault at 0x<epc>", then "  addr=0x<excvaddr>" only for
// the causes that set EXCVADDR (the address is never invented: a stack-guard hit, cause 1006, is a data
// breakpoint and has none), as program output; then the exit marker with status 70, and after the marker
// the board-only details (cause, both registers, the stack-guard note), which run_on_board.py sends to
// stderr. There is no symbol (no symbol table on the board) and no actor field (the fault banner names no actor; the actor runtime is rt_actors.S).
    .align  4
    .global silica_rt_fatal_report
    .type   silica_rt_fatal_report, @function
silica_rt_fatal_report:
    entry   a1, 32
    mov     a5, a6
    mov     a7, a4
    mov     a6, a2
    movi    a10, silica_rt_fault_pre
    call8   silica_rt_puts
    mov     a10, a7
    call8   silica_rt_print_hex32
    movi    a8, 32
    bgeu    a6, a8, 2f                // vector codes 1001.. and causes 32+: no fault address
    movi    a8, EXCVADDR_CAUSES
    ssr     a6
    srl     a8, a8
    bbci    a8, 0, 2f
    movi    a10, silica_rt_fault_addr
    call8   silica_rt_puts
    mov     a10, a5
    call8   silica_rt_print_hex32
2:  movi    a10, 10
    call8   silica_rt_putc
    movi    a10, 70
    call8   silica_rt_exit_marker
    movi    a10, silica_rt_fault_cause
    call8   silica_rt_puts
    mov     a10, a6
    call8   silica_rt_print_u32
    movi    a10, silica_rt_fault_epc
    call8   silica_rt_puts
    mov     a10, a7
    call8   silica_rt_print_hex32
    movi    a10, silica_rt_fault_vaddr
    call8   silica_rt_puts
    mov     a10, a5
    call8   silica_rt_print_hex32
    movi    a8, 1006
    bne     a6, a8, 1f
    movi    a10, silica_rt_fault_guard
    call8   silica_rt_puts
1:  movi    a10, 10
    call8   silica_rt_putc
    call8   silica_rt_halt
    retw
    .size   silica_rt_fatal_report, . - silica_rt_fatal_report

// a2 = the pc of a fault raised while a fatal or abort report was being written (spec §15.4.5.5). The
// line and the exit marker only: the details after the marker, and the fault address, are left out.
    .align  4
    .global silica_rt_fatal_last_resort
    .type   silica_rt_fatal_last_resort, @function
silica_rt_fatal_last_resort:
    entry   a1, 32
    mov     a6, a2
    movi    a10, silica_rt_fault_pre
    call8   silica_rt_puts
    mov     a10, a6
    call8   silica_rt_print_hex32
    movi    a10, 10
    call8   silica_rt_putc
    movi    a10, 70
    call8   silica_rt_exit
    retw
    .size   silica_rt_fatal_last_resort, . - silica_rt_fatal_last_resort

    .section .rodata.silica_rt_console, "a"
silica_rt_exit_prefix:
    .byte   0x02
    .asciz  "SILICA:EXIT:"
silica_rt_stacks_pre:
    .asciz  " [silica] stacks: machine "
silica_rt_stacks_aux:
    .asciz  " aux "
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
silica_rt_fault_cause:
    .asciz  " fault: exccause="
silica_rt_fault_epc:
    .asciz  " epc="
silica_rt_fault_vaddr:
    .asciz  " excvaddr="
silica_rt_fault_guard:
    .asciz  " (stack guard: machine or auxiliary stack overflow)"
silica_rt_badarith_msg:
    .asciz  "badarith\n"
silica_rt_case_clause_msg:
    .asciz  "case_clause\n"
silica_rt_true_str:
    .asciz  "true"
silica_rt_false_str:
    .asciz  "false"
