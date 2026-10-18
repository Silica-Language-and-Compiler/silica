# Phase 1 Standard Data Structures — Dependency-Ordered Implementation Plan

**Date:** 2026-06-29; BinaryTree amendment 2026-07-02
**Status:** Implementation sequencing authority. Implementation status (2026-10-16): all ten public traits and the live, CSR and dense graph representations are implemented in `compiler/stdlib/data_structures/` with trials under `trials/ordered_data_structures/`; the open items are listed in the per-section status records below and in §37.
**Design authority:** `[data_structure_designs/README.md](data_structure_designs/README.md)` and every design linked from it

## 1. Purpose

This document defines the implementation order for the Phase 1 standard data structures. It does not redesign their APIs, algorithms, representations, or invariants. Those decisions belong to the detailed design suite.

The governing scheduling rule is:

> Implement and accept the deepest shared dependency first. Implement a consumer only after every dependency it uses has passed its acceptance gate. Implement terminal structures—structures with no downstream Phase 1 consumers—last.

Sections §6–§8 establish substrate and the WBT core. Sections §9–§37 are one strict serial queue—complete each in order. This is a topological plan, not a list ordered by perceived API simplicity.

## 2. Scope and authority

### 2.1 In scope

- compiler and runtime support required by the detailed designs;
- canonical application-lifetime arenas for generated specializations;
- exact function-value ordering identity;
- recursive tuple allocation and references;
- trait and constructor-record support for all Phase 1 collection families;
- the WBT, skew binary random-access-list, Brodal–Okasaki, and persistent binary-tree cores;
- all ten public data-structure traits;
- live WBT, CSR snapshot, and dense graph representations;
- generated module registration, build integration, new trials, validation, and cross-representation conformance.

### 2.2 Out of scope

- any old data-structure implementation or trial removed by the reset;
- B-trees, red-black trees, binary heaps, pairing heaps, adjacency-list graph replacements, or mutable alternatives;
- compatibility wrappers for removed modules;
- priority-queue arbitrary deletion or decrease-key;
- rose-tree compaction or child-slot reuse;
- compiler-wide adoption of `BinaryTree` as the parser AST representation (downstream migration tracked in `bootstrap_retirement_and_self_host_plan.md`, not a standard BinaryTree acceptance prerequisite);
- graph vertex removal;
- algorithms not explicitly part of the detailed design suite.

### 2.3 Conflict rule

1. `[data_structure_to_algorithms.md](data_structure_to_algorithms.md)` controls algorithm-family choices.
2. `[data_structures_as_traits.md](data_structures_as_traits.md)` controls trait architecture and constructor-record resolution.
3. `[data_structure_designs/](data_structure_designs/)` controls exact APIs, representations, invariants, and failure behavior.
4. This file controls implementation order and acceptance gates only.

If this plan appears to specify behavior differently from a detailed design, the detailed design wins and this plan must be corrected.

### 2.4 Non-negotiable genericity gate

