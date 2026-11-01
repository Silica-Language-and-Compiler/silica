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

// Bring-up app 13: the display. Writes "Hello from Silica" (white on black, two lines, 5x7 font at
// 4x) on the 240x320 ST7789 panel behind FPC P2, in landscape as the panel sits on the board (flex to
// the left): MADCTL 0xA0 exchanges rows and columns and flips the rows, so the frame is 320x240.
//
// Pins are the netlist's (PORT_TEST_BOARD_byu_idaho_v4.0_feb26.md, "What the hardware design says":
// display FPC P2 on GPIO0, 1, 3, 45, 46): chip select GPIO0, data/command GPIO45, clock GPIO46, data
// GPIO3, and GPIO1 driven as the panel reset (the eBadge netlist, P2 pins 2-6, agrees; the panel is an
// ST7789, read back as ID 0x858552). The sheet's "SPI CS: 10" is not driven -- GPIO10 is the
// Right button behind an external pull-down -- and a software reset command follows the GPIO1 pulse,
// so nothing depends on GPIO1 being the reset line. GPIO0, 3, 45, 46 are strapping pins, sampled at
// reset only; the ROM has long finished with them by the time main runs.
//
// The bus is 4-wire SPI mode 0 (clock idle low, data sampled on the rising edge, most significant bit
// first), bit-banged through the GPIO set/clear registers as asm_11 drives its LEDs: MOSI is set or
// cleared, then the clock is raised and dropped, each edge performed (memw) before the next (see
// clk_pulse). Every command opens its own chip-select transaction (see cmd). Both rules were found
// by reading the controller back over SDA (its ID, status, and frame memory) after each attempt.
// The CPU ran at 40 MHz during all of it (see asm_11's measure_clock). The controller behind the panel (flex marked
// HS20HS072RX) is not recorded in this tree, so only the MIPI DCS commands common to the ST7789 /
// ILI9341 family are used: software reset, sleep out, 16-bit pixel format, memory access control,
// normal mode, display inversion on, display on, column/row address set, memory write. Inversion is
// needed: this IPS panel showed a 0xFFFF fill as black without it. The backlight is always on in
// hardware (+3.3 V through R18, 100 ohm, into P2 pin 10) and is dim -- look in subdued light.
//
// Expected console: "reset", "init", "clear <cycles>", "text", "done", status 0; on the panel, a
// black screen with "Hello from" over "Silica" in white, centred, reading left to right along the
// long side (first seen 2026-09-29).

#define CS_PIN    0
#define RST_PIN   1
#define MOSI_PIN  3
#define DC_PIN    45
#define CLK_PIN   46

#define GPIO_BASE       0x60004000      // +8 OUT_W1TS, +12 OUT_W1TC (pins 0-31)
#define OUT_W1TS        8               // +20 OUT1_W1TS, +24 OUT1_W1TC (pins 32-63)
#define OUT_W1TC        12
#define OUT1_W1TS       20
#define OUT1_W1TC       24

#define CS_MASK         (1 << CS_PIN)
#define MOSI_MASK       (1 << MOSI_PIN)
#define DC_MASK         (1 << (DC_PIN - 32))
#define CLK_MASK        (1 << (CLK_PIN - 32))

#define DCS_SWRESET     0x01
#define DCS_SLPOUT      0x11
#define DCS_NORON       0x13
#define DCS_INVON       0x21
#define DCS_DISPON      0x29
#define DCS_CASET       0x2A
#define DCS_RASET       0x2B
#define DCS_RAMWR       0x2C
#define DCS_MADCTL      0x36
#define DCS_COLMOD      0x3A

#define WIDTH           320             // landscape: MADCTL exchanges rows and columns
#define HEIGHT          240
#define FG              0xFFFF          // RGB565 white
#define BG              0x0000          // RGB565 black
#define SCALE           4
#define GLYPH_W         (5 * SCALE)     // 20
#define GLYPH_H         (7 * SCALE)     // 28
#define CELL_W          (6 * SCALE)     // 24: one blank column between glyphs

    .section .text.main, "ax"
    .literal_position

