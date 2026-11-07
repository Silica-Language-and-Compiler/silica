# `emitter/STM32-L476RG_raw/board/` — bare-metal ST NUCLEO-L476RG board pack

Everything the `STM32-L476RG_raw` emit target needs besides the emitter itself: the Thumb-2 runtime a
compiled program links against, the memory map, the image builder and the hand-written smoke images.
The layout mirrors `../../ESP32-S3_raw/board/` (`runtime/`, `tools/`, `tests/`, `pack/`, `apps/`).
The board facts are in [../BOARD_DESCRIPTION.md](../BOARD_DESCRIPTION.md); the compiler-side board
pack is [../board_pack.silica](../board_pack.silica).

**Status (2026-11-07): stage 1, nothing has run on the board yet.** The emitter tree compiles in the
units checked so far (shared/, control/, effects/, board_pack, pack_descriptions), every runtime file
assembles and the two smoke images link; the cross compiler has not been built and no image has
been loaded. What is ported and what is not is listed under "Runtime: what is here".

## The port in one page

The compiler side is the ESP32-S3_raw emitter with its Xtensa helper layer replaced: every emitter
site names AArch64-style virtual registers (X0-X30, W, D/S/H, SP, X29) and calls `shared/arm_*`
(the ESP32 tree's `shared/xt_*`) for the machine code. The module names changed (`arm_isa`, `arm_vr`,
`arm_mem`, `arm_float`, `arm_frame`); the exported function names did not (`xt_movi`, `xt_ldr`, ...),
so the 841 call sites in the other 110 modules are the ESP32's unchanged. The memory model is chunk
15's (frame regions on the auxiliary stack, auxiliary stack chains, state chains, the heap only as the
source of chunks, ACBs, message nodes and mailbox buffers; `main`'s stacks are small and fixed).

| VR | Home | Why |
| --- | --- | --- |
| `X0`, `X1`, `X2` | `r0:r1`, `r2:r3`, `r4:r5` | argument / result pairs: a call needs no moves |
| `X9` | `r6:r7` | the binary-prim operand temp |
| `r9` | TP: the base of the register block `silica_rt_core_regs` | loaded at boot, never written again |
| `X3`-`X8`, `D0`-`D7` | the register block (X3 at 0 .. X8 at 40, D0 at 48 .. D7 at 104) | caller-saved on AArch64, so one shared block is exact |
| `SP` | the auxiliary stack pointer, the word at `r9 + 112` | the machine sp never moves inside a function |
| `X29` | `sp + SFP` (read-only) | the frame slot area `[X29, #-N]` is `[sp, #SFP-N]` |
| every other `X`/`W`, `D`/`S`/`H` | 8-byte frame slot `SVR_X<nn>` / `SVR_D<nn>` | only homes the body references get a slot |