Every implementation unit, trial, and generated specialization must follow the [overriding genericity rule](data_structure_designs/common_contract.md#overriding-genericity-rule).

An implementation—including one produced by an AI—must derive `ItemType`, `KeyType`, `ValueType`, `PriorityType`, `NodeIdType`, `EdgePayloadType`, `EdgeDataType`, `WeightType`, `AccType`, and `SpaceType` from programmer declarations. It must not hard-code them from examples or representation internals. Acceptance requires non-scalar and structurally composite witnesses wherever the language permits them; testing only `int64` or `string` does not establish generic support.

## 3. Scheduling policy

### 3.1 Ready-work rule

An implementation unit enters the ready queue only when:

1. every predecessor in the dependency graph is implemented;
2. every predecessor has passed its local positive, negative, and invariant trials;
3. the unit's detailed design has no unresolved decision affecting its representation contract.

Among ready units, use this priority:

1. shared compiler/runtime substrate;
2. representation core with the greatest number of downstream consumers;
3. reusable generated backend;
4. nonterminal public trait implementation;
5. terminal public structure or representation.

Work proceeds one section at a time in the order given by §6–§37.

### 3.2 What “accepted” means

A unit is accepted only when:

- its public and internal Silica types match the detailed design;
- it compiles through the normal compiler and standard-library build;
- its success, empty, duplicate, invalid-input, and incompatibility paths are tested;
- `validate` accepts generated valid values and rejects deliberately malformed test fixtures where fixtures can be constructed safely;
- persistence tests prove old roots remain observable after updates;
- allocation tests prove nodes use the correct canonical arena;
- no test relies on a removed implementation or removed trial.

### 3.3 Leaf-last rule

The following are terminal leaves in the Phase 1 dependency graph and must not be used to bootstrap their own prerequisites:

- `SearchTree`;
- `PriorityQueue`;
- `Tree`;
- CSR graph snapshots;
- dense matrix graphs.

Their trait declarations may be parsed earlier as compiler fixtures, but their complete generated modules and conformance trials belong in the terminal layers.

`BinaryTree` is not scheduled as a terminal unit here because its accepted backend unlocks the separately gated compiler-AST migration. That downstream migration does not gate standard BinaryTree acceptance.

### 3.4 Serial execution rule

Sections §6–§41 define one direct implementation sequence. Do not begin section *n* until every predecessor §*m* (*m* < *n*) has passed its exit gate.

Bootstrap compiler retirement (§11–§13) runs after the minimal WBT public backends (§9–§10) and before the remaining representation cores (§15 onward). This is a **safe dual-path transition**: `silica-bootstrap-compiler` and the current compiler tree `compiler/src/` stay **untouched** as the production default until cutover; self-host edits land only in a parallel tree (`src/`). That parallel tree becomes alias-free and BST-free, then builds via `build-selfhost`, then fixed-point integrate gates promotion and bootstrap retirement. Detailed step lists for §11–§13 live in [bootstrap_retirement_and_self_host_plan.md](bootstrap_retirement_and_self_host_plan.md).

## 4. Dependency graph

```text
Language/runtime substrate
├── canonical arena registry and construction
├── exact function-value ordering identity
├── recursive tuples, ref?, and alloc_rec
├── traits, provided methods, and constructor records
├── collection type witnesses and generated-module registry
├── checked int64 arithmetic
└── runtime-sized immutable buffers
    │
    ├── WBT core
    │   ├── wbt_set ── OrderedSet ── SearchTree                     [leaf]
    │   ├── wbt_map ── OrderedMap
    │   └── live WBT graph core
    │       ├── DirectedGraph live module
    │       ├── UndirectedGraph live module
    │       └── WeightedGraph live modules
    │           └── CSR freeze modules                              [leaf]
    │
    ├── immutable List + skew binary random-access-list core
    │   ├── Tree                                                     [leaf]
    │   └── dense graph modules                                     [leaf]
    │
    ├── immutable List + Brodal–Okasaki core
    │   ├── Heap
    │   └── PriorityQueue                                           [leaf]
    │
    └── persistent fixed-arity binary-tree core
        └── tree_binary ── BinaryTree
            └── compiler AST bridge / migration                     [separate bootstrap-retirement plan]

WBT indexes + graph traits + random-access-list core
└── dense graph modules                                             [leaf]

WBT from_sorted + live graph modules + runtime-sized buffers
└── CSR freeze modules                                              [leaf]
```

The CSR/dense representation decision is closed:

```text
compiler-version-private structural layouts
├── public vertex IDs: NodeIdType; internal slots: distinct int64 domain
├── runtime-sized internal extents, absent from public graph type parameters
├── CSR: parallel neighbor and attributed/weighted edge-data buffers
├── dense: boolean unweighted cells; one tagged attributed/weighted cell sequence
└── distinct WBT, CSR, and dense concrete generated types
```

These decisions are implementation inputs, not an additional scheduling barrier.

## 5. Layer summary


| Layer | Implementation units                                   | Hard dependencies               | Unlocks                                |
| ----- | ------------------------------------------------------ | ------------------------------- | -------------------------------------- |
| 0     | baseline, design freeze, trial harness                 | detailed designs                | controlled implementation              |
| 1     | compiler/runtime substrate                             | Layer 0                         | every representation                   |
| 2     | WBT, skew RAL, Brodal–Okasaki, binary-tree cores       | Layer 1                         | all generated backends                 |
| 3     | `wbt_set`, `wbt_map`, ordered traits, Heap, BinaryTree | relevant Layer 2 core           | search, graphs, PQ, AST migration      |
| 4     | live WBT graph core and graph traits/modules           | WBT set/map                     | weighted and snapshot graphs           |
| 5     | `SearchTree`, `PriorityQueue`, `Tree`                  | their complete branches         | terminal API completion                |
| 6     | CSR and dense graph modules                            | graph/index/buffer dependencies | representation completion              |
| 7     | full integration and hardening                         | all prior layers                | Phase 1 completion                     |


Layers group related work conceptually. After §8, sections §9–§37 are strictly serial.

## 6. Layer 0 — Establish the implementation baseline

### 6.1 Confirm normative inputs

**Baseline artifact:** `[standard_data_structures_baseline/normative_inputs.md](standard_data_structures_baseline/normative_inputs.md)` (recorded 2026-06-29).

Record the current revisions of:

- both parent design documents;
- every file in `data_structure_designs/`;
- recursive tuple and runtime-sized-buffer language designs;
- compiler collection type-witness and trait behavior.

Do not copy behavior from deleted source or deleted trials. The reset is the baseline.

### 6.2 Create a fresh trial hierarchy

**Trial root:** `[trials/ordered_data_structures/](../../../trials/ordered_data_structures/)` (created 2026-06-29 as `trials/standard_data_structures_phase1/`; since renamed; see `[README.md](../../../trials/ordered_data_structures/README.md)`). Implementation status (2026-10-16): the leaves with trials are `compiler_substrate`, `wbt_core`, `skew_ral_core`, `brodal_okasaki_core`, `binary_tree_core`, `ordered_collections`, `heap_collections`, `tree_collections`, `search_tree_collections`, `graph_live_core`, `graph_csr_core`, `graph_dense_core`, `graph_collections` and `self_host_maps`. `live_graphs`, `terminal_structures`, `snapshot_graphs` and `cross_representation` hold only `smoke_harness_ready`; `binary_tree/` was never created (its coverage lives in `binary_tree_core/`); compile-fail trials live in `trials/error_enforcement_addition/standard_data_structures/` rather than an `error_enforcement/` leaf.

Create a new Phase 1 trial root organized by dependency rather than by public structure alone:

```text
trials/ordered_data_structures/   (layout as planned; see the status above for what exists)
├── compiler_substrate/
├── wbt_core/
├── skew_ral_core/
├── brodal_okasaki_core/
├── binary_tree_core/
├── binary_tree/
├── ordered_collections/
├── live_graphs/
├── terminal_structures/
├── snapshot_graphs/
├── error_enforcement/
└── cross_representation/
```

Each directory must have normal compile/run integration and must distinguish:

- expected compile success;
- expected compile failure;
- expected runtime success;
- expected deterministic runtime collection error.

### 6.3 Create a requirements-to-trials ledger

**Ledger artifact:** `[standard_data_structures_baseline/requirements_to_trials_ledger.md](standard_data_structures_baseline/requirements_to_trials_ledger.md)` (recorded 2026-06-29).

For every numbered design section, record at least one of:

- implementing source unit and trial;
- compile-time-only assertion;
- explicitly non-executable mathematical invariant;
- out-of-scope marker copied from the design.

The ledger prevents apparently complete modules from omitting failure or compatibility behavior.

The 2026-07-02 BinaryTree amendment adds coverage for `persistent_binary_tree.md` and `binary_tree_trait.md`. Its planned trial leaves are `binary_tree_core/` for Layer 2 invariants and `binary_tree/` for Layer 3 trait/module acceptance. Implementation status (2026-10-16): both are covered in `binary_tree_core/`; `binary_tree/` was not created. This amendment does not change the recorded 2026-06-29 baseline snapshot.

### 6.4 Record the closed CSR/dense representation contract

**Contract artifact:** `[standard_data_structures_baseline/csr_dense_representation_contract.md](standard_data_structures_baseline/csr_dense_representation_contract.md)` (recorded 2026-06-29).

**Ledger rows:** `[requirements_to_trials_ledger.md](standard_data_structures_baseline/requirements_to_trials_ledger.md)` §6.4 (`CSR-D1` … `CSR-D7`).

The requirements-to-trials ledger must record:

- compiler-version-private inline layouts that generated modules may inspect but user source may not;
- public `NodeIdType` vertex IDs translated to a distinct internal `int64` dense-slot domain;
- runtime-sized internal extents that do not participate in public graph type identity;
- parallel CSR neighbor and edge-data buffers for attributed/weighted forms;
- one boolean dense cell sequence for unweighted forms;
- one `:none | (:some, EdgeDataType)` dense cell sequence for attributed/weighted forms;
- distinct concrete WBT, CSR, and dense generated types, including their attributed/weighted specializations.

### Layer 0 exit gate

- The new trial root builds even while empty or with smoke fixtures. **Verified:** `make integrate` passes (`trials/standard_data_structures_phase1/`, 2026-07-06, `118 0`).
- Every detailed design section appears in the coverage ledger.
- No new file imports or references a removed implementation.
- The closed CSR/dense representation contract appears in the coverage ledger.

## 7. Layer 1 — Implement the compiler and runtime substrate

This layer is the deepest dependency. No representation core starts until its relevant substrate trials pass.

### 7.1 Canonical arena registry

Implement the common constructor allocation rule:

- one canonical application-lifetime arena per generated representation specialization and memory space;
- repeated construction of that specialization resolves the same arena identity;
- different representation specialization, item/key/value/edge-data specialization, or memory space resolves a different canonical arena where the design requires it;
- collection values carry the arena capability needed by recursive nodes;
- updates allocate replacement nodes in the collection's arena;
- cross-value operations compare arena identity when they may make one result reference both operands.

Compiler/runtime work includes:

- a stable specialization key;
- application-lifetime arena creation and lookup;
- constructor lowering that requests the canonical arena rather than allocating an arena per call;
- emitted arena identity comparison for meld and subtree-sharing checks;
- deterministic diagnostics for a missing or mismatched canonical arena.

Acceptance trials:

- two constructor calls for the same specialization share an arena;
- different spaces do not share an arena;
- different concrete specializations do not alias accidentally;
- WBT path copying, heap meld, and tree subtree insertion can later consume the same primitive contract;
- application shutdown, not collection reachability, defines arena lifetime.

**§7.1 status (2026-07-06):** Complete — runtime registry (`canonical_arena_runtime_asm.silica`), Silica prims (`canonical_arena_lookup`, `canonical_arena_same`), and acceptance trials in `compiler_substrate/` (`canonical_arena_reuse`, `canonical_arena_different_space`, `canonical_arena_different_specialization`). Constructor arena lowering at collection let-bindings delivered in §7.5. **Integrate verified:** `compiler_substrate/` `60 0`; phase-1 root `118 0`.

### 7.2 Exact function-value ordering identity

Implement the ordering provenance required by all ordered structures:

- a top-level function has canonical symbol identity;
- a closure identity contains exact code identity and exact captured-environment instance identity;
- two separately created closures are incompatible even when captures and behavior compare equal;
- a comparator bundle includes every ordering-relevant function value named by the detailed design;
- min/max orientation is part of heap ordering identity;
- no programmer-provided identity override exists.

Provide compiler/SIR/emitter support to:

- materialize a non-forgeable identity token for an exact function value;
- compare identity tokens without invoking the function;
- retain captured environments for at least as long as any collection carrying their identity;
- include ordering identity in generated collection values without exposing a public customization field.

Acceptance trials:

- repeated references to one top-level comparator are compatible;
- one closure value copied into two constructor records is compatible;
- two separately evaluated closure expressions are incompatible;
- min and max orientations are incompatible;
- meld and subtree sharing reject incompatible identity before allocating a result.

**§7.2 status (2026-07-06):** Complete (substrate) — runtime ordering identity (`ordering_identity_runtime_asm.silica`), Silica prims, closure `.__oid_env` side bindings, and substrate acceptance trials in `compiler_substrate/` (`ordering_identity_top_level`, `ordering_identity_closure_copy`, `ordering_identity_closures`, `ordering_identity_orientation`, `ordering_identity_meld_reject`). **Compiler-path bundle embedding:** complete in §7.9 (`collection_constructor_calls.silica` — side-let materialization of `{field}_ordering_bundle` on named constructor bindings). **Integrate verified:** `compiler_substrate/` `60 0`; phase-1 root `118 0`. **Remaining §7.2 acceptance (Layer 2+):** representation-core internal record shape (Layer 2 step 1 per track); meld/subtree rejection before allocation — §16 step 4/9 and exit gate (primitive/bootstrapped meld), re-verified at §19.

### 7.3 Recursive tuples and references

Implement the recursive structural encoding used by every core:

- parser support for recursive tuple declarations and recursive positions;
- `ref?` or the exact optional recursive-reference syntax selected by the language design;
- `alloc_rec` in the canonical arena;
- type equality with an occurs check;
- recursive record field projection;
- SIR representation;
- emitter layout, alignment, and reference operations;
- `:none` as the empty recursive position.

Acceptance trials:

- a one-node recursive value allocates and can be read;
- a multi-node structure traverses through optional references;
- type mismatch at a recursive position fails at compile time;
- malformed unguarded recursion fails deterministically;
- recursive nodes can contain function values, `List` values, and other recursive references needed by the three cores.

**§7.3 status (2026-07-06):** Complete — all acceptance trials pass (`recursive_tuple_alloc_fixture`, `recursive_tuple_multi_node`, `recursive_tuple_fn_in_node`, `recursive_tuple_list_in_node`, compile-fail mismatch + unguarded `rec` in `error_enforcement/`). Emitter uses the `alloc_ref` allocation path for `alloc_rec` (semantically equivalent per spec). **Integrate verified:** `compiler_substrate/` `60 0`; `error_enforcement/` `16 0`; phase-1 root `118 0`.

### 7.4 Trait dispatch and provided methods

Complete the trait machinery required by the parent design:

- first-argument receiver dispatch;
- `required` and `provided` methods;
- provided bodies calling only trait methods and ordinary public functions;
- associated placeholders for item, key, value, node ID, edge data, weight, priority, and memory space;
- exact structural matching of an implementation to a trait;
- deterministic ambiguity and missing-method diagnostics;
- generated link-name mangling that separates concrete specialization, trait, method, and memory space.

Acceptance trials:

- one concrete WBT-set fixture implements two independent traits;
- a provided `contains`-style method calls the required fold hook;
- a generated module may override a provided method;
- wrong receiver type, unresolved placeholder, ambiguous implementation, or missing required method is rejected;
- two specializations do not collide at link time.

**§7.4 status (2026-07-06):** Complete — compiler fixes: multi-param `first_param_type` in provided-method specialization (`trait_specialization.silica`); `fn(...)` vs `(T1,T2) -> R` unification at trait call sites (`function_types_compatible` in `call_site_actual_matches_formal`); assoc-type placeholder resolution extended; explicit-impl override skip for provided specialization; `leaf.mk` links `lib/*.o` with entrypoints (traits_addition pattern). Trials: `trait_dispatch_provided_fold_contains`, `trait_dispatch_dual_trait_record`, `trait_dispatch_override_provided`, `trait_dispatch_link_mangle_specializations`; compile-fail `trial_compile_fail_trait_dispatch_no_impl`, `trial_compile_fail_trait_assoc_unresolved`, `trial_compile_fail_trait_missing_required_impl`. **Integrate verified:** `compiler_substrate/` `60 0`; `error_enforcement/` `16 0`; phase-1 root `118 0`.

### 7.5 Constructor function-record resolution

Implement constructor selection by:

- collection type witness;
- exact inline function-record shape;
- memory-space witness;
- generated representation family.

Cover all public families:

- `OrderedSet`;
- `OrderedMap`;
- `SearchTree`;
- `DirectedGraph`;
- `UndirectedGraph`;
- `WeightedGraph`;
- `Heap`;
- `PriorityQueue`;
- `Tree`;
- `BinaryTree` (added by the §7.10 constructor-record delta).

Acceptance trials:

- field order does not change structural record meaning if Silica records are order-independent;
- a missing, extra, or wrongly typed function field rejects the constructor;
- `EdgeDataType` remains separate from the internal `{to, data}` wrapper;
- unweighted graph convenience construction resolves `EdgeDataType = unit`;
- constructor lowering obtains the canonical arena.

**§7.5 status (2026-07-06):** Complete — extended `type_checker_collections.silica` for all nine public families (parse/validate/witness/return-accept); exact constructor-record field validation (missing/extra fields → E2017; witness/type mismatch → E2003/E2017); Heap uses `compare_item` (not `compare_priority`); module/representation matching; `collection_specialization_key/2`; SIR arena injection at constructor let-bindings (`collection_constructor_calls.silica`); int64 literal-pool collection through `case` branches (`int64_literal_pool.silica`, fixes arena-key compare emission). Stub modules in `compiler_substrate/lib/Stub*`. Positive trials in `compiler_substrate/`: `constructor_record_resolution`, `constructor_record_field_order`, `constructor_canonical_arena_lowering`. Compile-fail goldens in `error_enforcement/`: `trial_compile_fail_constructor_missing_field`, `trial_compile_fail_constructor_extra_field`, `trial_compile_fail_constructor_witness_mismatch`, `trial_compile_fail_constructor_wrong_module`. **Type-check exit gate verified.** Runnable constructor lowering and end-to-end `@empty` trials — Layer 1 §7.9. **Integrate verified:** `compiler_substrate/` `60 0`; `error_enforcement/` `16 0`; phase-1 root `118 0`.

### 7.6 Collection type witnesses and registry

Extend parsing, type checking, code generation, and module registration to every public and concrete generated family. The registry must be representation-based, not type-width-based.

The registry must distinguish:

- public behavior trait;
- concrete generated record type;
- construction/update module;
- representation orientation or directedness;
- all type and memory-space parameters.

Acceptance trials:

- every bracketed public type form parses and type-checks;
- every concrete generated representation has one stable internal identity;
- unrelated records with coincidentally similar fields do not acquire collection behavior accidentally;
- emitted module/link names remain distinct across min/max, directed/undirected, weighted/unweighted, and memory spaces.

**§7.6 status (2026-07-06):** Complete — extended `type_checker_collections.silica` with representation-based registry: `representation_id_from_module/1`, `is_registered_construction_module/1`, `public_trait_family_tag/1`, `bind_type_has_collection_runtime_fields/1`; stable `collection_specialization_key/2` formula `(family × 16777216) + (rep × 65536) + (st × 256) + tp` covering all nine public families, memory spaces, and multi-param type tags (map/graph/priority-queue); min/max heap distinguished (`StubHeap` rep 6, `StubHeapMax` rep 9). Constructor lowering gated to registered modules plus collection bracket types or explicit runtime-field records (`collection_constructor_calls.silica`, `type_checker_expressions.silica` E2017 for unregistered modules); arena/spec-key injection in function-body and `sequence proc` let paths (`terms.silica`). Positive trials in `compiler_substrate/`: `collection_bracket_type_parse`, `collection_registry_specialization_distinct`, `collection_record_not_collection`. Compile-fail goldens in `error_enforcement/`: `trial_compile_fail_collection_bracket_missing_mem`, `trial_compile_fail_collection_unregistered_module`. Distinct link names covered by §7.4 trial `trait_dispatch_link_mangle_specializations`. **Exit gate verified:** `make integrate` passes in `compiler_substrate/` (`60 0`) and `error_enforcement/` (`16 0`); phase-1 root `118 0`. Full constructor runtime lowering and ordering-bundle injection at let sites — Layer 1 §7.9.

### 7.7 Common result and error plumbing

Implement common conventions once:

- lookup status atoms are exactly `:not_found | :found`;
- the found payload remains a separate returned field or tuple member;
- no named option/result type is introduced for ordinary lookup;
- comparator calls accept only `:less | :equal | :greater`;
- a different comparator atom yields deterministic `:invalid_comparator_result`;
- incompatible orderings, arenas, indexes, capacities, and overflow have distinct deterministic errors as specified by the designs.

**§7.7 status (2026-07-06):** Complete — tightened `comparator_return_type_ok/1` in `type_checker_collections.silica` to require `:less | :equal | :greater` (bare `atom` rejected at constructor witness and declaration sites); added `validate_collection_result_type_declaration/2` and `validate_lookup_result_record_type/2` for lookup-result records whose `status` field is exactly `:not_found | :found`. Runtime builtins `comparator_result_valid/1` and `comparator_result_validate/1` wired through type checker, SIR (`collection_result_calls.silica`), and emitter (`prims_collection_result.silica`); invalid comparator atoms map to `:invalid_comparator_result`. Positive trials in `compiler_substrate/`: `comparator_result_valid`, `comparator_result_validate`, `collection_lookup_status_shape`. Compile-fail goldens in `error_enforcement/`: `trial_compile_fail_comparator_bare_atom`, `trial_compile_fail_lookup_status_union`. Stub modules and constructor trials updated to declare comparator functions as `fn(T, T) -> :less | :equal | :greater`. **Exit gate verified:** `make integrate` passes in `compiler_substrate/` (`60 0`) and `error_enforcement/` (`16 0`); phase-1 root `118 0`. Bullet 6 above is a design-wide summary: overflow and capacity checks are §7.8; incompatible ordering/arena meld and index behavior are Layer 2+ representation work (often `compatible: boolean`, `:not_found`, or validate `{valid, error, …}` rather than one shared compiler hook).

### 7.8 Checked arithmetic and runtime-sized buffers

Provide shared checked `int64` operations for:

- `size + 1`;
- subtree-size sums;
- edge and adjacency counts;
- `n * n`;
- prefix sums;
- buffer byte sizes and alignment;
- random-access-list weights;
- heap rank/size calculations.

Harden the existing runtime-sized immutable-buffer path needed later by CSR:

- runtime capacity survives type checking and lowering;
- exact element type and alignment are preserved;
- allocation rejects negative or overflowing sizes;
- freeze construction can fill a fresh buffer before publishing an immutable graph value;
- no completed snapshot performs in-place growth.

**§7.8 status (2026-07-06):** Complete — checked `int64` builtins `checked_int64_add`, `checked_int64_mul`, `checked_int64_add1`, and `checked_int64_byte_size` return `(boolean, int64)` and reject signed overflow via runtime helpers (`checked_int64_runtime_asm.silica`, `prims_checked_int64.silica`); wired through type checker, SIR (`checked_int64_calls.silica`), and emitter. Buffer hardening in `prims_memory.silica`: `alloc_buf` uses element-size-aware byte counts, rejects negative `N` and multiplying overflow, preserves element type from `buf(R, Space, T, N)` in SIR; `read_buf`/`write_buf`/`buf_load`/`buf_store` emit software bounds checks from runtime capacity metadata in SIR (`memory_region_calls.silica` `|bounds:` encoding). Positive trials in `compiler_substrate/`: `checked_int64_overflow`, `runtime_buf_dynamic_size`. **Integrate verified:** `compiler_substrate/` `60 0`; phase-1 root `118 0`. CSR freeze-fill immutability and §30 CSR-specific overflow trials remain Layer 6 work.

### 7.9 Constructor runtime lowering and ordering-bundle injection

Complete the compiler-side work required to close §7.2 (bundle embedding) and finish §7.5/§7.6 constructor lowering:

- every registered collection constructor let lowers through `build_collection_constructor_lets` without falling back to a plain let when the callee return type is known;
- function values in constructor records lower to runnable SIR at every let site (function body, `sequence proc`, and top-level);
- merged runtime records include materialized ordering-identity bundles (`ordering_identity_bundle_make`) for every ordering-relevant function field named by the family design;
- merged records retain canonical-arena lookup, specialization key, and stub-module field projection from §7.6;
- §7.5 constructor acceptance trials run end-to-end (parse → typecheck → SIR → emit → link → run), not typecheck-only helpers.

Acceptance trials (`compiler_substrate/`):

- `constructor_canonical_arena_lowering`, `constructor_record_field_order`, and `constructor_record_resolution` pass as runnable programs;
- at least one `@empty` run trial per stub family (`StubWbtSet`, `StubWbtMap`, `StubHeap`, …) through full pipeline;
- ordering bundles on merged constructor records are observable via test-only assertions (extends ordering-identity substrate trials).

**Dependencies:** §7.2 prims, §7.5/§7.6 registry and merge (`collection_constructor_calls.silica`), §7.7 comparator return types. **Blocks:** Layer 2 core work that constructs values through public `@empty` rather than internal test hooks.

**§7.9 status (2026-07-06):** Complete — `collection_constructor_calls.silica` lowers registered constructor lets through `build_collection_constructor_lets` (key → arena → raw → bundle side-lets → merge → bind); arena lookup uses keyed `var_ref`; bundles materialize via `{field}_ordering_bundle` side bindings with raw/key re-anchor lets (named bindings only; `_` discard skips bundle injection); module-scoped ordering-field list when bind type is an explicit runtime record. Positive trials in `compiler_substrate/`: `constructor_canonical_arena_lowering`, `constructor_record_field_order`, `constructor_record_resolution` (runnable end-to-end); `constructor_stub_empty_run` (all nine stub `@empty` paths); `constructor_ordering_bundle` (bundle field observable on merged records). **Integrate verified:** `compiler_substrate/` `60 0`; `error_enforcement/` `16 0`; phase-1 root `118 0`. **Layer 1 exit gate** satisfied for §7.1–§7.9 substrate criteria; proceed to §8.

### 7.10 BinaryTree family registration delta

**Amendment date:** 2026-07-02.
**Dependencies:** completed §§7.1, 7.3–7.9.
**Blocks:** BinaryTree core §17 and public backend §20 only. It does not invalidate the accepted nine-family substrate or block their already-ready representation tracks.

Extend the completed collection substrate for the tenth public family:

- parse and validate `BinaryTree[ItemType, mem(SpaceType)]`;
- recognize `BinaryTreeType` where trait associated placeholders require a receiver-family witness;
- register the `tree_binary` generated module and a `StubBinaryTree` substrate module;
- allocate distinct family and representation IDs without changing any existing ID;
- include item specialization and memory space in the stable specialization key;
- accept the constructor record `{ compare_item: fn(ItemType, ItemType) -> :less | :equal | :greater }` for `empty` and `with_root` (decision 2026-10-16: the record is not `{}`; the function field is the `ItemType` witness, stored in the tree record and never called by the core);
- witness `ItemType` from the `compare_item` field, `SpaceType` from the declared result type and, for `with_root`, the explicit root item;
- reject `empty({ compare_item: ... })` when the expected collection type does not determine `SpaceType`;
- reject `{}` (E2017) and every extra field in the constructor record;
- lower constructor lets through the canonical arena/spec-key merge path;
- carry no comparator, extractor, orientation, or ordering-identity bundle for this unordered family; and
- preserve the rule that an unrelated coincidentally shaped record or unregistered module does not acquire BinaryTree behavior.

The witness-only `compare_item` field is a deliberate adaptation of the common constructor-function-record rule: BinaryTree reads no ordering from it, but it follows the same record shape as every other family. Existing ordered-family lowering and bundle materialization must remain byte-for-byte behaviorally unchanged.

Acceptance trials (`compiler_substrate/`):

- `binary_tree_bracket_type_parse`: every supported item shape and memory space parses and type-checks;
- `binary_tree_empty_constructor_record`: `empty({ compare_item })` resolves from its binding type and `with_root({ compare_item }, item)` agrees with the explicit item witness;
- `binary_tree_registry_specialization_distinct`: item and space specializations receive distinct keys while repeated construction reuses one canonical arena;
- `binary_tree_stub_run`: runnable `StubBinaryTree@empty` and `@with_root` paths traverse parse → typecheck → SIR → emit → link → run;
- `binary_tree_constructor_no_ordering_bundle`: the merged record contains arena/spec-key fields and the witness-only `compare_item`, and no fabricated ordering token or bundle;
- existing nine-family constructor, bundle, registry, and link-mangling trials remain unchanged and green.

Compile-fail trials (`error_enforcement/`):

- `trial_compile_fail_binary_tree_empty_unwitnessed`;
- `trial_compile_fail_binary_tree_constructor_extra_field`;
- `trial_compile_fail_binary_tree_item_witness_mismatch`;
- `trial_compile_fail_binary_tree_wrong_module`;
- `trial_compile_fail_binary_tree_missing_mem`.

**§7.10 exit gate:** BinaryTree has a stable bracket witness, family/representation identity, `{ compare_item }` constructor resolution, runnable canonical-arena lowering, and deterministic negative diagnostics; the full Phase 1 root integrates with all prior Layer 1 trials.

**§7.10 status (2026-10-16):** Partially met; the remainder is not scheduled. The type checker parses `BinaryTree[ItemType, mem(SpaceType)]` (`type_checker_collections.silica`, `type_interner.silica`), and `binary_tree_core/binary_tree_bracket` exercises it as a return type, a binding and a trait-call receiver. §17 and §20 were implemented without the rest of this delta: there is no `StubBinaryTree`, none of the `compiler_substrate/` trials `binary_tree_*` above and none of the five `trial_compile_fail_binary_tree_*` trials exist, and the constructor record is `{ compare_item }` by decision (2026-10-16), not `{}`. `tree_binary@empty` takes `{ compare_item }` (a witness the core never calls and that produces no ordering bundle) because a bare `ItemType` resolves only from a `compare_*` field of the constructor record (`tree_binary.silica` header, deviation 1).

### Layer 1 exit gate

The historical nine-family Layer 1 gate is complete after §§7.1–§7.9. The amended ten-family suite is complete only after §7.10 also passes and the criteria below hold:

- Every substrate acceptance trial passes in each supported memory space.
- At least one minimal hand-written recursive fixture passes through parse, type check, SIR, emission, link, and run.
- Exact function identity and canonical arena identity are independently observable through test-only assertions.
- All original nine constructor-record shapes resolve against stub concrete modules at type-check time.
- The historical nine-family gate remains accepted; the amended ten-family suite is complete only after §7.10 adds runnable `StubBinaryTree` construction and `{ compare_item }` constructor-record enforcement.
- **§7.9:** at least one runnable `@empty` trial per stub family; no registered constructor let falls back to plain let when merge lowering applies; merged constructor records carry ordering-identity bundles for ordering-relevant fields (completes §7.2 bundle embedding on the compiler path).
- No representation algorithm has been used to compensate for missing compiler support.

**Re-verified (2026-07-07, through the §8A.3 WBT smart-node gate):** `make integrate` — `compiler_substrate/` `60 0`, `error_enforcement/` `16 0`, `wbt_core/` `36 0`, seven Layer 0 smoke leaves `14 0`, phase-1 root `126 0`. This verification accepts WBT §§8A.1–§8A.3 only; balance, update, deletion, bulk construction, validation, and public trait wiring remain later gated work.

## 8. WBT representation core

**Dependencies:** Layer 1 substrate (§§7.1–7.10).

The Adams-family WBT core (§8A) is the first representation package after Layer 1. Sections §9 onward follow in strict serial order.

## 8A. Corrected Adams-family WBT core

**Dependencies:** canonical arenas, exact comparator identity, recursive tuples, checked arithmetic.
**Downstream consumers:** set, map, search tree, every graph family, CSR/dense node indexes.

**Normative design:** `[data_structure_designs/weight_balanced_tree.md](data_structure_designs/weight_balanced_tree.md)`.
**Coverage ledger:** `[standard_data_structures_baseline/requirements_to_trials_ledger.md](standard_data_structures_baseline/requirements_to_trials_ledger.md)` rows for `weight_balanced_tree.md` §§1–16.
**Trial leaf:** [trials/ordered_data_structures/wbt_core/](../../../trials/ordered_data_structures/wbt_core/) (formerly `trials/standard_data_structures_phase1/wbt_core/`).
**Implementation boundary:** compiler-private WBT implementation unit(s) under `stdlib/data_structures/`; public trait wiring is §9–§10.

The implementation is split into the gated work packages below. Complete them in order. A later package may add a trial for an earlier helper, but it may not compensate for an earlier gate that is still failing.

For each completed package:

1. add its positive, runtime-error, and malformed-fixture trials;
2. run `make record-golden` and `make integrate` in `trials/standard_data_structures_phase1/wbt_core/`;
3. run the Phase 1 root `make integrate` before marking the package complete;
4. replace the package's planned status with a dated `**§8A.n status:** Complete — ...` record in the same style as Layer 1; and
5. replace the corresponding planned entries in the requirements-to-trials ledger with the landed artifact names.

Do not import an implementation from a removed standard-data-structure trial or from the obsolete B-tree families. The detailed WBT design, not historical source, is authoritative.

### 8A.1 Representation, empty roots, and specialization state

Implement the two logical recursive node shapes:

- set node: `(key, size, left, right)`;
- map node: `(key, value, size, left, right)`.

At every actual Silica boundary, repeat the complete inline recursive tuple shape; the expository names above do not create aliases or named node types. Both child positions are `ref?` values in the collection's canonical arena, and `:none` is the only empty-root/empty-child representation.

Define the compiler-private owning records used by the core trials. They must preserve:

- the canonical `region` supplied by Layer 1 constructor lowering;
- the optional root;
- the exact placement comparator function value;
- its materialized ordering-identity bundle;
- every specialization field required by the representation registry; and
- no public trait vtable or alternate mutable root.

Set and map shapes must remain distinct specializations. `ItemType`, `KeyType`, `ValueType`, and `SpaceType` remain inferred parameters; no example scalar type may leak into the implementation. Empty construction has logical size zero and allocates no WBT node. Singleton construction uses the smart constructor delivered in §8A.3 rather than writing a cached size directly.

Acceptance trials:

- `wbt_empty_representation`: set and map roots are `:none`, report size zero, retain the constructor's arena and exact ordering bundle, and allocate no node;
- `wbt_representation_specializations`: set versus map, different key/value types, and different memory spaces retain distinct concrete specialization identity while repeated construction of one specialization reuses its canonical arena;
- `wbt_generic_payload_shapes`: instantiate at least scalar, `string`, and non-scalar tuple/record payloads without changing the node algorithm;
- extend Layer 1's constructor bundle trial to prove that the bundle entering the real WBT owning record is the bundle produced for the exact comparator value.

**§8A.1 exit gate:** empty set and map core values compile, link, and run through the normal library path; their runtime records carry the Layer 1 arena and ordering state; there is no public leaf module or test-only replacement node representation.

**§8A.1 status (2026-07-06):** Complete — compiler-private `wbt_set.silica` and `wbt_map.silica` in `stdlib/data_structures/` with inline set node `(ItemType, int64, ref?, ref?)`, map node `(KeyType, ValueType, int64, ref?, ref?)`, empty root `:none`, and Layer 1 constructor fields (canonical `region`, `specialization_key`, materialized ordering bundles). Positive trials in `wbt_core/`: `wbt_empty_representation`, `wbt_representation_specializations`, `wbt_representation_string_specialization`, `wbt_generic_payload_shapes`, `wbt_generic_tuple_map_empty`, `wbt_constructor_ordering_bundle`. **Integrate verified:** `wbt_core/` `28 0` (§8A.1 + §8A.2 trials); phase-1 root `118 0`.

### 8A.2 Read-only primitives

Implement allocation-free helpers before any update:

- `size(:none) = 0` and `size(node) = node.size`;
- `weight(tree) = size(tree) + 1`, using checked arithmetic even though a valid node cannot have `size = int64.max`;
- set search/contains and map search/get by the placement comparator;
- minimum and maximum binding lookup for non-empty roots;
- ascending left-node-right fold for both node shapes; and
- any early-exit fold needed by later consumers, with the same ascending visitation order.

Every comparator result is validated at the call site before a branch is chosen. `:less`, `:equal`, and `:greater` are the only accepted results; another atom produces deterministic `:invalid_comparator_result`. Empty search, minimum, and maximum must take their specified empty path without invoking the comparator.

Traversal may be expressed recursively, but a valid balanced tree must not require more than `O(log n)` machine-stack depth. Read-only helpers do not allocate WBT nodes, change the root, or materialize an intermediate collection.

Acceptance trials:

- `wbt_search_contains`: hit and miss at the root, leftmost, rightmost, and internal positions for set and map roots;
- `wbt_minimum_maximum`: correct empty/singleton/multi-node behavior and key/value pairing;
- `wbt_fold_ascending`: exact ascending output, one callback per logical binding, empty-fold identity, and preservation of map values with their keys;
- `trial_collection_error_wbt_search_invalid_comparator`: force an invalid atom on root, left-branch, and right-branch comparisons;
- test-only allocation observations show zero new WBT nodes for successful and unsuccessful searches, min/max, `size`, and folds.

**§8A.2 exit gate:** all read-only helpers pass for both node shapes, visit the required order, reject invalid comparator atoms deterministically, and allocate no WBT node.

**§8A.2 status (2026-07-06):** Complete — read-only helpers implemented and exported in `wbt_set.silica` / `wbt_map.silica`: `size/1`, `weight/1`, `search_status/2`, set `contains/2` and map `get/3` / `contains_key/2`, ascending `fold/3`, `minimum` / `maximum`, and `comparator_result_validate` at every compare site (`contains` / `get` halt on invalid comparator). Trial-only `wbt_trial_fixture` / `wbt_trial_i64` supply multi-node `alloc_rec` fixtures for nonempty acceptance paths. Positive trials in `wbt_core/`: `wbt_read_only_empty`, `wbt_search_contains`, `wbt_minimum_maximum`, `wbt_fold_ascending`, `trial_collection_error_wbt_search_invalid_comparator`, `wbt_read_only_alloc_free`, `wbt_weight_checked`. **§8A.2 exit gate verified:** `wbt_core/` `28 0`; phase-1 root `118 0`. Proceed to §8A.3.

### 8A.3 The sole smart-node construction path

Implement exactly one smart constructor per physical node shape, sharing one size-computation rule:

1. read each child size, using zero for `:none`;
2. compute `left_size + right_size` with `checked_int64_add`;
3. compute the final `+ 1` with `checked_int64_add1`;
4. reject overflow before calling `alloc_rec`; and
5. allocate the immutable tuple in the owning collection's canonical arena.

No insert, replacement, deletion, extraction, rotation, or bulk builder may allocate a WBT node directly. Map construction must move `(key, value)` as one binding. The constructor does not accept a caller-selected cached size.

Add a narrow trial-only malformed-root fixture builder outside the standard library. It may construct impossible cached-size and wrong-arena inputs needed for negative validation and overflow trials; production operations must never call it.

Acceptance trials:

- `wbt_smart_node_size`: leaf and unequal-depth child combinations compute exact cached sizes for set and map nodes;
- `wbt_smart_node_arena`: every new node belongs to the supplied canonical arena and both old children remain readable and unchanged;
- `trial_collection_error_wbt_smart_node_overflow`: synthetic `int64.max` child metadata fails before allocation and publishes no new root;
- emitted SIR/assembly or a test-only allocator observation establishes that every production WBT node allocation is reached through the smart constructor.

**§8A.3 exit gate:** direct production `alloc_rec` sites for WBT nodes exist only inside the smart constructors, overflow is checked before allocation, and cached size cannot be selected by a caller.

**§8A.3 status (2026-07-07):** Complete — the sole smart-node construction path is implemented for both production WBT node shapes in `wbt_set.silica` and `wbt_map.silica`. Each production module still contains exactly one WBT-node `alloc_rec` site, inside the private smart-node finish helper reached from `smart_node`; callers cannot supply a cached size directly. The smart constructors compute child sizes, check the combined size and final `+ 1` before allocation, and allocate the final immutable tuple in the supplied canonical arena.

The prior multi-node hang was fixed at the runtime/compiler boundary rather than by weakening the WBT design. The emitter now preserves simple GPR parameters across non-tail user calls in non-tail function bodies, which keeps `smart_node` payload and child references stable while checked arithmetic helpers run. The private finish-helper ABI now places payload fields before the arena argument, so allocation lowering cannot overwrite tuple-payload materialization with the arena pointer.

The accepted `wbt_core/` gate now explicitly enumerates stable WBT trials so loose development probes cannot accidentally become acceptance artifacts. `check-wbt-alloc-rec-gate` is part of the gate and verifies exactly one production `alloc_rec` site each in `wbt_set.silica` and `wbt_map.silica`.

Accepted §8A.3 artifacts:

- `wbt_smart_node_size`: leaf and unequal-depth child combinations compute exact cached sizes for set and map nodes;
- `wbt_smart_node_arena`: every new node belongs to the supplied canonical arena and existing children remain readable and unchanged;
- `wbt_smart_node_production_path`: production construction reaches the sole smart-node allocation path;
- `trial_collection_error_wbt_smart_node_overflow`: synthetic `int64.max` child metadata fails before allocation and publishes no new root;
- `check-wbt-alloc-rec-gate`: the source-level production allocation-site budget remains one per WBT physical node module.

Goldens were recorded from executing the corrected code path. **§8A.3 exit gate verified:** `wbt_core/` `make positive-integrate` and `make integrate` both pass with `36 0`; Phase 1 root `make integrate` passes with `126 0`. Proceed to §8A.4 balance predicates and rotations.

### 8A.4 `(DELTA, GAMMA) = (3, 2)` balance predicates and rotations

Implement the original WBT weight law exactly:

```text
weight(tree) = size(tree) + 1
balanced iff
    weight(left)  <= 3 * weight(right) and
    weight(right) <= 3 * weight(left)
```

Use an overflow-safe comparison for `a <= 3*b`; wrapped multiplication is not an acceptable predicate. Do not substitute the Adams `ratio = 5` presentation, node-size comparisons, AVL height, or a different WBT parameter pair.

Implement mirrored `balance_left` and `balance_right` paths. For a right-heavy node:

- choose a single left rotation only when `weight(rl) < 2 * weight(rr)`;
- choose a double left rotation when the weights are equal or the inner side is larger.

Use the exact mirror for left-heavy nodes. Equality choosing the double rotation is a normative edge case. Missing heavy children, or missing inner children required by a selected double rotation, are representation violations; do not silently select a different rotation. Every rebuilt node must go through §8A.3.

Acceptance trials:

- `wbt_balance_boundaries`: both balance inequalities immediately below, at, and above the `DELTA = 3` boundary, including synthetic near-overflow sizes;
- `wbt_rotation_single_left` and `wbt_rotation_single_right`: exact root/binding order, cached sizes, and untouched subtree sharing;
- `wbt_rotation_double_left` and `wbt_rotation_double_right`: exact root/binding order, cached sizes, and key/value pairing;
- `wbt_rotation_gamma_equality`: `weight(inner) == 2 * weight(outer)` selects the double rotation in both directions;
- `wbt_rebalance_adversarial`: repeated rotations preserve ascending fold output and pass direct cached-size/balance assertions; §8A.10 later re-runs these fixtures through the production validator;
- malformed fixtures with an absent required heavy/inner child fail deterministically instead of returning a plausibly shaped tree.

**§8A.4 exit gate:** each of the four rotation branches and the `GAMMA` equality edge is directly exercised for set and map bindings; targeted assertions establish cached-size, strict-order, and `(3,2)` balance behavior pending the full-validator recheck in §8A.10.

**§8A.4 status:** Complete.

### 8A.5 Persistent set insertion

Implement insertion returning `{root, inserted}`:

- `:none` allocates one singleton and returns `inserted = true`;
- `:equal` returns the original node and `inserted = false`;
- `:less` and `:greater` recurse into exactly one child;
- a no-change child result returns the original ancestor unchanged; and
- a changed child result rebuilds and rebalances on unwind.

The stored item is canonical for its comparator-equivalence class. A later comparator-equal item must not replace it. Preserve the comparator function, ordering bundle, arena, and registry state when the core operation is wrapped back into an owning test value.

Acceptance trials:

- `wbt_set_insert_duplicate`: duplicate and representationally distinct comparator-equal insertion return `inserted = false`, preserve the canonical stored item, preserve root identity, and allocate no WBT node;
- `wbt_set_insert_orders`: empty, singleton, ascending, descending, alternating-extremes, and median-first input;
- `wbt_set_insert_adversarial`: sequences chosen to exercise every rotation repeatedly and sizes around balance-boundary transitions;
- `wbt_set_insert_persistence`: retain every prior root, then verify its size, fold output, and search results after later updates; §8A.10 later validates the same retained-root fixtures;
- `wbt_set_insert_sharing`: changed paths are copied while untouched child references remain shared;
- `trial_collection_error_wbt_set_insert_invalid_comparator`: invalid results at root and deeper descent publish no result root.

Run the insertion matrix for more than one payload shape and every supported `SpaceType`.

**§8A.5 exit gate:** all insertion shapes pass the directed size/order/balance assertions; duplicate insertion is an identity-preserving zero-node no-op; old roots retain their observable contents; §8A.10 remains responsible for the final full-validator gate.

**§8A.5 status (2026-07-09; stabilized 2026-07-10):** Complete — `wbt_set@insert/2` returns `{set, inserted}` with path-copy rebalance via §8A.3 `smart_node` / `balance_left` / `balance_right`. Duplicate comparator class is a zero-node identity no-op (`inserted=false`). Invalid comparator results halt via `1/0` and publish no result root. Positive trials in `wbt_core/`: `wbt_set_insert_duplicate`, `wbt_set_insert_orders` (int64 matrix), `wbt_set_insert_adversarial`, `wbt_set_insert_persistence`, `wbt_set_insert_sharing`, `wbt_set_insert_payload_shapes` (string payload matrix: singleton/duplicate, ascending, descending, alternating-extremes, median-first; fold digest + min/max/contains). Emitter support: content string `lt`/`gt`/`le`/`ge`/`eq`/`nq` via `L_string_cmp_helper` with X0/X1 preserved across the helper call. SpaceType coverage is pinned in `compiler_substrate/collection_ordered_set_space_matrix`, which asserts distinct OrderedSet specialization keys for `normal`, `normal_writeback`, `normal_writethrough`, `normal_noncacheable`, `atomic`, and `device`. Collection-error: `trial_collection_error_wbt_set_insert_invalid_comparator` (trial-only `wbt_trial_insert_i64@insert_status_i64`). Proceed to §8A.6.

### 8A.6 Persistent map insertion and replacement

Mirror §8A.5 set insertion on the map node shape `(KeyType, ValueType, int64, ref?, ref?)`, then add the replacement branch. Do not invent a second balancing algorithm: unequal descent, path-copy, and rebalance reuse §8A.3 `smart_node` and §8A.4 `balance_left` / `balance_right` exactly as set insert does.

**Normative result shape (compiler-private owning wrap):**

```text
insert(map, key, value) -> { map, inserted, replaced }
```

Flag combinations that may be published:

| Case | `inserted` | `replaced` | size | root identity |
| --- | --- | --- | --- | --- |
| empty / new key | `true` | `false` | `old + 1` | new path-copied root |
| key comparator-equal | `false` | `true` | unchanged | new path-copied root (matched node + ancestors) |
| invalid `compare_key` | — | — | — | no result root published |

`inserted = true ∧ replaced = true` is forbidden. Observationally equal old/new values still replace (`replaced = true`); never suppress replacement by calling `compare_value`.

**Hard invariants (carry from §8A.5):**

- Placement uses only `compare_key` (validated at every call site). `compare_value` must not run on insert, replace, rotate, or key-order checks.
- Canonical key: on `:equal`, keep the **stored** key bytes/representation; install only the new value; preserve both child refs unchanged at the matched node.
- Never keep a live empty `ref?` in a frame that allocates (`smart_node` / balance).
- Do not rebind `map.root` to a node `ref` inside descent helpers (that corrupted retained roots on set insert).
- Exactly one production `alloc_rec` remains inside map `smart_node` finish (`check-wbt-alloc-rec-gate`).
- Prefer small helpers over deep nested `and` / many live locals in one `produces` (emitter/stack hazards).

Complete the steps below in order. A later step may add trials for an earlier helper, but must not leave an earlier step's gate failing.

#### Step 1 — Public export and result wrappers

1. Export `insert/3` from `stdlib/data_structures/wbt_map.silica`.
2. Define private helpers that build the three-field result without nesting large records in one expression:
   - `insert_pair_new(map, root)` → `{map with root, inserted=true, replaced=false}`;
   - `insert_pair_replaced(map, root)` → `{map with root, inserted=false, replaced=true}`;
   - `insert_invalid_halt(...)` → same halt style as set insert (`1/0` / collection-error path) and publish no result root.
3. Owning-record fields copied on every success path: `compare_key`, `compare_value`, `region`, `specialization_key`, both ordering bundles. Only `root` changes.

**Step 1 check:** empty map + one insert compiles and returns a record with all three fields; invalid-comparator halt path is linkable from a trial-only status helper if needed (mirror `wbt_trial_insert_i64`).

#### Step 2 — Empty-root singleton insert

1. When `map.root` is `:none`, allocate one leaf via `smart_node(key, value, :none, :none, region)` (or the map smart-node arity already used in §8A.3).
2. Return `inserted=true`, `replaced=false`, size `1`.
3. Confirm `get` / `contains_key` / `fold` see the single binding and that `compare_value` was never invoked.

**Step 2 check:** trial fragment — empty → insert `(k0, v0)` → size 1, `get(k0)=v0`, flags `{true,false}`.

#### Step 3 — Equal-key replacement at a node (no descent)

1. Read the node tuple; compare `key` to `node_key` with validated `compare_key`.
2. On `:equal`:
   - build a **new** node with `(stored_key, new_value, same_size, same_left, same_right)` through §8A.3;
   - do **not** compare values;
   - do **not** rebalance (children and size unchanged ⇒ already balanced);
   - return that node ref to the caller for ancestor rebuild.
3. Representationally distinct but comparator-equal keys must keep `stored_key`, not the argument key.

**Step 3 check:** singleton map; insert same logical key with new value → size still 1, `get` returns new value, fold/search still report the original key representation, flags `{false,true}`, old root still returns old value.

#### Step 4 — Unequal descent (structural clone of set insert)

1. On `:less` / `:greater`, recurse into exactly one child (empty child ⇒ Step 2 leaf-as-child).
2. If the recursive result reports no structural change is impossible for map insert except via halt; for replacement deeper in the tree, the child root always changes, so ancestors always path-copy.
3. On unwind after a **new-key** insert (`inserted=true`): rebuild the ancestor with the new child via `smart_node`, then `balance_left` / `balance_right` as in §8A.5.
4. On unwind after a **replacement** (`replaced=true`): rebuild the ancestor with the new child via `smart_node`. Size is unchanged along the path; still run the same balance helpers (they must be no-ops when already balanced) so there is one rebuild path.
5. Untouched sibling child refs must be shared (pointer identity), not deep-copied.

**Step 4 check:** multi-node map; insert new key on left and right; insert replacing an internal key; assert size, ascending fold of `(key,value)` pairs, and sibling sharing on the replace path.

#### Step 5 — Wire `insert` top-level

```text
case map.root of
  :none -> singleton (Step 2)
  root_ref -> insert_at_node(map, key, value, root_ref)
```

`insert_at_node`:

1. `read_ref` → `(node_key, node_value, size, left, right)`;
2. validated `compare_key(key, node_key)`;
3. `:equal` → Step 3, wrap with `insert_pair_replaced`;
4. `:less` / `:greater` → Step 4 descend/rebuild;
5. invalid atom → `insert_invalid_halt`.

Keep helper granularity similar to `wbt_set` insert (`insert_at_node_less` / `_greater`, leaf-as-child, finish-rebuild) so live `ref?` and register pressure stay manageable.

**Step 5 check:** export-only smoke — orders matrix on `int64` keys / `string` values (or similar) covering empty, singleton, ascending, descending, alternating, median-first, plus one replace in each shape.

#### Step 6 — Persistence, sharing, and value-pairing stress

1. Retain every prior map root across a sequence of inserts and replaces; each old root must keep its old `get`/`fold` observations.
2. On replace at depth ≥ 1, assert both children of the matched node are reference-identical to the pre-replace children, and that only the path to the root is new.
3. Force single and double rotations (reuse §8A.4 / §8A.5 adversarial key orders) and assert every fold step still yields intact `(key, value)` pairs — never a key with a sibling's value.

**Step 6 check:** dedicated persistence + sharing + rotation-pairing trials below.

#### Step 7 — Prove `compare_value` is unused on placement

1. Construct maps whose `compare_value` traps (e.g. `1/0` or an atom that fails validation) if called.
2. Exercise empty insert, new-key insert, equal-key replace, and rotation-heavy inserts.
3. Success of those paths is the proof; do not “soft-skip” by substituting a benign value comparator in the negative trial.

**Step 7 check:** `wbt_map_compare_value_not_called`.

#### Step 8 — Invalid `compare_key` collection errors

1. Invalid atom at root compare, left descent, and right descent.
2. Input map remains valid and observable; no partial result root is published.
3. Prefer a trial-only `insert_status_*` helper (as in §8A.5) if exporting a status-shaped API would collide with emitter labels or widen the public core surface.

**Step 8 check:** `trial_collection_error_wbt_map_insert_invalid_comparator`.

#### Step 9 — Genericity and SpaceType coverage

1. Instantiate at least two distinct key/value type pairs; include one non-scalar value (tuple or record) where the language permits.
2. Do not rely on `int64`/`int64` alone for the gate.
3. SpaceType specialization keys remain covered by `compiler_substrate/collection_ordered_set_space_matrix` (and map analogue if present); do not block §8A.6 on re-deriving every space if Layer 1 already pins them, but do not hard-code a single space into `insert`.

**Step 9 check:** payload/type matrix trial(s) listed below pass under `wbt_core/` integrate.

#### Step 10 — Gate integration

1. Add positives to `wbt_core/POSITIVE_SILICA` (enumerated list, not probe wildcards).
2. `make record-positive-golden` then `make positive-integrate` / `make integrate` in `wbt_core/`.
3. Re-run `check-wbt-alloc-rec-gate` (still one `alloc_rec` in `wbt_map.silica`).
4. Phase 1 root `make integrate`.
5. Mark this section Complete with dated status and update the requirements-to-trials ledger row for map insertion.

Acceptance trials:

- `wbt_map_insert_replace`: both valid result-flag combinations—`{inserted=true, replaced=false}` and `{inserted=false, replaced=true}`—and an unchanged logical size on replacement;
- `wbt_map_canonical_key`: comparator-equal but representationally distinct keys preserve the first stored key while replacing its value;
- `wbt_map_value_pairing`: single/double rotations and deep path copies never detach a value from its key;
- `wbt_map_compare_value_not_called`: a value comparator that would fail if invoked is not called by any key-placement path;
- `wbt_map_replace_persistence`: the old root retains the old value, the new root has the replacement, and both subtrees of the matched node are shared;
- `wbt_map_insert_orders`: alternating-extremes and median-first order matrices (ascending/descending live in `wbt_map_insert_replace`; split so one process stays within the shared canonical arena budget);
- `trial_collection_error_wbt_map_insert_invalid_comparator`: failure at each descent direction leaves the input root valid and unpublished output inaccessible.

Instantiate keys and values with different concrete types, including at least one non-scalar value.

**§8A.6 exit gate:** map insertion and replacement preserve canonical keys and key/value pairing, report exact flags, never use value comparison for placement, preserve every old version, keep the single smart-node allocation site, and pass `wbt_core/` integrate with the trials above.

**§8A.6 status (2026-07-10):** Complete — `wbt_map@insert/3` returns `{map, inserted, replaced}` with path-copy rebalance via §8A.3 `smart_node` / `balance_left` / `balance_right`. New-key insert reports `{inserted=true, replaced=false}`; equal-key replacement keeps the stored key, installs the new value, preserves both children, and reports `{inserted=false, replaced=true}` without calling `compare_value`. Invalid `compare_key` results halt via `1/0` and publish no result root. Rebuild helpers mirror set insert (`sequence out <- insert_balance_*(map, smart_node(...))`) so `:none` and `child_map.root` lower with preserved callee-saved regs. Positive trials in `wbt_core/`: `wbt_map_insert_replace` (flags + ascending/descending), `wbt_map_insert_orders` (alternating-extremes / median-first; split from replace for shared-arena budget), `wbt_map_canonical_key`, `wbt_map_value_pairing`, `wbt_map_compare_value_not_called`, `wbt_map_replace_persistence`, `wbt_map_insert_payload_shapes` (string→int64), `wbt_map_insert_tuple_value` (int64→`(int64, string)` non-scalar value). `check-wbt-alloc-rec-gate` remains one `alloc_rec` in `wbt_map.silica` (`smart_node_finish_alloc`). SpaceType specialization keys remain covered by Layer 1 / `compiler_substrate/collection_ordered_set_space_matrix` (insert does not hard-code a space). Collection-error: `trial_collection_error_wbt_map_insert_invalid_comparator` (trial-only `wbt_trial_insert_map_i64@insert_status_i64`). Exit gate: `wbt_core/` positive-integrate **84 0**; Phase 1 root integrate **176 0**. Proceed to §8A.7.

### 8A.7 Deletion, extreme extraction, and deletion-side rebalancing

Mirror §8A.5 / §8A.6 update discipline on the delete path. Do not invent a second balancing algorithm: path-copy and rebalance reuse §8A.3 `smart_node` and §8A.4 `balance_left` / `balance_right`. Implement **extreme extraction first** (`delete_min` / `delete_max`); ordinary `delete` of an interior node with two children must call those helpers rather than duplicating spine logic.

**Normative result shapes (compiler-private owning wrap):**

```text
delete(set, item) -> { set, removed }
delete(map, key)  -> { map, removed }

delete_min(set) -> { set, status: :empty | :found, item }
delete_max(set) -> { set, status: :empty | :found, item }
delete_min(map) -> { map, status: :empty | :found, key, value }
delete_max(map) -> { map, status: :empty | :found, key, value }
```

Flag / status combinations that may be published:

| Case | `removed` / status | size | root identity |
| --- | --- | --- | --- |
| empty or absent key/item | `removed=false` / `:empty` on extreme of empty | unchanged | **same** root (zero-node no-op) |
| present leaf / one-child / two-child / root | `removed=true` / `:found` | `old - 1` | new path-copied residual root |
| invalid placement comparator | — | — | no changed root published |

`removed = true` with an unchanged root identity is forbidden. Map deletion always removes the key and its value together; never call `compare_value` on delete, extreme extraction, rotate, or key-order checks.

**Heavier-side / tie rule (two non-empty children, normative):**

- if `size(left) > size(right)`: extract **maximum** from the left (predecessor), splice into the deleted node’s place;
- otherwise (right heavier **or** size tie): extract **minimum** from the right (successor).

**Hard invariants (carry from §§8A.5–§8A.6):**

- Placement / search uses only the set item comparator or map `compare_key` (validated at every call site).
- Never keep a live empty `ref?` in a frame that allocates (`smart_node` / balance); prefer set-style `sequence out <- …` rebuilds when passing `:none` beside a child root field.
- Do not rebind `set.root` / `map.root` to a node `ref` inside descent helpers.
- Exactly one production `alloc_rec` per module remains inside `smart_node` finish (`check-wbt-alloc-rec-gate`).
- Prefer small helpers over deep nested `and` / many live locals in one `produces`.
- On absent recursive results, **copy nothing** on the unwind (return the original ancestor root unchanged).
- After a structural change on the left child, rebuild then `balance_left`; after a change on the right child, rebuild then `balance_right` (same helpers as insert; they are no-ops when already balanced).

Complete the steps below in order. A later step may add trials for an earlier helper, but must not leave an earlier step's gate failing. Implement set and map in parallel within a step when the helper shapes differ only by the value field; do not finish set-only and defer map pairing to a later gate.

#### Step 1 — Public exports and result wrappers

1. Export from `wbt_set.silica`: `delete/2`, `delete_min/1`, `delete_max/1`.
2. Export from `wbt_map.silica`: `delete/2`, `delete_min/1`, `delete_max/1`.
3. Define private helpers that build result records without nesting large owning records in one expression:
   - `delete_pair_removed` / `delete_pair_unchanged` (set and map);
   - `extreme_found_*` / `extreme_empty_*` for min/max results;
   - `delete_invalid_halt(...)` — same `1/0` / collection-error style as insert; publish no changed root.
4. Owning-record fields copied on every success path that publishes a new root: comparators, `region`, `specialization_key`, ordering bundles. Only `root` changes. Unchanged paths must return the **input** owning record (same root identity).

**Step 1 check:** empty set/map + `delete` / `delete_min` compile and return the documented record shapes; invalid-comparator halt path is linkable from a trial-only status helper if needed (mirror `wbt_trial_insert_*`).

#### Step 2 — Set `delete_min` / `delete_max`

1. Empty root → `{set, status=:empty, item=placeholder-or-unused}`; no allocation.
2. Non-empty: walk the left spine (`delete_min`) or right spine (`delete_max`) to the extreme node.
3. Extreme is a leaf or has only the opposite-side child empty: residual is the surviving child (possibly `:none`).
4. On unwind, rebuild each ancestor with `smart_node` and the deletion-side balance helper (`balance_left` after removing from the left spine under a node, `balance_right` after removing from the right spine — match the child that shrank).
5. Return the extracted item and the residual set.

**Step 2 check:** `wbt_delete_extreme` fragments for set — depth-zero singleton; multi-level left/right spines; residual size = old−1; fold/search omit the extracted item; old root still contains it.

#### Step 3 — Map `delete_min` / `delete_max`

1. Same spine / rebuild / balance structure as Step 2 on the map node shape `(KeyType, ValueType, int64, ref?, ref?)`.
2. Extracted binding is always `(key, value)` together; never invent a placeholder value or call `compare_value`.
3. Residual map fold must retain intact pairing for every remaining binding.

**Step 3 check:** map extreme extraction at depth zero and multiple levels; `get` of extracted key is `:not_found` on the new root and `:found` on the old root; fold pairs stay attached after any rotation on the unwind.

#### Step 4 — Absent and empty `delete` (identity no-op)

1. `delete` on empty root → unchanged owning record, `removed=false`, zero WBT node allocations.
2. Unequal descent that reaches `:none` → unwind with **no** `smart_node` / balance; return original root, `removed=false`.
3. Invalid comparator atom at any compare site → halt; input root remains valid and observable.

**Step 4 check:** `wbt_delete_absent` for set and map (empty + missing key in a non-empty tree); root reference identity preserved; no `alloc_rec` beyond whatever the trial fixture already used.

#### Step 5 — Present delete: leaf and one-child cases

1. On `:equal` with both children `:none`: residual at this node is `:none` (parent rebuilds with the empty sibling side).
2. On `:equal` with exactly one non-empty child: residual is that child ref (no new node at the deleted site).
3. On unwind after `removed=true`, ancestors path-copy via `smart_node` + the appropriate `balance_*` for the side that lost weight.
4. Cover deletion of the current tree root when it is a leaf or one-child node (`wbt_delete_root` cases).

**Step 5 check:** `wbt_delete_leaf`, `wbt_delete_one_child`, and matching root cases for set and map; size/order/balance observations; map values remain paired.

#### Step 6 — Present delete: two-child splice via extremes

1. On `:equal` with two non-empty children, apply the heavier-side / tie rule (above).
2. Call Step 2/3 extraction on the chosen subtree to obtain `(replacement_binding, residual_subtree)`.
3. Build the replacement node with `smart_node(replacement_key[, replacement_value], residual_of_extracted_side, untouched_sibling)` — for maps, the spliced key **and** value come from the extracted binding.
4. Then run deletion-side balance on that rebuilt node as if this site’s child weight changed.
5. Prove left-heavier, right-heavier, and equal-size child pairs select predecessor vs successor deterministically.

**Step 6 check:** `wbt_delete_two_child` and `wbt_delete_heavier_side` for set and map; after splice, search/fold omit only the deleted key; replacement key’s value (map) is the extracted binding’s value, not the deleted node’s value.

#### Step 7 — Wire top-level `delete`

```text
case root of
  :none -> unchanged, removed=false
  root_ref -> delete_at_node(...)
```

`delete_at_node`:

1. `read_ref` → node fields;
2. validated comparator vs search key/item;
3. `:equal` → Step 5 or Step 6;
4. `:less` / `:greater` → descend; if child reports `removed=false`, return unchanged ancestor; if `removed=true`, rebuild + balance on that side;
5. invalid atom → `delete_invalid_halt`.

Keep helper granularity similar to insert (`delete_at_node_less` / `_greater`, finish-rebuild) so live `ref?` and register pressure stay manageable. Split large order/delete matrices across trial files if the shared canonical arena budget requires it (same lesson as §8A.6).

**Step 7 check:** export-only smoke covering empty, absent, leaf, one-child, two-child, and root deletion for set and map on at least one scalar payload.

#### Step 8 — Deletion-side rebalance stress

1. Build fixtures (via insert) that, under chosen delete orders, force single and double rotations in both directions, including `GAMMA` equality cases from §8A.4.
2. After each deletion assert size, ascending fold, and direct balance observations (full postorder validator remains §8A.10).
3. Map trials must show key/value pairing survives every rotation on the delete unwind.

**Step 8 check:** `wbt_delete_rebalance` (set + map, or paired trials).

#### Step 9 — Persistence and delete-all permutation

1. Retain every prior root across a sequence of deletions; each old root must keep its old `contains`/`get`/`fold` observations.
2. Deterministic delete-all: insert a known adversarial set/map, delete every key in several fixed orders, check size/order/balance observations after every deletion, finish at `:none`.
3. Amend this trial in §8A.10 to invoke the production validator after every deletion; for §8A.7 use directed size/order/balance assertions only.

**Step 9 check:** `wbt_delete_persistence` plus the delete-all permutation trial (name may be folded into persistence or a dedicated `wbt_delete_all_orders` if arena budget requires a split).

#### Step 10 — Invalid comparator collection errors

1. Invalid atom at root compare, left descent, and right descent for `delete` (and at least one extreme-extraction compare site if extremes compare).
2. Input collection remains valid and observable; no partial/changed result root is published.
3. Prefer trial-only `delete_status_*` helpers if a status-shaped public API would collide with emitter labels.

**Step 10 check:** `trial_collection_error_wbt_delete_invalid_comparator` (set and map coverage, or two tightly scoped trials).

#### Step 11 — Genericity

1. Exercise delete / extremes on more than one payload shape for set (e.g. `int64` and `string`) and for map (e.g. `int64`→`int64` and at least one non-scalar value shape already used in §8A.6).
2. Do not hard-code a single `SpaceType` into delete helpers; SpaceType keys remain covered by Layer 1 / `compiler_substrate/collection_ordered_set_space_matrix`.

**Step 11 check:** payload matrix coverage under `wbt_core/` integrate (dedicated trials or extensions of the structural trials above).

#### Step 12 — Gate integration

1. Add positives to `wbt_core/POSITIVE_SILICA` (enumerated list, not probe wildcards).
2. `make record-positive-golden` then `make positive-integrate` / `make integrate` in `wbt_core/`.
3. Re-run `check-wbt-alloc-rec-gate` (still one `alloc_rec` each in `wbt_set.silica` and `wbt_map.silica`).
4. Phase 1 root `make integrate`.
5. Mark this section Complete with dated status (follow the §8A.5 / §8A.6 status pattern) and update the requirements-to-trials ledger row for deletion / extreme extraction.

Acceptance trials:

- `wbt_delete_absent`: empty and non-empty absence preserve root identity and allocate no WBT node;
- `wbt_delete_leaf`, `wbt_delete_one_child`, `wbt_delete_two_child`, and `wbt_delete_root`: cover each structural case for set and map roots;
- `wbt_delete_extreme`: minimum/maximum extraction at depth zero and multiple levels, with direct residual-tree size/order/balance assertions;
- `wbt_delete_heavier_side`: left-heavier, right-heavier, and equal-size children prove the deterministic predecessor/successor rule;
- `wbt_delete_rebalance`: deletion sequences that exercise single and double rotations in both directions, including `GAMMA` equality;
- `wbt_delete_persistence`: all roots before and after repeated deletion remain searchable and fold correctly; §8A.10 later validates every retained root;
- delete-all permutation (standalone or folded into persistence): adversarial insert then delete every key in several orders, finishing at `:none`;
- `trial_collection_error_wbt_delete_invalid_comparator`: invalid comparator results at root and deeper paths publish no changed root.

Instantiate set items and map key/value pairs with more than one concrete type where the language permits; map trials must keep values attached through every splice and rotation.

**§8A.7 exit gate:** every structural and rebalancing branch is covered for set and map, absent deletion is a zero-node identity no-op, the heavier-side/tie rule is proven, extremes never detach map values from keys, the single smart-node allocation site is preserved, and `wbt_core/` integrate passes with the trials above. All retained versions preserve their observable contents pending the §8A.10 validator recheck.

**§8A.7 status (2026-07-10):** Complete — `wbt_set` / `wbt_map` export `delete/2`, `delete_min` / `delete_max` (set `/2` and map `/3` take a placeholder binding for the empty-root case). Result shapes: `{set|map, removed}` and `{set|map, status: :not_found | :found, …}` (status atoms match search/get, not a separate `:empty`). Path-copy rebalance reuses §8A.3 `smart_node` and §8A.4 `balance_*`; two-child delete splices via heavier-side / tie rule (left-heavier → predecessor `delete_max`, else successor `delete_min`). Emitter constraints carried from insert: no nested `case` closing over outer pattern-bound refs; no live `:none` into `smart_node`/balance (map rebuilds case residuals into literal-`:none` helpers; finish helpers use `sequence` bindings, not one-liner nested calls). Map delete never calls `compare_value`. Positive trials in `wbt_core/`: `wbt_delete_absent`, `wbt_delete_leaf`, `wbt_delete_one_child`, `wbt_delete_two_child`, `wbt_delete_root`, `wbt_delete_extreme`, `wbt_delete_heavier_side`, `wbt_delete_rebalance`, `wbt_delete_persistence`, `wbt_delete_payload_shapes` (string set + int64→`(int64,string)` map). Collection-error: `trial_collection_error_wbt_{set,map}_delete_invalid_comparator` (trial-only `wbt_trial_delete_*@delete_status_i64`). `check-wbt-alloc-rec-gate` remains one `alloc_rec` per module. Exit gate: `wbt_core/` positive-integrate **108 0**; Phase 1 root integrate **200 0**. Proceed to §8A.8.

### 8A.8 Deterministic linear `from_sorted`

Implement sorted construction without routing through insertion:

1. count the input with checked `int64` arithmetic;
2. preflight adjacent keys with the placement comparator, rejecting descending order, comparator equality, and invalid result atoms before publishing a root;
3. recursively consume exactly `n` bindings from a list cursor;
4. choose `left_count = n / 2`;
5. consume the root binding after the left subtree;
6. build `right_count = n - left_count - 1`; and
7. use §8A.3 bottom-up so every cached size is derived, not copied from input.

The internal counted builder must reject negative counts, early exhaustion, and unconsumed trailing input. The list-facing core path derives the count itself, but the counted helper still needs direct mismatch trials. A failed build returns an invalid bulk result with no partial root published; it must not sort or deduplicate the input.

Acceptance trials:

- `wbt_from_sorted_shape`: lengths `0` through at least `32`, plus values around powers of two, produce the exact deterministic median shape and pass direct size/order/balance assertions; §8A.10 later rechecks all shapes with the production validator;
- `wbt_from_sorted_set_map`: set items and map bindings have equivalent key shapes, with map values kept attached;
- `wbt_from_sorted_valid_invalid`: strict ascending input succeeds; one descending adjacency and one comparator-equal adjacency at beginning, middle, and end fail;
- `wbt_from_sorted_count_mismatch`: negative, short, and long counted-helper inputs fail without publishing a partial root;
- `trial_collection_error_wbt_from_sorted_invalid_comparator`: invalid atoms at each preflight position fail deterministically;
- `wbt_from_sorted_linear`: comparator-call and node-allocation observations are bounded by a linear function and show exactly `n` WBT nodes on success, distinguishing this path from fold-insert;
- `wbt_from_sorted_persistence`: the input list remains readable and unchanged after success and failure.

**§8A.8 exit gate:** valid input produces the specified deterministic shape in `O(n)` time and `O(n)` nodes; every malformed-input class is rejected; no insertion loop, sorting pass, or deduplication is hidden in the builder.

**§8A.8 status (2026-07-14):** Complete — `wbt_core` acceptance suite for deterministic linear `from_sorted` is enumerated in `POSITIVE_SILICA` / `COLLECTION_ERROR_TRIALS`, recorded, and green: empty/singleton/two boundaries; `wbt_from_sorted_shape` (0..16 and powers of two) plus `wbt_from_sorted_shape_large` (31/32) with exact median shape; `wbt_from_sorted_set_map`; `wbt_from_sorted_valid_invalid` (ascending OK; desc/eq at begin/mid/end fail for set and map); `wbt_from_sorted_count_mismatch` and `wbt_from_sorted_map_invalid_two`; production `from_sorted_preflight_status` invalid-comparator collection-error trials; `wbt_from_sorted_linear` (exact `n` cached nodes + median shape, distinct from fold-insert); `wbt_from_sorted_persistence`. Live builder path is buffer fill + bottom-up `smart_node` (no hidden insert/sort/dedup). Exit gate is green.

### 8A.9 Join/split scope decision

Audit every Phase 1 downstream consumer before adding `join`, `concat`, or `split`. The current public set/map designs, live graphs, and snapshot index builders do not require them, so the default decision is **deferred—not implemented in Phase 1 §8A**.

**Revisit home:** §14 (after `OrderedSet` / `OrderedMap` land). Do not leave the reopen decision only in this §8A subsection.

If a concrete consumer later proves one is required (at §14 or afterward):

- record that consumer and operation in §14 and the requirements ledger;
- implement it only in terms of the same smart constructor and `(3,2)` balance functions;
- check ordering and arena preconditions before allocating a result that can reference both inputs;
- add direct valid, invalid-precondition, persistence, sharing, and randomized-oracle trials; and
- satisfy a separate dated mini-gate before the consumer uses it.

Do not add a second balancing algorithm or speculative public API.

**§8A.9 exit gate:** either the deferral is recorded after the consumer audit, or every required primitive has its own accepted mini-gate. An untested optional primitive may not ship in the internal module.

**§8A.9 status (2026-07-15):** Complete — consumer audit recorded; `join` / `concat` / `split` **deferred** out of §8A (not implemented). Audit: public `OrderedSet` / `OrderedMap` / `SearchTree` designs expose insert, delete, search, fold, `from_sorted`, and validate only; live WBT graphs update indexes via insert-style edge ops; CSR/dense snapshot builders need WBT `from_sorted` for `node_to_slot`, not join/split/concat. No Phase 1 §8A consumer requires these primitives. **Verified:** `stdlib/data_structures/wbt_{set,map}.silica` export none of `join` / `concat` / `split` (internal `from_sorted_buf_split` is the §8A.8 median builder only). **Mandatory reopen checkpoint:** §14 after §9–§10. Exit gate satisfied by recorded deferral plus forward pointer.

### 8A.10 Full structural validation

Implement one postorder validation pass for each node shape. For every reachable subtree it computes checked logical size and optional minimum/maximum binding information, then verifies:

- every child reference belongs to the owning canonical arena;
- no node is reached twice within one root and no cycle exists, when reference identity support is available;
- cached size is positive and equals `1 + left + right`;
- left maximum is strictly less than the node key and the node key is strictly less than right minimum;
- both `(DELTA, GAMMA) = (3, 2)` balance inequalities hold;
- map nodes retain exactly one value paired with each key;
- the root's computed count equals its cached size; and
- all comparator calls return a valid ordering atom.

Return the common `{valid, error, logical_count}` shape. Choose one deterministic error precedence and keep it stable in golden trials so a malformed tree does not report whichever violation happens to be noticed by incidental traversal changes. Validation must terminate on a malformed cycle by using a trial/implementation-appropriate visited-reference set; a valid tree retains `O(log n)` traversal stack.

Acceptance trials:

- `wbt_validate_invariants`: every successful fixture from §§8A.1–8A.8 validates with the exact logical count;
- `wbt_validate_malformed_fixture`: independently detect wrong arena, cycle/repeated child, zero or incorrect cached size (including at the root), left/right order violation, and balance violation;
- `wbt_validate_error_precedence`: multi-fault fixtures prove the documented deterministic diagnostic order;
- `wbt_validate_map_pairing`: map validation and fold observe each original key/value binding after rotations, replacement, deletion, and bulk build;
- `trial_collection_error_wbt_validate_invalid_comparator`: invalid comparison during bound checking produces `:invalid_comparator_result`;
- validation itself does not mutate or repair malformed or valid input.

Malformed fixture construction remains trial-only. No production constructor may expose caller-selected child references or cached sizes merely to make validation tests convenient.

**§8A.10 exit gate:** the validator accepts every valid operation result, rejects every independently injectable invariant violation, terminates on cycles, reports deterministic diagnostics, and returns the exact logical count.

**§8A.10 status (2026-07-15):** Complete — `wbt_set@validate/1` and `wbt_map@validate/1` return `{valid, error, logical_count}` via a single left-then-right postorder walk. Entry checks: `:cycle` / `:repeated_child` (via `ref_eq` on parent/child and sibling edges) and `:wrong_arena` (`ref_in_region`). Node-local checks after children: `:invalid_comparator_result`, `:negative_count`, `:size_mismatch`, `:order_violation`, `:balance_violation` under fixed precedence. Set also exports `validate_with_compare/2` for bound-check comparator injection; `validate_error_code/1` maps atoms to stable int64 codes (`:ok=0` … `:balance_violation=8`). Emitter-safe helpers keep child refs as parameters (`edges_when_left` / `map_edges_when_left`) to avoid multi-arg register scramble. Positive trials in `wbt_core/`: `wbt_validate_invariants` (empty + 7-node fixture + insert-2; exit 3), `wbt_validate_malformed_fixture` (seven independent faults; exit 7), `wbt_validate_error_precedence` (size before order), `wbt_validate_map_pairing` (mutate + bulk fold pairing). Collection-error: `trial_collection_error_wbt_validate_invalid_comparator`. Malformed construction remains trial-only in `wbt_trial_fixture`.

### 8A.11 Deterministic exhaustive and randomized trace hardening

After the directed trials pass, add test-only list-based mathematical oracles. The oracle may use simple linear search and sorted insertion/deletion, but must not become a standard-library implementation or share balancing code with the WBT.

Run:

- bounded exhaustive set traces over a small key domain, covering every insert/delete/search sequence to a documented depth;
- bounded exhaustive map traces including new insertion, replacement, lookup, and deletion;
- fixed-seed randomized traces with ascending, descending, duplicate-heavy, and uniformly shuffled key distributions;
- a persistence fan-out trace that updates many descendants from one old root rather than only a linear version chain;
- periodic `from_sorted` rebuilds compared with the incrementally maintained oracle;
- validation after every mutating operation, not only at trace completion; and
- invalid-comparator schedules that fail on the first, middle, and last comparison of search, insert, replace, delete, sorted preflight, and validation.

For every step compare:

- logical size;
- ascending set items or map bindings;
- search/get presence and payload;
- update flags;
- retained old-version contents; and
- validator result.

Use fixed seeds checked into the trial source or scout output. On failure, print the seed and the shortest known operation prefix so the result is reproducible. Add coarse comparator-call, allocation, and height bounds sufficient to catch accidental linear search, insertion-based `from_sorted`, whole-tree copying, or failure to balance; do not make wall-clock timing the gate.

Required aggregate artifacts:

- `wbt_set_exhaustive_trace`;
- `wbt_map_exhaustive_trace`;
- `wbt_set_randomized_oracle`;
- `wbt_map_randomized_oracle`;
- `wbt_persistence_fanout`;
- `wbt_complexity_observations`.

Run the aggregate suite for every supported memory space and for enough distinct payload specializations to catch hard-coded type assumptions. Keep trial sizes bounded so `make integrate` remains a deterministic regression suite rather than a benchmark.

Complete the steps below in order. A later step may add trials for an earlier helper, but must not leave an earlier step's gate failing.

#### Step 1 — Oracle harness and per-step checker

1. Add trial-only sorted-list oracles in `wbt_core/lib/wbt_trial_oracle_i64.silica` (set items and map bindings via `prepend` / `empty`, linear membership, sorted insert/delete/replace).
2. Export shared checkers: size, fold sum, search/get for every oracle key, `validate` + `logical_count`, and optional update-flag witnesses.
3. Add `wbt_oracle_harness_smoke.silica`: hand-written insert/delete/replace trace with oracle agreement and validation after every mutation.

**Step 1 check:** `wbt_oracle_harness_smoke` exits `0`.

#### Step 2 — Set exhaustive trace

1. Document domain `{1,2,3}` and depth `3` (216 insert/delete sequences).
2. Recursive trial driver applies each operation, checks oracle + validator, then recurses.
3. Add `wbt_set_exhaustive_trace.silica`.

**Step 2 check:** `wbt_set_exhaustive_trace` exits `0`.

#### Step 3 — Map exhaustive trace

1. Document domain `{1,2,3}` with values `key*10`, depth `3`, ops insert/replace/delete.
2. Mirror Step 2 driver for map flags and `get` payloads.
3. Add `wbt_map_exhaustive_trace.silica`.

**Step 3 check:** `wbt_map_exhaustive_trace` exits `0`.

#### Step 4 — Fixed-seed randomized oracles

1. Add deterministic LCG + fixed key schedules (ascending, descending, duplicate-heavy, uniform shuffle) in `wbt_trial_trace_i64.silica`.
2. Check oracle + validator after every step; encode seed in trial source (scout exit code only).
3. Add `wbt_set_randomized_oracle.silica` and `wbt_map_randomized_oracle.silica`.

**Step 4 check:** both randomized trials exit `0`.

#### Step 5 — Persistence fanout and `from_sorted` cross-check

1. Retain one ancestral root plus multiple divergent descendants; verify ancestral contents unchanged.
2. Periodically rebuild via `from_sorted` from oracle list and compare with incremental WBT.
3. Add `wbt_persistence_fanout.silica`.

**Step 5 check:** `wbt_persistence_fanout` exits `0`.

#### Step 6 — Complexity observations and invalid-comparator schedules

1. Injectable comparator counters bound search/insert/delete/`from_sorted`/validate call counts on fixed traces.
2. Coarse height/size bounds on the same traces (no wall-clock timing).
3. Invalid-comparator schedules at first/middle/last comparison sites across search, insert, replace, delete, sorted preflight, and validation.
4. Add `wbt_complexity_observations.silica` plus any narrowly scoped collection-error companions required by the schedules.

**Step 6 check:** `wbt_complexity_observations` exits `0`; collection-error companions match golden stderr/exit.

#### Step 7 — Gate integration

1. Add all new positives to `wbt_core/POSITIVE_SILICA`.
2. `make record-positive-golden` then `make positive-integrate` in `wbt_core/`.
3. Update requirements-to-trials ledger rows for trace hardening.
4. Mark §8A.11 Complete with dated status.

**§8A.11 exit gate:** exhaustive and fixed-seed randomized traces agree with their independent oracles at every operation; every intermediate and retained root validates; complexity observations match the design's asymptotic table.

**§8A.11 status (2026-07-16):** Complete — Steps 1–7: trial-only `wbt_trial_oracle_i64` / `wbt_trial_trace_i64`; positives `wbt_oracle_harness_smoke`, `wbt_set_exhaustive_trace`, `wbt_map_exhaustive_trace`, `wbt_set_randomized_oracle`, `wbt_map_randomized_oracle`, `wbt_persistence_fanout`, `wbt_complexity_observations` in `wbt_core/POSITIVE_SILICA` with recorded goldens; requirements-to-trials ledger rows for WBT §§8–12/14/16 updated for trace hardening. **Integrate verified.**

### 8A exit gate

The corrected Adams-family WBT core is accepted only when all of the following hold:

- §§8A.1–8A.11 have dated complete status records, and every landed artifact is reflected in the requirements-to-trials ledger.
- `make integrate` passes in `wbt_core/` and at the Phase 1 trial root from a clean golden baseline.
- Set and map recursive shapes compile from `stdlib/data_structures/` without a trial-only runtime dependency and without registering §9–§10 public modules early.
- Every production node is allocated by the checked smart constructor in the owning canonical arena.
- Search, min/max, size, and fold allocate no WBT nodes.
- Duplicate set insertion and absent deletion return the identical root and allocate no WBT nodes.
- Map replacement retains the canonical key, preserves key/value pairing, and does not invoke `compare_value`.
- All single/double rotation directions, the strict `GAMMA` choice, and the equality-to-double edge are directly covered.
- Insertion, replacement, deletion, extraction, and `from_sorted` preserve old roots and share untouched subtrees.
- `from_sorted` has deterministic shape, rejects every specified malformed input, and meets the linear comparison/allocation gate.
- Invalid comparator results are exercised at every comparator-using operation and never publish a changed root.
- Full validation covers arena, acyclicity/non-duplication, cached size, strict order, `(3,2)` balance, map pairing, and root logical count.
- Exhaustive and fixed-seed randomized set/map traces agree with independent test oracles after every operation.
- The §8A.9 consumer audit records join/split/concat as deferred for §8A; the mandatory reopen checkpoint is §14 (not only this bullet).
- No public `wbt_set`, `wbt_map`, `OrderedSet`, `OrderedMap`, SearchTree, or graph implementation has been used to hide a missing core behavior.

Only after this gate passes may §9 begin. §15–§37 wait until §13 (bootstrap removal gate) passes.

**§8A exit gate status (2026-07-16):** Complete — §§8A.1–8A.11 dated complete; ledger rows for WBT core + trace hardening current; `make integrate` passed on the §8A.11 golden baseline. Join/split/concat remain deferred per §8A.9 (reopen at §14). Proceed to §9.

## 9. `wbt_map` and `OrderedMap`

**Authority:** [`ordered_map_trait.md`](data_structure_designs/ordered_map_trait.md); shared core [`weight_balanced_tree.md`](data_structure_designs/weight_balanced_tree.md).
**Dependencies:** accepted §8A WBT core and Layer 1 trait substrate.
**Downstream consumers:** live weighted graphs, node-to-slot indexes, CSR/dense indexing; §11 compiler BST replacement for self-host.

**Already delivered by §8A (do not reimplement):** map node shape; smart constructor; search/`get`/`contains_key`/`fold`/`size`; insert/replace with `{inserted, replaced}`; delete; `from_sorted`; validate; `compare_value` unused on key placement paths (`wbt_map_compare_value_not_called`).

**Remaining work:** public `OrderedMap` trait + generated-module registration, §7.9 constructor lowering for `OrderedMap[...]`, thin public surface over the core (including `find_value` / `from_list` / `singleton`), and `ordered_collections/` acceptance trials.

Complete the steps below in order. A later step may add trials for an earlier helper, but must not leave an earlier step's gate failing.

#### Step 1 — Public registration and `@empty`

1. Register `OrderedMap` / generated `wbt_map` as the public map family (not only the §8A compiler-private core path).
2. Constructor record `{compare_key, compare_value}` via §7.9: runnable `wbt_map@empty`, canonical arena, specialization key, ordering bundles on merged records.
3. Negative constructor goldens for missing/extra/mismatched fields (`error_enforcement/` → `ordered_map_constructor_record` or equivalent).

**Step 1 check:** `OrderedMap[K, V, mem(normal)] <- wbt_map@empty({...})` compiles and runs; constructor-record compile-fails match goldens.

#### Step 2 — Required trait methods

1. Land `export trait OrderedMap` with required `compare_key`, `compare_value`, `get`, `fold`.
2. Wire each required method to the §8A core (no second balancing algorithm).
3. Preserve exact lookup shape `{status: :not_found | :found, value: ValueType}`.

**Step 2 check:** `ordered_collections/` → `ordered_map_trait_dispatch` (or equivalent) exercises required methods on an empty and nonempty map.

#### Step 3 — Provided methods and `find_value`

1. Provided `contains_key` and cached `O(1)` `size` override (fold-derived fallbacks remain valid for other impls).
2. Implement `find_value/2` as ascending in-order linear search returning the smallest key whose value compares equal via `compare_value`.
3. This is the only placement-adjacent path that may invoke `compare_value`.

**Step 3 check:** `ordered_map_find_value_linear` — hit/miss, first-of-equal-values, and trap/`compare_value` only on the find path.

#### Step 4 — Public module surface

1. Export the generated-module surface from `ordered_map_trait.md` §4 over the core: `empty`, `singleton`, `insert`, `delete`, `get`, `contains_key`, `find_value`, `size`, `fold`, `from_list`, `from_sorted`, `validate`.
2. Prefer thin wrappers / re-exports; do not fork insert/delete/`from_sorted`/validate algorithms.
3. Align bulk list element shape `List[{key, value}, SpaceType]` with the design (adapt core tuple lists if needed at the public boundary only).

**Step 4 check:** `wbt_map_get_insert`, `ordered_map_insert_replace`, `ordered_map_delete_absent`, `ordered_map_from_sorted`, `ordered_map_not_found_status` (or merged equivalents) pass on the public module.

#### Step 5 — Placement vs value-comparator acceptance

1. Re-prove on the public/`OrderedMap` path that `compare_value` is not called during key descent, insertion, replacement, deletion, balancing, `get`, or `contains_key` (reuse or extend `wbt_map_compare_value_not_called`).
2. Persistence and string/example trials from the ledger (`ordered_map_persistence`, `ordered_map_string_example`).

**Step 5 check:** value-comparator trap trial + persistence/example positives exit `0`.

#### Step 6 — Gate integration

1. Add new positives to `ordered_collections/POSITIVE_SILICA` (and compile-fail goldens under `error_enforcement/` as needed).
2. `make record-positive-golden` then `make integrate` for the affected leaves / Phase 1 root.
3. Update requirements-to-trials ledger rows for `ordered_map_trait.md`.
4. Mark §9 Complete with dated status.

**§9 exit gate:** public `OrderedMap` + generated `wbt_map` satisfy `ordered_map_trait.md`; core algorithms remain sole WBT implementations; `compare_value` is used only for `find_value` / value equality; integrate passes on a clean golden baseline.

**§9 status:** Complete (2026-07-16).

## 10. `wbt_set` and `OrderedSet`

**Authority:** [`ordered_set_trait.md`](data_structure_designs/ordered_set_trait.md); shared core [`weight_balanced_tree.md`](data_structure_designs/weight_balanced_tree.md).
**Dependencies:** accepted §8A WBT core and Layer 1 trait substrate.
**Downstream consumers:** `SearchTree`, live graph outer vertex sets/maps, graph neighbor sets, CSR/dense indexing.

**Already delivered by §8A (do not reimplement):** set node shape; smart constructor; search/`contains`/`fold`/`size`; insert (duplicate no-op); delete; `from_sorted`; validate; persistence and invalid-comparator coverage in `wbt_core/`.

**Remaining work:** public `OrderedSet` trait + generated-module registration, §7.9 constructor lowering for `OrderedSet[...]`, thin public surface (`singleton` / `from_list` if not already public), and `ordered_collections/` acceptance trials.

Complete the steps below in order. A later step may add trials for an earlier helper, but must not leave an earlier step's gate failing.

#### Step 1 — Public registration and `@empty`

1. Register `OrderedSet` / generated `wbt_set` as the public set family.
2. Constructor record `{compare_item}` via §7.9: runnable `wbt_set@empty`, canonical arena, specialization key, ordering bundle on merged records.
3. Negative constructor goldens (`error_enforcement/` → `ordered_set_constructor_record` or equivalent).

**Step 1 check:** `OrderedSet[T, mem(normal)] <- wbt_set@empty({compare_item: ...})` compiles and runs; constructor-record compile-fails match goldens.

#### Step 2 — Required trait methods

1. Land `export trait OrderedSet` with required `compare_item` and `fold`.
2. Wire both to the §8A core; fold remains strictly ascending.

**Step 2 check:** `ordered_collections/` → `ordered_set_trait_dispatch` (or equivalent) on empty and nonempty sets.

#### Step 3 — Provided method overrides

1. Override provided `contains` with `O(log n)` WBT search and `size` with cached `O(1)` root metadata.
2. Fold-derived provided definitions remain valid fallbacks for non-WBT impls.

**Step 3 check:** nonempty contains hit/miss; size matches fold cardinality and stays `O(1)` observationally (no full walk in the override path).

#### Step 4 — Public module surface

1. Export the generated-module surface from `ordered_set_trait.md` §4 over the core: `empty`, `singleton`, `insert`, `delete`, `contains`, `size`, `fold`, `from_list`, `from_sorted`, `validate`.
2. Prefer thin wrappers / re-exports; do not fork core algorithms.
3. Public insert/delete result shapes match the design (`{set, inserted}` / `{set, removed}`).

**Step 4 check:** `wbt_set_empty_insert`, `ordered_set_duplicate_insert`, `ordered_set_invalid_comparator`, and bulk/`from_sorted` public-path trials pass.

#### Step 5 — Persistence, example, and complexity-sensitive acceptance

1. Persistence and string/example trials from the ledger (`ordered_set_persistence`, `ordered_set_string_example`).
2. Confirm complexity-sensitive cached-size and fold-order behavior required by `ordered_set_trait.md` on the public path (core §8A.11 observations remain authoritative for asymptotics).

**Step 5 check:** persistence/example positives exit `0`; no public API regresses duplicate-insert identity or absent-delete identity.

#### Step 6 — Gate integration

1. Add new positives to `ordered_collections/POSITIVE_SILICA` (and compile-fail goldens under `error_enforcement/` as needed).
2. `make record-positive-golden` then `make integrate` for the affected leaves / Phase 1 root.
3. Update requirements-to-trials ledger rows for `ordered_set_trait.md`.
4. Mark §10 Complete with dated status.

**§10 exit gate:** public `OrderedSet` + generated `wbt_set` satisfy `ordered_set_trait.md`; core algorithms remain sole WBT implementations; integrate passes on a clean golden baseline.

**§10 status:** Complete (2026-07-16).

## 11. Self-host source prerequisites (parallel tree; aliases out; BST → WBT)

**Authority:** [bootstrap_retirement_and_self_host_plan.md](bootstrap_retirement_and_self_host_plan.md) Phase 0 (audit), Phase 5.1 (alias ban), Phase 3 (emitter BST → WBT).

**Dependencies:** §8A, §9, and §10 exit gates (public `wbt_map` / `wbt_set` / traits available for compiler-internal `use`).

### Safe-transition freeze (non-negotiable through §12)

Until the §13 cutover gate passes:

1. **Do not modify** `silica-bootstrap-compiler` (crate, recipes, or retirement).
2. **Do not modify** the production compiler tree `compiler/src/` for self-host migration (aliases, `bst`, maps, ABI cleanups aimed at self-host). That tree remains the bootstrap-built default and keeps current trials green.
3. **All self-host source edits** land only under `compiler/src/` (parallel copy of `src/`, plus any new helpers such as `compiler_maps.silica`).
4. Default `make` / integrate path continues to use bootstrap → current `src/`.

**Hard constraints (parallel tree only — [silica-specification.md](../silica-specification.md) §3.4.2):**

1. **No `type` aliases** of any kind (including `type TokenKind = int64`).
2. **No named `struct Name { … }` declarations.** Record types are written **inline** as `{ field: Type, … }` wherever a type is required. Record values use **struct literals** only (`{ … }`, or `identifier { … }` as a value form where the grammar allows — never as a type declaration).
3. **Host for `src/` is the seed** `compiler/src` → `silica-compiler` (E1047 enforced). Do **not** disable E1047 or re-teach boot-era named structs in the seed to make the parallel tree compile.
4. Linear recursive ADTs use built-in **`List[T, mem(S)]`**, not custom `ListX` cons-cell structs. Tree-shaped ADTs (`Expr`, `SIRTerm`) use a seed-legal encoding (see §12 Wave C) — not named self-typed structs.

**Rationale:** Frozen `src/` still uses bootstrap-era named structs because **silica-boot** compiles that tree. The parallel tree must match the surface language the seed already implements, so `build-selfhost` is a deliberate rewrite off boot-only ADTs — not a seed dialect expansion.

### Edit discipline (non-negotiable)

**Crafted edits only** under `src/`. Do **not** run tree-wide / multi-file batch rewriters, bulk regex migrations, or “fix the whole dialect in one pass” scripts. Each change is hand-scoped to the files and APIs named in the active step, reviewed before the next step starts. Mechanical helpers (if any) may inventory or transform a **single named file** under explicit review — never the whole tree unattended.

Complete the steps below in order.

#### Step 1 — Phase 0 inventory + stand up the parallel tree

1. Record bootstrap-only build assumptions, Makefiles still on `silica-boot`, and the self-host W-id feasibility matrix (class A/B/C).
2. Stdlib smoke checklist for compiler-internal `use` of `wbt_map` / `wbt_set` / `OrderedMap` / `OrderedSet` (acceptance already green from §9–§10).
3. Create `src/` as a faithful copy of `src/` (including `data_structures/` inputs the compiler needs). Document the sync rule: cherry-pick or re-copy only when deliberately refreshing from frozen `src/`; never edit `src/` for self-host work.

**Step 1 check:** Inventory checked into the authority plan’s Completion Tracking table; `src/` exists and is the only tree listed for §11–§12 edits.

#### Step 2 — Replace emitter `bst` with WBT maps in `src/` (first source edit)

This is the **first** self-host source change after the parallel tree exists. Keep boot-era `struct` / `type` shapes intact in this step; only swap the index representation.

1. Land `data_structures/compiler_maps.silica` under `src/` with explicit `OrderedMap[…, mem(normal)]` bindings — **no aliases**.
2. Crafted migration of each `use bst` emitter module in `src/` (atom table, int/float literal pools, `int_rodata`) to `compiler_maps` / `wbt_map` + `OrderedMap@get` / `wbt_map@insert`. One module (or one coherent helper API) at a time.
3. Remove `data_structures/bst.silica` from the **parallel** tree once `use bst` / `bst@` / `BstNode` counts in `src/` are zero. Do **not** delete `src/data_structures/bst.silica` (frozen production tree still needs it).

**Compiler WBT surface:** `wbt_map@empty`, `wbt_map@insert`, `OrderedMap@get` (set analogues where adopted). No `join`, `concat`, or `split`.

**Step 2 check:** Zero `use bst` / `bst@` / `BstNode` under `src/`; frozen `src/` still uses `bst` as today.

#### Step 3 — Ban all `type` aliases in `src/`

1. In `src/` only: remove `type TokenKind = int64` and every other `type` alias — **file by file**, not a tree-wide strip.
2. Rewrite call sites to bare `int64` (token kind codes) and **inline** constant records from `token_kinds()` — not a named `TokenKinds` struct type.
3. Grep-clean legacy bootstrap exports from `src/` `use` paths (`btree_*`, `graph_adj_*`, width-specialized empties) as encountered.

**Step 3 check:** No `type` declarations in `src/`; frozen `src/` still contains its current aliases untouched; current lexer trials still pass via bootstrap → `src/`.

#### Step 4 — Class-A compile blockers on the parallel tree

1. Fix class-A items **in `src/`** (and only if unavoidable, in shared stdlib / host bugfixes that do not change frozen `src/` semantics) so the **seed** can compile the full `src/` graph under §3.4.2 (no named structs / no aliases). Crafted, incremental fixes only.
2. Do not claim §12 until that seed host can compile-only smoke `src/silica.config.compiler`.

**§11 exit gate:** `src/` has zero `type` aliases and zero `bst` uses; emitter pools there are WBT-backed; Phase 0 inventory recorded; remaining class-A items (including the named-struct dialect rewrite) are fixed or explicitly listed as §12 inputs. Frozen `src/` and `silica-bootstrap-compiler` remain untouched; default build still bootstrap → `src/`.

**§11 status:** Complete (2026-09-08 audit) — `src/` has zero `type` aliases, zero named `struct` declarations and zero `bst` uses; the seed (`binaries/seed-compiler`) compiles and links the full 331-unit `src/silica.config.compiler`. Residual: `string_literal_pool.silica` still deduplicates by linear scan (bootstrap-plan Step 3.3); the Step 0.2 W-id comments survive in `src/` as history.

**§11 delivered (so far):**

1. `compiler/src/` re-stood up as a faithful copy of frozen `src/`.
2. `data_structures/compiler_maps.silica` + crafted emitter-pool migration (`atom_table`, `int64_literal_pool`, `float32_literal_pool`, `float64_literal_pool`, `int_rodata`) onto WBT `OrderedMap` via `compiler_maps`; `data_structures/bst.silica` removed from the parallel tree only.
3. Grep gate: zero `use bst` / `bst@` / `BstNode` under `src/`.

**§11 open:** none. (Step 3 alias removal and Step 4 / §12 dialect rewrite both landed; see §12 status.)

## 12. Build flip and ABI hardening (parallel path only)

**Authority:** [bootstrap_retirement_and_self_host_plan.md](bootstrap_retirement_and_self_host_plan.md) Phases 1–2; surface language [silica-specification.md](../silica-specification.md) §3.4.2 / §3.3.7.

**Dependencies:** §11 exit gate (self-hostable **parallel** tree: no aliases, no `bst`) plus the dialect rewrite below.

**Host rule (as implemented):** `make -C src build` (aliases `build-selfhost` / `assembly-selfhost`) compiles `src/` with **`binaries/seed-compiler`** — a *published* seed generation built from frozen `src/`, never a path into `src/` and never `binaries/silica-compiler` (which tracks the newest build and may be a selfhost that cannot yet build itself; `check-seed` enforces this). The host keeps **E1047 on**. `src/Makefile` still passes `HOST_COMPILER=…`, which `src/Makefile` ignores. The DeviceIO staging overlay (`src_staging_deviceio/`) no longer exists; DeviceIO is resolved at link by `silica_rt_shim.s` / `deviceio_link_thunks.s`.

**Scope:**

- Dual-build Makefile switch: **`build-bootstrap` (default)** continues to build frozen `src/` with `silica-boot`; **`build-selfhost` / `assembly-selfhost`** compile and link only from `src/`.
- `src/silica.config.compiler` batch mode; self-hosted `.sams` → `.o` → link recipe; stack/resource limits for the full parallel graph.
- **Dialect rewrite of `src/`** off bootstrap-only named structs (waves A–C below).
- Finish Phase 2 workaround removals **inside `src/`** once the self-host path exists.
- Do **not** change the default production recipe or delete bootstrap in this section.

### §12 dialect rewrite waves (parallel tree only)

| Wave | What | Target shape |
| ---- | ---- | ------------ |
| **A** | Custom `ListX` cons-cell structs (~36) | `List[<inline element>, mem(normal)]`; `[]` / prepend / list patterns |
| **B** | Non-recursive records (`SourceLocation`, `Token`, `Param`, `SymbolEntry`, tables, results, `token_kinds()` payload, …) | Inline `{ field: Type, … }` types; `{ … }` values; factory fns instead of `export TypeName/0` |
| **C** | Recursive trees `Expr`, `SIRTerm` (and any other self-typed nodes) | Seed-legal encoding: **index-arena** `{ nodes: List[<inline node>, mem(normal)], root: int64 }` with `-1` = none (replaces cyclic `kind=-1` dummies). |
| **D** | Residual class-A W-ids | Keyword binding renames (`required`/`provided` as idents), comment/`sequence` token quirks, E3009 residuals, string/ABI W-ids as needed for batch green |

**Grep gates before claiming §12:**

- `rg '^\s*struct\s+\w+' compiler/src` → zero
- `rg '^\s*type\s+\w+\s*=' compiler/src` → zero
- `rg 'use bst' compiler/src` → zero

**§12 exit gate:** `make build-selfhost` / `assembly-selfhost` produces a self-host binary from `src/` without `silica-boot` on that path’s compile critical path (runtime `.a` may remain temporarily); full `src/silica.config.compiler` batch compiles under the seed with **E1047 on** and **zero** named struct / `type` alias declarations in the parallel tree. Default `make` / integrate still uses bootstrap → frozen `src/`.

**§12 status:** Exit gate met (2026-09-02, commit `ccdb0610` "selfhost compiler passes all CI trials"; audited 2026-09-08). Waves A–C are complete; the 331-unit batch compiles under the seed with E1047 on and zero named structs / aliases; the link is Rust-free (no `libsilica_compiler.a`). The resulting selfhost binary (`binaries/silica-compiler`) is what every `trials/*/` suite now runs on. What §12 did **not** deliver, and §13 now owns: the selfhost compiling *itself* (last unit `emitter_core.silica`, memory wall being broken by the `list_nth` builtin), generation 2, differential, and fixpoint.

**Dialect rewrite progress:**

| Wave | Status | Notes |
| ---- | ------ | ----- |
| Plan / host rules | Done | §11 hard constraints + crafted-edit discipline; `src/README.md` |
| Emitter WBT (§11 Step 2) | Done | Zero `use bst` under `src/`; pools via `compiler_maps` / WBT |
| Wave A/B | Done | `rg '^\s*struct\s+\w+' src` → 0; `rg '^\s*type\s+\w+\s*=' src` → 0 |
| Wave C `Expr` / `SIRTerm` | Done | Index arenas `{ nodes: List[<inline node>, mem(normal)], root: int64 }` in `parser/parser_ast.silica` and `sir_generator/sir_ast.silica`; `root = -1` replaces the cyclic dummy |
| Wave D residuals | Done for batch-green | ~23 historical `bootstrap` workaround comments remain in `src/` (W02, W04, W15 among them); reclassify as historical or delete |

**§12 open:** none for the exit gate. Housekeeping carried into §13: the orphan `src/btree_set_nodeid.silica` (excluded from the build by `topo_silica_config.sh`) was deleted 2026-10-16, reclassify the residual workaround comments, and either wire or delete `HOST_COMPILER` in `src/Makefile`.

## 13. Cutover / fixed-point / bootstrap retirement

**Authority:** [bootstrap_retirement_and_self_host_plan.md](bootstrap_retirement_and_self_host_plan.md) Phase 6 (Phase 5.1 already required by §11 on the parallel tree). The keyed-lookup migration this section once carried (former Phase 4) was withdrawn 2026-09-29: the compiler keeps its lists.

**Dependencies:** §12 exit gate.

**Scope:**

- **Phase 6:** self-host integrate suite (`trials/self_host_addition/`), fixed-point (`host_n` compiles `host_{n+1}` from `src/`).
- **Cutover (only after fixed-point green):** promote `src/` over production `src/` (or swap trees per authority plan), make self-host the default build, then retire `silica-bootstrap-compiler` from the default path. Until that moment the freeze in §11 still holds.

**§13 exit gate:** Phase 6.1 fixed-point integrate passes on the parallel tree; `make integrate` includes the self-host trial; after cutover, production compiler source has zero `type` aliases, no `bst` dependency, and builds/maintains itself without `silica-bootstrap-compiler` on the default path. Blocks §14 onward until this gate passes.

**§13 status (2026-10-16):** The record below is kept for history and is superseded. Per the project record the selfhost reached its fixed point on 2026-09-12 (gen3 equals gen2 modulo UUID/signature) and Linux x86-64 reached its own on 2026-09-19; commit `eff040583` records new fixed points for all three hosted platforms. `trials/self_host_addition/` does not exist. Whether `silica-bootstrap-compiler` is off the default path is not verified here; `bootstrap_retirement_and_self_host_plan.md` is the authority. **Earlier record (2026-09-08):** In progress. Self-host integrate is de facto in place (all trials run on the selfhost binary), but: there is no `trials/self_host_addition/`; the selfhost has not been shown to compile 100 % of `src/` (`emitter_core.silica` outstanding; `list_nth` landed in both trees to break its memory wall, confirming build pending); no generation-2 build, differential or fixpoint exists; cutover and bootstrap removal not done. The step order is the seven-step ladder recorded in the bootstrap-retirement plan's status snapshot (liveness → memory → probe harness → per-unit sweep → gen 2 [pause] → differential → fixpoint). Also on this path: `src/fix_seed_emission.py` had to be retired before any fixpoint claim (removed 2026-10-16), and defect A5 in `../HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md` (provided trait methods across the exit-75 restart) affects the compiler's own build.

## 14. WBT join/split/concat reopen (from §8A.9)

**Dependencies:** §9, §10, and §13.

**Purpose:** Keep the §8A.9 deferral from being forgotten after public set/map backends exist.

After §9, §10, and §13, and before treating §9–§10 work as finished, re-audit whether any Phase 1 consumer—including `OrderedSet` / `OrderedMap` public surface, `SearchTree`, live graphs, and CSR/dense indexes—needs WBT `join`, `concat`, or `split`.

Default outcome (matches §8A.9 and `ordered_set_trait.md` / `ordered_map_trait.md`): **remain deferred**—no public trait methods and no internal `wbt_set` / `wbt_map` exports for these ops in the initial §9–§10 landing.

Reopen only if a **named** consumer requires set union, ordered concat, or key-range split and fold-insert / `from_sorted` is insufficient. Then follow §8A.9’s conditional mini-gate (same `(3,2)` balance, precondition checks, trials, dated acceptance) before any consumer uses the primitive. Speculative Adams set-algebra API without a consumer is still out of scope; if still undesired after this checkpoint, record “deferred post–Phase 1” in the ledger and move on.

**§14 exit gate:** dated record either reaffirming deferral (no Phase 1 consumer) or accepting each required primitive under the §8A.9 mini-gate rules.

**§14 status (2026-10-16):** Deferral reaffirmed in the code; the dated ledger record is still owed. §13 no longer blocks it. `wbt_set.silica` and `wbt_map.silica` export no `join`, `concat` or `split`, and no landed consumer (`OrderedSet`, `OrderedMap`, `SearchTree`, the live, CSR and dense graphs) uses one; fold-insert and `from_sorted` suffice.

## 15. Skew binary random-access-list core

**Dependencies:** §13; canonical arenas, recursive tuples, immutable Silica `List`, checked arithmetic.
**Downstream consumers:** rose-tree child slots and dense graph storage.

Implement in this order:

1. leaf/node tree encoding; internal generated record carries canonical arena identity where the skew RAL design requires it;
2. digit record and immutable `List` forest spine;
3. `prepend`;
4. `head` and `tail`;
5. logarithmic lookup;
6. persistent logarithmic update;
7. deterministic bulk construction;
8. ordered fold and range traversal;
9. consumer orientation adapter, including reverse physical orientation where designed;
10. full validation.

Required trials:

- all sequence lengths across several skew-weight boundaries;
- repeated prepend/head/tail round trips;
- lookup/update at first, middle, last, and invalid indexes;
- persistence of previous sequences;
- digit-order, tree-weight, cached-size, and arena validation;
- overflow rejection during weight construction;
- bulk-build sequence equivalence to the abstract list.

Do not add lazy thunks. Both the forest spine and consumer-facing use are strict.

**§15 status (2026-09-08):** Implemented ahead of §13 at Lee's direction (the §8A exit-gate note that
§15 waits for §13 was set aside for this section only; §13 remains open). Landed in
`stdlib/data_structures/` as twelve units following the thin-dispatcher split
(`tutorials_and_howtos/thin_dispatchers_for_compile_ram.md`):

