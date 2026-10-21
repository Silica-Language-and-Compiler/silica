# `ESP32-S3_raw` port — native Xtensa LX7 code generation, bare metal

**Status:** In progress (started 2026-09-12); the emitter conversion is complete for the language the Apple Silicon path runs, the actor runtime runs on both cores, and peek and poke are delivered (2026-10-16; [esp32s3_port_status.md](esp32s3_port_status.md) is the current record). Board pack (runtime, link script, image and flash tools,
bring-up apps) exists under `src/emitter/ESP32-S3_raw/board/`; the emitter conversion is
being done file by file. This is a design record for one port, not a specification; where it
disagrees with [silica-specification.md](../silica-specification.md), the specification wins.

**Decisions taken by Lee (2026-09-12):**

| Question | Decision |
| --- | --- |
| How is Xtensa produced | **Native code generation**: every instruction-emitting site emits Xtensa. Not a translation pass over AArch64 text. |
| Runtime | **Bare metal**: no ESP-IDF, no FreeRTOS. Image at flash 0x0, loaded into SRAM by the ROM. |
| Testing | **On the port test board** ([PORT_TEST_BOARD_byu_idaho_v4.0_feb26.md](../../src/emitter/ESP32-S3_raw/board/PORT_TEST_BOARD_byu_idaho_v4.0_feb26.md)), with early test apps. How trials run against this target is **not decided**; nothing here touches `trials/`. |

## Related documents

| Document | Role here |
| --- | --- |
| [esp32s3_port_status.md](esp32s3_port_status.md) | Status: behaviours verified on the board, differences from Apple Silicon, and the gaps ordered for the next addition |
| [porting_for_os_free_targets.md](../porting_for_os_free_targets.md) | What a complete OS-free port needs; this port covers the compiler target and a first runtime |
| [linux_aarch64_port_checklist.md](linux_aarch64_port_checklist.md) | The sibling hosted port; same "Darwin-isms" inventory, different ISA problem |
| [memory-effects-aarch64-implementation-plan.md](../memory-effects-aarch64-implementation-plan.md) | `Space` on ESP32-S3 (pools, not MAIR) — later phases |
| `emitter/ESP32-S3_raw/board/README.md` | Runtime, memory map, console protocol, tools, bring-up apps |
| [docs/required-software.md](../../../docs/required-software.md) | The toolchain, esptool and board the port needs |
| [trials/targets/README.md](../../../trials/targets/README.md) | Running the trial tree on the board (`TRIAL_TARGET=ESP32-S3_raw`) |

---

## 1. The problem

The `apple_silicon_mac` emitter this tree was copied from is AArch64 through and through: register
choice (31 × 64-bit GPRs, X19–X28 callee-saved), a dozen special-case parameter shadows into those
registers, flag-setting compares, SP pushes, `[X29, #-N]` frame slots, Darwin syscalls, and ~10k lines
of hand-written runtime assembly embedded as strings (actors on pthreads, print via `SVC`, strings via
`mmap`). ESP32-S3 is Xtensa LX7: **16 visible 32-bit registers in a sliding window**, no flags, no
64-bit arithmetic, no double-precision FPU, and no OS.

The emitter's *logic* — SIR walking, type classification, aggregate promotion, region ownership,
binding bookkeeping in `outer_reg` — is ISA-independent and was debugged over dozens of defects. The
port keeps that logic and replaces the machine layer under it.

## 2. Virtual registers

The emitter keeps naming values the way it always has — `X0`–`X30`, `W<n>`, `D/S/H<n>`, `SP`, and
frame slots `[X29, #-N]` — but on this target those are **virtual registers (VRs)**, names in the
emitter's IR, not machine registers. Every instruction site asks the shared helper module
(`shared/xt_isa.silica`) for Xtensa code that operates on VRs; the helpers map each VR to a home:

| VR | Home | Why |
| --- | --- | --- |
| `X0` / `W0` | `a10:a11` (lo:hi) | CALL8 argument 0 and result position in the caller's window: calls and returns need no moves |
| `X1`, `X2` | `a12:a13`, `a14:a15` | CALL8 arguments 1 and 2 |
| `X9`, `X10` | `a4:a5`, `a6:a7` | the binary-prim operand temps; survive CALL8 (harmless superset of AArch64 caller-saved) |
| every other `X`/`W` VR | 8-byte frame slot `SVR_x<n>` | callee-saved semantics come free: each frame has its own copy |
| `X3`–`X7` | frame slots at `[sp + 0 .. 40)` | also the outgoing argument area, see §4 |
| `D0`–`D7` (`S`/`H` alias the low bits) | frame slots at `[sp + 40 .. 104)` | float arguments, see §4 |
| other `D`/`S`/`H` | frame slots `SVR_d<n>` | |
| `[X29, #-N]` | `[sp + SFP - N]` | the emitter's frame-slot area, sized exactly as before |
| `SP` pushes / slabs | auxiliary data stack; its pointer is the word at `THREADPTR + 112` of the core's register block (§4) | the machine SP may not move inside a windowed frame (§3) |

