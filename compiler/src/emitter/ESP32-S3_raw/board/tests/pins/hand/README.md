# Hand-run pin apps (ESP32-S3 e-badge, hardware v4.1.0)

These programs need a person at the board and a jumper wire, so they are not trials: there are no goldens and no
`.wait_for_exit` files, `run_pin_tests.sh` does not look in this directory, and no suite runs them. They are the
e-badge counterparts of the NUCLEO-L476RG hand apps (`STM32-L476RG_raw/board/tests/pins/hand/`) and test
`pin_mode` / `pin_pull` / `pin_write` / `pin_read` with the pin tied to GND, tied to 3V3, or tied to another pin.
Each file name starts with `device_` because the module calls the pin builtins (E2232 otherwise).

The display, LEDs, buzzer, buttons, joystick and everything the working screen uses are never touched: the apps
use GPIO35 and GPIO36 only (both on the exposed `J3` header, no other function). The pull-the-jumper cue is
console text only (the NUCLEO apps blink LD2; here no LED is used).

## Wiring (all on the badge's bottom edge: J9, J3, J11 from left to right)

Pin numbers are the header's own (KiCad `J3`, `J11`); the silkscreen labels are in quotes. `J3` is a 2x6 socket,
odd pins on one row and even pins on the other; its even row reads `5V, SCL, GND, U1TX, U1RX, GND` (pins 2, 4, 6,
8, 10, 12) and its odd row `3.3V, SDA, GND, CLK, MISO, MOSI` (pins 1, 3, 5, 7, 9, 11).
Orient the board so the silkscreen reads upright and look at the row that carries "U1TX", "U1RX".

| App | Jumper between | Notes |
| --- | --- | --- |
| `device_grounded_35` | GPIO35 = J3 pin 8 "U1TX" and GND = J3 pin 6 "GND" (the next pin in the same row) | a 2.54 mm shunt across pins 6 and 8, or a wire; pulled out during the run (the console says when) |
| `device_power_36` | GPIO36 = J3 pin 10 "U1RX" and 3V3 = J11 pin 4 or 3 "3.3V" (middle column of the 2x3 header) | wire, in for the whole run; the column to its right is "5Vn" (5 V): do not use it |
| `device_twopin_35_drives`, `device_twopin_36_drives` | J3 pin 8 "U1TX" (GPIO35) and J3 pin 10 "U1RX" (GPIO36): ONE jumper, nothing else | a shunt across pins 8 and 10 (adjacent, same row), in for both programs |

