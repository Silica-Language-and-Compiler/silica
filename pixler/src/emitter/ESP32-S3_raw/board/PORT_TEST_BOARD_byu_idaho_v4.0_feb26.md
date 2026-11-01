# Port test board: BYU Idaho ESP32-S3 board, version 4.0 (FEB26)

The `ESP32-S3_raw` port (Xtensa LX7, bare metal, no ESP-IDF runtime) was brought up and tested
on this board. Bring-up apps under `board/` use these pin assignments. Anything board-specific
in the runtime (console, LEDs, buttons) must come from this file, not from a generic ESP32-S3
DevKit pinout.

## Board sheet (as supplied)

```
BYU IDAHO
VERSION 4.0  FEB26
```

### Peripherals

| Function | GPIO |
| --- | --- |
| LED | 6 |
| Addr LEDs (addressable) | 7 |
| Buzzer | 48 |
| RGB LED red | 1 |
| RGB LED green | 4 |
| RGB LED blue | 5 |

### Buttons

| Button | GPIO |
| --- | --- |
| Left | 21 |
| Right | 10 |
| Down | 47 |
| Up | 11 |
| Point | 0 (**the BOOT tactile switch SW1 by the USB-UART jack, not a joystick push**) |
| A | 34 |
| B | 33 |

### Analog

| Signal | GPIO |
| --- | --- |
| Joystick X axis | 8 |
| Joystick Y axis | 9 |
| Battery voltage (BV) | 12 |

### Accelerometer

| Field | Value |
| --- | --- |
| I2C address | 0x1C (on the I2C bus below) |

### Display (SPI2)