| Unit | Role | `use`s |
|---|---|---|
| `skew_ral_weights` | weight arithmetic, checked link weight, skew-form test | — |
| `skew_ral_node` | cell encoding `(item, left, right)`, allocation in the canonical arena, arena membership | — |
| `skew_ral_tree_read` | in-tree lookup, forward/reverse folds, range folds | weights, node |
| `skew_ral_tree_write` | path-copying update | weights, node |
| `skew_ral_forest` | digit spine: empty, prepend (one link), head, tail | weights, node |
| `skew_ral_index` | forest lookup and persistent update | tree_read, tree_write |
| `skew_ral_traverse` | forest folds and `O(log n + k)` range folds | tree_read |
| `skew_ral_build` | `from_list` (both orientations) and `filled` by O(1) prepends | forest |
| `skew_ral_validate` | full validation, preflight, error atoms and their codes | weights, node |
| `skew_ral_dispatch_access` | thin dispatcher: prepend/head/tail/lookup/update on the record | forest, index |
| `skew_ral_dispatch_bulk` | thin dispatcher: bulk build, folds, ranges, validate | build, traverse, validate |
| `skew_ral` | facade: constructor, orientation adapter (`get`/`set`/`append`), public core surface | the two dispatchers only |

Representation (inline at every boundary): `{ count, reversed: boolean, compare_item, forest:
List[(weight, tree)], region, specialization_key }`; cells are `(ItemType, ref?, ref?)` and only
digits carry weights (design §3). Arena key 81 via `canonical_arena_lookup` until the consumer
families register specializations.

