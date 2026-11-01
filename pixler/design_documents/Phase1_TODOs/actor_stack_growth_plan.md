# Growable and Shrinkable Actor Stacks — Implementation Plan

**Scope:** chunk 1 after the first fixed point on every emitter path (see [ROADMAP.md](../../../ROADMAP.md)).
**Authority:** [silica-specification.md](../silica-specification.md) §15.1.2.2 *Actor Stack Architecture*, as
revised on 2026-09-17, together with §15.4.11.2 (failure reasons) and §22.4 (`get_actor_memory_usage`).
**Mechanics:** [actor_growable_stack_design.md](../actor_growable_stack_design.md) §2.1, §2.2, §4.2, §4.4 and §7,
revised the same day. The specification wins where the two differ.

## What the specification requires (2026-09-17 revision)

- One contiguous, inaccessible reservation per actor, made at spawn. Default size: the machine's memory
  plus swap, read once at runtime start, page-rounded, just under the total where the host's overcommit
  heuristic refuses the exact amount. `stack_policy(reserve, release)` at spawn lowers it.
- Nothing committed at spawn. Growth in the fault handler: one platform page, doubling per fault to 1 MB,
  then 1 MB per fault. The platform's page size, not a fixed one.
- Two mappings per actor, the committed run and the remainder; no guard mapping. A fault inside the
  reservation is growth, tested before the guarded-foreign-call recovery.
- Release at the message boundary, in the chunks it grew by, down to what the actor's release algorithm
  retains. Five named algorithms, `:release_on_return`, `:keep_last_message`, `:track_recent_peak`,
  `:release_when_idle` and `:keep_high_water` (spec §15.1.2.2; design §4.2.1), and `stack_policy` is a
  required argument of every spawn form, so every actor names one.
- No per-actor maximum, no runtime cap, no `:oom`. Exhausting a lowered reservation is
  `(:explicit, :stack_exhausted)`; a reservation that cannot be made is `(:explicit, :stack_reserve_failed)`
  on the spawning actor.
- `main` is not an actor and runs on the platform's ordinary stack.
- `get_actor_memory_usage` returns reserved, committed, retained and high-water bytes.

The segmented design this plan described until 2026-09-17 (a probe under each frame, a guard page under
each segment, frames hopping between segments) is withdrawn. It removes the address-space limit but
pointers into frames cannot cross segments, every call pays a limit check, and the languages that tried
it abandoned it. The reservation is not a hidden maximum in the sense the earlier text meant: by default
it exceeds what the machine can commit, and a program only sees a smaller one when it asked for one.

## What the code did before chunk 1 (measured 2026-09-17, morning)

- `_silica_rt_actor_init_region` maps a 1 GB `PROT_NONE` reservation per actor with 8 MB committed and
  grows it a page at a time in the fault handler (`sbase`/`ssize` in the fault banner). It never shrinks.
- The fault handler tries the guarded-foreign-call recovery **before** the stack-growth test; that order
  is the reverse of the specification and must be swapped.
- On Linux the emitted `main` is a trampoline onto a private 256 MB stack, and on macOS the compiler is
  linked with a 256 MB main stack (`-Wl,-stack_size`). Both exist only because the compiler runs its
  whole pipeline on the main thread. Neither is allowed by the revised §15.1.2.2.
- The Pi 5 kernel and macOS use 16 KB pages; the runtime's growth code assumes 4 KB in places.
- Debian sets `vm.max_map_count` to about one million on the Pi image and 65,530 on stock kernels; two
  mappings per actor means the limit is reached at half that many actors.

## Work

1. **Reservation.** Replace the 1 GB constant with the default computed at runtime start (physical memory
   plus swap; `sysconf`/`sysctl` on the hosts) and the per-spawn override from `stack_policy`. Reserve
   with no access rights. Fail the spawn with `:stack_reserve_failed` when the reservation cannot be made.
2. **Growth.** Commit nothing at spawn. Chunked growth in the fault handler, doubling from one page to
   1 MB, using the platform page size read at start. Move the reservation-membership test ahead of the
   guarded-foreign-call recovery. Exhaustion of a lowered reservation fails the actor with
   `:stack_exhausted`; running out of memory does nothing of ours.
3. **Release.** At message return, release down to the retained amount in the same chunk sizes
   (`MADV_FREE` / `MADV_FREE_REUSABLE`); an idle sweep releases the rest after the grace period. The
   five algorithms and their control-block state are in design §4.2.1; `:release_when_idle` needs an idle
   sweep on the carrier threads.
