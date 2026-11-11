# device_actor_stm32_addition

Board-only trials for device workers and the poke prims on the NUCLEO-L476RG (`STM32-L476RG_raw`), the
twins of `../device_actor_addition` (ESP32-S3) where they apply (`silica_device_actor_specification.md`).
Every register access happens inside a device worker's `sequence proc[register_rwr] ... produces pure
... end`; `main` only spawns, casts and waits. The workers live in `lib/`; the device descriptions are the
board pack's hand-written modules in `compiler/src/emitter/STM32-L476RG_raw/board/pack/`
(`device_stm32l4_<peripheral>_registers`, from ST RM0351), named by the Makefile.

| Trial | Shows |
| --- | --- |
| `device_uart_hello` | a USART2 worker: `peek(:isr)` polled for TXE, `poke(:tdr)` per byte; prints `hi` |
| `device_gpio_button` | an LED worker (GPIOA: MODER read-modify-write, BSRR for PA5) and a button worker (RCC AHB2ENR for the GPIOC clock, then IDR bit 13 for B1), the level cast to a printer actor |
| `device_discarded_peek` | `_: uint32 <- peek(w, :isr) impl Register32 {}` is still one load (check the `ldr` in `lib/device_usart2_lib.sams`) |
| `device_cast_registered` | `spawn_device_registered` + `cast_device_registered` through the third (device) registry |
| `device_client_result` | the §4.6 handshake: an ordinary client casts the device work and the worker casts the result to the named receiver |
| `device_window_param_survives_let` | a call-free register body with lets before its peek/poke keeps the window parameter; then PA5 driven high reads back 1 from IDR |
| `device_fault_lines` | a device worker that ends on a CPU exception (head of an empty list: the MPU null guard makes it a MemManage fault at 8) reports `exccause` / `epc` / `excvaddr` after `reason_tag` |
| `device_fault_lines_registered` | the same through `spawn_device_registered` |
| `device_map_computed_outside_window` | a computed `map_device` base outside every window: the runtime abort `illegal device map`, status 71 |

`refusals/` holds the two programs the emitter refuses at assembly time (see its README).
`device_led_row_constant_heap` has no twin: the NUCLEO has no LED row.

## Goldens and targets

- The trials carry `<stem>.STM32-L476RG_raw.scout` only; on a hosted target the emitter rejects the prims
  with E2220 (covered by `error_enforcement_addition/device_*`), and the ESP32-S3 board run skips the suite
  (`targets/ESP32-S3_raw.skip`). This directory stays `INTEGRATE_PENDING` (skipped by the host run).
- `compare_scout_normalized.sh` folds `actor_id`, `supervisor_acb`, the `epc` line and the
  `[silica] fault/abort` addresses, as in `device_actor_addition`. `excvaddr` is compared as printed.
- The goldens are hand-derived from the board facts (`BOARD_DESCRIPTION.md`, UM1724): B1 idles high (1);
  USART2 is the runtime console, so a worker's bytes appear in the program output. Nobody presses B1
  during the run.

Board run: `make integrate TRIAL_TARGET=STM32-L476RG_raw TRIAL_SUITES=device_actor_stm32_addition` from
`trials/`.