| Signal | GPIO |
| --- | --- |
| Chip Select | 0 |
| Data/Command | 45 |
| SPI CS | 10 (**a transcription error: the board's silkscreen says "Reset: 1", and so does the netlist**) |
| SPI CLK | 46 |
| SPI MOSI | 3 |

### SD card

| Signal | GPIO |
| --- | --- |
| Chip Select | 40 |
| SPI MOSI | 39 |
| SPI CLK | 38 |
| SPI MISO | 37 |

### Minidip A (see I2C)

| Signal | GPIO |
| --- | --- |
| CLK | 13 |
| IO1 | 14 |
| IO2 | 15 |
| IO3 | 16 |

### Minidip B (see I2C)

| Signal | GPIO |
| --- | --- |
| CLK | 45 |
| IO1 | 17 |
| IO2 | 18 |
| IO3 | 12 |

### Protocols

| Bus | Signal | GPIO |
| --- | --- | --- |
| UART0 | TX | 43 |
| UART0 | RX | 44 |
| UART1 | TX | 35 |
| UART1 | RX | 36 |
| SPI (SPI3) | MISO | 37 |
| SPI (SPI3) | MOSI | 39 |
| SPI (SPI3) | CLK | 38 |
| SPI (SPI3) | SD CS | 40 |
| I2C | SCL | 42 |
| I2C | SDA | 41 |

## What the hardware design says (authoritative over the sheet)

The board is the **BYU-I eBadge v4.0**. Design files: <https://github.com/BYU-I-eBadge/e-badge>,
folder `hardware v4.0/badge-esp32-s3/` (KiCad; `production/netlist.ipc` is the manufactured wiring).
Module: ESP32-S3-MINI-1-N4R2.

**GPIOs reach the peripherals only through jumpers on header J4** (2x15 socket). Odd J4 pins are
ESP32 GPIOs, the even pin beside each is a peripheral; a shunt across the pair connects them, so a
missing jumper disconnects that peripheral no matter what the software does:

| J4 pins | GPIO | Peripheral |
| --- | --- | --- |
| 1-2 | GPIO2 | RGB red (**the sheet says 1; the netlist says 2**) |
| 3-4 | GPIO4 | RGB green |
| 5-6 | GPIO5 | RGB blue |
| 7-8 | GPIO6 | single LED |
| 9-10 | GPIO7 | addressable LED chain (24 LEDs, powered from 5V_STABLE) |
| 11-12 | GPIO8 | joystick X |
| 13-14 | GPIO9 | joystick Y |
| 15-16 | GPIO10 | Right button |
| 17-18 | GPIO11 | Up button |
| 19-20 | GPIO21 | Left button |
| 21-22 | GPIO47 | Down button |
| 23-24 | GPIO33 | B button |
| 25-26 | GPIO34 | A button |
| 27-28 | GPIO48 | buzzer (MLT-5020 through a DTC114E transistor) |
| 29-30 | GPIO12 | battery voltage divider |

Directly wired (no jumper): display FPC `P2` on GPIO0 (CS), 45 (D/C), 46 (SCL), 3 (SDA), 1 (RST,
held low by R39 100 kΩ until driven; the sheet's "SPI CS: 10" row is wrong); SD card on GPIO37-40; I2C
(accelerometer MMA8452Q at 0x1C, headers) on GPIO41/42; UART0 to the CP2102N on GPIO43/44;
minidip A header J9 on GPIO13-18; UART1 header on GPIO35/36.

## Measured on the port's test unit (2026-09-12)

| Item | Result |
| --- | --- |
| Chip | ESP32-S3 (QFN56) revision v0.2, dual core, 240 MHz rated, 40 MHz crystal |
| Memory | 4 MB embedded quad-SPI flash (XMC, 3.3 V by eFuse), 2 MB embedded quad PSRAM (AP_3v3) |
| MAC | 3c:0f:02:e3:af:68 |
| USB | UART bridge enumerates as `/dev/cu.usbserial-10` on macOS; the board has a power switch, and nothing enumerates while it is off |
| CPU clock after ROM hand-off | ~20 MHz (10.03 M CCOUNT cycles in 0.503 s of wall time); the ROM does not start the PLL |
| Flash backup before first flash | `/Volumes/2T/silica/board_backups/byui_esp32s3_v4.0_3c0f02e3af68_2026-09-12_full_flash.bin` (SHA-256 `82b068ae...98fc`); restore with `esptool write-flash 0x0 <file>` |
| Buttons Left/Right/Down/Up/A/B | **Active high**: read 0 at rest and 1 while pressed (external pull-downs win over the internal pull-up). Clean edges, no bounce seen at a 10 ms poll |
| Point (GPIO0) | Reads 1 at rest (external strapping pull-up) |
| RGB LED | **Red GPIO2, green GPIO4, blue GPIO5**, all active high (confirmed one colour at a time). The sheet's "Red: 1" is wrong: GPIO1 is a display-connector pin |
| Single LED (GPIO6) | Works, active high, but **faint**: a red 0603 LED behind 5.1 kΩ (~0.3 mA). Easy to miss in room light |
| Buzzer (GPIO48) | Works. Fed from +3.3 V through the **RV1 trimmer** (blue block marked W102 beside BUZZER1, a 0-1 kΩ volume control, 25-turn, slips at the ends); on this unit it arrived turned to the quiet end and was silent until turned ~30 turns counter-clockwise. Loudest at its 2.7 kHz resonance |
| Addressable LEDs (GPIO7) | Work: 24 x WS2813B-2121, GRB order, driven by a bit-banged stream (`asm_11_addressable_leds`) without a level shifter (3.3 V data into 5 V LEDs). A square wave cannot light them (every long low is a reset). The pulse widths are nop counts, so asm_11 now measures the CPU clock first: 4/14 nops (0/1) at the 20 MHz hand-off of 2026-09-12; at the 40 MHz hand-off of 2026-09-29, 12–14 / 32–36 nops give clean frames, 9/29 mixed colours, 16/40 all ones (white); the app uses 13/34 |
| J4 jumpers | All 15 fitted on this unit (photo, 2026-09-12) |

## Port notes (derived from the sheet, not part of it)

- **Console.** UART0 on GPIO43/44 is the ESP32-S3 ROM's default console, which ROM
  `ets_write_char_uart` already drives at 115200 8N1 after reset. The bare-metal runtime prints
  through it, so program output and the exit marker need no UART setup of their own.
- **Shared pins on the sheet.** Treat these as one physical line each until checked on the
  hardware: GPIO0 (Point/BOOT switch and display chip select), GPIO45 (display Data/Command and
  Minidip B CLK), GPIO12 (battery voltage and Minidip B IO3), GPIO37–40 (the SD card and the SPI3
  bus are the same wires). GPIO10 is only the Right button (the sheet's "display SPI CS: 10" is
  wrong). Bring-up apps avoid the minidips for that reason.
- **Strapping pins.** GPIO0, GPIO3, GPIO45 and GPIO46 are ESP32-S3 strapping pins, sampled at
  reset. Holding Point (GPIO0) low during reset enters the ROM download mode instead of running
  the image — useful for flashing, surprising for a test that reads that button at boot.
- **Module flash type.** Buttons A/B (GPIO33/34) and UART1/SPI3 (GPIO35–37) use pins that
  octal-SPI modules reserve for flash/PSRAM, so this board presumably carries a quad-SPI module.
  Not verified; it matters only when PSRAM support is added.
- **LEDs.** Which level lights LED (GPIO6) and the RGB LED (GPIO2/4/5), active-high or
  active-low, is not on the sheet. The blink app toggles, so either polarity is visible.
  (Measured: all active high.)

## Display (measured 2026-09-29, second test unit)

The panel is an **HS20HS072RX** (flex marking), 240x320, **ST7789** — it answers `RDDID` with
`0x858552` — on a 12-pin 0.5 mm FPC (`P2`, LCSC C11086): pins 1 GND, 2 CS, 3 RS (D/C), 4 SCL,
5 SDA, 6 RST, 7 NC, 8 IOVCC, 9 VCC, 10 LED-A, 11 LED-K, 12 GND (eBadge `display.kicad_sch`). Wired to
GPIO0 (CS), GPIO45 (D/C), GPIO46 (SCL), GPIO3 (SDA, bidirectional — the controller answers reads on
it), GPIO1 (RST, R39 100 kΩ pull-down: the panel is held in reset until GPIO1 is driven high).
`apps/asm_13_display_hello` drives it bit-banged (SPI2 is not used). Two rules it enforces, found by
reading its status register after each attempt:

| Rule | What happened without it |
| --- | --- |
| Every command byte starts its own chip-select transaction (CS high ≈ 5 µs, then low); parameters and pixel data stay inside it | With CS held low from the reset pulse on, SWRESET was accepted and every later command ignored (`RDDST` stayed `0x00610000`); with a transaction per command all were taken (`0x80532400`) |
| Every clock edge is performed (`memw`) before the next store, one call per clock (roughly 0.5 µs half-periods at 40 MHz) | Edges issued back to back from the write buffer (~25 ns apart) and 5-cycle nop-timed pulses (~125 ns at 40 MHz) were ignored |

Also: `INVON` is required (a `0xFFFF` fill shows black without it); `MADCTL 0xA0` gives landscape
with the flex on the left and text upright (320 columns x 240 rows); `COLMOD 0x55` (RGB565) works;
24/32-bit register reads (`RDDID`, `RDDST`) take one dummy clock, 8-bit ones none, `RAMRD` one dummy
byte then 3 bytes per pixel. The **backlight is not switchable**: +3.3 V through R18 (100 Ω) into
LED-A, four white LEDs in parallel rated 80 mA, so it runs at a few milliamps and is dim in room light.

The **first test unit's panel never displayed anything** (its backlight glowed, its controller
answered reads, but nothing it was sent ever showed); the second unit displayed at once with the same
code, so that panel or its flex is faulty.

## Measured on the second test unit (2026-09-29)

Same board revision (VERSION 4.0 FEB26 on the back). Console UART enumerates as `/dev/cu.usbserial-10`
on macOS as well.

| Item | Result |
| --- | --- |
| CPU clock after ROM hand-off | **40 MHz** (40.00 M CCOUNT cycles per `ets_delay_us(1 s)`, real seconds by wall clock; asm_04's 20.0 M cycles per 0.5 s tone says the same) — twice the ~20 MHz measured on 2026-09-12, on both units. Nop-timed pulses (asm_11) came out half as wide and no LED decoded them until the app measured the clock and doubled its nop counts |
| Pad read-back (asm_09) | GPIO 1, 2, 4, 5, 6, 7, 48 and (probe) GPIO 0, 1, 3, 45, 46 all drive 1 and 0 — GPIO46 is output-capable on the ESP32-S3 |
| LED (GPIO6) | blinks, faint |
| RGB LED | red GPIO2, green GPIO4, blue GPIO5, active high |
| Buzzer (GPIO48) | three rising tones once RV1 is turned up |
| Buttons | Left 21, Right 10, Down 47, Up 11, A 34, B 33: idle 0, pressed 1. **Point is the BOOT switch** (SW1 → 470 Ω → GPIO0): idle 1, pressed 0. The joystick has no push wired to a GPIO |
| Joystick | GPIO8 = X, GPIO9 = Y (pot wipers). Read as digital inputs: 1 at rest (mid-rail); X reads 0 pushed left and 1 pushed right, Y reads 0 pushed up and 1 pushed down. Anything finer needs the ADC |
| Addressable LEDs (GPIO7) | Work: all 24, red / green / blue / running white, once asm_11 measured the 40 MHz clock and used its 13/34-nop table. With the 20 MHz table only LED 1 lit (green for a red frame) and the rest held stale data — a timing symptom, not a fault |
| Display | works — see the section above |
