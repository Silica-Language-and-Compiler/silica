# nucleo_flash_max_actors: fill the Nucleo's SRAM with actors, from flash

An example application for the ST NUCLEO-L476RG (emit target `STM32-L476RG_raw`). The program runs from
the chip's flash: its code and constants are in flash, so all of SRAM1 and SRAM2 is left for data. It
works out how many actors fit in that memory, spawns **three fewer** than that estimate, makes every one
of them run once, and exits with status 0 when all of them have answered.

**It is run by hand only. Every run erases and reprograms the flash, and it is never part of the trials.**
See "Flash wear, and why the trials cannot reach this" below.

## What it does

`main.silica` follows the small-main rule. `main` registers a FailureReporter, starts the supervisor
`AppSupervisor`, casts the spawner its first message and waits in `wait_for_exit()`. The supervisor has
two workers:

- **spawner** spawns one worker actor per dispatch, casts it one message, and casts itself the next
  step. No function recurses, so no stack grows past its first chunk. The loop is a chain of messages.
  When it spawns the last worker it prints `spawned: N`.
- **tally** counts the answers. When the count reaches `actors_to_spawn()` it prints
  `answered: N (estimate MAX)` and calls `cast_exit(0)`.

Each worker answers the tally once. Its stack chunks are allocated at its first dispatch, so the
message makes every worker really occupy its memory. The supervisor allows no restarts. A failed spawner
or tally therefore ends the root supervisor, and the reporter exits with status 70. Running out of heap
is the runtime's abort, status 71. Status 0 means all `MAX - 3` workers ran and answered.

Expected console output (between the start and exit markers; **not yet run on the board**):

```
spawned: 34
answered: 34 (estimate 37)
0
```

## Memory layout of the flash image

`BOARD_EXEC=flash` links the image with
`compiler/src/emitter/STM32-L476RG_raw/board/runtime/silica_stm32l476rg_flash.ld`. The numbers below
are from this program's map (`make size`):

| Region | Range | Holds |
| --- | --- | --- |
| Flash (1 MiB) | `0x0800_0000`-`0x0800_AD1F` | vector table (word 0 = `0x2001_8000`, the stack top; word 1 = `_start` with its Thumb bit), `.text`, `.rodata`, then the `.data` load image: 44,320 bytes, 22 pages of 2 KiB |
| SRAM1 (96 KiB) | `0x2000_0000`-`0x2000_0CCF` | `.data` (32 B, copied from flash by `_start`) and `.bss` (3,248 B) |
| | `0x2000_0CD0`-`0x2001_67FF` | heap arena 0: **88,880 bytes** (ACBs, supervision blocks, rows, message nodes, registry tables, and the stack chunks SRAM2 cannot hold) |
| | `0x2001_6800`-`0x2001_7FFF` | main's machine stack, 6 KiB (fixed: not moved, enlarged or made growable) |
| SRAM2 (32 KiB) | `0x1000_0000`-`0x1000_0BFF` | the fault stack (1 KiB) and main's auxiliary stack (2 KiB) |
| | `0x1000_0C00`-`0x1000_7FFF` | heap arena 1: **29,696 bytes**, actor stack chunks only (tried first) |

The same program built as a RAM image would put about 44 KB of code in SRAM1 and leave about 45 KB of
heap. From flash the heap is 88,880 bytes.

## The actor-count estimate

The estimate comes from the runtime's allocator (`board/runtime/rt_heap.S`). Every block has a 16-byte
header and is rounded up to 16 bytes. ACBs and every other runtime block come from arena 0. A stack
chunk comes from arena 1 (SRAM2) when it fits there, otherwise from arena 0. A worker allocates its
208-byte ACB at spawn, and its 2 KiB machine chunk and 512 B auxiliary chunk at its first dispatch.
Nothing is freed while the program runs, so `estimate_actors.sh` replays these allocations against the
two arenas, taking the sizes from the linker map:

| Item | Arena 0 (SRAM1) | Arena 1 (SRAM2) |
| --- | ---: | ---: |
| Arena size (map: `_silica_heap_*`, `_silica_sram2_heap_*`) | 88,880 | 29,696 |
| Registry tables, 3 x (64 slots x 4 B + header) | 816 | |
| Reporter, supervisor, tally, spawner: 4 x ACB 224, with first chunks 4 x 2,592 | 896 | 10,368 |
| Supervision blocks 3 x 96 (72 B + header, rounded to 16), child rows 2 x 128 | 544 | |
| Message nodes in flight, 8 x 80 | 640 | |
| **Left for workers** | **85,984** | **19,328** |
| Per worker: ACB 224 (arena 0) + machine chunk 2,064 + auxiliary chunk 528 = **2,816** | | |
| Workers whose chunks fit in arena 1: 7 pairs + 2 auxiliary chunks (19,328 = 7 x 2,592 + 2 x 528 + 128) | 7 x 224 | 18,144 + 1,056 |
| The other 30 workers: ACB plus whatever chunks did not fit in arena 1 (2 x (224 + 2,064) + 28 x 2,816) | 83,424 | |
| **MAX = 37 workers** (992 bytes left in arena 0, 128 in arena 1; a 38th needs 2,816) | | |