Scratch registers for expansions: `a2`, `a3`, `a8`, `a9`. Incoming arguments arrive in `a2`–`a7`; the
prologue moves them to `a10`–`a15` before anything else runs, which frees `a2`–`a7`.

**Values.** Every `X`-class value is a 64-bit pair: `int64`/`uint64` naturally, and pointers, atoms,
booleans with a zero high word. This keeps every emitter decision that says "X" valid and keeps all
memory layouts identical to `apple_silicon_mac` (8-byte fields, 24-byte list cells, string descriptor
`{tag, data@+8, length@+16}`). `W`-class values use the low register of the pair. `float32` uses the
FPU with the value homed in memory (`lsi`/`ssi` straight to and from the home). `float64` is soft
float through libgcc (`__adddf3`, …); `float16` converts through `float32`.

**Flags.** Xtensa has none. Compare-and-branch, compare-and-set and compare-and-select are emitted as
single combined helpers at the site that knows both halves (`xt_cmp_branch`, `xt_cmp_set`,
`xt_cmp_select`), using `blt/bltu/beq…` on the high words first and the low words on a tie.

## 3. Frames

Each function's layout is computed **after** its body is emitted and published as assembler symbols
at the top of the function, before the label:

```
    .set SFRAME, <total>          ; entry immediate, 16-byte aligned
    .set SFP, <x29 base>          ; [X29, #-N] == [sp + SFP - N]
    .set SVR_x19, <off> ...       ; one line per VR home the body used
    .align 4
name:
    entry   a1, SFRAME
```

GAS resolves those symbols in instruction operands and in `.if` conditions (verified with the
toolchain), so a load from a home is `l32i a8, a1, SVR_x19` when in range and a `movi`/`add` form
otherwise, chosen by the assembler from the final value. Only VR homes the body actually references are
allocated, so frames stay small for the deep recursion Silica code does.

```
 sp + SFRAME       ── caller's SP
 [SFRAME-16, SFRAME)   base save area (window overflow writes the caller's a0-a3 here)
 [SFRAME-32, SFRAME-16) this function's a4-a7 on overflow (it makes CALL8 calls)
 [SFP - area, SFP)     emitter frame slots [X29, #-N]
 [..]                  VR homes (only those used)
 [40, 104)             D0-D7 homes = outgoing float arguments (when used)
 [0, 40)               X3-X7 homes = outgoing integer arguments (when used)
 sp
```

Rules inherited from the windowed ABI (see `board/runtime/rt_vectors.S`): nothing is stored below
`sp`; the machine `sp` never moves after `entry` (so AArch64-style pushes go to the auxiliary data
stack); every function is `.align 4` (the assembler rejects an unaligned `entry`).

## 4. Calls

**Silica calling convention on Xtensa** (used for Silica functions and every runtime entry point):
windowed `CALL8`; argument *n* occupies a 64-bit pair. `X0`–`X2` travel in `a10`–`a15` (the callee's
`a2`–`a7`), which is exactly the standard ABI for three `int64` arguments. `X3`–`X8` and `D0`–`D7`
live in the core's **register block**: `silica_rt_core_regs` in `rt_start.S`, 128 bytes per core (`X3`
at 0 … `X8` at 40, `D0` at 48 … `D7` at 104, the auxiliary stack pointer at 112), reached through the
core's `THREADPTR` (`rur t, threadptr` -- one instruction, like the `movi` of an absolute address it
replaces -- then `l32i`/`s32i` with the offset). They are caller-saved registers on AArch64, so a single
block shared by every frame on a core reproduces their semantics exactly: a caller stages them before
the call, the callee reads them on entry, and nothing is preserved across a call -- which is what the
emitter already assumes. Each core has its own block, so both cores run emitted code at once (§8.9).
Results: integer in `a2:a3` (caller sees `a10:a11` = `X0`); a float result is written to `D0` in the
block, where the caller reads it. (An earlier design passed `X3`–`X7`/`D0`–`D7` in the caller's frame
at `[sp + SFRAME + off]`; it was dropped because a callee storing a float result into a caller frame
that does not expect one could corrupt that frame.)

Runtime functions written in assembly follow the same convention (every argument a pair). C and libgcc
functions are called with the standard windowed ABI; libgcc's `int64`/`double` signatures coincide with
it. Because `CALL8` clobbers `a8`–`a15`, an expansion that calls libgcc in the middle of an expression
(64-bit divide, float64 arithmetic) saves and restores `X0`–`X2` around the call in the frame's
`SVR_LC` area (32 bytes).

**Tail calls.** The windowed ABI has no tail call: `entry` needs the window rotation of a real `CALLn`.
A self tail call becomes a jump back to just after the prologue with the arguments reloaded, which is a
true loop. Other tail calls become `call8` + return and use stack; deep mutual tail recursion is
bounded by the stack (§6).

## 5. Runtime

Bare metal, in `board/runtime/*.S` (the IO-in-`.s` rule). Everything the Apple emitter inlined as
Darwin syscalls, libSystem calls or per-module `L_*_helper` bodies is a `silica_rt_*` entry point
here, called with the Silica pair convention of §4:

