# Hand-run pin apps (NUCLEO-L476RG)

These programs need a person at the board and a jumper wire, so they are not trials: there are no goldens and no
`.wait_for_exit` files, `run_pin_tests.sh` does not look in this directory, and no suite runs them.

## device_grounded_pa6

Tests `pin_mode` / `pin_pull` / `pin_write` / `pin_read` on PA6 (flat pin 6, Arduino D12 / MISO).
The file name starts with `device_` because the module calls the pin builtins (E2232 otherwise).

Wiring at start: a jumper from PA6 (CN5 D12, or CN10 pin 13) to GND.

| Phase | LD2 (PA5) | Steps (expected read) |
| --- | --- | --- |
| 1, jumper IN | solid on | 1 pull up (0), 2 pull down (0), 3 no pull (0), 4 push-pull LOW (0), 5 open drain released + pull up (0) |
| wait, 20 s | blinks at 4 Hz | console prints `>>> PULL THE JUMPER FROM PA6 NOW: N s left <<<` once a second: pull the jumper now |
| 2, jumper OUT | off | 6 pull up (1), 7 pull down (0), 8 open drain released + pull up (1), 9 push-pull HIGH (1), 10 push-pull LOW (0) |
| end | three slow blinks | `SUMMARY: P passed, F failed of 10`, then `DONE` and exit status 0 |

Safety: phase 1 never drives push-pull HIGH (the latch is written LOW before every mode change).
Step 9 drives push-pull HIGH only if step 6 read 1; if the jumper is still in it is skipped and counted
as a failure. Each step waits 20 ms after configuring before it reads.

## device_power_pa6

PA6 tied to 3.3 V. Wiring: a jumper from PA6 (CN5 D12) to **3V3 (CN6 pin 4), NOT 5V**, installed before
the program is loaded and left in for the whole run (one phase, no pull-out step).

| Step | Configuration | Expected read |
| --- | --- | --- |
| 1 | input + pull up | 1 |
| 2 | input + pull down | 1 (3.3 V overpowers the ~40 kOhm pull-down) |
| 3 | input + no pull | 1 |
| 4 | open drain released (latch HIGH) + pull up | 1 |
| 5 | open drain released (latch HIGH) + pull down | 1 |

LD2: solid ON while reading and for a 5 s hold after `SUMMARY`, then three slow blinks, `DONE`, exit 0.

Safety rules (PA6 is tied to 3.3 V, so an output sinking current would be a short):
- never drive PA6 LOW: the file contains no `pin_write(6, false)`;
- never make PA6 a push-pull output: the file contains no `pin_mode(6, :output)`;
- never open drain with the latch LOW: every step writes the latch HIGH (BSRR, valid in any mode) before
  it configures the pin, and `pin_mode` writes OTYPER before MODER (`rt_support.S`), so the switch goes
  straight to "open drain, released";
- the program starts by putting PA6 into input mode, latch HIGH and no pull, and ends the same way.
  Before inserting the jumper, make sure the previous program left PA6 as an input (both apps here end
  that way).

## device_twopin_pa6_drives and device_twopin_pa7_drives

Two pins tied together. Wiring: ONE jumper between D12 (PA6, pin 6) and D11 (PA7, pin 7), nothing else,
installed before loading and left in for both programs. Run A, then B (two loads).

A, `device_twopin_pa6_drives` (14 steps, only PA6 is ever an output):

| Steps | Driver | Reader | Expected |
| --- | --- | --- | --- |
| 1-6 | PA6 push-pull HIGH / LOW | PA7 with no pull, pull up, pull down | the driver wins: 1 / 0 |
| 7-8 | nobody (PA6 input, no pull) | PA7 pull up / pull down | the pull wins on the floating net: 1 / 0 |
| 9-11 | PA6 open drain LOW / released | PA7 pull up; released also with pull down | 0; 1 / 0 |
| 12-13 | PA6 push-pull HIGH / LOW | PA6 reads its own pad | 1 / 0 |
| 14 | PA6 push-pull, 8 HIGH/LOW pairs | PA7 after every write | 16 of 16 match |

B, `device_twopin_pa7_drives` (8 steps, only PA7 is ever an output):

| Steps | Driver | Reader | Expected |
| --- | --- | --- | --- |
| 1-6 | PA7 push-pull HIGH / LOW | PA6 with no pull, pull up, pull down | 1 / 0 |
| 7-8 | PA7 push-pull HIGH / LOW | PA7 reads its own pad | 1 / 0 |

LD2: solid ON while running and for a 5 s hold after `SUMMARY`, then three slow blinks, `DONE`, exit 0.

Safety rules (the pins are tied together, so two outputs at once can be a short):
- at most one of the two pins is ever in an output mode, and in each program only one pin (A: PA6, B:
  PA7) appears in a `pin_mode(_, :output)` / `:output_open_drain` call; the reader is only an input;
- every step starts with `release_all`: each pin gets latch HIGH, input, no pull, PA6 first and then PA7.
  The previous step left at most one output, and a pin whose latch goes HIGH while it is still an output
  only drives HIGH against an input;
- then the reader's pull, then the driver's latch (written while it is still an input), then its mode
  (`pin_mode` writes OTYPER before MODER), so push-pull or open-drain LOW only ever drives against an input;
- both programs end with both pins as inputs, latch HIGH, no pull.

Why two programs: the combined 22-step program (`unbuilt/device_twopin_pa6_pa7.silica.combined`, object
36.4 KB) failed the image link (`program too large: less than 16 KiB left for the heap`, the assert in
`board/runtime/silica_stm32l476rg.ld`). The split programs are built from flat per-step literal cases like
`device_power_pa6`, not the combined file's table machinery: A's object is 28.5 KB (heap 21,168 bytes), B's
25.4 KB (heap 24,320 bytes).

Results (2026-11-10, compiler silica-999991): A 14 of 14, B 8 of 8.

## Building and running

Build and run by hand (from a scratch directory; for the power app substitute `device_power_pa6`):

```
cp <this dir>/device_grounded_pa6.silica compiler/stdlib/Supervisor.silica trials/lib_trial_support/trial_wait_int64.silica .
printf 'device_grounded_pa6.silica\ntrial_wait_int64.silica\nSupervisor.silica\n' > silica.config
binaries/silica-compiler-STM32-L476RG_raw
T=compiler/src/emitter/STM32-L476RG_raw/board/tools
sh $T/build_image.sh -r .rt --prepare
sh $T/build_image.sh -q -r .rt -o build/pa6 device_grounded_pa6.sams Supervisor.sams trial_wait_int64.sams __silica_runtime.sams
<board python> $T/run_on_board.py --port /dev/cu.usbmodem21103 --timeout 120 --out pa6.sout build/pa6.elf
```
