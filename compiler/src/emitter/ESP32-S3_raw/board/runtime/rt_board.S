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

// Board I/O for the bare-metal ESP32-S3 runtime: plain GPIO through the IO_MUX and the GPIO matrix,
// a microsecond delay and the CPU cycle counter. These are the device-register pokes that the
// bring-up apps (and, until Silica has map_device and volatile device access, Silica test apps via
// foreign bindings) use to drive the port test board's LEDs, buttons and buzzer; see
// PORT_TEST_BOARD_byu_idaho_v4.0_feb26.md for the pin map.
//
// Windowed (CALL8) functions, Silica convention (argument n is a pair: pin in a2, level in a4);
// pin numbers 0..48.
//
//   silica_rt_gpio_output(pin)            push-pull output, low
//   silica_rt_gpio_input_pullup(pin)      input with the pad pull-up enabled
//   silica_rt_gpio_write(pin, level)      level 0 or non-zero
//   silica_rt_gpio_read(pin) -> 0 | 1
//   silica_rt_delay_us(us)                busy-wait (ROM ets_delay_us, which knows the CPU clock)
//   silica_rt_cycles() -> CCOUNT          free-running CPU cycle counter
// and the board pin builtins (pin_mode / pin_pull / pin_write / pin_read, at the end of the file).

#define IO_MUX_GPIO0_REG          0x60009004     // + 4 * pin
#define MCU_SEL_MASK              0x7000         // bits 14:12, function 1 = GPIO
#define MCU_SEL_GPIO              0x1000
#define FUN_DRV_MASK              0x0C00         // bits 11:10
#define FUN_DRV_20MA              0x0800         // drive strength 2 (IDF default)
#define FUN_IE                    0x0200
#define FUN_PU                    0x0100
#define FUN_PD                    0x0080

#define GPIO_OUT_W1TS_REG         0x60004008
#define GPIO_OUT_W1TC_REG         0x6000400C
#define GPIO_OUT1_W1TS_REG        0x60004014
#define GPIO_OUT1_W1TC_REG        0x60004018
#define GPIO_ENABLE_W1TS_REG      0x60004024
#define GPIO_ENABLE_W1TC_REG      0x60004028
#define GPIO_ENABLE1_W1TS_REG     0x60004030
#define GPIO_ENABLE1_W1TC_REG     0x60004034
#define GPIO_IN_REG               0x6000403C
#define GPIO_IN1_REG              0x60004040
#define GPIO_PIN0_REG             0x60004074     // + 4 * pin; bit 2 = open drain
#define GPIO_FUNC0_OUT_SEL_CFG    0x60004554     // + 4 * pin
#define SIG_GPIO_OUT_IDX          256

#define ROM_ETS_DELAY_US          0x40000600

// GPIO19/20 are the USB PHY's D-/D+ pads; they only act as GPIO once the USB-Serial-JTAG pad
// enable is cleared (ESP-IDF gpio_ll_func_sel does the same).
#define USB_SERIAL_JTAG_CONF0_REG 0x60038018
#define USB_PAD_ENABLE            0x4000

    .section .text.silica_rt_board, "ax"
    .literal_position

// a2 = pin. If it is 19 or 20, release the USB pads. Leaf macro, uses a7, a8, a9.
.macro RELEASE_USB_PAD_IF_NEEDED
    addi    a7, a2, -19
    bltui   a7, 2, 90f
    j       91f
90: movi    a7, USB_SERIAL_JTAG_CONF0_REG
    l32i    a8, a7, 0
    movi    a9, ~USB_PAD_ENABLE
    and     a8, a8, a9
    s32i    a8, a7, 0
    memw
91:
.endm

// a2 = pin -> a4 = W1TS/W1TC base selector: (pin < 32 ? bank0 : bank1), a5 = 1 << (pin & 31).
// Leaf macro, uses a4, a5, a6.
.macro PIN_BANK_MASK
    movi    a5, 1
    extui   a6, a2, 0, 5
    ssl     a6
    sll     a5, a5
    extui   a4, a2, 5, 1          // 0 for pins 0..31, 1 for 32..63
