# The NUCLEO-L476RG in QEMU (`SILICA_BOARD_EMULATOR=qemu`)

The `STM32-L476RG_raw` trial target runs on the Nucleo over ST-LINK, or, with `SILICA_BOARD_EMULATOR=qemu`,
in `qemu-system-arm` with no board at all, the way `ESP32-S3_raw` runs in Espressif QEMU in CI. Same compiler,
same emitted code, runtime, linker script and image layout; same goldens and skip list. Use it to run the
Nucleo trials without a board, in parallel, or on a machine with no ST-LINK (the Trials workflow's
`STM32-L476RG_raw` shards).

```
SILICA_BOARD_EMULATOR=qemu make integrate TRIAL_TARGET=STM32-L476RG_raw
SILICA_BOARD_EMULATOR=qemu make integrate TRIAL_TARGET=STM32-L476RG_raw TRIAL_SUITES=base
SILICA_BOARD_EMULATOR=qemu bash trials/targets/run_one_trial.sh STM32-L476RG_raw base test
SILICA_BOARD_EMULATOR=qemu sh tools/build_image.sh -o /tmp/x/app app.sams && python3 tools/run_in_qemu.py /tmp/x/app.elf
```

Needs `brew install qemu arm-none-eabi-gcc arm-none-eabi-binutils` (QEMU 9.1 or later for the STM32L4x5
USARTs; checked with 11.1.3) and any Python 3 (standard library only: the preflight takes the
`TARGET_EMULATOR_*` settings of `trials/targets/STM32-L476RG_raw.conf` instead of the board's pyserial,
OpenOCD and stlink).

The emulated run and the board run are the same trial target: they share its lock, mirror
(`trials/.target/STM32-L476RG_raw/`), outputs (`<trial>.STM32-L476RG_raw.sout`) and report
(`trials/.integrate_report.STM32-L476RG_raw`), so one waits for the other and the last run's results are
what is on disk. The report's header says which one ran (`board: qemu b-l475e-iot01a ...`).

## How it runs

| | Board | QEMU (`SILICA_BOARD_EMULATOR=qemu`) |
| --- | --- | --- |
| Machine | NUCLEO-L476RG (STM32L476RG) | `-machine b-l475e-iot01a` (STM32L475VG: the same L4x5/L4x6 die family, Cortex-M4F, SRAM1 96 KiB at `0x2000_0000`, SRAM2 32 KiB at `0x1000_0000`, the same RCC, GPIO and USART blocks) |
| Image | `tools/build_image.sh` | the same script: every source assembled with `BOARD_QEMU`, the runtime cache kept apart (`<cache>/qemu`), RAM images only |
| Load | `tools/run_on_board.py`: OpenOCD `reset halt`, `load_image`, the wall clock `mww`, `resume _start` | `tools/run_on_board.py` hands its command line to `tools/run_in_qemu.py`: QEMU's generic loader takes the ELF's segments plus an 8-byte vector table in flash at `0x0800_0000` (sp = top of SRAM1, reset = `_start`), since a Cortex-M in QEMU starts from the vector table, not from a probe. The wall clock is written into a copy of the ELF |
| Console | USART2 through the ST-LINK virtual COM port | USART2 as QEMU's second `-serial` (the first, USART1, is `null`), a TCP socket on 127.0.0.1 with `wait=on`, so the guest starts once the runner is attached and the start marker cannot be lost |
| Protocol | START / EXIT markers, `--send` after the marker | the same: `run_in_qemu.py` imports the board runner's `capture` |
| Concurrency | one program at a time (`.board.lock`) | `TARGET_EMULATOR_RUN_SLOTS` (4) QEMUs at once; `BOARD_RUN_SLOTS=N` overrides |

## The one runtime difference: `BOARD_QEMU`

QEMU has no model of the flash interface (`0x4002_2000` is an unimplemented device: writes are dropped,
reads give 0). `rt_start.S` sets `FLASH_ACR` to 4 wait states before the PLL switch and waits until the
register reads back 4, which never happens in QEMU. With `BOARD_QEMU` defined the write is kept and the
read-back loop becomes six narrow NOPs (its 12 bytes), so every address and the heap size are the board
image's. The board's images are assembled without the symbol and are byte-identical to before.

## What the model does not give you

- Timing. QEMU runs as fast as the host lets it; SysTick follows the host's clock, so timer trials measure
  host time and can be disturbed by a loaded machine (that is why the run slots stay below the core count).
- Bus faults on unmapped addresses that the silicon raises (QEMU maps more than the part has), and the
  GPIO alternate-function and output-speed settings (logged by `-d unimp`, ignored).
- The ST-LINK, flash programming (`--exec flash` is refused), and the probe's serial check: `--probe`
  reports the QEMU version and checks that the machine exists.

A trial that cannot pass in the model only goes in `trials/targets/STM32-L476RG_raw.skip` with a reason
that says so (the file is shared with the board, so such an entry skips it on the board too); none is
needed today.

Debugging an image: `python3 tools/run_in_qemu.py --print-qemu image.elf` prints the command and keeps the
staged files. Replace the TCP `-serial` with `-serial stdio` and add `-d unimp,guest_errors,int` (or
`-s -S` for gdb on :1234) to see what the guest does.

Environment: `SILICA_QEMU_ARM` (the `qemu-system-arm`; default: PATH, then Homebrew's),
`SILICA_QEMU_MACHINE` (default `b-l475e-iot01a`), `SILICA_QEMU_EXTRA` (extra QEMU arguments).
