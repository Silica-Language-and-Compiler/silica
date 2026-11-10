# `emitter/ESP32-S3_raw/board/` — bare-metal ESP32-S3 board pack

Everything the `ESP32-S3_raw` emit target needs besides the emitter itself: the runtime a
compiled program links against, the memory map, the image, run and comparison tools, the
generated board-pack modules, and the sample apps used to bring the port up and to exercise it on
the board. None of it is compiled by the Silica compiler build (`topo_silica_config` only lists the
compiler's own `.silica` units, and the topo script prunes `board/apps`); the runtime is assembled
with Espressif's Xtensa GCC toolchain when an image is built.

What the port has of the host's behaviours, where a program sees a difference on the board, and what is
still missing is kept in
[design_documents/ports/esp32s3_port_status.md](../../../../design_documents/ports/esp32s3_port_status.md).

The port was tested on the board described in
[PORT_TEST_BOARD_byu_idaho_v4.0_feb26.md](PORT_TEST_BOARD_byu_idaho_v4.0_feb26.md) (a BYU-I eBadge
v4.0). Pin numbers in the apps follow that file's J4 table, which comes from the board's design
netlist; the supplied pin sheet has the RGB red pin wrong (1 instead of 2).

## Layout

| Path | What |
| --- | --- |
| `runtime/rt_vectors.S` | Exception vectors: windowed-ABI overflow/underflow handlers (from ESP-IDF), alloca, the fatal-fault and runtime-abort trampolines |
| `runtime/rt_start.S` | `_start`: interrupts off, VECBASE, fresh window, own stack, watchdogs off, zero `.bss` + heap, `main`, exit marker |
| `runtime/rt_console.S` | UART0 output (raw FIFO writes), the `print_*` routines (`*_stderr` is the same routine: one console), `exit`, the runtime-abort entries (`silica_rt_abort_*`), `badarith` / `case_clause`, the fatal fault report; UART0 input: the `exit` line reader core 0's scheduler polls (`silica_rt_console_poll_exit_line`) |
| `runtime/rt_string.S` | String routines (`silica_rt_string_*`): concat, lengths, eq/cmp, predicates, substring |
| `runtime/rt_list.S` | List routines (`silica_rt_list_*`): length, tail, at, prepend over the emitter's chunked lists |
| `runtime/rt_transport.S` | The transport builtins that touch a string or a list (`silica_rt_tr_*`: byte_at, byte_slice, bytes_of, join_bytes, atom_name, atom_index_of_name; transport_serialization_design.md §9.2); the emitter's `terms/prims/prims_transport.silica` calls them, the scalar transport prims are register work there |
| `runtime/rt_float.S` | Float printing (host digit algorithm, including the host's `FCVTZS` behaviour on nan/inf; float64 via libgcc, float32 on the FPU), half conversions, truncation, float16 → int32 for a float16 exit code |
| `runtime/rt_ordering.S` | Ordering identity tokens, canonical arenas (stdlib data structures), checked int64 add/mul |
| `runtime/rt_heap.S` | Heap: first-fit free list with coalescing over a bump top (8-byte block headers); `silica_rt_free` and region release (`silica_rt_region_destroy`, the extension chain too) give memory back; exhaustion is a runtime abort |
| `runtime/rt_board.S` | Plain GPIO output/input/read/write, `delay_us`, cycle counter (used by the `asm_*` apps) |
| `runtime/rt_device.S` | `map_device` window check for a computed base (`silica_rt_map_device_check`): the run-time twin of the window table in `../board_pack.silica`; a base outside every window is the runtime abort `illegal device map` |
| `runtime/rt_actors.S` | The actor runtime on both LX7 cores: cooperative per-core scheduler with the four dispatch-order policies of `set_scheduler_policy` (priority FIFO, round robin, weighted fair, lottery), control blocks, mailboxes, spawn/send/cast/call/self, the PID registry actor, remove/kill, actor failure reports and their delivery to a registered FailureReporter, the root-exit note, migrate_actor and the topology queries, the chunked actor stacks (`silica_rt_stack_grow`, `silica_rt_aux_grow`), wait_for_exit and cast_exit (main's wait returns the value of the first cast_exit request, or 0 for a console `exit` line read by core 0's scheduler; the program ends when main returns; an idle program waits, spec §15.1.2.5), core 1's entry into its scheduler ([design §8](../../../../design_documents/ports/esp32s3_xtensa_port.md)) |
| `runtime/rt_supervisors.S` | The supervisor child table: start trampoline materialisation, restart policies and strategies, the `call_supervisor` helpers |
| `runtime/silica_esp32s3.ld` | Linker script: code from IRAM 0x40378000, data after it on the D-bus (the emitter's function-name records first), `main`'s auxiliary stack, heap, `main`'s machine stack below 0x3FCE9700; both stacks sized per image (`_silica_main_stack_size`, `_silica_main_aux_size`, see "Stack budget") |
| `tools/run_app.sh` | Builds one app under `apps/` in a temporary directory and runs it on the board, then compares the output with the app's `expected.scout` (see "Running the Silica applications on the board") |
| `tools/build_image.sh` | Assemble sources + runtime, link twice (the second time with `main`'s stack sizes from `main_stack_bound.py`), `esptool elf2image` → `.elf`, `.map`, `.bin`, `.stack`; `-r <dir>` caches the assembled runtime (reassembled only when a runtime source is newer), `--prepare` fills that cache, `-q` prints nothing on success |
| `tools/main_stack_bound.py` | Static stack bound of a linked image: the deepest chain of windowed frames from `_start` and the deepest auxiliary-stack reservation, the runtime depth reserve, and (`--root`, `--report`, `--list`) the same for any function |
| `tools/run_on_board.py` | Load `.bin` into RAM and run it (or `--flash` it at 0x0, or `--no-flash` to rerun what is in flash), capture UART0 between the markers, print `.sout`-style text (`--out FILE` writes it); `--send TEXT` writes to the console's receive side (the program's standard input) `--send-delay` seconds (default 1) after the start marker; `--timeout` (default 60 s); `--probe` checks the board; `--list-ports` prints the candidate ports. The RAM load ends with `MEM_END` sent without waiting for its response, so esptool's reader cannot swallow the program's first bytes (the start marker) when the host is slow |
| `tools/usb_console_check.py` | Gate check for the second console (plan item F): runs `run_app.sh` for `silica_31_device_usb_console` (options pass through; `--port` / `$BOARD_PORT` is the UART0 port) while it waits for the USB-Serial-JTAG CDC port (found by USB id 303A:1001 on every open, since the node reappears, possibly renamed, after the chip resets; `--usb-port` is only a check and another id is refused; no device present is reported as such), opens it with DTR/RTS left high (setting them low before the open resets the chip on macOS), writes `A` until it reads the expected reply (`--expect`), and prints both consoles; the USB phase starts only at `run_app.sh`'s `running ... on the board` line (the port is not touched during the esptool connect and load) and `--usb-timeout` (default 60 s) counts from that line; exit 0 only when the UART0 run matched and the USB reply arrived (8 = UART0 matched, no USB reply). Needs pyserial: run it with `$BOARD_PYTHON` |
| `tools/compare_sout.sh` | Compares a board run's `.sout` with an `expected.scout` the way the trial harness does (fatal-report addresses folded) |
| `tools/host_reference.sh` | Writes an app's `expected.scout` by building and running it with the macOS compiler (fatal-report lines folded) |
| `tools/gen_board_pack.py` | Generates `pack/board_pack_<peripheral>_values.silica`, `pack/device_esp32s3_<peripheral>_registers.silica` and `pack/board_pack_gpio_signals.silica` from the ESP-IDF register headers (default IDF tree `/Volumes/2T/silica-esp-idf`); `--check` regenerates into a temporary directory and diffs against the tree |
| `pack/` | The generated per-peripheral register and value modules (GPIO, IO_MUX, UART0, UART1 (description only: its field constants are UART0's, the same `uart_reg.h` layout), SPI2, SYSTEM, LEDC, RMT, USB-Serial-JTAG) the device drivers use; do not edit by hand |
| `apps/device_lib/` | Device-worker drivers written in Silica (GPIO, UART0, the UART1 `(:uart1)` transport carrier (`device_esp32s3_uart1`: the carrier actor contract of `transport_serialization_design.md` §6.2 on the UART1 header, GPIO35 TX / GPIO36 RX), USB-Serial-JTAG (`device_esp32s3_usb_serial_jtag`: the item F console worker `usb_serial_jtag_worker` and the `(:usb_serial_jtag)` transport carrier `usb_serial_jtag_carrier`, the §6.2 contract both ways on the native USB-C jack), SPI2/ST7789 display, LEDC/buzzer, RMT/WS2813B LED row) |
| `apps/silica_*` | Silica sample apps, each with the `expected.scout` from the macOS compiler, except `silica_20`, `silica_25` and `silica_26`, `silica_27` (hardware-dependent output: button presses, register dumps, pad levels). Device apps (`silica_16` on) cannot run on the host (E2220: `poke` cannot be compiled for apple_silicon_mac), so the `expected.scout` of `silica_23`, `silica_24` and `silica_28` is written from the source. `silica_32` is the UART1 transport demo; the USB-C transport demos (formerly `silica_33`) are board/Mac pairs in `examples/transport_pairs/` at the repository root, each a board program directory that `tools/run_app.sh` builds from its path, with its Mac peers and a run script |
| `apps/asm_*` | Bring-up apps in hand-written Xtensa assembly (runtime and board checks, no compiler involved) |
| `tests/xt_helpers_selftest/` | 408-case hardware self-test of the emitter's Xtensa instruction helpers (`shared/xt_*.silica`) |

The window table the emitter checks a constant `map_device` base against is `../board_pack.silica`
(emitter code, beside this directory); `runtime/rt_device.S` holds the same table for computed bases.
When one changes, the other changes.

## Image model

The image is built to be flashed at offset **0x0**, where the second-stage bootloader normally lives,
or loaded straight into RAM through the ROM's download mode (what `run_on_board.py` and the trials
do by default: nothing is written to flash). Either way the ESP32-S3 ROM loads its RAM segments and
calls `_start`; there is no ESP-IDF bootloader, no FreeRTOS and no
flash cache mapping, so the whole program (code + data + heap + stack) must fit in about 390 KB of
internal SRAM. Larger programs need a flash-XIP layout (future work).

Rules the emitter must follow (they come from the Xtensa windowed ABI and this memory map):

- Every function starts with `entry a1, N` and must be 4-byte aligned (`.align 4` before each label;
  the assembler rejects an unaligned `entry`).
- Nothing is ever stored below SP: the 16 bytes under SP receive the caller's `a0`–`a3` on a window
  overflow. The top 16 bytes of a frame are the base save area and, in a function that makes CALL8
  calls, the next 16 receive its own `a4`–`a7`. Locals live below `sp + N - 32`.
- Outgoing stack arguments go at `[sp + 0 ...]`; a callee reads them at `[sp + N + 0 ...]`.
- All data (strings, tables, `.rodata`) goes in data-bus sections. Only code and `L32R` literal pools
  go on the instruction bus, which faults on byte and halfword loads.

## Console protocol

```
\x02SILICA:START\x03<program output>\x02SILICA:EXIT:<status>\x03[ fault: exccause=.. epc=.. excvaddr=..[ (stack guard ...)]]
[silica] stacks: machine <used>/<size> aux <used>/<size> actors <n> actor-max machine <b> aux <b> sup-max machine <b> aux <b>
```

`status` is the low byte of `main`'s result, like a host exit code. `run_on_board.py` turns the
text between the markers into `<program output><status>\n`, the same text the trial harness writes to
a `.sout`; whatever follows the exit marker (the board-only fault details and the stacks line, see
"Stack budget") goes to its stderr.

### Process failures

A process that ends abnormally reports it the way every Silica target does (spec §15.4.5.5; the
mechanism on each target is in
[design_documents/runtime_failure_reporting.md](../../../../design_documents/runtime_failure_reporting.md)):

| Class | Program output (before the exit marker) | Status |
| --- | --- | --- |
| Fatal fault: a CPU exception, including a stack-guard hit (`main`'s machine or auxiliary stack) | `[silica] fault at 0x<epc>`, plus `  addr=0x<excvaddr>` for the causes that set EXCVADDR | 70 |
| Runtime abort: a failed runtime check (list index, region/buffer, canonical arena, not a Silica string, heap exhausted, illegal device map) | `[silica] abort: <reason> at 0x<pc>` | 71 |
| `case_clause` / `badarith` in `main` | the atom name | 1 |

A fatal fault or abort on either core stops the other core (2026-10-16): the first core to claim the fatal-owner word stalls the other through the RTC stall bits and writes the one report. Each core has its own fault stack and fault counter, which costs 2 KB of heap. Both cores' last-byte words start as newline, so a report cannot be blocked by a console line hold.

The report is program output here because the board has one console; on a hosted target the same line
goes to stderr, which the trial harness captures with stdout. The board has no symbol table, so the
host's ` in <symbol>+0x<offset>` and `actor=`/`sbase=`/`ssize=` fields are omitted, never invented.
The addresses in a report differ by run and target: compare a run with an app's `expected.scout` using
`tools/compare_sout.sh <run.sout> <app>/expected.scout`, which folds each report line to
`[silica] fault at <PTR>` / `[silica] abort: <reason> at <PTR>` (`trials/normalize_fatal_reports.awk`,
the same rule the trial harness applies).

### Actor failures and the FailureReporter

A fault inside an actor is not a process fault: it ends that actor with the host's actor failure
report (`=== Silica Actor Failure ===` ..., frame #0 named from the emitter's function-name records)
and the program goes on. The report goes to the registered FailureReporter (spec §15.4.13.4), as on
the hosts:

- The FailureReporter is an ordinary **cast-only** actor (`fn reporter(report: string, state: int64)
  -> (:no_reply, int64)`): the runtime casts it each formatted report, and it usually writes the report
  with `println_stderr` (the console, here). With no reporter registered, the runtime writes the
  report itself.
- `main` spawns the reporter and calls `register_failure_reporter` **before it starts any other actor
  or supervisor**; the compiler rejects a start that can run first with **E2236
  StartBeforeFailureReporter**. Every app from `silica_16_device_uart` to `silica_22_device_buzzer` has
  the pattern
  (`start_reporter` first in `main`, then `spawn_registered_supervisor`).
- When a root actor or the root supervisor ends, the runtime prints the **root note**
  `[silica] root actor exited (no supervisor)` before the report reaches the reporter, because the
  reporter may end the program as soon as it has the report. The apps' reporter recognises the root
  supervisor's report (no supervisor, frame #0 `<unknown behavior>`; the board prints a null
  supervisor as `0x00000000`) and ends the program with `cast_exit(70)`, the fault status.

## How a program ends

`main` is not an actor (spec §15.1.2.2). An app that uses actors follows the small-main rule: `main`
registers the FailureReporter, starts the app's supervisor, casts the work to it, and ends with
`wait_for_exit()`. The program ends when `main` returns, so it ends either when an actor calls
`cast_exit(<status>)` (main's wait returns that value), or when the console receives the line `exit`
(the wait returns 0; core 0's scheduler polls UART0 for it). A program whose actors are all idle and
that nobody ends simply waits: `run_on_board.py` then reports "no exit marker" at its timeout. The
apps that end themselves call `cast_exit` after their last line; one that runs until it is stopped
(`silica_20_device_buttons_led`) needs `--send 'exit\n'`.

## Not supported on this target

Foreign C calls (no C runtime on bare metal) and file io (no filesystem) make a module fail to
assemble with one `.error` line naming the feature instead of emitting AArch64 text.

Actors run on both LX7 cores (`get_cpu_topology()` reports two `:performance` cores; an actor pinned
to core 1 runs on the APP cpu, which the runtime starts at its first actor entry point --
[design §8.9](../../../../design_documents/ports/esp32s3_xtensa_port.md)).

## Stack budget

`main`'s stacks are fixed and sized per image; every actor's and supervisor's two stacks are chains
of heap chunks that grow on demand and are released by the actor's `stack_policy` algorithm
(`design_documents/actor_memory_budget_plan.md`, Part II, items D and F; the mechanism is in
[esp32s3_xtensa_port.md §8.3](../../../../design_documents/ports/esp32s3_xtensa_port.md)):

- **`main`'s two stacks are sized per image.** `build_image.sh` links the image once, runs
  `tools/main_stack_bound.py` over it -- a static walk of the linked code from `_start` that sums
  `entry a1, N` frames along `call8`/`call0` edges and tail jumps and takes the maximum over branches,
  and adds up the reservations emitted code makes on the auxiliary stack (the emitter's `SP`: argument
  tuples and slabs) -- and links again with `_silica_main_stack_size` / `_silica_main_aux_size` set to
  the bounds plus a quarter (at least 128 bytes) and the 64-byte guard band, rounded up to 64. The sizes
  are printed and kept in `<name>.stack`. A `main` from which recursion or a call through a function
  value is reachable cannot be bounded and keeps the documented defaults in `silica_esp32s3.ld`:
  128 KB of machine stack (about 2000 nested 48-byte frames) and 64 KB auxiliary, the budget the port
  had before. A converted app (`main` starts a supervisor, casts the work to it and waits) needs under
  1 KB + 256 B; the whole 192 KB then goes to the heap. `main` is not an actor (spec §15.1.2.2): its
  stacks never grow, and a limit it crosses is a fatal fault.
- **Actors and supervisors grow by chunks, with no limit but the heap.** An actor holds no stack until
  its first dispatch, when the scheduler gives it a 2 KB machine chunk and a 512-byte auxiliary chunk
  (sized from the use measured under item E: a replying worker never grows). Every emitted prologue
  compares its new `a1` with the running context's machine limit (the current chunk's guard band top
  plus `_silica_rt_depth_reserve`, the deepest runtime chain emitted code can call, measured by the
  same tool and linked per image), and every auxiliary reservation compares the new `SP` with the
  auxiliary limit; below a limit the frame or reservation moves to the next chunk (`rt_actors.S`
  `silica_rt_stack_grow`, `silica_rt_aux_grow`): twice the previous chunk up to 16 KB (4 KB
  auxiliary), or as large as the frame or slab needs plus headroom. A frame that entered a chunk
  returns through `silica_rt_chunk_return`, which makes the chunk below current again; a release that
  empties an auxiliary chunk pops it. At the dispatch boundary the scheduler releases what the
  algorithm does not keep: `:release_on_return` everything, `:keep_last_message` the chunks beyond
  what the message reached, `:track_recent_peak` beyond the most of the last 32 messages,
  `:release_when_idle` everything a second after the last message, `:keep_high_water` nothing. A
  supervisor's `init` runs on the supervisor's own stack at its first dispatch, so a wide `init`
  literal (frame-homed field by field: a ten-child `init` is a 5.7 KB frame) takes a chunk of its own
  size and gives it back under its policy. A lowered reservation (`stack_policy(n, ...)`) caps what an
  actor's chunks may hold together; reaching it ends the actor with `(:explicit, :stack_exhausted)`.
  The heap exhausted by growth is a runtime abort (status 71), the host's out-of-memory outcome.
- **An overflow is always loud.** Each chunk and each of `main`'s stacks ends in a 64-byte guard band
  watched by an Xtensa data breakpoint, re-armed at every context switch and chunk change. The
  breakpoint sees stores only, which is why emitted code checks its limits as well; where the stack
  cannot grow (`main`; an actor at its lowered reservation) the runtime stores into the band on
  purpose, so the result is the debug exception (cause 1006): in an actor it ends that actor with
  `(:explicit, :stack_exhausted)`; in `main` it is a fatal fault (`[silica] fault at 0x<pc>`, status
  70, `exccause=1006` after the marker).
- **The end-of-program line reports the high-water marks.** After the exit marker the runtime prints
  `[silica] stacks: machine <used>/<size> aux <used>/<size> actors <n> actor-max machine <b> aux <b>
  sup-max machine <b> aux <b>`: how deep `main`'s stacks went (they are zeroed at start, so the mark
  is the lowest non-zero word) and the most chunk bytes any actor or supervisor held on each stack.
  `run_on_board.py` passes it to its stderr; the trial driver keeps it in the run's `.run.err`.

## Running the Silica applications on the board

### Prerequisites

- **The board** (the BYU-I eBadge v4.0 above, or any ESP32-S3 with the same pins) on a USB port and
  switched on. The tools find the one USB serial port (`/dev/cu.usbserial*`, `/dev/cu.usbmodem*`, ...);
  with several, set `BOARD_PORT=/dev/cu.<port>`. Another USB CDC device (a webcam shows up as a
  `/dev/cu.usbmodem*`) makes the pick ambiguous, so set `BOARD_PORT` then (2026-10-29: the test Mac needs
  `BOARD_PORT=/dev/cu.usbserial-310`). The USB-Serial-JTAG port of `usb_console_check.py` is found by id
  303A:1001, not by name. `BOARD_MAC=<mac>` makes the runner refuse any other
  board. Check it with `run_on_board.py --probe` (prints port, chip and MAC; see "The tools one at a time").
- **The Xtensa toolchain and the ESP-IDF Python environment** from the ESP-IDF 6.2 installer
  ([docs/required-software.md](../../../../../docs/required-software.md)): `xtensa-esp32s3-elf-gcc`
  under `~/.espressif/tools/xtensa-esp-elf/esp-16.1.0_20260609/xtensa-esp-elf/bin` (override:
  `XTENSA_BIN`), and esptool + pyserial in `~/.espressif/python_env/idf6.2_py3.14_env` (override:
  `ESPTOOL` for `build_image.sh`, `BOARD_PYTHON` for the Python that runs `run_on_board.py` and
  `main_stack_bound.py`). **What works today is the IDF environment:** `run_on_board.py` must run under
  `~/.espressif/python_env/idf6.2_py3.14_env/bin/python` (or another Python that has esptool 5.x and
  pyserial), and `build_image.sh` calls that environment's `esptool`. A change to plain `python3` with
  `pip install esptool pyserial` is planned but not done.
  **On the 2026-11-09 setup the installed environment is `idf6.1_py3.14_env`, not 6.2**, so the defaults point at a
  missing directory and every run needs the overrides. The system `python3` has no pyserial. A working recipe:
  ```sh
  export BOARD_PYTHON=~/.espressif/python_env/idf6.1_py3.14_env/bin/python
  export ESPTOOL=~/.espressif/python_env/idf6.1_py3.14_env/bin/esptool
  export BOARD_PORT=/dev/cu.usbserial-8310          # the USB-UART jack (UART0); the number differs per board
  export SILICA_COMPILER=$PWD/compiler/build/ESP32-S3_raw/silica-compiler   # also BOARD_SILICA_COMPILER for the suites
  ```
  The native USB-C jack enumerates separately (`/dev/cu.usbmodem*`, 303A:1001); find it by VID:PID, the node name
  changes across resets.
- **An ESP32-S3_raw compiler that matches the runtime in this tree.** The runtime (`rt_actors.S`,
  `rt_supervisors.S`) refers to symbols the compiler emits (atom tags, registry atoms), so a compiler
  older than the runtime compiles but does not link, and one older than the language rules the apps
  use does not compile (`E2007 unknown function: cast_exit` from the 2026-10-07 compiler). The
  compiler is built and published by `make TARGET=ESP32-S3_raw` in `compiler/src` (published as
  `binaries/silica-compiler-ESP32-S3_raw`; `INSTALL_SELFHOST=0` builds without publishing, into
  `compiler/build/ESP32-S3_raw/silica-compiler`).
  The cross compiler in `compiler/build/ESP32-S3_raw/` was rebuilt on 2026-11-09 for the `(:uart1)` window (77 minutes,
  scratch `BUILD_ROOT`) and again the same day for stage S-C of `transport_esp32s3_wifi_plan.md` (the `carried_on`
  link declaration: the shared parser and type checker, the pack's `provides_link` / `carrier_spawn` rows; 67 min 47 s, scratch `BUILD_ROOT`, copied over `compiler/build/ESP32-S3_raw/silica-compiler`).
  The published `binaries/silica-compiler-ESP32-S3_raw` knows neither the `:esp32s3_uart1` window (it refuses
  `map_device 0x60010000`) nor `carried_on`.

### Build and run one app

```sh
B=compiler/src/emitter/ESP32-S3_raw/board          # from the repository root
$B/tools/run_app.sh silica_21_device_led_row
SILICA_COMPILER=/path/to/silica-compiler $B/tools/run_app.sh silica_04_print
$B/tools/run_app.sh --send 'exit\n' --send-delay 65 --timeout 120 silica_20_device_buttons_led
$B/tools/run_app.sh --build-only --keep silica_14_wbt_map   # image only, keep the build directory
```

`tools/run_app.sh <app>` takes an app directory name under `apps/` (or a path to one) and:

1. copies the app's `.silica` files, and the files its `extra_sources.txt` lists (one path per line,
   relative to `compiler/`, in dependency order: the stdlib modules, the board pack, the drivers),
   into a temporary directory, writes a `silica.config` naming them in that order, and compiles there.
   Nothing is compiled in place: compiling a tracked source by its own path writes the ESP32 `.sams` /
   `.iface` next to it, over the host's tracked outputs (that happened to `compiler/stdlib/Supervisor.sams`);
2. builds the image with `tools/build_image.sh` (runtime cache in the same temporary directory),
   printing the section sizes and `main`'s stack sizes;
3. runs it from the board's RAM with `tools/run_on_board.py` (nothing is written to flash unless
   `--flash` is given) while holding the board lock `trials/.board.lock` (flock, the lock the board
   trial runs take for each trial), and refuses to start while a board trial run holds
   `trials/.integrate.lock.ESP32-S3_raw`;
4. prints the run in `.sout` form on stdout -- the program's output, then its exit status on a line
   of its own -- with its own progress, the image sizes and the board's `[silica] stacks:` line on
   stderr;
5. compares the run with the app's `expected.scout` through `tools/compare_sout.sh` and reports
   `MATCH` or `MISMATCH` (with the diff: `<` the board, `>` the golden);
6. removes the temporary directory, unless `--keep` is given (it prints the path).

Options: `--send TEXT`, `--send-delay S`, `--timeout S` (default 60), `--port P`, `--flash` are
passed to `run_on_board.py`; `--build-only` stops after the image; `--keep` keeps the build
directory. **Compiler:** `SILICA_COMPILER` (or `BOARD_SILICA_COMPILER`), else the published
`binaries/silica-compiler-ESP32-S3_raw` when it exists, else the local build
`compiler/build/ESP32-S3_raw/silica-compiler`. On 2026-10-15 the published link still points at the
2026-10-07 compiler (`silica-999983`), which rejects the current apps, and the 2026-10-10 local build
compiles them but does not link with the current runtime: point `SILICA_COMPILER` at a cross compiler
built from the current tree until the next publish. Exit status: 0 match (or a clean run when there
is no `expected.scout`), 1 mismatch, 3 no exit marker before the timeout, 4 board unavailable,
5 compile failure, 6 image build failure, 7 a board trial run is in progress.

A run of `silica_21_device_led_row` looks like this (stdout, then the script's stderr lines):

```
white
off
chase
red
green
blue
off
done
0
[silica] stacks: machine 304/1216 aux 16/256 actors 8 actor-max machine 19712 aux 512 sup-max machine 2048 aux 512
run_app: MATCH: the output equals silica_21_device_led_row/expected.scout
```

### What an app prints and how it ends

An app's console output is whatever it prints, and the last line of the `.sout` form is its exit
status (`main`'s result, or the `cast_exit` value). The expected output of each app is its
`expected.scout`; the comment at the top of each app's source says what it shows on the board
(LEDs, display, buzzer) and what it prints. The apps up to `silica_15` return from `main` directly;
the device apps (`silica_16` on) end with `cast_exit` from an actor once their last line is printed,
except `silica_20_device_buttons_led`, which watches the buttons for about 60 seconds, prints `done`,
and then waits for the console `exit` line (`--send 'exit\n'` with a `--send-delay` past those 60
seconds). A process failure prints its report line and ends with status 70 or 71 (see "Process
failures"); `silica_08_stack_guard` and `silica_15_list_index_abort` expect exactly that.

### Comparing by hand

`run_on_board.py --out run.sout` (or `run_app.sh ... > run.sout`) writes the `.sout` form;
`tools/compare_sout.sh run.sout apps/<app>/expected.scout` compares it, folding the addresses of the
fatal-report lines, and exits with `diff`'s status. `expected.scout` is the macOS compiler's output for
the same source, written by `tools/host_reference.sh apps/<app>`; it is a golden (it was
`expected.sout` until 2026-10-07: a `.sout` is always an output, a `.scout` the expected one), so
change it only with Lee's approval.

### The tools one at a time

```sh
B=compiler/src/emitter/ESP32-S3_raw/board
PY=~/.espressif/python_env/idf6.2_py3.14_env/bin/python
$B/tools/build_image.sh -o /tmp/esp/app <unit>.sams ...          # image from compiled units
$PY $B/tools/run_on_board.py /tmp/esp/app.bin                   # from RAM (default)
$PY $B/tools/run_on_board.py --flash /tmp/esp/app.bin           # write flash, then run
$PY $B/tools/run_on_board.py --send 'exit\n' /tmp/esp/app.bin   # send the console exit line
$PY $B/tools/run_on_board.py --probe                            # port, chip and MAC of the board
```

RAM loading uploads at 921600 baud and switches the chip back to 230400 before starting the program:
at 921600 the console of images above about 40 KB arrives corrupted (cause not established).

### The `asm_*` apps

The `asm_*` bring-up apps link against the same runtime. The runtime reads a few data words that the
compiler emits for Silica programs (`silica_registry_slots`, `silica_registry_atom_*`,
`silica_rt_reply_tag`, `silica_rt_no_reply_tag`); `rt_actors.S` gives them weak defaults (no registry
slots, no atoms), which a Silica program's own definitions override, so the assembly apps link and run
(`run_app.sh asm_00_hello` prints `hello from silica on esp32s3` and exits 42). Most `asm_*` apps drive
LEDs, the display, the buzzer or buttons, so run them only while watching the board. They are kept as the
record of the bring-up and as hardware references (pins). The working display reference is now
`silica_18_device_display`, which draws through the SPI2 peripheral (`device_lib/device_st7789`); the bit-banged
`asm_13_display_hello` is kept as the record of the pin map and the panel's init sequence before SPI2.

## The trials on the board

The trial tree runs on the board too: `make integrate TRIAL_TARGET=ESP32-S3_raw` in `trials/` (one
suite: `make -C <suite> integrate TRIAL_TARGET=ESP32-S3_raw`; some suites: `TRIAL_SUITES="..."`), see
[trials/targets/README.md](../../../../../trials/targets/README.md). The board compiler is
`BOARD_SILICA_COMPILER` (default `binaries/silica-compiler-ESP32-S3_raw`), the Python is `BOARD_PYTHON`
(default from `trials/targets/ESP32-S3_raw.conf`: the IDF environment). `trials/targets/board_suite.sh`
compiles each suite once, links each program with only the units it reaches through `use` (board
memory is small), runs it from RAM under `trials/.board.lock`, and compares with the trial's `.scout`
(or a hand-written `<stem>.ESP32-S3_raw.scout`). A trial with a `<stem>.wait_for_exit` marker gets
`--send 'exit\n'` `BOARD_EXIT_DELAY` seconds (default 5) after its start marker, as the host harness
sends `exit` after the trial's marker. Suites and trials the board cannot run, or the driver does not
handle yet, are listed with their reasons in `trials/targets/ESP32-S3_raw.skip`; they are reported as
skipped, never as passed.

## The sample apps

The `asm_*` apps were the port's bring-up checks; the `silica_*` apps exercise the emitter and the
runtime feature by feature (`silica_00` to `silica_15`) and the board's peripherals through device
workers written in Silica (`silica_16` on, drivers in `apps/device_lib`). The result column records
what was seen when an app was last checked on the test unit; the board trial runs are the current
record for the language features.

| App | Checks | Result on the test unit |
| --- | --- | --- |
| `asm_00_hello` | ROM load, `_start`, UART0, exit status | ✓ `hello from silica on esp32s3`, status 42 |
| `asm_01_blink` | GPIO output, delay | ✓ LED (GPIO6) blinks 10x -- faint, it runs at ~0.3 mA |
| `asm_02_rgb` | RGB LED red GPIO2 / green GPIO4 / blue GPIO5 | ✓ red, green, blue, white, off |
| `asm_05_recursion` | Window overflow/underflow, int64 add-with-carry | ✓ `sum 500500`, `sum64 hi 999 lo 4294966296`, `windows ok` |
| `asm_06_heap` | Allocator alignment/zeroing | ✓ `heap used 48000`, `list sum 1999000` (with the block headers of 2026-09-28 the expected figure is `heap used 64000`; not yet re-run on the board) |
| `asm_07_fault` | Fault vector -> fatal fault report + status 70 + details | ✓ status 139, `exccause=28` (before 2026-09-19; now expected: `[silica] fault at 0x4037....  addr=0x00000000`, status 70, `exccause=28` after the marker; not yet run on the board) |
| `asm_08_gpio_diag` | Register read-back of the GPIO setup | diagnostic |
| `asm_09_pin_readback` | Each output pin's real pad level at 1 and 0 | ✓ all listed pins toggle |
| `asm_10_pin_hunt` | Square wave on every pin in `pins.inc` | diagnostic (used to rule out pin-map errors) |
| `asm_13_display_hello` | ST7789 display (FPC P2) bit-banged (historical reference; the display is now driven by `silica_18_device_display` through SPI2): "Hello from Silica", white on black, landscape | ✓ |
| `silica_00_return42` | Prologue/epilogue, int64 constant, exit status | ✓ 42 |
| `silica_01_arith` | let bindings, int64 mul/div/rem (libgcc `__divdi3`) | ✓ 100 |
| `silica_02_calls` | User calls, arguments in `a10`–`a15`, results | ✓ 85 |
| `silica_03_case_bool` | case on booleans, compare-and-branch | ✓ 215 |
| `silica_04_print` | `print_int64`, `print_string`, `println` through `silica_rt_*` | ✓ matches the host |
| `silica_05_int64_wide` | Values above 2^32: carry, 64-bit compare, div/rem | ✓ matches the host |
| `silica_06_strings` | `concat`, `length_bytes`, `substring` (`rt_string.S`) | ✓ matches the host |
| `silica_07_recursion_depth` | 2000 nested frames: window spills, aux-stack pushes | ✓ 2001000 (needed the 128 KB + 64 KB stacks) |
| `silica_08_stack_guard` | Unbounded recursion hits the stack-guard watchpoint | ✓ status 139, `exccause=1006 ... (stack guard` (before 2026-09-19; now expected: `[silica] fault at 0x....`, status 70; not yet run on the board) |
| `silica_09_lists` | Literal/empty lists, length, prepend, patterns, remove_head, list_at, a 100-element fold (`rt_list.S`) | ✓ matches the host |
| `silica_10_records_tuples` | Records (fields, parameters, results, nesting), tuple decomposition, a tuple literal in a record read back out, a list of records | ✓ matches the host |
| `silica_11_regions` | alloc_region, scalar/tuple refs, int64 buffers, a 16 KB buffer that grows the region (`rt_heap.S`) | ✓ matches the host |
| `silica_12_floats` | float64 (soft float), float32 (FPU) and float16 arithmetic, compares, cases yielding floats, printing (`rt_float.S`) | ✓ matches the host |
| `silica_13_checked` | checked_int64_add / _mul / _add1 with overflow (`rt_ordering.S`) | ✓ matches the host |
| `silica_14_wbt_map` | The stdlib `wbt_map` (weight-balanced tree) compiled for the board with the app: insert, get, size, contains_key | ✓ matches the host |
| `silica_15_list_index_abort` | A runtime abort: `list_at` past the end (`rt_list.S` -> `silica_rt_abort_list_index`) | not yet run on the board; expected `9`, `[silica] abort: list index out of range at 0x....`, status 71 |
| `silica_16_device_uart` | A device worker prints on UART0 through peek and poke (`device_lib/device_esp32s3_uart`) | expected `hello from a device worker`, status 0 |
| `silica_17_device_gpio` | LED1 (GPIO6) and the Left button (GPIO21) through the GPIO device worker | expected `left button 0`, status 0 |
| `silica_18_device_display` | "Hello from / Silica" on the ST7789 through the display worker (SPI2) | expected `text`, status 0 (and the picture) |
| `silica_19_device_led_hold` | LED1 held visibly on by the GPIO worker (`:hold`), "led on" / "led off" in the worker's order | expected `led on`, `left button 0`, `led off`, status 0 |
| `silica_20_device_buttons_led` | LED1 lit while a direction button is pressed, for about 60 s | interactive (no `expected.scout`): `watching buttons`, `done`, then waits for `exit` |
| `silica_21_device_led_row` | The 24 WS2813B LEDs (GPIO7) driven from RMT channel 0: white, off, a chase, red, green, blue, off | ✓ 2026-10-15 with `run_app.sh`: matches `expected.scout` |
| `silica_22_device_buzzer` | The buzzer (GPIO48) from LEDC timer 0: 440, 880, 2730 Hz | expected `440`, `880`, `2730`, `done`, status 0 |
| `silica_23_device_blink` | Twin of `asm_01_blink`: LED1 (GPIO6) blinks ten times, 250 ms on and off, through the GPIO worker | expected `blink 1` to `blink 10`, `done`, status 0 (`expected.scout` written from the source); ✓ 2026-10-28 with `run_app.sh`: matched twice, LED1 seen blinking 10 times
| `silica_24_device_rgb` | Twin of `asm_02_rgb`: the RGB LED (GPIO2, 4, 5) shows red, green, blue, white, off, 1 s each | expected `red`, `green`, `blue`, `white`, `off`, status 0 (`expected.scout` written from the source); ✓ 2026-10-28: console matched, visual not recorded
| `silica_25_device_buttons_full` | Twin of `asm_03_buttons`: all seven buttons for 30 s, LED1 lit while the button mask differs from its idle value; the poll runs inside the GPIO worker (`:watch_all`: one peek of GPIO_IN and one of GPIO_IN1 per 10 ms round, the 7-bit mask cast on start and on each change, 128 for done); prints idle levels, changes, `done` | hardware-dependent (no `expected.scout`); ✓ 2026-10-28: 30 s completed, status 0; idle Left/Right/Down/Up/A/B 0, Point 1; Left, Right, Up, Down, B, A each logged press and release with LED1 lit; Point's change was not observed (open). The first version, polling by messages, aborted `heap exhausted` after about 8 s (see "Known issue: board emitter heap") |
| `silica_26_device_gpio_diag` | Twin of `asm_08_gpio_diag`: raw register dumps (IO_MUX, FUNC6_OUT_SEL_CFG, GPIO_PIN6, GPIO_ENABLE, GPIO_OUT, GPIO_IN) at six points, with `:peek` | hardware-dependent (no `expected.scout`); ✓ 2026-10-28: ran clean, register values consistent with the writes (IO_MUX_GPIO6 0x1800 to 0x1A00 with FUN_IE; GPIO_IN 0xfc000041; FUNC6_OUT_SEL_CFG 0x100 to 0x500), LED1 confirmed
| `silica_27_device_pin_readback` | Twin of `asm_09_pin_readback`: pins 1, 2, 4, 5, 6, 7, 48 driven 1 then 0 and read back; `pin N: <level> <level>` | hardware-dependent (no `expected.scout`); ✓ 2026-10-28: `pin N: 1 0` for all seven pins
| `silica_28_device_pin_hunt` | Twin of `asm_10_pin_hunt`: 440 Hz square on pins 2, 3, 7, 8, 9, 12 to 18, 45, 46 for about 4 s, run in the worker by `:square` | expected `square wave on`, `done`, status 0 (from the source); ✓ 2026-10-28: matched twice, observer confirmed
| `silica_29_recursion_wide` | Native coverage: 1000-deep recursion, int64 wide sum, values bound across deep calls (`asm_05_recursion`) | `expected.scout` matches the macOS host run; ✓ 2026-10-28: matched on the board
| `silica_30_heap_list` | Native coverage: 2000-element list built, walked and summed (`asm_06_heap`) | `expected.scout` matches the macOS host run; ✓ 2026-10-28: matched on the board (sums by index with `list_at`; the `[h, t]` pattern walk exhausted the heap)
| `silica_31_device_usb_console` | A second console: UART0 and the USB-Serial-JTAG worker (`device_lib/device_esp32s3_usb_serial_jtag`, `:exchange`) together; the worker waits up to about 20 s for a byte from the USB host, then writes `hello from usb serial jtag`, the byte and a newline to the USB console | UART0: `waiting for usb host`, `usb byte 65`, status 0 (`expected.scout` written from the source, with a host sending `A`); no byte in time: `usb timed out`, then seven register lines (`usb ep1_conf N`, `usb conf0 N`, `usb out_ep1_st N`, `usb in_ep1_st N`, `usb jfifo_st N`, `usb fram_num N`, `usb fram_num_100ms_later N`, decimal), status 3. Gate passed on the board 2026-10-30 (`usb_console_check.py` exit 0: UART0 matched, USB console `hello from usb serial jtag` and `A`), and again 2026-11-09 after the app moved to the chunk-15 spawn forms (`state_policy`). Run it with `tools/usb_console_check.py`, which plays the USB host |
| `silica_32_transport_uart1_etf` | One ETF frame over the `(:uart1)` transport carrier (`device_lib/device_esp32s3_uart1`, the §6.2 carrier contract of `transport_serialization_design.md` on the UART1 header, GPIO35 TX / GPIO36 RX, 115200 8N1): the owner opens the carrier, encodes `(:accel, { x: 1, y: -2, z: 512, at_ms: 1000 })` with `encode((:etf), ...)`, frames it with the carrier's properties (52 bytes) and sends it as one `:tx`, then closes. The Mac peer is `programmer_tools/transport_uart1_demo` (needs a USB-serial adapter on the header: adapter RX to GPIO35, GND to GND) | expected `link up uart1@115200`, `tx credit 8`, `sent 52 bytes`, `link down :closed`, status 0 (`expected.scout` written from the source); ✓ 2026-11-09 with `run_app.sh` (compiler built from the tree, `BUILD_ROOT` scratch): matched twice; nothing was wired to the header, so the bytes left on GPIO35 unobserved |
| `silica_33_transport_usb_serial_jtag_etf` | ETF frames both ways over the `(:usb_serial_jtag)` transport carrier (`device_esp32s3_usb_serial_jtag@usb_serial_jtag_carrier`, the native USB-C jack, `/dev/cu.usbmodem*` 303A:1001 on the Mac): the owner opens the carrier, grants receive credit, encodes `(:accel, { x: 1, y: -2, z: 512, at_ms: 1000 })` and sends it as one 52-byte `:tx`, then decodes the peer's reply `(:led, { which: :red, on: true })` from the `:rx` segments and prints it, then closes. The Mac peer is `programmer_tools/transport_usb_serial_jtag_demo` (the hosted `(:serial)` carrier, or the Erlang peer behind the bridge); start it after `run_app.sh` prints `running ... on the board` | expected `link up usb_serial_jtag`, `tx credit 8`, `sent 52 bytes`, `led red on`, `link down :closed`, status 0 (`expected.scout` written from the source); ✓ 2026-11-09 with `run_app.sh --timeout 120`: matched against the Silica peer and against the Erlang peer (the bridge showed the 52 bytes out and the 39-byte reply in); waits for the reply until `--timeout` when no peer opens the port |

Every `silica_*` app is compiled by the ESP32-S3_raw emitter and compared byte for byte with the
`expected.scout` the macOS compiler produced for the same source (`tools/host_reference.sh <app dir>`
writes that file: it compiles, links and runs the app on the Mac), except that a process-fatal report
line is compared with its addresses folded (`tools/compare_sout.sh`, see "Process failures").
An app that needs other modules (the stdlib, the board pack, the drivers) lists them in its
`extra_sources.txt`, one path per line relative to `compiler/`, in dependency order; the host
script, `run_app.sh` and a hand-made board build compile those files first, in one `silica.config`
with the app. Known limit of this emitter until chunk 15 phase 9: tuple results a caller destructures and `[h, t]` list matches leak heap (24 B and 32 B each), so long-running workers and long list walks end in `heap exhausted`; the plan (`design_documents/esp32s3_board_peripherals_plan.md`, "Known issue: board emitter heap") has the reproducers. Loops that run long therefore live inside the worker (`:watch`, `:watch_all`, `:square`).
A device app's device worker is `spawn_device`d with the driver's behaviour; the
windows it maps must be in the board pack's window table (`../board_pack.silica`).

`silica_04_print` binds every `print_int64` result: it was written while a bare
`print_int64(<literal>)` statement was a host-compiler defect, since fixed and covered by
`trials/sequence_block_addition/sequence_print_int64_literal_statement`. Three host defects the apps
found are fixed in both emitters (2026-09-13) and covered by
trials, and the apps exercise them again: a tuple literal as a record field value read back out
(`silica_10_records_tuples`; `trials/tuples_addition/decompose_record_tuple_field`,
`record_tuple_field_*`), a `case` whose arms yield a float not assembling (`MOV D0, #0`;
`trials/float64_addition/case_float_result`), and a `case` on a comparison of two float parameters
returning the wrong one, the compare's operand staging having overwritten the second parameter's
register (`silica_12_floats`; `trials/float64_addition/case_float_compare_params` and its float32 /
float16 twins).

## Known issues (2026-11-09)

- **Stale three-argument `spawn` forms.** The device apps `silica_16` to `silica_28` (14 files) still call `spawn` /
  `spawn_device` with the pre-chunk-15 three-argument form and fail with E2005 under the current compiler; they need the
  `state_policy(:keep_state_area)` argument. `silica_31_device_usb_console` and the new transport apps are current.
  Update the others when their suites are next run.
- **Board assembly goldens depend on the suite's compile set.** Atom indices are assigned across the whole `silica.config`,
  so staging another module into a suite renumbers `movi` immediates in that suite's `.esp32_s3.ascomp` files. Regenerate
  them from the compiler's own output (`gen_board_ascomp.sh --suite <name> ESP32-S3_raw`); see
  `trials/transport_board_addition/README.md`.
- **Carrier declarations on the board (stage S-C, 2026-11-09).** `carried_on usb: (:serial) (:usb_serial_jtag);` and
  `carried_on host_line: (:serial) (:uart, 1, 115200);` are the two links this pack provides;
  `spawn_dangerous_carrier(<name>, ...)` expands to `spawn_device(:idle, <worker>@<carrier>, ...)` and answers a
  `device_actor_ref` (the carriers are device workers; a device worker cannot be a supervisor child yet, so the owner
  spawns and restarts it). `(:uart, 0, ...)` is the console and is E2412 with the console note; UART2 has no window
  yet and is not provided; the UART1 worker's clock divider is fixed, so only 115200 is accepted (E2417 otherwise).
  `silica_33_transport_usb_serial_jtag_etf` and the `device_*_link_tx` trials use the declaration;
  `silica_32_transport_uart1_etf` keeps the tag form (`Carrier@mtu((:uart1))`, `spawn_device`), which still compiles.
- **Compiler: `.iface` files carry no device-description rows**, so a driver compiled in a later process after a skipped
  `use` can get a wrong E2213 (order-dependent). The transport carriers therefore have their own suite,
  `trials/transport_board_addition`, apart from `device_actor_addition`.