.endm

    .align  4
    .global silica_rt_gpio_output
    .type   silica_rt_gpio_output, @function
silica_rt_gpio_output:
    entry   a1, 32
    RELEASE_USB_PAD_IF_NEEDED
    // IO_MUX: GPIO function, drive strength 2, no pulls.
    movi    a3, IO_MUX_GPIO0_REG
    addx4   a3, a2, a3
    l32i    a7, a3, 0
    movi    a8, ~(MCU_SEL_MASK | FUN_DRV_MASK | FUN_PU | FUN_PD)
    and     a7, a7, a8
    movi    a8, MCU_SEL_GPIO | FUN_DRV_20MA
    or      a7, a7, a8
    s32i    a7, a3, 0
    // GPIO matrix: plain GPIO output driven by GPIO_OUT, enabled by GPIO_ENABLE; push-pull.
    movi    a3, GPIO_FUNC0_OUT_SEL_CFG
    addx4   a3, a2, a3
    movi    a7, SIG_GPIO_OUT_IDX
    s32i    a7, a3, 0
    movi    a3, GPIO_PIN0_REG
    addx4   a3, a2, a3
    l32i    a7, a3, 0
    movi    a8, ~4
    and     a7, a7, a8
    s32i    a7, a3, 0
    PIN_BANK_MASK
    // Drive low before enabling, so the pin never glitches high.
    movi    a3, GPIO_OUT_W1TC_REG
    movi    a7, GPIO_OUT1_W1TC_REG
    movnez  a3, a7, a4
    s32i    a5, a3, 0
    movi    a3, GPIO_ENABLE_W1TS_REG
    movi    a7, GPIO_ENABLE1_W1TS_REG
    movnez  a3, a7, a4
    s32i    a5, a3, 0
    memw
    retw
    .size   silica_rt_gpio_output, . - silica_rt_gpio_output

    .align  4
    .global silica_rt_gpio_input_pullup
    .type   silica_rt_gpio_input_pullup, @function
silica_rt_gpio_input_pullup:
    entry   a1, 32
    RELEASE_USB_PAD_IF_NEEDED
    PIN_BANK_MASK
    movi    a3, GPIO_ENABLE_W1TC_REG
    movi    a7, GPIO_ENABLE1_W1TC_REG
    movnez  a3, a7, a4
    s32i    a5, a3, 0
    movi    a3, IO_MUX_GPIO0_REG
    addx4   a3, a2, a3
    l32i    a7, a3, 0
    movi    a8, ~(MCU_SEL_MASK | FUN_PD)
    and     a7, a7, a8
    movi    a8, MCU_SEL_GPIO | FUN_IE | FUN_PU
    or      a7, a7, a8
    s32i    a7, a3, 0
    memw
    retw
    .size   silica_rt_gpio_input_pullup, . - silica_rt_gpio_input_pullup

    .align  4
    .global silica_rt_gpio_write
    .type   silica_rt_gpio_write, @function
silica_rt_gpio_write:
    entry   a1, 32
    mov     a9, a4                // level (PIN_BANK_MASK does not touch a9)
    PIN_BANK_MASK
    movi    a3, GPIO_OUT_W1TC_REG
    movi    a7, GPIO_OUT_W1TS_REG
    movnez  a3, a7, a9
    movi    a7, GPIO_OUT1_W1TC_REG
    movi    a8, GPIO_OUT1_W1TS_REG
    movnez  a7, a8, a9
    movnez  a3, a7, a4
    s32i    a5, a3, 0
    memw
    retw
    .size   silica_rt_gpio_write, . - silica_rt_gpio_write

    .align  4
    .global silica_rt_gpio_read
    .type   silica_rt_gpio_read, @function
