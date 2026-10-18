---
title: Participate
layout: default
permalink: /participate/
---

The compiler is self-hosted: it is written in Silica, builds itself, and runs the trials. Work is organised by **emitter path** and delivered in **chunks between fixed points**; the authoritative checklist is the [roadmap](https://github.com/yenrab/silica/blob/main/ROADMAP.md). How to open issues and PRs is in [CONTRIBUTING.md](https://github.com/yenrab/silica/blob/main/CONTRIBUTING.md). The [code organization](https://github.com/yenrab/silica/blob/main/compiler/design_documents/silica-compiler-code-organization.md) document helps you navigate the tree, and [Build and test the compiler]({{ '/build-and-test/' | relative_url }}) explains how to build for every platform, for some of them, or for just the machine you are on, and covers the trials and the fixed-point check.

## Fixed points and chunks

A **fixed point** is a self-hosted compiler that passes the whole trial tree when built by itself and then reproduces itself byte for byte (`make fixpoint`). A **chunk** is a slice of the not-yet-implemented specification; it is closed by the next fixed point on that path, never by a build that merely compiles. Every chunk ships with trials.

## The four paths

- **Apple Silicon (macOS, AArch64)** leads. The code as it stands today is the content of its first fixed point (FP1).
- **Linux AArch64** is in lock-step: fixed point *n* on Linux has exactly the Silica behaviours of fixed point *n* on Apple Silicon. Apple leads inside a chunk; the chunk is not closed until Linux has caught up. Port notes: [linux_aarch64_port_checklist.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/ports/linux_aarch64_port_checklist.md).
- **Linux x86-64 (AMD64, hosted)** is in lock-step with Linux AArch64, from which its backend was copied. It builds natively on an x86-64 Linux machine and has its own fixed point (first reached 2026-09-19, re-established 2026-10-16). Plan and status: [porting_to_linux_x86_64_hosted.md](../compiler/design_documents/porting_to_linux_x86_64_hosted.md).
- **ESP32-S3 (Xtensa LX7, OS-free)** is not in lock-step, and it has no fixed point: the board cannot host a compiler, so it can never build itself. Its milestone is a **board release**, every trial suite green on the board from a cross compiler built on a hosted machine. Its first board release has all the behaviours of Apple Silicon FP1 **plus peek and poke** — `map_device` binding a board-legal MMIO window, and the dedicated `peek` and `poke` prims for volatile device loads and stores, callable only from a `spawn_device` worker. They name registers, not offsets, and every access is checked against a device description the programmer supplies. The lexer through the SIR generator are shared by every path, so Apple Silicon and Linux AArch64 take the same change at that point, with their emitters rejecting the prims as a compile error, and re-establish their fixed points. After that first board release, ESP32-S3 works through the same chunks at its own pace, skipping hosted-only items. Port notes: [esp32s3_xtensa_port.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/ports/esp32s3_xtensa_port.md), [porting_for_os_free_targets.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/porting_for_os_free_targets.md), [device actor specification](https://github.com/yenrab/silica/blob/main/compiler/design_documents/silica_device_actor_specification.md).

## Actor placement in chunk 2; raw chip features in chunk 14

**Chunk 2 is actor placement, pinning and cooperative multitasking, and it is on every path**, right after the actor
stacks and data structures. On hosted paths it follows the BEAM pattern, and it may pull forward whatever part of
chunk 11's scheduler it needs.
The program surface is the same everywhere, and it is the one the compiler implements today (type checker, SIR and all
four emitters): `spawn(initial_state, behaviour, stack_policy(...))` with an optional last argument naming the core, a
`uint64` logical core id or `core_id(n)` (§4.6, §15.1.1), and the same position in `spawn_registered` and the supervisor
spawns; `migrate_actor(ref, core)` (§15.1.2, §22.10; the older `move(ref, from, to)` builtin was removed on 2026-10-16);
the `pin_actor_to_*` family and `unpin_actor`; `set_actor_priority` and `set_scheduler_policy` (four policies); and
`get_cpu_topology()` with the `cpu_topology` / `core_info` records (§22.10). What "pinned" can mean differs by target,
exactly as the specification already says.

| Path | What pinning means there |
| --- | --- |
| **OS-hosted** | The actor is bound to a **thread**: the runtime's carrier thread for that logical core, one carrier per core with many actors on it, switching cooperatively at yield points. The runtime never moves an actor to another carrier on its own. The runtime asks the OS for affinity for that thread where the OS allows it, but the OS still owns the cores, and Apple Silicon macOS offers no hard thread-to-core binding, so exclusive placement is **not** guaranteed. `migrate_actor` moves the actor between carrier threads, the way the BEAM moves processes between its scheduler threads. |
| **Raw (OS-free)** | The actor is bound to a **core**: the runtime pins it to the named core, exclusively and for its whole life, unless the program moves it or it terminates, and reports the real topology. The ESP32-S3 has two LX7 cores, so this applies to it, and it is **delivered** there: one cooperative scheduler per core, exclusive pinning from `spawn`, migration at the dispatch boundary, the four dispatch-order policies and the three priority tiers. |

**Chunk 14 is the rest of the chip's capabilities, and it is raw paths only**, wherever the chip has them; a feature the
chip lacks is recorded in the port notes as not applicable rather than left open. Hosted paths are different by
specification: on an OS the memory spaces are a discipline without guaranteed attribute differentiation (§12.1.1.0).
Apple Silicon's side of the placement work is already planned in
[cpu_topology_implementation_plan.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/cpu_topology_implementation_plan.md).

| Feature (spec wording) | Where | What the raw path delivers |
| --- | --- | --- |
| **Memory spaces.** `region(L, Space)` with `normal`, `normal_writeback`, `normal_writethrough`, `normal_noncacheable`, `atomic`, and `device` (§4.4); OS-free runtimes give each space its real attributes, on AArch64 through `MAIR_EL1` (§12.1.1.0, §12.1.1.1). | §4.4, §12.1.1 | Every space the chip can distinguish maps to the matching cache policy, shareability, or device attribute; `device` is the peek-and-poke window. Spaces the chip cannot distinguish are documented as collapsed. |
| **Chip-specific behaviours.** Feature detection and capability queries (§21.0), then whatever the chip has: on AArch64 SVE (§21.1), NEON (§21.2), MTE (§21.3), PAC (§21.4) and the system-register access of §21.0.2; on ESP32-S3 the Xtensa LX7 equivalents (its vector and cache-control instructions) and none of the AArch64-only items. | §21 | Each raw path carries the §21 items its chip supports, with trials, and lists the rest as not applicable. |

## Where you can help, by chunk

The chunks are **enhancement requests, not an ordered list**: the numbers are identifiers, not a sequence or a priority, and any of them can be taken up, alone or alongside others, when there is a contributor or a need. Two placements were decided explicitly: chunk 1 comes immediately after FP1 on every path, and chunk 2 follows it on the raw paths. Each chunk, whenever it is done, ends in the path's next fixed point.

1. **Growable and shrinkable actor stacks, and the remaining standard data structures** — first after the first milestone on every path. Stacks as [spec §15.1.2.2](https://github.com/yenrab/silica/blob/main/compiler/design_documents/silica-specification.md#spec-actor-stack-architecture) defines them since 2026-09-17: one reservation per actor, defaulting to the machine's memory plus swap and lowerable per spawn; nothing committed at spawn; growth in the fault handler in chunks that double from one platform page to 1 MB; release at the message boundary under one of five named algorithms, `:release_on_return`, `:keep_last_message`, `:track_recent_peak`, `:release_when_idle` and `:keep_high_water`, chosen by the `stack_policy` argument every spawn requires; no per-actor maximum and no cap; `main` is not an actor. Mechanics: [actor_growable_stack_design.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/actor_growable_stack_design.md) §2, §4, §7. Plan: [actor_stack_growth_plan.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/actor_stack_growth_plan.md). Data structures: the remaining public traits and graph query backends. [Designs](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/data_structure_designs/README.md).
2. **Actor placement, pinning and cooperative multitasking, on every path** — `spawn` with a logical core index or `core_id(n)`, `migrate_actor`, and `get_cpu_topology()`. A hosted path pins the actor to a thread and schedules many actors per carrier on the BEAM pattern, a raw path pins it to a core, as set out above. This is what replaces today's thread-per-actor and lets one machine hold millions of actors. First after chunk 1 on every path. The surface exists on every path today; the ESP32-S3 has the per-core schedulers, and the hosted carrier model (one carrier thread per logical core, many actors per carrier) is what remains.
3. **Immutable lists — map, filter, reduce** over region-backed, vector-sized chunks so the functional pipeline stays expressive while the emitter can target SIMD-friendly layouts. [List implementation design](https://github.com/yenrab/silica/blob/main/compiler/design_documents/list_implementation_design.md), [TODO M1–M3](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/list_map_filter_reduce_and_hardening_todo.md).
4. **Region memory safety**: static lifetime analysis, buffer bounds, isolation, an ownership-based release strategy, atomic references, lifetime polymorphism. It also enforces the aggregate move rule: a region handle is move-only (spec §4.4.2) and the rule extends to records and tuples that embed one, but the compiler checks only a bare region parameter, so every data structure sidesteps it. Measured scope for that part: 30 standard-library modules, 1,152 records with a region field, and all ten public data-structure traits. No design yet. [Region TODO](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/region_memory_safety_todo.md).
5. **Variants and advanced control**: variant types and patterns, behaviour switching, advanced effects (spec §4.2.5, §6).
6. **Atomic operations and synchronization guarantees** audited and completed (spec §17, §18).
7. **Extended numerics**: big integers, big floats, rationals, big rationals, and 128-bit integers as distinct explicit types with no implicit widening.
8. **Tooling and proof**: [formal verification](https://github.com/yenrab/silica/blob/main/compiler/design_documents/silica-formal-verification-specification.md), [cryptographic guardrails](https://github.com/yenrab/silica/blob/main/compiler/design_documents/crypto-proposal-introduction.md), IDE and developer experience (spec §29), and tighter AArch64 emission without weakening the trials' contract with checked-in baselines.
9. **Networking through Fifi**: networking is not part of the language (spec §20.4); a program reaches the host's sockets, TCP and UDP through the Foreign Function Interface (spec §26.3) like any other foreign library, inside guarded regions in dangerous actors. This chunk is the Fifi wrapper library for the host socket interface and its trials on the hosted paths. No TCP/IP stack is written. Needs chunk 1 (one actor per connection) and the buffer bounds checking from chunk 4.
10. **Actor identity and lifecycle**: the 64-bit actor identity with equality and order, the ending paths (`stop_self`, `fail_self`, `kill_abnormal`, orderly supervisor shutdown), supervisor report sinks, and the atom-keyed registry.
11. **Time, and the scheduling chunk 2 did not take**: the clocks, `send_after`, `cancel_timer` and `call_with_timeout`, priority hints and fairness refinement, and the raw paths' per-core schedulers. The hosted carrier model itself is chunk 2.
12. **State-machine actors**: the `StateMachine` trait, named states, inserted and postponed events, and the three timeout kinds. Needs the timers of chunk 11.
13. **Foreign data: byte buffers and re-creation** across the Fifi boundary, with the `Recreatable` trait. Needs the buffer bounds checking of chunk 4.
14. **Raw paths: chip features**: the memory spaces with their real attributes and the chip's §21 behaviours. Raw paths only, and it needs peek and poke, which define the `device` space.

CI trial edge-case additions are welcome at any time: grow [trials/](https://github.com/yenrab/silica/tree/main/trials) with scenarios that stress parsing, types, effects, and codegen so the trial tree keeps catching regressions.

## Later paths

A new emitter's first milestone has the same behaviours as the **analogous pre-existing milestone**, not Apple Silicon's: a hosted Linux path starts from Linux AArch64 (Linux on AMD or Intel x86-64 takes the current Linux AArch64 fixed point), and a bare-metal path starts from the nearest bare-metal one (bare-metal AArch64 takes the current ESP32-S3 board release, peek and poke included; a raw path has no fixed point). From there it works through the chunks. Hosted and bare metal stay parallel; smaller numbers mean sooner planned attention, not a guarantee. Among bare-metal rows in the same band, ESP32-S3 is listed first because a volunteer is driving it. If you enjoy ABIs, triples, link steps, CI on new hosts, or bringing up a small runtime on a board with no OS, pick a row and open a discussion or PR. See [porting for OS-free targets](https://github.com/yenrab/silica/blob/main/compiler/design_documents/porting_for_os_free_targets.md).

| Planned focus | Strand | Target | Why it helps |
| --- | --- | --- | --- |
| 1 | Hosted (chip + OS) | Linux on AArch64 | Same ISA as today’s primary machine, different syscall/link story; ARM cloud and desktop Linux for contributors and trials. |
| 1 | Bare metal (OS-free, by chip) | ESP32-S3 (Xtensa LX7) | Brought up and running on a real board: ROM/startup, linker, runtime, two-core actors and drivers written in Silica. A volunteer is driving it, so it is listed first among the bare-metal rows; see its [port status](https://github.com/yenrab/silica/blob/main/compiler/design_documents/ports/esp32s3_port_status.md). |
| 1 | Bare metal (OS-free, by chip) | AArch64 | Real cores without a full OS; see [memory effects on AArch64 / OS-free targets](https://github.com/yenrab/silica/blob/main/compiler/design_documents/memory-effects-aarch64-implementation-plan.md); ABI/runtime on a minimal environment. |
| 2 | Hosted (chip + OS) | Linux on x86_64 | Broad server and desktop footprint; strong payoff for CI and for developers not on Apple hardware. Already builds natively and reaches its own fixed point (`binaries/silica-compiler-linux_x86_64`; see [Build and test]({{ '/build-and-test/' | relative_url }})); the row stays for the work that remains on it ([execution plan](https://github.com/yenrab/silica/blob/main/compiler/design_documents/porting_to_linux_x86_64_hosted.md)). |
| 2 | Bare metal (OS-free, by chip) | RISC-V (application-profile cores) | Broad embedded/accelerator footprint; calling convention, linker/platform story, trials or hardware-in-the-loop. |
| 3 | Hosted (chip + OS) | Windows (x86_64; AArch64 when there is demand) | Lowers the barrier for contributors and teams on Windows workstations. |
| 3 | Bare metal (OS-free, by chip) | Common MCU classes (e.g. 32-bit embedded) | Longer tail of boards/ISAs; linker scripts, platform packages, minimal-runtime contract per profile. |

## Compiler-building tools

Tools for generating compiler code and coordinating work live under [compiler/compiler-building-tools/](https://github.com/yenrab/silica/tree/main/compiler/compiler-building-tools/).

For JSON-LD agent graphs, which files to use, and how they fit AI-assisted workflows, see [compiler-building-tools/README.md](https://github.com/yenrab/silica/blob/main/compiler/compiler-building-tools/README.md).
