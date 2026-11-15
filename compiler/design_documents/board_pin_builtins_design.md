# Board pin builtins (ESP32-S3 and STM32L476RG): design

Status: design, 2026-11-09 (Lee); implemented 2026-11-10 (§10 records what was decided at
implementation and what is still open).

## 1. Decision

Reading and writing the GPIO pins of a board is a **capability of the two boards' compilers, not a generic
one.** The ESP32-S3_raw and STM32-L476RG_raw compilers provide the same builtins, with the same names and
signatures, so one program source compiles for either board. The three hosted compilers
(apple_silicon_mac, linux_aarch64, linux_x86_64) reject them. The tests are board specific: each board
keeps its own, under its own board tree, and no hosted run executes them.

## 2. The builtins

One flat pin number per board, so the signatures are identical (a Silica program stays free of
conversions: it writes the number in the type the builtin takes, spec design rule "no data type
conversions"). Types below are the proposal; confirm them when the first builtin is implemented.

| Builtin | Meaning |
|---|---|
| `pin_mode(pin: uint32, mode: atom) -> atom` | `:input`, `:output`, `:output_open_drain`. Returns `:ok`. |
| `pin_pull(pin: uint32, pull: atom) -> atom` | `:none`, `:up`, `:down`. Returns `:ok`. |
| `pin_write(pin: uint32, high: boolean) -> atom` | Drive the pin; `true` is high. Returns `:ok`. |
| `pin_read(pin: uint32) -> boolean` | The level on the pin (not the output latch). |

Pin numbering is each board's own flat scheme, fixed by its board pack (`board_pack.silica`), which is the
single authority for which pins exist and which are reserved:
- **ESP32-S3:** the GPIO number (GPIO0..GPIO48 minus the numbers the chip does not have).
- **STM32L476RG:** `16 * port + bit`, port A = 0, B = 1, C = 2, D = 3, H = 7: PA0 = 0, PB0 = 16, PC13 = 45,
  PD2 = 50, PH0 = 112.

Open items for later: alternate functions (`pin_function`), drive strength, analog, interrupts. They are not
part of this design; the four builtins above cover reading and writing every pin.

## 3. Effect and actor

The effect is **`register_rwr`**. It is the existing hardware-access effect of the device-actor specification
(`silica_device_actor_specification.md`), and `device_io` stays the console/file I/O effect; pins use
`register_rwr`, not `device_io`.

The pin builtins appear only inside a `sequence proc[register_rwr] ... produces ... end` in a **device worker
actor's behaviour**, one spawned with `spawn_device` / `spawn_device_registered`. Everything the device-actor
specification already says holds:
- the module that calls them has the `device_` name prefix, and the prefix propagates along `use` to the
  application root;
- the spawn site declares only `concurrency`, not `register_rwr`;
- client actors do not call the builtins; they `cast` to the device worker (`cast_device`,
  `cast_device_registered`) and may do so as often as they like;
- a unit may not use both a `device_*` module and a `dangerous_*` (FFI) module, and a pin sequence may not
  contain `external_danger` values or `dangerous_*` calls.

A pin call outside such a sequence is rejected at compile time by the same checks that reject `peek`/`poke`
there today.

## 4. Gating: boards only

Every emitter has `unsupported_prim_reason(prim_name)` in its `emitter_core.silica`; the driver's pre-emit
pass (`sir_target_verify.silica`) rejects a program that uses a builtin the target answers with a reason
(error E2220). The pin builtins use that gate:
- **apple_silicon_mac, linux_aarch64, linux_x86_64:** `unsupported_prim_reason` returns a reason for each of
  `pin_mode`, `pin_pull`, `pin_write`, `pin_read` ("this target has no GPIO pins"). Nothing else in those
  compilers changes.
- **ESP32-S3_raw, STM32-L476RG_raw:** the reason is empty; the prims live in each emitter's
  `terms/prims/` (a `prims_pin.silica` per board), the register access in each board's runtime.

## 5. Checks

By the "check only when you have to" rule (the error would corrupt data): a pin number is an index that
reaches a register address, so a bad one pokes the wrong word. Therefore:
- **Compile time**, for a literal pin number: the pin must exist on the board, must not be a reserved pin,
  and `mode`/`pull` must be one of the listed atoms. A board with an input-only pin rejects `:output` and
  `pin_write` on it.
- **Run time**, for a pin number that is not a literal: a range check against the board pack's pin table
  before any register access. A bad value is a runtime abort (status 71) in the agreed banner format
  (`runtime_failure_reporting.md`); the reason names the builtin and the number.

**Reserved pins** are the board's own list in the pack, never selectable:
- *STM32L476RG (Nucleo-64):* PA2, PA3 (ST-LINK virtual COM port, the console), PA13, PA14 (SWD), PB3 (SWO),
  PC14, PC15 (32 kHz crystal), PH0, PH1 (clock). PA5 (LED) and PC13 (user button, external pull) are
  allowed; the button cannot pass a pull-down test, which the board's tests account for.
- *ESP32-S3 (the BYU-I e-badge, hardware v4.1.0, ESP32-S3-MINI-1-N8):* see §5.1. Everything the badge's
  working screen, LEDs, buttons, joystick, buzzer, SD card, I2C bus, USB and console use is reserved; the
  pin builtins never touch them and nothing about those subsystems changes.

### 5.1 ESP32-S3 pins on the e-badge

Source: the board's own KiCad schematic, <https://github.com/BYU-I-eBadge/e-badge/tree/main/hardware%20v4.1.0/badge-esp32-s3>
(top-level sheet `badge-esp32-s3.kicad_sch`, sheets `display`, `onboard_peripheral`, `leds`, `audio`,
`sd_card`, `gpio_header_block`, `exposed_pins`, `minibadge`, `uart_interface`; read 2026-11-09). The pin
numbers are the module's GPIO numbers as labelled in that schematic. The on-board buttons, joystick, LEDs and
buzzer reach the module through the 2x15 `gpio_header_block` jumper header (module side `IOn`, peripheral side
`...Mid`); the table lists the pin each peripheral is wired to at that header.

| GPIO | Used by | Class |
|---|---|---|
| 0 | display CS (also the boot-mode strap, `uart_interface` MODE) | reserved |
| 1 | display RST | reserved |
| 3 | display SDA (the display's data line) | reserved |
| 45 | display D/C (also a strapping pin) | reserved |
| 46 | display SCL (the display's clock; also a strapping pin) | reserved |
| 2, 4, 5 | RGB LED red, green, blue | reserved |
| 6 | single LED | reserved |
| 7 | addressable LEDs | reserved |
| 8, 9 | joystick X and Y (analog) | reserved |
| 10, 11, 21, 47 | right, up, left, down buttons | reserved |
| 33, 34 | B and A buttons | reserved |
| 48 | buzzer | reserved |
| 12 | battery voltage sense | reserved |
| 37, 38, 39, 40 | SD card (and the exposed SPI header): MISO, SCLK, MOSI, CS | reserved |
| 41, 42 | I2C SDA and SCL (accelerometer, exposed header, minibadge slots) | reserved |
| 43, 44 | UART0 TXD0 and RXD0 (the console / USB-serial bridge) | reserved |
| 19, 20 | USB D- and D+ | reserved |
| 26 | a module pin tied to the flash/PSRAM group; not wired | reserved |
| 22-25, 27-32 | not present on the module | not a pin: rejected |
| 13, 14, 15, 16, 17, 18 | minibadge slots 1 and 2 (CLK, IO1, IO2 each) | **allowed** (external add-on boards may load them) |
| 35, 36 | exposed header U1TX / U1RX | **allowed** |

So on this board the pin builtins can **write and configure** exactly GPIO13 to GPIO18, GPIO35 and GPIO36.
Every other number is a compile-time error for a literal and a runtime abort otherwise.

**Read-only pins (decided by Lee, 2026-11-09).** `pin_read` may also read the button and joystick pins: GPIO10,
11, 21, 47, 33 and 34 (buttons) and GPIO8 and 9 (joystick X and Y). They are never configured, driven or
pulled by the pin builtins: `pin_mode`, `pin_pull` and `pin_write` on them are rejected like any reserved pin.
`pin_read` only samples the level, so the pin sweep and the board trials can observe the buttons without
changing how the buttons or the joystick work. (The joystick pins are analog inputs; `pin_read` returns the
digital level of the pad.) All other reserved pins reject `pin_read` as well.

**Minibadge pins (decided by Lee, 2026-11-09).** The trials that touch GPIO13 to GPIO18 carry a comment that a
minibadge plugged into slot 1 or 2 can load or drive these lines, so a readback may differ from the written
level when an add-on is fitted; the pass criteria are for an empty slot.

The board pack records this table as the single authority (`board_pack.silica`, reserved-pin table with a
read-only class); the existing display, LED, button and joystick code is not edited by this work.

## 6. Implementation sketch

- **STM32L476RG:** the pack gains GPIOD and GPIOH windows (GPIOA..C exist); the runtime enables the port's
  clock in `RCC_AHB2ENR` on first use of the port. Registers per port: `MODER`, `OTYPER`, `PUPDR`, `IDR`,
  `ODR`, `BSRR`. Writes go through `BSRR` (atomic set/clear). Reads come from `IDR`, which reports the actual
  pin level in output mode too.
- **ESP32-S3:** the GPIO matrix registers (`GPIO_OUT_W1TS/W1TC`, `GPIO_ENABLE`, `GPIO_IN`, the IO_MUX pull
  bits). Pins 32 and up live in the second register bank.
- The shared front end needs the four builtins registered with the device-effect checks (effect, module
  prefix, worker-only), the same way `peek`/`poke` are.

## 7. Tests: board specific, not run by hosted platforms

Each board's tests live in its own board tree (`compiler/src/emitter/<TARGET>/board/tests/`, run by that
board's `tools/`), compiled by that board's compiler, with expected output in a `.scout`. The shared
`trials/` tree and the hosted integrate runs do not contain or run them.

**Pass trials (no wiring; they must run unattended):**
- *Output readback:* for every allowed pin (on the e-badge GPIO13-18, 35 and 36), `pin_mode(:output)`, `pin_write(true)`, read `true`,
  `pin_write(false)`, read `false`.
- *Pulls:* `pin_mode(:input)` with `:up` reads `true` and with `:down` reads `false` on an unloaded pin.
- *Open drain:* `:output_open_drain` with a pull-up reads `true` on write high and `false` on write low.
- *Reserved pins untouched:* the console still works at the end of the run.
- *Through an actor:* a client actor casts commands to a device worker that does the writes and reads.

**Failure trials (compile failure and runtime failure)**, each its own trial:
- a pin number the board does not have; a reserved pin; an unknown `mode` or `pull` atom; `pin_write` or
  `:output` on an input-only pin (ESP32-S3);
- a pin builtin outside a `register_rwr` sequence; in a function that is not a device worker behaviour; in a
  module without the `device_` prefix; with `register_rwr` declared at the spawn site; in a unit that also
  uses a `dangerous_*` module; a client actor declaring `register_rwr`;
- run time: a non-literal pin number out of range gives the abort 71 report (the sweep trial passes the value
  in from a message).

Compile-failure trials follow the existing compile-defect conventions: one trial per directory so one
rejected unit does not abort a batch.

**Hosted rejection (decided: yes, 2026-11-09):** a handful of compile-failure trials in the shared `trials/` tree
check that the three hosted compilers reject each builtin with E2220. They run on hosts and need no board.
They are the only part of this work the hosted platforms run.

Optional, manual, not part of any run: a wired fixture (a jumper between two pins) testing real input and
crosstalk.

## 8. Error codes

New diagnostics (unknown pin, reserved pin, bad mode/pull atom, input-only pin) take the next free numbers in
the device range of `error_codes.md`; the codes are assigned when the checks are written and the failure
trials name them. E2220 is the existing code for a target that lacks the builtin.

## 9. Order of work

1. Finish the Nucleo actor groups (messaging, failure handling, supervisors, timers, policies and priorities,
   small entries) and FFI/device behaviours (Lee, 2026-11-09).
2. Add the four builtins, front end first (registration with the device checks), then the Nucleo, then the
   ESP32-S3, then the hosted `unsupported_prim_reason` entries.
3. Board packs: GPIOD/GPIOH windows and the reserved-pin tables.
4. Each board's tests and failure trials, then a board run.
5. This document is updated with what was decided at implementation (types, codes, pin numbering).

## 10. Implementation (2026-11-10)

What the code does, where it lives, and the choices made while writing it. Items marked *(to confirm)*
are implementation choices Lee has not reviewed yet.

**Types (as proposed in §2, kept).** `pin_mode(pin: uint32, mode: atom) -> atom`, `pin_pull(pin: uint32,
pull: atom) -> atom`, `pin_write(pin: uint32, high: boolean) -> atom`, `pin_read(pin: uint32) -> boolean`.
The first three answer `:ok`.

**Mode and pull are atom literals** *(to confirm)*. The checker accepts only the listed atoms written as
literals (a variable is rejected, E2226), the same rule as a register name in `peek` / `poke`. The SIR then
carries a small code instead of the atom (mode `:input` 0, `:output` 1, `:output_open_drain` 2; pull
`:none` 0, `:up` 1, `:down` 2), so no emitter or runtime decodes an atom index, and a wrong atom cannot
reach a register (§5: it would write the wrong bits).

**Pin numbering (as §2).** ESP32-S3: the GPIO number. STM32L476RG: `16 * port + bit`, A = 0, B = 1, C = 2,
D = 3, H = 7 (PD2 = 50, PH0 = 112, PH1 = 113). The board pack's `pin_class(pin)` is the single authority:
0 not a pin, 1 reserved, 2 read-only (`pin_read` only), 3 usable; `pin_use(pin)` names what a reserved pin
is wired to, `pin_number_limit()` is one past the highest number, `pin_numbering()` is the diagnostics'
one-line summary. The older `pin_is_reserved` of the ESP32-S3 pack is the bring-up apps' narrower rule and
is not consulted by the builtins.
- STM32L476RG (LQFP64): usable are PA0-PA15, PB0-PB15, PC0-PC15 and PD2, less the reserved PA2, PA3, PA13,
  PA14, PB3, PC14, PC15, PH0, PH1: 42 pins. No read-only pins.
- ESP32-S3 e-badge: the §5.1 table exactly (usable GPIO13-18, 35, 36; read-only 8, 9, 10, 11, 21, 33, 34, 47;
  22-25 and 27-32 not pins; every other number up to 48 reserved).

**Error codes** (the next free numbers of the device range, `error_codes.md`):

| Code | Name | Where |
| --- | --- | --- |
| E2221 | PinNotOnBoard | pre-emit pass, literal pin, `pin_class` 0 |
| E2222 | PinReserved | pre-emit pass, literal pin, `pin_class` 1 |
| E2226 | PinModeOrPullUnknown | type checker: mode / pull not one of the listed atom literals |
| E2227 | PinReadOnly | pre-emit pass: `pin_mode` / `pin_pull` / `pin_write` on a `pin_class` 2 pin (this is the "input-only pin" check of §5; neither board has a pin the chip itself makes input-only, so the read-only class is what it rejects) |
| E2220 | PrimNotCompilableForTarget | the hosted emitters ("this target has no GPIO pins") |

The placement, effect and module rules are the device prims' own codes, unchanged: E2216 (outside a
`device_*` module, with a pin-specific message), E2219 (in `main`), E2223 (in a `spawn` behaviour), E2232
(`register_rwr` outside a `device_*` module), E2217 (a `device_*` module defining a function named
`pin_mode` ...), E3xxx for a missing `register_rwr`.

**Where the checks run.** The atoms, the arity and the argument types are checked by the shared type checker
(`type_checker_expressions_device.silica`, `check_pin_call`). Whether a literal pin exists, is reserved or is
read-only is the target's question, so it is answered before emission by the driver's pre-emit pass
(`sir_generator/sir_target_verify.silica`, `verify_pin_literal`), which asks the target's
`emitter_core@pin_literal_reason` / `pin_literal_code` (board emitters: `terms/prims/prims_pin.silica` over
`board_pack@pin_class`; hosted emitters: never reached, they answer E2220 first). The diagnostic names the
module, the function, the builtin and the pin.

**Run time.** A literal pin calls the runtime's unchecked entry (`silica_rt_pin_<builtin>_lit`); a computed
pin calls the checked entry (`silica_rt_pin_<builtin>`), which tests the pin against the runtime twin of
`pin_class` (`silica_rt_pin_class`) and otherwise ends the program with the abort report
`[silica] abort: <builtin>: pin <n> is not a pin it may use on this board at <site>`, status 71, even inside
an actor (as `illegal device map` does). STM32: `board/runtime/rt_support.S` (the port's clock on in
`RCC_AHB2ENR` at every call, MODER / OTYPER / PUPDR read-modify-writes, BSRR, IDR). ESP32-S3:
`board/runtime/rt_board.S` (IO_MUX: GPIO function and input buffer on in `pin_mode`, pulls in `pin_pull`;
matrix: FUNCn_OUT_SEL = GPIO_OUT, PINn open drain, ENABLE / OUT set-clear words, IN / IN1, bank 1 from
GPIO32); `pin_read` changes no configuration, so on the read-only pins it only samples.

**Front end.** The four names are device prims everywhere the device prims are listed: the type checker
(`is_device_prim_name`), the effect checker (`register_rwr`), the module checker (E2217), the SIR generator
(`sir_device_calls.silica` `build_pin`, and the runtime-prim list of `sir_generator_core`). SIR shapes:
`pin_mode` / `pin_pull` — kind 6, inner = the pin (uint32), right = the code constant; `pin_write` — right =
the level (bool); `pin_read` — typed bool. In the board emitters they are device prims too
(`prims_device@is_device_prim`): the pin is staged in X1, `pin_write`'s level in X2.

**Board packs.** STM32: windows 12 `:stm32l4_gpiod` (0x48000C00) and 13 `:stm32l4_gpioh` (0x48001C00), the pin
table above; hand-written device descriptions from RM0351 in `board/pack/` (`device_stm32l4_<gpioa..d, gpioh,
rcc, usart2>_registers`), listed in `pack_descriptions.silica`. ESP32-S3: the pin table; nothing about the
display, LED, button, joystick or buzzer code changed.

**Tests.** Board-specific, in `compiler/src/emitter/<TARGET>/board/tests/pins/`, run by that board's
`board/tools/run_pin_tests.sh` (through `trials/targets/board_suite.sh`); no hosted run executes them. Hosted
rejection: `trials/error_enforcement_addition/device_pin_<builtin>_hosted_rejection_trial` (E2220 on Mac,
pix and nix).

**Results (2026-11-10).** ESP32-S3 e-badge (empty minibadge slots): 22 of 22 (7 programs, 15 compile
failures). NUCLEO-L476RG: 18 of 18 (6 programs, 12 compile failures); B1 (PC13) reads high with the chip's
pull-down, as §5 expected. Hosted: the four E2220 trials pass on the Mac with a compiler built from this
tree (pix and nix goldens are derived, not yet run).

**Found while testing, fixed with a trial each** (outside the pin code): a guarded case arm whose guard
calls a function lost its scrutinee (every emitter; `case_addition/case_guard_call_keeps_scrutinee`); a
64-bit let in a uint32 function did not assemble (every emitter;
`functions_addition/let_wide_rhs_in_uint32_function`); the board copiers walked list chunks with CDATA =
2 * slot instead of max(16, slot) (both board runtimes); the STM32 runtime stored narrow list elements as
two words (`list_literal_from_atom_case_addition`).

**Open.** The optional wired fixture (§7) is not written. `pin_read` on an ESP32-S3 pad whose input buffer
is off reads 0; the builtins do not switch the buffer on for a read-only pin (the buttons' configuration is
not touched).

