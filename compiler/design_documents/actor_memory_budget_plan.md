# Actor memory budget: boards and hosted environments — development plan

**Scope:** what one actor, one supervisor and `main` cost in memory, how that cost is cut, and what bounds
the number of actors that can be resident. Two targets share one plan: the `ESP32-S3_raw` board (bring-up;
not one of the numbered [ROADMAP.md](../../ROADMAP.md) enhancement chunks) and the hosted runtimes
(`apple_silicon_mac`, `linux_aarch64`, `linux_x86_64`). Part I is common; Part II is the board only; Part III
is hosted only. Only what differs is segmented. Covers, for the board, what claims the SRAM today, `main`'s
fixed reservation, the raw path's per-actor and per-supervisor stack sizing and the trials that cannot run
for lack of memory; for hosted, the per-actor cost, what bounds the count and what stands between today and
millions.
[actor_stack_growth_plan.md](Phase1_TODOs/actor_stack_growth_plan.md) owns the *hosted* growth mechanism
(MMU reservation, fault-driven commit); its "Still to decide" defers "what targets without demand paging
(ESP32-S3) do instead" — §11 of this plan is that answer. Decided 2026-10-08 (Lee) and built as item F: the
board's stacks are chains of heap chunks, not a fixed pool (§11.1 keeps the reasoning that led there).
**Related:** [esp32s3_port_status.md](ports/esp32s3_port_status.md), [esp32s3_xtensa_port.md](ports/esp32s3_xtensa_port.md),
[actor_growable_stack_design.md](actor_growable_stack_design.md).

**Status as of 2026-10-16** (board checked against `board/runtime`, hosted against the three hosted
runtimes under `compiler/src/emitter/`, and the tree's `main.silica` and trial suites, that day; the item
bodies in §5 keep the dates of the work). Detail in §5 and §17.

| Item | Board (ESP32-S3) | Hosted |
| --- | --- | --- |
| A child-table row leak | done 2026-10-09 | done (not a leak there) |
| B composites copied to the heap | appears done (`silica_rt_state_adopt`, `silica_rt_state_adopt_ref`), gate trials unverified | not determined |
| C `run_behaviour` pad | done 2026-10-08 (the pad is gone: `entry a1, 32`) | does not apply |
| D `main` sized per image | `main`: done 2026-10-08. The per-function actor and supervisor sizes built with it are superseded by F | does not apply (reservation + release policy instead) |
| E measure and gate | retired 2026-10-08: `main`'s bound verified by measurement; what is left is part of F and the gates | retired 2026-10-08 |
| F actor and supervisor stacks start small and grow, no limit | built 2026-10-08 (chunk chains from the heap, five release algorithms, 1,000-actor trial); decided by Lee 2026-10-08, replaces D's per-function sizes | done in the hosted form (commit on demand, release at the message boundary) |
| G shrink the image | done 2026-10-05 | does not apply |
| H re-run the two generic-collections trials | done 2026-10-08: both pass on the board (unskipped) | does not apply |
| I halve the ACB | done 2026-10-09 (128 B); 144 B since the actor-identity words of 2026-10-12 | done 2026-10-09 (392 B); 448 B since 2026-10-12 (§14) |
| J registry capacity | done 2026-10-09 (one slot per atom of the image) | done 2026-10-09 (three registries, one slot per atom) |
| K `wait_for_exit` / `cast_exit` (spec §15.1.2.5) | done; verified on the board 2026-10-08; the board driver ends `.wait_for_exit` trials with the `exit` line | done; trial-verified 2026-10-08 |
| L the compiler's own small `main` | done: `main.silica` (shared by the cross compilers) | done |
| M every trial in the supervisor-actor shape | done: shared sources, `trials/lib_trial_support`, `programmer_tools/trial_shape_m` | done |
| N hosted carrier threads (ROADMAP chunk 2) | does not apply (per-core schedulers built) | not started |

# Part I: Common to the board and hosted environments

## 1. Goals and targets

**Goal, in priority order:** no corruption; as small as possible; as many actors as possible; feasible with
the runtime as it is. The work list in §5 is ordered by those four, which is why the correctness fix in §3
comes before any size is changed.

| Target | Actors and supervisors resident | Bound |
| --- | --- | --- |
| ESP32-S3 | **1,000**, with heap left for the program's own data | SRAM, 399,104 B (Part II); §11 says which steps the target needs |
| Hosted | **millions** | not memory today; the one-OS-thread-per-actor runtime and address space (Part III) |

The two targets differ in what binds, not in what is wanted: the same ACB, the same per-role stack ideas
and the same registry work serve both, and the same correctness fix (§3) gates both.

## 2. What an actor costs, and recycling

Every spawn costs, on every target: an **actor control block** (ACB, the same structure on every path, with
the supervision fields reserved whether or not they are used), a **machine stack**, an auxiliary stack on the
board, a **child-table row** in its supervisor for every child it has ever held, and allocator overhead. A
supervisor costs the same as an actor once, plus its rows. The registry actor every `main` injects at startup
is a fixed program-wide cost, not per actor. The numbers are per target: §7.1 (board), §14 (hosted).

**Recycling (board).** ACBs and message nodes go to their own free lists and are never returned to the
general heap, so a program's *peak historical* actor count, not its current one, sets a heap floor for the
rest of its life. Stack chunks of a live actor go to a free list for its next dispatch; the chunks of an ended
actor go back to the heap (`silica_rt_stack_to_heap`), so the peak of chunks ever in use at once is not kept
for good (§7.1).
Hosted ACBs, rows and message nodes are `calloc`'d and `free`'d individually (§14), so no such floor exists
there.

## 3. Correctness first: composites are passed by stack address, not copied

This is the finding that orders everything else. Verified on the board 2026-09-29; the hosted runtime has
the same structure (§14), see the note at the end of this section.

- **Spawn does not copy the initial state.** The runtime stores the spawner's `X0` (board: `a2`/`a3` via
  `silica_rt_spawn_common`) straight into the ACB's state slot. If the state is a composite, the ACB holds a
  pointer to wherever the spawner built it.
- **The reply is copied as an 8-byte value.** The behaviour-return path copies `reply` and `state` out of
  the result tuple as one 64-bit slot each into the message and the ACB. A composite is a pointer, and the
  pointee is not copied.
- **Composites are built on the stacks.** The emitter places aggregates either in the fixed frame
  (`tuple_flat_memref_near`: "allocated in the fixed frame rather than by moving SP", the machine stack) or
  by `SUB SP` (`tuple_make` "outer SUB SP bytes", the auxiliary stack on the board), depending on the path.
  `tuple_flat_memref_near` is in `term_aggregate_helpers.silica` of every emitter, hosted ones included.

So a supervisor's or worker's state can be a pointer into `main`'s frame or aux slab, and a `call` reply can
be a pointer into the callee's frame region. `supervisors_addition/supervisor_child_tuple_state` (state
`(10, 20)` built in `main`, read by the worker) passes today because `main`'s frame lives for the whole
program, which makes anything built there effectively static. That property does not survive a spawner
whose behaviour returns, and it certainly does not survive freeing a stack (§11 on the board; the release
algorithms of §17 on hosted).

**The fix (item B).** Copy composite state at spawn and composite replies/states at the end of the
behaviour-return path into the heap (board: `silica_rt_alloc`), so that no ACB and no message node ever
points into a stack. Then §11 becomes sound, and on the board the pad shrink of §8.1 (item C) depends on it.

**Hosted note.** The hosted runtime stores the spawner's `X0` and the behaviour's reply/state words the same
way (`stp x21, x20, [x19]` at spawn; the behaviour's result slab read back by the actor loop, both in
`prims_actors_runtime_asm.silica`), and runs behaviours on the actor's own reservation, which a release
algorithm can unmap at the message boundary. The aggregate-return rule in the emitter heap-promotes returned
tuples and records, but it lists actor behaviours (`use_actor_reply_sret_buffer`, reply tuple via `X20`) as
an exclusion (since 2026-10-12 a reply-form callee takes its reply buffer in X<argc> and every other user
call clears X8, `call.silica` `keeps_x8_for_callee`; the exclusion itself was not re-read). Whether a composite
state or reply can dangle on hosted after a release is therefore **not determined**; it needs the same two trials item B names, run on the hosted paths.

## 4. Sizing rules for a `main` that only starts a root supervisor

**Program shape assumed.** `main` declares the cores' multi-tasking algorithm, starts the application's root
supervisor through the `Supervisor` trait (`spawn_registered_supervisor`, spec §15.4.8.1), and waits. No
helper builds the supervisor: the emitter's per-supervisor start trampoline
(`module_linkage.silica` `format_one_supervisor_trampoline`) calls the module's `init` and hands its
`(flags, children)` to the runtime.

**The bounds in §9 hold only under these constraints, which are design rules, not observations:**

1. **`main` never recurses and never reaches the behaviour-return path.** That is why it is cheap. It also
   means both of `main`'s stacks have an exact compile-time bound (§4.1).
2. **A supervisor has no behaviour of its own.** One that does not drops the message in the loop
   ("a supervisor with no behaviour of its own drops the message") and never pays the board's pad; one that
   does has a floor of ~1.9 KB on the board like any actor.
3. **A supervisor's `init` is a flat child-spec list.** On the board the 816 B bound takes
   `materialize_init_children` (480) as the deeper branch; `init`'s own subtree is estimated at ~176 (its
   frame plus record/list allocation through `silica_rt_alloc`). `init` is user code — one that computes
   rather than declares needs its own measurement.
4. **The runtime sizes stacks per role.** On the board, reserve 0 gives every spawn 8 KB + 2 KB today.
   Supervisor and actor defaults differ (§10); `silica_rt_spawn_common` can tell them apart (`ACB_TRAMP` is
   non-null only for a supervisor), and that is where the per-role default belongs, with an explicit
   `stack_policy` reserve still overriding it. Item D. Hosted reserves per actor from `stack_policy` and
   inherits the spawner's policy for child-spec children (§14), so per-role sizing there is a policy choice,
   not a runtime change.

### 4.1 `main`'s stacks: exact per image, not one board-wide constant

The `recursion/` trial suite and any program that does its work in `main` need far more than the shape
above. One constant cannot serve both. Because `main` does not recurse in the shape above, and its runtime
callees are fixed constants, the compiler can compute `main`'s machine and auxiliary bound per image:
`main`'s SFRAME plus the deepest runtime callee, and the sum of its `SUB SP` reservations. Emit them as
`_silica_main_stack_size` / `_silica_main_aux_size` for the linker script and `rt_start.S` to use. A `main`
the compiler cannot bound (recursion reachable from it) keeps a documented default; trials that recurse in
`main` then either fit that default or go into `ESP32-S3_raw.skip` with a measured reason. Until that is
built, the interim constants are the ones in §10, chosen for the root-supervisor shape only. This is a
board rule: hosted `main` runs on the platform's ordinary stack (the 256 MB trampoline and link flag are
gone), and `main` is not an actor there.

### 4.2 Auxiliary stacks

Only emitted code moves the emitter's `SP`; the hand-written runtime never does. `main`'s auxiliary
consumers in this shape are its own argument slabs — the initial-state tuple (16 B for a pair) and the
`stack_policy` tuple (16 B); atoms and integers travel in registers. Estimated ~32–64 B, so 256 B (192
usable above the guard) is 3–6×; the exact figure is the per-image bound above. A supervisor's has two named
consumers: the sret buffer the trampoline reserves for `init`'s return (`SUB SP, SP, #sret_bytes`) and one
slab per child-spec record literal (eight fields, 64 B) before it is copied to the heap — so **it scales
with the width of the `init` child list**, and a root supervisor declaring many children in one literal is
the case to measure. An actor's behaviour pushes 16–32 B per level that carries a value across a call
(`board/README.md`), so the actor ratio stays at the runtime's 1:4 rather than being cut independently of
the machine stack. (The auxiliary stack is a board construct; the hosted runtime has one stack per actor.)

## 5. Work

In goal order — no corruption, then smaller, then more, then feasible — and in dependency order. Status per
target as of 2026-10-07; board status checked against `board/runtime` that day.

- **A. Fix the child-table row leak.** `silica_rt_child_table_free` (`rt_supervisors.S:172`) walks the
  `ACB_CT_HEAD` chain and calls `silica_rt_free` on each 88-byte row before clearing the anchors, mirroring
  `silica_rt_region_destroy`. Also retire the stale "the heap never frees" comments in `rt_heap.S` and
  `rt_actors.S`. First because it is a few lines and it unskews every measurement after it.
  *Board: **done 2026-10-09**, unpublished — `silica_rt_child_table_free` detaches the chain under the
  scheduler lock, cuts every live child loose from its row (`ACB_ROW`, which the child's own exit stamps
  under the same lock), then `silica_rt_free`s each row (96 B + 8 B heap header). Rows a walker still
  holds are not freed under it: every table walk outside the lock (the `call_supervisor` prims, a drain's
  restart logic, a start trampoline parked in a child supervisor's init) is bracketed by
  `silica_rt_child_table_enter`/`_leave` on two new ACB words (`ACB_CT_USERS` 256, `ACB_CT_PENDING` 260;
  `ACB_SIZE` is 264), and a supervisor that ends while its rows are in use leaves the free, and its
  ACB's recycling (`silica_rt_free_acb` defers the same way), to the last walker to leave. Found and
  fixed on the way, all in the board runtime: a row tombstoned or respawned while its dead child is still
  exiting on the other core (`silica_rt_row_release_child`, at the four takeover sites); `stop_child`
  run from a caller's context racing the supervisor's own loop, which served the child's exit notice and
  restarted the row a second time — an extra, orphaned supervisor per cycle, the ~4 KB a cycle that
  `:restart_child` of a supervisor child cost (`ROW_STOPPING`, row +92: `maybe_restart` leaves a row
  being stopped to the stopper); an exit notice to a dead supervisor leaked its 32-byte payload and node
  (`silica_rt_actor_deliver_exit` frees them on the drop); a dead supervisor's unserved notices leaked
  their payloads (`silica_rt_actor_exit` step 4 frees them); and `beqz 9f` early-outs that landed in
  `SCHED_LOCK`'s own local `9:` (the drain's pre-existing one included). Gate: §13. Still leaking per
  cycle, measured and not item A's: each `call_supervisor` reply record (~230 B) and a restarted
  supervisor's init child-spec list (~1 KB for ten specs). No "the heap never frees" comment was left in
  `rt_heap.S` or `rt_actors.S`; the one in `rt_supervisors.S` went with the function. Hosted: **done** —
  `_silica_rt_child_table_free` in `prims_actors_child_table_asm.silica` walks the node chain (`+80` next),
  `free`s each row and clears the anchors; there was no leak to fix.*
- **B. Copy composite state and replies to the heap** (§3): at spawn, for `X0` init; in
  `silica_rt_run_behaviour`, for `reply` and `state`. Add a trial in which the spawner is an actor whose
  behaviour returns before the child reads its state, and one in which a caller reads a composite reply
  after the callee has served another message. The correctness gate for C, D and F.
  *Board: **appears done** — state and message copies are on the heap and released per dispatch via
  `silica_rt_state_release`; its gate trials are unverified. Hosted: **not determined** (§3 hosted note).*
- **C. Shrink the `run_behaviour` pad** from 1,568 to 512 (§8.1). Feasible: `entry`'s immediate is 12 bits
  scaled by 8 (0–32,760), and 1,568 appears at exactly one site. Conditions: record the 192-byte derivation
  at the `entry`, or publish it as an assembler symbol computed from the loop's post-behaviour depth, so a
  later deeper call after the behaviour returns cannot silently undercut it; re-measure after any change to
  `silica_rt_actor_main`'s post-behaviour path or `actor_exit`'s chain; verify on the board with
  `supervisors_addition` and `actors_addition`, looking for wrong replies, not just clean exits — a too-small
  pad does not trip the guard.
  *Board: **done 2026-10-08** — `silica_rt_run_behaviour` is `entry a1, 32`: with item B's heap copies the
  pad had no job left, so it was removed rather than shrunk to 512; the loop's post-behaviour frames may
  reuse the behaviour's region. `supervisors_addition` and `actors_addition` pass on the board with it
  (replies compared, not just exits). Hosted: does not apply; there is no pad.*