| File | Routines |
| --- | --- |
| `rt_vectors.S` | window overflow/underflow handlers (the ESP-IDF ones), alloca, fatal vectors, the debug vector for the stack guards |
| `rt_start.S` | `_start`: interrupts off, VECBASE, fresh window, `THREADPTR`, stack, watchdogs, `.bss`/heap zeroing, stack-guard watchpoints, `main`, exit marker; the per-core register blocks (`silica_rt_core_regs`) and the auxiliary stack; the APP cpu: `silica_rt_start_app_cpu`, `silica_rt_start_core1`, `silica_rt_stall_app_cpu` (§8.9) |
| `rt_console.S` | UART0 output, `print_i64/u64/bool/string`, `exit`, the runtime-abort entries (`silica_rt_abort_with`, `silica_rt_abort_<site>`), `badarith`, `case_clause`, the fatal fault report ([runtime_failure_reporting.md](../runtime_failure_reporting.md)); UART0 input: the `exit` line reader (§8.1) |
| `rt_heap.S` | first-fit free list with coalescing over a bump top, 8-byte block headers (`alloc`, `region_alloc`, `raw_alloc`), region blocks (`region_grow`, `region_contains`); `free` and `region_destroy` (the extension chain too) return memory; exhaustion is a runtime abort |
| `rt_string.S` | `string_concat`, `length_bytes/chars`, `eq`, `cmp`, `starts_with/ends_with/contains`, `substring`, `substring_until_char`; the 24-byte string header of the host |
| `rt_list.S` | `list_length/tail/at/prepend` over the emitter's chunked lists (constants packed into one argument word) |
| `rt_float.S` | `print_f64/f32/f16` with the host's digit algorithm (15 / 7 digits), `h2f`, `f2h`, `trunc_f32/f64` |
| `rt_ordering.S` | ordering identity tokens, canonical arenas, `checked_i64_add/mul/add1` |
| `rt_board.S` | GPIO, delay, cycle counter (used by the `asm_*` apps) |
| `rt_device.S` | `silica_rt_map_device_check`: the run-time twin of the board-pack window table (`emitter/ESP32-S3_raw/board_pack.silica`) for a computed `map_device` base; the abort `illegal device map` |
| `rt_actors.S` | the actor runtime (§8): the cooperative per-core scheduler, actor control blocks, mailboxes, `spawn`/`send`/`cast`/`call`/`self`, the PID registry actor, `remove_actor`/`kill_abnormal`, the failure report, `migrate_actor` and the topology queries, `wait_for_exit` and `cast_exit` (the exit request word and `main`'s wake) |
| `rt_supervisors.S` | the supervisor child table (§8.6): `materialize_init_children` for the start trampoline, restart policies and strategies, the `call_supervisor` helpers |

## 6. Limits of the first version

- Everything runs from internal SRAM (~390 KB for code, data, heap and stack). No flash XIP, no PSRAM.
- `main`'s machine and auxiliary stacks (the latter the emitter's `SP`) are sized per image by
  `board/tools/main_stack_bound.py` through `build_image.sh` (two links; `_silica_main_stack_size`,
  `_silica_main_aux_size` in the linker script), with 128 KB + 64 KB as the documented default for a
  `main` the static walk cannot bound (recursion, or a call through a function value); heap = the rest.
  Both stacks have a 64-byte guard at the bottom watched by an Xtensa data breakpoint (`DBREAKA0/1`,
  store-only), and emitted code compares its stack pointers with the running context's limits
  (`VRG_MLIMIT`, `VRG_ALIMIT` in the per-core register block) so a frame larger than the band cannot
  straddle it unseen; an overflow is reported as a fatal fault (spec §15.4.5.5: `[silica] fault at
  0x<pc>`, status 70, the report a host process gives for the same overflow), with cause 1006 in the
  details after the exit marker. See `board/README.md`, "Stack budget".
- One cooperative scheduler per core, both LX7 cores running actors (§8.9); interrupts off; no FFI (the guarded-FFI runtime is setjmp/signal based).
- Non-self tail calls use stack.

## 7. Order of work

Driven by the early apps in `board/apps/silica_*` (each has the macOS reference output, produced by
`board/tools/host_reference.sh`). Steps 1-7 are done and pass on the test board (2026-09-12):

| Step | App | Emitter pieces |
| --- | --- | --- |
| 1 | `silica_00_return42` | module prelude, sections, function frame/prologue/epilogue, int64 constants, atom tables |
| 2 | `silica_01_arith`, `silica_02_calls` | lets, int64 arithmetic, calls, parameters, recursion, case on booleans |
| 3 | `silica_03_case_bool` | comparisons, and/or short circuit, nested case |
| 4 | `silica_04_print`, `silica_05_int64_wide` | print runtime, 64-bit multiply/divide |
| 5 | `silica_06_strings` | string runtime (concat, length, substring) |
| 6 | `silica_07_recursion_depth`, `silica_08_stack_guard` | frame size under deep recursion; the stack guards |
| 7 | `silica_09_lists` … `silica_14_wbt_map` | lists, records/tuples, regions/refs/bufs, floats, checked int64, the stdlib map |
| 8 | the actor trial suites | the actor runtime (§8): the cooperative scheduler, supervisors, placement |
| 9 | `actors_addition/actor_cross_core_call_reply`, `actor_cross_core_cast_stress`, the three actor suites again | core 1 (§8.9): both LX7 cores run actors |
| 10 | `silica_16_device_uart` to `silica_22_device_buzzer` | peek and poke, the device workers and the drivers under `board/apps/device_lib` ([esp32s3_peek_poke_implementation_plan.md](esp32s3_peek_poke_implementation_plan.md)) |
| 11 | next | the remaining trial suites of port status §4.3 |

