# `ESP32-S3_raw` port status — behaviours verified, differences from Apple Silicon, and gaps

State as of 2026-10-16: the board pack in `src/emitter/ESP32-S3_raw/board/` and the ESP32-S3 cross compiler built
from the current tree (`binaries/silica-compiler-ESP32-S3_raw` -> `silica-999981-ESP32_S3_raw-macos-applesilicon`, built 2026-10-16 by `build_all_platforms.sh`). The run counts in §1 are the ones recorded on the dates shown; later board runs (the `stack_budget_board_addition`, `cast_exit_board_addition`, `device_actor_addition` and `cast_device_registered_unheld_name_board_addition` suites, and the apps of §1) are not recorded here with counts. The reference behaviour is the Apple
Silicon path's first fixed point (the current `trials/` tree, [ROADMAP.md](../../../ROADMAP.md)); this
document says how much of it the ESP32-S3 path has, how each part was verified, where an app author sees a
different behaviour on the board, and what is missing — ordered so the next addition to port is easy to pick.
It is updated by hand when a suite is run on the board or a gap closes.

## Related documents

| Document | Role here |
| --- | --- |
| [esp32s3_xtensa_port.md](esp32s3_xtensa_port.md) | The design: virtual registers, frames, calls, runtime, first-version limits |
| `emitter/ESP32-S3_raw/board/README.md` | The board pack: memory map, console protocol, tools, the `silica_*` sample apps and the `asm_*` bring-up apps |
| [trials/targets/README.md](../../../trials/targets/README.md) | Running the trial tree on the board; the skip list `ESP32-S3_raw.skip` |
| [porting_for_os_free_targets.md](../porting_for_os_free_targets.md) | What a complete OS-free port needs (MMIO, device registers) |

## 1. Verified on the board

Everything below was compiled by the ESP32-S3 compiler, loaded into the board's RAM and compared with the
same `.scout` goldens the host uses (behaviour only: there are no Xtensa `.ascomp` goldens).