Two deviations forced by the bootstrap compiler, both recorded in the facade header:

1. The record carries `compare_item` although the core never calls it: the checker resolves a
   bare `ItemType` formal at a qualified call only from a comparator witness on the first argument
   (`type_checker_collections@assoc_type_from_record_witness`). `Tree` supplies its own
   `compare_item` (tree_trait.md §2); dense graphs pass a cell comparator.
2. Orientation is `reversed: boolean`, not `:front | :reverse`: atom constants are numbered per
   compilation unit (`emitter/.../atoms/const_atoms.silica`), so a non-seeded atom built in one
   unit and cased in another does not match. For the same reason every validation and preflight
   error atom is created and decoded inside `skew_ral_validate` only.

Acceptance trials in `trials/ordered_data_structures/skew_ral_core/` (all exit 0; helper
`lib/ral_trial_i64`): `ral_encoding_roundtrip`, `ral_prepend_head_tail` (lengths 0–20),
`ral_lookup_boundaries` (lengths 1–17, every index), `ral_update_persistence`,
`ral_append_convention`, `ral_bulk_build`, `ral_fold_range` (every window of a 20-item sequence,
both orientations), `ral_validate_invariants` (nine malformed fixtures), `ral_weight_overflow`,
`ral_generic_payloads` (string and tuple items), `ral_persistence_fanout`.