// clk_pulse(): one clock, each edge performed (memw) before the next is issued. A call per clock
// is deliberate: the panel ignored clocks issued back to back from the write buffer (~25 ns apart
// at the 40 MHz hand-off clock measured on 2026-09-29) and also a 5-cycle pulse timed with nops
// (~125 ns); this routine, first written for the read-back probe that returned the ST7789's ID
// 0x858552, is what the panel accepts. About 1 us per bit, 2.5 s for a full clear -- a bring-up
// speed, not a driver's -- and, unlike nop counts, it scales with the CPU clock.
    .align  4
    .type   clk_pulse, @function
clk_pulse:
    entry   a1, 32
    movi    a3, GPIO_BASE
    movi    a4, CLK_MASK
    s32i    a4, a3, OUT1_W1TS
    memw
    s32i    a4, a3, OUT1_W1TC
    memw
    retw
    .size   clk_pulse, . - clk_pulse

// spi_byte(b): eight bits out, most significant first; the data store is performed (memw) before
// the clock rises.
    .align  4
    .type   spi_byte, @function
spi_byte:
    entry   a1, 32
    movi    a3, GPIO_BASE
    movi    a4, MOSI_MASK
    movi    a6, 8
1:  bbsi    a2, 7, 2f
    s32i    a4, a3, OUT_W1TC
    j       3f
2:  s32i    a4, a3, OUT_W1TS
3:  memw
    call8   clk_pulse
    slli    a2, a2, 1
    addi    a6, a6, -1
    bnez    a6, 1b
    retw
    .size   spi_byte, . - spi_byte

// cmd(c): one command byte (D/C low) at the start of its own chip-select transaction: CS is raised,
// held 5 us, and lowered again before the byte. The panel needs that after SWRESET, which resets
// its serial interface -- with CS held low from the reset pulse onward, SWRESET was accepted and
// every command after it was ignored (status stayed 0x00610000), while the same commands each in a
// fresh transaction were all taken (0x80532400). Parameters and pixel data stay in the transaction.
    .align  4
    .type   cmd, @function
cmd:
    entry   a1, 32
    mov     a5, a2
    movi    a3, GPIO_BASE
    movi    a4, CS_MASK
    s32i    a4, a3, OUT_W1TS
    memw
    movi    a10, 5
    call8   silica_rt_delay_us
    movi    a3, GPIO_BASE
    movi    a4, CS_MASK
    s32i    a4, a3, OUT_W1TC
    movi    a4, DC_MASK
    s32i    a4, a3, OUT1_W1TC
    memw
    mov     a10, a5
    call8   spi_byte
    retw
    .size   cmd, . - cmd

// dat(d): one parameter byte (D/C high).
    .align  4
    .type   dat, @function
dat:
    entry   a1, 32
    movi    a3, GPIO_BASE
    movi    a4, DC_MASK
    s32i    a4, a3, OUT1_W1TS
    memw
    mov     a10, a2
    call8   spi_byte
    retw
    .size   dat, . - dat

// pixels(colour, n): n pixels of one RGB565 colour into the current window.
    .align  4
    .type   pixels, @function
pixels:
    entry   a1, 32
    extui   a4, a2, 8, 8          // high byte first
    extui   a5, a2, 0, 8
    mov     a6, a3
    movi    a7, GPIO_BASE
    movi    a8, DC_MASK
    s32i    a8, a7, OUT1_W1TS
    memw
1:  mov     a10, a4
    call8   spi_byte
    mov     a10, a5
    call8   spi_byte
    addi    a6, a6, -1
    bnez    a6, 1b
    retw
    .size   pixels, . - pixels

// set_window(x0, y0, x1, y1): column and row address ranges, then start a memory write.
    .align  4
    .type   set_window, @function