## 8. Actor runtime

The runtime the Apple emitter carries as emitted AArch64 text (`apple_silicon_mac/terms/prims/
prims_actors_runtime_asm.silica`: pthreads, `os_unfair_lock`, `__ulock`) is here a hand-written part of
the board pack, `board/runtime/rt_actors.S` and `rt_supervisors.S`, called through the same
`silica_rt_*` entry points by `terms/prims/prims_actors.silica` (the Apple dispatcher's operand staging
spelled with the AArch64 virtual registers and turned into Xtensa by `shared/xt_*`). The observable
behaviour follows the reference routine for routine; what follows is what the bare-metal model changes.
This is the OS-free reading of spec §15.1.2 (Actor Pinning Policy, dispatch boundaries and yield
points), §15.1.2.2 (stacks), §15.1.2.3 (termination), §22.10 and §23.1.1.

### 8.1 Contexts and the scheduler

There is no thread. A **context** is a windowed-ABI machine stack plus an auxiliary (emitter `SP`)
stack and a saved `(a0, a1, auxiliary stack pointer)`: `main` (the boot stacks; a pseudo-ACB pinned to core 0),
every actor (its ACB), and one **scheduler** per core (a pseudo-ACB with a 4 KB stack and no auxiliary
stack: it runs no emitted code). Each core has a core block with three ready queues (high, normal,
low priority), the running context and its scheduler.

The scheduler loop pops the next ready context of its core, highest priority first, records it as the
core's current context, arms the stack guards for it and switches to it. The context switches back
when it parks (an actor whose mailbox is empty), suspends (a `call` awaiting its reply, `main` in
`wait_for_exit`, `supervision_wait_and_drain_one`) or ends. Between those points nothing is preempted:
interrupts are off, and a message arriving from another core only puts the target on a ready queue.
After every dispatch an actor re-queues itself (when messages wait) or parks, so actors sharing a core
take turns (§23.1.1). `set_actor_priority` chooses the queue an actor waits in, and the program's
dispatch-order policy (§8.10, `set_scheduler_policy`) chooses which queue's head runs next.

`main` is a context like the others: `call` from `main` suspends it; `wait_for_exit()` parks it
(status `ST_WAITQ`, which nothing else sets) until an exit request is recorded, then returns the
recorded `int64` value to `main` (`a2:a3`). `main` continues, and the program ends when `main`
returns, through the image's ordinary end of `main` (`rt_start.S` -> `rt_console.S` `silica_rt_exit`:
the exit marker with `main`'s result as the status, then halt, core 0 stalling the APP cpu first);
the actors are abandoned. A program that has gone quiet waits (spec §15.1.2.5; the earlier
quiescence ending is gone). The two triggers:

- `cast_exit(value)` from any actor on either core: `silica_rt_cast_exit` passes the two words of the
  value to `silica_rt_exit_request_record`, which under `silica_rt_sched_lock` records the first
  request (`silica_rt_exit_flag` 0 -> 1, the value in `silica_rt_exit_request`) and, when `main` is
  parked, marks it ready on core 0's queue; a later request returns 0. `wait_for_exit` checks the flag
  under the same lock before parking, so a request made while `main` was still running (say, during a
  `call` it was waiting on) returns the moment `main` reaches its wait, and `main`'s call wait is never
  woken by it.
- the console's receive side, the program's standard input on this target: core 0's scheduler loop
  pops the UART0 RX FIFO on every pass (`rt_console.S` `silica_rt_console_poll_exit_line`, a
  three-word matcher for a line reading exactly `exit`, one trailing carriage return ignored, every
  other line discarded) and a completed `exit` line records a request with value 0. The scheduler is
  the reader because it runs only while `main` has yielded, which is when a line can be acted on, and
  a dispatch that never returns stops it along with everything else on the core. The loader's
  leftovers in the FIFO are discarded before `main` runs (`rt_start.S`).

### 8.2 The context switch

`silica_rt_ctx_switch(save, load)` spills every live register window above its own to the stacks they
belong to (the `SPILL_ALL_WINDOWS` trick from Zephyr / ESP-IDF `xt_asm_utils.h`: write a high register
in each rotation of the window and let the overflow exception spill the frame that owns it; sixteen
rotations return to the starting window), saves `a0` (return address with the window increment), `a1`
and the auxiliary stack pointer, loads the other context's, and returns with `RETW`, which reloads
that context's caller frame from its own stack through the underflow handler. A context is first
entered through two fabricated frames at the top of its stack (`silica_rt_ctx_prepare`): the `RETW`
lands in a trampoline with the ACB in `a2`, which calls the actor's loop (`silica_rt_actor_main`) or
the scheduler loop. Emitted code keeps its caller-saved virtual registers (X3-X8, D0-D7) in its core's
register block (§4); a switch happens only inside a runtime call, which the emitter treats as
clobbering them, so nothing else is saved. The block's auxiliary stack pointer is the one word of it a
switch saves and loads.