Known gap: folding with a tuple-typed callback parameter is not exercised. The bootstrap emitter
miscompiles any function whose tuple parameter follows a scalar one (`step(5, (3, 10))` returns 13);
a repro is staged outside the tree and the fold-over-tuple checks return to `ral_generic_payloads`
once the emitter is fixed. Nothing in `src/` or `src/` was changed for §15.

**Gate:** `make integrate` in `skew_ral_core/` and `make gate-stdlib` at the trial root — see the
line below.
**Gate result (2026-09-08):** `skew_ral_core/` `make integrate` → `.integrate_counts` `12 0`, 12 of 12 `.ascomp` matched; root `make gate-stdlib` → 16 matched, 0 differed (the four WBT goldens unchanged). The full trial-root `make integrate` fan-out was not rerun; other leaves do not link the new units.

## 16. Brodal–Okasaki bootstrapped queue core

**Dependencies:** canonical arenas, exact ordering identity, recursive tuples, immutable Silica `List`, checked arithmetic.
**Downstream consumers:** `Heap` and `PriorityQueue`.

**§16 status (2026-10-16):** Complete. `stdlib/data_structures/` holds `brodal_okasaki.silica`, its split units (`_node`, `_compare`, `_link`, `_forest`, `_extract`, `_boot`, `_validate`, `_dispatch_core`, `_dispatch_bulk`) and the forwarders `brodal_okasaki_min`, `brodal_okasaki_max`, `brodal_okasaki_priority`. `brodal_okasaki_core/` has 13 trial programs (`bo_empty_peek`, `bo_from_list`, `bo_generic_payloads`, `bo_invalid_comparator_status`, `bo_max_orientation_adapter`, `bo_meld_incompatible`, `bo_meld_tree`, `bo_old_heap_valid_after_pop`, `bo_pop_order_oracle`, `bo_pop_persistence`, `bo_push_duplicate`, `bo_rank_collisions`, `bo_validate_invariants`) plus `smoke_harness_ready`. **Earlier record (2026-09-08 audit):** Implementation on disk, unrecorded and uncommitted: 11 `stdlib/data_structures/brodal_okasaki*.silica` units and 14 trials under `trials/ordered_data_structures/brodal_okasaki_core/` exist as untracked files and were being edited during the audit; that leaf has no `.integrate_counts`, so no gate run is recorded, and the ledger row still says "planned". Whoever owns this work should add a dated status block here in the §15 style (units, dispatcher split, trials, gate result) before it is committed.