4. **Spawn.** `stack_policy(reserve, release)` as the last required argument of every spawn form, before
   the optional core id: type checker, SIR, and all three emitters. Every spawn in the trials, the
   standard library and the compiler then names its policy; that is one mechanical pass over the tree.
5. **Report.** `get_actor_memory_usage` returns the four-field record.
6. **The compiler's `main`.** Make it spawn one actor holding the pipeline and `call` it, returning the
   reply as the exit code, so the compiler runs on an actor stack. Then delete the Linux `main`
   trampoline in `emitter/linux_aarch64/emitter_core.silica` and the macOS `-Wl,-stack_size` link flag,
   so `main` runs on the platform's ordinary stack on both hosts. Measure the per-invocation cost, since
   the process-per-unit loop restarts the compiler hundreds of times per build.
7. **NUMA.** Node-local commitment and lazy migration (design §4.3, §5.3) only on platforms that report
   NUMA nodes; nothing on the Mac or the Pi.

## Implementation status (2026-09-17, evening; Apple Silicon)

Work items 1 to 6 are implemented; 7 (NUMA) is not applicable on the Mac or the Pi. The runtime is
`emitter/<target>/terms/prims/prims_actors_stack_asm.silica` on both hosted paths, with the spawn,
thread-loop, arena and fault-handler changes in `prims_actors_runtime_asm.silica` and
`ffi_fault_runtime_asm.silica`. The Linux AArch64 port was written from the Apple module (it ran on a Pi 5 the next day, below), and
`emitter/linux_x86_64` carries its own copy of the module, so all three hosted paths have it. Decisions the specification leaves open, taken here:

- The runtime is still one OS thread per actor (carriers are chunk 12). The thread keeps a 128 KB
  pthread stack for the mailbox loop and switches SP onto the reservation for every behavior call and
  for the supervisor trampoline; because a growth fault happens with SP inside inaccessible memory,
  every actor thread installs a 64 KB `sigaltstack`, which is given back with the stack on a full release.
- A release is an anonymous `MAP_FIXED` remap to `PROT_NONE`. On Darwin `madvise(MADV_FREE*)` only
  re-accounts and `mprotect(PROT_NONE)` keeps the contents; the remap is the one call that returns the
  pages, and on Linux it also keeps the two mappings merged.
- The lowest page of every reservation is never committed. Reaching it is the end of the reservation;
  without it a lowered stack ran straight into whatever mapping sat below (the arena block did).
- `:keep_last_message` and `:track_recent_peak` measure a message's usage instead of guessing it: the
  committed run is zero at the start of every message (fresh pages are zero and the runtime zeroes the
  range the last message used), so the lowest page holding a nonzero word after the behavior returns
  is that message's depth; the scan touches only the pages about to be released.
- `:release_when_idle` has no carrier thread to sweep for it: the actor's own mailbox wait carries a
  one-second timeout while it holds committed stack, and releases on expiry.
- The implicit heap that `region_alloc` served from a fault-grown 1 GB arena is now a chain of 64 MB
  anonymous blocks with a bounds-checked bump pointer: no third mapping and no cap.
- Children started from child specs inherit the spawning supervisor's stack policy; the child-spec
  record has no policy field in the specification.
- `stack_policy(reserve, release)` is one word, `(reserve rounded to 16) | algorithm index`, and the
  release atom must be a literal: atoms are per-executable indices, so the runtime cannot name one.
- `get_actor_memory_usage` is `proc[concurrency]` in the effect checker, as §22.4 says.