The behaviour itself is called under a 1.5 KB padding frame (`silica_rt_run_behaviour`): a reply may
point into the behaviour's frame region (a tuple or record built there), and the loop's own frames
after the return (waking the caller, yielding) fit inside the pad, so the region is intact when the
caller reads the reply. The reference gets the same effect from running user frames on the actor's
stack and the loop on the thread's.

### 8.3 Stacks

Spec §15.1.2.2: an actor's stack is runtime-managed, starts small, grows on demand with no limit and
is released at the dispatch boundary by the actor's `stack_policy` algorithm. The board has no demand
paging, so each of an actor's two stacks -- the machine stack of windowed frames and the auxiliary
stack of the emitter's `SP` -- is a chain of heap chunks (`rt_actors.S`, "Growable stacks";
`actor_memory_budget_plan.md` item F). A chunk is a 64-byte-aligned heap block: a 64-byte header
(chain links, size, the entering frame's return address or the entering reservation's previous `SP`,
the limit, top and band addresses, the chunk's index in the chain), a 64-byte guard band watched by a
data breakpoint, and the frames or slabs above, filled downward from the top. Nothing is taken at
spawn: the scheduler gives an actor its first chunks when it dispatches it with none (2 KB machine,
512 B auxiliary, chosen from the use measured under item E so a replying worker never grows), and
re-enters the actor loop afresh at every dispatch, so the loop's own frames are at the top of the
first chunk and the stack is empty at the boundary.

Growth is where emitted code checks its limits. Every prologue compares its new `a1` with the machine
limit the context switch publishes (`VRG_MLIMIT`: the current chunk's band top plus
`_silica_rt_depth_reserve`, the deepest runtime chain emitted code can call, which the growth chain is
part of); below it, the frame -- which holds nothing yet -- parks itself 32 bytes under the limit with
`MOVSP`, calls `silica_rt_stack_grow`, and moves itself with a second `MOVSP` to the top of the next
chunk (the retained one above the current chunk when it is big enough, else a fresh one: twice the
previous chunk up to 16 KB, or the frame plus 1 KB of headroom when that is larger). Both `MOVSP`s
run with a windowed return address in `a0`: the alloca exception handler reads the call size from it
when the caller's window has to be reloaded, so a plain `CALL0` return address there (an earlier
form of this prologue) made it reload a four-register window and the frame's `RETW` then faulted. The frame's `a0` becomes `silica_rt_chunk_return`, with the real return address kept in the
chunk header; when the frame returns, `RETW` lands there in the caller's window, the chunk below is
made current again and the real return address is jumped to with `a0-a7` and the result intact. The
windowed ABI stays exact across the move because every spill and reload of a frame's registers is
addressed through the `a1` of the frame above it, and `MOVSP` reloads the caller's window through the
alloca exception if the parked chain spilled it. Every auxiliary reservation compares the new `SP`
with `VRG_ALIMIT`; below it the reservation's size goes to `VRG_ARG` and `silica_rt_aux_grow` moves
`SP` to the top of the next auxiliary chunk (512 B doubling to 4 KB, or the slab plus 256), keeping
the previous `SP` in the header; every release compares with the chunk's top (`VRG_ATOP`) and
`silica_rt_aux_release` pops back when it is reached (a restore of a saved `SP`, the self-tail-call
stub's, is checked on both sides and pops as far as it needs). Growth never fails as such: a heap
exhausted is a runtime abort, the host's out-of-memory outcome. A lowered reservation
(`stack_policy(n, ...)`) caps what the chunks of both stacks may hold together; reaching it ends the
actor with `(:explicit, :stack_exhausted)` by a store into the guard band, the same debug exception a
real overflow raises. `main` is not an actor: its two stacks are fixed, sized per image by
`board/tools/main_stack_bound.py` (a static walk over the linked image, run by `build_image.sh`), and
a limit it crosses is a fatal fault.

Release is the scheduler's, after the switch back, never on the stack being released: at the
boundary `silica_rt_actor_release_policy` keeps a prefix of each chain and frees the rest --
`:release_on_return` nothing, `:keep_last_message` what the dispatch reached, `:track_recent_peak`
the most any of the last 32 dispatches reached (a ring in the ACB), `:keep_high_water` everything,
and `:release_when_idle` everything until the core's scheduler, scanning its idle actors every quarter
second, finds one with no message for a second (the 16 MHz system timer). `get_actor_memory_usage`
reports the chunks held (committed, retained), the most each chain has held (high water), and as
reserved the lowered reservation or, at the default, the whole heap. The end-of-program diagnostic
line reports the most any actor and supervisor held (`board/README.md`, "Stack budget"). Freed chunks,
ACBs and message nodes go on free lists. `silica_rt_run_behaviour` does not pad the behaviour's frame
region: composite replies and states are heap copies (item B), so nothing points into that region once
the behaviour has returned.

Every switch and every chunk change re-arms the two data breakpoints (`DBREAKA0/1`) on the guard at
the bottom of the current machine and auxiliary chunk of the context about to run, `main`'s two
stacks included; the scheduler runs with them disarmed. A store into a band is a debug exception that
ends that actor only, with failure reason tag 4 (`(:explicit, :stack_exhausted)`), instead of
corrupting memory; with growth it is reached only through a lowered reservation.

### 8.4 Failures inside an actor

`rt_vectors.S` calls `silica_rt_actor_fault_hook` from the fatal trampoline: when the core's current
context is an actor, the actor is marked failed (tag 3 `:memory_fault`, or 4 for a stack-guard hit),
queued for its exit path, and the scheduler context is resumed directly (the trampoline's fresh
window state is what makes the `RETW` reload the scheduler's frame); the process report of
[runtime_failure_reporting.md](../runtime_failure_reporting.md) is written only when the fault is
`main`'s or the runtime's. `badarith` and `case_clause` (`rt_console.S`) call
`silica_rt_actor_trap(1)` in an actor: the exit path runs on the actor's stack and the scheduler
continues.

The exit path (`silica_rt_actor_exit`) is the reference's: the supervisor's ingress receives the
structured exit notice (or the root note `[silica] root actor exited (no supervisor)` is printed),
the failure report is printed (or cast to a registered root `FailureReporter` as a Silica string), the
outstanding calls complete with the death result 0, the rest of the mailbox is dropped, the registered
name is removed, the ACB is marked dead. Frame #0 of the report names the behaviour through the
`{address, name}` records the emitter writes for every function (`.rodata.silica_fnames`, kept by the
linker script between `_silica_fnames_start` and `_end`), the board's stand-in for `dladdr`.

An actor that another actor ends (`remove_actor`, `kill_abnormal`, a supervisor's stop) and that is not
running -- parked, suspended in a call, or queued -- is ended synchronously in the caller's context
(`silica_rt_end_actor`), which is what makes the supervisor's sequential stop (§15.4.12.2) a plain
call instead of the reference's spin on the row's `exit_done` flag. The running actor itself ends
after its behaviour returns, as the reference does. An actor running on another core ends at its next
dispatch boundary.

### 8.5 Pinning and placement (spec §15.1.2, §22.10)

Every actor is pinned to a core from spawn: `spawn`'s core argument when it names a running core
(0 is also "runtime-assigned", as in the reference's ABI), else round robin over the running cores.
`migrate_actor(ref, core)` returns 0 `:ok` (pin moved; applied at the next dispatch boundary when the
actor is running or queued, at once when it is parked or suspended -- its mailbox is its own, so
message order is preserved, §15.1.2.4.1), 1 `:invalid_target` (not a running core), 2
`:actor_not_found` (no such live actor); the emitter maps the code to the program's own atom indices at
the call site (`emit_prim_op_with_atoms`), because atom indices are per executable. `pin_actor_to_core`
is a move; `pin_actor_to_performance_core` moves to core 0; the two LX7 cores are alike and both report
as `:performance`, so `get_efficiency_cores()` is empty and `pin_actor_to_efficiency_core` is a no-op
returning 0. `get_cpu_topology()` and `get_core_capabilities(id)` build the emitter's record and list
layouts (a core_info per running core, capabilities empty, frequency 0 as on the host, no NUMA nodes, no
cache levels; an unknown id gives the sentinel `id: -1`).

### 8.6 Supervisors

`rt_supervisors.S` ports the reference child table unchanged in shape (88-byte rows, tombstones,
`materialize_init_children` walking the child-spec list of 64-byte cells, `start_child`, the
`call_supervisor` helpers, `maybe_restart` with the `:permanent`/`:transient` policies, the restart
frequency cap in seconds from the 16 MHz system timer, and the `:one_for_one` / `:one_for_all` /
`:rest_for_one` strategies). Exit notices are processed either by the supervisor's own loop (an
ingress message) or, as in the reference, by whoever calls a supervisor helper (`drain_ingress`).
A supervisor whose restart cap is breached reports and ends, and an ending supervisor first shuts its children down (`silica_rt_sup_shutdown_children`, spec §15.4.8.4): deepest first, last row first, a child with shutdown 0 killed with reason tag 1 and one with shutdown > 0 ending `(:explicit, :shutdown)`; the shutdown time is not enforced because nothing is preempted. A child supervisor's `SB` is a 64-byte side block that only supervisors get, and a duplicate child id in a started `init` list ends the supervisor (`silica_rt_supervisor_fail_duplicate_child_id`; E2235 catches the literal case).

### 8.7 Registries

The three PID registries (ordinary, dangerous, device) are runtime actors spawned by `silica_pid_registry_init` (injected by the
emitter at the top of `main`); their behaviour is written in the emitted-function
ABI and answers `{op, name, pid}` messages (offsets 8/16/24 after the shape word) with a `(status, pid)` pair; each table has one slot per atom of the image
(`silica_registry_slots`, written into `__silica_runtime.sams` by the emitter; the keyed forms use it to tell an atom from an ACB address), and is written directly by `register_actor_named` and read by the `_registered` call/cast forms.
A name already held is refused (`:name_taken`, `:already_registered`, `:actor_not_found`; a registered spawn of a taken name fails the spawner with `:language_error`), and a dying actor's name is removed (§20.3.1).

### 8.8 What is not done

- `link` / `monitor` / `demonitor` return the reference's benign values (its Phase G surface).
- Ending an actor that is running on another core waits for its next dispatch boundary.

### 8.9 Two cores

Both LX7 cores run actors (2026-09-28). The scheduler of §8.1 was already per core; what made core 1
runnable is the following, in the order a program meets it.

- **Per-core register blocks.** The emitted code's caller-saved virtual registers and its auxiliary
  stack pointer are in a per-core block reached through `THREADPTR` (§4): `_start` points core 0's
  `THREADPTR` at `silica_rt_core_regs`, core 1's entry at the second block; `shared/xt_vr.silica` and
  `xt_mem.silica` emit `rur` instead of the old `movi silica_rt_vrg+off`; the runtime readers
  (`silica_rt_ctx_switch`, the fault hook, `silica_rt_actor_spawn*`, `silica_rt_region_grow` /
  `_contains`, the supervisor child spawn) do the same.
- **Starting the APP cpu.** `silica_rt_actors_init` (core 0, at the first actor entry point) ends by
  calling `rt_start.S silica_rt_start_app_cpu`: the ESP-IDF sequence for the chip -- clear the RTC
  software stall of the APP cpu (`RTC_CNTL_OPTIONS0` / `SW_CPU_STALL` "c0"/"c1" fields), then in
  `SYSTEM_CORE_1_CONTROL_0_REG` enable the clock, clear RunStall and pulse `RESETING`, then hand the ROM
  the entry with the ROM function `ets_set_appcpu_boot_addr` (0x40000720). Core 1 lands in
  `silica_rt_start_core1` (interrupts off, VECBASE, one live window, PS, guards disarmed, `THREADPTR`,
  a 2 KB boot stack), calls `silica_rt_core1_main`, which switches from a boot pseudo-ACB nothing ever
  resumes into the core's prepared scheduler context. A program that never touches actors never starts
  core 1. `silica_rt_ncores` is `NCORES_RUN` (2; 1 rebuilds the one-core runtime for diagnosis).
- **The heap bump is a compare-and-swap** (`rt_heap.S`, S32C1I on `silica_rt_heap_next`), and the free
  lists of ACBs, message nodes and stacks take their own lock (`silica_rt_free_lock`) inside the six
  list routines, because some callers hold the scheduler lock and some do not (the list routines call
  nothing that locks, so the order scheduler lock -> free lock is the only one).
- **The console lock** (`rt_console.S`): one word, owned by a core (id + 1), re-entrant on the owner
  through a per-core depth, taken at the entry of every output routine, so `print_i64 -> print_u64 ->
  write -> putc` nests and each routine's output is one piece. A core that ends a routine mid-line
  keeps the lock (the line hold) until it writes a newline or yields, so a `println` (two routine
  calls) or `print_string` followed by `print_int64` is one line and only whole lines interleave; a
  context switch releases the hold, so a line waits only for straight-line code on the other core,
  never for a message. (Before the hold, `supervisors_addition/record_message_cast_between_actors`
  showed a core-1 actor's `21` inside `main`'s `println`.)
  The actor failure report is composed in one shared buffer and written under the lock. Both cores' last-byte words start as newline (2026-10-16), so a report written before either core has printed cannot leave the lock held by a line hold. A context
  abandoned by a fault may hold the lock: the actor fault hook releases this core's hold. A
  process-fatal report (fatal or abort trampoline) on either core first claims the fatal-owner word; the claiming core stalls the other core (RunStall through the RTC stall bits) and clears the lock. Each core has its own fault stack and fault counter (2 KB more heap). `silica_rt_halt` stalls the APP cpu after the
  output has drained, so nothing prints after the exit marker; the chip reset before the next load
  clears the stall.
- **Idle cores peek.** An idle scheduler spins on a lock-free read of its three ready heads (and, on
  core 0, of `main`'s wait-for-quiescence status) and takes the scheduler lock only when it sees
  something, so an idle core does not slow the busy one with lock traffic; `CORE_BUSY` is cleared on the
  idle path and re-read under the lock by `silica_rt_all_quiescent`.
- **What a program sees.** `spawn(.., 1)` and `migrate_actor(ref, 1)` place an actor on the APP cpu;
  `0` is runtime-assigned (round robin over the two cores, as the reference); `get_cpu_topology()`
  reports two `:performance` cores. Covered by `actors_addition/actor_cross_core_call_reply` (calls
  crossing cores both ways, state kept on core 1) and `actor_cross_core_cast_stress` (a 400-message
  ring whose hops alternate direction, so both cross-core paths, the free lists, the heap and the
  console are used by both cores at once).

### 8.10 Dispatch-order policies for actors sharing a core

`set_scheduler_policy(policy: atom) -> :ok | :invalid_policy` (`proc[concurrency]`, 2026-09-28) lets a
program choose how the ready actors *of one core* take turns. One policy is in force for the whole
program and every core applies it to its own ready queues. It decides nothing else: it never moves an
actor between cores (`migrate_actor`, spawn's core argument and the round robin over cores at spawn
are untouched) and never interrupts a running actor -- a switch still happens only at a dispatch
boundary or where the actor suspends (§15.1.2, §23.1.1), and that invariant does not depend on the
policy. The four names are ordinary atoms a program passes to a prim (no claimed names, no fixed
indices): the emitter maps the program's own atom indices to the runtime's codes at the call site and
the result code back (`prims_actors.silica emit_set_scheduler_policy`, the `migrate_actor` pattern), so
an atom the program never names cannot be selected. Any other atom answers `:invalid_policy` and
leaves the policy as it was. The call may be made at any time; it takes effect at the next push or
pop of a ready queue on every core.

The three per-core priority queues of §8.1 stay the storage under every policy; only the queue chosen
at push and the queue chosen at pop depend on the policy (`silica_rt_rq_push`, `silica_rt_rq_pop`,
`silica_rt_rq_take`; the core block gained the three queue lengths and the weighted-fair tier and
credit). The `priority_level` an actor was given with `set_actor_priority` is its weight class:

| Policy | Push | Pop |
| --- | --- | --- |
| `:priority_fifo` (default) | the actor's priority queue | the head of the highest-priority non-empty queue -- what the runtime always did |
| `:round_robin` | the normal queue, whatever the priority | the same scan, so one flat queue in strict arrival order |
| `:weighted_fair` | the priority queue | deficit round robin over the three tiers with a unit cost per dispatch: the tier being served runs its head while it has credit and actors, then the next tier starts with a fresh quantum, an empty tier forfeits its quantum (DRR zeroes an idle queue's deficit). Quanta high 4, normal 2, low 1; shares are per tier, FIFO within a tier; O(1) per pick, nothing starves |
| `:lottery` | the priority queue | Waldspurger-Weihl lottery: a tier holds weight x (actors queued) tickets with the same 4 / 2 / 1 weights, a xorshift32 draw picks the tier in proportion to its tickets and the tier's head runs. Choosing the tier and then its head keeps a pick O(1); FIFO within the tier gives every actor of a tier the same turns, so an actor's expected share is its ticket share. The generator (Marsaglia's 13 / 17 / 5 xorshift32, one word under the scheduler lock) is seeded from `CCOUNT` at the first draw; nothing in the runtime or the standard library provided randomness before, and this needs none of cryptographic strength |

A policy change with actors queued is kept simple rather than clever: the queued actors stay where they
are. A switch to `:round_robin` first drains what already waits in the high and low queues, in the old
order; a switch away from it treats what waits in the flat queue as normal until each actor's next push.

`set_actor_priority`'s level is the atom type `priority_level = :low | :normal | :high` (spec §22.10);
the emitter now maps those atoms to the runtime's levels at the call site too (`emit_set_actor_priority`)
and the runtime answers `:actor_not_found` for no actor or an ended one. Before this the atom index
itself reached the runtime, which clamped every index above 2 to normal, so the priority queues had
never been exercised: the new trials are the first to run them.

Hosted targets now have a ready queue per carrier thread (item N of
`actor_memory_budget_plan.md`; carriers on `apple_silicon_mac`, and on Linux AArch64 and x86-64 in
`aa8101edf2` and `ef2e778126`), so `set_scheduler_policy` is real there: each target's
`prims_actors_carrier_asm.silica` defines `silica_rt_set_scheduler_policy`, which selects one of
`:priority_fifo`, `:round_robin`, `:weighted_fair` and `:lottery`, applied by every carrier to its own
queues as the board applies one per core. (Before the carriers, hosted actors were threads the OS
schedules and the call was a no-op answering `:ok` for any atom.) Trials:
`trials/scheduler_policy_addition` (its README says how the order trials are compared on a target that
defines no order). No specification change: this is a runtime configuration choice made through an
ordinary atom argument, not a new normative guarantee.

**What is not done -- a fifth, BEAM-style policy (future work, documentation only).** A natural fifth
policy is one modelled on the BEAM's reduction counting: every dispatch would get a bounded budget of
execution steps, and the runtime would force a yield when the budget runs out instead of waiting for
the behaviour to return or the actor to suspend. It is deliberately not implemented, and nothing here
prepares for it, because it introduces a yield point the specification does not define. §15.1.2 is
strict about the two kinds there are: a *dispatch boundary* is the moment a behaviour function returns,
and a *scheduler yield point* is a dispatch boundary or a point where the running actor suspends to
wait; a yield forced by an exhausted reduction budget is neither, and §23.1.1 builds on the same two
kinds. Before any implementation is attempted, the specification (§15.1.2 and §23.1.1) would have to
define that new yield-point kind and say how it interacts with the existing guarantee that nothing
preempts an actor between yield points -- which this policy would, by construction, break for the
actor whose budget ran out. Until then the four policies above are the whole of the feature, and every
one of them keeps the invariant that a running actor stops only where §15.1.2 says it may.
