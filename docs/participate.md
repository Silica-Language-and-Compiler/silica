---
title: Participate
layout: default
permalink: /participate/
---

The compiler is self-hosted: it is written in Silica, builds itself, and runs the trials. Work is organised by **emitter path** and delivered in **chunks between fixed points**; the authoritative checklist is the [roadmap](https://github.com/yenrab/silica/blob/main/ROADMAP.md). How to open issues and PRs is in [CONTRIBUTING.md](https://github.com/yenrab/silica/blob/main/CONTRIBUTING.md). The [code organization](https://github.com/yenrab/silica/blob/main/compiler/design_documents/silica-compiler-code-organization.md) document helps you navigate the tree, and [Build and test the compiler]({{ '/build-and-test/' | relative_url }}) explains how to build for every platform, for some of them, or for just the machine you are on, and covers the trials and the fixed-point check.

## Fixed points and chunks

A **fixed point** is a self-hosted compiler that passes the whole trial tree when built by itself and then reproduces itself byte for byte (`make fixpoint`). A **chunk** is a slice of the not-yet-implemented specification; it is closed by the next fixed point on that path, never by a build that merely compiles. Every chunk ships with trials.

## Paths still in progress

Apple Silicon, Linux AArch64 and Linux x86-64 are working hosted paths, each with its own fixed point, and the chunks below are taken up on them in lock-step (Apple Silicon leads inside a chunk). What is still being built is the bare-metal side:

- **ESP32-S3 (Xtensa LX7, OS-free)** is not in lock-step, and it has no fixed point: the board cannot host a compiler, so it can never build itself. Its milestone is a **board release**, every trial suite green on the board from a cross compiler built on a hosted machine. Its first board release has all the behaviours of the hosted first fixed point **plus peek and poke** — `map_device` binding a board-legal MMIO window, and the dedicated `peek` and `poke` prims for volatile device loads and stores, callable only from a `spawn_device` worker. They name registers, not offsets, and every access is checked against a device description the programmer supplies. The lexer through the SIR generator are shared by every path, so the hosted paths take the same change at that point, with their emitters rejecting the prims as a compile error, and re-establish their fixed points. After that first board release, ESP32-S3 works through the same chunks at its own pace, skipping hosted-only items. The board has not received a new compiler since the hosted carrier work: the open items are recorded as the "ESP32-S3 board gap" in the [roadmap](https://github.com/yenrab/silica/blob/main/ROADMAP.md); the work is on a separate branch. Port notes: [esp32s3_xtensa_port.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/ports/esp32s3_xtensa_port.md), [porting_for_os_free_targets.md](https://github.com/yenrab/silica/blob/main/compiler/design_documents/porting_for_os_free_targets.md), [device actor specification](https://github.com/yenrab/silica/blob/main/compiler/design_documents/silica_device_actor_specification.md).

## Raw chip features in chunk 14

**Chunk 14 is the rest of the chip's capabilities, and it is raw paths only**, wherever the chip has them; a feature the
chip lacks is recorded in the port notes as not applicable rather than left open. Hosted paths are different by
specification: on an OS the memory spaces are a discipline without guaranteed attribute differentiation (§12.1.1.0).

| Feature (spec wording) | Where | What the raw path delivers |
| --- | --- | --- |
| **Memory spaces.** `region(L, Space)` with `normal`, `normal_writeback`, `normal_writethrough`, `normal_noncacheable`, `atomic`, and `device` (§4.4); OS-free runtimes give each space its real attributes, on AArch64 through `MAIR_EL1` (§12.1.1.0, §12.1.1.1). | §4.4, §12.1.1 | Every space the chip can distinguish maps to the matching cache policy, shareability, or device attribute; `device` is the peek-and-poke window. Spaces the chip cannot distinguish are documented as collapsed. |
| **Chip-specific behaviours.** Feature detection and capability queries (§21.0), then whatever the chip has: on AArch64 SVE (§21.1), NEON (§21.2), MTE (§21.3), PAC (§21.4) and the system-register access of §21.0.2; on ESP32-S3 the Xtensa LX7 equivalents (its vector and cache-control instructions) and none of the AArch64-only items. | §21 | Each raw path carries the §21 items its chip supports, with trials, and lists the rest as not applicable. |

## Where you can help, by chunk

The chunks are **enhancement requests, not an ordered list**: the numbers are identifiers, not a sequence or a priority, and any of them can be taken up, alone or alongside others, when there is a contributor or a need. Chunks that were completed are not listed; their numbers are kept so references stay stable. Each chunk, whenever it is done, ends in the path's next fixed point.

1. **Remaining standard data structures** — the public traits and graph query backends not yet built (CSR and dense graph indexes, `BinaryTree` backends). The growable actor stacks of this chunk are delivered. [Designs](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/data_structure_designs/README.md).
2. **Actor placement: what remains** — the hosted carrier model is delivered on every hosted path. Still open: the **ESP32-S3 board gap** (acquire mode 2 row-child drain protection, board trials for the supervisor self-check pieces that were written but never run, and a new board compiler; see the [roadmap](https://github.com/yenrab/silica/blob/main/ROADMAP.md); separate branch), and the held Linux `get_actor_memory_usage` and x86-64 timing measurements.
4. **Region memory safety**: static lifetime analysis, buffer bounds, isolation, an ownership-based release strategy, atomic references, lifetime polymorphism. The earlier plan to make the 1,152 standard-library records with a region field linear was withdrawn after measurement: they hold only never-freed family arenas, not owned regions. The design splits owned regions (linear) from structure storage (arena or counted regions, open decision Q2), adds a region checker and drop-based release, and moves messages between actors. Status 2026-10-22: run-time bounds checking is done on all four targets; the rest is designed (staged 0 to 8) and not built. Several decisions are open with Lee. [Design](https://github.com/yenrab/silica/blob/main/compiler/design_documents/region_memory_safety_design.md), [Region TODO](https://github.com/yenrab/silica/blob/main/compiler/design_documents/Phase1_TODOs/region_memory_safety_todo.md).
5. **Variants and advanced control**: variant types and patterns, behaviour switching, advanced effects (spec §4.2.5, §6).
6. **Atomic operations and synchronization guarantees** audited and completed (spec §17, §18).
7. **Extended numerics**: big integers, big floats, rationals, big rationals, and 128-bit integers as distinct explicit types with no implicit widening.
8. **Tooling and proof**: [formal verification](https://github.com/yenrab/silica/blob/main/compiler/design_documents/silica-formal-verification-specification.md), [cryptographic guardrails](https://github.com/yenrab/silica/blob/main/compiler/design_documents/crypto-proposal-introduction.md), IDE and developer experience (spec §29), and tighter AArch64 emission without weakening the trials' contract with checked-in baselines.
9. **Networking through Fifi**: networking is not part of the language (spec §20.4); a program reaches the host's sockets, TCP and UDP through the Foreign Function Interface (spec §26.3) like any other foreign library, inside guarded regions in dangerous actors. This chunk is the Fifi wrapper library for the host socket interface and its trials on the hosted paths. No TCP/IP stack is written. Needs the buffer bounds checking from chunk 4.
10. **Actor identity and lifecycle**: the 64-bit actor identity with equality and order, the ending paths (`stop_self`, `fail_self`, `kill_abnormal`, orderly supervisor shutdown), supervisor report sinks, and the atom-keyed registry. Open: `stop_self`, `fail_self` and `panic`; supervisor `:terminate_actor` and `:set_report_sink`; the registry calls `register`, `whereis` and `unregister`.
11. **Time and scheduling refinement**: the clocks, `send_after`, `cancel_timer` and `call_with_timeout`, priority hints and fairness refinement. Not started (status 2026-10-16).
12. **State-machine actors**: the `StateMachine` trait, named states, inserted and postponed events, and the three timeout kinds. Needs the timers of chunk 11.
13. **Foreign data: byte buffers and re-creation** across the Fifi boundary, with the `Recreatable` trait. Needs the buffer bounds checking of chunk 4.
14. **Raw paths: chip features**: the memory spaces with their real attributes and the chip's §21 behaviours. Raw paths only, and it needs peek and poke, which define the `device` space.

CI trial edge-case additions are welcome at any time: grow [trials/](https://github.com/yenrab/silica/tree/main/trials) with scenarios that stress parsing, types, effects, and codegen so the trial tree keeps catching regressions.

## Later paths

A new emitter's first milestone has the same behaviours as the **analogous pre-existing milestone**, not Apple Silicon's: a hosted path starts from the nearest existing hosted fixed point, and a bare-metal path starts from the nearest bare-metal one (bare-metal AArch64 takes the current ESP32-S3 board release, peek and poke included; a raw path has no fixed point). From there it works through the chunks. Hosted and bare metal stay parallel; smaller numbers mean sooner planned attention, not a guarantee. Among bare-metal rows in the same band, ESP32-S3 is listed first because a volunteer is driving it. If you enjoy ABIs, triples, link steps, CI on new hosts, or bringing up a small runtime on a board with no OS, pick a row and open a discussion or PR. See [porting for OS-free targets](https://github.com/yenrab/silica/blob/main/compiler/design_documents/porting_for_os_free_targets.md).

| Planned focus | Strand | Target | Why it helps |
| --- | --- | --- | --- |
| 1 | Bare metal (OS-free, by chip) | ESP32-S3 (Xtensa LX7) | Brought up and running on a real board: ROM/startup, linker, runtime, two-core actors and drivers written in Silica. A volunteer is driving it, so it is listed first among the bare-metal rows; see its [port status](https://github.com/yenrab/silica/blob/main/compiler/design_documents/ports/esp32s3_port_status.md). |
| 1 | Bare metal (OS-free, by chip) | AArch64 | Real cores without a full OS; see [memory effects on AArch64 / OS-free targets](https://github.com/yenrab/silica/blob/main/compiler/design_documents/memory-effects-aarch64-implementation-plan.md); ABI/runtime on a minimal environment. |
| 2 | Bare metal (OS-free, by chip) | RISC-V (application-profile cores) | Broad embedded/accelerator footprint; calling convention, linker/platform story, trials or hardware-in-the-loop. |
| 3 | Hosted (chip + OS) | Windows (x86_64; AArch64 when there is demand) | Lowers the barrier for contributors and teams on Windows workstations. |
| 3 | Bare metal (OS-free, by chip) | Common MCU classes (e.g. 32-bit embedded) | Longer tail of boards/ISAs; linker scripts, platform packages, minimal-runtime contract per profile. |

## Compiler-building tools

Tools for generating compiler code and coordinating work live under [compiler/compiler-building-tools/](https://github.com/yenrab/silica/tree/main/compiler/compiler-building-tools/).

For JSON-LD agent graphs, which files to use, and how they fit AI-assisted workflows, see [compiler-building-tools/README.md](https://github.com/yenrab/silica/blob/main/compiler/compiler-building-tools/README.md).
