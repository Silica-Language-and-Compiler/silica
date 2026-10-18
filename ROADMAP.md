# Roadmap

Development is organised by **emitter path**. Each path is a backend under
[compiler/src/emitter/](compiler/src/emitter/), and each path advances through numbered **milestones**. What a
milestone is depends on whether the path's machine can run a compiler at all.

- **Hosted paths reach fixed points.** A fixed point is a build of the self-hosted compiler that passes the whole
  [trial tree](trials/) when built by itself (gen2) and reproduces itself byte for byte (gen3 = gen2; see
  [Build and test](README.md#building-the-compiler)).
- **Raw paths reach board releases.** A raw target has no operating system and cannot host a compiler, so it can never
  build itself and has no fixed point. Its compiler is a cross compiler built on a hosted machine, and its milestone is
  a **board release**: every trial suite green on the board, run from that cross compiler's output.

Between milestones the not-yet-implemented parts of the
[specification](compiler/design_documents/silica-specification.md) are delivered in **chunks**;
a chunk is closed by a new milestone, never by a build that merely compiles. Dates are deliberately absent.

## The four paths

| Path | Emitter | Rule |
| --- | --- | --- |
| Apple Silicon (macOS, AArch64) | `emitter/apple_silicon_mac/` | Leads. The code as it is today is the content of its first fixed point (FP1). |
| Linux AArch64 | `emitter/linux_aarch64/` | **Lock-step** with Apple Silicon: fixed point *n* on Linux contains exactly the Silica behaviours of fixed point *n* on Apple Silicon. Apple leads inside a chunk; the chunk is not closed until Linux has caught up and both fixed points are re-established. Port notes: [linux_aarch64_port_checklist.md](compiler/design_documents/ports/linux_aarch64_port_checklist.md). |
| Linux x86-64 (AMD64, hosted) | `emitter/linux_x86_64/` | **Lock-step** with Linux AArch64, which it was copied from: the same Silica behaviours at each fixed point. It builds natively on its own machine (Ubuntu on x86-64, `nix`), has its own `.linux_x86_64.ascomp` goldens, and keeps its own fixed point; its first was reached 2026-09-19 and the build of 2026-10-16 reproduced it (355 units, gen3 byte-identical to gen2). Plan and status: [porting_to_linux_x86_64_hosted.md](compiler/design_documents/porting_to_linux_x86_64_hosted.md). |
| ESP32-S3 (Xtensa LX7, OS-free) | `emitter/ESP32-S3_raw/` | **Not** in lock-step, and it has no fixed point: the board cannot host a compiler, so its milestone is a board release (above). Its first board release has all the behaviours of Apple Silicon FP1 **plus peek and poke** (device memory access, below). It then works through the same chunks at its own pace, skipping hosted-only items. Port notes: [esp32s3_xtensa_port.md](compiler/design_documents/ports/esp32s3_xtensa_port.md), [porting_for_os_free_targets.md](compiler/design_documents/porting_for_os_free_targets.md). |

**Peek and poke (first delivered in the ESP32-S3's first board release).** Every device has a programmer-supplied **device description**, an
implementation of the built-in `DeviceDescription` trait that lists its registers with offsets, widths, and access modes.
`map_device(device, base) -> device_window(R, D)` binds that device's registers at a board-legal address (a bind, not an
allocation); `peek(window, :register)` and `poke(window, :register, value)` are the volatile device load and store, dedicated
prims that name registers rather than offsets, with the width stated at every access by a required `Register8`…`Register64`
marker and checked against the description. Only a `spawn_device` worker in a `device_*` module may call them, and
`register_rwr` ordering follows the port table. The lexer through the SIR generator are the same on every path, so
the prims are part of every path's compiler: ESP32-S3 implements them in its emitter, and each hosted emitter rejects them with
a compile error naming the module, function, and prim. That rejection needs a diagnostic channel from the emitter, which it
does not have today. When ESP32-S3 reaches its first board release, Apple Silicon and Linux AArch64 take the same shared change and the
rejection and re-establish their fixed points; nothing they already run changes.
Details: [silica_device_actor_specification.md §4.7–§4.9, §10](compiler/design_documents/silica_device_actor_specification.md) and
[porting_for_os_free_targets.md §5](compiler/design_documents/porting_for_os_free_targets.md).

## Actor placement in chunk 2; raw chip features in chunk 14

**Chunk 2 is actor placement, pinning and cooperative multitasking, and it is on every path**, right after the actor
stacks and data structures. On hosted paths it follows the BEAM pattern, and it may pull forward whatever part of
chunk 11's scheduler it needs.
The program surface is the same everywhere, and it is the one the compiler implements today (type checker, SIR and
all four emitters):

- `spawn(initial_state, behaviour, stack_policy(...))` takes an optional last argument naming the core: a `uint64`
  logical core id or `core_id(n)` (§4.6, §15.1.1); `spawn_registered` and the supervisor spawns take it in the same
  position. The `core_set` and list placement forms are not accepted.
- `migrate_actor(ref, core) -> :ok | :invalid_target | :actor_not_found | :migration_blocked` (§15.1.2, §22.10); the
  older `move(ref, from, to)` builtin was removed on 2026-10-16 (an unknown function, E2007).
- `pin_actor_to_core(ref, core)`, `pin_actor_to_performance_core(ref)`, `pin_actor_to_efficiency_core(ref)`,
  `pin_actor_realtime(ref)`, `pin_actor_to_numa_node(ref, node)`, `unpin_actor(ref)` (§22.10).
- `set_actor_priority(ref, :high | :normal | :low)` and
  `set_scheduler_policy(:priority_fifo | :round_robin | :weighted_fair | :lottery) -> :ok | :invalid_policy`
  ([tutorial](compiler/tutorials_and_howtos/actor_scheduler_policy_tutorial.md)).
- `get_cpu_topology()` with the `cpu_topology` / `core_info` records, `get_core_capabilities(id)`,
  `get_performance_cores()`, `get_efficiency_cores()` (§22.10).

What "pinned" means differs by target, exactly as the specification already says (§15.1.2 Actor Pinning Policy,
§23.1.3):

| Path | What pinning means there |
| --- | --- |
| **OS-hosted** | The actor is bound to a **thread**: the runtime's carrier thread for that logical core, one carrier per core with many actors on it, switching cooperatively at yield points. The runtime never moves an actor to another carrier on its own. The runtime asks the OS for affinity for that thread where the OS allows it, but the OS still owns the cores, and Apple Silicon macOS offers no hard thread-to-core binding, so exclusive placement is **not** guaranteed. `migrate_actor` moves the actor between carrier threads, the way the BEAM moves processes between its scheduler threads. Today an actor is its own operating-system thread; this chunk replaces that with the carriers, which is what lets one machine hold millions of actors. |
| **Raw (OS-free)** | The actor is bound to a **core**: the runtime pins it to the named core, exclusively and for its whole life, unless the program moves it or it terminates, and reports the real topology. **Delivered on the ESP32-S3 (2026-09-28/29, [esp32s3_xtensa_port.md](compiler/design_documents/ports/esp32s3_xtensa_port.md) §8.5, §8.9, §8.10):** every actor is pinned from `spawn` (its core argument, else round robin over the running cores), one cooperative scheduler per core dispatches only that core's actors, nothing is preempted; `migrate_actor` moves the pin at the actor's next dispatch boundary (at once when it is parked) and its mailbox goes with it; `pin_actor_to_core` is a move, `pin_actor_to_performance_core` moves to core 0, the two LX7 cores are alike so `get_efficiency_cores()` is empty and `pin_actor_to_efficiency_core` is a no-op; `get_cpu_topology()` reports the two cores (capabilities empty, frequency 0, no NUMA or cache levels); the four dispatch-order policies and the three priority tiers are real. Trials: `actor_cross_core_call_reply`, `actor_cross_core_cast_stress`, `actor_migrate_and_move`, `migrate_actor_expression_core`, and the `scheduler_policy_addition` suite. Open: ending an actor that is running on the other core waits for its next dispatch boundary. |

**Chunk 14 is the rest of the chip's capabilities, and it is raw paths only**, wherever the chip has them; a feature the
chip lacks is recorded in the port notes as not applicable rather than left open. Hosted paths are different by
specification: on an OS the memory spaces are a discipline without guaranteed attribute differentiation (§12.1.1.0).
Apple Silicon's side of the placement work is already planned in
[cpu_topology_implementation_plan.md](compiler/design_documents/Phase1_TODOs/cpu_topology_implementation_plan.md).

| Feature (spec wording) | Where | What the raw path delivers |
| --- | --- | --- |
| **Memory spaces.** `region(L, Space)` with `normal`, `normal_writeback`, `normal_writethrough`, `normal_noncacheable`, `atomic`, and `device` (§4.4); OS-free runtimes give each space its real attributes, on AArch64 through `MAIR_EL1` (§12.1.1.0, §12.1.1.1). | §4.4, §12.1.1 | Every space the chip can distinguish maps to the matching cache policy, shareability, or device attribute; `device` is the peek-and-poke window. Spaces the chip cannot distinguish are documented as collapsed. |
| **Chip-specific behaviours.** Feature detection and capability queries (§21.0), then whatever the chip has: on AArch64 SVE (§21.1), NEON (§21.2), MTE (§21.3), PAC (§21.4) and the system-register access of §21.0.2; on ESP32-S3 the Xtensa LX7 equivalents (its vector and cache-control instructions) and none of the AArch64-only items. | §21 | Each raw path carries the §21 items its chip supports, with trials, and lists the rest as not applicable. |

## First milestone (each path)

- **Apple Silicon FP1** — the current behaviour set: every trial suite green under the selfhost built by the selfhost, and `make fixpoint` passing. Progress and open items: [self-host plan](compiler/design_documents/Phase1_TODOs/bootstrap_retirement_and_self_host_plan.md) (its opening status section records that self-hosting is reached and the bootstrap retired; the body below it is the 2026-09-08 plan, kept as history), [open defects](compiler/design_documents/HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md). Reaching it retired the Rust bootstrap for this path: nothing in the build path is Rust any more.
- **Linux AArch64 FP1** — the same behaviours, same trials, on Linux.
- **Linux x86-64 FP1** — the Linux AArch64 behaviours, same trials, on x86-64. Reached 2026-09-19 (`nix`); fixed points on this path were re-established on 2026-10-07 and again on 2026-10-16 (build log `remote-linux_x86_64.log` of the 2026-10-16 build; the 2026-10-16 binary is not yet published into `binaries/`, the newest published one there is from 2026-10-07).
- **ESP32-S3 board release 1** — the same behaviours plus peek and poke (and, on Apple Silicon and Linux AArch64, a new fixed point that rejects them; see above), with the hosted-only pieces (console and file `device_io` syscalls, sysctl CPU topology, Fifi against OS libraries) replaced by their board-pack equivalents. It is a board release, not a fixed point: the cross compiler is built on a hosted machine and the board runs its output.

## The chunks after the first milestone: enhancement requests

The chunks are **enhancement requests, not an ordered list**. Their numbers are identifiers, not a sequence or a
priority: any of them can be taken up when a contributor, a dependency, or demand calls for it, and several can be in
progress at once. Two placements were decided explicitly and still hold: chunk 1 comes immediately after the first
milestone on every path, and chunk 2 (actor placement and pinning) follows it on every path.

However a chunk is picked up, it is done on Apple Silicon first, then Linux (lock-step), and picked up by ESP32-S3
when that path gets to it; each ends in a new milestone for the path, a fixed point on a hosted path and a board
release on a raw one. Milestones are numbered in the order they are actually reached, so a chunk has no number until
it lands.

| # | Chunk | Spec / design | What closes it |
| --- | --- | --- | --- |
| 1 | **Growable and shrinkable actor stacks, and the remaining standard data structures.** Runtime-managed stacks as the specification now defines them (§15.1.2.2, revised 2026-09-17): one inaccessible reservation per actor defaulting to the machine's memory plus swap and lowerable per spawn, nothing committed at spawn, growth in the fault handler in chunks that double from one platform page to 1 MB, release at the message boundary under one of five named algorithms (`:release_on_return`, `:keep_last_message`, `:track_recent_peak`, `:release_when_idle`, `:keep_high_water`) chosen by the `stack_policy` argument every spawn now requires, no per-actor maximum and no cap, `main` not an actor. The segmented design this row once described is withdrawn. Alongside them, the remaining public data-structure traits and query backends (CSR and dense graph indexes, `BinaryTree`). | spec §15.1.2.2, §15.4.11.2, §22.4; [actor_growable_stack_design.md](compiler/design_documents/actor_growable_stack_design.md) §2, §4, §7; [actor_stack_growth_plan.md](compiler/design_documents/Phase1_TODOs/actor_stack_growth_plan.md); [data_structure_designs](compiler/design_documents/Phase1_TODOs/data_structure_designs/README.md) | Deep recursion inside actors bounded only by machine memory, stacks that shrink after each message, idle actors holding no stack memory, and the compiler running as an actor, with trials; all ten traits with goldens under `ordered_data_structures`. **Status 2026-10-16: delivered on the hosted paths** (reservation, chunked commit, five release algorithms, `stack_policy` on every spawn, `main` not an actor; specification §15.1.2.2) and **on the ESP32-S3 in its own form** (heap-chunk chains with the same five algorithms, a 1,000-actor trial; [actor_memory_budget_plan.md](compiler/design_documents/actor_memory_budget_plan.md) item F). The data-structure designs are implemented in `compiler/stdlib/data_structures/` and covered by `trials/ordered_data_structures/`, with the exceptions listed in [data_structure_designs/README.md](compiler/design_documents/Phase1_TODOs/data_structure_designs/README.md). The compiler's own `main` is the small shape (start the supervisor, `wait_for_exit()` last; budget plan item L) and ends the program with `cast_exit`. |
| 2 | **Actor placement, pinning, and cooperative multitasking.** The surface as built: `spawn(..., stack_policy(...), core)` with a `uint64` core id or `core_id(n)`; `migrate_actor(ref, core)`; the `pin_actor_to_core` / `_to_performance_core` / `_to_efficiency_core` / `_realtime` / `_to_numa_node` and `unpin_actor` family; `set_actor_priority` and `set_scheduler_policy` with its four policies; `get_cpu_topology()`, `get_core_capabilities(id)`, `get_performance_cores()`, `get_efficiency_cores()` — identical on every path, listed under "Actor placement in chunk 2" above. **ESP32-S3: delivered** (per-core cooperative schedulers, exclusive pinning from `spawn`, migration at the dispatch boundary, the policies and priorities). **Hosted paths: the calls exist but the carrier model does not** — an actor is still its own operating-system thread, `get_cpu_topology()` comes from `sysctl`, pinning is a thread-affinity hint, `set_scheduler_policy` is accepted and answers `:ok` without effect. What remains of the chunk is the **BEAM pattern** there: one carrier thread per logical core, many actors per carrier, cooperative switching at yield points (a behaviour's return, or a wait such as a call awaiting its reply), an actor bound to its core's carrier and `migrate_actor` moving it between carriers; whatever of chunk 11's scheduler this needs is **moved forward into this chunk**. | §4.5.2, §4.6, §15.1.2, §22.10, §23.1.1, §23.1.3 | An actor spawned for a core runs there and stays there for its life unless the program moves it, as far as the target can guarantee it; `get_cpu_topology()` reports the real machine; `migrate_actor` moves a running actor; a hosted machine holds millions of actors, with no thread per actor and no starvation under load, which is the claim chunk 1 deliberately does not make; all with trials on every path. The ESP32-S3 meets its part of this gate today; the hosted gate is open until the carriers exist. **Status 2026-10-16:** hosted carriers not started ([actor_memory_budget_plan.md](compiler/design_documents/actor_memory_budget_plan.md) item N); until they land a hosted actor is one operating-system thread, which bounds how many a hosted machine can hold (specification §15.1.2.2 implementation status). |
| 3 | **Immutable lists: map, filter, reduce** with region-backed chunked storage and Collectable elements. | [list_implementation_design.md](compiler/design_documents/list_implementation_design.md), [TODO M1–M3](compiler/design_documents/Phase1_TODOs/list_map_filter_reduce_and_hardening_todo.md) | M1–M3 delivered with trials. |
| 4 | **Region memory safety.** Static region-lifetime analysis, buffer bounds checking, region isolation, an ownership-based release strategy that ends use-after-free, atomic references, lifetime polymorphism. It also closes the **aggregate move rule**: §4.4.2 makes a region handle move-only and extends the discipline to records and tuples that embed one, but the compiler checks only the narrowest case, a parameter whose own declared type is a region, not returned and not passed on. A region carried in a record field moves nothing, so the rule is unenforced for every real data structure. Enforcing it makes those aggregates linear: a function that receives one and keeps using it must return it and the caller must rebind. **Scope of that part, measured 2026-09-25:** 30 standard-library modules and 1,152 records with a region field, including wbt_map (413), wbt_set (316), tree_binary (87), tree_rose (71) and the skew_ral, brodal_okasaki and graph families; all ten public data-structure traits are built on them, and the compiler's own sources use those traits. Design: [region_memory_safety_design.md](compiler/design_documents/region_memory_safety_design.md). | [region_memory_safety_design.md](compiler/design_documents/region_memory_safety_design.md); [region_memory_safety_todo.md](compiler/design_documents/Phase1_TODOs/region_memory_safety_todo.md); spec §12, §30, §4.4.2, §7.4 | The §12 safety properties enforced at compile time or halted at run time, never silent, and the linearity rule holding for a region in a record or tuple as it does for a bare one, with trials for the misuse it is meant to catch; the standard library and the compiler build and reach their fixed points under it. |
| 5 | **Variants and advanced control.** Variant types and variant patterns, behaviour switching by returning a different behaviour, advanced effects. | spec §4.2.5, §6.1.2, §6.3, §15 | Trials per construct. |
| 6 | **Atomic operations and synchronization guarantees** audited against the spec and completed. | spec §17, §18 | Every listed operation has a trial and a documented ordering. |
| 7 | **Extended numerics.** Big integers, big floats, rationals, big rationals, and 128-bit integers, all as distinct explicit types with no implicit widening. | spec §30; Phase 3 in the previous roadmap | Each numeric type has literals, arithmetic, comparison, conversion rules, and printing, with trials; no implicit widening anywhere. |
| 8 | **Tooling and proof.** Formal-verification tooling, language-level cryptographic guardrails, IDE and developer-experience surface, tighter emission. | spec §29; [formal verification](compiler/design_documents/silica-formal-verification-specification.md), [crypto proposal](compiler/design_documents/crypto-proposal-introduction.md) | Each tool or guardrail lands with its own trials or diagnostics. |
| 9 | **Networking through Fifi.** Networking is not part of the language (spec §20.4): a program reaches the host's sockets, TCP and UDP through the Foreign Function Interface (§26.3) like any other foreign library, inside guarded regions in dangerous actors. This chunk provides the Fifi wrapper library for the host socket interface and the trials for it on the hosted paths; no TCP/IP stack is written. **Prerequisites:** chunk 1 (one actor per connection needs growable stacks) and the buffer bounds checking from chunk 4 (every received byte is untrusted input). | spec §20.4, §26.3, §15.4.13 | Loopback echo-server, client and many-connection trials through the wrappers on the hosted paths; malformed-packet trials that fail safely. |
| 10 | **Actor identity and lifecycle.** The 64-bit actor identity (a 32-bit spawner position and a 32-bit child number) with equality and order on every actor reference type, positions stable across restarts and numbering that continues across them; `self()` and `actor_id`. Ending actors: `stop_self`, `fail_self`, `kill_abnormal`, orderly shutdown by a supervisor, and removal of `:temporary` rows. Supervisor `:terminate_actor` and `:set_report_sink`, with exit reports cast to the report sink. The atom-keyed registry (`register`, `whereis`, `unregister`, removal when an actor ends, names carried across restarts). The run-time calling-convention check for references whose convention the compiler cannot see. | spec §4.5.1, §7.4, §15.1.2.3, §15.1.4, §15.4.8.3, §15.4.10.5, §15.4.11.2, §15.4.12, §15.4.13.4, §16.2.6.4, §20.3.1 | A stale reference never equals a live actor, and sending to one never reads freed memory; every ending path gives its documented `failure_reason`; a restarted named child is reachable by name under a new identity; report sinks see every exit in ingress order; all with trials. **Status 2026-10-16: partly delivered.** Done, with trials: the 64-bit actor identity with equality, order and dead-reference behaviour (spawner positions are numbered at run time, build-time numbering is still design); `actor_not_found` for sends to ended or unheld names, including `cast_registered`; the run-time calling-convention check and the compile-time cast/call convention checks (E2237, E2238); cascading shutdown (a supervisor stops its live children, last row first, before it ends, and `:temporary` rows are removed); the failure-reporter start-order check (E2236); `register_failure_reporter`. Open: `stop_self`, `fail_self` and `panic`; supervisor `:terminate_actor` and `:set_report_sink`; `register`, `whereis` and `unregister` (names bind only at spawn); enforcement of the `shutdown` time limit; rejection of `remove_actor(self())` at compile time. |
| 11 | **Time, and the scheduling chunk 2 did not take.** The monotonic and wall clocks, `send_after`, `cancel_timer` and `timer_ref`, and `call_with_timeout`. `priority_level` hints and the fairness work beyond what the carriers already do, and the raw paths' per-core schedulers. The hosted carrier model itself is chunk 2: whatever of this chunk that needed came forward with it, so what is left here is time and refinement. | spec §15.1.2 (Actor Pinning Policy), §16.1.1.2, §22.10, §22.14, §23.1.1 | **Status 2026-10-16: not started** (`call_with_timeout`, `send_after`, `cancel_timer` and the clocks do not exist). Timers fire no earlier than asked and never after cancellation; a timed-out call's late reply is discarded; priority hints change scheduling order without starving anyone; raw paths run many actors per core; with trials. |
| 12 | **State-machine actors.** The `StateMachine` trait, `spawn_state_machine` and `state_machine_behavior`: named states, inserted events, postponement, and state, event and generic timeouts. **Prerequisite:** the timers of chunk 11. | spec §15.5; [actor capabilities](compiler/design_documents/silica_actor_capabilities_specification.md) §9.2 | Trials for event order (inserted, then postponed after a state change, then mailbox), each timeout kind and its cancellation, and a supervised state machine restarting from `init`. |
| 13 | **Foreign data: byte buffers and re-creation.** `buf(L, Space, uint8, N)` across the Fifi boundary, and the `Recreatable` trait: the compiler-derived `recreate` that checks declared limits and rebuilds a tainted value in a region the caller owns, so it may leave the handler that received it. Libraries that root their own `dangerous_` exposure source. On raw paths, Fifi through the board pack's C runtime. **Prerequisite:** the buffer bounds checking of chunk 4. | [FFI wrapper spec](compiler/design_documents/silica_ffi_wrapper_specification.md) §6, §7.7, §14; [porting_for_os_free_targets.md](compiler/design_documents/porting_for_os_free_targets.md) §9.1 | Byte buffers round-trip through a foreign call; every rejection atom of §7.7 has a trial; re-created values pass the taint checks that raw foreign values fail. |
| 14 | **Raw paths: chip features.** The memory spaces with their real attributes and the chip's §21 behaviours, as listed under "raw chip features in chunk 14" above. Raw paths only: on hosted paths the memory spaces are a discipline without guaranteed attribute differentiation (§12.1.1.0). **Prerequisite:** peek and poke, which define the `device` space. | §4.4, §12.1.1, §21 | Each raw path's port notes list every item as delivered with trials or as not applicable. |


## Later paths

A new emitter's first milestone has the same behaviours as the **analogous pre-existing milestone**, not
Apple Silicon's: a hosted Linux path starts from Linux AArch64 (Linux x86-64 did exactly this and is now one of the four paths above), and a bare-metal path starts from the nearest bare-metal one (bare-metal AArch64
takes the current ESP32-S3 board release, peek and poke included). From there it works through the chunks.
Planned attention: bare-metal AArch64 next; RISC-V after; Windows and other MCU classes later.

**Bare-metal AArch64 (planned).** A new OS-free emitter. Its first board pack is QEMU's `virt` board, followed by
real AArch64 boards as further packs over the same `chip/arm64` layer. It is a raw path, so its milestone is a board
release too: its first one has the behaviours of ESP32-S3's current board release, peek and poke included. Chunk 2 then brings actor pinning, and chunk 14 the AArch64 chip features (memory spaces
through `MAIR_EL1`, and SVE, NEON, MTE and PAC where the core has them), and chunk 13 brings Fifi through the board
pack's C runtime. The BEES project lists raw AArch64 as a 1.0 platform, which makes this the next bare-metal path after
ESP32-S3. Bring-up order and image format:
[porting_for_os_free_targets.md](compiler/design_documents/porting_for_os_free_targets.md) §8 and §11.

## Runtime (Track 2)

Fifi, calling C and C-ABI libraries, is in production on the hosted paths
([designing apps with foreign functions](compiler/tutorials_and_howtos/designing_apps_with_foreign_functions.md)).
Calls from other languages into Silica are not planned.
