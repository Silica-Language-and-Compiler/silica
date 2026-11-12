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
                         registry table pointers, scheduler stack 1 KiB; the registry tables themselves are heap blocks, 3 x 4 B per atom)
                   heap arena 0: the leftover (first fit, 16-byte blocks; ACBs, message nodes,
                         mailbox buffers, state chains, copier tables, SBs, rows, and the stack
                         chunks arena 1 cannot hold)
                   main's machine stack 6 KiB (grows down from the top; fixed: never moved,
                         enlarged or made growable)
       0x20018000
SRAM2  0x10000000  fault stack 1 KiB (the fatal report runs here whatever the SRAM1 stacks hold)
       0x10000400  main's auxiliary stack 2 KiB (the emitter's SP)
       0x10000C00  heap arena 1: actor stack chunks only (machine and auxiliary), 29,696 bytes
       0x10008000
```

**Two heap arenas (2026-11-09, Lee's decision).** `rt_heap.S` keeps one first-fit heap per region.
Every runtime block comes from arena 0 (SRAM1); `silica_rt_chunk_take` (the only user of
`silica_rt_alloc_chunk_or_null`) takes a stack chunk from arena 1 (the SRAM2 left after the fault stack
and main's auxiliary stack: `_silica_sram2_heap_start` .. `_silica_sram2_heap_end`) first and falls back
to arena 0. A chunk is one block, so it lies wholly in one region and the limits the emitted code compares
(`VRG_MLIMIT`, `VRG_ALIMIT`, `VRG_ATOP`) are within it; nothing assumes an address order between two
chunks of a chain (`silica_rt_aux_release` pops on any address outside the current chunk, every emitted
restore is checked on both sides, `rt_is_old` and `silica_rt_in_aux_chain` test each chunk's own range),
so a chain mixes the regions freely. `silica_rt_free` finds a block's arena by address. ACBs stay in SRAM1
(`rt_ref_acb` checks a reference against the SRAM1 heap). Arena 1 is not zeroed at boot: every block is
zeroed when it is handed out. The exit diagnostic prints both: ` heap: in use U free F sram2: in use U2
free F2`; `get_heap_in_use` answers the sum.

**The FFI stack (2026-11-10).** A foreign call in an actor runs on a machine chunk of that actor's own
chain (rt_ffi.S), so it is placed like every stack chunk: SRAM2's arena 1 first, then SRAM1, and it goes
back with the actor's release policy. Its size is `_silica_ffi_stack_size` (2 KiB; `BOARD_FFI_STACK`
in build_image.sh) above the chunk's limit, so the chunk is at least 2 KiB + 64 + 128 + 512 + 1,024 =
3,776 bytes (4 KiB when the doubling rule gives more). Nothing is reserved for it in the linker script
and the fault stack, main's auxiliary stack and the arena stay where they were. A foreign call in main
runs on main's fixed 6 KiB machine stack (not moved, not enlarged).

Budget, measured on compiler_addition/actor_call_record_msg (a base-suite image with trial support:
.text 30.0 KiB, .bss 2.7 KiB): SRAM1 heap 59,312 bytes, SRAM2 arena 29,696 bytes. An actor at its first
dispatch costs 224 bytes of SRAM1 (the 208-byte ACB and its block header) plus 2,064 + 528 bytes of chunks
(2 KiB machine + 512 B auxiliary with their headers). Before: everything in SRAM1, 2,816 bytes an actor,
21 actors. After: the first 11 actors' chunk pairs (28,512 bytes) and 2 more auxiliary chunks fit in SRAM2,
so 2,816 N - 22,704 - 6,864 <= 59,312 gives 31 actors (+10, +48%). An actor with a described state also
holds a 2,064-byte state chain in SRAM1, and each queued message a 64-byte node (80 with its header) plus
its mailbox buffer.

Measured on the smoke images (2026-11-07): .text 8.5 KiB (stubs included), .bss 2.7 KiB, heap 80.9 KiB
(`0x20002bf0-0x20016800`), SRAM2 used 3 KiB of 32 before the chunk arena. An emitted base trial on the ESP32 is ~3,300 lines
of Xtensa; the Thumb-2 form should be 10-15 KiB, leaving ~65-70 KiB of heap. Per actor at its first
dispatch: ACB 208 B + 2 KiB machine chunk + 512 B auxiliary chunk (+ 72 B SB and 112 B row for a
supervisor's child); chunks double to 8 KiB / 2 KiB. The base trials run four contexts (reporter,
supervisor, worker, main's pseudo-ACB): under 12 KiB. Defaults to override per image:
`BOARD_MAIN_STACK`, `BOARD_MAIN_AUX` (build_image.sh), and the runtime depth reserve
`_silica_rt_depth_reserve` (512 B; the deepest runtime chain under an emitted frame, plus an
exception frame). `_start` zeroes `.bss` through the main stack top and the used SRAM2 range before
anything runs; the probe loads the ELF (`.sram2` is NOLOAD) and resumes at `_start`, which sets sp
and VTOR first.

Clock: SYSCLK 80 MHz (the part's rating) from the PLL on HSI16 (PLLM /1, PLLN x10, PLLR /2; voltage
range 1, the reset default; flash latency set to 4 wait states before the switch, although the image
runs from SRAM); AHB, APB1 and APB2 undivided, so PCLK1, USART2's clock, is 80 MHz too. SysTick
(reload 79,999) at 1 ms keeps `silica_rt_ticks_ms`. Console: USART2 on PA2/PA3 (AF7), 115200 8N1
(BRR 694: 0.06% fast), transmit polled, receive through the RXNE interrupt into a ring, the Nucleo's ST-LINK virtual COM port (`/dev/cu.usbmodem21103`).

**Flash images, by hand only (2026-11-12).** `BOARD_EXEC=flash tools/build_image.sh ...` links with
`runtime/silica_stm32l476rg_flash.ld` (code and constants at 0x0800_0000, `.data` copied from flash by `_start`;
the RAM default is unchanged and byte-identical), and `tools/run_on_board.py --exec flash --yes-wear-flash`
programs it. Every load wears the flash, so the trials never use it: `build_image.sh` refuses flash with `-r`
(the harness's runtime cache) and the RAM loader refuses a flash image. Design:
`compiler/design_documents/stm32_flash_execution_design.md`; example: `examples/nucleo_flash_max_actors/`.

**Open item: image headroom (found 2026-11-10, no trial).** The image runs from SRAM1, so every byte of
`.text`, `.rodata` and `.data` comes out of the heap, and `silica_stm32l476rg.ld` refuses an image that leaves
less than 16 KiB of heap (`ASSERT(_silica_heap_start + 0x4000 < _silica_heap_end, "program too large: less
than 16 KiB left for the heap")`). A Nucleo program that added a few more print statements tripped it: each
`print_*` call site and its string literal grow `.text` and `.rodata`, and there is no spare SRAM1 left after
the runtime. This is a capacity limit, not a compiler defect with an observable fixed behaviour (the correct
output of such a program is the same on every target), so no staged trial exists; a trial would only encode
today's image size. The levers are a smaller image (emitted code size, shared print helpers) or running
`.text`/`.rodata` from flash (the part has 1 MiB; the image runs from RAM only because the probe loads nothing
into flash). Whichever is chosen, re-measure the budget above.

## Runtime: what is here (stage 1) and what is not

| File | Here | Not yet |
| --- | --- | --- |
| `rt_vectors.S` | vector table, SysTick, USART2's receive interrupt (IRQ 38), the fault vectors (2026-11-09): on the SRAM2 fault stack a HardFault / MemManage / BusFault / UsageFault taken in thread mode while an actor runs ends THAT actor (`rt_failure.S` `silica_rt_actor_fault_hook`, :memory_fault, tag 3) and the scheduler is resumed by an exception return; in main, the scheduler or an interrupt handler it is the fatal report (status 70); `silica_rt_fatal_depth` sends a fault raised while a fatal or abort report runs to the last-resort line (70) | DebugMonitor / MPU stack guards (the limit checks are the guard) |
| `rt_start.S` | `_start`: VTOR, FPU, the MPU null guard (2026-11-09: 0x0-0xFFFFF, the readable boot alias of flash, is no-access, so a null dereference is a MemManage fault as on the ESP32-S3 and the hosts), clock, console, zeroing, register block, runtime init, markers | the two-pass per-image main-stack bound (`main_stack_bound.py`) |
| `rt_console.S` | USART2, putc/write/puts, the interrupt-filled 64-byte receive ring (2026-11-09: the USART has a one-byte receive register, so an `exit` line sent while the scheduler slept in `wfi` overran it and was lost), print_i64/u64/bool/char/string, exit marker, `exit` line reader, runtime aborts (71), fatal report (70) | |
| `rt_heap.S` | two first-fit arenas with coalescing (SRAM1: every runtime block; SRAM2: stack chunks first), zeroed blocks, the exit summary | |
| `rt_frame.S` | `dyn_alloc`, `adopt`, `frame_alloc`, `in_aux_chain`, aux chunk append/publish, `ev_frame` (the evacuation of a function's result through the copier: in an actor into a fresh auxiliary chunk after the deepest one, in main into scratch below the callee's SP then moved up under p; 2026-11-09) | |
| `rt_state.S` | the state chain (chunks, 129 free-list heads, holes, `state_alloc` / `free` / `contains`, the release log), **the copier in all its modes** (frame rule and chain-node "old", bump and chain destinations), `state_install` and `state_dispatch_end` for described states (proven evacuation, unproven / compaction fallback), `message_buffer`, `message_forward`, `reply_place`, `state_retire`, `state_log_drain`, `state_retain_node`, `state_area_bytes`, `compact_state` (2026-11-09) | |
| `rt_string.S` | every string routine; the UTF-8 classes are the hosts' (a sequence start counts one character and skips its lead length, a stray continuation byte or 0xF8..0xFF counts one by itself; `substring` advances by the same classes) | |
| `rt_list.S` | length, tail, at, prepend (in place and copy-on-write) | |
| `rt_transport.S` | the transport builtins that touch a string or a list (`silica_rt_tr_*`: byte_at, byte_slice, bytes_of, join_bytes, atom_name, atom_index_of_name); the scalar ones are register work in the emitter's `prims_transport.silica` | the transport_addition suite itself (skipped on this board) |
| `rt_actors.S` | init, scheduler loop, context switch, chunk chains + growth entries, spawn (plain, linked, supervisor trampoline wait), cast / send / registered casts (a cast to a call-only actor is a convention mismatch; the ESP32-S3's back-pressure: a sender whose target has 16 messages queued yields until the queue shortens or 200 ms pass), **call / call_registered** (the caller parks with its SP, floor and chunk in the node; the reply placed by `reply_place`; a target that ends first completes the call with the death result, the caller raises actor_not_found), `recv`, the registry actor of `get_registry_actor` over the plain table (:insert / :lookup / :delete), the three registries sized per image (one slot per atom: `silica_registry_slots`, heap tables made by `actors_init`; 64 fixed slots before 2026-11-09 lost every name whose atom was 64 or above), `behaviour_name`, registries as tables, `wait_for_exit` / `cast_exit`, reporter registration, clocks, the scheduler's part of an actor's end (the exit path of an actor that ended where it stood, status `ST_FAULTED`, or at its boundary with alive cleared), benign pinning/link returns; an exit notice in a supervisor's ingress runs the restart logic (rt_supervisors.S); a supervisor's ACB is recycled by the last of its holders (its end, its spawner `TR_SPAWNER`, the exit notice of one that ended in its start trampoline `TR_NOTICE`: `silica_rt_tramp_release`); the supervision block goes back with the ACB; a spawn whose supervisor ended in its start trampoline returns that actor's (dead) identity (2026-11-09, group 3); (2026-11-10) **actor identity** (spec §15.1.4, the ESP32-S3's "Actor identity"): an `actor_ref` is position << 32 | child number, never an ACB address; `silica_rt_ident_assign` numbers each spawn from its spawner's record (main position 0 from `silica_rt_main_spawner`, the running actor's `ACB_SPOS`/`ACB_SNEXT`, a row child's supervisor's, a supervisor taking the next global position from `silica_rt_next_position` when spawned, the registry actor 0xFFFFFFFE through `silica_rt_spawn_rec_override`); a row's `ROW_SPOS`/`ROW_SNEXT` survive restarts, so a restarted child takes the next child number; numbers are never reused; `silica_rt_ref_acb` resolves a reference by walking the chain of every ACB (`ACB_ALL_NEXT`; no hash table: one core, at most ~1,000 actors), a miss or an ended actor is actor_not_found, and a recycled ACB carries all ones in `ACB_ID`, so a stale reference never reaches its next occupant; registries keep ACBs internally and answer identities; (2026-11-10, group 4) **timers**: `timer_prepare` / `send_after` / `cancel_timer`, one list ordered by deadline in SysTick milliseconds (deadline = now + delay + 1 ms, so never early), fired by the scheduler loop before every pop (the idle `wfi` wakes each tick), a delay of 0 cast at once from the caller, numbers never reused, an ended or call-only target drops the message (buffer and record freed), a timer holds its target's identity, an ended actor's timers purged when its ACB is freed; `monotonic_time` answers nanoseconds (ms count x 10^6 + the SysTick counter, 12.5 ns); (2026-11-10, group 5) **priorities and policies**: three ready queues (high / normal / low, core block +0/+12/+40 as on the ESP32-S3), `set_actor_priority` (read at the next push), `set_scheduler_policy` `:priority_fifo` / `:round_robin` / `:weighted_fair` (DRR, quanta 4/2/1) / `:lottery` (xorshift32 seeded from SysTick); main is a normal-priority context ; (2026-11-10, group 6) **stack release policies** at the dispatch boundary (`silica_rt_actor_release_policy`, on the scheduler's stack: `:release_on_return` nothing, `:keep_last_message` (also unset) the chunks this dispatch reached, `:track_recent_peak` the most of the last 32 dispatches (a 32-byte ring per actor), `:release_when_idle` everything until a second passes without a message (`silica_rt_actor_idle_scan`, every quarter second from the scheduler loop, over the chain of every ACB, `ACB_ALL_NEXT`), `:keep_high_water` everything), the high-water marks `ACB_HW_M` / `ACB_HW_A` kept by the growth entries, **get_actor_memory_usage** (reserved = the lowered reservation, else both heap arenas; committed = retained = the chunk bytes held; high_water), **get_cpu_topology / get_core_capabilities / get_performance_cores** (one :performance core 0: capabilities `armv7e-m`, `dsp`, `fpv4-sp`, 80 MHz; one NUMA node with the SRAM1 and SRAM2 ranges; no cache levels; any id but 0 gives the sentinel -1) | the enforcement of a lowered stack reservation (`stack_policy(n, ...)`, n > 0: recorded and reported, not enforced; decision pending), a spawn-time reservation step |
| `rt_failure.S` | (2026-11-09, group 2) the actor's end, design_documents/runtime_failure_reporting.md: the exit path (notice to the supervisor's ingress, the failure report cast to the registered FailureReporter or written, the death result for the call being served and every queued call, the mailbox and ingress dropped, the registered name freed in all three registries, the state chain released), `remove_actor`, `kill_abnormal` / `_named` ((:explicit, :killed)), `fail_self`, `stop_self_normal` / `_explicit` (at the boundary, a call still answered), traps (`badarith`, `case_clause` with the reason-line detail, convention mismatch, name taken, kill/remove naming the caller: :language_error; actor_not_found: (:explicit, :actor_not_found)), the bounds and allocation failures (`*_failed`: (:explicit, atom) in an actor, the abort in main), main's language-level failure (the atom's name, the pending reports, status 1), the CPU fault hook, the report (the hosts' banner with the `reason:` line; device-actor fault lines with Cortex-M exception names), the pending-report list, `report_begin` / `report_end`, the exit drain (up to ~1 s), the failure payload accessors; (group 3) an ending supervisor shuts its children down first (`silica_rt_actor_exit` = shutdown + `silica_rt_actor_exit_body`; `silica_rt_end_actor_leaf`), its rows go back, `kill_abnormal` drains the victim's supervisor's ingress, `exit_payload_free` releases the notice's hold, `root_report_and_note` | |
| `rt_supervisors.S` | (2026-11-09, group 3: the ESP32-S3's file on one core) `materialize_init_children` (rows in the list's order, each child registered by id, `:dangerous` children in both registries), the restart logic (`maybe_restart`: policy, intensity in SysTick seconds with the breach `(:explicit, :restart_intensity_breach)`, `:one_for_one` / `:one_for_all` / `:rest_for_one`, `:duplicate_child_id`), the deepest-first shutdown (`sup_shutdown_children`: `:killed` / `:shutdown`), `start_child`, every `call_supervisor` operation (`add/remove/terminate/restart_child`, `which_children`, `count_children`, `get_child*`, `set_report_sink`, the `-2` self-row answer and `sup_op_*`), exit reports to the sink, `drain_ingress`, the row walkers' hold (`SB_CT_USERS`), the trial accessors and hooks (`child_table_*_ref`, `supervision_ingress_enqueue`, `supervision_wait_and_drain_one`, `add_child`) | nothing waits for a child running elsewhere (one core: the running actor ends at its boundary) |
| `rt_support.S` | checked int64 add/add1/mul, `h2f`/`f2h`, `trunc_f32/f64`, `map_device_check`, memcpy/memmove/memset/memcmp/strlen (the memory functions a foreign C wrapper links against), LED + delay helpers | |
| `rt_ffi.S` | (2026-11-10, group 7) **foreign calls** (spec §20.4; the ESP32-S3's rt_ffi.S for the AAPCS): `silica_rt_ffi_call` takes the emitter's 64-byte call block (terms/ffi_foreign.silica: six argument words, words 0-3 in r0-r3 and 4-5 on the outgoing stack, the function at +24, the result mode at +28, the struct area at +32; a composite result of more than 4 bytes comes back through the hidden pointer in r0, mode 2), in an actor on a machine chunk of the actor's own chain with `_silica_ffi_stack_size` (2 KiB, `BOARD_FFI_STACK`) free above its limit (taken through `silica_rt_stack_grow`, left through `silica_rt_chunk_return`; the SRAM2 chunk arena first, then SRAM1), with MPU region 1 making 32 bytes of that chunk's band no-access for the call (a C stack that runs through the limit, the depth reserve and the headroom faults instead of writing the heap block below); in main on main's fixed stacks, unguarded; `VRG_FFI` (register block +148) is 1 for the call, so a CPU fault in an actor's foreign code ends it with `:foreign_fault` (tag 5; the fault hook also switches the band guard off and clears `CCR.DIV_0_TRP`, which the sigfpe probe sets), a foreign fault in main is the fatal report (70); `ffi_string_in` (a frame block holding the bytes and a NUL, X0 = pointer, X1 = count), `ffi_string_out` (a fresh frame string from a tagged `_ptr`/`_len` result; the empty string for a nonzero tag or a null pointer) | a hosted-style guarded region for a fault outside any actor (main's is process-fatal, as the ESP32-S3's) |
| `rt_float.S` | `print_f64` (soft float, the host's 15-digit algorithm with an exact FCVTZS-style double -> int64), `print_f32` (FPU, 7 digits), `print_f16` (widened; `nan`/`inf`/`-inf` as words), `f16_to_i32` (a float16 `main`'s exit code) | |
| `rt_stubs.S` | one aborting stub per unported entry, so every program links (`tools/list_runtime_stubs.sh` regenerates the list) | |

A stub aborts with `[silica] abort: runtime entry not yet ported to STM32-L476RG_raw at 0x<pc>`
(status 71) at the first use.

**The copier's machine stack.** The copier recurses through the descriptors (at most 13 levels;
`term_message_copy` caps the depth at 12) on the running context's machine stack, about 80 bytes a
level in Thumb-2 (`rt_sc_val` 56 + `rt_sc_fields` 20), under 1.2 KB in all with `ev_frame`'s own
frame. It is not given a stack of its own and no bound is declared per image (the ESP32's
`main_stack_bound.py` is not ported): the conservative choice was to stay inside the reserve every
machine chunk already keeps below its limit for runtime chains, `_silica_rt_depth_reserve` (512 B,
`--defsym _silica_rt_depth_req`) + `MCHUNK_HEADROOM` (1,024 B). A measure and a copy that disagree
abort with "copier overrun" rather than write past the destination.

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

**Float ABI and C wrappers (2026-11-10).** Everything is built `-mfloat-abi=softfp` (the FPv4-SP
instructions are used as before; only the C calling convention for floats differs from `hard`): the
emitter lays a foreign call's `float32` / `float64` arguments out as core-register words and reads the
result from r0:r1 (terms/ffi_foreign.silica), and the AEABI helpers it calls take the same form, so no
code in the image uses the VFP argument registers. C wrappers are compiled freestanding with
`-ffixed-r9` (r9 is TP; the fault entry reloads it anyway, rt_vectors.S); no C library is linked, the
memory functions are rt_support.S's. The ffi_addition fixtures for this board are built by
`trials/ffi_addition/fixtures_board_STM32-L476RG_raw.mk` (Thumb-2 archives in
`fixtures/build/STM32-L476RG_raw/`; board versions of the fault probes and the text echo in
`fixtures/board/STM32-L476RG_raw/src/`).

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