- **D. `main` sized per image; per-role defaults superseded by F** (§4, §4.1). As first written: supervisor
  1,536/512 and actor 2,048/512 at reserve 0, chosen in `silica_rt_spawn_common` by `ACB_TRAMP`; interim
  `main` constants 1,024/256; then the per-image `main` bound emitted by the compiler, with the
  default-or-skip rule for a `main` it cannot bound.
  *Decided 2026-10-08 (Lee): actor and supervisor stacks start minimal, grow to fit and are released by their
  declared `stack_policy` algorithm, with no size limit, on the board as on the hosted targets (spec
  §15.1.2.2). What is left of D is `main`: it is not an actor, has no growth, and keeps the per-image size
  below. The per-function actor and supervisor sizes below (the stack table and the 8 KB + 2 KB defaults) are
  superseded by item F, and an actor or supervisor no longer ends because its stack is full. The limit checks
  in emitted code stay: in F they are where a stack grows instead of where it fails. A supervisor's `init`
  runs on the supervisor's own stack (its start trampoline calls `init` while the spawner waits), so a wide
  `init` grows that stack and its release policy gives the memory back.*
  *Board: **done 2026-10-08** (published with K and M in the 2026-10-16 compilers). As built it goes further than per-role
  constants, because the measurement (item E) showed no constant can serve supervisors: this emitter homes
  every virtual register and every record-literal field in the fixed frame, so a ten-child `init` is a
  5,712-byte frame (`phase_e_decl_10_*`) where §4's estimate was ~176 B. What landed:*
  - *`main`'s two stacks are sized per image (§4.1): `board/tools/main_stack_bound.py` walks the linked
    image's code from `_start` (`entry` frames along `call8`/`call0`/tail-jump edges, the maximum over
    branches; the emitter's `SP` reservations summed per function; libgcc and the runtime included; only
    control-flow-reachable instructions, since libgcc keeps tables inside its functions), and
    `build_image.sh` links twice, the second time with `_silica_main_stack_size` / `_silica_main_aux_size`
    (bound + a quarter, at least 128, + the 64 B guard, rounded to 64) and the sizes in `<name>.stack`. A
    `main` the walk cannot bound (recursion reachable from it, or a call through a function value — one of
    the `generic_modules_addition` trials) keeps the documented default, 128 KB + 64 KB, the budget the port
    had: no trial loses anything, and converted `main`s need under 1 KB + 256 B.*
  - *Actors and supervisors at reserve 0 take their sizes from the image's stack table (`silica_rt_stack_table`,
    the same tool: every behaviour and start trampoline whose address appears in a literal, bounded, with the
    actor loop's frames and the runtime reserve under the deepest frame, rounded up to 512 so the
    exact-match free list keeps few classes; auxiliary at least 256). `silica_rt_spawn_common` looks the
    behaviour or trampoline up; a function not in the table (recursive, or calling a function value) takes
    the role default `ACTOR_MACHINE_STACK` / `SUP_MACHINE_STACK`, kept at 8 KB + 2 KB because a recursive
    behaviour's depth is data the runtime cannot know (the program states it with a reserve). An explicit
    reserve overrides the table; a child spec inherits its supervisor's explicit reserve, and under a
    supervisor at the default is sized by its own behaviour (`ACB_RESERVE` stays 0 for a default).*
  - *The §8.2 gap is closed (decided and built, not just recorded): every emitted prologue compares the new
    `a1` with the context's limit (`VRG_MLIMIT`: the guard band's top + `_silica_rt_depth_reserve`, the
    deepest bounded runtime chain emitted code calls in this image, measured by the tool and linked per
    image), and every `SP` reservation compares the new `SP` with `VRG_ALIMIT`; `silica_rt_stack_overflow` /
    `silica_rt_aux_overflow` store into the band so the result is the same debug exception as a real
    overflow. The context switch publishes both limits; `main`'s are set at start-up.*
  - *Side changes the measurement forced: core 1 is started at start-up (`silica_rt_actors_start_cores`), so
    the ROM call is no longer charged to every actor stack; the abort trampoline and `rt_heap.S`
    `silica_rt_heap_reaches` declare their depth (`<name>__stack_bound` absolute symbols the tool reads: the
    report runs on the fault stack; the recursion is bounded by its depth argument); a supervisor that dies in
    its start trampoline now wakes the spawner (`silica_rt_spawn_waiter_wake`), which used to leave `main`
    suspended in `spawn` for ever; and `_start` zeroes `main`'s stacks so their high-water marks can be read.*
  - *Trials: `trials/stack_budget_board_addition` (board-only, goldens from the board): machine overflow and
    auxiliary overflow end the actor loudly and the program goes on; a recursive `main` keeps the default; a
    call-chain `main` is bounded; an eight-child supervisor starts on its table size; `get_actor_memory_usage`
    on the board.*
  - *Board results 2026-10-08 (scratch copy of the trial tree, `wait_for_exit` programs skipped because the
    board driver does not send `exit` yet): `stack_budget_board_addition` 6/6, `supervisors_addition` 104/106
    (10 skipped), `actors_addition` 292/292 (24 skipped, item B's two trials among the passes),
    `generic_modules_addition` 11/11 (item H's two included), `modules_addition` 260/260 (2 skipped),
    `compiler_addition` 423/423 (1 skipped), `memory_region_addition` 396/397 (the five capacity skips stand),
    `cast_exit_board_addition` 2/2. The three failures are not D's: `phase_e_decl_10_one_for_all_restart_child`
    and `..._rest_for_one_...` restart ten children across both cores and hang in the cross-core kill (the known
    "ending an actor on the other core waits for its dispatch boundary"); on one core (`NCORES_RUN 1`) both pass,
    and before D they died earlier with `stack reservation failed` (ten 10 KB children did not fit the heap).
    `write_buf_flat_tuple` reads the length word of a buffer in a frame region as 0: the committed runtime plus
    nothing but the stack zeroing fails the same way, so the trial passed only on memory left over from the
    previous image -- a pre-existing ESP32 emitter defect in the frame-region buffer path, now caught
    deterministically.*
  *Hosted: does not apply in this form; stacks are reservations sized by `stack_policy`, and `main` runs on
  the platform stack.*
- **E. Measure and gate.** High-water marks for `main`, a supervisor with a wide `init` list, and the
  deepest actor in each trial suite, via `silica_rt_get_actor_memory_usage`; decide the probe store of §8.2;
  set the constants; move any trial that no longer fits into `ESP32-S3_raw.skip` with its measured shortfall.
  *Retired 2026-10-08. With growable stacks there are no actor or supervisor sizes to set, and `main`'s
  per-image bound has been checked against measured high-water marks (below). The two measurements still
  needed belong to F: the size of a stack's first chunk and its growth step on the board, which the measured
  actor and supervisor use below informs, and whether 1,000 actors and supervisors fit the heap at rest, which
  is the board gate (§13). The record of what was measured is kept below.*
  *Board: **measured 2026-10-08.** The end-of-program line (`rt_console.S`: `[silica] stacks: machine
  <used>/<size> aux <used>/<size> actors <n> actor-max ... sup-max ...`, after the exit marker, from the
  lowest non-zero word of each zeroed block; actors are folded in when they end and at exit over the all-ACB
  chain) gives every trial's marks; `main`'s came in at 50–75 % of the per-image size across the suites run
  (bound ≥ used in every image). Supervisors: 896 B machine / 88 B aux for a one-child `init`, 4,816 / 16 B
  for eight children (table size 5,632 / 320), a ten-child trampoline bound 6,320 B. Actors: 288–776 B
  machine, ≤ 160 B aux across `supervisors_addition`, `actors_addition`, `generic_modules_addition`,
  `modules_addition` (behaviours that merely reply); the recursion trials of this plan's own suite reach
  whatever their reserve allows and end loudly. The probe of §8.2 is the limit check above. Hosted:
  `get_actor_memory_usage` exists (reserved, committed, retained, high-water); no per-actor figures have
  been taken for this plan: **not measured**.*
- **F. Actor and supervisor stacks start small and grow, no limit** (§11; first written as "stacks allocated
  on dispatch") — the order-of-magnitude step on the board. It restructures the actor loop.
  *Decided 2026-10-08 (Lee): this is no longer optional on the board. Every actor and supervisor stack starts
  small and grows on demand with no limit, and is released at the message boundary by its `stack_policy`
  algorithm, as the hosted runtimes already do. The board has no demand paging, so it grows by chunks taken
  from the heap; the emitted limit checks from D are the growth trigger. The first-chunk size and growth step
  are chosen from the stack use measured under E. This replaces D's per-function sizes, and settles the
  specification question of §11.1: there is no fixed board stack size. Gate: §13, including 1,000 actors and
  supervisors at rest.*
  *Board: **built 2026-10-08** (published with K and M in the 2026-10-16 compilers). Design (`rt_actors.S` "Growable stacks",
  [esp32s3_xtensa_port.md §8.3](ports/esp32s3_xtensa_port.md)): each of an actor's two stacks is a chain of
  64-byte-aligned heap chunks (64 B header, 64 B guard band, frames or slabs above); nothing is taken at
  spawn, the scheduler gives an actor its first chunks when it dispatches it with none and re-enters the
  actor loop afresh at every dispatch, so the loop's frames sit at the top of the first chunk and the stack is
  empty at the boundary. D's limit checks are the growth trigger: a prologue below `VRG_MLIMIT` parks its
  still-empty frame under the limit with `MOVSP`, calls `silica_rt_stack_grow`, and moves itself by a
  second `MOVSP` to the top of the next chunk, its `a0` replaced by
  `silica_rt_chunk_return` (the real one kept in the chunk header), which makes the chunk below current
  again when the frame returns; the windowed ABI stays exact because spills and reloads are addressed
  through the `a1` of the frame above, and `MOVSP` reloads a spilled caller through the alloca exception.
  An auxiliary reservation below `VRG_ALIMIT` leaves its size in `VRG_ARG` and `silica_rt_aux_grow` moves
  `SP` to the next auxiliary chunk; the matching release reaches the chunk's top (`VRG_ATOP`) and
  `silica_rt_aux_release` pops it (a restore of a saved `SP`, the self-tail-call stub's, is checked on both
  sides). Release is the scheduler's, after the switch back, by the five algorithms in chunks (`ACB_PEAK`
  per dispatch, a 32-entry ring for `:track_recent_peak`, a quarter-second idle scan per core on the 16 MHz
  system timer for `:release_when_idle`). Sizes, from E's measurements: first chunks 2 KB machine (holds
  ~1.1 KB of frames after the reserve, header and band: every measured replying actor) and 512 B auxiliary
  (384 usable; measured ≤ 160); a later chunk doubles its predecessor up to 16 KB / 4 KB or holds the frame
  or slab plus 1 KB / 256 B of headroom, so a ten-child `init` (5.7 KB) takes one 6.9 KB chunk. A lowered
  reservation caps the chunks of both stacks together and ends the actor with `(:explicit, :stack_exhausted)`
  when reached; the heap exhausted is a runtime abort (71), the host's out-of-memory outcome; `main` keeps
  D's per-image fixed stacks and its fatal fault. D's stack table, per-role defaults and
  `silica_rt_spawn_reserve_failed` are gone (`build_image.sh`, `main_stack_bound.py`, which now reads
  `<name>__stack_extra` for the parked grow chain and counts it in `rt_depth`). Trials:
  `stack_budget_board_addition` reworked (growth to ~140 KB, a lowered reservation reached on each stack, the
  five algorithms, a ten-child `init`, a thousand idle actors); `supervisors_addition`'s board-only golden
  for `stack_policy_registered_forms` no longer differs from the host's (its board-only `.ESP32-S3_raw.scout`
  now equals the host golden and can be deleted). Board results 2026-10-08 (scratch copy of the trial
  tree, `wait_for_exit`-without-`cast_exit` programs left out as in D's run, built compiler, unpublished):
  `stack_budget_board_addition` 11/11, `supervisors_addition` 104/106 (10 skipped; the two misses are
  `phase_e_decl_10_rest_for_one_restart_child`, which under two cores reports the five siblings the
  restart stops where the host reports one -- the known two-core kill difference, D's second failure, no
  longer a hang; and the stale board golden above), `actors_addition` 296/297 (22 skipped; the miss is
  `actor_message_capturing_fn_literal`, the item M defect repro that fails on every host),
  `generic_modules_addition` 11/11, `modules_addition` 261/261, `compiler_addition` 423/423,
  `memory_region_addition` 396/397 (`write_buf_flat_tuple`, D's pre-existing frame-region defect),
  `recursive_function_addition` 325/325, `cast_exit_board_addition` 2/2. Gate results: §13.*
  *Hosted: the equivalent is implemented (chunk 1, 2026-09-17): nothing committed at spawn, growth in the
  fault handler, release at the message boundary under one of five algorithms. What it does not remove is
  the OS thread per actor (§15).*
- **G. Complementary, any time: shrink the image.** Per-function `.text` sections, or another way to make
  `--gc-sections` effective, so a unit like `wbt_set.silica` stops bloating `.iram0.text`. Independent of
  stack sizes; attacks the ~18.5 KB large-image case that no stack change reaches.
  *Board: **done** 2026-10-05 — per-function sections plus `--gc-sections`. Hosted: does not apply.*
- **H. Re-run `two_generic_collections_record_round_trip` and `two_generic_collections_round_trip`** after D
  and G; if they still do not fit, skip them with the measured shortfall like the six in §12.
  *Board: **done 2026-10-08** — both pass on the board once `main` is sized per image (2,240 B machine +
  960 B auxiliary each; their images had ~18.5 KB of heap with the 192 KB `main`); removed from
  `ESP32-S3_raw.skip`. Hosted: does not apply.*
- **I. Halve the ACB**, both targets. Board: to ~128 B by moving the supervision fields (offsets 96–172:
  supervisor, agent type, child row, first child, next sibling, child table, strategy, restart accounting,
  trampoline) into a side block allocated only for supervisors. Required by the board's 1,000 target (§11),
  not merely a candidate. Cost not yet assessed: emitted code reads ACB slots at fixed offsets (the state
  and behaviour pairs at 0 and 8, at least), so the layout change touches the emitter's actor primitives and
  `rt_supervisors.S`, not only `rt_actors.S`. Assess after F, since the two change the same structure.
  Hosted: the ACB is 512 B (384 runtime + 128 stack module, §14) and is `calloc`'d per spawn; at a million
  actors it is 512 MB before anything else, so the same split pays there (derived, not measured), but it is
  not what binds first (§15).
  *All four targets: **done 2026-10-09**, unpublished; verifier runs pending.* **Board:** `ACB_SIZE` 128 (from
  264). The worker ACB keeps state/behaviour at 0/8 (the only slots emitted code reads), packs the small
  fields into bytes (status, core, target core + 1, kind, priority, alive, device, state owned, reason tag,
  EXCCAUSE + 1) and the atom-sized ones into halfwords (reason atom, agent type, registered name + 1), drops
  the two dead sibling links and the reservation word (derived from the policy word, `ACB_RESERVE_LD`), and
  points at two side blocks: a 64 B supervision block (`ACB_SB`: ingress head/tail/depth, spawn waiter,
  sync_failure_reported, trampoline and trampoline-ran, strategy, allowed/time frame/restarts/window,
  child-table head/len/users/pending) that `spawn_common` makes for an actor started with a trampoline and
  `silica_rt_enqueue_ingress` makes on demand for any other actor that receives an exit notice (an
  `add_child` parent), and the 32 B `:track_recent_peak` ring, made only for that algorithm; both go back
  with the ACB (`silica_rt_free_acb`). The child row stays on the child (`ACB_ROW` 76, read by
  `rt_heap.S silica_rt_state_release`). Every query on an actor without a block sees an empty table.
  Measured on the board with the working-tree runtime (the compiler is unchanged: emitted code reads only
  word 0): `thousand_actors_at_rest` holds 1,005 idle actors with **190,696 B of the 353,280 B heap in use,
  162,584 B free** (321,856 in use / 32,960 free before: 136 B less per actor, the 128 B block plus its 8 B
  header against 272); `supervisor_end_frees_child_table`, `supervisor_ten_child_init`,
  `stack_release_algorithms` and `actor_high_water_within_reserve` match their goldens. **Hosted:** the
  ACB is 392 B (from 512): 0–215 unchanged, 216 the supervision block pointer (96 B `calloc` by
  `silica_rt_sb_require`: ingress front/rear at 0/8, depth 16, child-table head 24, len 32,
  sync_failure_reported 40, trampoline 48, strategy 56, allowed 64, time frame 72, restarts 80, window 88;
  freed by `child_table_free` on every exit path), 224 the started flag, 232 the exit reason tag, 240 the
  active call, 248/256/264 the FFI arena, 272–391 the stack module (every field 112 lower). The dead
  first-child/next-sibling list is gone. Checked on the Mac with an incremental build: the actor_stacks
  suite and an 18-trial supervisors subset match their behaviour goldens (the subset's assembly goldens and
  atom-index lines differ only because a scratch suite numbers atoms differently; a control build from the
  pre-change runtime shows the same). Linux: the runtime text assembles under `clang --target` with the
  same pre-existing error set as before the change; not run on pix or nix yet.*
  *Since 2026-10-12 (actor identities, spec §15.1.4; checked in the source 2026-10-16): every reference is a
  64-bit identity (position << 32 | child number) resolved through an identity table, so each ACB gained
  words. **Board:** `ACB_SIZE` 144 (128/132 the identity, child number then position; 136/140 the spawner
  record, position + 1 and next child number); the `rt_actors.S` header comment still says 128 B. **Hosted:**
  the ACB is 448 B (`calloc` at both spawn sites on all three runtimes): 392 holders of the block, 400 a row
  child's parked exit notice, 408 the identity, 416/424 the spawner record (a row child's is in its row),
  432 the calling convention recorded at spawn (spec §16.2.6.4: 0 not checked, 1 call-only, 2 cast-only),
  440 spare. The supervision block is 120 B (`silica_rt_sb_require`; 96 children counted in a replacement
  wait, 104 tearing down, 112 references). Every supervision block and ACB is held by reference count and
  freed by its last holder.*
- **J. Registry capacity — a hard cap the memory arithmetic does not see.** Every supervised child is
  registered under its `id` atom (board: `silica_rt_supervisor_spawn_child_row_by_flavor` →
  `silica_rt_register_actor_named`), into one global table of 240 actor_refs indexed by atom index (board:
  `REGISTRY_SLOTS = 240` in `rt_actors.S`, with a second table for `:dangerous`; hosted: the PID registry
  actor's 3,840 B state, `occ[240]` at +0 and actor_refs at +1,920, in `prims_actors_runtime_asm.silica`,
  with a dangerous and a device registry made the same way). The store **silently does nothing** for an atom
  index ≥ 240 (board: `silica_rt_registry_store`; hosted: `cmp x22, #240 / b.ge L_pidreg_insert_ok`, which
  then replies `:ok`) and **silently overwrites** an occupied slot. So with the runtime's ~21 prefix atoms
  (board figure), at most ~219 distinctly named children can be registered program-wide; the rest spawn and
  are supervised through their child rows, but every name-keyed operation on them (`call_supervisor`
  `:get_child`, keyed `call`/`cast`, `kill_abnormal` by name) returns "not found" with no error. On the
  board 240 is also the discriminator between an atom and an ACB pointer in every keyed form, so it can be
  raised only while it stays below the lowest ACB address (≥ `0x3FC8_8000` there, so a few thousand is
  safe); the keyed forms test `cmp x11, #240` in the hosted runtimes too, so the same constraint is likely
  there against heap addresses and is **not checked**. Fix: size each registry per image from the atom-table
  length the emitter already emits (board: 4 B per slot, 1,024 slots × 2 registries = 8 KB), and make an
  out-of-range or duplicate registration fail loudly rather than vanish. Required by both targets' counts
  whenever children have distinct ids. Also check `INGRESS_LIMIT = 1024` (board supervision ingress depth)
  against a mass child failure at that scale.
  *All four targets: **done 2026-10-09**, unpublished.* **Sizing:** the runtime module (`__silica_runtime.sams`,
  written once after every unit of the batch) is now emitted from the build-wide atom table (`main_emit.silica`,
  `atom_table@build_runtime_atom_table`: the fixed runtime prefix, then `silica.atoms`, then the registry's three
  reply atoms), and it carries `silica_registry_slots` = that table's atom count; the three registries are
  `calloc`'d (hosts, `slots × 16 B`) or `silica_rt_alloc`'d (board, `slots × 4 B`) from that word at start-up,
  one slot per atom, so no atom index is ever out of range (spec §4.1.7: atoms are fixed when the program is
  built). A runtime module already in the directory is rewritten whenever a unit is compiled, so an incremental
  build never leaves a registry sized by an older table. **Discriminator:** every keyed form (`call_registered`,
  the three `cast_*_registered`, `kill_abnormal` by name) and the registry actor compare the key with the same
  word instead of `#240`; an int64 below the atom count is an atom, at or above it an actor_ref. Checked against
  real control-block addresses in the failure reports of this day's runs: macOS `0x1030_3da6_0` and up (the
  malloc zones sit above the 4 GB image base), Linux x86-64 `0x1ecc_a930` and up (non-PIE image at 0x400000,
  brk heap above it), Linux AArch64 `0x0c16_7930` and up, the board `0x3FC8_8000` and up; no target hands out an
  address below any atom count a program can have. **Duplicates (spec §20.3.1, Lee 2026-10-08):** a registration
  of a name a live actor or supervisor holds is refused everywhere: the registry actor's `:insert` replies
  `:name_taken` (or `:already_registered` when the actor holds another name, `:actor_not_found` when it has
  ended; `:ok` when the actor re-inserts its own name); `spawn_registered` / `spawn_dangerous_registered` /
  `spawn_device_registered` / `spawn_registered_supervisor` probe the name before spawning
  (`silica_rt_registry_require_free{,_dangerous,_device}`) and on a taken name spawn nothing and fail the
  caller with `failure_reason` `:language_error` (`silica_rt_registry_name_taken`, the `case_clause` path: an
  actor ends with reason tag 2, `main` writes `language_error` and exits 1); a supervised child whose `id` a
  live actor holds is not started and the supervisor's `init` fails the same way (the start trampoline probes
  each id; `:add_child` returns child 0); `E2235 DuplicateChildId` rejects an id repeated in one `init` child
  list literal at compile time (`type_checker_supervisor.silica`). A restart is not a duplicate: the hosted
  runtimes now remove an actor's names at teardown (`silica_rt_registry_forget_actor` at the top of
  `deliver_exit`, so before the supervisor sees the exit; the board already did this through `ACB_REG_NAME`),
  and `register_*_named` treats a slot whose holder has ended as free. Trials: `actor_registration_addition/
  registry_many_names` (270 names), `register_name_taken`, `spawn_registered_name_taken_fails`,
  `update_registration` (now asserts the refusal); `supervisors_addition/working_registry_restarted_child_reachable`,
  `working_registry_child_id_taken_across_supervisors`; `error_enforcement_addition/
  supervisor_duplicate_child_id_trial` (E2235). Results per platform are in the 2026-10-09 item-J report.
  `INGRESS_LIMIT` (1024) was not revisited.

