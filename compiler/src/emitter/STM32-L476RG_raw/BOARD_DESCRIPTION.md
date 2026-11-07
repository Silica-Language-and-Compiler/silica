# STM32-L476RG_raw: target board description

Emitter directory for the ST NUCLEO-L476RG (STM32L476RG). The layout mirrors
`../ESP32-S3_raw` (atoms, board/{apps,pack,runtime,tests,tools}, constraints,
control, effects, recursion, shared, terms/{const,let,prims}). Directories
are empty placeholders (`.gitkeep`); the sample apps of the ESP32 tree are not
copied.

## Board, as probed on 2026-11-07 (`st-info --probe`, stlink from Homebrew)

| Item | Value |
|---|---|
| Board | NUCLEO-L476RG (on-board ST-LINK) |
| ST-LINK | VID 0x0483, PID 0x374b, firmware V2J33S25 (mass-storage `DETAILS.TXT` says version 0221), serial 066CFF343654393143174720 |
| Chip | STM32L47x_L48x, chip id 0x415, reference manual RM0351 |
| Core | Arm Cortex-M4 with FPU (CPUID 0x410fc241), SWD core id 0x2ba01477 |
| Flash | 1,048,576 bytes (1 MiB), page size 2,048 bytes; size register 0x1fff75e0 |
| SRAM | 98,304 bytes (0x18000) reported by st-info, which is SRAM1 at 0x2000_0000-0x2001_7FFF. The part has a further 32 KiB SRAM2 at 0x1000_0000-0x1000_7FFF. **Probed 2026-11-07 (OpenOCD, first smoke load): SRAM2 is NOT mapped above SRAM1 at 0x2001_8000 on this board (a write there bus-faults: CFSR 0x9600, BFAR 0x2001ffec); 0x1000_0000-0x1000_7fff reads back.** So the two are separate regions: the image, heap and main's machine stack live in SRAM1; the fault stack and main's auxiliary stack in SRAM2 (board/runtime/silica_stm32l476rg.ld). SRAM2_PE option byte at its default |
| Boot ROM | base 0x1fff0000, size 0x7000 |
| Option bytes | base 0x1fff7800, size 4 |
| Target voltage | 3264 mV |
| Mac drive | `/Volumes/NOD_L476RG` (drag-and-drop programming, writes to flash) |
| Virtual COM port | `/dev/cu.usbmodem21103` |

The ESP32-S3 board on the same Mac is `/dev/cu.usbserial-10`. With both boards
attached the ESP32 trial harness needs `BOARD_PORT=/dev/cu.usbserial-10`.

## Tools installed (Homebrew)

`stlink` (st-info, st-flash, st-util), plus whatever else Lee installed
(OpenOCD, arm-none-eabi toolchain). Run `st-info --probe` to confirm the
connection.

## Port notes (not started)

- Instruction set: Thumb-2 (ARMv7E-M), 32-bit; not Xtensa and not AArch64.
- Programs for the ESP32-S3 go to RAM, never flash. The same rule should hold
  here: load into SRAM through the debug port (OpenOCD or st-util/gdb), not
  into flash.
- The Silica runtime model (chunk 15 stack memory model: frame regions, aux
  stack chains, state chains, heap only as the source of stack chunks and
  mailbox buffers) applies unchanged; the memory budget is far smaller than
  on the ESP32-S3. The port lives in this directory (board/README.md).

## Raw `st-info --probe` output (essential lines)

```
Found 1 stlink programmers
  version:    V2J33S25
  serial:     066CFF343654393143174720
  flash:      1048576 (pagesize: 2048)
  sram:       98304
  chipid:     0x415
  dev-type:   STM32L47x_L48x
  voltage:    3264 mV
STM32L47x_L48x: 96 KiB SRAM, 1024 KiB flash in at least 2 KiB pages.
chip_id 0x415, flash_type 10, flash_size_reg 0x1fff75e0, flash_pagesize 0x800,
sram_size 0x18000, bootrom_base 0x1fff0000, bootrom_size 0x7000,
option_base 0x1fff7800, option_size 0x4, flags 2
```
