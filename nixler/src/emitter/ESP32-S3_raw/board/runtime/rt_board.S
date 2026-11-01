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