Implement in this order:

1. strict skew-binomial tree;
2. immutable `List` child/deferred spines;
3. primitive skew queue insertion and linking;
4. primitive meld and rank normalization — **reject incompatible ordering or arena identity before allocating any merged result** (uses `ordering_identity_same` / `canonical_arena_same`; completes §7.2 meld acceptance on the primitive path);
5. primitive delete-min normalization;
6. bootstrapped queue representation; internal generated record carries ordering-identity bundle, orientation, and canonical arena identity;
7. empty, length, and peek;
8. bootstrapped insert;
9. bootstrapped meld — **same before-allocation incompatibility rejection as step 4**;
10. delete-min/pop;
11. min/max orientation adapter;
12. full validation.

Required trials:

- empty and singleton behavior;
- ascending, descending, duplicate, and adversarial priority streams;
- all rank-collision patterns reachable in bounded exhaustive tests;
- repeated meld trees, not just pairwise meld;
- pop order against a sorted test oracle;
- persistence of both meld operands and all older roots;
- rejection before allocation for incompatible ordering or arena identity (§7.2 acceptance — primitive meld step 4 and bootstrapped meld step 9);
- invalid comparator atom propagation;
- strictness: no hidden deferred thunk representation;
- rank, heap-order, cached-minimum, size, list-spine, and arena validation.
## 17. Persistent fixed-arity binary-tree core

**Dependencies:** §7.10 BinaryTree registration delta, canonical arenas, recursive tuples, checked arithmetic, immutable Silica `List` for paths and zipper breadcrumbs.
**Downstream consumers:** `tree_binary` / `BinaryTree` in §20; compiler-wide AST bridge and migration in the separate bootstrap-retirement plan.
**Normative design:** `[data_structure_designs/persistent_binary_tree.md](data_structure_designs/persistent_binary_tree.md)`.
**Trial leaf:** `trials/ordered_data_structures/binary_tree_core/` (landed 2026-09-18).

The core is unordered. It carries no comparator or ordering identity and does not depend on WBT, skew RAL, Brodal–Okasaki, rose-tree slots, or public trait dispatch.

Implement and gate these packages in order:

1. **Representation and smart construction**
   - inline recursive tuple `(item, subtree_node_count, left, right)`;
   - `:none` empty root/child;
   - private owning record with canonical arena, root, and specialization key;
   - one smart constructor deriving `1 + left_count + right_count` with checked arithmetic;
   - no production node allocation outside that constructor.
2. **Read-only root, child, and path navigation**
   - constant-time root/left/right helpers;
   - `List[:left | :right, SpaceType]` path traversal;
   - exact `:not_found | :found` behavior;
   - no binary-tree node allocation.
3. **Persistent item replacement**
   - rebuild target and root path;
   - preserve both target children;
   - share every unselected ancestor subtree;
   - return the identical root on a missing path.
4. **Persistent left/right subtree replacement**
   - preserve fixed child role and opposite sibling;
   - accept empty subtree as clear;
   - recompute checked counts at every copied ancestor;
   - reject incompatible arena before allocating a result path.
5. **Construction from child trees**
   - build one root over compatible left/right whole-tree operands;
   - verify both operands before allocation;
   - permit repeated physical subtree sharing and count each logical occurrence.
6. **Traversal and shape-preserving mapping**
   - preorder, inorder, and postorder folds;
   - callback paths in fixed-role order;
   - preorder/postorder maps that preserve shape;
   - no implicit equality calls to suppress rebuilt nodes.
7. **Inline functional zipper**
   - focus plus tagged left/right breadcrumbs with parent item and untouched sibling;
   - `open`, down-left/right, replace-focus-item/subtree, `up`, and `close`;
   - no named zipper/frame type;
   - downward movement allocates breadcrumb storage but no binary-tree node;
   - upward reconstruction uses only the smart constructor.
8. **Full validation**
   - arena, active-path acyclicity, cached counts, checked arithmetic, root count, and left/right role preservation;
   - legal repeated physical subtree references are not mistaken for cycles;
   - deterministic error precedence.
9. **Exhaustive and randomized hardening**
   - fixed-seed path update and zipper traces against a simple test-only binary-tree oracle;
   - validation after every update and on retained old roots;
   - operation counters for `O(h)` path updates and `O(n)` traversal/map;
   - scalar and composite item specializations across supported spaces.

Required directed artifacts:

- `binary_tree_inline_recursive_shape`;
- `binary_tree_arena_specialization`;
- `binary_tree_smart_node_count`;
- `trial_collection_error_binary_tree_count_overflow`;
- `binary_tree_direct_child_queries`;
- `binary_tree_path_lookup`;
- `binary_tree_path_copy`;
- `binary_tree_graft_compatibility`;
- `binary_tree_fold_orders`;
- `binary_tree_map_shape`;
- `binary_tree_zipper_roundtrip`;
- `binary_tree_sharing_multiplicity`;
- `binary_tree_missing_path_noop`;
- `binary_tree_validate_invariants`;
- `binary_tree_validate_cycle_and_shared_subtree`;
- `binary_tree_randomized_oracle`;
- `binary_tree_complexity_observations`.

Each package must run leaf `make record-golden` / `make integrate` and the Phase 1 root `make integrate` before receiving a dated completion record. Update the requirements ledger as artifacts land.

### 17 exit gate

- §7.10 has passed; no test bypasses registered constructor/arena lowering.
- Empty, leaf, unary, and binary shapes compile, link, run, and validate.
- Every production node uses the checked smart constructor in the canonical arena.
- Root/child/path queries allocate no binary-tree nodes.
- Item and child replacement path-copy only the selected route and preserve old roots.
- Missing-path updates return the prior root.
- Subtree compatibility is checked before result allocation.
- Left and right roles are preserved through construction, replacement, mapping, zipper reconstruction, and validation.
- Preorder, inorder, and postorder match their independent oracle sequences.
- Zipper down/up/close round trips reproduce the source tree; focused changes rebuild only breadcrumbs.
- Repeated physical subtree sharing is accepted and counted by logical occurrence; cycles are rejected.
- Fixed-seed traces and complexity counters match the detailed design.
- The core compiles into the standard library without public `BinaryTree` trait wiring or compiler-AST-specific logic.

**§17 status (2026-10-16):** Complete in substance, with deviations. `stdlib/data_structures/tree_binary.silica` implements the owning record `{ root, compare_item, region, specialization_key }`, the node `(item, subtree_node_count, left, right)`, the sole checked smart constructor, path queries, item and child replacement, the three folds, shape-preserving maps, the inline zipper and `validate` (`:ok | :cycle | :wrong_arena | :negative_count | :size_mismatch | :count_overflow`). `binary_tree_core/` has 13 trial programs (`binary_tree_bracket`, `bt_compatibility`, `bt_empty_and_root`, `bt_folds`, `bt_generic_payloads`, `bt_maps`, `bt_node_and_queries`, `bt_persistence_sharing`, `bt_replace_children`, `bt_replace_item`, `bt_trait_dispatch`, `bt_validate`, `bt_zipper`); the directed-artifact names above were not used one-for-one. Not landed: `binary_tree_randomized_oracle`, `binary_tree_complexity_observations`, and a `trial_collection_error_binary_tree_count_overflow` (a checked `count_preflight/2` is exported). Deviations (module header): constructor record `{ compare_item }`, not `{}`; queries take a placeholder item; paths are built with `path_root/path_left/path_right` because atoms are numbered per unit; `mem(normal)` only.

### 17 exit gate (representation cores)

- Each core passes its complete invariant and randomized trace suite.
- Each core has a stable internal generated-type shape matching its detailed design, including ordering bundle and arena identity fields where the detailed design requires them (§7.2 representation-path completion).
- **§16:** primitive and bootstrapped meld reject incompatible ordering or arena identity before allocating a merged result; required trial above passes in `brodal_okasaki_core/`.
- **§17:** the persistent binary-tree core passes path-copy, zipper, logical-sharing, and active-path cycle validation suites after the §7.10 branch gate.
- No public leaf structure has been implemented.
- WBT, skew RAL, Brodal–Okasaki, and persistent binary-tree values can be compiled into the standard library without test-only runtime support.
## 18. Generic live WBT graph core

**Dependencies:** §10 and §9, canonical arenas, graph constructor records, graph trait substrate.

Implement one parameterized storage core with:

- outer node-ID WBT;
- inner target-keyed WBT set/map;
- separate `EdgeDataType`;
- internal `{to: NodeIdType, data: EdgeDataType}` wrappers;
- directedness-specific update helpers;
- cached logical vertex, edge, and adjacency counts;
- deterministic vertex and neighbor folds;
- ordering bundle and arena identity;
- validation shared by all live graph variants.

The core must not:

- expose the internal edge wrapper as the public edge-data type;
- use `compare_edge_data` to place neighbors;
- silently add absent endpoint vertices unless the detailed design says so;
- implement `remove_vertex`;
- inspect CSR or dense records.
**§18 status (2026-10-16):** Complete (landed 2026-09-18). `graph_wbt_core.silica` is the shared engine (outer WBT map node to inner WBT map target to value, over `wbt_map`); the generated modules are `graph_wbt_directed`, `graph_wbt_undirected`, `graph_weighted` (weighted directed) and `graph_weighted_undirected`. Trials: `graph_live_core/` (17 programs, among them `gl_validate`, `gl_persistence_sharing`, `gl_large_oracle`, `gl_generic_payloads`, `gl_record_edge_data`, `gl_tuple_node_ids`; the two `defect_generic_payload_*` programs there passed after the boxed record layout).

## 19. `Heap`

**Dependencies:** §16 and Layer 1 trait substrate.
**Downstream consumer:** `PriorityQueue` shares this core and ordering machinery.

Implement:

- `brodal_okasaki_min` and `brodal_okasaki_max`;
- constructor resolution and orientation identity (Layer 1 §7.9 lowering on public `@empty` / `singleton`);
- required and provided `Heap` methods;
- `empty`, `push`, `peek`, `pop`, `meld`, `from_list`, and `validate`;
- exact incompatibility and empty behavior — **`meld` returns `{heap: left, compatible: false}` without allocating a merged heap when ordering or arena identity differs** (re-verifies §7.2 and §16 on the public trait surface).

Acceptance must run identical abstract traces against min and max orientations and verify opposite pop order, including meld incompatibility trials aligned with `heap_trait.md`.

**§19 status (2026-10-16):** Complete (landed 2026-09-18). `Heap.silica` (required `len`, `peek`, `compare_item`; provided `is_empty`) over `brodal_okasaki_min` / `brodal_okasaki_max`. The `heap_*` programs in `heap_collections/` (`heap_duplicates`, `heap_empty_and_singleton`, `heap_from_list`, `heap_generic_payloads`, `heap_large_runs`, `heap_meld`, `heap_persistence`, `heap_push_pop_order`, `heap_trait_dispatch`, `heap_validate`) are 10 of that leaf's 23. Deviations are in the `Heap.silica` header: `peek` takes a placeholder item, and a `Heap[...]` binding is accepted only for an `@empty` call.
## 20. `tree_binary` and `BinaryTree`

**Dependencies:** §17, §7.10 family registration, trait substrate.
**Downstream consumer:** optional compiler-wide AST bridge/migration in `bootstrap_retirement_and_self_host_plan.md`; that migration is not part of this structure's acceptance gate.
**Normative design:** `[data_structure_designs/binary_tree_trait.md](data_structure_designs/binary_tree_trait.md)`.
**Trial leaf:** planned `trials/standard_data_structures_phase1/binary_tree/`.

Implement:

- exact `BinaryTree[ItemType, mem(SpaceType)]` generated family;
- constructor record `{ compare_item: fn(ItemType, ItemType) -> :less | :equal | :greater }` for `empty`, `with_root`, and `node` (decision 2026-10-16);
- `tree_binary@empty`, `@with_root`, and compatible left/right node construction;
- required trait methods for count, empty, root/path/child queries, and three fold orders;
- representation-module item, left, and right replacement/clear operations;
- shape-preserving preorder/postorder maps;
- inline zipper operations with no named zipper or frame type;
- validation export and deterministic failure records;
- specialization-safe link names and trait implementations.

Acceptance trials:

- `binary_tree_trait_dispatch`: required/provided dispatch and specialization separation;
- `binary_tree_empty_root_children`: empty, leaf, left-only, right-only, and binary cases;
- `binary_tree_node_graft`: compatible independently constructed subtrees and before-allocation mismatch rejection;
- `binary_tree_replace_item` and `binary_tree_replace_children`: flags, counts, fixed roles, sharing, and old-root persistence;
- `binary_tree_fold_map`: exact preorder/inorder/postorder and shape-preserving maps;
- `binary_tree_zipper_public_surface`: inline zipper type flows through all exported operations and closes correctly;
- `binary_tree_inline_surface_compile`: no user-defined node/path/frame/zipper alias is required or emitted;
- `binary_tree_failure_matrix`: empty/missing paths, empty child descent, incompatible graft, and overflow;
- `binary_tree_validate`: valid and malformed fixtures, including legal shared subtrees versus cycles;
- `binary_tree_string_example`: detailed-design example through normal trait/module syntax;
- generic payload matrix with scalar, string, tuple/record, function-containing, and supported-space witnesses where legal.

### 20 exit gate

- The complete `binary_tree_trait.md` ledger section has landed artifacts.
- `tree_binary` builds through the normal standard-library path with no test-only runtime dependency.
- Empty-record construction is unambiguous only with sufficient declared/argument witnesses and never creates an ordering bundle.
- Trait methods and generated operations preserve the exact inline recursive representation contract.
- All persistent updates and zipper reconstruction preserve old roots and untouched subtree sharing.
- Public surface source contains no named node, path, option, result, frame, or zipper type.
- `BinaryTree` and rose `Tree` have distinct type, module, trait, path, update, and invariant behavior.
- BinaryTree acceptance is complete without converting the compiler parser AST.

**§20 status (2026-10-16):** Complete in substance, with deviations. `BinaryTree.silica` is the trait (required `node_count`, `root_item`, `get`, `left_item`, `right_item` and the three folds; provided `is_empty`) over `tree_binary`. The `BinaryTree[ItemType, mem(normal)]` bracket type is accepted (`binary_tree_bracket`). The trials are in `binary_tree_core/` (e.g. `bt_trait_dispatch`, `bt_zipper`, `bt_validate`); `binary_tree/` was never created and the `binary_tree_*` public-surface trial names above were not used. Not landed: `binary_tree_inline_surface_compile`, `binary_tree_failure_matrix`, `binary_tree_string_example` and the constructor-record compile-fail trials (see §7.10).

### 20 exit gate (public backends)

- `OrderedSet`, `OrderedMap`, `Heap`, and `BinaryTree` pass their complete detailed-design suites.
- Their generated records and methods link without specialization collisions.
- **§14:** join/split/concat reopen checkpoint is dated (reaffirmed deferral or accepted mini-gate).
- **§19:** public `Heap@meld` incompatibility behavior matches §16 before-allocation rejection (left heap unchanged, `compatible=false`).
- WBT set/map backends are usable internally without dispatching through public traits where representation code requires direct operations.
- The accepted BinaryTree backend is available to the downstream bootstrap-retirement AST bridge without making that bridge part of the standard-structure gate.
- Search, priority-queue, tree, and graph leaves remain unimplemented.
## 21. Directed live graph

Implement `graph_wbt_directed` and `DirectedGraph` conformance:

- vertex insertion and membership;
- directed edge insertion, replacement/no-op behavior, and removal;
- out-degree, neighbor traversal, edge fold, and connected query;
- exact vertex/edge counts;
- lookup and missing-endpoint behavior.
**§21 status (2026-10-16):** Complete (landed 2026-09-18). `graph_wbt_directed` plus the `DirectedGraph` trait (`DirectedGraph.silica`); trials `gl_directed_vertices`, `gl_directed_add_edge`, `gl_directed_remove_edge`, `gl_directed_payloads`, `gl_directed_folds_reachable` and `graph_collections/gc_directed_trait`.

## 22. Undirected live graph

Implement `graph_wbt_undirected` and `UndirectedGraph` conformance:

- two directional wrappers for each non-loop logical edge;
- one wrapper for a self-loop;
- atomic persistent update/removal of both directions;
- logical edge count distinct from adjacency-entry count;
- symmetry validation;
- `EdgeDataType = unit` convenience path for unweighted construction.
**§22 status (2026-10-16):** Complete (landed 2026-09-18). `graph_wbt_undirected` plus `UndirectedGraph.silica`; trials `gl_undirected_symmetry`, `gl_unit_edges` and `graph_collections/gc_undirected_trait`, `gc_undirected_trait_weighted`.

## 23. Weighted live graphs

**Dependencies:** accepted directed and undirected storage behavior plus `WeightedGraph` trait substrate.

Implement weighted directed and weighted undirected modules:

- edge data remains separate from the internal wrapper;
- weight extraction uses the designed function record;
- replacement updates edge data and weight atomically;
- undirected reverse wrappers carry comparator-equal data/weight;
- weight validity behavior matches the detailed design;
- a weighted value implements the applicable direction trait and the independent `WeightedGraph` trait.
**§23 status (2026-10-16):** Complete (landed 2026-09-18). `graph_weighted`, `graph_weighted_undirected` plus `WeightedGraph.silica`; trials `gl_weighted_directed`, `gl_weighted_undirected`, `gl_record_edge_data` and `graph_collections/gc_weighted_trait`, `gc_weighted_trait_undirected`.

## 24. Live-graph acceptance matrix

Run every graph operation against:

- empty, isolated-vertex, single-edge, self-loop, cycle, disconnected, and duplicate-edge cases;
- directed and undirected forms;
- unweighted and weighted forms;
- top-level comparator and captured-closure comparator identities;
- old roots after every update;
- validation of outer WBT, every inner WBT, wrappers, counts, symmetry, and arena.

Add randomized traces checked against a simple mathematical graph oracle. The oracle is test-only and must not become a standard-library implementation.

### 24 exit gate (live graphs)

- All live graph modules pass the matrix.
- Query algorithms consume graph traits rather than generated record fields.
- Weighted values satisfy both independent trait contracts.
- The deterministic node/neighbor fold order needed by CSR freeze is stable.
- CSR and dense remain dependency-blocked until their graph/index/buffer prerequisites are accepted.
**§24 exit gate status (2026-10-16):** Met as far as the ledger records it: the matrix is spread over the `graph_live_core/` programs, with `gl_large_oracle` as the randomized oracle comparison and `gl_validate` as the validation sweep. Graph algorithms written once over a trait (one copy per implementation) are in `graph_collections/`.

