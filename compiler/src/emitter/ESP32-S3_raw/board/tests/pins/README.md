# Board pin builtin tests (ESP32-S3 e-badge (hardware v4.1.0))

Board-specific tests of `pin_mode`, `pin_pull`, `pin_write` and `pin_read`
([board_pin_builtins_design.md](../../../../../../design_documents/board_pin_builtins_design.md) §7).
They live in this board's tree, are compiled by this board's compiler and are run by this board's
`tools/run_pin_tests.sh`; the shared `trials/` tree and the hosted integrate runs do not contain or run
them (the hosted rejection trials are `trials/error_enforcement_addition/device_pin_*_hosted_rejection_trial`).

Pins are the module's GPIO numbers. The builtins may configure and drive GPIO13-GPIO18 (the minibadge slots) and GPIO35, GPIO36 (the exposed U1TX / U1RX header); `pin_read` may also read the buttons (GPIO10, 11, 21, 33, 34, 47) and the joystick (GPIO8, 9). Every other pin is reserved (display, LEDs, buzzer, SD card, I2C, UART0, USB) or not a pin. **Minibadge note:** a minibadge plugged into slot 1 or 2 can load or drive GPIO13-GPIO18, so a readback may differ from the written level when an add-on is fitted; the pass criteria are for empty slots.

```
compiler/src/emitter/ESP32-S3_raw/board/tools/run_pin_tests.sh             # every test here, on the board
compiler/src/emitter/ESP32-S3_raw/board/tools/run_pin_tests.sh <stem>      # one test
```

The layout is a trial suite's (`trials/targets/board_suite.sh` runs it): `<stem>.silica` with
`<stem>.ESP32-S3_raw.scout` and `<stem>.wait_for_exit` is a program run on the board (they need no wiring and run
unattended); `<stem>.silica` with `<stem>.ESP32-S3_raw.golden_fail` is a compile-failure trial, compiled alone;
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