silica_rt_gpio_read:
    entry   a1, 32
    extui   a4, a2, 5, 1
    movi    a3, GPIO_IN_REG
    movi    a7, GPIO_IN1_REG
    movnez  a3, a7, a4
    memw
    l32i    a7, a3, 0
    extui   a6, a2, 0, 5
    ssr     a6
    srl     a7, a7
    extui   a2, a7, 0, 1
    retw
    .size   silica_rt_gpio_read, . - silica_rt_gpio_read

    .align  4
    .global silica_rt_delay_us
    .type   silica_rt_delay_us, @function
silica_rt_delay_us:
    entry   a1, 32
    mov     a10, a2
    movi    a8, ROM_ETS_DELAY_US
    callx8  a8
    retw
    .size   silica_rt_delay_us, . - silica_rt_delay_us

    .align  4
    .global silica_rt_cycles
    .type   silica_rt_cycles, @function
silica_rt_cycles:
    entry   a1, 32
    rsr     a2, ccount
    retw
    .size   silica_rt_cycles, . - silica_rt_cycles

// ---- board pin builtins (board_pin_builtins_design.md) -------------------------------------------
//
// Windowed (CALL8) entries, Silica pair convention: the pin is X1 = a4 (a uint32; a5 is not read), the
// mode / pull / level X2 = a6; pin_read answers in X0 = a2:a3, the others leave a2:a3 alone.
//   silica_rt_pin_mode(pin, mode)    mode 0 :input, 1 :output, 2 :output_open_drain
//   silica_rt_pin_pull(pin, pull)    pull 0 :none, 1 :up, 2 :down
//   silica_rt_pin_write(pin, level)  level 0 low, otherwise high
//   silica_rt_pin_read(pin) -> 0 | 1 the pad level (GPIO_IN / GPIO_IN1)
// The checked entries test the pin against silica_rt_pin_class (the twin of board_pack@pin_class: the
// same rows) and end the program with the abort report "<builtin>: pin <n> is not a pin it may use on
// this board" (status 71) for a number the builtin may not use; the _lit entries are for a literal pin,
// which the compiler checked already (sir_target_verify). pin_mode turns the pad's input buffer on
// (FUN_IE) in every mode, so pin_read reports the pad level of an output too; pulls and drive strength
// are kept. pin_read touches no configuration: on a read-only pin (the buttons, the joystick) it samples
// the level only (Lee, 2026-11-09).

#define PIN_LIMIT                 49             // board_pack@pin_number_limit
#define PIN_READ_ONLY             2
#define PIN_USABLE                3

// The checked prologue, inside the entry's window: a9 = the builtin's reason prefix. Uses a8, a9.
.macro PIN_CHECK minclass, prefix
    movi    a8, PIN_LIMIT
    bgeu    a4, a8, 80f
    movi    a8, silica_rt_pin_class
    add     a8, a8, a4
    l8ui    a8, a8, 0
    movi    a9, \minclass
    bgeu    a8, a9, 81f
80: movi    a9, \prefix
    j       silica_rt_pin_bad
81:
.endm

// a4 = pin -> a11 = bank (0 for GPIO0-31, 1 for GPIO32 and up), a12 = 1 << (pin & 31). Uses a13.
.macro PIN_BANK_MASK_A4
    movi    a12, 1
    extui   a13, a4, 0, 5
    ssl     a13
    sll     a12, a12
    extui   a11, a4, 5, 1
.endm

    .align  4
    .global silica_rt_pin_mode
    .type   silica_rt_pin_mode, @function
silica_rt_pin_mode:
    entry   a1, 32
    PIN_CHECK PIN_USABLE, silica_rt_pin_reason_mode
    j       rt_pin_mode_body
    .size   silica_rt_pin_mode, . - silica_rt_pin_mode

    .align  4
    .global silica_rt_pin_mode_lit
    .type   silica_rt_pin_mode_lit, @function