Nothing else may be connected to J3 (no serial adapter on U1TX/U1RX). Do not put wire ends into J3 pins 3, 4, 7,
9, 11 (I2C and the SD card's SPI): they are in use by the accelerometer and the SD card. Why these pins: GPIO35/36 are wired only from the module to J3 (no resistor, LED, level shifter, pull or strapping function), and
J3 has GND on both outer pins of the row (6 and 12).

## device_grounded_35

GPIO35 tied to GND at the start. Ten steps in two phases.

| Phase | Steps (expected read) |
| --- | --- |
| 1, jumper IN | 1 pull up (0), 2 pull down (0), 3 no pull (0), 4 push-pull LOW (0), 5 open drain released + pull up (0) |
| hold | `phase 1 done, keep jumper IN, wait 5 s` |
| wait, 30 s | the console prints a banner and then `>>> PULL THE JUMPER FROM GPIO35 NOW: N s left <<<` once a second: pull the jumper now |
| 2, jumper OUT | 6 pull up (1), 7 pull down (0), 8 open drain released + pull up (1), 9 push-pull HIGH (1), 10 push-pull LOW (0) |
| end | `SUMMARY: P passed, F failed of 10`, then `DONE`, exit status 0 |

Safety: phase 1 never drives push-pull HIGH (the latch is written LOW before every mode change). Step 9 drives
push-pull HIGH only if step 6 read 1; if the jumper is still in, step 9 is skipped and counted as a failure.
Each step waits 20 ms after configuring before it reads.

## device_power_36

GPIO36 tied to 3V3 for the whole run (one phase, no pull-out step).

| Step | Configuration | Expected read |
| --- | --- | --- |
| 1 | input + pull up | 1 |
| 2 | input + pull down | 1 (3.3 V overpowers the internal pull-down) |
| 3 | input + no pull | 1 |
| 4 | open drain released (latch HIGH) + pull up | 1 |
| 5 | open drain released (latch HIGH) + pull down | 1 |

Safety rules (GPIO36 is tied to 3.3 V, so an output sinking current would be a short):
- never drive GPIO36 LOW: the code has no `pin_write(36, false)`;
- never make GPIO36 a push-pull output: the code has no `pin_mode(36, :output)`;
- never open drain with the latch LOW: every step writes the latch HIGH before it configures the pin
  (`pin_write` writes the output register in any mode), and `pin_mode` sets the pad's open-drain bit before the
  output enable (`rt_board.S`), so the switch goes straight to "open drain, released";
- the program starts and ends with GPIO36 an input, latch HIGH, no pull.

## device_twopin_35_drives and device_twopin_36_drives

Two pins tied together; run A, then B (two loads, the jumper stays in).

A, `device_twopin_35_drives` (14 steps, only GPIO35 is ever an output):

| Steps | Driver | Reader | Expected |
| --- | --- | --- | --- |
| 1-6 | GPIO35 push-pull HIGH / LOW | GPIO36 with no pull, pull up, pull down | the driver wins: 1 / 0 |
| 7-8 | nobody (GPIO35 input, no pull) | GPIO36 pull up / pull down | the pull wins on the floating net: 1 / 0 |
| 9-11 | GPIO35 open drain LOW / released | GPIO36 pull up; released also with pull down | 0; 1 / 0 |
| 12-13 | GPIO35 push-pull HIGH / LOW | GPIO35 reads its own pad | 1 / 0 |
| 14 | GPIO35 push-pull, 8 HIGH/LOW pairs | GPIO36 after every write | 16 of 16 match |

B, `device_twopin_36_drives` (8 steps, only GPIO36 is ever an output):

| Steps | Driver | Reader | Expected |
| --- | --- | --- | --- |
| 1-6 | GPIO36 push-pull HIGH / LOW | GPIO35 with no pull, pull up, pull down | 1 / 0 |
| 7-8 | GPIO36 push-pull HIGH / LOW | GPIO36 reads its own pad | 1 / 0 |

Safety rules (the pins are tied together, so two outputs at once can be a short):
- at most one of the two pins is ever in an output mode, and in each program only one pin (A: GPIO35, B: GPIO36)
  appears in a `pin_mode(_, :output)` / `:output_open_drain` call; the reader is only an input;
- every step starts with `release_all`: each pin gets latch HIGH, input, no pull, GPIO35 first and then GPIO36;
- then the reader's pull, then the driver's latch (written while it is still an input), then its mode, so
  push-pull or open-drain LOW only ever drives against an input;
- both programs end with both pins as inputs, latch HIGH, no pull.

## Console format

One line per step: `step N: <what>: read V, expect E: PASS` (or `FAIL`), then `SUMMARY: P passed, F failed of N:
ALL PASS` (or `FAILURES`) and `DONE`. `run_hand_app.sh` counts the step lines ending in `: PASS` / `: FAIL`.

## Running

Build and check everything without touching the board (any time, also while the board is in use):

```
compiler/src/emitter/ESP32-S3_raw/board/tests/pins/hand/run_hand_app.sh --build-only device_grounded_35
```

A real run (Lee at the board, the jumper in as the table says BEFORE the run):

```
compiler/src/emitter/ESP32-S3_raw/board/tests/pins/hand/run_hand_app.sh device_grounded_35
compiler/src/emitter/ESP32-S3_raw/board/tests/pins/hand/run_hand_app.sh device_power_36
compiler/src/emitter/ESP32-S3_raw/board/tests/pins/hand/run_hand_app.sh device_twopin_35_drives
compiler/src/emitter/ESP32-S3_raw/board/tests/pins/hand/run_hand_app.sh device_twopin_36_drives
```

`run_hand_app.sh` (macOS, bash) compiles with the installed `binaries/silica-compiler-ESP32-S3_raw`, builds the RAM
image with `board/tools/build_image.sh`, refuses to go on while another board run is active (the
`trials/.integrate.lock.ESP32-S3_raw` lock, `trials/.board.lock`, processes of the board tools, the serial port in
use), takes the target's trial lock, writes `RUN STARTING, jumper must be IN between <pins>` to the status file
`/private/tmp/claude-501/-Volumes-2T-silica/e3b4f0ea-081d-496d-bfaa-fe5a90e42862/scratchpad/esp_status.txt`,
waits 15 s (`--pause S`), checks again, loads the image (`stream_on_board.py`, which is `tools/run_on_board.py`
with a live console), and streams the console. On `PULL THE JUMPER` (first line, and again at `10 s left`) and on
`DONE` it plays `/System/Library/Sounds/Glass.aiff` and posts a macOS notification; at the end it writes
`DONE: <p> PASS, <f> FAIL` to the status file. Exit status 0 means DONE with no FAIL step.

The image is loaded into RAM (nothing is written to flash), as the pin trials do.
