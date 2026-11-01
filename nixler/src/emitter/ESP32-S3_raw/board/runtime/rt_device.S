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

// Device windows for map_device (silica_device_actor_specification.md §5.1, porting_for_os_free_targets.md
// §5.1, §10). The window table below is the run-time twin of the emitter's board pack,
// emitter/ESP32-S3_raw/board_pack.silica (window_base / window_size, rows 0-10): the emitter checks a
// constant map_device base against that table at compile time and calls this routine for a computed
// one. When one table changes, the other changes.
//
//   silica_rt_map_device_check(a2:a3 base, a4:a5 size) -> a2:a3 base
//
// Silica pair convention (design §4): the base is X0 = a2:a3, the size X1 = a4:a5, high words zero on
// this 32-bit bus. Returns, with the base still in a2:a3, when [base, base + size) lies inside one
// window; otherwise it does not return: silica_rt_abort_with (rt_console.S) reports
// "[silica] abort: illegal device map at 0x<site>" and ends the program with status 71.

    .section .rodata.silica_rt_device, "a"
    .align  4
// Each row: base, size (bytes); a zero base ends the table. Same order as board_pack.silica.
silica_rt_device_windows:
    .word   0x60000000, 0x1000        // :esp32s3_uart
    .word   0x60004000, 0x1000        // :esp32s3_gpio
    .word   0x60008000, 0x1000        // :esp32s3_rtc_cntl
    .word   0x60009000, 0x1000        // :esp32s3_io_mux
    .word   0x6001F000, 0x1000        // :esp32s3_timg0
    .word   0x60020000, 0x1000        // :esp32s3_timg1
    .word   0x60023000, 0x1000        // :esp32s3_systimer
    .word   0x60038000, 0x1000        // :esp32s3_usb_serial_jtag
    .word   0x600C0000, 0x1000        // :esp32s3_system
    .word   0x60024000, 0x1000        // :esp32s3_spi2 (TRM-unconfirmed, as in the board pack)
    .word   0x60016000, 0x1000        // :esp32s3_rmt (TRM-unconfirmed, as in the board pack; channel RAM at +0x800)
    .word   0x60019000, 0x1000        // :esp32s3_ledc (TRM-unconfirmed, as in the board pack)
    .word   0, 0
silica_rt_reason_illegal_device_map:
    .asciz  "illegal device map"

    .section .text.silica_rt_device, "ax"
    .literal_position
    .align  4
    .global silica_rt_map_device_check
    .type   silica_rt_map_device_check, @function
silica_rt_map_device_check:
    entry   a1, 32
    bnez    a3, 8f                    // a 64-bit address or size is never a window
    bnez    a5, 8f
    beqz    a4, 8f                    // an empty range maps nothing
    add     a6, a2, a4                // a6 = end of the requested range
    bltu    a6, a2, 8f                // wrapped past the top of the bus
    movi    a7, silica_rt_device_windows
1:  l32i    a8, a7, 0                 // a8 = window base
    beqz    a8, 8f
    l32i    a9, a7, 4                 // a9 = window size
    bltu    a2, a8, 2f                // base below this window
    add     a10, a8, a9               // a10 = window end
    bltu    a10, a6, 2f               // range ends past this window
    retw
2:  addi    a7, a7, 8
    j       1b
8:  movi    a10, silica_rt_reason_illegal_device_map
    call8   silica_rt_abort_with
    retw
    .size   silica_rt_map_device_check, . - silica_rt_map_device_check