silica_rt_pin_mode_lit:
    entry   a1, 32
rt_pin_mode_body:
    // IO_MUX: GPIO function, input buffer on; pulls and drive strength kept.
    movi    a8, IO_MUX_GPIO0_REG
    addx4   a8, a4, a8
    l32i    a9, a8, 0
    movi    a10, ~MCU_SEL_MASK
    and     a9, a9, a10
    movi    a10, MCU_SEL_GPIO | FUN_IE
    or      a9, a9, a10
    s32i    a9, a8, 0
    PIN_BANK_MASK_A4
    beqz    a6, 3f
    // An output: the matrix routes GPIO_OUT to the pad (output enable from GPIO_ENABLE), PINn's open-drain
    // bit set for mode 2 and cleared for mode 1, then the enable bit.
    movi    a8, GPIO_FUNC0_OUT_SEL_CFG
    addx4   a8, a4, a8
    movi    a9, SIG_GPIO_OUT_IDX
    s32i    a9, a8, 0
    movi    a8, GPIO_PIN0_REG
    addx4   a8, a4, a8
    l32i    a9, a8, 0
    movi    a10, ~4
    and     a9, a9, a10
    addi    a13, a6, -2
    bnez    a13, 1f
    movi    a10, 4
    or      a9, a9, a10
1:  s32i    a9, a8, 0
    movi    a8, GPIO_ENABLE_W1TS_REG
    movi    a9, GPIO_ENABLE1_W1TS_REG
    movnez  a8, a9, a11
    s32i    a12, a8, 0
    memw
    retw
3:  movi    a8, GPIO_ENABLE_W1TC_REG
    movi    a9, GPIO_ENABLE1_W1TC_REG
    movnez  a8, a9, a11
    s32i    a12, a8, 0
    memw
    retw
    .size   silica_rt_pin_mode_lit, . - silica_rt_pin_mode_lit

    .align  4
    .global silica_rt_pin_pull
    .type   silica_rt_pin_pull, @function
silica_rt_pin_pull:
    entry   a1, 32
    PIN_CHECK PIN_USABLE, silica_rt_pin_reason_pull
    j       rt_pin_pull_body
    .size   silica_rt_pin_pull, . - silica_rt_pin_pull

    .align  4
    .global silica_rt_pin_pull_lit
    .type   silica_rt_pin_pull_lit, @function
silica_rt_pin_pull_lit:
    entry   a1, 32
rt_pin_pull_body:
    // IO_MUX FUN_WPU / FUN_WPD: both cleared, then the one the code names.
    movi    a8, IO_MUX_GPIO0_REG
    addx4   a8, a4, a8
    l32i    a9, a8, 0
    movi    a10, ~(FUN_PU | FUN_PD)
    and     a9, a9, a10
    movi    a10, FUN_PU
    movi    a11, FUN_PD
    movi    a12, 0
    addi    a13, a6, -1
    moveqz  a12, a10, a13
    addi    a13, a6, -2
    moveqz  a12, a11, a13
    or      a9, a9, a12
    s32i    a9, a8, 0
    memw
    retw
    .size   silica_rt_pin_pull_lit, . - silica_rt_pin_pull_lit

    .align  4
    .global silica_rt_pin_write
    .type   silica_rt_pin_write, @function
silica_rt_pin_write:
    entry   a1, 32
    PIN_CHECK PIN_USABLE, silica_rt_pin_reason_write
    j       rt_pin_write_body
    .size   silica_rt_pin_write, . - silica_rt_pin_write

    .align  4
    .global silica_rt_pin_write_lit
    .type   silica_rt_pin_write_lit, @function
silica_rt_pin_write_lit:
    entry   a1, 32