Gate status: deep recursion far past 8 MB, shrink after a message under each algorithm, a lowered
reservation reporting `(:explicit, :stack_exhausted)`, a reservation that cannot be made
(`:stack_reserve_failed` on an actor, a reported exit from `main`), and a foreign call from deep inside
a grown stack are covered by `trials/actor_stacks_addition`, `error_enforcement_addition/stack_policy_*`
and `ffi_addition/app_foreign_call_from_deep_stack`. "A million idle actors" cannot be reached with one
OS thread per actor (the host's thread limit, not the stacks, is the bound); the trial spawns a thousand
with lowered reservations and checks that every one holds zero committed stack. The compiler runs its
pipeline in an actor (`main.silica`); the 256 MB main stack (Darwin link flag, Linux trampoline) is gone.

Result on 2026-09-18: Apple Silicon fixed point re-established (`make fixpoint`: 336 units emitted
identically, the compiler binary byte-identical across generations). Note that the compiler now links
its own actor runtime (`main` spawns the pipeline actor) and that runtime text is emitted by the
*building* compiler, so an edit to the runtime assembly converges one generation later than an edit to
compiler code: when `make fixpoint` reports no unit differences but a differing binary, copy the newest
build to `binaries/silica-gen1` and run `make gen2`, `make fixpoint` again. The whole trial tree passes
under that compiler except the project-bees defect trials (sd1, sd3, sd8, sd10, sd12, sd15, sd16, sd18,
sd19), which document open defects unrelated to this chunk. Per-invocation cost of the compiler is
unchanged (0.05 s warm for a small unit, before and after). Linux AArch64 reached its own fixed point
on the Pi 5 the same day (cross hand-off: `bootstrap-assembly` on the Mac, `bootstrap-link` on the Pi,
then gen1 → gen2 → gen3 with gen3 byte-identical to gen2; about an hour per generation, one unit,
`emitter_core`, peaking near 3.6 GB RSS on the 4 GB board). The Pi found one runtime defect the Mac had
passed by scheduling luck: an actor that dies must unmap its stack *before* it wakes any waiter, since a
caller woken by the death may ask `get_actor_memory_usage` at once (`_silica_rt_actor_fail_current`
now frees first, on both hosts).

## Insertion points

| Piece | Where |
| --- | --- |
| Reservation, commit, release | `emitter/<target>/terms/prims/prims_actors_runtime_asm.silica`, `_silica_rt_actor_init_region` and the fault handler in `terms/ffi_fault_runtime_asm.silica` |
| Fault precedence | `terms/ffi_fault_runtime_asm.silica`, `_silica_rt_sync_fault_handler`: reservation test first, then `_silica_rt_ffi_guarded_fault_handler_try` |
| Actor control block | the ACB fields #272..#391 (stack base, reservation, committed, high-water, next chunk, algorithm, retained, usage ring, ring index, last message time, alternate stack, policy as given, saved runtime SP, lowered flag, pending exit atom), listed at the head of `prims_actors_stack_asm.silica`; the control block is 448 bytes on the hosted paths since 2026-10-12 |
| `stack_policy` | type checker, SIR generator and the three emitters, following the same chain as `core_id` |
| `main` | `src/main.silica` (spawns the pipeline actor). The Linux `main` trampoline in `emitter/linux_aarch64/emitter_core.silica` and the Darwin `-Wl,-stack_size` flag are gone; `LDFLAGS_STACK` in `src/Makefile` now holds only the Linux link flags `-no-pie -rdynamic` |

## Still to decide

The ESP32-S3 has no demand paging and no overcommit, so it does not use this design: the board's stack
sizes, the chunk pool its actors draw from and the 1,000-actor target are in
[actor_memory_budget_plan.md](../actor_memory_budget_plan.md) Part II. What remains open here:

- Operating-system prerequisites: whether `vm.max_map_count` is documented or checked by the runtime at
  start, and what targets without demand paging (ESP32-S3) do instead. Awaiting discussion.

## Gate

- Trials: deep recursion inside an actor well past 8 MB; a handler whose committed stack shrinks back
  after the message; a foreign call from deep inside a grown stack that grows further; a million idle
  actors holding no stack memory; a lowered reservation being exhausted and reported; the compiler
  running as an actor with a bounded RSS.
- The chunk closes when those trials pass under a compiler built by itself on both hosts, and
  `make fixpoint` passes again on both.

**Status of the gate (2026-10-16).** The compiler-as-an-actor, deep-recursion, shrink, lowered-reservation and
foreign-call trials exist and passed on Apple Silicon at the 2026-09-18 fixed point; Linux AArch64 reached its
fixed point the same day (above) and Linux x86-64 on 2026-09-19 (it carries its own copy of the stack module). The
Apple Silicon fixed point was reached again on 2026-10-16 (`make fixpoint`: 348 units compared, none emitted
differently by gen2 than by gen1, gen3 byte-identical to gen2; build log
`silica_builds/20261016-052517/fixpoint-apple_silicon_mac.log`). Open: the "million idle actors" trial (the hosted
runtime is still one OS thread per actor; the trial holds a thousand, and the count waits on ROADMAP chunk 2's
carriers) and the `vm.max_map_count` decision above.

Related: [region_memory_safety_todo.md](region_memory_safety_todo.md) (arena ownership and release),
[porting_for_os_free_targets.md](../porting_for_os_free_targets.md) (board stacks and the port table).