set_window:
    entry   a1, 32
    movi    a10, DCS_CASET
    call8   cmd
    extui   a10, a2, 8, 8
    call8   dat
    extui   a10, a2, 0, 8
    call8   dat
    extui   a10, a4, 8, 8
    call8   dat
    extui   a10, a4, 0, 8
    call8   dat
    movi    a10, DCS_RASET
    call8   cmd
    extui   a10, a3, 8, 8
    call8   dat
    extui   a10, a3, 0, 8
    call8   dat
    extui   a10, a5, 8, 8
    call8   dat
    extui   a10, a5, 0, 8
    call8   dat
    movi    a10, DCS_RAMWR
    call8   cmd
    retw
    .size   set_window, . - set_window

// draw_font_row(bits): one 5-bit font row (bit 4 = leftmost column) as SCALE pixel rows of
// SCALE-wide pixels, inside a window already positioned by draw_glyph.
    .align  4
    .type   draw_font_row, @function
draw_font_row:
    entry   a1, 32
    mov     a6, a2
    movi    a3, SCALE             // a3 = pixel rows left
1:  mov     a2, a6
    movi    a4, 5                 // a4 = columns left
2:  movi    a10, BG
    bbci    a2, 4, 3f
    movi    a10, FG
3:  movi    a11, SCALE
    call8   pixels
    slli    a2, a2, 1
    addi    a4, a4, -1
    bnez    a4, 2b
    addi    a3, a3, -1
    bnez    a3, 1b
    retw
    .size   draw_font_row, . - draw_font_row

// draw_glyph(x, y, glyph): the 7 rows of one glyph with its top-left pixel at (x, y).
    .align  4
    .type   draw_glyph, @function
draw_glyph:
    entry   a1, 32
    mov     a10, a2
    mov     a11, a3
    addi    a12, a2, GLYPH_W - 1
    addi    a13, a3, GLYPH_H - 1
    call8   set_window
    movi    a5, 7
1:  l8ui    a10, a4, 0
    call8   draw_font_row
    addi    a4, a4, 1
    addi    a5, a5, -1
    bnez    a5, 1b
    retw
    .size   draw_glyph, . - draw_glyph

// glyph_of(ch) -> address of the glyph's 7 rows; a character not in charset draws as a space.
    .align  4
    .type   glyph_of, @function
glyph_of:
    entry   a1, 32
    movi    a3, charset
    movi    a4, font
1:  l8ui    a6, a3, 0
    beqz    a6, 2f
    beq     a6, a2, 3f
    addi    a3, a3, 1
    addi    a4, a4, 7
    j       1b
2:  movi    a4, font              // space is the first glyph
3:  mov     a2, a4
    retw
    .size   glyph_of, . - glyph_of

// draw_text(x, y, str): glyphs left to right, CELL_W apart.
    .align  4
    .type   draw_text, @function
draw_text:
    entry   a1, 32
1:  l8ui    a5, a4, 0
    beqz    a5, 2f
    mov     a10, a5
    call8   glyph_of
    mov     a12, a10
    mov     a10, a2
    mov     a11, a3
    call8   draw_glyph
    addi    a2, a2, CELL_W
    addi    a4, a4, 1
    j       1b
2:  retw
    .size   draw_text, . - draw_text

// write(pin, level): silica_rt_gpio_write with the level in the second argument pair.
    .align  4
    .type   write, @function
write:
    entry   a1, 32
    mov     a10, a2
    mov     a12, a3
    call8   silica_rt_gpio_write
    retw
    .size   write, . - write

    .align  4
    .global main
    .type   main, @function
main:
    entry   a1, 32
    movi    a2, 0