rt_pin_write_body:
    PIN_BANK_MASK_A4
    movi    a8, GPIO_OUT_W1TC_REG
    movi    a9, GPIO_OUT_W1TS_REG
    movnez  a8, a9, a6
    movi    a9, GPIO_OUT1_W1TC_REG
    movi    a10, GPIO_OUT1_W1TS_REG
    movnez  a9, a10, a6
    movnez  a8, a9, a11
    s32i    a12, a8, 0
    memw
    retw
    .size   silica_rt_pin_write_lit, . - silica_rt_pin_write_lit

    .align  4
    .global silica_rt_pin_read
    .type   silica_rt_pin_read, @function
silica_rt_pin_read:
    entry   a1, 32
    PIN_CHECK PIN_READ_ONLY, silica_rt_pin_reason_read
    j       rt_pin_read_body
    .size   silica_rt_pin_read, . - silica_rt_pin_read

    .align  4
    .global silica_rt_pin_read_lit
    .type   silica_rt_pin_read_lit, @function
silica_rt_pin_read_lit:
    entry   a1, 32
rt_pin_read_body:
    extui   a11, a4, 5, 1
    movi    a8, GPIO_IN_REG
    movi    a9, GPIO_IN1_REG
    movnez  a8, a9, a11
    memw
    l32i    a9, a8, 0
    extui   a13, a4, 0, 5
    ssr     a13
    srl     a9, a9
    extui   a2, a9, 0, 1
    movi    a3, 0
    retw
    .size   silica_rt_pin_read_lit, . - silica_rt_pin_read_lit

// The abort for a pin the builtin may not use, in the checked entry's window (a0 still returns into
// the site): the reason is composed in silica_rt_pin_reason_buf (a9's prefix, the number a4 in decimal,
// the tail), then silica_rt_abort_body (rt_console.S) reports it at the CALL8 and halts (status 71).
    .align  4
silica_rt_pin_bad:
    movi    a10, silica_rt_pin_reason_buf
1:  l8ui    a11, a9, 0
    beqz    a11, 2f
    s8i     a11, a10, 0
    addi    a9, a9, 1
    addi    a10, a10, 1
    j       1b
2:  movi    a12, silica_rt_pin_digits_end
    mov     a13, a4
    movi    a14, 10
3:  remu    a15, a13, a14
    quou    a13, a13, a14
    addi    a15, a15, 48
    addi    a12, a12, -1
    s8i     a15, a12, 0
    bnez    a13, 3b
    movi    a14, silica_rt_pin_digits_end
4:  l8ui    a15, a12, 0
    s8i     a15, a10, 0
    addi    a12, a12, 1
    addi    a10, a10, 1
    bne     a12, a14, 4b
    movi    a9, silica_rt_pin_reason_tail
5:  l8ui    a11, a9, 0
    s8i     a11, a10, 0
    addi    a9, a9, 1
    addi    a10, a10, 1
    bnez    a11, 5b
    movi    a2, silica_rt_pin_reason_buf
    j       silica_rt_abort_body

    .section .rodata.silica_rt_pin, "a"
// The pin builtins' table, one byte per GPIO 0..48 (board_pack.silica pin_class: 0 not a pin,
// 1 reserved, 2 read-only, 3 usable; the same rows).
silica_rt_pin_class:
    .byte   1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 1, 3, 3, 3   // 0..15
    .byte   3, 3, 3, 1, 1, 2, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0   // 16..31
    .byte   0, 2, 2, 3, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2   // 32..47
    .byte   1                                                // 48..48
silica_rt_pin_reason_mode:  .asciz "pin_mode: pin "
silica_rt_pin_reason_pull:  .asciz "pin_pull: pin "
silica_rt_pin_reason_write: .asciz "pin_write: pin "
silica_rt_pin_reason_read:  .asciz "pin_read: pin "
silica_rt_pin_reason_tail:  .asciz " is not a pin it may use on this board"

    .section .bss.silica_rt_pin, "aw", @nobits
    .align  4
silica_rt_pin_reason_buf:
    .space  80
silica_rt_pin_digits:
    .space  12
silica_rt_pin_digits_end:
