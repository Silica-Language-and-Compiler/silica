<h1 align="left">
  <img src="../../../silica_icon_tiny.png" alt="" width="40" height="40" style="vertical-align: middle; margin-right: 0.35em;" />
  Silica compiler — design documents
</h1>

These files are **working documents**: specifications, plans, and design notes for the Silica language and the self-hosted compiler. They are **revised as the implementation evolves**; where they disagree with each other or with the code, treat the situation as “docs catching up” unless a document explicitly marks itself as normative for a given area.

Use the entries below for **quick navigation**. Each item links to a file in this directory, followed by a short summary of what it contains.

---

## [APPLICATION_IS_ONE_COMPILATION_UNIT.md](./APPLICATION_IS_ONE_COMPILATION_UNIT.md)

**Read this before designing anything.** A Silica application, libraries included, is one compilation unit, with one atom table and whole-program checks. Today's one-unit-per-file build (`silica.config`, process-per-unit reclaim, `.iface` files) is a work-around for compiler memory; nothing may be designed around it.

---

## [HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md](./HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md)

**Record of the high-priority defect list** found while generating the `train_*` trial pairs: silent miscompilations (second float parameter lost, returned closure loses its capture, record actor state faults, tuple-after-scalar parameter clobber, provided trait methods unresolved after the exit-75 restart) and the mistakes the compiler accepted without a diagnostic. Each item has a minimal reproduction. As of 2026-10-16 every item is fixed and pinned by an installed `train_defect_*` trial except A2 closure environments (a returned capturing function literal is rejected with E1067; the closure representation is not implemented). The document has a per-item status table.

---

## [HIGH_PRIORITY_compiler_defects_addendum_2026-09-09.md](./HIGH_PRIORITY_compiler_defects_addendum_2026-09-09.md)

**Addendum to the defect list**: a parenthesised right operand reads the left operand's value in place of the first parameter (`20 + (x + 1)` returns 41 for x = 5), and `float32` comparisons with compound expressions on both sides compare the wrong registers. Both with probe tables; both fixed and pinned by `train_defect_a7_*` and `train_defect_a8_*` (status note at its top).

---

## [compiler_defects_resolution_plan.md](./compiler_defects_resolution_plan.md)

**Plan for resolving the defect list** (phases for operand staging, provided-method overloads across the exit-75 restart, returned closures, actor codegen, large units, and the diagnostic gaps). Executed; its implementation status says what remains (closure environments, the misleading-message wordings).

---

## [compiler_defects_execution_status_2026-09-10.md](./compiler_defects_execution_status_2026-09-10.md)

**Execution record of the 2026-09-10 scratch run** of the resolution plan: causes found and changes made per item, validation numbers, and the facts learned. Accepted into the repository; the open list it ends with is superseded by the status note at its top.

---

## [silica-specification.md](./silica-specification.md)

**Authoritative Silica language specification** (large document): syntax, types, effects, regions, actors, diagnostics, compiler interface, and normative semantics for the language as currently defined.

---

## [silica-specification-additional.md](./silica-specification-additional.md)

**Extra compile-time rules** that reject anti-patterns (dead bindings, duplicate computation, loop invariants, redundant algebra, etc.) and records the **actor execution contract** (runtime loop vs. user behavior) for tooling. Only the dead-binding rule exists today (`E1055`); the rest is intent, marked in its status table.

---

## [execution-environments-hosted-vs-bare-metal.md](./execution-environments-hosted-vs-bare-metal.md)

**Reader-oriented overview** of how **OS-hosted** processes vs **OS-free** / bare-metal targets affect **memory `Space` guarantees** and **actor core placement**, with pointers to normative spec sections and related plans.

---

## [porting_to_linux_x86_64_hosted.md](./porting_to_linux_x86_64_hosted.md)

**Porting plan** for the **Linux x86_64 hosted** target (Debian-family x86-64 hosts, DigitalOcean droplets), revised 2026-09-18: the backend was copied from `linux_aarch64` into `src/emitter/linux_x86_64/`, the Mac compiled and the x86-64 machine ran until the cross hand-off produced the first native selfhost, then fixpoint. Executed through the first fixed point (2026-09-19); the document records the port and its later status. The register and frame model (System V, five callee-saved registers, fixed `rbp` frame) is in `src/emitter/linux_x86_64/regs/README.md`.

---

## [porting_for_os_free_targets.md](./porting_for_os_free_targets.md)

**Porting plan** for **OS-free / raw-metal** boards: what “complete” means, present vs missing (including MMIO map and volatile load/store), device registers vs CPU GPRs vs system registers, board-pack contract, and phased bring-up.

---

## [ports/esp32s3_port_status.md](./ports/esp32s3_port_status.md)

**ESP32-S3 port status** (native Xtensa, bare metal): the behaviours verified on the board (apps and trial suites, with dates), the behaviours that differ from Apple Silicon (console, exit statuses, faults, stacks, heap, numerics, printing), what the emitter refuses (`.error`), and the gaps ordered for the next addition: actor runtime, peek and poke, the suites not yet run on the board, trial-driver gaps, emitter performance.

---

## [ports/linux_aarch64_port_checklist.md](./ports/linux_aarch64_port_checklist.md)

**Hosted port checklist** (now the record of how the port was made; it self-hosts and has fixed points) for **64-bit Raspberry Pi OS / Debian AArch64**: emit-target naming, the Darwin-ism inventory (syscall convention, `X8` hazard, symbol decoration, relocation syntax, sections, entry point and stack), the per-target golden-file split, Pi bootstrap steps, and verification gates through self-host.

---

## [actor_growable_stack_design.md](./actor_growable_stack_design.md)

Actor memory architecture: **growable per-actor stacks**, lazy page migration, isolation vs. the older per-actor heap sketch, NUMA-oriented behavior, and cleanup on actor termination.

---

## [Phase1_TODOs/actor_stack_growth_plan.md](./Phase1_TODOs/actor_stack_growth_plan.md)

**Actor stack growth plan** (ROADMAP chunk 1): segmented per-actor stacks managed by the runtime, with the insertion points in the emitters and runtimes. The earlier `actor_implementation_plan.md` was removed; actor status lives in the specification and the port status documents.

---

## [silica_actor_capabilities_specification.md](./silica_actor_capabilities_specification.md)

Draft extension for **mode- and protocol-typed actor capabilities**: `actor_ref call`, `actor_ref cast`, `dangerous_actor_ref cast`, protocol ordering, capability splitting, and how Silica's existing call-only/cast-only actors become reference-level authority.

---

## Supervision

The supervision roadmap document (`supervisors_implementation_development_plan.md`) was removed; supervision is specified in [silica-specification.md](./silica-specification.md) §15.4 (`Supervisor` trait, `supervisor_ref`, `spawn_registered_supervisor`, `call_supervisor`, runtime-owned child tables, restart strategies, `FailureReporter`, `link` / `monitor`) and taught in `../tutorials_and_howtos/supervisors_and_failure_reporter_tutorial.md`.

---

## [actor_spawn_core_affinity_os_semantics.md](./actor_spawn_core_affinity_os_semantics.md)

**OS semantics** for **`spawn`** with a **single core id** (`uint64`): how macOS, Linux, FreeBSD, Solaris/illumos, and Windows interpret affinity vs. hints, carrier threads vs. actors, and pointers to topology and emitter plans.

---

## [Phase1_TODOs/cpu_topology_implementation_plan.md](./Phase1_TODOs/cpu_topology_implementation_plan.md)

Apple Silicon + macOS **CPU topology implementation record**: sysctl-backed `get_cpu_topology`, `get_core_capabilities`, core lists, cache/NUMA layout caveats, and remaining portability/frequency-reporting work.

---

## [atom_actor_registry_direct_index_design.md](./atom_actor_registry_direct_index_design.md)

**O(1) registry** mapping atom intern ids to **`actor_ref`**: contiguous **`0…N−1`** ids, contiguous slot buffer keyed by id, region-backed growth; contrast **`List`** scan, trees, no surface **`Map`**.

---

## [runtime_failure_reporting.md](./runtime_failure_reporting.md)

**Runtime failure reporting**, implemented 2026-09-19 on every target: one report format for a fault (exit 70) and an abort (exit 71), per-site abort entries, the banners, and what the supervisor and `FailureReporter` receive. Replaces the earlier BEAM-like crash-containment notes, which were removed.

---

## [brokered_ipc_isolation_architecture.md](./brokered_ipc_isolation_architecture.md)

**Process isolation** for using unsafe native libraries: safe application, **broker**, and untrusted worker; separate IPC channels, validation, no in-process FFI to the worker, policy and recovery.

---

## [crypto-proposal-introduction.md](./crypto-proposal-introduction.md)

High-level introduction to **language-level cryptographic guardrails**: secret vs. public labels, constant-time comparisons, control-flow and indexing rules, protected buffers, and `proc[secret]`-style constraints.

---

## [tls_quantum_safe_future.md](./tls_quantum_safe_future.md)

**Future development** (not implemented): first-class **TLS 1.3** with a **hybrid ML-KEM** default, one supervised `spawn_dangerous` actor per connection, Fifi taint/`external_danger` rules, and no application-visible engine types.

---

## [direct_machine_object_emitter_future.md](./direct_machine_object_emitter_future.md)

**Future compiler development** (not implemented; the four backends still emit assembly text): replacing assembly-text steps with Silica-owned **chip instruction encoders** and **object writers** for AArch64, x86-64, ESP32-S3 / Xtensa, and later documented targets, while keeping hardware behavior explicit in compiler data.

---

## [list_implementation_design.md](./list_implementation_design.md)

How **immutable, Erlang-style lists** are represented and lowered in the compiler: chunks, handles, early desugaring, and integration with memory spaces—implementation detail that refines the language spec where noted. Its implementation status records the shipped layout (24-byte handles, copy-on-write prepend, boxed elements) and that `map` / `filter` / `reduce` are not implemented.

---

## [Phase1_TODOs/list_map_filter_reduce_and_hardening_todo.md](./Phase1_TODOs/list_map_filter_reduce_and_hardening_todo.md)

**Remaining TODOs** for the list pipeline after core representation, literals, and list patterns: `map` / `filter` / `reduce` (not started), explicit non-primitive element coverage (partly covered), Collectable/region-authority checks, and final spec-alignment cleanup.

---

## [list_chunk_vector_alignment_todo.md](./list_chunk_vector_alignment_todo.md)

**Open work** (nothing done) for making list **chunk data** sizing and codegen **follow target SIMD width** (**§4.5** bridge from design **§2/§4.1** to the current fixed **16-byte** minimum in **`prims_list.silica`**).

---

## [Phase1_TODOs/data_structure_to_algorithms.md](./Phase1_TODOs/data_structure_to_algorithms.md)

**Locked algorithm authority** for standard collections: Adams weight-balanced trees, WBT live graphs + CSR freeze, Brodal–Okasaki heaps, Okasaki skew binary random-access lists. All other design docs defer here for insert/delete algorithms and persistence.

## [Phase1_TODOs/data_structures_as_traits.md](./Phase1_TODOs/data_structures_as_traits.md)

**Trait API specification (not implemented):** maps each trait module to WBT / WBT-graph / Brodal–Okasaki / random-access-list backends per `data_structure_to_algorithms.md`. Constructor function records, `provided` + `fold` surfaces, comparator contracts, views/adapters.

## [graph_representation_design.md](./graph_representation_design.md)

Graph families for code generation: **WBT live graphs** (vertex WBT + inner neighbor WBT set/map), **CSR snapshots** (freeze from live graph), **dense matrix** (random-access list). Dense bitset graphs are **out of scope**.

## [Phase1_TODOs/standard_data_structures_implementation_plan.md](./Phase1_TODOs/standard_data_structures_implementation_plan.md)

Step-by-step implementation plan for standard generated data structures. Defers to `data_structure_to_algorithms.md` for algorithms and to the representation design documents for Silica shapes and naming.

---

## [balanced_tree_and_heap_design.md](./balanced_tree_and_heap_design.md)

**WBT** ordered trees and **Brodal–Okasaki** heaps: inline shapes, path-copying immutability, trait wiring, module naming (`wbt_set`, `wbt_map`, `brodal_okasaki_*`), generator requirements.

---

## [btree_set_design.md](./btree_set_design.md)

Ordered **set and map** design (Adams WBT only): operations, bulk `from_sorted`, validation, and generator exports. Filename retained for navigation; content is WBT, not B-tree.

---

## [parser_design.md](./parser_design.md)

Silica **parser architecture** based on **constraint propagation** (not classic LL/LR/PEG): roles on tokens, local constraints, one file per capability, and how the design stays modular as features grow. Implemented in `src/parser/`; its status notes record where the shipped layout differs.

---

## [recursion_implementation.md](./recursion_implementation.md)

Design for **general recursion**: explicit frame stacks, tail and preemption (**fuel** / reductions), defunctionalized continuations, and tradeoffs vs. naive CPS. Mostly not implemented (recursion runs on the native actor stack; native tail calls exist; no fuel); the status note says what the compiler does.

---

## [recursive_tuple_specification.md](./recursive_tuple_specification.md)

**Recursive tuple types** (implemented): `rec`, `:none`, region-backed recursive slots, typing with occurs-check, construction/decomposition, and ties to formal verification (recursive products).

---

## [Phase1_TODOs/region_memory_safety_todo.md](./Phase1_TODOs/region_memory_safety_todo.md)

**Implementation gaps** for the region memory model vs. the full specification: lifetime analysis phases, what is already implemented in the compiler, and what remains for sound region safety.

---

## [silica-compiler-code-organization.md](./silica-compiler-code-organization.md)

**Directory and file layout** of the Silica-in-Silica compiler (`compiler/src`): driver, lexer, parser, module/type/trait/effect/FFI checkers, SIR generator, per-target emitters, naming conventions, and how to add a feature without churn.

---

## [silica-formal-verification-specification.md](./silica-formal-verification-specification.md)

**Formal verification** framing: Curry–Howard view, value calculus, recursive product rules, region lifetime judgments—extends toward proof terms and checkable reasoning over Silica programs. A statement of rules; the compiler has no proof checker (status note lists what it enforces).

---

## [../tutorials_and_howtos/silica_sequence_blocks_tutorial.md](../tutorials_and_howtos/silica_sequence_blocks_tutorial.md)

Tutorial for **`sequence` blocks** (`sequence` / `produces` / `pure` / monadic steps): where they appear vs. function bodies, effect declarations, and binding patterns—updated from older `do`-style tutorials.

---

## [utf8_support.md](./utf8_support.md)

**UTF-8 in char literals** and helpers such as `substring_until_char` (implemented): lexer, SIR and emitter changes, and correct handling of multi-byte characters in pure Silica.

---

## [Phase2_TODO/use_tree_first_pass.md](./Phase2_TODO/use_tree_first_pass.md)

**Phase 2 compiler driver (design; not implemented as of 2026-10-16):** the first process of a multi-unit batch builds the **module use-tree** only — lex and parse declarations through the **first `fn`**, Kahn-sort, then exit 75. Function bodies wait for the resume-process full parse. Progress must say a use-tree is being built.

---

## [Phase1_TODOs/bootstrap_retirement_and_self_host_plan.md](./Phase1_TODOs/bootstrap_retirement_and_self_host_plan.md)

**Self-host migration plan and record.** Self-hosting is reached (first fixed point 2026-09-12; fixed points on Apple Silicon, Linux AArch64 and Linux x86-64; the Rust bootstrap crate was removed 2026-09-17). Its status section lists what is done and what is left (the `string_literal_pool` linear scan, two orphan files); the body is the original plan.

---

## [module_interface_cache_and_bottom_up_typecheck_plan.md](./module_interface_cache_and_bottom_up_typecheck_plan.md)

**Module interface (`.iface`) cache** and bottom-up type checking: dependents type-check against published interfaces rather than dependency ASTs. Implemented (format 2 with a persisted type DAG, stamp and hash invalidation, parse skip); the status note maps each plan item to its code.

---

## [memory-effects-aarch64-implementation-plan.md](./memory-effects-aarch64-implementation-plan.md)

**Plan for per-space hardware behaviour** (`mem(Space)`) on OS-free targets (AArch64 `MAIR`, ESP32-S3). The static discipline is implemented; per-space pools, `alloc_region` space routing and atomic `LDAR`/`STLR` access are not (status table at its top).

---

## Further documents in this directory

- [actor_memory_budget_plan.md](./actor_memory_budget_plan.md): what one actor, supervisor and `main` cost in memory on the ESP32-S3 board and on hosted targets, how the cost is cut, and what bounds the number of actors (formerly `esp32s3_memory_budget_plan.md`).
- [esp32s3_board_peripherals_plan.md](./esp32s3_board_peripherals_plan.md): supporting the test board's peripherals through device workers (`peek` / `poke` over board-pack descriptions) and the efficient Silica versions of the board apps.
- [ports/esp32s3_xtensa_port.md](./ports/esp32s3_xtensa_port.md): the native Xtensa LX7 port (emitter conversion, board pack, runtime on both cores).
- [ports/esp32s3_peek_poke_implementation_plan.md](./ports/esp32s3_peek_poke_implementation_plan.md) and [ports/esp32s3_peek_poke_implementation_details.md](./ports/esp32s3_peek_poke_implementation_details.md): the peek/poke programme and its design record.
- [silica_device_actor_specification.md](./silica_device_actor_specification.md): device actors, `map_device` / `peek` / `poke`, and device descriptions.
- [silica_ffi_wrapper_specification.md](./silica_ffi_wrapper_specification.md) and [dangerous_ffi_security_model.md](./dangerous_ffi_security_model.md): the Fifi foreign-call wrapper rules and the security model of `dangerous_*` actors.
- [region_memory_safety_design.md](./region_memory_safety_design.md): region memory safety design (ROADMAP chunk 4).
- [pid_registry_process_global_actor_gate.md](./pid_registry_process_global_actor_gate.md): the process-global PID registry reached only through its gate actor.
- [macos_crash_handling_for_silica.md](./macos_crash_handling_for_silica.md): what a macOS runtime may safely do in the crash path.
- [IPC_Bare.md](./IPC_Bare.md), [IPC_OS.md](./IPC_OS.md), [IPC_RTOS.md](./IPC_RTOS.md): actor runtime and messaging architectures for bare metal, operating systems and RTOS targets (each has an implementation status note).
- [Phase2_TODO/actor_monitor_demonitor_todo.md](./Phase2_TODO/actor_monitor_demonitor_todo.md) and [Phase2_TODO/stateful_and_sharded_data_structures.md](./Phase2_TODO/stateful_and_sharded_data_structures.md): Phase 2 plans.
- [Phase1_TODOs/data_structure_designs/](./Phase1_TODOs/data_structure_designs/README.md) and [Phase1_TODOs/standard_data_structures_baseline/](./Phase1_TODOs/standard_data_structures_baseline/normative_inputs.md): per-structure designs and the baseline inputs and ledger for the standard collections.