Scratch: `r8`, `r10`, `r11`, `r12` (the ESP32's a2, a8, a9, a3); `lr` is saved in the frame by the
prologue and free inside a body. Values are 64-bit `(lo, hi)` pairs; every memory layout is the hosted
emitters' (8-byte fields, 24-byte list cells, 24-byte string headers). 64-bit arithmetic uses the carry
(`ADDS/ADC`, `SUBS/SBC`, `UMULL`), compares the `SUBS/SBCS` flag pair with IT blocks, 64-bit division
and register-amount shifts libgcc's AEABI routines. `float32` is on the FPv4-SP FPU through `VMOV`
in and out of the home; `float64` is soft float (`__aeabi_dadd` ...); `float16` converts through the
runtime. Every function is `.thumb_func`, so a function value carries the Thumb bit and `BLX` works
(`xt_callr` forces bit 0 anyway).

**Frame** (`emitter_core` publishes `.set SFRAME / SFP / SVR_*` ahead of the label; the prelude macros
of `arm_vr` choose the encoding from the final values):

```
 sp + SFRAME        caller's sp
 [SFRAME-16, SFRAME)  the saved lr at SFRAME-4 (FRAME_ENTER / FRAME_LEAVE)
 [SFP, SFP+16)        frame record: entry SP, caller's floor, pre-call SP, unused (arm_frame)
 [SFP - spill, SFP)   the emitter's [X29, #-N] slots
 [0, homes)           SVR_X10..X28, SVR_D8..D31 in use, SVR_LC (32) for libgcc calls
 sp
```

`FRAME_ENTER n` compares `sp - n` with `VRG_MLIMIT` (`r9 + 116`); below it the frame calls
`silica_rt_stack_grow` (r10 = n, r11 = the real return address), which moves sp to the top of the next
machine chunk and hands back `silica_rt_chunk_return` as the return address; the real one and the
caller's sp stay in the chunk header (`CH_RET`, `CH_SAVED_SP`), and `chunk_return` puts the chunk
below back when the frame returns. In `main` a limit crossed is the fatal fault (status 70, cause
1006 like the ESP32's stack guard). Every auxiliary reservation compares the new SP with `VRG_ALIMIT`
and grows through `silica_rt_aux_grow` (with the ESP32's mirror of the live bytes above the old SP);
every release compares with `VRG_ATOP` and pops through `silica_rt_aux_release`.

**Calling convention of the runtime** (`rt_defs.h`): an entry emitted code calls keeps every register
except `r10`, `r11`, `lr`, and `r0:r1` when it answers in X0 (`ENTRY_SAVE` = `push {r0-r8, r12, lr}`);
internal routines are AAPCS. C and libgcc meet the AAPCS, with `X0`/`X1` saved in `SVR_LC` around a
libcall (X2 and X9 are AAPCS callee-saved).

## Memory map and budget (96 KiB SRAM1 + 32 KiB SRAM2)

Probed on the board on 2026-11-07 (first smoke load): SRAM1 is 96 KiB at `0x2000_0000-0x2001_7FFF`
and SRAM2 32 KiB at `0x1000_0000-0x1000_7FFF`, two **separate** regions -- a write to `0x2001_8000`
bus-faults on this part, so the reference manual's alias of SRAM2 above SRAM1 is not available here.
`runtime/silica_stm32l476rg.ld`:

```
SRAM1  0x20000000  vector table (VTOR), .text, .rodata (silica_fnames first), .data
                   .bss: runtime state (register block 192 B, core block, main/scheduler ACBs,
                         registries 3 x 256 B, scheduler stack 1 KiB)
                   heap: the leftover (first fit, 16-byte blocks; stack chunks, ACBs, nodes, SBs, rows)
                   main's machine stack 6 KiB (grows down from the top)
       0x20018000
SRAM2  0x10000000  fault stack 1 KiB (the fatal report runs here whatever the SRAM1 stacks hold),
                   main's auxiliary stack 2 KiB (the emitter's SP); the rest unused for now
       0x10008000
```

Measured on the smoke images: .text 8.5 KiB (stubs included), .bss 2.7 KiB, heap 80.9 KiB
(`0x20002bf0-0x20016800`), SRAM2 used 3 KiB of 32. An emitted base trial on the ESP32 is ~3,300 lines
of Xtensa; the Thumb-2 form should be 10-15 KiB, leaving ~65-70 KiB of heap. Per actor at its first
dispatch: ACB 208 B + 2 KiB machine chunk + 512 B auxiliary chunk (+ 72 B SB and 112 B row for a
supervisor's child); chunks double to 8 KiB / 2 KiB. The base trials run four contexts (reporter,
supervisor, worker, main's pseudo-ACB): under 12 KiB. Defaults to override per image:
`BOARD_MAIN_STACK`, `BOARD_MAIN_AUX` (build_image.sh), and the runtime depth reserve
`_silica_rt_depth_reserve` (512 B; the deepest runtime chain under an emitted frame, plus an
exception frame). `_start` zeroes `.bss` through the main stack top and the used SRAM2 range before
anything runs; the probe loads the ELF (`.sram2` is NOLOAD) and resumes at `_start`, which sets sp
and VTOR first.

Clock: HSI16 (16 MHz) as SYSCLK; SysTick at 1 ms keeps `silica_rt_ticks_ms`. Console: USART2 on
PA2/PA3 (AF7), 115200 8N1, polled, the Nucleo's ST-LINK virtual COM port (`/dev/cu.usbmodem21103`).

## Runtime: what is here (stage 1) and what is not

| File | Here | Not yet |
| --- | --- | --- |
| `rt_vectors.S` | vector table, fault vectors into the fatal report, SysTick | DebugMonitor / MPU stack guards (the limit checks are the guard) |
| `rt_start.S` | `_start`: VTOR, FPU, clock, console, zeroing, register block, runtime init, markers | the two-pass per-image main-stack bound (`main_stack_bound.py`) |
| `rt_console.S` | USART2, putc/write/puts, print_i64/u64/bool/char/string, exit marker, `exit` line reader, runtime aborts (71), fatal report (70) | |
| `rt_heap.S` | first-fit heap with coalescing, zeroed blocks, the exit summary | |
| `rt_frame.S` | `dyn_alloc`, `adopt`, `frame_alloc`, `in_aux_chain`, aux chunk append/publish | **`ev_frame` (the copier)** |
| `rt_state.S` | scalar / undescribed `state_install`, `state_dispatch_end` | **the copier**: described states, `message_buffer`, `message_forward`, `reply_place`, retire, compaction |
| `rt_string.S` | every string routine | |
| `rt_list.S` | length, tail, at, prepend (in place and copy-on-write) | |
| `rt_actors.S` | init, scheduler loop, context switch, chunk chains + growth entries, spawn (plain, linked, supervisor trampoline wait), cast / send / registered casts, registries as tables, `wait_for_exit` / `cast_exit`, reporter registration, clocks, `remove_actor`, `stop_self_normal`, benign pinning/link returns | **call / call_registered**, actor failure handling and reports (a fault is process-fatal), `recv`, kill/fail, supervision ingress, timers, priorities, policies, stack release policies (chunks kept until the actor ends), the identity table (an `actor_ref` is the ACB address) |
| `rt_supervisors.S` | `materialize_init_children` (flags record, child rows, each child registered by id), `count_children` | restarts, shutdown, `start_child` and the `call_supervisor` operations, exit reports |
| `rt_support.S` | checked int64 add/add1/mul, `h2f`/`f2h`, `trunc_f32/f64`, `map_device_check`, memcpy/memmove/memset/memcmp/strlen, LED + delay helpers | `print_f64/f32/f16`, ordering identities, FFI (`ffi_call`, string in/out) |
| `rt_stubs.S` | one aborting stub per unported entry, so every program links (`tools/list_runtime_stubs.sh` regenerates the list) | |

A stub aborts with `[silica] abort: runtime entry not yet ported to STM32-L476RG_raw at 0x<pc>`
(status 71) at the first use.

## Building an image

```
# the cross compiler (Haiku / Lee; the Makefile builds it with binaries/silica-compiler, not the seed)
make -C compiler/src build TARGET=STM32-L476RG_raw         # publishes binaries/silica-compiler-STM32-L476RG_raw

# a program: compile in a directory with silica.config, then link with the runtime
binaries/silica-compiler-STM32-L476RG_raw                  # writes <unit>.sams, __silica_runtime.sams
sh compiler/src/emitter/STM32-L476RG_raw/board/tools/build_image.sh -o out/test test.sams .trial_stdlib/*.sams __silica_runtime.sams
#   -> out/test.elf (what the probe loads), out/test.map, out/test.bin

# the hand-written smoke images (no compiler needed)
cd compiler/src/emitter/STM32-L476RG_raw/board/tests/smoke_return42 && sh ../../tools/build_image.sh -o out/smoke_return42 main.S
cd ../smoke_actor && sh ../../tools/build_image.sh -o out/smoke_actor main.S
```

`build_image.sh -r <cache> --prepare` assembles the runtime once for a trial run (the ESP32 driver's
usage). Toolchain: Homebrew's `arm-none-eabi-gcc` (16.2.0 on this Mac): assembler, linker, libgcc and
the C compiler for foreign wrappers all come from it (`ARM_BIN` overrides the directory).

## Loading and running (the probe; nothing is written to flash)

The debug probe is the Nucleo's on-board ST-LINK, driven by OpenOCD (Homebrew `openocd`; `st-util`/
`arm-none-eabi-gdb` are an alternative). One run, from a shell, with the console port already open:

```
openocd -f interface/stlink.cfg -f target/stm32l4x.cfg \
    -c "init" -c "reset halt" \
    -c "load_image out/test.elf" \
    -c "resume <address of _start>" -c "shutdown"
```

`_start` sets its own sp (0x20018000, the top of SRAM1) and VTOR first; its address comes from
`arm-none-eabi-nm out/test.elf | awk '$3=="_start"'` (no Thumb bit: `resume` takes the instruction
address). The run's console
output is on `/dev/cu.usbmodem21103` at 115200: `\x02SILICA:START\x03 <program bytes>
\x02SILICA:EXIT:<status>\x03 <diagnostic line>` (the ESP32 protocol). Optional: the host's Unix
time in milliseconds written into the 8 bytes after the `SILICA:WALLCLOCK` tag in `.data`
(`mww`) before `resume`, so `current_time` answers epoch milliseconds.

## Trial harness (the spec for `trials/targets`, written there by another agent)

- `trials/targets/STM32-L476RG_raw.conf`: `TARGET_DESCRIPTION="ST NUCLEO-L476RG over ST-LINK (bare
  metal)"`, `TARGET_BOARD_DIR="compiler/src/emitter/STM32-L476RG_raw/board"`, `TARGET_PYTHON` = a
  Python with pyserial (the ESP-IDF environment has it), plus `TARGET_PROBE=openocd`,
  `TARGET_PORT_DEFAULT=/dev/cu.usbmodem21103`, `TARGET_GOLDEN_NAME=st_nucleo`.
- `board/tools/run_on_board.py` for this target: the ESP32 driver's interface (`image`, `--port`,
  `--timeout`, `--out`, `--send`, `--send-marker`, `--probe`, `--list-ports`, exit codes 0/3/4) with
  the ESP32 loading replaced by: open the serial port first (115200, pyserial), then run OpenOCD as a
  subprocess with the commands above (`reset halt`, `load_image <elf>`, optional `mww` of the wall
  clock, `resume <_start>`, `shutdown`), then capture until the exit marker exactly as the ESP32
  driver does (`capture()` can be reused verbatim). `--probe` runs `openocd ... -c init -c "reset halt"
  -c shutdown` and prints `port chip serial` (chip from `st-info --probe`). The port is
  `--port`, else `$BOARD_PORT`, else the single `/dev/cu.usbmodem*`; the ESP32 board's
  `/dev/cu.usbserial*` must never be a candidate for this target.
- `board_suite.sh` / `trial_target.sh`: parametrise the image extension (`.elf` here, `.bin` on the
  ESP32) and the preflight (`st-info --probe` must list one ST-LINK). Assembly goldens: this target
  compares `<stem>.st_nucleo.ascomp` (platforms.mk `silica_golden_name_for_target`); the ESP32 run
  compares output only and has no `.ascomp` convention.
- `STM32-L476RG_raw.skip`: everything but `base` at first (`driver:` reasons), then widen suite by
  suite as runtime pieces land.
- First run: ONE trial (`base/test`, the smallest: `fn main` returning 42 through the trial support
  supervisor) with a one-shot script before `make integrate TRIAL_TARGET=STM32-L476RG_raw
  TRIAL_SUITES=base`.