The program spawns `MAX - 3 = 34`. The three-actor margin (8,448 bytes) covers what the replay does not
model: auxiliary-chunk growth in the spawner's own dispatch (a 1 KiB chunk if its frames pass the first
512 B), more message nodes in flight if the scheduler runs the spawner ahead of the workers, and the
stack chunk the reporter needs only when it reports.

The estimate is one named constant, `estimated_max_actors()` in `main.silica`, and `actors_to_spawn()`
subtracts the three. `make size` recomputes MAX from the current map. It warns and fails when the
constant disagrees, for example after a runtime change moves `.bss` or a stack size changes.

## Flash wear, and why the trials cannot reach this

Flash survives about 10,000 erase cycles per 2 KiB page. Each run of `make flash` erases and reprograms
the 22 pages this image covers. Lee's rule (2026-11-10) is that flash is never used when running
trials. A board suite is hundreds of images, and flashing each one would wear out the part. This
program is kept out of every trial path:

- It lives under `examples/`, not `trials/`. `make integrate`, `trials/targets/board_suite.sh`,
  `run_one_trial.sh` and `gen_board_ascomp.sh` only look under `trials/`. There is no trial, golden,
  skip row or integrate hook for it.
- The trial harness always builds images with a runtime cache (`build_image.sh -r`). `build_image.sh`
  refuses `BOARD_EXEC=flash` together with `-r`/`--prepare`, so a trial run cannot build a flash image
  even if `BOARD_EXEC=flash` is set in its environment.
- `run_on_board.py` programs flash only with `--exec flash --yes-wear-flash`. The harness passes
  neither. Its default RAM mode refuses a flash-linked image (`_start` in `0x0800_0000`-`0x080F_FFFF`),
  so such an image can never be handed to the RAM loader by mistake.
- Here, `make` and `make build` compile and link only, and `make size` reads the map. `flash` is not a
  prerequisite of any other target.

## Running it by hand

Build and inspect. This touches no board:

```
cd examples/nucleo_flash_max_actors
make            # = make build: compile with /Volumes/2T/silica/binaries/silica-compiler-STM32-L476RG_raw, link BOARD_EXEC=flash
make size       # flash footprint, SRAM budget, MAX recomputed and checked against main.silica
```

Program and run. **This wears the flash.** Do it only when nothing else, a trial run for example, is
using the board:

```
make flash
```

This runs `board/tools/run_on_board.py --exec flash --yes-wear-flash --timeout 60
build/image/nucleo_flash_max_actors.elf` under `$(PYTHON)`, the ESP-IDF Python environment with pyserial.
The tool opens the console, then runs OpenOCD: `reset halt`, `program <elf> verify`, `reset halt`,
`resume`. It prints the program's output and the exit status. To see the OpenOCD command line without
running it, add `--print-openocd` to that command.

After a run the program stays in flash. It starts again at every reset or power-up, prints its lines and
halts. The RAM-loading trial flow still works, because its `reset halt` stops the core before the flashed
program runs. To erase the program, which costs another erase cycle, run:
`openocd -f interface/stlink.cfg -f target/stm32l4x.cfg -c init -c "reset halt" -c "stm32l4x mass_erase 0" -c shutdown`.

## First run on the board (2026-11-12, by hand, compiler 999990)

`make flash` programmed and verified the image, the board booted from flash, and the program printed:

```
[silica] stacks: machine 268/6144 aux 16/2048 heap: in use 76336 free 12544 sram2: in use 29568 free 128
spawned: 34
answered: 34 (estimate 37)
```

and exited 0. So OpenOCD's `program ... verify` works on this ST-LINK, the board boots from main flash, `.data` is
copied from flash correctly, and every worker's first dispatch stayed within its first chunks. SRAM2's chunk arena
ended 128 bytes from full and the SRAM1 heap 12,544 bytes from full, which is consistent with MAX = 37 (three more
workers would need about 8,448 bytes). The run cost one erase cycle on each of the 22 flash pages.

Still not checked on the board (see `compiler/design_documents/stm32_flash_execution_design.md`):

- Whether the ART enable in `_start` reads back.
- The flash-mode wall clock: it is not written, so `current_time` counts from the start.
