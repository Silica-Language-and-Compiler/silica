# `emitter/STM32-L476RG_raw/board/qemu/`: the NUCLEO-L476RG in QEMU

The board pack of the `STM32-L476RG_qemu` trial target ([trials/targets/STM32-L476RG_qemu.conf](../../../../../../trials/targets/STM32-L476RG_qemu.conf)):
the trials the `STM32-L476RG_raw` compiler emits, run in `qemu-system-arm` instead of on the Nucleo. There is
no separate compiler: the emitted code, the runtime (`../runtime/`), the linker script and the image layout are
the board's. Use it to run the Nucleo trials without a board, in parallel, or on a machine with no ST-LINK.

```
make integrate TRIAL_TARGET=STM32-L476RG_qemu                         # every suite the Nucleo runs
make integrate TRIAL_TARGET=STM32-L476RG_qemu TRIAL_SUITES=base
bash trials/targets/run_one_trial.sh STM32-L476RG_qemu base test      # one trial
sh tools/build_image.sh -o /tmp/x/app app.sams && python3 tools/run_on_board.py /tmp/x/app.elf
```

Needs `brew install qemu arm-none-eabi-gcc` (QEMU 9.1 or later: the STM32L4x5 USARTs; checked with 11.1.3)
and any Python 3 (standard library only).

## How it runs

| | Board (`../tools/`) | QEMU (`tools/`) |
| --- | --- | --- |
| Machine | NUCLEO-L476RG (STM32L476RG) | `-machine b-l475e-iot01a` (STM32L475VG: the same L4x5/L4x6 die family, Cortex-M4F, SRAM1 96 KiB at `0x2000_0000`, SRAM2 32 KiB at `0x1000_0000`, the same RCC, GPIO and USART blocks) |
| Image | `build_image.sh` | the same, through `tools/build_image.sh` with `BOARD_ASFLAGS=-Wa,--defsym,BOARD_QEMU=1` (RAM images only) |
| Load | OpenOCD: `reset halt`, `load_image`, the wall clock `mww`, `resume _start` | QEMU's generic loader: the ELF's segments, plus an 8-byte vector table in flash at `0x0800_0000` (sp = top of SRAM1, reset = `_start`), since a Cortex-M in QEMU starts from the vector table, not from a probe. The wall clock is written into a copy of the ELF |
| Console | USART2 through the ST-LINK virtual COM port | USART2 as QEMU's second `-serial` (the first, USART1, is `null`), a TCP socket on 127.0.0.1 with `wait=on`, so the guest starts only once the runner is attached and the start marker cannot be lost |
| Protocol | START / EXIT markers, `--send` after the marker | the same: `tools/run_on_board.py` imports the board runner's `capture` |
| Concurrency | one program at a time (`.board.lock`) | `TARGET_RUN_SLOTS` (4) QEMUs at once; `BOARD_RUN_SLOTS=N` overrides |

## The one runtime difference: `BOARD_QEMU`

QEMU has no model of the flash interface (`0x4002_2000` is an unimplemented device: writes are dropped,
reads give 0). `rt_start.S` sets `FLASH_ACR` to 4 wait states before the PLL switch and waits until the
register reads back 4, which never happens in QEMU. With `BOARD_QEMU` defined the write is kept and the
read-back loop is left out; nothing else in the runtime depends on it. The board's images are assembled
without the symbol and are unchanged.

## What the model does not give you

- Timing. QEMU runs as fast as the host lets it; SysTick follows the host's clock, so timer trials measure
  host time and can be disturbed by a loaded machine (that is why the run slots stay below the core count).
- Bus faults on unmapped addresses that the silicon raises (QEMU maps more than the part has), and the
  GPIO alternate-function and output-speed settings (logged by `-d unimp`, ignored).
- The ST-LINK, flash programming (`--exec flash`), and the probe's serial check: `--probe` reports the
  QEMU version and checks that the machine exists.

Differences found by the trials go in `trials/targets/STM32-L476RG_qemu.skip` with their reason, or as a
`<trial>.STM32-L476RG_qemu.scout` golden when the emulated output is right and differs for a real reason.

Debugging an image: `python3 tools/run_on_board.py --print-qemu image.elf` prints the command and keeps the
staged files. Replace the TCP `-serial` with `-serial stdio` and add `-d unimp,guest_errors,int` (or
`-s -S` for gdb on :1234) to see what the guest does.