| What | Result | When |
| --- | --- | --- |
| Bring-up apps `silica_00`..`silica_14` (return, arithmetic, calls, case, print, wide int64, strings, 2000-deep recursion, stack guard, lists, records and tuples, regions and buffers, float64/32/16, checked int64, the stdlib `wbt_map`) | 15 / 15 match the host's output byte for byte | 2026-09-13 |
| `tuples_addition` | 630 / 630 | 2026-09-13 |
| `float64_addition` | 322 / 322 | 2026-09-13 |
| `float32_addition` | 316 / 316 (after the nan/inf printing fix, §2) | 2026-09-13 |
| `float16_addition` | 303 / 303 (after `silica_rt_f16_to_i32`, §2) | 2026-09-13 |
| `modules_addition` | 253 / 253 (7 m 51 s, about 1.9 s per trial) | 2026-09-13 |
| `traits_addition` | 20 / 20 programs (the other 18 units are trait modules, compiled with them) | 2026-09-13 |
| `deep_frame_spill_addition` | 8 / 8 | 2026-09-13 |
| `error_enforcement_addition` | a 40-trial sample of `.golden_fail` diagnostics, 40 / 40 | 2026-09-13 |
| `actors_addition` | 297 / 298 through the driver, 14 m 52 s for the three actor suites; the one miss (`train_actors_atomproto_10026`, no console output within 300 s) passed 3 / 3 when its image was re-run by hand, so it was a RAM-load glitch, not the program; `string_concat_cast_stress` and `aggregate_return_in_actor_keeps_stack` are skipped (§2: they exhaust the 300 KB heap) | 2026-09-28 |
| `actor_registration_addition` | 3 / 3 | 2026-09-28 |
| `scheduler_policy_addition` (new, `set_scheduler_policy`: the four dispatch-order policies of [esp32s3_xtensa_port.md §8.10](esp32s3_xtensa_port.md), the strict dispatch orders `H H H H N N N N L L L L` / `L N H L N H ...` / `H H H H N N L N N L L L` observed on core 0) | 6 / 6; afterwards `actors_addition` 300 / 300 (2 skipped), `actor_registration_addition` 3 / 3, `supervisors_addition` 115 / 115 unchanged under the default `:priority_fifo` (9 m 59 s) | 2026-09-28 |
| `supervisors_addition` | 114 / 114 programs plus `stack_policy_registered_forms` against its board golden (on 2026-09-28 a 2 MB reserve could not be made on the board and the golden carried the spec's abort; since the chunked stacks of 2026-10-08 the reservation is a cap and the program runs as on the host) | 2026-09-28 |
| Two cores: `actors_addition` (300, with the new `actor_cross_core_call_reply` and `actor_cross_core_cast_stress`), `actor_registration_addition` (3), `supervisors_addition` (115, `stack_policy_registered_forms` against its board golden) | 418 / 418 through the driver in 10 m 07 s with both LX7 cores running actors ([esp32s3_xtensa_port.md §8.9](esp32s3_xtensa_port.md)); actors spawned with core 0 are round-robin over the two cores, so most of these trials ran their actors on the APP cpu. One earlier run (417 / 418) showed a core-1 actor's output inside `main`'s `println` (`record_message_cast_between_actors`); the console line hold of §8.9 closed it. | 2026-09-28 |
| `cpu_discovery_and_spawn_pinning` | the suite is `INTEGRATE_PENDING` on every target (skipped by both drivers). By hand, with two cores (2026-09-28): `cpu_spawn_third_arg_affinity` matches (its spawn to core 1 now runs on the APP cpu; core 2 is runtime-assigned), a probe of `get_performance_cores` / `get_cpu_topology` reports 2 cores and `get_core_capabilities(1)` gives `id: 1` (`2` the `-1` sentinel), and an assembly probe pinned to core 1 answers with PRID core 1, then 0 after `migrate_actor(ref, 0)`, and `migrate_actor(ref, 5)` is `:invalid_target`. Earlier by hand: `cpu_spawn_third_nonliteral_affinity` prints its `1` but exits 2 where the golden says 1 (the golden predates the atom seed, under which `:ok` is 2; the host gives 2 as well); `cpu_topology_runtime_queries` and `cpu_topology_phase_h_verify` do not compile on any target (E2015, the pre-`mem(normal)` list syntax) | 2026-09-28 |
| Device-worker apps `silica_16_device_uart` to `silica_22_device_buzzer` (peek and poke through the drivers in `board/apps/device_lib`) | `silica_21_device_led_row` matched its `expected.scout` with `run_app.sh`; the other apps' results are not recorded here (the board README lists their expected output; `silica_20_device_buttons_led` is interactive) | 2026-10-15 |

Not yet run on the board (§4.3, counts as of 2026-09-13) is the larger part of the tree; nothing there is known to fail, but nothing
there is known to pass either.

## 2. Behaviours that differ from Apple Silicon

What a program sees on the board that it would not see on the Mac. "Same" means the trials could not tell
the two apart.

| Area | Apple Silicon | ESP32-S3_raw | Consequence |
| --- | --- | --- | --- |
| Console | `write(2)` to stdout / stderr | UART0, one stream; program output between `\x02SILICA:START\x03` and the exit marker | `.sout` comparisons are the same because the host harness merges stderr into `.sout` too. There is no separate stderr on the board: `print_string_stderr` goes to the same UART. |
| Exit status | process exit code | low byte of `main`'s result in the exit marker | Same for 0–255. |
| Division by zero, no case arm | `badarith` / `case_clause` on stderr, status 1 | the same text on the UART, status 1 | Same. |
| Runtime abort (spec §15.4.5.5) | `[silica] abort: <reason> at 0x… in <fn>+0x…` on stderr, status 71 | `[silica] abort: <reason> at 0x…` on the UART before the exit marker, status 71 | Same once the addresses are folded ([runtime_failure_reporting.md](../runtime_failure_reporting.md) §5). Before 2026-09-19 both were C `abort()`-style, status 134. |
| A bad memory access | the sync fault handler prints `[silica] fault at 0x… in <fn>+0x…  addr=0x…  actor=0x…  sbase=0x…  ssize=0x…`, status 70 | the fatal vector prints `[silica] fault at 0x…` (plus `  addr=0x…` for the causes that set EXCVADDR) before the exit marker, status 70; `exccause=<n> epc=… excvaddr=…` (`(stack guard …)` for cause 1006) after it; a fatal fault or abort on either core stops the other (first core to claim the fatal-owner word stalls the other through the RTC stall bits; own fault stack and counter per core, 2 KB of heap; 2026-10-16) | Same once folded: the trial harness compares `[silica] fault at <PTR>` ([runtime_failure_reporting.md](../runtime_failure_reporting.md)). Before 2026-09-19 the board reported status 139. |
| Stack overflow in `main` | 8 MB main stack (`-stack_size 0x10000000` for the compiler itself); a fatal fault, status 70 | `main`'s machine and auxiliary (`SP`) stacks sized per image by a static bound (`board/tools/main_stack_bound.py`, 128 KB + 64 KB when `main` cannot be bounded), each with a 64-byte guard watched by an Xtensa data breakpoint plus a limit check in every emitted prologue and `SP` reservation; a fatal fault, status 70 | A bounded `main` gets exactly what its deepest chain needs plus margin; a recursive `main` keeps the default, where ~2000 nested frames fit (`silica_07`). Deeper recursion that the host survives faults on the board. |
| Heap and regions | region arenas with release; `free` returns memory | `rt_heap.S`: a first-fit free list with coalescing over a bump top (since 2026-09-28); `silica_rt_free` and `silica_rt_region_destroy` (extension chain too) give memory back; `region_grow` / `region_contains` work; exhaustion is a runtime abort (status 71) | A program that holds more than the board's heap (about 170 to 350 KB depending on the image) fails with the abort where the host has gigabytes; allocate-and-free loops no longer exhaust it. The trials that need more are in `ESP32-S3_raw.skip`. |
| Program + data size | effectively unlimited | ≈ 390 KB of SRAM for code, data, heap and both stacks (`0x3FC88000`–`0x3FCE9700`); the linker refuses an image with no heap left | Very large programs do not fit. The ~40 KB deep_frame_spill programs fit with room to spare. |
| int64 / uint64 | native | pairs of 32-bit registers; multiply, divide and remainder through libgcc (`__muldi3`, `__divdi3`, …) | Same results; slower. |
| float64 | FPU (`D` registers) | libgcc soft float, IEEE double | Same digits (verified by every float64 trial); slower. |
| float32 | FPU | the LX7 FPU | Same. |
| float16 | FPU (`H` registers, FEAT_FP16) | widened to float32 by `silica_rt_h2f`, narrowed by `silica_rt_f2h` (round to nearest even) | Same results in `float16_addition`. |
| Printing non-finite float32 | `FCVTZS` saturates: nan prints `-0.0000000`, ±inf `±2147483647.0000000` | reproduced deliberately (`rt_float.S`) | Same. float64 / float16 print `nan`, `inf`, `-inf` on both. |
| A `main() -> float16 / float32 / float64` exit code | `FCVTZS` (nan → 0, saturated) | `silica_rt_f16_to_i32`; float32 via `trunc.s`; float64 via libgcc | Same for the values the trials use; saturation of huge float64 values is libgcc's, not `FCVTZS`'s (untested). |
| Strings | inline `L_*` helpers per module | `rt_string.S` (`concat`, lengths, `eq`/`cmp`, `starts_with`/`ends_with`/`contains`, `substring`, `substring_until_char`), same 24-byte header | Same where tested (`silica_06`, modules, tuples). `string_addition` not yet run. |
| Lists | inline chunked lists | `rt_list.S` (`length`, `tail`, `at`, `prepend`), same layout | Same where tested (`silica_09`, `silica_14`). `list_addition` not yet run. |
| Tail calls | self tail calls are jumps | self tail calls are jumps; a tail call to another function still grows the stack | Mutual recursion depth is bounded by `main`'s stack (128 KB by default, or the per-image bound). |
| Timing | — | `silica_rt_delay_us`, `silica_rt_cycles` (board only) | Board-only surface, used by the `asm_*` apps; the runtime routines stay board-only; Silica programs reach the hardware through device workers (§4.2) and the SYSTIMER registers. |
| Compile time | — | the ESP32 emitter is about 9× slower on very large functions (deep_frame_spill: 88.7 s vs 9.6 s per trial); small trials compile in the same time | A whole-tree board run is dominated by board time, not compile time, except for that suite. |
| Actors: scheduling | one pthread per actor, preemptive, all cores | one cooperative scheduler per core ([esp32s3_xtensa_port.md §8](esp32s3_xtensa_port.md)); switches only at a dispatch boundary or where an actor suspends (`call`, an empty mailbox, `wait_for_exit`); both LX7 cores run actors | Output from several actors is in dispatch order instead of racing; the goldens that depend on interleaving are compared as multisets on both targets (`.scout.multiset`). |
| Actors: `wait_for_exit()` / `cast_exit` | `main` sleeps in `select` on standard input and the exit pipe; `wait_for_exit` returns the value of the first request, which is 0 for an `exit` line (recorded as `cast_exit(0)`; a later `cast_exit` returns false) or `value` for the first `cast_exit(value)`; `main` continues and the process ends when `main` returns (spec §15.1.2.5) | `main` parks until an exit request is recorded: `cast_exit` from an actor on either core, or an `exit` line on the console UART's receive side, polled by core 0's scheduler loop; `wait_for_exit` returns the value and the program ends when `main` returns, through the exit marker and halt ([esp32s3_xtensa_port.md §8.1](esp32s3_xtensa_port.md)) | Same on both. A quiet program waits on both; the board driver sends `exit` `BOARD_EXIT_DELAY` (default 5) seconds after the start marker for a trial with a `.wait_for_exit` marker, as the host harness does. |
| Actors: stacks | reserved address space, grown by page faults, released by the stack policy's algorithm | chains of heap chunks grown on demand with no limit (first chunks 2 KB + 512 B at the first dispatch, doubling to 16 KB / 4 KB), released at the dispatch boundary by the policy's algorithm ([esp32s3_xtensa_port.md §8.3](esp32s3_xtensa_port.md), `actor_memory_budget_plan.md` item F); the growth trigger is the limit check in every emitted prologue and `SP` reservation; a lowered reservation caps the chunks and ends the actor with `(:explicit, :stack_exhausted)` when reached; the heap exhausted is a runtime abort; `get_actor_memory_usage` reports the chunks held, the most held, and the heap as the default reservation | Same contract; a reservation is a cap on heap chunks rather than address space, so `stack_policy_registered_forms` (2 MB and 4 MB reservations) runs on the board as on the host. |
| Actors: a fault or trap inside an actor | signal handler: the actor fails, the process continues | the fault vector hands the fault to the scheduler: the actor fails (`:memory_fault`, or `:stack_exhausted` for a stack-guard hit), the process continues | Same. `badarith` / `case_clause` in an actor: same as the host (reason tag 1). |
| Actors: the failure report's frame #0 | `dladdr` names the behaviour | the emitter's function-name records name it | Same text. |
| Actors: references and conventions | a reference is a 64-bit identity (child number, position; spec §15.1.4) resolved through the runtime; a call to a cast-only actor or a cast to a call-only actor is rejected by the compiler (E2237, E2238) and, for an unresolved reference, fails the sender with `:language_error` at run time | the same: `spawn` returns the identity, never the ACB (`ACB_ID`), and the run-time convention word before a behaviour (`ACB_CONV`) is checked by `silica_rt_convention_mismatch` | Same. |
| Actors: `kill_abnormal` / `remove_actor` of a parked actor | the victim's thread ends it shortly after | ended synchronously in the caller's context | The report and the root-exit note appear before the caller's next output instead of racing it. |
| Actors: cores | `get_cpu_topology()` from `sysctl` (6 E + 4 P cores on the reference Mac); pinning is a thread affinity hint | two cores (both LX7 cores run actors since 2026-09-28, [esp32s3_xtensa_port.md §8.9](esp32s3_xtensa_port.md)), both `:performance`, no efficiency cores, no NUMA nodes, no cache levels; frequency 0 as on the host; pinning is exclusive: an actor pinned to core 1 runs on the APP cpu and nowhere else, `0` is runtime-assigned (round robin) | Core counts in printed topology differ from the Mac's (2 against 10); `get_core_capabilities(2)` is the `id: -1` sentinel on the board. A program that never touches actors never starts core 1. |

## 3. Behaviours the emitter refuses

A module that uses one of these does not assemble: the emitter writes one `.error` line naming the feature
instead of Xtensa text, so the failure is immediate and legible.

| Construct | `.error` text | Why |
| --- | --- | --- |
| Foreign calls (`ffi`) | `ESP32-S3: foreign (C) calls are not supported on this target` | No C runtime; the host's guarded FFI is setjmp / signal based. **Planned, not implemented:** Fifi on OS-free targets per [porting_for_os_free_targets.md §9.1](../porting_for_os_free_targets.md), with archives built against the board pack and faults caught by the trap vector. |
| File io | `ESP32-S3: file io is not supported on this target (<prim> -> <reg>)` | No filesystem. |
| `peek` / `poke` of a register that is not 32 bits wide | `ESP32-S3: peek of a <n>-bit register is not supported on this board (...)` (same for `poke`) | The first lowering is `l32i` / `s32i` only (`terms/prims/prims_device.silica`). |
| `map_device` with a constant base and size outside every board window | `ESP32-S3: map_device base <hex> size <hex> is not within a board window` | The window table is `board_pack.silica`; a computed base is checked at run time by `rt_device.S` (abort `illegal device map`, status 71). |
| A frame ENTRY cannot allocate | `frame larger than ENTRY can allocate (32760 bytes)` | Xtensa windowed-ABI limit; not hit by any trial so far. |

## 4. Gaps, in the order that makes the next addition easy

### 4.1 Language behaviours of Apple Silicon FP1 that the board does not have

| Gap | What it blocks in `trials/` | What closing it needs |
| --- | --- | --- |
| Actor stacks that grow (spec §15.1.2.2) | `actor_stacks_addition` (13; skipped on the board, `ESP32-S3_raw.skip`) | Done 2026-10-08 (item F): the board grows and releases chunked stacks. The suite's own trials recurse hundreds of thousands of frames deep and expect megabytes committed, which the ~350 KB heap cannot hold, so it stays skipped; `stack_budget_board_addition` covers growth, the five release algorithms, a lowered reservation reached and a thousand idle actors on the board. |
| `link` / `monitor` / `demonitor` | none: the host runtime's Phase G surface returns benign values, and so does the board's | The same work on both targets. |
| Foreign calls | `ffi_addition` (16 apps), `warning_enforcement_addition` (its fixtures build C archives) | **Planned:** Fifi on OS-free targets, per [porting_for_os_free_targets.md §9.1](../porting_for_os_free_targets.md). That needs a board-pack C runtime for wrapper archives, and a trap-vector path that ends only the faulting FFI worker. It also needs the actor runtime above. Until then, record these suites as not applicable on the board. |
| File io | no dedicated suite; used inside some trials | Not applicable without a filesystem. |
| Host fault semantics (status 70 and the `[silica] fault at …` line) | any trial whose golden encodes a host fault | Done 2026-09-19: `rt_console.S` prints the same report line and status (spec §15.4.5.5); goldens are folded, so no per-target `.scout` is needed. Not yet run on the board. |
| Memory release | none directly; long-running allocation loops | Done 2026-09-28: `rt_heap.S` is now a real first-fit, coalescing allocator (`silica_rt_free` / `silica_rt_region_destroy` actually return memory) instead of the old no-op free; `memory_region_addition/region_local_release` is expected to pass. Not yet run on the board. Five sibling trials and one `compiler_addition` trial still cannot fit the board's real heap capacity regardless (1.6 MB / ~940 KB workloads against a ~170 KB heap) and are skipped, not failing; see [actor_memory_budget_plan.md](../actor_memory_budget_plan.md). |

### 4.2 ESP32-S3 FP1 items beyond Apple Silicon FP1

The roadmap defines ESP32-S3 FP1 as Apple Silicon FP1 **plus peek and poke** (device descriptions,
`map_device`, the `peek` / `poke` prims, `spawn_device`, `register_rwr` ordering; [ROADMAP.md](../../../ROADMAP.md),
[silica_device_actor_specification.md §4.7](../silica_device_actor_specification.md),
[porting_for_os_free_targets.md §5](../porting_for_os_free_targets.md)).

Implementation status (2026-10-16): the shared stages, the ESP32-S3 lowering, the board pack windows, the third
registry and the device drivers are in the tree
([esp32s3_peek_poke_implementation_plan.md](esp32s3_peek_poke_implementation_plan.md), "Implementation status").
The hosted emitters reject the prims through `sir_generator/sir_target_verify.silica` (E2220). What a board
program sees: the drivers under `board/apps/device_lib/` (GPIO, UART, SPI2 / ST7789 display, LEDC buzzer, RMT LED
row) drive the board's peripherals from Silica, and the apps `silica_16` to `silica_22` use them. Remaining:
peek and poke are 32-bit only on this board (§3); the board runs of the device suites are not recorded with counts
(§1); device interrupts and DMA (spec §9, §5.3) are not implemented ([esp32s3_board_peripherals_plan.md](../esp32s3_board_peripherals_plan.md));
the diagnostic channel is narrow (§3's refusals other than the device rows are still `.error` lines).

### 4.3 Trial suites not yet run on the board

Every suite below is expected to work — the emitter converts every non-actor primitive and the bring-up apps
cover each area once — but has not been run. Times are estimates at ~1.9 s per program trial.

| Suite | Programs | Estimated board time | Note |
| --- | --- | --- | --- |
| `case_addition` | 747 | 24 min | |
| `string_addition` | 669 | 21 min | the largest untested runtime surface (`rt_string.S`) |
| `functions_addition` | 645 | 20 min | |
| `list_addition` | 529 | 17 min | `rt_list.S` |
| `records_addition` | 457 | 15 min | |
| `compiler_addition` | 425 | 14 min | |
| `int64_addition`, `int32_addition`, `int16_addition`, `int8_addition` | 414, 402, 404, 373 | 51 min | libgcc 64-bit division on the board |
| `uint64_addition`, `uint32_addition`, `uint16_addition`, `uint8_addition` | 409, 405, 412, 411 | 52 min | |
| `memory_region_addition` | 362 | 12 min | first-fit heap with release; five of its trials are in `ESP32-S3_raw.skip` for heap size |
| `effect_check_addition` | 342 | 11 min | |
| `negation_addition`, `recursive_function_addition`, `sequence_block_addition` | 324, 323, 276 | 29 min | |
| `bitwise_addition`, `boolean_addition`, `atoms_addition`, `base` | 294, 208, 212, 84 | 25 min | |
| `error_enforcement_addition` | 10,829 compile-failure trials (compile only, 4 at a time) | ~15 min | 40 sampled so far; its 7 sub-suites with their own Makefiles are skipped by the driver (§4.4) |

About 5–6 hours in one run (`make integrate TRIAL_TARGET=ESP32-S3_raw`), which holds the trial lock for that
long; per suite with `TRIAL_SUITES=`. The Mac is kept awake by the driver.

### 4.4 Trial driver gaps (`trials/targets/`)

| Gap | Effect | What closing it needs |
| --- | --- | --- |
| `ordered_data_structures` | skipped (`driver:`) | Its 10 sub-suites share one stdlib build and put programs in leaf directories; `board_suite.sh` handles one flat suite. |
| Sub-suites with their own Makefile (the 7 under `error_enforcement_addition`) | skipped automatically, reported | Recurse into them the way the host `Makefile`s do. |
| No Xtensa `.ascomp` | assembly is never compared on the board target | By design for now; an Xtensa golden set would need its own hand-derivation policy. |
| One board | suites compile in parallel but run one trial at a time on the single board | More boards, `BOARD_PORT` per worker. |

### 4.5 Emitter performance

Very large functions compile ~9× slower than on the host (the `xt_*` helper layer builds every instruction
from its AArch64 operand text). Only `deep_frame_spill_addition` shows it; a profile of `xt_isa` / `xt_mem`
on one of those units is the starting point.

### 4.6 Host defects the board apps still avoid

`silica_04_print` binds every `print_int64` result because a bare `print_int64(<literal>);` statement drops
its value on the host too (`trials/sequence_block_addition/sequence_print_int64_literal_statement`); the port
reproduces the host exactly. Three others found by the apps were fixed on 2026-09-13 in all three emitter
trees (tuple literal as a record field value; a `case` yielding a float; float parameters clobbered by
float-prim staging) and are covered by trials; the `case`-float fix (`case_fallback_zero`) is present in the `linux_aarch64` and `linux_x86_64` trees; whether the tuple-literal record field and float-parameter fixes reached them was not re-checked on 2026-10-16.

## 5. How to update this document

- A suite run clean on the board moves from §4.3 to §1 with its count and date.
- A behaviour difference discovered by a trial goes in §2, with the `<trial>.ESP32-S3_raw.scout` it needed.
- A gap closed in §4 is removed there and, if it changed what a program sees, noted in §2.