- **K. Ending the program: `wait_for_exit` and `cast_exit`** (spec §15.1.2.5, decided 2026-10-07, revised
  2026-10-08). `main` blocks in `wait_for_exit() -> int64`; the wait ends on a standard-input line `exit`
  (`wait_for_exit` returns 0) or when an actor issues `cast_exit(value: int64)` (it returns `value`, the first
  request's). `main` then continues, and the program ends when `main` returns, with `main`'s result, as a
  returning `main` always ended it; the actors are abandoned. A `main` that returns `int64` usually returns
  the value, which makes it the exit status. The program does not end because it has gone quiet: an idle
  program waits. This item is what lets the compiler's own `main` shrink (item L), and it changes how every
  program that ends with `wait_for_exit` stops.
  - **Builtin.** `cast_exit(value: int64) -> boolean proc[concurrency]`: type checker signature, the effect
    checker's `conc` table entry beside `wait_for_exit` (`effect_checker_core.silica`), SIR lowering, and the
    emitter mapping to a runtime entry `silica_rt_cast_exit` on all four targets, next to the
    `wait_for_exit` mapping (`prims_actors.silica`). No allocation, so it costs nothing per message.
  - **Hosted runtimes** (`prims_actors_runtime_asm.silica`, three targets): a flag word `exit_flag` (0 = none,
    1 = recorded), a value word `exit_request` (any `int64`, which is why the flag is separate) and a private
    pipe made at runtime start (`pipe`, close-on-exec). `cast_exit` compares-and-swaps the flag from 0 to 1;
    the winner stores its value with release ordering, writes one byte to the pipe and returns 1; a later
    request returns 0. Actors are threads today and will be carriers after chunk 2; the compare-and-swap is
    correct under both. `_silica_rt_wait_for_exit` sleeps in `select` on standard input (macOS: `poll` misses
    tty input) and the pipe's read end; when the pipe is readable it loads the value (acquire) and returns it,
    and an `exit` line is recorded as `cast_exit(0)` (2026-10-16; a later `cast_exit` returns false, as on the board) and returns 0. It returns to `main`, which ends the process by returning as before.
    Writes are direct system calls, so nothing is buffered and lost.
  - **Board** (`rt_actors.S`, `rt_console.S`): the same flag and a two-word value, and `main`'s context parked
    by the scheduler (`ST_WAITQ`) instead of returning when every actor is idle. `cast_exit` records the
    request under `silica_rt_sched_lock` (`silica_rt_exit_request_record(lo, hi)`) and makes a parked `main`
    ready on core 0's queue; `main` resumes in `wait_for_exit`, reads the value under the lock and returns it
    in `a2:a3`; the program then ends through the image's ordinary end of `main` (`rt_start.S` ->
    `silica_rt_exit` with `main`'s result: the exit marker the board driver reads, then halt). The `exit` line
    arrives on the console UART's receive side, polled by core 0's scheduler loop, and records value 0.
  - **Board apps (decided 2026-10-07).** Every app under `board/apps/silica_*` takes the supervisor-actor
    shape: `main` starts a supervisor with one actor, casts the work to it and ends in `wait_for_exit()`, because
    the board's `main` stack will be too small for anything else (items D and E). An app that does a piece of
    work and finishes ends with `cast_exit(0)`; one that runs until stopped (button watchers) does not.
  - **Migration (board).** Today the board's `wait_for_exit` returns 0 once every actor is idle, and every
    board app and board trial relies on that to end. After K they wait. Each needs one of: the issuing actor
    calls `cast_exit(0)` at its end, or the board driver (`trials/targets/`, `run_on_board.py`) sends `exit`
    on the UART after the program's marker, as the host harness does today with `.wait_for_exit` files. The
    second keeps the programs unchanged and matches the hosts; it needs UART receive (above).
  - **Standard input at its end (decided 2026-10-07).** At end of input `wait_for_exit` takes standard input out of
    its `select` set and keeps sleeping on the exit pipe; it never returns. Before K, end of input returned 0
    and `main` continued, so a program run with its input closed (`make`, CI, `</dev/null`) left `main` at once.
    A trial whose program reaches `wait_for_exit()` and relied on end of input to finish now waits: each such
    trial gets a `.wait_for_exit` marker (the harness then writes `exit`), or issues `cast_exit`. Count them
    before landing K.
  - **Trials** (every hosted target, and the board): an actor issuing `cast_exit(3)` ends the process with
    status 3; the first of two requests wins (the second returns `false`); `cast_exit` from an actor
    serving a `call`; the standard-input `exit` line still ends with 0; a program with no trigger waits (the
    harness ends it with `exit`, as `.wait_for_exit` trials are ended today); `main` returning before
    `wait_for_exit` is reached still ends the program with `main`'s value.
  *Board: **built, verified on the board 2026-10-08** (rt_actors.S, rt_console.S UART exit line, run_on_board.py `--send`;
  suite `cast_exit_board_addition`). Hosted: **built, trial-verified 2026-10-08** on all three hosts. Neither is
  published: K lands together with M (decided 2026-10-08). The board trial driver does not yet honour
  `.wait_for_exit` markers.* *Update 2026-10-16: K, L and M are all in the tree and in the compilers built
  from it that day. The board trial driver now honours `.wait_for_exit` markers: `trials/targets/board_suite.sh`
  sends the `exit` line for a trial with the marker (`run_on_board.py --send`).*
- **L. The compiler's own `main` becomes small** (spec §15.1.2.2, "Keep `main` small" in `learn-silica.md`).
  Today `main.silica` spawns one pipeline actor and `call`s it for the exit code. After L: `main` starts a
  root supervisor (the `Supervisor` trait, `spawn_registered_supervisor`) whose child is the pipeline
  actor, `cast`s the work to it, and ends with `code: int64 <- wait_for_exit()`. The pipeline actor ends
  the program with `cast_exit(code)` once its work and output are complete.
  - **Compiler-only rule (not in the spec).** The compiler's pipeline actor is reached by `cast`, never by
    `call`, and serves no calls. The spec allows `cast_exit` from any actor; this restriction is the
    compiler's own design, so that no caller ever waits on a reply the process ends before sending.
  - **Exit statuses.** 0 success, 1 errors, 75 between units of a process-per-unit batch. `cast_exit` takes
    an `int64` (spec §15.1.2.5), so `main_driver@run`'s code passes through unchanged.
  - **Bootstrap.** `cast_exit` is a new builtin: the compiler source may use it only from the generation
    after the one that implements it (the seed rejects an unknown builtin, E2005). Order: land K and
    publish a compiler that has it, then change `main.silica` and the driver, then reach a new fixed
    point on every hosted target.
  - **Child restart.** The pipeline child is `:temporary`: a compile that fails is reported, not retried.
  *Done (checked in `compiler/src/main.silica` 2026-10-16), with these differences from the text above.
  `main` spawns a `FailureReporter` and registers it first (spec §15.4.13.4, E2236: nothing may be started
  before a reporter is registered), starts the root supervisor `:compiler_supervisor`, casts one message to
  its registered child `:pipeline` and ends in `wait_for_exit()`. The pipeline child is `:transient`, not
  `:temporary`, with `allowed_restart_count` 0, so its first death breaches the restart limit and the root
  supervisor fails; the reporter recognises the root supervisor's own report and ends the program with
  `cast_exit(main_crash@root_failure_status())`: status 76 ("crashed in a unit, continue") when a unit was in
  progress, so the batch loop reruns the compiler as it does on 75, else 1. The pipeline behaviour is
  `(:no_reply, state)`, cast-only.*

- **M. Every trial takes the supervisor-actor shape** (decided 2026-10-07). `main` starts a supervisor with one
  actor, casts the trial's work to it, and ends in `wait_for_exit()`; the actor ends a batch trial with
  `cast_exit(status)`, where `status` is what the trial's `main` returns today, so each `.scout`'s last line
  keeps its meaning. This holds on every platform, since the hosts and the board share the trial sources, and
  it replaces the earlier plan to change only the trials that outgrow the smaller `main` stack.
  - **Order.** After K is published on every target (the trials need `cast_exit` in the compiler that builds
    them), and before D shrinks `main`'s stack on the board.
  - **Done by script, not by hand.** The shapes are few: `main` returning a value, `main` printing and
    returning, `main` already spawning actors, `.wait_for_exit` trials. A transformer per shape, every
    result compiled and run, and a list of the trials no shape fits. The 10,519 generated `train_*` pairs
    change through their generator (`programmer_tools/train_trial_generator`), not one by one.
  - **Goldens.** Output and exit status (`.scout`) must not change; `.ascomp` goldens are refreshed only where
    `.sout` matches `.scout`. Error-trial goldens (`.golden_fail`) carry line and column numbers, so their
    goldens are re-derived and checked. Error trials take the shape too, for consistency (decided 2026-10-07),
    even though a rejected program never runs.
  - **Who.** The transformers are scripts, written by Opus (decided 2026-10-07).
  *Done.* The scripts are `programmer_tools/trial_shape_m/` (README there): `gen_support.py` writes the shared
  modules `trials/lib_trial_support/trial_support_<T>.silica` and `trial_wait_<T>.silica` (28 in all, one per
  result type), each with one `:transient` worker, `start/0` and `run/1`; a suite compiles the modules its
  trials `use` through private links (`TRIAL_SUPPORT_CONFIG` in `trials/silica_compiler.mk`). The trial `main`
  keeps its name and header and ends in `wait_for_exit()`. Since 2026-10-11 every `start/0` registers a
  `FailureReporter` before it starts the supervisor (E2236); the reporter writes each report with
  `println_stderr`, so reports are printed asynchronously and suites that see them compare with
  `trials/compare_scout_unordered.sh` (a `.scout.multiset` or `.scout.sorted` marker; see
  [runtime_failure_reporting.md](runtime_failure_reporting.md) §5).

- **N. Hosted carrier threads** (added 2026-10-08, after the lettered items; the hosted part of ROADMAP chunk 2).
  When this item was written every hosted actor was its own operating-system thread, with a 128 KB thread
  stack and a 64 KB signal stack, so threads, mappings and address space bound the count long before memory
  did (§15), pinning was only a thread-affinity hint (`thread_policy_set` with an affinity tag on macOS) and
  `set_scheduler_policy` answered `:ok` with no effect (with the gate off, and on the Linux targets, that is
  still what happens; with it on, stages 3 and 4 below made placement and the policies real). N replaces
  the thread per actor with the BEAM pattern the board already uses per core:
  - one carrier thread per logical core, each running many actors from its own run queue;
  - cooperative switching only at the specification's yield points: a behaviour returning (the dispatch
    boundary), or a wait such as a `call` awaiting its reply or `wait_for_exit`;
  - an actor bound to its core's carrier, so pinning (`spawn(..., core)`, the `pin_actor_*` family) is
    real; `migrate_actor` moves an actor from one carrier's run queue to another's at its next dispatch
    boundary, as on the board;
  - `set_scheduler_policy` and `set_actor_priority` take effect per carrier, as on the board;
  - actor stacks keep chunk 1's reservations and release policies, switched in and out by the carrier
    instead of owned by a thread, and no thread stack or signal stack per actor;
  - whatever of chunk 11's scheduler this needs comes forward with it (ROADMAP).
  - **Measure:** `docs/examples/idle_actor_capacity` (written 2026-10-08, not run) gives the idle-actor count
    before and after N, on each hosted machine.
  - **Gate:** the hosted part of ROADMAP chunk 2: an actor spawned for a core runs there until moved;
    `migrate_actor` moves a running actor; `get_cpu_topology()` reports the real machine; the scheduler-policy
    order trials pass on the hosts; a hosted machine holds millions of idle actors with no thread per actor
    and no starvation under load; with trials on every hosted target.
  *Stage 1 built 2026-10-19 on `apple_silicon_mac` only (branch `hosted-carriers-item-n`, unpublished); the
  Linux runtimes are untouched. Stage 2 (N carriers) built the same day on the same branch: "Stage 2
  status" below.*
  - **Stage 1 status.** The carrier infrastructure exists behind a process-start gate and is off by default:
    `SILICA_CARRIERS=1` in the environment, read once by `_silica_rt_stack_runtime_init` (`getenv`) into
    `_silica_rt_carriers_enabled`. The emitted runtime text is the same either way, so the gate perturbs no
    `.sams` and the same binary can be run both ways. Off, every actor keeps its thread as before (the loop,
    waits and exit paths take the same branches they took, through two new helpers:
    `_silica_rt_actor_mail_signal` at the 21 sites that signalled a mailbox futex, and
    `_silica_rt_call_wrapper_wake` at the two sites that signalled a call wrapper). On, ONE carrier thread
    (`prims_actors_carrier_asm.silica`, a new runtime module concatenated after the stack module) runs every
    plain actor spawned without a start trampoline: a worker from `spawn`, `spawn_linked`, a supervisor's
    row child of `:plain` flavour (`spawn_linked_row` now takes X6 = 1 for a `:dangerous` row). Dangerous
    actors (`spawn_dangerous_linked`, X6 = 1), supervisors (they have a trampoline) and the runtime's own
    registry actors (`_silica_rt_spawn_rec_override` set around their spawns) keep a thread each.
    - *Carrier block* `_silica_rt_carrier0` (static, 128 B): lock, futex word, idle flag, run-queue head and
      tail, current actor, base SP, 64 KB signal alternate stack (one per carrier, installed once by
      `_silica_rt_altstack_install_at`), pthread, started and created flags. The thread is created at the
      first adoption (`_silica_rt_carrier_ensure_started`); failure to create it is a runtime abort.
    - *ACB fields* (448 → 480 B, both `calloc` sites, `_silica_rt_dead_acb` extended; the layout comments in
      `prims_actors_runtime_asm.silica` and `prims_actors_stack_asm.silica` updated): #440 the carrier (0 =
      a thread actor; the former spare word), #448 status (1 idle, 2 ready, 3 running, 4 parked), #456
      run-queue link, #464 the SP of a parked context, #472 the actor parked in a spawn waiting for this
      one to start. The parked context itself (X19–X30, D8–D15, 176 B) is pushed on the actor's own
      reservation by `_silica_rt_ctx_save`, not kept in the ACB; `_silica_rt_ctx_resume` pops it. The
      call wrapper gained +48, the parked caller.
    - *Dispatch.* The carrier loop (`Lcar_loop`) pops a ready actor, sets the thread's current actor (the
      pthread TLS word, `_silica_rt_tls_actor_set`, once per dispatch; cleared when the loop is re-entered)
      and enters `_actor_thread_main`'s mailbox loop at `LBB1_loop` with X19 = the ACB, as the actor's own
      thread would. The behaviour runs on the reservation with the carrier's SP in ACB #368, returns to the
      carrier at the dispatch boundary, and `_silica_rt_stack_on_message_return` runs on the carrier's
      stack. The code after the behaviour reads the node being dispatched from ACB #240 instead of the
      dispatch frame (three sites), so a resumed actor's return needs nothing from the carrier's abandoned
      frame. After a message `_silica_rt_carrier_requeue` puts the actor back on the queue when mail waits
      or it has been ended, else marks it idle; an idle actor is made ready by the next mail. The loop is
      re-entered afresh (SP reset to the base) from every path that leaves an actor.
    - *Waits.* A `call` from a carrier actor inside its behaviour parks (`LBB4_wait_start`: context saved,
      wrapper+48 = the caller, status 4, under wrapper+72); the reply and the call-death path make it ready
      under the same lock; the resumed actor re-checks `reply_set` under the lock as a woken thread does.
      `call` from `main`, from an actor thread, or from a runtime path running on the carrier's own stack
      (SP outside the actor's reservation) keeps the futex wait, so calls from `main` work unchanged. A
      spawn from a carrier actor parks on the child's started word instead of spinning
      (`_silica_rt_spawn_wait_started`; `_silica_rt_started_store` at the six sites that set #224 wakes
      it, Dekker-style with `dmb ish` on both sides and the status check under the parker's lock).
    - *Exit paths on the carrier's stack.* `LBB1_exit` already runs there and ends in the carrier loop
      (X24 = the carrier). The five in-behaviour ends (`badarith`, `case_clause`, `language_error`/
      `actor_not_found`/`name_taken`, `fail_current`, the guarded-FFI finish) switch SP to the carrier's
      base, run their body, unmap the reservation (`stack_free`, which the thread trap paths still do not
      do) and enter the loop instead of `pthread_exit`. Stack exhaustion of a carrier actor returns from
      the fault handler into `_silica_rt_actor_fail_current(ACB, atom)` by rewriting the ucontext (Darwin
      mcontext x0 +16, x1 +24, sp +264, pc +272), so the kernel unwinds the signal frame and the carrier's
      alternate-stack state and mask are clean for the next fault.
    - *The restart protocol (2026-10-19, after three defects the carrier trials found).* One protocol
      for the supervisor's own thread, a draining caller and parked carrier actors, described in
      `prims_actors_child_table_asm.silica`'s header with its primitives in `prims_actors_carrier_asm.silica`:
      (1) the supervision block (now 144 B) has a *restart token* (#120) with one holder at a time; only
      the holder dequeues the ingress and runs `maybe_restart`, so no two `:one_for_all` / `:rest_for_one`
      cascades overlap. The supervisor's thread takes it with the node it dequeues (`LBB1_wait`) and skips
      the ingress while another holder has it (a release signals its mailbox when notices remain). A dying
      row child on its own thread handles only its own notice, and only when it is first in the ingress
      (`_silica_rt_supervisor_drain_own_exit`), and never waits in its exit path (the replacement wait and
      `sup_wait_enter` / `leave` / `quiesce` are gone). Every other drainer (`kill_abnormal`, the
      `call_supervisor` operations) goes through `_silica_rt_supervisor_drain_ingress` or `_drain_hold`
      (`terminate_child` / `restart_child` hold the token across their stops and respawns): a row child of
      the supervisor never takes the token, since the cascade it would run could stop the child itself,
      but waits until the token is free and the ingress empty (`_silica_rt_sup_restart_acquire`; a carrier
      actor parks on the block's wait list, +128). (2) A row's `exit_done` (+56) is a *generation word*:
      the identity (ACB #408) of the last child of the row that ended, stored as its last act
      (`_silica_rt_row_exit_done_store`) and never cleared; every wait is for one identity
      (`_silica_rt_row_wait`, the one wait at the seven former spin sites: carrier actor on its own stack
      parks on the row's list, anything else spins), so a stale value never satisfies a wait and no party
      clears what another still waits for. (3) `_silica_rt_actor_stop` is the one way another actor is
      ended (alive, reason tag and atom only while it was alive, mailbox signal) and it also unlinks and
      wakes an actor parked on a wait list (ACB #480 names the list; the ACB is 496 B now); a waiter that
      may be ended by the stop (`kill_abnormal`'s two waits) passes itself and returns at once when that
      happens, so a killer stopped by the cascade of the death it caused replies and ends at its next
      boundary instead of deadlocking with the cascade. Lock order everywhere: the waiting actor, then the
      supervisor, then `_silica_rt_row_wait_lock` (which guards every wait list). Pending callers of a
      dying actor are signalled before its exit drains anything (`signal_pending_call_deaths` moved up).
      The three defects, each confirmed with `sample` and an instrumented runtime before the fix: a
      `:one_for_all` sibling calling `kill_abnormal` hung with the gate off (the supervisor's cascade
      waited for the killer's exit, the killer for the victim's `exit_done`, the victim for its
      replacement) and failed with it on (a `:count_children` drain ran a second cascade concurrently); a
      plain actor killing a `:one_for_all` child hung on both gates (gate off: the two stopped siblings
      each drained their own notice in their exit paths and ran cascades waiting on each other; gate on:
      a cascade's `str xzr` of `exit_done` after a parked killer's wake and before its re-read, shown by
      removing the two clears from an emitted runtime: 0 hangs in 8 runs instead of 3 in 3); and the same
      under `:rest_for_one` (a second cascade from the stopped bystander's exit path respawned a row
      twice: duplicate child id). The suspected "killer kills itself via its own drain" was refuted for
      the gate-off case (the killer never reached its drain) but would have been real with the gate on, and
      the rule that a row child never drains its own supervisor's ingress is what prevents it. Known gap,
      pre-existing and unchanged: `restart_child` of a `:one_for_all` supervisor called by one of its own
      row children stops the caller's row and waits for it (a spin or park that nothing ends).
    - **Not done in stage 1:** several carriers, pinning (`spawn(..., core)`, `pin_actor_*`), `migrate_actor`,
      `set_scheduler_policy` / `set_actor_priority` on carriers (stages 3–4); supervisors on carriers; the
      `:release_when_idle` sweep for carrier actors (their
      stack is released at the next message boundary instead, and the idle timed wait does not exist for
      them); the TLS indirection of risk R2.1 (`pthread_setspecific` per dispatch for now); the Linux
      runtimes; the idle-actor capacity measurement. The row wait list is reached through the single
      carrier block (`_silica_rt_carrier0`); with several carriers the parker must be found through the
      thread's own carrier.
    - **Trials:** `trials/carriers_addition` (host-only; its Makefile passes `SILICA_CARRIERS=$(SILICA_CARRIERS)`,
      default 1, to the trial processes only; `make integrate SILICA_CARRIERS=0` runs the same trials a
      thread per actor): `two_actors_one_carrier`, `many_actors_one_carrier` (1,000 actors, each called
      once, committed stack checked afterwards), `call_from_main_to_carrier_actor`,
      `nested_calls_one_carrier` (two actors parked at once).
    - **Verified 2026-10-19 on the Mac** with the compiler built from this branch
      (`compiler/build/apple_silicon_mac/silica-compiler`, not installed): `carriers_addition` 8/8 under
      `SILICA_CARRIERS=1` and 8/8 under `=0`; its trial `.sams` are byte-identical to the installed
      `binaries/silica-compiler`'s, so the `.ascomp` goldens hold for either. A 500-idle-actor probe peaks at
      507 threads with the gate off and 6 with it on (one carrier, the supervisor, the registries, main).
      `actor_stacks_addition` with the gate exported to the compiler as well (so the compiler's own
      reporter, supervisor and pipeline actors ran on a carrier while it compiled the suite): 24/26, and
      every `.sams` byte-identical to the gate-off run (26/26), which is risk R3.1's check. The two
      differences are the expected ones, not carrier defects: `stack_release_when_idle_after_second`
      (no `:release_when_idle` sweep on carriers yet) and `stack_lowered_reservation_exhausted`, where
      both failure reports are right (the exhaustion exit through the rewritten ucontext works and the
      carrier went on to run a 300,000-deep recursion afterwards) but the trial's `true` is `false`
      because its worker busy-polls the exhausted actor's memory from the same carrier, which under
      cooperative one-carrier scheduling never gets to run until the poll gives up. `supervisors_addition`
      with the gate exported to the compiler too: 282/286 before the row wait (the four failures,
      `phase_e_root_restart_cap_exceeded`, `phase_e_root_restart_cap_zero_no_drain`,
      `transient_inner_supervisor_breach_restarted`, `working_registry_restarted_child_reachable`, were
      all the same shape: a plain worker on the carrier calling `kill_abnormal` on a sibling plain worker
      of the same carrier, hitting the stage 1 abort at `Lkab_wait_exit_done`); with the row wait those
      four pass under `SILICA_CARRIERS=1` (six runs each) and `=0`, their `.sams` unchanged against the
      `.ascomp` goldens, and `carriers_addition` is 8/8 under both gates, all with the compiler built
      from this tree. **With the restart protocol (2026-10-19, later):** `carriers_addition` 22/22 under
      both gates (the three new trials `worker_triggers_one_for_all_cascade`,
      `worker_under_one_for_all_kills_sibling`, `worker_under_rest_for_one_kills_sibling`, each also run 15
      times per gate standalone, 15/15); `supervisors_addition` batch-compiled with no trial `.sams`
      changed but `__silica_runtime` (its three new trials `working_restart_protocol_*`, the same three
      driven from `main`, pass and sort last so no atom is renumbered). **Unverified:** the whole of
      `supervisors_addition`, `actor_stacks_addition`, `actors_addition` and
      `supervisors_host_defects_addition` under both gates after the protocol (a full run is pending), the
      `:dangerous` row flavour path, a spawn from a carrier actor of a supervisor whose init needs the
      registry (the spawn-park path was exercised only by the trial support's shape), and any Linux
      target (the Linux runtimes have neither the carriers nor the protocol: the three
      `working_restart_protocol_*` trials will hang or fail there until it is ported, and they have no
      Linux `.ascomp` yet).
  - **Stage 2 status (2026-10-19, `apple_silicon_mac` only, same branch, same gate).** The one static
    carrier became N carriers, one thread per logical core, and every place that assumed carrier 0 is
    per carrier. The emitted runtime text changes (so every suite's `__silica_runtime.ascomp` moves
    once more); the trial `.sams` do not, and with the gate off the behaviour is the one of stage 1 and
    before (the only gate-off difference is the thread record below, a plain store where
    `pthread_setspecific` was).
    - *Count.* `_silica_rt_stack_runtime_init` reads `SILICA_CARRIER_COUNT` (decimal, >= 1; anything
      else ignored) and otherwise `hw.logicalcpu` (`_silica_rt_sysctl_u64`), at least 1, into
      `_silica_rt_carrier_count`. The table (`_silica_rt_carriers`, N blocks of 128 B) is `calloc`'d at
      the first adoption (`_silica_rt_carriers_ensure`, under `_silica_rt_carriers_lock`); each
      carrier's thread is created the first time an actor is bound to it, so an idle machine with one
      worker has one carrier thread.
    - *Carrier block (128 B).* +0 lock, +8 futex word, +16 idle, +24/+32 run queue head/tail (links
      ACB #456), +40 the actor being run, +48 base SP, +56 the 64 KB signal alternate stack (one per
      carrier, installed by its thread), +64 pthread_t, +72 started, +80 created, +88/+96 the thread
      record (current actor; the carrier itself), +104 the sweep list head, +112 the index, +120 the
      time of the last sweep.
    - *Thread record (risk R2.1).* The pthread key no longer names the ACB: it names a two-word record,
      the thread's current actor and its carrier (0 = not a carrier's thread). A carrier's record is in
      its block, written with a plain store at each dispatch (`Lcar_have`) and cleared at each re-entry
      of the loop, so no `pthread_setspecific` per switch; an actor thread's record is ACB #496/#504
      (ACB 512 B, both `calloc` sites, `_silica_rt_dead_acb` extended; `_actor_thread_main` installs it
      with `_silica_rt_tls_record_set`); main gets a `calloc`'d record the first time an ingress drain
      installs a current actor on it. `_silica_rt_tls_current_actor_get` reads the record's first word,
      `_silica_rt_tls_actor_set` writes it, `_silica_rt_on_carrier_thread` reads the second (no
      `pthread_self` comparison, no static block). Fault attribution is therefore "the actor this
      carrier is running", which the handler's growth test and the exhaustion rewrite (both per ACB
      #440 already) rely on. Pre-existing and unchanged: an ingress drain installs the supervisor as
      the current actor while it runs on the drainer's stack (`_silica_rt_supervisor_handle_notice`),
      on every kind of thread, so a growth fault inside `maybe_restart` would be attributed to the
      supervisor; stage 1 had the same through `pthread_setspecific`.
    - *Binding.* `_silica_rt_carrier_adopt` binds at spawn, for life (ACB #440): a nonzero core id
      (ACB #208; a row child's #208 is its row pointer and counts as none) binds to carrier
      `core mod N`; none, or 0, takes the next carrier in turn (`_silica_rt_carrier_next`, an atomic
      round robin, process-wide). Why in turn rather than the spawner's carrier: it is the board's rule
      (rt_actors.S spawn: "the argument when it names a running core (0 is also default), else round
      robin"), so a program places the same way on every target; it spreads the load, which is what N
      carriers are for; and inheriting needs a fallback anyway (supervisors and main have no carrier).
      Why `core mod N` rather than the board's "out of range is round robin": a program written for
      cores 1 and 2 lands on two carriers whenever there are two and on the same one when there is one,
      deterministically at every count, which the trials need (a difference from the board, noted). The
      cost of the choice is that a call from a worker to a child it spawned is usually cross-carrier: a
      park on one carrier and a push plus futex wake on the other, instead of a same-carrier park and
      pop. Exclusive pinning, `pin_actor_*`, `migrate_actor`, priorities and policies are stages 3 and 4.
    - *Per-carrier everywhere.* Every wake pushes to the TARGET actor's carrier
      (`_silica_rt_carrier_push` reads #440: mail, the call wrapper wake, the started store, the wait
      list wake, a stop), waking that carrier's futex when it sleeps; the parker lookups
      (`_silica_rt_on_carrier_thread`, `_silica_rt_carrier_self_on_own_stack`) go through the thread's
      record; every exit path on the carrier's stack and the fault handler's exhaustion rewrite read the
      actor's own carrier (#440, then its base SP +48); `_silica_rt_carrier_leave`, `_requeue` and
      `_loop_enter` take the carrier from the actor or their caller. The spawn park, the row and
      token waits and `_silica_rt_actor_stop` were already written against #440 and needed nothing.
      The `Lrw_spin` abort (an exit path on a carrier's stack spinning for a carrier actor) is kept
      as it was: with several carriers the awaited child may be elsewhere and a spin would merely
      stall this carrier, but the callers do not say which carrier the child is on, so the conservative
      abort stands.
    - *Lock order with N carriers* (in `prims_actors_carrier_asm.silica`'s header): a call wrapper's
      lock (+72) > the waiting actor's lock > the supervisor's lock > `_silica_rt_row_wait_lock` > a
      carrier's lock (+0). The carrier lock is a leaf: the loop takes it with nothing held; push,
      mark_idle, unlist and the sweep take it with at most one actor's lock (and what is above it)
      held; no path holds two carriers' locks. So a reply on carrier 2 pushing its parked caller to
      carrier 1, a cascade on a supervisor's thread stopping siblings on two carriers, and two
      carriers waking each other's actors take the locks in one order. `_silica_rt_carriers_lock`
      (the table's creation) is taken with nothing held.
    - *Idle sweep (the `:release_when_idle` gap of stage 1, closed).* An actor marked idle with
      policy 4 and committed stack goes on its carrier's sweep list (status 5, `_silica_rt_carrier_mark_idle`,
      linked through #456; the list changes only on the carrier's own thread or under its lock). The
      carrier sweeps (`_silica_rt_carrier_sweep`, lock held) before sleeping on an empty queue and
      sleeps with the earliest due time as its timeout (`_silica_rt_cv_wait_timeout`), and, so that a
      busy carrier releases too (cooperative scheduling: a carrier ping-ponging two actors never has
      an empty queue), at a dispatch at most every quarter second while the list is not empty. A listed
      actor a second past its last message (#344) is released by `_silica_rt_stack_idle_check`, the
      same check an actor thread makes in its timed wait, and becomes plainly idle; mail for a listed
      actor takes it off the list first (`_silica_rt_carrier_unlist`, under the carrier lock, so it
      never races the sweep). Nothing of a listed actor runs: it is off the run queue, and its ACB goes
      only after a dispatch (its exit path), which the unlist precedes.
    - *Trials* (`trials/carriers_addition`; the Makefile also passes `SILICA_CARRIER_COUNT=$(SILICA_CARRIER_COUNT)`,
      default 0 = the machine's count; named `workers_*` so they sort after the stage-1 trials and renumber
      no atom): `workers_call_cross_carrier` (300 calls A on core 1 -> B on core 2, the carriers wake each
      other), `workers_cast_stress_cross_carrier` (111 casts to each of four cast-only counters on
      cores 1..4 from a fifth carrier, multiset), `workers_two_carriers_interleaved_growth` (500,000-deep
      recursions on two carriers at once, `:keep_high_water` read back per actor: growth faults
      attributed per carrier), `workers_supervisor_children_on_different_carriers` (`:rest_for_one`
      rows bound in turn, the middle one killed by a plain worker on another carrier, restart, count,
      calls), `workers_exhaustion_on_one_carrier_keeps_siblings` (a 256 KB reservation exhausted on
      carrier 1 through a relay; siblings on carriers 1 and 2 recurse 300,000 deep afterwards; the poll
      for the release goes through a call so a shared carrier can run the exit),
      `workers_call_cycle_across_carriers` (documents today's behaviour: A on core 1 calls B on core 2
      which calls A; both park for ever with their kicker, the carriers are free and siblings on both
      still answer; the process ends through `exit`; to be re-derived when R1.5 lands),
      `workers_spawn_from_actor_binds_per_policy` (cores 0, 1, 2, 7, none from an actor, a registered
      spawn for core 3 from the driver, calls across every pair). No thread-count probe trial: nothing a
      program can observe is deterministic in the thread count (the registries' and supervisors'
      threads vary with what the trial support starts), so it is not written.
    - *Verified 2026-10-19 on the Mac* with the compiler built from this branch
      (`compiler/build/apple_silicon_mac/silica-compiler`, 13 s incremental, not installed):
      `carriers_addition` 36/36 (18 trials, two checks each) at `SILICA_CARRIER_COUNT=1`, 2 and 4 under
      `SILICA_CARRIERS=1` and 36/36 with the gate off (the 11 stage-1 trials' `.sams` unchanged against
      their `.ascomp`; the seven new `.ascomp` taken from runs whose `.sout` matched the hand-derived
      `.scout`, which every one did at the first run). The binding policy was
      confirmed with an instrumented `__silica_runtime.sams` (a `write(2)` of core id and carrier index
      in `_silica_rt_carrier_adopt`, built in the scratchpad, never in the tree): at N = 4 core 2 -> 2,
      core 7 -> 3, core 3 -> 3, no core id -> 0, 1, 2, 3 in turn; at N = 2 core 7 -> 1, core 2 -> 0; at
      N = 1 everything -> 0. `actor_stacks_addition` with the gate and count exported to the compiler too:
      25/26 at counts 1 and 2, `stack_release_when_idle_after_second` now passing (the sweep); the one
      failure is stage 1's `stack_lowered_reservation_exhausted`, whose worker busy-polls from a carrier
      shared with the relay it is waiting for (the exhaustion itself is handled and the carrier recurses
      300,000 deep afterwards): the trial assumes preemption, which the specification's cooperative
      yield points do not promise, so it is a trial shape to decide on, not a runtime defect. The
      hammer: every `carriers_addition` trial (18) run 30 times at each of counts 1, 2 and 4 under
      `SILICA_CARRIERS=1`, outputs compared as the suite compares them: 0 failures in 1,620 runs. With
      the gate and count exported to the compiler as well (so the compiler's own actors ran on carriers
      while it compiled each suite): `scheduler_policy_addition` 12/12 at counts 2 and 1 and with the
      gate off; `actors_addition` 753/753 at counts 1 and 2 and with the gate off (two of its runs,
      queued right behind another suite, stopped after 2 s with no trial run and no message the log
      kept; both passed when rerun alone: a harness-level stop, not reproduced); `supervisors_addition`
      292/292 at counts 2 and 1 and with the gate off; no trial `.sams` changed in any of them. The
      suites' `__silica_runtime.ascomp` goldens are not compared by `integrate` and are stale since
      stage 1 (the runtime text moved then and again now): to be refreshed per suite once each
      suite's `.sout` matches its `.scout`.
    - **Unverified:** `supervisors_host_defects_addition` and `actor_registration_addition` under both
      gates; every big suite at count 4; `actor_stacks_addition` with the gate off after stage 2; the
      `:dangerous` row flavour; a carrier actor spawning a supervisor; the compiler compiling itself on
      N carriers (risk R3.3's order); any Linux target. **The compiler has not run on carriers at all
      yet** (found 2026-10-19, below): `compiler/build/apple_silicon_mac/silica-compiler` is a gen1
      built by the installed `binaries/silica-compiler` (999945), so the runtime linked into it is the
      installed compiler's, with no carrier code (`nm` finds no `silica_rt_carrier*` symbol in either
      binary). Exporting `SILICA_CARRIERS` to the compiler process in the suite runs above changed
      nothing in it; every "compiler's own actors on carriers" claim in the stage 1 and 2 status is
      void until a gen2 (the branch compiler compiling itself) exists and runs the suites.
    - *The `train_actors_twoactors_0012` fault (2026-10-19, later): not a carrier defect.* A
      verification run of `actors_addition` with the gate exported to the compiler aborted once with
      exit 70 in `constraint_core_narrow_slot_backward+0x1e0`, `addr` outside the actor's reservation.
      Reproduced in a scratch copy of the suite (the batch's first pass, which parses all 382 units,
      is the process that faults, always at the 321st unit): fresh first passes fail 8/25 with the gate
      off, 8/25, 7/25, 6/25 and 4/25 at counts 1, 2, 4 and 8 (noise: the binary has no carrier code),
      and 8/25 with the installed 999945 compiler, so the defect predates the branch. The faulting
      instruction is `LDR X3, [X1, #24]` in the sret epilogue's heap promote
      (`emitter_core@sret_tuple_epilogue_copy`): a function returning a record it was given as a
      parameter copied `sret_aggregate_bytes` = 32 bytes (the 16-byte-rounded shell of the two-field
      `{ token, possible_roles }` slot record) out of the value in X0, while the value was a 24-byte
      region box made by `cons_slot`'s list cons (`emit_list_head_box`, `MOV X0, #24`). A `mmap`
      interposer (`DYLD_INSERT_LIBRARIES`, scratchpad only) showed the fault address equal to the end
      of the actor's 64 MB arena block (`0x15fe04000 + 0x4000000`): the box was that block's last 24
      bytes, the list handle after it had opened the next block, and the next block had not been placed
      adjacently, so the rounding word was on an unmapped page. In passing runs the next block is
      adjacent and the over-read reads its header harmlessly; the rate is the kernel's placement, not
      a race (under lldb, which perturbs the layout, 0 faults in 40 runs). Every record with an even
      field count was over-read by one word at every sret return of a value that was a box (a list
      head, a nested-record field copy, a parameter returned as is). Fix (all three emitters, same
      text): `prims_tuple@sret_aggregate_copy_bytes` (the value's flat size; tuples unchanged) is what
      both epilogue branches copy, through `term_aggregate_helpers@aggregate_return_heap_promote_x0_copy`
      (allocates the shell, copies the flat size); the caller's home and the promoted block keep their
      rounded size. Verified on the Mac: the build-dir compiler relinked with a `constraint_core.o`
      emitted by the fixed compiler (the lexer units with it) passed 25/25 fresh first passes with the
      gate off and 25/25 at count 4; the emitted `ident`/`narrow_slot_backward` epilogues copy three
      words. In `actors_addition` the fix changes two trials' `.sams` only
      (`record_float32_fields_state_reply`, `zero_heap_growth_record_call_per_message`: the fourth
      word's copy pair removed in both epilogue branches), so those two `.ascomp` move once their
      `.sout` matches. Trial `carriers_addition/workers_two_field_record_return_at_arena_block_end`
      (sorts last; no atom renumbered): worker a counts its own arena through `heap_used()` (exact for
      region allocations on hosted targets), fills its first block with 32-byte promoted records until a
      prepended two-field record's box is the block's last 24 bytes, and worker b's block, mapped right
      after a's first block and unmapped when b is removed (polled through calls to a relay, so a shared
      carrier runs b's exit), leaves the page after a's block unmapped; `ident(state.head)` then faulted
      10/10 with the unfixed compiler under the gate off and counts 1, 2 and 4, and answers 3 with the
      fixed one (40/40; `carriers_addition` 38/38 at counts 1, 2, 4 and with the gate off, its
      `.ascomp` recorded from a run whose `.sout` matched the hand-written `.scout`). The Linux
      emitters carry the identical edit, compiled only as a front-end check with the Mac compiler; the
      installed compilers (999945 and the Linux fixed points) still have the over-read, and the
      compiler will keep faulting this way one run in three on the suite's first pass until a compiler
      built by the fixed compiler is installed.
    - **Not done in stage 2:** exclusive pinning, `migrate_actor`, `set_actor_priority` and
      `set_scheduler_policy` on carriers (stages 3 and 4). Until then `pin_actor_to_core`,
      `pin_actor_to_efficiency_core`, `pin_actor_to_performance_core`, `unpin_actor`,
      `set_actor_priority` and `migrate_actor` answer their success value for a carrier actor and do
      nothing (the thread-affinity and QoS hints need a thread, and a carrier actor's ACB #144 is 0:
      in stage 1 they dereferenced it, a crash under the gate for any program that pinned a plain
      worker, found while reading the `scheduler_policy_addition` sources); supervisors on
      carriers; cycle detection and the self-call failure (R1.5); the Linux runtimes; the idle-actor
      capacity measurement.
  - **Stage 3 status (2026-10-19, `apple_silicon_mac` only, same branch, same gate): placement is
    real on carriers.** The runtime text changes (every suite's `__silica_runtime.ascomp` moves
    again); the trial `.sams` do not, except where a trial now uses the test-only query below.
    With the gate off the behaviour is stage 2's, plus the range check of `migrate_actor` and the
    `_silica_rt_sysctl_u64` fix, both below.
    - *Semantics per call, for a carrier actor* (`prims_actors_carrier_asm.silica` header,
      "Placement"; a thread actor, which is any actor with the gate off, a supervisor or a
      dangerous actor, keeps the thread-affinity-hint path it had):

      | call | effect | answer |
      | --- | --- | --- |
      | `spawn(..., core)` | bound at spawn to carrier `core mod N` when `core` is one of the machine's logical cores (1 .. `hw.logicalcpu` - 1, what `get_cpu_topology` reports; 0 is the default); a core the machine does not have, or none, binds in turn (the board's rule for an out-of-range core at spawn). Stays there for life unless the program moves it: the runtime never moves an actor on its own (spec §15.1.2, no rebalancing is implemented). | the reference |
      | `migrate_actor(ref, core)` | idle: bound to the target's carrier at once; idle on its carrier's sweep list: unlisted, bound, listed on the target; ready (queued), running or parked in a call: the target is pending in ACB #512 and applied at the next dispatch boundary (`_silica_rt_carrier_requeue`, or `_silica_rt_carrier_mark_idle` when the dispatch finds no mail); never while running, never at a resume (a parked actor resumes on the carrier it parked on, inside the same dispatch, spec §15.1.2). The mailbox is the actor's own and moves with it: message order is unchanged. Target carrier: `core mod N`. | `:ok`; `:invalid_target` when `core >= hw.logicalcpu` (either kind of actor); `:actor_not_found` for a null reference or an actor whose alive flag is clear (an ended actor, or one `remove_actor` has stopped); `:migration_blocked` is never produced on this target (nothing blocks a move) |
      | `pin_actor_to_core(ref, core)` | the move above (spec §15.1.2: the helpers are shorthands for `migrate_actor`) | the word 0 whatever the move answered: the `(int64, affinity_error)` tuple of §22.10 is not materialised by any emitter (pre-existing) |
      | `pin_actor_to_performance_core(ref)` | carrier i is logical core i's; the P carriers are `[0, min(P, N))`, P = `hw.perflevel0.logicalcpu` (all cores when the machine does not answer: a uniform topology is all P). Already on one: no move; else the move to the next P carrier in turn (`_silica_rt_pcore_next`) | 0 |
      | `pin_actor_to_efficiency_core(ref)` | the E carriers are `[P, N)`: none when `N <= P` (a `SILICA_CARRIER_COUNT` of P or less) or the machine has no E cores. Already on one, or none: no move; else the move to the next E carrier in turn | 0 |
      | `unpin_actor(ref)` | nothing (no unpinned state, spec §22.10; a thread actor clears its affinity tag as before) | `:ok` (emitter) |
      | `pin_actor_realtime`, `pin_actor_to_numa_node` | nothing: no real-time policy and no NUMA domain is honoured on this target (unchanged stubs) | 0 |
      | `actor_carrier_index(ref)` (test-only) | reads ACB #440 -> carrier +112 | the index, -1 for a thread actor or a null reference; a pending move is not reported until applied |

      Exclusivity: none is promised on an OS-hosted target (spec §15.1.2 OS-hosted; memory
      `silica-core-pinning-hosted-vs-raw`). What the carrier model guarantees is the carrier:
      an actor runs only on the carrier it is bound to, and only the program moves it. The
      hosted runtime does no BEAM-style balancing of its own: a program that wants it moves
      actors itself (the in-turn choice at spawn and per kind at a pin is the only spreading).
    - *Carrier affinity.* Each carrier thread asks the OS for affinity to its logical core with
      `thread_policy_set(THREAD_AFFINITY_POLICY, tag = index + 1)`, as the thread actors did
      (`_silica_rt_carrier_main`). On Apple Silicon the kernel answers `KERN_NOT_SUPPORTED` (46,
      measured with a 10-line C probe on this Mac): there is no thread-to-core binding at all on
      this target, so a carrier runs wherever the OS puts it; the request is kept for hosts that
      honour the tag and its result is not checked. `get_cpu_topology()` and the core lists come
      from sysctl as before; the carrier count defaults to the same `hw.logicalcpu` and carrier i is
      core i, so a core id means the same thing to `spawn`, `migrate_actor` and the topology.
    - *Hand-off protocol and locks.* `_silica_rt_carrier_migrate` holds the actor's lock and takes
      at most one carrier lock at a time (the old carrier's in the unlist, released before the
      target's in the relist); the lock order of the stage 2 header is unchanged (carrier locks
      remain leaves). The pending word is taken by an exclusive-load/store swap
      (`_silica_rt_carrier_apply_pending`) so a later request is never lost. Invariant: an actor
      on a carrier's run queue or sweep list has #440 = that carrier (push and listing read #440
      after the apply; #440 changes only while the actor is on neither, under its lock). Every
      path that leaves an actor now re-enters the loop of the carrier its thread is, read before
      the actor's status was published (`_silica_rt_carrier_requeue`, the no-mail path of the
      mailbox loop, the three park sites: `LBB4_wait_start`, `_silica_rt_spawn_wait_started`,
      `_silica_rt_wait_park`); `_silica_rt_carrier_leave`, which read #440 after the park, is
      gone, since a moved actor's #440 would have sent the old thread into another carrier's
      loop. Exit paths and the fault handler still read #440: the actor is running then and a
      move is only pending.
    - *ACB.* 528 B (#512 the pending target, #520 spare); both `calloc` sites, `_silica_rt_dead_acb`
      and the layout comments updated.
    - *Root causes found on the way (all fixed in this tree).* (1) `_silica_rt_sysctl_u64`
      stored its length word and then zeroed it (`stp xzr, xzr, [sp]` after `str w0, [sp, #8]`), so
      every `sysctlbyname` through it answered ENOMEM and every caller got 0: the stage 2 default
      carrier count ("`SILICA_CARRIER_COUNT=0` = the machine's count") was 1 carrier, never the
      machine's; `get_cpu_topology()` failed on `hw.memsize` and answered its failure value, which
      `cpu_discovery_and_spawn_pinning/cpu_topology_phase_h_verify.scout` had recorded as the
      golden (0 cores, 0 NUMA nodes; re-derived to 1 and 1); the cache sizes were 0. Fixed by
      zeroing first, in `apple_silicon_mac` and, because the `.scout` is shared, the identical
      two-line reorder in `linux_aarch64` and `linux_x86_64` (compiled only as a front-end check
      here). (2) The effect checker did not know `migrate_actor`: a sequence whose only
      concurrency call was a `migrate_actor` was rejected with E3010 (unused effect) and a call
      outside `proc[concurrency]` was accepted, against spec §22.10. Added to both tables of
      `effect_checker_core.silica`; trial
      `error_enforcement_addition/effect_migrate_actor_undeclared` (E3002), which the installed
      compilers accept until one built from this tree is installed. (3) Pre-existing and NOT
      fixed: `get_efficiency_cores()` / `get_performance_cores()` read wrongly through the list
      builtins (`length` 4 and `head` 5 for the E list [4..9] on this Mac, from `main` and from an
      actor, with the installed 999945 compiler as well as this tree's), so
      `cpu_discovery_and_spawn_pinning/cpu_topology_runtime_queries` fails with either compiler
      and that suite's four `.ascomp` are stale (a different emitter's text); the new kind-pin
      trial counts cores through `get_core_capabilities` instead.
    - *Trials* (`trials/carriers_addition`, named `workers_zpin_*`; the compile order is
      topological, so atoms of trials on `trial_support_int64` are numbered before the two
      `trial_wait_int64` trials: `workers_call_cycle_across_carriers` and
      `workers_cast_stress_cross_carrier` renumber six atoms and their `.ascomp` were refreshed
      from runs whose `.sout` matched). The observable is `actor_carrier_index`, and every printed
      fact is an equality with a probe actor spawned for the same core, so the goldens hold at
      every carrier count (the probe binds to `core mod N` too) and with the gate off (-1 == -1):
      `spawn_for_core_runs_there`, `pin_then_unpin`, `pin_performance_efficiency`,
      `migrate_idle_actor` (an idle and a sweep-listed actor), `migrate_running_actor_defers_to_dispatch_boundary`
      (self-migration inside the behaviour: the index read before the return is the old carrier),
      `migrate_parked_in_call_actor` (the callee moves its parked caller; the caller resumes on the
      old carrier and runs its next dispatch on the new), `migrate_with_pending_mail_keeps_order`
      (150 casts around three moves, served in order), `migrate_to_invalid_core_returns`
      (`:invalid_target`, `:ok` for the current core, `:actor_not_found` after `remove_actor`),
      `cast_stress_while_migrating` (1,000 casts while another actor moves the counter 400 times),
      `supervisor_child_migrated_then_restarted` (a row child moved, killed, its replacement moved;
      the old reference answers `:actor_not_found`). Where a fact must be read after a move
      requested during a dispatch, the trial sends one more call first, since the move is applied
      after the reply of the dispatch it was requested in.
    - *Verified 2026-10-19 on the Mac* with the compiler built from this branch:
      `carriers_addition` at `SILICA_CARRIER_COUNT=2`: every `.sout` matched (the `.ascomp` of the
      ten new trials recorded from that run); the placement itself confirmed with a scratch program
      printing `actor_carrier_index` after each call at counts 1, 2, 4 and 10 (core 1 -> 1, migrate
      to 3 -> 3, pin to 2 -> 2, performance pin stays, efficiency pin -> 4 at count 10 and stays at
      4 or fewer carriers, an absent core -> `:invalid_target`; -1 throughout with the gate off).
      Then `carriers_addition` 58/58 (29 trials, two checks each) at `SILICA_CARRIER_COUNT=1`, 4 and
      the default (the machine's 10, real since the sysctl fix) under `SILICA_CARRIERS=1`, and 58/58
      with the gate off. The hammer: each of the ten new trials run 30 times at counts 1, 2 and 4
      under the gate and 30 times with it off, compared as the suite compares: 0 failures in
      1,200 runs. `actors_addition` 753/753 with the gate off (one first-pass compiler fault of
      the known sret kind, rerun) and 753/753 at count 2 under the gate (the gate and count
      exported to the compiler process too, which changes nothing in it: the build-dir compiler
      is a gen1 with the installed runtime); `scheduler_policy_addition` 12/12 at count 2 and with
      the gate off; `cpu_discovery_and_spawn_pinning` 3/8 at count 2, the same five pre-existing
      failures (four stale `.ascomp` and `cpu_topology_runtime_queries`'s list reads) it has with
      the installed compiler, `cpu_topology_phase_h_verify` passing against its re-derived `.scout`.
      **Unverified:** `supervisors_addition`, `actor_stacks_addition`, `supervisors_host_defects_addition`
      and `actor_registration_addition` after stage 3 under either gate; every big suite at count 4;
      any Linux target (the Linux runtimes have no carriers, no `actor_carrier_index`, and
      `carriers_addition` is Mac-only); the two Linux helper reorders beyond a parse of the units;
      the compiler compiling itself on carriers (still no gen2).
    - **Not done in stage 3:** `set_actor_priority` and `set_scheduler_policy` on carriers (stage
      4); supervisors on carriers; the Linux runtimes (no carriers; they received only the sysctl
      reorder); materialising the `(int64, affinity_error)` tuple of the `pin_actor_*` helpers;
      `pin_actor_realtime` and `pin_actor_to_numa_node` stay stubs; the ROADMAP chunk 2 and
      specification "implementation status" paragraphs (§15.1.2, §15.1.2.2) still describe the
      thread-per-actor runtime and should be refreshed once this branch is published.
  - **Stage 4 status (2026-10-19, `apple_silicon_mac` only, same branch, same gate): the dispatch-order
    policies and the priority levels are real per carrier.** `set_scheduler_policy` has a runtime
    symbol on the Mac for the first time (`_silica_rt_set_scheduler_policy`, in
    `prims_actors_carrier_asm.silica`; the emitter's inline `MOV dest, #:ok` is gone), so the `.sams`
    of every program that calls it changes (the six `scheduler_policy_addition` host `.ascomp` are
    stale) and the runtime text moves again (every suite's `__silica_runtime.ascomp`); no other trial
    `.sams` changes. With the gate off the behaviour is stage 3's, plus the two answer changes marked
    "either gate" below.
    - *Scope.* One policy word for the process (`_silica_rt_sched_policy`, 0 = `:priority_fifo`),
      applied by every carrier to its own run queues: the board's rule ("one policy is in force for
      the whole program and every core applies it to its own ready queues", rt_actors.S), and the
      specification's reading (`set_scheduler_policy` names no core; §22.10 and §23.1.1 make the
      priority levels hints to "the per-core scheduler"). "Per carrier" in this item means that each
      carrier orders its own ready set under the one policy, as each board core does, not that a
      carrier has a policy of its own; a per-carrier word would need a core argument the call does
      not have and would make a call from `main` (no carrier) meaningless.
    - *Storage.* The carrier block is 256 B (128 before): +128 three run queues, 24 B each at
      +128 + 24 q (q = 0 high, 1 normal, 2 low: head, tail, length), +200 the weighted-fair tier
      being served, +208 its credit (4 at creation: a round starts at the high tier with its
      quantum, as a board core's does), +216 the lottery's xorshift64 state; +24/+32, the one
      queue of stages 1 to 3, are unused. ACB #520 (the stage 3 spare) is the priority level (0
      low, 1 normal, 2 high), written as 1 right after both `calloc`s (every actor starts at
      `:normal`, §22.10) and in `_silica_rt_dead_acb`; the layout comments in
      `prims_actors_runtime_asm.silica` and the carrier header are updated. The three sites that
      stepped through the table by 128 (`_silica_rt_carrier_adopt`, `_silica_rt_carrier_for_core`,
      `_silica_rt_carrier_pick_kind`) step by 256.
    - *Where the policy is read.* Only `_silica_rt_rq_push` (from `_silica_rt_carrier_push`, the
      one way an actor enters a run queue: mail, a wrapper wake, a started store, a wait-list
      wake, a stop, a requeue) and `_silica_rt_rq_pop` (from the carrier loop, `Lcar_have`),
      both under the carrier's lock, which stays a leaf of the stage 2 lock order; the loop's
      "anything queued" check reads the three heads. Cooperative throughout: a policy orders
      dispatch and never preempts a running behaviour (spec §15.1.2 yield points).

      | policy | push (the queue the ready actor is appended to) | pop (the actor that runs next) | starvation |
      | --- | --- | --- | --- |
      | `:priority_fifo` (default, 0) | its priority tier | the head of the highest-priority non-empty queue; an actor with more mail goes back to the tail of its tier at its dispatch boundary, so a high actor with mail runs before any normal one, a normal before any low one | strict within a carrier: the bound of §22.10 holds only while the higher tiers drain; a program whose high actors always have mail selects `:weighted_fair` or `:lottery` (the board's semantics; `workers_zsched_priority_per_carrier` shows the caveat) |
      | `:round_robin` (1) | the normal queue, whatever the level | the same scan, so one flat queue in strict arrival order | none |
      | `:weighted_fair` (2) | its priority tier | deficit round robin over the tiers, quanta high 4 / normal 2 / low 1, a unit cost per dispatch: the tier being served runs its head while it has credit and actors, then the next tier starts with its quantum; an empty tier forfeits it | none: a low actor waits at most 4 + 2 dispatches, a normal one at most 4 + 1 |
      | `:lottery` (3) | its priority tier | tickets = weight x queued actors per tier (4 / 2 / 1); a xorshift64 draw per carrier (seeded from the clock and the carrier's index at the first draw) picks the tier in proportion, the tier's head runs | none in expectation (a low actor against one busy high actor is drawn with probability 1/5 per dispatch), no hard bound |

      A policy change (any time, from anywhere) takes effect at the next push or pop on every
      carrier and leaves queued actors where they are, the board's rule: a switch to `:round_robin`
      first drains what waits in the high and low queues (the pop scan is the same), and every push
      from then on lands in the normal queue; a switch away from it treats what waits in the flat
      queue as normal until each actor's next push (`workers_zsched_policy_change_while_ready`
      derives H N H N H N H N L L L L from exactly this).
    - *Priority levels.* `set_actor_priority(ref, level)` stores the level in #520 for every
      actor (an unknown level is normal, as on the board). A carrier actor's level is the tier of
      its next push and its weight class: an actor already queued stays in the queue it was pushed
      to (the board's rule; `workers_zsched_priority_change_of_ready_actor` derives
      H N N N N L L L L H H H). A thread actor's level is also mapped to a pthread QoS class as
      before (gate off, supervisors, dangerous actors). Answers, either gate: `:ok`;
      `:actor_not_found` for a null reference and now also for an actor that has ended (the alive
      flag, as `migrate_actor` and the board check; before, an ended thread actor's dead thread
      was given a QoS class and `:ok` answered).
    - *Return atoms.* `set_scheduler_policy` answers `:ok` for the four names and
      `:invalid_policy` for any other atom, the board's atoms, either gate (the policy word is
      stored with the gate off and nothing reads it: the four names stay accepted and have no
      effect, since the OS schedules the threads). The emitter maps the program's atom indices to
      the codes 0..3 before the call (an atom the program never names gets no compare; the code
      stays 4, rejected) and the code back to `:ok` / `:invalid_policy` after it
      (`prims_actors.silica emit_set_scheduler_policy_with_atoms`, the `migrate_actor` pattern;
      `:invalid_policy` was already interned for the prim by `atom_table.silica`). Consequence
      for an existing golden: `scheduler_policy_addition/scheduler_policy_names_accepted` now
      prints `:invalid_policy` / `rejected` on the Mac, the lines of its board golden
      (`.ESP32-S3_raw.scout`), not of its shared `.scout` (`:ok` / `accepted`, written when the
      hosted call was a no-op). Not changed here: a `.scout` moves only with Lee's decision; the
      options are to take the board's lines into the shared `.scout` (the per-target golden then
      says nothing the shared one does not) or to keep accepting every atom with the gate off,
      which would make a program's answer depend on an environment variable and is not
      recommended.
    - *Trials* (`trials/carriers_addition`, `workers_zsched_*`, on `trial_wait_int64` so that
      their atoms are numbered after every existing trial's and no `.ascomp` moves; compile
      order is topological, `trial_support` users first). The order trials put the three actors
      AND a driver actor on core 1's carrier (`core mod N`: the same carrier at every count) and
      the driver's one dispatch sets the levels and the policy and queues the twelve casts, so
      nothing runs before everything is queued, which is what main's casts achieve on the board
      (core 0 dispatches only when main suspends) and what main's casts cannot achieve on a
      host (main is a thread; the carrier runs beside it). Their goldens are exact under the
      gate; with the gate off the actors are threads and the same lines are compared as a
      multiset: a new marker, `<stem>.scout.ordered_on_carriers`, which the suite's Makefile
      reads as "in order under `SILICA_CARRIERS=1`, multiset otherwise". `priority_fifo_order`
      (H H H H N N N N L L L L), `round_robin_order` (L N H ...), `weighted_fair_order`
      (H H H H N N L N N L L L), `weighted_fair_counts` (eighteen casts; the three reports in the
      order H, N, L, derived from the quanta), `lottery_all_run` (multiset under either gate),
      `policy_change_while_ready`, `priority_change_of_ready_actor` (both derived above),
      `priority_per_carrier` (a high actor feeding itself 100,000 steps on core 1's carrier and a
      low actor on core 2's: the mark the low actor sends arrives while the high one is still
      counting when they are on different carriers and exactly at the end of the drain when they
      share one, `:priority_fifo`; the trial reads which case holds from `actor_carrier_index`,
      -1 under the gate off counting as independent, so the verdict holds at every count and
      either gate), `no_starvation_weighted_fair` (the same shape on one carrier: the mark is
      handled at step 5 of the drain, the verdict asks for at most 8, the spec's bounded number
      of dispatches; with the gate off, below 100,000), `no_starvation_lottery` (below 100,000
      under either gate), `policy_names` (the four names, a rejection, a change after it, under
      either gate). Three front-end facts met on the way, worked around in the trial sources and
      not fixed: a call in a `case` subject (`case next < k() of`), a `cast(..., v impl
      ActorMessage {})` in a `case` arm, and `self()` in a `case` arm each answer E2005 "invalid
      or unsupported case pattern" (the arm's braces and the subject's call confuse the case
      parser); the trials bind the comparison and `self()` first and cast through a helper.
    - *Verified 2026-10-19 on the Mac* with the compiler built from this branch (13 s
      incremental; a gen1 whose own runtime is the installed compiler's, so the gate reaches only
      the trial processes): `carriers_addition` 80/80 (40 trials, two checks each) at
      `SILICA_CARRIER_COUNT=1`, 2 and 4 under `SILICA_CARRIERS=1` and 80/80 with the gate off;
      every hand-derived order golden matched at its first run and the eleven `.ascomp` were
      recorded from runs whose `.sout` matched. The hammer: each of the eleven new trials run 30
      times at counts 1, 2 and 4 under the gate and 30 times with it off, compared as the suite
      compares: 2 failures in 1,320 runs, both `policy_change_while_ready` with the gate off,
      where the driver's second `print_atom` (after the casts) shared a line with a turn actor's
      `println` on another thread (`:okturn L`): the known interleaving of thread actors, not a
      scheduler fault; the print was removed and the trial re-recorded, then 0 failures in 120
      more runs of it over the four configurations. `scheduler_policy_addition` with the branch
      compiler, with the gate off and at count 2 under it: the five order and count trials'
      outputs match their shared `.scout` (multiset), `scheduler_policy_names_accepted`'s does
      not (`:invalid_policy` / `rejected`, above), and all six `.sams` differ from the host
      `.ascomp` (the policy call), which are to be refreshed once the `.scout` question is
      settled. Whether the existing hosted `*_order` trials could now take exact goldens: no, as
      they stand. Measured over 30 runs each under the gate, `main`'s casts from its own thread
      race carrier 0's dispatch: at count 2 all three printed the board's order 30/30, at count 1
      `priority_fifo_order` 28/30 (`N H H H H N N N L L L L`, `L H H H H ...` once each),
      `weighted_fair_order` 26/30, `round_robin_order` 30/30; the order is the policy's only when
      every message is queued before the first dispatch, which `main` on a host cannot guarantee.
      Recommendation: keep their multiset goldens, and take the exact-order fact from the
      `workers_zsched_*` twins; or, if one source is wanted for both targets, reshape the three
      trials to the driver-actor form (a driver on the actors' core issues the casts in one
      dispatch), which is deterministic on the board as well, and then give them exact goldens
      on every target. The pin/migrate subset of `actors_addition` (`actor_cross_core_call_reply`,
      `actor_cross_core_cast_stress`, `actor_migrate_and_move`, `identity_cross_core`,
      `migrate_actor_expression_core`, `actor_builtins_return_ok`) at count 2 under the gate:
      6/6, every `.sams` unchanged against its `.ascomp`. **Unverified:** the whole of
      `actors_addition`, `supervisors_addition`, `actor_stacks_addition`,
      `supervisors_host_defects_addition` and `actor_registration_addition` after stage 4 under
      either gate (a full run is pending; the runtime text moved, the trial `.sams` did not, so
      only run-time behaviour can differ); `scheduler_policy_addition` at counts 1 and 4; any
      Linux target; the compiler compiling itself on carriers (still no gen2).
    - **Not done in stage 4:** supervisors on carriers; the Linux runtimes (no carriers, no policy
      symbol: their `set_scheduler_policy` is still the inline `:ok`); materialising the
      `(int64, affinity_error)` tuple; time (`send_after`, `call_with_timeout`) and any
      preemption or reduction budget (ROADMAP chunk 11; the port design's §8.10 says why a
      budget needs a specification change first); the `scheduler_policy_addition` hosted goldens
      (above); the ROADMAP chunk 2 and port-design §8.10 sentences that call the hosted
      `set_scheduler_policy` a no-op, to be refreshed when this branch is published.

## 6. Gate (common)

- A: a supervisor that ends frees every child-table row it held; a spawn/end loop shows no heap growth
  beyond what the loop's own calls leak. (Board: shown 2026-10-09, `stack_budget_board_addition/
  supervisor_end_frees_child_table`, §13. Hosted: to be shown by the same loop; the source already frees.)
- B: the two new trials in item B pass on the target, and no ACB or message node holds a stack address.
- I and J are gated with each target's own count (§13, §18).
- K: the item K trials pass on every hosted target and on the board, and no program ends because it went idle.
- L: every hosted compiler reaches a fixed point with the small `main`, and the full trial tree passes with it.
- Each target's gate is in its own part: §13 (board), §18 (hosted).

# Part II: The board (ESP32-S3_raw)

## 7. The numbers today

`silica_esp32s3.ld` maps internal SRAM1 (one physical array, seen at the instruction bus `0x4037_8000` and
the data bus `0x3FC8_8000`) as a single `0x61700`-byte window: **399,104 B, 389.75 KiB** usable by this
bare-metal image. The ROM keeps its own stack and data above that, and SRAM0 is left free for it to use as
instruction cache. The chip has **no demand paging**: nothing is committed lazily, so every byte of every
stack is resident from the moment it is allocated.

Fixed runtime reservations, verified against source 2026-09-29:

| Reservation | Bytes | Source |
| --- | ---: | --- |
| `main`'s machine stack | 131,072 | `silica_esp32s3.ld:36` (`_silica_stack_size`), top of the SRAM window |
| `main`'s auxiliary stack | 65,536 | `rt_start.S` (`AUX_STACK_SIZE`), in `.bss` |
| Fault stack | 2,048 | `silica_esp32s3.ld` (`_silica_fault_stack_size`) |
| Canonical arena table + count + env pointer | 8,208 | `rt_ordering.S` (512 × 16 B table + two 8 B words) |
| Actor-runtime fixed state (per-core blocks, both cores' ACBs, per-core scheduler stacks, locks, free-list heads, pid-registry refs) | 9,410 | `rt_actors.S` `.bss.silica_rt_actors` (`silica_rt_cores` → `silica_rt_region_dump_limit`) |
| Per-core register blocks (×2 cores) | 256 | `rt_start.S` (`VRG_BLOCK_SIZE=128 × NCORES_MAX=2`) |
| Core 1's boot stack | 2,048 | `rt_start.S` (`CORE1_STACK_SIZE`); used only until core 1 enters its scheduler |
| Heap bookkeeping (bump pointer, free-list head, lock) | 12 | `rt_heap.S` |
| **Total** | **218,590 (213.5 KB)** | |

**55% of usable SRAM is claimed before a byte of program code, data or heap exists, and 90% of that is
`main`'s two stacks.** (Since 2026-10-08, item D, the two are sized per image: a converted `main` reserves
about 1 KB + 256 B, and a small trial image's heap is ~358 KB instead of ~163 KB; the 192 KB figure
remains only for a `main` the static walk cannot bound.) What remains (~176 KB nominal) holds code, rodata, data, the rest of `.bss` and the
heap. Measured 2026-09-28: **~170 KB of heap** (174,080 B is the figure used below) for a small trial image,
and as little as **~18.5 KB** for a large one (`generic_modules_addition/two_generic_collections_record_round_trip`
and `.../two_generic_collections_round_trip`: `.iram0.text` alone is 147 KB, because `wbt_set.silica` is
5,474 lines and `--gc-sections` could not drop unused functions while each compiled unit was one `.text`
section; per-function sections landed 2026-10-05, item G, and these two have not been re-measured since).

**Failure modes.** Every stack — `main`'s two, each actor's two — ends in a 64-byte guard band watched by
one of the two Xtensa data breakpoints, re-armed at every context switch for the context about to run. A
store into the band is a debug exception (cause 1006). In an actor it ends only that actor with
`(:explicit, :stack_exhausted)` (`rt_actors.S`); in `main` it is a fatal fault, exit status 70
(`board/README.md`, `esp32s3_port_status.md`). Neither corrupts memory, so a stack that turns out too small
fails loudly. The one gap is §8.2.

### 7.1 Per-actor and per-supervisor cost

An actor's ACB and both its stacks come from the general heap (`rt_actors.S`, `rt_heap.S`), so every spawn
is heap pressure. Verified 2026-09-29:

| Item | Bytes | Source |
| --- | ---: | --- |
| ACB — any actor (item I, 2026-10-09: 128, 264 before; 144 since the identity words of 2026-10-12) | 144 | `rt_actors.S` `ACB_SIZE`, via `silica_rt_alloc_acb` |
| Supervision block — a supervisor's only (ingress queue, trampoline, strategy, restart accounting, child table head/len/users/pending); also made for an actor that receives an exit notice through `add_child` | 64 | `rt_actors.S` `SB_SIZE`, via `silica_rt_sb_require` |
| `:track_recent_peak` ring — that algorithm's actors only | 32 | `rt_actors.S` `RING_SIZE`, in `silica_rt_spawn_common` |
| Stacks (item F, 2026-10-08): none at spawn, none while idle under `:release_on_return`. An actor dispatched with none takes a first machine chunk of 2,048 and an auxiliary chunk of 512; later chunks double up to 16,384 / 4,096, or hold the frame or slab plus 1,024 / 256 of headroom. A lowered `stack_policy` reserve caps both stacks together (first chunks at least 768 / 256) | 0 at rest; 2,560 per first dispatch | `rt_actors.S` `MCHUNK_FIRST`, `ACHUNK_FIRST`, `MCHUNK_CAP`, `ACHUNK_CAP`, `MCHUNK_HEADROOM`, `ACHUNK_HEADROOM`, `*_LOWERED_MIN`; `silica_rt_alloc_stack` |
| Allocator overhead per stack chunk: 16 B header + up to 63 B of 64-byte alignment slack, plus a 64 B chunk header and a 64 B guard band inside it | ≤79 + 128 | `silica_rt_alloc_stack`; `rt_actors.S` "Growable stacks" |
| Supervisor child-table row, one per child it has *ever* held; freed when the supervisor ends (item A) | 112 | `rt_supervisors.S` `ROW_SIZE` (96 before the spawner record of 2026-10-12), via `silica_rt_alloc`, chained off the supervision block |

One actor at rest: the 144 B ACB plus the heap's 8 B block header, **152 B**, and no stack (derived from the
constants above; the 1,005-actor measurement of item I, 190,696 B in use, was taken with the 128 B ACB). A
dispatched actor adds its chunks, 2,560 B plus overhead for the first pair, until its release algorithm
gives them back. A supervisor costs 64 more once (its supervision block), plus a 112 B row per child. Before
item F the same actor held 10,240 B of stacks for its whole life (~10,526 B with the 128 B ACB, ~10,654 with
the 264 B one). The registry actor every `main` injects at startup (~3.5 KB) is a fixed program-wide cost,
not per actor.

**Recycling.** ACBs and message nodes go to their own free lists (`silica_rt_acb_free`, `silica_rt_node_free`)
and are never returned to the general heap — `silica_rt_free_acb` only pushes. Stack chunks of a live actor
are pushed on `silica_rt_stack_free` by `silica_rt_free_stack` for the actor's next dispatch (no zeroing, no
search), and `silica_rt_alloc_stack` reuses a free block only on an **exact** size match (`beq` on the
header's size word); the chunks of an ended actor go back to the general heap with `silica_rt_stack_to_heap`
(fix of 2026-10, found by `stack_budget_board_addition/supervisor_end_frees_child_table`: kept on the free
list they held the peak of chunks ever in use at once, so heap use varied with the timing of the two cores).
Two consequences remain: a program's *peak historical* actor count, not its current one, sets a heap floor
for the rest of its life through the ACB list; and chunks of many different sizes strand memory in the stack
free list, which is why the chunk sizes double from fixed starting points.

**Leak (item A), fixed 2026-10-09.** `silica_rt_child_table_free` (run when a supervisor ends) used to zero
`ACB_CT_HEAD`/`ACB_CT_LEN` without walking the row chain and freeing each row, unlike
`silica_rt_region_destroy`, which does exactly that for a region's extension chain; every row a supervisor
ever held was orphaned when it ended (independent of the 2026-09-28 `rt_heap.S` rewrite that made `free`
real). It now frees the rows, with the lifetime rules in §5 A. Measured on the board with a ten-worker
supervisor ended and restarted ten times: 29,760 B of growth with the rows kept, 19,440 with them freed
(10 rows × 104 B a cycle); the rest is the loop's four `call_supervisor` reply records a cycle and the
restarted init's child-spec list, neither freed yet.

## 8. Board correctness details

The mechanism of §3 on the board, and what the `run_behaviour` pad does and does not cover. Verified
2026-09-29.

- `silica_rt_spawn_common` stores the spawner's `X0` straight into `ACB_STATE` (`s32i a3, a2, ACB_STATE`).
- `silica_rt_run_behaviour` copies `reply` and `state` out of the result tuple as one 64-bit slot each into
  `MSG_REPLY` and `ACB_STATE`.

### 8.1 What the 1.5 KB pad in `silica_rt_run_behaviour` does, and does not do

`silica_rt_run_behaviour` opens `entry a1, 1568` (`rt_actors.S:1331`). Its stated job: the result may point
into the behaviour's frame region just below this frame, so the loop frames built after the behaviour returns
must fit *inside* the pad and leave that region intact. That protects fixed-frame composites on the machine
stack until the actor yields — and nothing else. `SUB SP` composites on the auxiliary stack are outside its
reach at any size, and once the actor is rescheduled and runs another behaviour, the next `run_behaviour`
descends over the region whatever the pad is. The pad is a partial mitigation of the problem in §3, not a
solution.

Measured, its job needs **192 bytes**: everything `silica_rt_actor_main` calls after
`call8 silica_rt_run_behaviour` returns, deepest first —

| Call | Depth |
| --- | ---: |
| `silica_rt_actor_exit` → `deliver_unwind_report` → `actor_cast` → `alloc_node` → `alloc` → `heap_take` | **192** |
| `silica_rt_yield_to_sched` → `ctx_switch` → `console_release_if_mine` | 96 |
| `silica_rt_wake` → `rq_push` | 64 |
| `silica_rt_free_node`, `silica_rt_rq_push`, `silica_rt_free` | 32 |

`yield_to_sched` switches to the scheduler's own stack, so nothing the scheduler does is charged here. The
pad is about 8× its requirement, and it is the single largest per-actor cost: 1,568 of an actor's 1,856 B
of fixed overhead (§9). With item B done the pad has no job left except covering its own loop's
post-behaviour frames, which is what item C then shrinks it to.

### 8.2 A guard-band gap that smaller stacks make more likely

The breakpoint fires on a store *into* the 64-byte band. `entry` only subtracts; window-overflow spills go
to the top of the callee's frame; outgoing-argument homes are at the frame's bottom but only when a
function passes more than three arguments. A frame or slab larger than 64 B whose stores all land above the
band can therefore straddle it and write below the block unseen. `silica_rt_run_behaviour`'s 1,568-byte
frame stores nothing near its bottom, so with a 2 KB stack it is the likeliest frame to do this. Shrinking
the pad (item C) reduces the exposure; a probe store at the lowest address of any frame or slab larger than
the band, emitted in the prologue or at the `SUB SP`, removes it. Recorded here so the smaller sizes below
are not adopted without it being decided (item E).

**Decided and built 2026-10-08 (item D):** a single probe store is not enough — a frame larger than the
band whose caller sat just above it can land entirely below the band — so emitted code compares instead:
the prologue checks `a1` against the context's machine limit (band top + the runtime reserve), every `SP`
reservation checks the new `SP` against the auxiliary limit, and a failing check stores into the band on
purpose (`silica_rt_stack_overflow` / `silica_rt_aux_overflow`), so the watchpoint still reports it. The
hand-written runtime's own frames are covered by the reserve: the deepest runtime chain emitted code can
call is measured per image and kept above the band under every emitted frame.

## 9. Static sizing bounds (board)

The rules these bounds rest on are in §4; this is the board's arithmetic.

**Method.** A static call-graph walk over `board/runtime/*.S`: sum `entry a1, N` along `call8` edges and
take the maximum over branches. Fallthrough labels with no `entry` of their own (`silica_rt_actor_spawn_linked`
falls into `silica_rt_actor_spawn_dangerous_linked`) resolve into their successor. The walk cannot follow
`callx8` into emitted code — the behaviour, a supervisor's `init` — so those are estimated and marked; it
does not count libgcc frames for `float64` arithmetic or 64-bit division; and the maximum it reports is
often a failure branch (the spawn paths bottom out in `spawn_reserve_failed` → `actor_trap` → …), which is
conservative. Every figure here is a bound to be confirmed on the board with the high-water scan in
`silica_rt_get_actor_memory_usage` (lowest non-zero word of the zeroed block), item E.

| Context | Decomposition | Bound |
| --- | --- | ---: |
| `main` | `_start` + `silica_rt_start_windowed` 64 + emitted `main` SFRAME ~112 (est.) + `silica_rt_registry_spawn` 416 + guard 64 | **~656 B** |
| Supervisor | `ctx_prepare` frames 144 + `silica_rt_actor_main` 80 + trampoline SFRAME 48 (fixed, `supervisor_trampoline_frame_header`) + `silica_rt_supervisor_materialize_init_children` 480 + guard 64 | **816 B** |
| Actor, fixed overhead only | `ctx_prepare` 144 + `silica_rt_actor_main` 80 + `silica_rt_run_behaviour` 1,568 + guard 64 | **1,856 B** |
| Actor, fixed overhead, pad at 512 | 144 + 80 + 512 + 64 | **800 B** |

Other things `main` does are shallower: `wait_for_exit` 240, `actor_spawn` 368, `get_cpu_topology` 176,
`set_scheduler_policy` 32. The exit path after `main` returns (`silica_rt_exit` chain, 208) is a sibling at
the same depth, not additive.

## 10. Proposed sizes, and what they buy (board)

Interim constants for the root-supervisor shape, with the pad at 512 B (item C done) and actor stacks at
the runtime's 1:4 ratio. Sizes are multiples of 512 B so the exact-match free list has few classes.

**Fixed reservations.**

| Reservation | Now | Proposed | Source |
| --- | ---: | ---: | --- |
| `main` machine stack | 131,072 | **1,024** | `silica_esp32s3.ld:36` |
| `main` auxiliary stack | 65,536 | **256** | `rt_start.S` `AUX_STACK_SIZE` |
| Everything else in §7 | 21,982 | 21,982 | |
| **Total** | **218,590 (213.5 KB)** | **23,262 (22.7 KB)** | |

**Freed: 195,328 B, all of it `main`'s.** Heap for a small image goes from ~174,080 to **~369,408 B (360.75 KB)**.

**Per entity.**

| Item | Now | Proposed |
| --- | ---: | ---: |
| `main` (machine + auxiliary) | **196,608** | **1,280** |
| Supervisor: ACB 256 + machine + auxiliary + overhead ~158 | 256 + 8,192 + 2,048 + 158 = **10,654** | 256 + 1,536 + 512 + 158 = **2,462** |
| Actor: ACB 256 + machine + auxiliary + overhead ~158 | 256 + 8,192 + 2,048 + 158 = **10,654** | 256 + 2,048 + 512 + 158 = **2,974** |
| Child-table row, per child ever held | 88 | 88 |

**Margin.**

| Stack | Bound | Proposed | Margin |
| --- | ---: | ---: | --- |
| `main` machine | ~656 | 1,024 | 1.6× |
| `main` auxiliary | ~64 (est.) | 256 | 192 usable, 3–6× |
| Supervisor machine | 816 | 1,536 | 1.9× |
| Actor machine, pad at 512 | 800 fixed | 2,048 | 1,248 B for the behaviour |

Without item C the actor's fixed overhead is 1,856 B and 2 KB leaves under 200 B for user code; the
honest figure would be 4 KB and the actor row 4,822. The pad shrink is worth 1,056 B on every actor, which
is why it precedes sizing.

**As built (2026-10-08, item D).** The pad is gone (fixed overhead 256 B + the runtime reserve, ~450–560 B
per image, + the 64 B band). The constants above were not adopted: `main` is sized per image, and an actor or
supervisor at reserve 0 is sized per function from the image's stack table (a replying worker gets 1,024 +
256 B; an eight-child supervisor 5,632 + 320 B), with 8 KB + 2 KB only for a function the walk cannot bound.
The capacity ratio to quote is therefore per program: with 1 KB workers and a converted `main`, a small image
holds ~230 workers (ACB 256 + 1,024 + 256 + overhead ~158 + row 88 ≈ 1,782 B each in ~358 KB of heap), the
free-list caveats of §7.1 unchanged.

**Capacity: one root supervisor and N workers, nothing else on the heap.**

| | Now | Proposed |
| --- | ---: | ---: |
| Heap for a small image | 174,080 | 369,408 |
| Root supervisor | 10,654 | 2,462 |
| Per worker, with its child-table row | 10,742 | 3,062 |
| **Workers that fit** | **15** | **119** |

Ceilings: they assume no messages, lists, strings or records on the heap, and §7.1's free lists make the
count a peak-historical one. The ratio, **~8×**, is the result to quote.

## 11. Stacks allocated on dispatch, not at spawn (item F, board)

**Implementation status (2026-10-16).** This section is the 2026-09/10-07 analysis that led to item F; the
design as built differs from the pool described below. On 2026-10-08 Lee decided the board's actor and
supervisor stacks start small and grow with no limit, as on the hosted paths (spec §15.1.2.2), so there is no
fixed stack pool and no fixed board stack size: an actor with no stack is given chains of heap chunks when it is
dispatched, grows them at the emitted limit checks and releases them at the message boundary under its
`stack_policy` algorithm (§5 F, [esp32s3_xtensa_port.md](ports/esp32s3_xtensa_port.md) §8.3). §11.1's
specification question is settled by that decision; its items 2 (item B), 3 (the actor loop re-entered fresh at
every dispatch) and 5 (no zeroing per dispatch: fresh heap blocks are zeroed, reused chunks are not) were
carried out in that form. The numbers below are the projection that motivated F, kept for the arithmetic; the
measured result is in §13.

Everything in §10 still gives every actor a stack for its whole life. The alternative: an actor is spawned
with **no stack**, gets one when dispatched, and gives it back at the dispatch boundary when its behaviour
returns. The stack never moves — no growth, no relocation, none of the hosted design's MMU tricks — it is
simply not resident while the actor is idle. This is the bare-metal answer to the question
`actor_stack_growth_plan.md` defers. (Hosted gets the same effect from demand paging, §14.)

It replaces one "actors that fit" number with two independent quantities:

- **Resident cost per actor** — ACB 256 B, plus an 88 B child-table row for a supervised one = **344 B**.
  This bounds how many actors can *exist*.
- **Stack pool** — *K* stacks, *K* being the actors holding one at the same instant.

*K* is small because the scheduler is not preemptive: an actor runs a behaviour and yields at the dispatch
boundary. **K = NCORES_RUN (2) + the actors suspended mid-behaviour** — blocked in `call` awaiting a reply,
the one suspension with live user frames (model comment at the head of `rt_actors.S`). `wait_for_exit` and
an empty mailbox suspend at a boundary with nothing live.

**Totals**, same heap and scenario as §10, stack unit 2,048 + 512 + 158 = 2,718 B (pad at 512):

| Model | Stack pool | Resident per worker | **Workers that fit** | Heap left at 1,000 |
| --- | ---: | ---: | ---: | ---: |
| Fixed stacks, §10 | — | 3,062 | **119** | — |
| On demand, K = 2, ACB 256 | 5,436 | 344 | **1,057** | 19,716 |
| On demand, K = 8, ACB 256 | 21,744 | 344 | **1,009** | 3,408 |
| On demand, K = 16, ACB 256 | 43,488 | 344 | **946** | — |
| On demand, K = 2, ACB 128 | 5,436 | 216 | **1,684** | 147,844 |
| On demand, K = 8, ACB 128 | 21,744 | 216 | **1,608** | 131,536 |
| On demand, K = 16, ACB 128 | 43,488 | 216 | **1,508** | 109,792 |

Under this model the pad and the stack sizes stop being the lever — K = 8 with the pad at 1,568 costs
~48 workers, not 1,056 B each — and **the ACB's 256 B becomes the binding cost.**

**What the 1,000 target needs, read off that table.** Fixed stacks cannot reach it at any size: 119 is the
ceiling with every stack already at its bound. On-demand stacks with the ACB at 256 B *touch* 1,000 only as
a ceiling — at K = 8 there are 3,408 B left for every message node (48 B each), mailbox, state record and
string the program owns, so it is not a working configuration. **1,000 as a working number needs F and the
ACB halving (item I) together**, plus the registry resized (item J) if the children carry distinct ids:
at K = 8 that leaves ~131 KB for the program, and holds K up to 16 with ~110 KB. The program-side condition
is K itself — a `cast`/`send` design; a supervision tree that `call`s
down through its depth pins one stack per level and spends the pool.

### 11.1 What it needs

1. **A specification decision.** `actor_stack_growth_plan.md` quotes §15.1.2.2: nothing committed at
   spawn, no per-actor maximum, a reservation that cannot be made reported as
   `(:explicit, :stack_reserve_failed)` on the spawner. A fixed pool is a program-wide cap on concurrently
   running actors, and reserving pool *slots* at spawn (the way to keep the spawner-reports-failure
   contract) is a raw-only mechanism. Item 6 of the earlier draft insisted on "the same public API, not a
   raw-only variant"; the specification wins where they differ, so §15.1.2.2 has to say what a target
   without demand paging may do before this is built.
2. **Item B done.** Releasing a stack at the boundary recycles the behaviour's frame region immediately; a
   reply or state pointing into it is corrupted, not merely at risk.
3. **The release is done by the scheduler, after the switch.** At the boundary the actor is executing
   `silica_rt_actor_main` → `yield_to_sched` → `ctx_switch` on the stack to be freed. And `actor_main`'s loop
   is a frame on that stack, so the actor stops being a resumable coroutine and is re-entered fresh through
   `silica_rt_ctx_prepare` per message. The state already lives in `ACB_STATE`, and the first-entry flags
   (`ACB_TRAMP_RAN`) already distinguish first from subsequent entries, so re-entry fits the model — but it
   restructures the loop rather than tuning it.
4. **K validated against real programs.** `cast`/`send` message passing holds K near 2; deep synchronous
   `call` chains through a supervision tree push K toward N and recover the fixed-stack numbers. The board's
   intended concurrency style decides whether this step is worth its cost.
5. **A per-dispatch cost decision.** `silica_rt_alloc_stack` zeroes every block it hands out
   (`silica_rt_zero_block`), which is how `get_actor_memory_usage` finds the high-water mark. Zeroing 2 KB
   per message is real time at 240 MHz; a pre-zeroed pool of one size class makes allocate/release O(1)
   pointer swaps, and high water then needs another measurement. `get_actor_memory_usage`'s four fields
   (spec §22.4) also need defined meanings for an idle actor with no stack.

### 11.2 Staged counts toward the target

*Projection written 2026-10-07. F, I and J are built (2026-10-08, 2026-10-09); the measured 1,005-actor result is in §13 and §5 I.*

What each stage of §5 allows, from the numbers above: one root supervisor plus N actors and supervisors
(a supervisor costs the same as a worker at rest — ACB plus its child-table row — so the tree's shape does
not change the count), K ≤ 8 throughout.

| Stage | Items | What binds | Actors + supervisors |
| --- | --- | --- | ---: |
| Today | — | 10 KB fixed stacks; `main` holding 192 KB | **15** |
| Stacks right-sized | A–E | 2.5–3 KB fixed stacks in a ~369 KB heap | **119** (~74 without C) |
| Stacks on demand | + F | the registry: ~219 distinctly named children (item J); heap ceiling 1,009 with 3 KB left | **~219 named**, or a 1,009 ceiling that is not workable |
| Registry resized | + J | the ACB at 256 B | **~900** working (~40 KB left for program data); 1,009 ceiling |
| ACB halved | + I | program data | **1,000 with ~131 KB free**; 1,608 ceiling |

The jump from 119 to ~900 is all F, which is the step that restructures the actor loop and needs §11.1's
decision; everything before it is sizing and correctness, worth doing regardless, and tops out at 119. J
is cheap and independent (8 KB of tables and a loud failure) and need not wait for F — done with D, the F
plateau is ~900 at once; it binds only when children carry distinct ids. I is what turns 1,000 from a
ceiling into a working number. The ~369 KB heap in every row is the small-image figure; a program carrying
1,000 actors' worth of behaviour code takes more of the same SRAM, which is why item G keeps the last
column honest at scale.

## 12. Currently skipped for lack of memory (`trials/targets/ESP32-S3_raw.skip`, added 2026-09-28)

Six trials are capacity-bound on this board, confirmed against the numbers above, and are skipped rather
than failing:

| Trial | Needs | Have |
| --- | --- | --- |
| `memory_region_addition/region_chain_free_walked` | three 1.6 MB buffers (200000 int64) per region | ~170 KB heap |
| `memory_region_addition/region_move_conditional` | a 1.6 MB buffer | ~170 KB heap |
| `memory_region_addition/region_move_pass_and_return` | a 1.6 MB buffer | ~170 KB heap |
| `memory_region_addition/region_move_pass_no_return` | a 1.6 MB buffer | ~170 KB heap |
| `memory_region_addition/region_scope_loop_release` | a 1.6 MB buffer | ~170 KB heap |
| `compiler_addition/substring_utf8_cursor` | ~940 KB of never-freed intermediate strings | ~170 KB heap |

All six are shortfalls against real board capacity, not defects: `rt_heap.S` became a real first-fit,
coalescing allocator on 2026-09-28 (previously `free`/`region_destroy` were permanent no-ops), which is what
let `region_local_release` (a much smaller working set) start passing. This image uses no PSRAM, so the
ceiling does not move on its own; revisit only if the board's usable memory budget changes materially, or a
trial is rewritten to fit within it. None of them is reached by any stack change in this plan. The two
generic-collections trials of item H were skipped on the same ground; after D and G both pass and are no
longer in the list (2026-10-08).

## 13. Gate (board)

- A, B: §6. A on the board, 2026-10-09: `supervisor_end_frees_child_table` (ten cycles of a ten-worker
  supervisor ended through its root's `:terminate_child` and restarted by `:restart_child`, each worker
  ended by a division fault on a scalar call): heap growth 19,440 B over the ten cycles with the rows freed
  against 29,760 with them kept, golden under 25,000; `supervisors_addition` (106 of 117; the ten
  `wait_for_exit` programs without `cast_exit` left out) and `stack_budget_board_addition` pass with the
  runtime. Three follow-ups the same day: the miscompile the trial worked around,
  `supervisors_board_defects_addition/supervisor_ref_after_calls` (a `supervisor_ref` from
  `spawn_registered_supervisor` or a parameter was garbage in a `call_supervisor` after ten
  `call_registered` calls: a let nested in another let's RHS saw only its own tail as its body, so with
  every callee-saved register bound the liveness fallback reused a register live after the enclosing let;
  every let RHS now keeps the bound callee-saved registers, `_keep_cs`, in all four emitters, and the
  trial no longer rebinds the root); the fault that garbage raised was itself hidden because
  `silica_rt_actor_fault_hook`'s `9f` early-outs landed on `SCHED_LOCK`'s own local label (the hook spun
  on a garbage address and the nested path reported the hook's pc; the label is now 8, and an actor's
  fault raised while this core holds the lock, which the lock word now records as core id + 1, is
  reported as the original fault, status 70); and the two leaks measured here are freed, each
  `call_supervisor` reply by the caller's scope when it is done with it (spec §12.1.2, the ownership rule
  `let_owns_local_region` uses, extended to a let-bound fresh composite: record_make/tuple_make tails
  and `get_actor_memory_usage` records, freed right after binding when the body never names them, else
  from a frame slot of their own at scope end, never when the name is moved, stored, returned, rebound or
  projected to an inline aggregate) and the init child-spec list by the runtime once its rows are filled
  (`silica_rt_init_result_release`, guarded by `silica_rt_heap_reaches` from the supervisor's own state
  and every row's composite initial state). Growth over the ten cycles is 4,920 B (492 a cycle: the nine
  handles a ten-element list literal drops while it is built, and the child-info record a `:get_child`
  reply copies from), golden under 10,000.
- C: the pad's derivation is recorded at its `entry`, and `supervisors_addition` / `actors_addition` pass
  on the board with correct replies.
- D/E: `main`'s, supervisors' and actors' sizes are set from board-measured high-water marks with the
  margins in §10 or better; the §8.2 probe is decided and recorded; every trial either passes or is in
  `ESP32-S3_raw.skip` with a measured shortfall.
- F (built 2026-10-08, results on the board the same day, scratch copy of the trial tree with the
  `wait_for_exit`-without-`cast_exit` programs left out as in D's run): a behaviour recursing 2,000 deep
  grows its stack to 145,920 B (`actor_deep_recursion_grows`: 145,408 machine in chunks of 2, 4, 8 and
  16 KB plus 512 auxiliary) and completes where D's 8 KB block ended the actor, then `:keep_last_message`
  leaves it 2,560 B after a shallow message; a ten-child `init` (5.7 KB frame) runs on a 6.9 KB chunk of
  its own and the supervisor starts all ten (`supervisor_ten_child_init`); every release algorithm
  behaves as §15.1.2.2 says (`stack_release_algorithms`, `stack_release_when_idle`, the last one through
  the idle scan a second after the message); a lowered reservation reached on either stack ends the
  actor with tag 4 (`actor_machine_overflow_ends_actor`, `actor_aux_overflow_ends_actor`). At rest:
  1,005 actors (1,000 `:release_on_return` workers each dispatched once, the registries, a spawner and
  a probe) hold no stack and leave 32,960 B of the 354,816-byte heap (`thousand_actors_at_rest`:
  321,856 in use, of which the thousand 256-byte control blocks are 264 KB with their heap headers and
  the trial's own thousand usage records 40 KB). The 1,000 target is met; the ≥100 KB of room is not,
  and what binds is the control block (item I), as §11 derived; supervisors and named children stay
  bounded by the registry (item J) at ~219 names, so the thousand are plain actors (J, 2026-10-09, lifts that
  bound: one slot per atom). Suite counts: §5 F.
- F + I + J, the target: 1,000 actors and supervisors with distinct ids spawned, each registered and each
  dispatched at least once on the board, with ≥100 KB of heap still free (`get_actor_memory_usage` and the
  heap's free total), at K ≤ 8; a name-keyed lookup of the 1,000th resolves.
- H: `two_generic_collections_record_round_trip` and `two_generic_collections_round_trip` pass, or are
  skipped with a measured reason like the six in §12.

# Part III: Hosted environments (`apple_silicon_mac`, `linux_aarch64`, `linux_x86_64`)

Sources: [actor_stack_growth_plan.md](Phase1_TODOs/actor_stack_growth_plan.md),
[actor_growable_stack_design.md](actor_growable_stack_design.md), and
`emitter/<target>/terms/prims/prims_actors_runtime_asm.silica`, `prims_actors_stack_asm.silica` and
`prims_actors_child_table_asm.silica`, read 2026-10-07. Figures verified on `apple_silicon_mac`; where a
Linux runtime differs it is said. Anything not in the source or those documents is marked **not measured**.

## 14. The numbers today

Hosted memory is virtual and demand-paged: a reservation costs address space, not RAM, until touched. So
the per-actor cost splits into **resident** (RAM and kernel objects) and **virtual** (address space and
mappings).

| Item | Size | Source |
| --- | ---: | --- |
| ACB, `calloc`'d per spawn (at two spawn sites); 0–215 runtime, 216 supervision block pointer, 224 started, 232 reason tag, 240 active call, 248–264 FFI arena, 272–391 stack module, 392 holders, 400 parked exit notice, 408 identity, 416/424 spawner record, 432 calling convention, 440–480 carrier fields (item N stage 1, `apple_silicon_mac` only: carrier, status, run-queue link, parked SP, spawn waiter, wait list), 496/504 the thread record (item N stage 2: an actor thread's current actor and 0 = not a carrier's thread) (item I, 2026-10-09: 392 B, 512 before; 448 B since the identity and holder words of 2026-10-12; 496 B on the Mac since 2026-10-19 (stage 1 + the restart protocol), 512 B since stage 2) | 512 B (Mac); 448 B (Linux) | `prims_actors_runtime_asm.silica` `mov w1, #512`; `mov esi, 448` on x86-64 |
| Supervision block, `calloc`'d for a supervisor (spawn with a trampoline) or on the first exit notice an actor receives: ingress front 0, rear 8, depth 16, child-table head 24, len 32, sync_failure_reported 40, trampoline 48, strategy 56, allowed 64, time frame 72, restarts 80, window 88, children counted in a replacement wait 96, tearing down 104, references 112; freed by its last reference (`sb_unref`) | 120 B | `silica_rt_sb_require` |
| Identity table: one entry per actor that has not finished ending (identity → ACB), open addressing, plus the spawner records | not measured | `actor_rt_identity_chunk`, `prims_actors_runtime_asm.silica` |
| ACB stack-module fields: base 272, reserve 280, committed 288, high water 296, next chunk 304, algorithm 312, retained 320, 32-entry usage ring 328, ring index 336, last message time 344, alt stack 352, policy 360, saved SP 368, lowered 376, exit reason 384 | within the 448 B | `prims_actors_stack_asm.silica` header |
| Stack reservation, virtual, one per actor | default: physical memory + swap, page-rounded (fallback 16 GiB if the sysctl read fails, Apple Silicon); `stack_policy(reserve, …)` lowers it | `_silica_rt_stack_runtime_init`; spec §15.1.2.2 |
| Stack committed at spawn | 0 | growth plan |
| First growth chunk | one platform page: 16 KB on Apple Silicon and Pi 5, 4 KB on most other Linux; then doubling per fault to 1 MB, then 1 MB per fault | design doc "Runtime constants" |
| Lowest page of every reservation | never committed (exhaustion detector) | growth plan, status |
| Release | anonymous `MAP_FIXED` remap to `PROT_NONE` at the message boundary, down to what the algorithm retains (five algorithms) | `prims_actors_stack_asm.silica` |
| Per-actor OS thread (the runtime is one thread per actor) | pthread stack 128 KB (`pthread_attr_setstacksize`, `0x20000`), carrying the mailbox loop; behaviours run on the reservation (SP switched around each `blr`) | `prims_actors_runtime_asm.silica`; growth plan |
| Per-thread signal alt stack | 64 KB `mmap` (virtual), freed with a full release | `prims_actors_stack_asm.silica` |
| Implicit heap (arena) per actor | a chain of 64 MB anonymous RW blocks mapped on first allocation; an idle actor holds none; freed together when the actor ends | `_silica_rt_region_alloc`, `_silica_rt_actor_dealloc_region` |
| Mappings per actor, stack | 2 (committed run, inaccessible remainder), plus the thread stack, the alt stack and any arena blocks | growth plan; counts beyond the 2 **not measured** |
| Child-table row, one per child held, `calloc`'d, freed on supervisor end (88 B before the row recorded its child's identity and spawner record) | 120 B | `prims_actors_child_table_asm.silica` `mov w1, #120` |
| Message node | 152 B (heap) | `prims_actors_runtime_asm.silica` header comment |
| PID registry actor state, one each for the pid, dangerous and device registries (item J: sized from the image's atom count, `silica_registry_slots` slots × 16 B; 3,840 B, `occ[240]` + actor_refs, before) | per image | `_silica_rt_pid_registry_beh` |
| Resident RAM per idle actor (ACB, kernel thread, touched thread stack and TLS, first committed page) | **not measured** | |
| Kernel thread cost per actor | **not measured** | |

**Derived, not measured.** At 448 B the ACBs of a million actors are 448 MB (plus 120 B per supervised child).
A million 64 MB arena blocks, were every actor to allocate once, would be 64 TB of address space; the default
reservation at, say, 16 GB of memory plus swap would be 16 PB for a million actors, which no 47- or 48-bit
address space holds. So a program with many actors must lower every reservation, as the design document's
example does (`stack_policy(33554432, :release_on_return)`, 32 MB, which is 32 TB at a million). The address
width of the hosts is **not measured here**.

**Recycling.** ACBs, rows and message nodes are `calloc`'d and `free`'d individually, and a dying actor
unmaps its stack and its alt stack and returns its arena blocks (`_silica_rt_actor_fail_current` frees the
stack before it wakes any waiter). There is no peak-historical floor of the board's kind and no
exact-size-match list.

**Composite state.** See §3, hosted note: not determined.

**Registry.** The registry is an actor, and each operation allocates a 24 B and a 16 B reply block with
`calloc`. Since item J (2026-10-09) each of the three tables has one slot per atom of the image
(`silica_registry_slots`), an insert of a name a live actor holds replies `:name_taken` and stores nothing,
and the keyed forms tell an atom from a pointer by the same per-image count (§5 J for the addresses checked).

## 15. What bounds the count

None of these is the amount of RAM taken by stacks, which demand paging and release have removed as the
first limit. In the order they would be met:

1. **One OS thread per actor.** The host's thread limit is the bound, not the stacks. The growth plan says so
   in terms: "a million idle actors cannot be reached with one OS thread per actor", and the gate trial
   (`trials/actor_stacks_addition/stack_many_idle_actors_hold_nothing`) spawns **a thousand** with lowered
   reservations and checks that every one holds zero committed stack. The thread limit of the hosts is **not
   measured**; a thousand is the highest count verified. Chunk 2 of the ROADMAP replaces this with one
   carrier thread per logical core and many actors per carrier, switching cooperatively at yield points
   (the BEAM pattern); until then the hosted gate "a million idle actors holding no stack memory" is open.
2. **Mappings.** Two per actor for the reservation alone, plus the thread's own stack and the alt stack.
   The growth plan records `vm.max_map_count` at about one million on the Pi image and 65,530 on stock
   Linux kernels, so two mappings per actor reaches the limit at half of those counts: about 32,000 actors
   on a stock Linux kernel from the reservation mappings alone, fewer with the other mappings. Whether the
   runtime documents or checks the limit at start is still undecided ("Still to decide" in the growth plan).
   macOS has no such limit that was measured here. The mappings per actor under carriers are **not measured**.
3. **Address space** of the reservations and the arena (§14, derived): bounded only by lowering the default
   reservation per actor; a program with millions of actors must pass a small `stack_policy` reserve to every
   spawn, and child-spec children inherit their supervisor's.
4. **The registry** (item J, done 2026-10-09): one slot per atom of the image in each of three tables, and a
   loud refusal of a duplicate; it no longer bounds the count of named children (a program has as many names
   as it has atoms).
5. **The ACB** (item I, 392 B since 2026-10-09; 448 B since 2026-10-12; 512 before): `calloc`'d, resident. Not the first limit, but at a million actors it is
   close to half a gigabyte before a single message exists.
6. **Process-level stack growth** is not a limit: the fault handler commits one chunk at a time under every
   release algorithm and the default reservation exceeds what the machine can commit.

## 16. Path to millions

Counts are only given where verified; every other cell is **not measured**.

| Stage | What changes | What binds | Actors |
| --- | --- | --- | ---: |
| Today (chunk 1, 2026-09-18) | Reservation, fault-driven growth, five release algorithms; thread per actor | the host's thread limit; mappings; 240-slot registry for named children | **1,000** verified (the gate trial); beyond that not measured |
| Registry resized (J) | per-image table size, loud failure | thread limit | no change to the count of unnamed actors; named children no longer capped at ~219 |
| Carriers (ROADMAP chunk 2, hosted part) | one carrier thread per logical core, many actors per carrier; no thread stack or alt stack per actor | mappings, address space, ACB | not measured |
| Lower reservations by default for many-actor programs | spawn names a small `stack_policy` reserve; the mapping count falls to what one actor needs | ACB and message memory | not measured |
| ACB split (I, done 2026-10-09) | supervision fields moved to a side block only supervisors get (96 B then, 120 B now); a worker's ACB was 392 B and is 448 B since the identity words | message and program data | not measured |

What stands between today and millions, in order: the carriers (the thread per actor), the mapping count
and address space per actor once there are no threads, the registry, and the ACB. The stack mechanism itself
is already in the form millions needs: nothing committed at spawn and release at the message boundary.

## 17. Hosted status per work item

Checked from the hosted runtime source on 2026-10-07 and again on 2026-10-16 (sizes and K, L, M, N); none of the hosted trials were re-run for this plan.

| Item | Status | Basis |
| --- | --- | --- |
| A | done | `_silica_rt_child_table_free` walks the chain and `free`s each row, 120 B since 2026-10-12 (`prims_actors_child_table_asm.silica`) |
| B | not determined | raw word stores at spawn and for the behaviour result; aggregate-return promotion excludes actor behaviours (§3); the item B trials have not been run on hosted |
| C | does not apply | no pad; behaviours run on the reservation |
| D | does not apply in the board form | reserve and release policy come from `stack_policy`; children inherit the spawner's policy (the child-spec record has no policy field in the specification); `main` runs on the platform stack |
| E | retired 2026-10-08 | stacks grow and are released by policy, so there is nothing to size; `get_actor_memory_usage` (reserved, committed, retained, high-water) stays available for the gate |
| F | done in the hosted form | nothing committed at spawn; release at the message boundary; five algorithms; `trials/actor_stacks_addition` (13 trials) and `error_enforcement_addition/stack_policy_*` |
| G | does not apply | |
| H | does not apply | |
| I | done 2026-10-09 | ACB 392 B then, 448 B since 2026-10-12; supervision block 96 B then, 120 B now, only for supervisors (`silica_rt_sb_require`), all three hosted runtimes (§5 I) |
| K | done | `cast_exit` / `wait_for_exit` in the hosted runtimes; trial-verified 2026-10-08 (§5 K) |
| L | done | `compiler/src/main.silica` (§5 L) |
| M | done | `trials/lib_trial_support`, `programmer_tools/trial_shape_m` (§5 M) |
| N | stage 4 built 2026-10-19, `apple_silicon_mac` only, gated off by default (`SILICA_CARRIERS=1`; `SILICA_CARRIER_COUNT=<n>` overrides the core count) | one carrier thread per logical core for plain workers, bound at spawn (`core mod N`, else in turn), per-carrier idle sweep; placement (`migrate_actor`, the `pin_actor_*` family) real on carriers; the four dispatch-order policies and the three priority levels real per carrier; supervisors, dangerous and registry actors keep threads; §5 N "Stage 2", "Stage 3" and "Stage 4 status" |
| J | done 2026-10-09 | per-image `silica_registry_slots` (one per atom) sizes the three registries and the keyed-form discriminator; duplicates refused per §20.3.1; names removed at teardown (§5 J) |

## 18. Gate (hosted)

- A, B: §6. A is already satisfied by the source; B needs the two trials run on each hosted path.
- The existing chunk-1 gate stays: deep recursion past 8 MB in an actor, shrink after a message under each
  algorithm, a lowered reservation reporting `(:explicit, :stack_exhausted)`, `:stack_reserve_failed` on an
  actor and a reported exit from `main`, and a foreign call from deep inside a grown stack.
- J: a registration beyond the table fails loudly; a name-keyed lookup of the last registered child resolves.
- The target, millions: not gated until carriers exist. Then, in stages with each count measured on the host
  before it is claimed (a thousand today, then ten thousand, a hundred thousand, a million): every actor
  spawned with a lowered reservation, dispatched at least once, holding zero committed stack while idle, with
  resident memory per actor recorded (`get_actor_memory_usage` and the process's RSS), and the mapping count
  against `vm.max_map_count` recorded on Linux.
