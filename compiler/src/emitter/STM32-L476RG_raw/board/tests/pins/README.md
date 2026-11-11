# Board pin builtin tests (NUCLEO-L476RG)

Board-specific tests of `pin_mode`, `pin_pull`, `pin_write` and `pin_read`
([board_pin_builtins_design.md](../../../../../../design_documents/board_pin_builtins_design.md) §7).
They live in this board's tree, are compiled by this board's compiler and are run by this board's
`tools/run_pin_tests.sh`; the shared `trials/` tree and the hosted integrate runs do not contain or run
them (the hosted rejection trials are `trials/error_enforcement_addition/device_pin_*_hosted_rejection_trial`).

Pins are `16 * port + bit` (PA0 = 0, PB0 = 16, PC13 = 45, PD2 = 50, PH0 = 112); the builtins may use 42 of them: every PA, PB, PC pin and PD2 except the reserved PA2, PA3 (the console), PA13, PA14 (SWD), PB3 (SWO), PC14, PC15 (32 kHz crystal), PH0, PH1 (clock). There are no read-only pins on this board, so the read-only failure trials are the ESP32-S3's only.

```
compiler/src/emitter/STM32-L476RG_raw/board/tools/run_pin_tests.sh             # every test here, on the board
compiler/src/emitter/STM32-L476RG_raw/board/tools/run_pin_tests.sh <stem>      # one test
```

The layout is a trial suite's (`trials/targets/board_suite.sh` runs it): `<stem>.silica` with
`<stem>.STM32-L476RG_raw.scout` and `<stem>.wait_for_exit` is a program run on the board (they need no wiring and run
unattended); `<stem>.silica` with `<stem>.STM32-L476RG_raw.golden_fail` is a compile-failure trial, compiled alone;
`lib/device_pin_sweep.silica` is the sweep worker the programs share. `compare_scout_normalized.sh`
folds the address of the runtime abort line.

| Test | Shows |
| --- | --- |
| `device_pin_output_readback` | every usable pin: output, write high, read high, write low, read low |
| `device_pin_pulls` | input with `:up` reads high, with `:down` low (unloaded pins) |
| `device_pin_open_drain` | `:output_open_drain` with the pull-up: high floats to 1, low reads 0 |
| `device_pin_through_actor` | an ordinary client casts the pin work to the device worker |
| `device_pin_literal` | literal pins: compile-time checked, unchecked runtime entries |
| `device_pin_runtime_bad_pin` | a computed pin that is not a pin: the abort report, status 71 |
| `device_pin_*` without a `.scout` | compile failures: not a pin (E2221), reserved (E2222), unknown or non-literal mode / pull (E2226), read-only (E2227, ESP32-S3), wrong arity (E2005), outside register_rwr, in main (E2219), in a spawn behaviour (E2223), register_rwr at the spawn site, a client declaring register_rwr |
| `pin_outside_device_module` | compile failure: a module without the `device_` prefix |

The console still working at the end of every program is the "reserved pins untouched" check.