## 25. `SearchTree`

**Dependencies:** accepted `wbt_set`, `OrderedSet`, multi-trait conformance.

Implement `SearchTree` as the designed behavioral view:

- the concrete value is the same generated WBT-set value;
- one concrete type implements both `OrderedSet` and `SearchTree`;
- construction and updates remain `wbt_set` operations;
- search behavior, fold order, comparator identity, validation, and complexity are unchanged.

Do not create a second representation, copy the tree, or add an independent arena.
**§25 status (2026-10-16):** Complete (landed 2026-09-18). `SearchTree.silica` is a trait over the same `wbt_set` value as `OrderedSet` (required `contains_key`, `compare_item`; no provided block); `search_tree_collections/` has 14 programs (`st_*`, `ordered_set_field_annotation`, `ordered_set_field_projection`). The `SearchTree`-typed-parameter defect noted when it landed is fixed: `st_parameter_accepts_updated_tree` passes (its header records the former `compile_defects_search_tree_parameter_addition`).

## 26. `PriorityQueue`

**Dependencies:** accepted §16 Brodal–Okasaki core, Heap ordering machinery, trait substrate.

Implement:

- priority/value entry payloads that move together;
- the exact constructor bundle for priority and tie/value comparison;
- push, peek, pop, meld, bulk construction, and validation;
- deterministic duplicate/tie behavior;
- ordering and arena compatibility checks.

Do not implement arbitrary-entry deletion, handles, or decrease-key.
**§26 status (2026-10-16):** Complete (landed 2026-09-18). `PriorityQueue.silica` (required `len`, `peek`; provided `is_empty`, `peek_priority`, `peek_value`) over `brodal_okasaki_priority`; trials are the `pq_*` programs of `heap_collections/` (`pq_duplicates`, `pq_empty`, `pq_from_entries`, `pq_generic_payloads`, `pq_item_type_is_value`, `pq_large_runs`, `pq_meld`, `pq_persistence`, `pq_priority_type_composite_result`, `pq_push_pop_lexicographic`, `pq_state_in_fn_record_list`, `pq_trait_dispatch`, `pq_validate`). Deviations are in the `brodal_okasaki_priority` header (placeholders spelled `KeyType`/`ValueType`, comparator pair carried twice, entries carry their comparators, placeholder arguments to `peek`).

## 27. `Tree`

**Dependencies:** §15, exact item comparator identity, canonical arenas, trait substrate.

Implement:

- `tree_rose` node and root construction;
- reverse-oriented skew-RAL child slots;
- stable path lookup;
- add child and add subtree;
- remove child by leaving a tombstone/vacant slot;
- replace and traversal;
- cached live-node counts and validation;
- compatibility checks before subtree sharing.

Do not reuse, compact, or renumber vacant child slots.

`Tree` remains the arbitrary-arity stable-slot rose tree. It does not reuse the fixed-role BinaryTree core, and `BinaryTree` does not implement or replace this trait.

### 27 exit gate (terminal structures)

- All three terminal structures pass their detailed-design trials.
- SearchTree shares rather than duplicates `OrderedSet` representation.
- PriorityQueue exposes no decrease-key/deletion surface.
- Tree preserves every path index across removal and all later updates.
**§27 status (2026-10-16):** Complete (landed 2026-09-18). `tree_rose.silica` (child slots are a reversed skew RAL forest spine; the stdlib exports `add_leaf/3` because `add_child` is a supervisor built-in name) and `Tree.silica` (8 required methods, no provided block). `tree_collections/` has 16 programs (`rt_*`, `tree_field_annotation`). The `Tree[ItemType, mem(normal)]` bracket type is accepted (`tree_field_annotation`). Eight numbered deviations are in the `tree_rose` header.

## 28. Shared deterministic node-slot assignment

**Entry requirements (before §28):**

Do not begin §28 until:

- live WBT graph modules are accepted;
- WBT `from_sorted` and map indexing are accepted;
- skew RAL is accepted;
- runtime-sized buffer and checked-arithmetic trials pass;
- all graph query traits are accepted independently of representation.

Implement one internal slot-assignment procedure used by CSR and dense construction:

1. fold live node IDs in comparator order;
2. assign dense slots `0..n-1`;
3. construct a node-ID-to-slot WBT map;
4. preserve a slot-to-node sequence;
5. reject overflow before allocating final storage;
6. retain ordering identity and canonical arena provenance required by the concrete design.

Acceptance proves identical live graph values receive identical slot assignments.

Public IDs use `NodeIdType` and assigned slots use `int64`. Test fixtures must include non-integer IDs as well as sparse integer IDs to prove that implementations never use an ID directly as a slot.
**§28 status (2026-10-16):** Implemented inside `graph_csr_core.silica` and `graph_dense_core.silica` rather than as a separate shared module (comparator-order fold, slots `0..n-1`, `node_to_slot` WBT map, slot-to-node sequence); exercised by `gcsr_directed_freeze`, `gcsr_generic_payloads`, `gd_universe`, `gd_generic_payloads`. Whether both cores call one shared procedure was not verified.

## 29. CSR snapshots

**Dependencies:** live graph modules, shared slot assignment, WBT map, runtime-sized immutable buffers.

Implement freeze as a staged construction:

1. validate or trust only an accepted live graph input;
2. assign slots;
3. count adjacency entries with checked arithmetic;
4. allocate exact offsets and adjacency buffers;
5. compute prefix sums;
6. fill neighbors in deterministic per-source comparator order;
7. fill edge data/weights in aligned corresponding positions;
8. publish the immutable snapshot only after construction succeeds;
9. expose graph query-trait conformance;
10. expose no mutation operation.

Required trials:

- empty, isolated, sparse, self-loop, directed, undirected, and weighted snapshots;
- offset monotonicity and final-offset equality;
- neighbor public-ID membership and deterministic ordering;
- logical edge/count equivalence with the source;
- query equivalence between the live graph and snapshot;
- source persistence and snapshot immutability;
- exact-size allocation and overflow rejection;
- malformed-buffer validation through safe test fixtures.
**§29 status (2026-10-16):** Complete (landed 2026-09-18). `graph_csr_core` plus `graph_csr_directed`, `graph_csr_undirected`, `graph_csr_weighted`, `graph_csr_weighted_undirected`; `graph_csr_core/` has 9 programs (`gcsr_directed_freeze`, `gcsr_undirected`, `gcsr_weighted`, `gcsr_validate`, `gcsr_snapshot_isolation`, `gcsr_equivalence_large`, `gcsr_generic_payloads`, `gcsr_record_edge_data`, `defect_generic_payload_csr_record_data`). Not trialed: the overflow-rejection path of freeze (unreachable in a trial; ledger row CSR §9).

## 30. Dense matrix graphs

**Dependencies:** shared slot assignment, WBT node index, skew RAL, graph traits, checked `n * n`.

Implement:

- fixed vertex universe;
- row-major checked cell indexing;
- one skew-RAL persistent cell sequence;
- boolean cells for unweighted graphs;
- `:none | (:some, EdgeDataType)` cells for attributed/weighted graphs;
- directed and undirected edge updates;
- atomic symmetric update for non-loop undirected edges;
- weighted cell data where applicable;
- deterministic neighbor traversal;
- graph query-trait conformance and validation.

Required trials:

- `0x0`, `1x1`, and several rectangular index positions within square `n x n` storage;
- first/last cell and overflow boundaries;
- directed, undirected, self-loop, weighted, and missing-vertex behavior;
- old matrices after updates;
- symmetry and count invariants;
- live WBT versus dense query equivalence for the same fixed vertex universe.

### 30 exit gate (CSR and dense graphs)

- CSR and dense concrete types match the compiler-version-private representation contract.
- WBT, CSR, and dense values remain distinct concrete types without a runtime representation tag.
- Every representation returns identical abstract graph answers for shared fixtures.
- CSR exposes no mutation path.
- Dense vertex universes cannot grow through edge updates.
- No graph algorithm depends on WBT, CSR, or dense fields.
**§30 status (2026-10-16):** Complete with one deviation (landed 2026-09-18). `graph_dense_core` plus `graph_dense_directed`, `graph_dense_undirected`, `graph_dense_weighted`, `graph_dense_weighted_undirected`; `graph_dense_core/` has 9 programs (`gd_universe`, `gd_directed_updates`, `gd_undirected`, `gd_weighted`, `gd_validate`, `gd_equivalence`, `gd_generic_payloads`, `gd_record_edge_data`, `defect_generic_payload_dense_record_data`). Deviation: cells are optional references (`ref?`) for every family, not boolean or `:none | (:some, EdgeDataType)` cells (`graph_dense_core.silica` header, deviation 1; see CSR-D5/D6 in the ledger). `graph_collections/` (20 programs) runs the three graph traits over live, CSR and dense values, and `gd_equivalence` / `gcsr_equivalence_large` compare them against the live graph.

## 31. Standard-library build integration

Add the new source hierarchy to the standard-library build:

- trait modules;
- shared internal cores;
- generated representation modules;
- registry/configuration entries;
- emitted library artifacts;
- dependency declarations in build files.

Build order must mirror this plan:

1. common substrate;
2. representation cores;
3. reusable backends;
4. live graphs;
5. terminal structures;
6. CSR/dense;
7. cross-representation trials.

Do not restore deleted legacy source merely to satisfy an old build entry. Remove or replace stale entries with the new design-authoritative modules.
**§31 status (2026-10-16):** Done. `trials/ordered_data_structures/Makefile` builds the 57 modules in `SDS_STDLIB_MODULES` once into a stdlib cache and every leaf reuses them; `make gate-stdlib` compares the cached objects with `stdlib_goldens/`. `gate-stdlib` is not part of `integrate` and reported 8 diffs against Sep 12 goldens on 2026-09-18 (`wbt_set`, `wbt_map`, six `skew_ral` units); the current count has not been re-measured.

## 32. Full specialization matrix

Compile and run representative specializations across:

- primitive and structural keys/items;
- top-level and closure comparators;
- multiple memory spaces supported in Phase 1;
- BinaryTree scalar/composite payloads, `{ compare_item }` construction, and zipper signatures;
- min and max heaps;
- directed and undirected graphs;
- unweighted and separate edge-data types;
- weighted edge data;
- empty and large values.

The matrix should emphasize distinct layout shapes, not every combinatorial repetition.
## 33. Cross-representation graph conformance

For each applicable graph fixture:

1. construct a live WBT graph;
2. freeze it to CSR;
3. construct the equivalent dense graph;
4. run only public trait queries;
5. compare vertex membership, neighbors, connected, degrees, edge fold, counts, edge data, and weights;
6. compare deterministic traversal order where the designs promise it.

Any disagreement is a failed representation, not permission to weaken the trait.
## 34. Persistence and allocation stress

For every persistent update family:

- retain a sample of old roots;
- perform long branching update histories;
- re-query every retained root;
- validate structural sharing where observable through test-only instrumentation;
- verify allocations occur only in the canonical arena;
- verify semantic no-ops return the prior root where the detailed design promises that optimization;
- for BinaryTree, distinguish legal repeated physical subtree sharing from cycles and count repeated logical occurrences correctly.
## 35. Negative and diagnostic suite

Cover:

- invalid comparator result;
- comparator identity mismatch;
- heap orientation mismatch;
- canonical arena mismatch;
- wrong constructor record;
- unresolved trait placeholder;
- missing trait method;
- generated link-name collision attempts;
- invalid index/path;
- absent lookup and empty pop/peek;
- duplicate sorted input;
- integer overflow;
- malformed CSR offsets;
- dense-capacity overflow;
- graph endpoint and representation misuse;
- ambiguous, empty (`{}`) or extra-field BinaryTree constructor records;
- BinaryTree missing paths, incompatible subtree arenas, count overflow, and malformed cycles.

Diagnostics must be deterministic and must not depend on allocator addresses.
## 36. Complexity guardrails

Use operation counters or bounded stress thresholds rather than wall-clock microbenchmarks to detect:

- accidental linear WBT search/update;
- accidental whole-tree copying;
- non-logarithmic skew-RAL lookup/update;
- accidental sorting during WBT `from_sorted`;
- repeated-growth CSR construction instead of exact allocation;
- full-matrix traversal for a query whose design promises a narrower bound;
- heap operations that flatten and rebuild the entire queue;
- BinaryTree path updates that copy nodes outside the selected route;
- BinaryTree zipper movement that re-traverses from the root or rebuilds more than one ancestor per `up`.

These guardrails verify algorithm shape; they are not a performance-tuning project.
## 37. Documentation synchronization

Before declaring completion:

- link this plan from the Phase 1 design index;
- ensure every generated module name matches the detailed designs;
- ensure examples compile against the final trait and constructor syntax;
- update design status only after its acceptance gate passes;
- leave exclusions explicit rather than creating placeholder APIs;
- cross-link BinaryTree's downstream compiler-AST migration to `bootstrap_retirement_and_self_host_plan.md` without making that migration a standard-structure acceptance gate.

### 37 exit gate (Phase 1 complete)

Phase 1 is complete only when:

- the normal compiler and standard-library build succeed from a clean checkout;
- every new trial passes;
- all ten public traits have accepted implementations;
- WBT live, CSR, and dense graph answers agree through public traits;
- all invariants and compatibility failures are covered;
- no source, build entry, documentation link, or trial depends on the removed implementation;
- the requirements-to-trials ledger has no unexplained gaps;

**§32–§36 status (2026-10-16):** There is no dedicated suite for these sections. What exists is per-leaf: `*_generic_payloads` programs in every leaf (string, tuple and record payloads), the memory-space matrix in `compiler_substrate/collection_ordered_set_space_matrix`, `wbt_persistence_fanout`, `ral_persistence_fanout`, `gl_persistence_sharing` and the `*_large_*` / `*_oracle` programs, `wbt_complexity_observations`, and the compile-fail trials in `trials/error_enforcement_addition/standard_data_structures/` (18). Not landed: the `cross_representation/` three-way conformance leaf (the same comparison is made inside `gd_equivalence` and `gcsr_equivalence_large`), BinaryTree complexity counters, and a negative suite for heap orientation mismatch, malformed CSR offsets and dense-capacity overflow.

**§37 status (2026-10-16):** Open. Phase 1 is not declared complete: the ledger still has `planned` rows (see its status header), the `terminal_structures`, `live_graphs`, `snapshot_graphs` and `cross_representation` leaves contain only `smoke_harness_ready`, and the BinaryTree constructor-record compile-fail trials and `StubBinaryTree` (§7.10) are not written.

## 38. Compiler parser AST → BinaryTree (withdrawn)

Withdrawn 2026-09-29. The compiler's `Expr` stays an index arena; no migration to `BinaryTree` is planned. The number is kept so later references stay valid.

## 39. Concrete execution queue

Sections §6–§37 are the authoritative serial queue. Complete each section in order.

1. Layer 0 baseline (§6). **(complete)**
2. Layer 1 compiler/runtime substrate (§7). **(complete)**
3. WBT core (§8 / §8A). **(complete 2026-07-16)**
4. `wbt_map` and `OrderedMap` (§9). **(complete)**
5. `wbt_set` and `OrderedSet` (§10). **(complete)**
6. Self-host source prerequisites on `src/` only: crafted BST → WBT, then alias ban (§11). **(complete)**
7. Additive build-selfhost / ABI hardening on the parallel tree (§12). **(exit gate met 2026-09-02; the selfhost binary runs all trials; bootstrap now builds only the seed)**
8. Fixed-point + cutover / bootstrap retirement (§13). **(fixed points reached on the hosted platforms, see §13 status; bootstrap retirement not verified)**
9. Join/split reopen checkpoint (§14). **(deferral reaffirmed in code; ledger record owed)**
10. Skew binary random-access-list core (§15). **(implemented 2026-09-08 ahead of §13 at Lee's direction; see §15 status)**
11. Brodal–Okasaki core (§16). **(complete 2026-09-18; see section status)**
12. Persistent binary-tree core (§17). **(complete 2026-09-18; see section status)**
13. Generic live WBT graph core (§18). **(complete 2026-09-18; see section status)**
14. `Heap` (§19). **(complete 2026-09-18; see section status)**
15. `tree_binary` and `BinaryTree` (§20). **(complete 2026-09-18; see section status)**
16. Directed live graph (§21). **(complete 2026-09-18; see section status)**
17. Undirected live graph (§22). **(complete 2026-09-18; see section status)**
18. Weighted live graphs (§23). **(complete 2026-09-18; see section status)**
19. Live-graph acceptance matrix (§24). **(complete 2026-09-18; see section status)**
20. `SearchTree` (§25). **(complete 2026-09-18; see section status)**
21. `PriorityQueue` (§26). **(complete 2026-09-18; see section status)**
22. `Tree` (§27). **(complete 2026-09-18; see section status)**
23. Shared graph node-slot assignment (§28). **(complete 2026-09-18; see section status)**
24. CSR snapshot variants (§29). **(complete 2026-09-18; see section status)**
25. Dense graph variants (§30). **(complete 2026-09-18; see section status)**
26. Full integration and hardening (§31–§37). **(§31 done; §32–§37 partial, see status)**
27. Phase 1 complete at §37 exit gate.


## 40. Definition of done by structure


| Public structure  | Required accepted dependencies                                 | Completion artifact                                                 |
| ----------------- | -------------------------------------------------------------- | ------------------------------------------------------------------- |
| `OrderedSet`      | substrate, WBT core                                            | trait + `wbt_set` + full design trials                              |
| `OrderedMap`      | substrate, WBT core                                            | trait + `wbt_map` + full design trials                              |
| `Heap`            | substrate, Brodal–Okasaki core                                 | trait + min/max modules + full design trials                        |
| `DirectedGraph`   | substrate, WBT set/map, live graph core                        | trait + live module; CSR/dense conformance after §30            |
| `UndirectedGraph` | substrate, WBT set/map, live graph core                        | trait + symmetric live module; CSR/dense conformance after §30  |
| `WeightedGraph`   | directed/undirected live foundations, separate edge-data model | trait + weighted live variants; CSR/dense conformance after §30 |
| `SearchTree`      | accepted `OrderedSet` representation and multi-trait support   | trait adapter over identical WBT-set value                          |
| `PriorityQueue`   | accepted §16 Brodal–Okasaki core and ordering bundle               | trait + priority/value module, without decrease-key                 |
| `Tree`            | accepted skew RAL and stable-slot semantics                    | trait + `tree_rose`, without compaction                             |
| `BinaryTree`      | §7.10 and §17            | trait + `tree_binary` + zipper and full design trials               |


**Implementation status (2026-10-16):** every row is implemented; the completion artifacts are the stdlib modules and trial leaves named in the §16–§30 status records. `BinaryTree` was completed with the `{ compare_item }` constructor record (decision 2026-10-16), without the rest of the §7.10 delta. Exceptions to "full design trials": see the ledger `planned` rows.

For graph traits, public-trait completion and representation-family completion are tracked separately. A live implementation can be accepted before CSR/dense, but the graph representation family is not complete until §30 passes.

## 41. Stop conditions

Stop downstream implementation and return to the failed dependency when:

- a detailed design and executable type shape disagree;
- canonical arena identity cannot be represented without changing a public type;
- exact closure identity is not stable through lowering/emission;
- recursive type support requires an unplanned ownership or lifetime rule;
- a representation cannot validate its stated invariant;
- a consumer needs an operation excluded from its dependency's design;
- a proposed CSR/dense layout violates the closed compiler-version-private representation contract;
- a proposed convenience API would add behavior excluded by the detailed designs.
- BinaryTree construction cannot be witnessed without weakening constructor ambiguity checks (resolved 2026-10-16 by the witness field `{ compare_item }`).

The remedy is to correct or explicitly revise the authoritative design, then resume from the affected gate. It is not to hide the discrepancy inside a generated module.