1:  movi    a3, pins
    addx4   a3, a2, a3
    l32i    a10, a3, 0
    call8   silica_rt_gpio_output
    addi    a2, a2, 1
    movi    a3, 5
    blt     a2, a3, 1b
    movi    a10, CS_PIN           // idle: deselected, reset released
    movi    a11, 1
    call8   write
    movi    a10, RST_PIN
    movi    a11, 1
    call8   write
    movi    a10, 10000
    call8   silica_rt_delay_us
    movi    a10, RST_PIN          // reset pulse: 10 ms low, 120 ms to come back
    movi    a11, 0
    call8   write
    movi    a10, 10000
    call8   silica_rt_delay_us
    movi    a10, RST_PIN
    movi    a11, 1
    call8   write
    movi    a10, 120000
    call8   silica_rt_delay_us
    movi    a10, msg_reset
    call8   silica_rt_puts
    movi    a10, CS_PIN           // selected for the rest of the run
    movi    a11, 0
    call8   write
    movi    a10, DCS_SWRESET
    call8   cmd
    movi    a10, 150000
    call8   silica_rt_delay_us
    movi    a10, DCS_SLPOUT
    call8   cmd
    movi    a10, 120000
    call8   silica_rt_delay_us
    movi    a10, DCS_COLMOD       // 16 bits per pixel
    call8   cmd
    movi    a10, 0x55
    call8   dat
    movi    a10, DCS_MADCTL       // MY | MV: landscape with the flex on the left, text upright
    call8   cmd
    movi    a10, 0xA0
    call8   dat
    movi    a10, DCS_NORON
    call8   cmd
    movi    a10, DCS_INVON        // IPS panel: without inversion 0xFFFF shows as black
    call8   cmd
    movi    a10, DCS_DISPON
    call8   cmd
    movi    a10, 20000
    call8   silica_rt_delay_us
    movi    a10, msg_init
    call8   silica_rt_puts
    rsr     a2, ccount
    movi    a10, 0                // clear the whole panel
    movi    a11, 0
    movi    a12, WIDTH - 1
    movi    a13, HEIGHT - 1
    call8   set_window
    movi    a10, BG
    movi    a11, WIDTH * HEIGHT
    call8   pixels
    rsr     a3, ccount
    sub     a3, a3, a2
    movi    a10, msg_clear
    call8   silica_rt_puts
    mov     a10, a3
    call8   silica_rt_print_u32
    movi    a10, 10
    call8   silica_rt_putc
    movi    a10, (WIDTH - (10 * CELL_W - SCALE)) / 2     // "Hello from": 236 px wide
    movi    a11, 88
    movi    a12, line1
    call8   draw_text
    movi    a10, (WIDTH - (6 * CELL_W - SCALE)) / 2      // "Silica": 140 px wide
    movi    a11, 88 + GLYPH_H + 2 * SCALE
    movi    a12, line2
    call8   draw_text
    movi    a10, msg_text
    call8   silica_rt_puts
    movi    a10, CS_PIN
    movi    a11, 1
    call8   write
    movi    a10, msg_done
    call8   silica_rt_puts
    movi    a2, 0
    movi    a3, 0
    retw
    .size   main, . - main

    .section .rodata.main, "a"
    .align  4
pins:       .word   CS_PIN, RST_PIN, MOSI_PIN, DC_PIN, CLK_PIN
msg_reset:  .asciz  "reset\n"
msg_init:   .asciz  "init\n"
msg_clear:  .asciz  "clear "
msg_text:   .asciz  "text\n"
msg_done:   .asciz  "done\n"
line1:      .asciz  "Hello from"
line2:      .asciz  "Silica"
// One glyph per charset character, in charset order; 7 rows each, bit 4 the leftmost column.
charset:    .asciz  " HelofrmSica"
font:
    .byte   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00    // space
    .byte   0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11    // H
    .byte   0x00, 0x00, 0x0E, 0x11, 0x1F, 0x10, 0x0E    // e
    .byte   0x0C, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E    // l
    .byte   0x00, 0x00, 0x0E, 0x11, 0x11, 0x11, 0x0E    // o
    .byte   0x06, 0x09, 0x08, 0x1C, 0x08, 0x08, 0x08    // f
    .byte   0x00, 0x00, 0x16, 0x19, 0x10, 0x10, 0x10    // r
    .byte   0x00, 0x00, 0x1A, 0x15, 0x15, 0x11, 0x11    // m
    .byte   0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E    // S
    .byte   0x04, 0x00, 0x0C, 0x04, 0x04, 0x04, 0x0E    // i
    .byte   0x00, 0x00, 0x0E, 0x10, 0x10, 0x11, 0x0E    // c
    .byte   0x00, 0x00, 0x0E, 0x01, 0x0F, 0x11, 0x0F    // a
