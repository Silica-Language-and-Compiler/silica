# STM32-L476RG_raw: running the image from flash (reserved option, not implemented)

Status: design only, written 2026-11-10. Nothing here is built; the board image still runs from SRAM1
and nothing is written to flash. This records the option so the work can be picked up without rediscovering
the constraints. Everything not read from a file or measured is marked **unverified**.

Update 2026-11-12: sections 2.1-2.5 are implemented and link-verified, not run on the board:
`runtime/silica_stm32l476rg_flash.ld`, `BOARD_EXEC=flash` in `tools/build_image.sh` (refused with `-r`/`--prepare`,
the harness's runtime cache, instead of a second cache directory), the `.ifdef BOARD_EXEC_FLASH` parts of
`rt_start.S` (.data copy first, ART on) and `rt_actors.S` (convention-word guard accepts flash, flash in the
memory ranges), and `tools/run_on_board.py --exec flash --yes-wear-flash` (no wall clock written in flash mode;
the RAM mode refuses a flash image). RAM images are byte-identical to before. The vector table is 98 words, not
82; `.align 7` is kept and the flash script asserts the table is at 0x0800_0000. The by-hand user is
`examples/nucleo_flash_max_actors/`.

Paths below are relative to `compiler/src/emitter/STM32-L476RG_raw/board/` unless they start with `trials/`.

## 1. Why

- The image runs from RAM. `tools/run_on_board.py` loads the ELF into SRAM1 through OpenOCD and resumes at
  `_start`: `reset halt`, `load_image <elf>`, optional `mww` of the wall clock, `resume <_start>`,
  `shutdown` (`openocd_command`, run_on_board.py lines 161-178; module docstring lines 25-34). Nothing is
  written to flash.
- SRAM1 is 96 KiB (0x2000_0000-0x2001_7FFF). `.text`, `.rodata`, `.data`, `.bss`, then the heap, then main's
  machine stack all live in it (`runtime/silica_stm32l476rg.ld` lines 20-36, 59-118). Every byte of
  code and constant data therefore comes out of the heap.
- The linker refuses an image that leaves under 16 KiB of heap:
  `ASSERT(_silica_heap_start + 0x4000 < _silica_heap_end, "program too large: less than 16 KiB left for the
  heap")` (silica_stm32l476rg.ld line 120).
- The combined two-pin hand program (`tests/pins/hand/`, `unbuilt/device_twopin_pa6_pa7.silica.combined`,
  object 36.4 KB) failed that assert; it was split into two programs of 28.5 KB and 25.4 KB objects (heap
  21,168 and 24,320 bytes) (tests/pins/hand/README.md lines 82-88).
- README.md "Open item: image headroom" (lines 140-149) names two levers: a smaller image, or running
  `.text`/`.rodata` from flash (the part has 1 MiB). This document is the second lever.
- The runtime alone is about 8.5 KiB of `.text` (smoke_return42 map: `.text` 0x2150, `.data` 0x20, `.bss`
  0xa80; heap start 0x20002bf0, heap end 0x20016800, from `tests/smoke_return42/out/*.map`).

## 2. Proposed design

### 2.1 Memory map and linker script

Add a second linker script `runtime/silica_stm32l476rg_flash.ld` (do not parameterise the RAM one; the RAM
script stays byte-for-byte what the trial harness uses):

```
MEMORY {
  flash (RX)  : org = 0x08000000, len = 0x100000     /* 1 MiB */
  sram1 (RWX) : org = 0x20000000, len = 0x18000
  sram2 (RW)  : org = 0x10000000, len = 0x8000
}
```

- `.vectors`, `.text`, `.rodata` (including the `.rodata.silica_fnames` block between `_silica_fnames_start`
  and `_end`, ld lines 68-73) go `> flash`.
- `.data` is linked at its RAM address and loaded from flash: `.data : { ... } > sram1 AT> flash`, with
  `_silica_data_load = LOADADDR(.data)`. `.bss`, `.sram2`, heap and stack are unchanged (SRAM1 then holds
  `.data`, `.bss`, heap, stack; SRAM2 unchanged).
- Keep the 16 KiB heap assert; add `ASSERT(_silica_text_end <= 0x08100000, ...)`. The part has a dual-bank
  1 MiB array (2 x 512 KiB; **unverified**, RM0351), irrelevant here because one image is far below 512 KiB.
- The `.sram2` and SRAM2 chunk arena are untouched.

### 2.2 `_start` (rt_start.S) changes

- Copy `.data` from `_silica_data_load` to `_silica_data_start.._silica_data_end` **first**, before anything
  that reads it. Two `.data` objects exist today: `silica_rt_wall_clock` (rt_actors.S line 221, 16-byte tag plus
  8-byte time) and `silica_rt_fatal_depth` (rt_vectors.S line 172; its comment "reads 0 before rt_start.S zeroes
  .bss" must keep holding, so the copy precedes any fault path). Both are zero-initialised now, apart from
  the ASCII tag; the copy is a few dozen bytes.
- VTOR: `_start` already writes `silica_rt_vectors` into VTOR (rt_start.S lines 75-77). In flash the table sits at
  0x0800_0000 and is also what the hardware reads at reset (boot alias 0x0). The table has 82 words
  (rt_vectors.S lines 38-61, 0x148 bytes) but is aligned only to 128 (`.align 7`, line 39); a table of that
  size needs 512-byte alignment for VTOR on ARMv7-M (**unverified**, ARM ARM). It is first in `.text` at an
  origin that is itself 512-aligned, so it works either way; change line 39 to `.balign 512` in the flash script's
  build to make that explicit. Word 0 is `_silica_stack_top` (SP) and word 1 `_start` with its Thumb bit
  (`FUNC` macro): correct for hardware reset in flash. (In RAM mode the probe uses `resume <_start & ~1>`;
  unchanged.)
- Flash latency and caches (FLASH_ACR at 0x4002_2000, rt_start.S lines 67-69, 132-140): today `_start` sets only
  LATENCY = 4 wait states, before switching to the 80 MHz PLL ("everything runs from SRAM, but the setting must
  match the clock", lines 23-26). In flash mode the latency write already precedes the clock switch, which is
  the required order. The code does not enable the instruction cache (ICEN, bit 9), data cache (DCEN, bit 10)
  or prefetch (PRFTEN, bit 8) of the ART accelerator; the reset value of FLASH_ACR is believed to be 0x0000_0600
  (ICEN and DCEN set, PRFTEN clear) (**unverified**, RM0351). Flash mode should set PRFTEN | ICEN | DCEN
  explicitly (read-modify-write, keeping the latency field) and read back, since without the ART a 80 MHz
  core at 4 wait states runs at roughly a fifth of its speed on straight-line code (rule of thumb, **unmeasured**).
  Doing this in `_start` for the RAM image too is harmless but changes nothing there; keep it flash-only
  (`.ifdef BOARD_EXEC_FLASH`) to leave the RAM image byte-identical.
- The MPU null guard (rt_start.S lines 98-111): region 0 is base 0x0000_0000, size 2^20 (SIZE 19), XN, no access,
  i.e. 0x0-0x000F_FFFF, the boot alias of flash. It does **not** cover 0x0800_0000-0x080F_FFFF where the image
  executes, so the guard and flash execution coexist. After a flash boot the alias at 0 shows the same flash;
  the guard blocks reads of it, which is intended (null pointer faults). Verified by reading; not run in flash
  mode.
- Everything else in `_start` (clock, console, zeroing `.bss` through the stack top, register block, heap)
  is independent of where code lives.

### 2.3 What the emitted code and runtime assume about code in RAM

Searched `runtime/*.S`, `emitter_core.silica` and `atoms/*`; findings:

1. **A real dependency: the behaviour convention word (rt_actors.S lines 1783-1806).** When an actor is created,
   the runtime reads the word at `beh - 4` (written by the emitter before a function declared to return
   `(:reply, ...)` / `(:no_reply, ...)`: 0x5C1AC0F1 / 0x5C1AC0F2) **only if the behaviour address lies in
   0x2000_0000-0x2001_FFFF** (`MOV32 r2, 0x20000000 ... cmp ... blo 1f`, `MOV32 r2, 0x20020000 ... bhs 1f`,
   lines 1790-1795). Outside that range the convention is taken as 0 ("not checked"), and the low nibble kept
   from the word, whose bit 2 is the state-release proof, is lost. With code in flash every behaviour address is
   0x0800_xxxx, so this guard must accept the flash range (0x0800_0000-0x080F_FFFF, or better: the image's
   `_silica_image_start.._silica_text_end`) or the convention check and the state-release proof silently
   turn off. This must be changed before any flash image is trusted; it is the single most likely source of
   RAM-vs-flash differences. (A second reason to keep the guard exact: it protects against dereferencing a
   non-code pointer.)
2. No self-modifying or runtime-patched code found: no store targets `.text` (the stores to
   `silica_rt_core_regs` etc. are to `.bss`); no `isb` after writes to code (the `isb`s in rt_start.S,
   rt_failure.S line 901 and rt_ffi.S lines 114/144 follow MPU/system register writes). **Unverified** for
   `rt_support.S`/`rt_stubs.S` in full; confirm with a scan of every `str` whose base register is derived
   from a `.text` symbol, and by running the RAM-vs-flash check of section 6.
3. Literal pools: emitted code builds constants with `movw/movt` (the `MOV32` macro) and reads wide literals from
   `.rodata` (`atoms/*_literal_pool.silica`, `.section .rodata`). The only `.ltorg` directives are in
   rt_console.S line 607, rt_supervisors.S line 1777 and rt_failure.S line 1440. Pools in flash are
   ordinary read-only data; no issue.
4. `.rodata` in flash is read through the data bus (ART handles it); the emitted `string` and `.rodata.silica_fnames`
   records are only read. The runtime never writes a string literal (**unverified**, but any such write would
   already fault on the host targets, where `.rodata` is read-only).
5. Memory range report (rt_actors.S lines 3386-3392) lists only SRAM1 and SRAM2; add flash (0x0800_0000, 1 MiB)
   if the spec of the range reporter wants the executable range (**unverified**: not needed for correctness).
6. Address-range heuristics on `0x2000_0000` elsewhere: none found by grep in `runtime/`, `board_pack.silica` (only
   the memory description at lines 165-198) or the emitter besides item 1.
7. Alignment of `.vectors` and `.text` sections to 4 bytes, Thumb interworking, and the 2-byte instruction
   alignment of `ldr` literal loads are unchanged.

### 2.4 `build_image.sh` switch

`BOARD_EXEC=ram|flash`, default `ram` (tools/build_image.sh lines 33-36 document the other `BOARD_*` knobs):

- `ram`: today's behaviour, byte-identical output (`-T runtime/silica_stm32l476rg.ld`).
- `flash`: `-T runtime/silica_stm32l476rg_flash.ld` and an assembler define for the flash-only `_start` code
  (`-Wa,--defsym,BOARD_EXEC_FLASH=1` or `-DBOARD_EXEC_FLASH`, since `.S` is preprocessed). The `.bin` is then the
  raw image at 0x0800_0000 (line 31 says 0x2000_0000 today; make the comment mode-dependent). Print the flash
  footprint (`.text + .rodata + .data` load size) and the heap size as it prints the heap today (lines 135-140).
- The runtime object cache (`-r`) must key on `BOARD_EXEC` (`rt_start.S` differs), otherwise a flash object is
  linked into a RAM image. Use two cache subdirectories.

### 2.5 The loader (run_on_board.py)

A mode flag `--exec flash` (default `ram`):

```
openocd -f interface/stlink.cfg -f target/stm32l4x.cfg -c "adapter serial <serial>" \
        -c init -c "reset halt" -c "flash write_image erase <elf>" -c "verify_image <elf>" \
        -c "reset halt" -c "resume" -c shutdown
```

or `-c "program <elf> verify"` for the same effect (stm32l4x flash driver; page erase 2 KiB, 64-bit
programming; **unverified**, to be confirmed on the board). The console is opened first as today, so the
`SILICA:START` marker is not lost. The reset-then-resume order (not `reset run`) keeps the time between program
end and console capture identical to the RAM flow.

Wall clock (**needs a decision**): in RAM mode the loader writes the host's Unix time into
`silica_rt_wall_clock` after `load_image` and before `resume`. In flash mode `_start`'s `.data` copy would overwrite
a value written before `resume`, and a write to the flash-resident initial image is not possible. Options:
(a) place the 8 time bytes in a `NOLOAD` RAM section outside the `.bss` zeroing range, with the tag, and keep the
write before `resume` (needs the zero loop to stop before it, or the section placed above the stack top region);
(b) halt at a breakpoint on `silica_rt_wall_clock_start`'s call site in `_start` (rt_start.S line 208, after
`.data` and `.bss` are initialised), `mww` the time, `rbp`, `resume`. (b) leaves the runtime untouched and
adds a halt of a few milliseconds to the clock's start; (a) is cleaner. Unverified which one OpenOCD handles
reliably with an already-running core.

### 2.6 Wear and when to use it

- Flash endures about 10,000 erase cycles per page (datasheet figure; **unverified**, STM32L476 DS gives 10 kcycles
  at 85 C). A flash image occupying n pages consumes one cycle on each of them per load.
- **Rule (Lee, 2026-11-10): flash is never used when running trials.** A full board suite is many images;
  flashing each would wear the part out. The trial harness (`trials/targets/`, `run_one_trial.sh`, `board_suite.sh`,
  `make integrate`) always loads into RAM; the default mode is `ram`, and there is no flash option in the harness:
  `board_suite.sh` and `run_one_trial.sh` must refuse `BOARD_EXEC=flash` outright. Flash is reachable only from the
  hand-run loader for a single app, never from a trial run.
- Flash mode is for (1) hand apps that survive a power cycle (`tests/pins/hand`, `apps/`), and (2) programs
  whose image does not fit the RAM budget (the 36.4 KB two-pin program).
- A flashed program restarts at every power-up or reset and drives its pins unattended. The loader needs an
  `--erase` action (`flash erase_sector 0 0 last` or `stm32l4x mass_erase`) and the doc for hand apps must say so.

### 2.7 Heap budget in flash mode

Code, `.rodata` and the `.data` load image leave SRAM1; `.data` (tens of bytes), `.bss` (about 2.7 KB for the
smoke image) and the stacks remain. Estimate for the two-pin app A (object 28.5 KB, heap 21,168 bytes today):
the heap would grow by roughly the `.text + .rodata` share of the 28.5 KB, about 40-50 KB total (**unverified**:
the object's text/rodata split was not measured; read it with `arm-none-eabi-size -A` on a built ELF). The combined
36.4 KB program would be expected to leave well above 16 KiB. Actor stacks use SRAM2 first and SRAM1 as fallback
(ld lines 25-28), so the extra SRAM1 heap also raises how many actors fit.

## 3. Risks

1. The convention-word range check (2.3 item 1): silent loss of the convention check and state-release proof.
2. Speed: the ART/prefetch settings are unmeasured; timing-dependent trials (timers, `send_after`) have
   been measured only from RAM (zero wait states, deterministic). Flash adds variable fetch latency (cache
   misses), so timing assertions in the harness may need different margins. Keep the harness on RAM.
3. Debugging: breakpoints in flash use the six FPB comparators of the Cortex-M4 (**unverified** count); RAM
   mode has none of that limit when software breakpoints are available.
4. Wall clock (2.5).
5. A stale image from the previous flash run persists; a `reset halt` on a half-programmed device could start
   garbage. `verify_image` before `reset` guards it.
6. The ST-LINK programming time (seconds per image) multiplies in any batch flow.
7. Option bytes: whether the Nucleo boots from main flash by default (BOOT0 pin low, nBOOT0/nSWBOOT0 option
   bits) and RDP level are **unverified** on the user's board; read them first (`stm32l4x option_read`).

## 4. Verification plan

1. **Link-only**: the combined two-pin program built with `BOARD_EXEC=flash` links (the 16 KiB heap assert passes
   with margin) where the RAM build fails.
2. **Flash/RAM equality**: a base-suite sample (say 30-50 trials covering actors, supervisors, strings, floats,
   behaviour conventions with `(:reply, ...)` and `(:no_reply, ...)` shapes, `behaviour_case_arm_helper_state_record`,
   timers) run in RAM mode through the trial harness; build the same programs once in flash mode and load each by
   hand (one flash write each, not through the trial harness) and compare the `.sout` files byte for byte
   (`tools/compare_sout.sh`). Keep the list small: each flash load counts against the wear budget.
3. **Convention check**: a flash image of a `(:reply, ...)` behaviour with a deliberately wrong convention use
   must be rejected the same way as in RAM (proves 2.3 item 1 fixed).
4. **Fault path**: a null dereference and an actor memory fault in a flash image report the same lines as in RAM
   (proves the MPU guard and the vector table).
5. **Power cycle**: unplug and replug; the flashed hand app restarts and prints `SILICA:START`.

## 5. What must be measured first

1. Section sizes of the largest real images (`arm-none-eabi-size -A` on the 28.5 KB and 25.4 KB two-pin
   ELFs): text, rodata, data, bss.
2. FLASH_ACR's reset value and the ART's effect on a representative loop (a timed `silica_rt_ticks_ms` loop in RAM vs
   flash), to size the speed risk.
3. Whether `openocd` can program the board and run `reset halt` / `resume` reliably with the console open,
   and how long a 30 KB image takes to program and verify.
4. The option bytes and boot source (risk 7).
5. Which wall-clock option works (2.5).

## 6. Not decided

Whether the second linker script is generated from the first (a shared `INCLUDE` for the SRAM2 and heap
parts) to avoid drift; whether `BOARD_EXEC` becomes a per-suite default for suites whose images exceed the RAM
budget; whether to enable the ART in the RAM image too (RAM code does not need it).
