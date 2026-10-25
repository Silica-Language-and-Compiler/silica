# Layer 0 §6.1 — Normative Inputs Baseline

**Recorded:** 2026-06-29  
**Status:** Accepted baseline for Phase 1 standard data structures implementation; amended 2026-07-02 for `BinaryTree`
**Authority:** [`standard_data_structures_implementation_plan.md`](../standard_data_structures_implementation_plan.md) §6.1  
**Repository snapshot:** `main` at `df118756e30bd973b69cd935e439be233dffc1e7` (pin file contents with `git log -1 -- <path>` before each downstream layer gate)

## Purpose

This file records the normative design inputs and the implementation reset baseline required by Layer 0 §6.1. All Phase 1 implementation work must trace to these documents and must **not** copy behavior from removed stdlib modules or pre-reset trials.

---

## 1. Parent design documents

| Document | Role | Header date | Path |
|---|---|---|---|
| Algorithm map | Locked algorithm-family choices | 2026-06 (reviewed) | [`data_structure_to_algorithms.md`](../data_structure_to_algorithms.md) |
| Trait architecture | Trait surfaces, constructor records, generated-module wiring | 2026-06-29 | [`data_structures_as_traits.md`](../data_structures_as_traits.md) |
| Implementation plan | Dependency order and acceptance gates only | 2026-06-29 | [`standard_data_structures_implementation_plan.md`](../standard_data_structures_implementation_plan.md) |
| CSR/dense contract | Closed snapshot/dense representation rules (§6.4) | 2026-06-29 | [`csr_dense_representation_contract.md`](csr_dense_representation_contract.md) |
| Requirements ledger | Design-section → trial coverage map (§6.3) | 2026-06-29 | [`requirements_to_trials_ledger.md`](requirements_to_trials_ledger.md) |
| Bootstrap retirement context | Compiler-internal migration targets; not API authority | — | [`bootstrap_retirement_and_self_host_plan.md`](../bootstrap_retirement_and_self_host_plan.md) |

**Conflict resolution (normative):**

1. `data_structure_to_algorithms.md` — algorithm families  
2. `data_structures_as_traits.md` — trait architecture and constructor-record model  
3. `data_structure_designs/` — detailed APIs, representations, invariants  
4. `standard_data_structures_implementation_plan.md` — sequencing only  

If the implementation plan disagrees with a detailed design on behavior, the detailed design wins and the plan must be corrected.

---

## 2. Detailed design suite (`data_structure_designs/`)

Every file below is normative for Phase 1. All inherit [`common_contract.md`](../data_structure_designs/common_contract.md), including the [overriding genericity rule](../data_structure_designs/common_contract.md#overriding-genericity-rule).

| File | Covers |
|---|---|
| [`README.md`](../data_structure_designs/README.md) | Suite index, authority rule, representation map |
| [`common_contract.md`](../data_structure_designs/common_contract.md) | Shared type model, comparators, arenas, results, validation |
| [`ordered_set_trait.md`](../data_structure_designs/ordered_set_trait.md) | `OrderedSet` + `wbt_set` |
| [`ordered_map_trait.md`](../data_structure_designs/ordered_map_trait.md) | `OrderedMap` + `wbt_map` |
| [`search_tree_trait.md`](../data_structure_designs/search_tree_trait.md) | `SearchTree` (WBT-set view) |
| [`directed_graph_trait.md`](../data_structure_designs/directed_graph_trait.md) | `DirectedGraph` live/query trait |
| [`undirected_graph_trait.md`](../data_structure_designs/undirected_graph_trait.md) | `UndirectedGraph` live/query trait |
| [`weighted_graph_trait.md`](../data_structure_designs/weighted_graph_trait.md) | `WeightedGraph` capability trait |
| [`heap_trait.md`](../data_structure_designs/heap_trait.md) | `Heap` + min/max modules |
| [`priority_queue_trait.md`](../data_structure_designs/priority_queue_trait.md) | `PriorityQueue` |
| [`tree_trait.md`](../data_structure_designs/tree_trait.md) | `Tree` + `tree_rose` |
| [`binary_tree_trait.md`](../data_structure_designs/binary_tree_trait.md) | `BinaryTree` + `tree_binary` |
| [`weight_balanced_tree.md`](../data_structure_designs/weight_balanced_tree.md) | Adams WBT core `(3, 2)` |
| [`persistent_binary_tree.md`](../data_structure_designs/persistent_binary_tree.md) | Persistent fixed-role binary-tree core + inline zipper |
| [`live_wbt_graph.md`](../data_structure_designs/live_wbt_graph.md) | Live adjacency WBT representation |
| [`csr_graph_snapshot.md`](../data_structure_designs/csr_graph_snapshot.md) | CSR freeze and query |
| [`dense_matrix_graph.md`](../data_structure_designs/dense_matrix_graph.md) | Dense RAL-backed graph |
| [`skew_binary_random_access_list.md`](../data_structure_designs/skew_binary_random_access_list.md) | Skew binary RAL core |
| [`brodal_okasaki_queue.md`](../data_structure_designs/brodal_okasaki_queue.md) | Brodal–Okasaki shared heap/PQ core |

**Public traits (ten after the 2026-07-02 amendment):** `OrderedSet`, `OrderedMap`, `SearchTree`, `DirectedGraph`, `UndirectedGraph`, `WeightedGraph`, `Heap`, `PriorityQueue`, `Tree`, `BinaryTree`.

The BinaryTree amendment does not alter the recorded 2026-06-29 repository snapshot or historical nine-family Layer 1 status. It adds a new normative family and requires the implementation-plan §7.10 substrate delta before its representation work starts.

**Rejected parallel paths (do not implement):** finger trees, Patricia/crit-bit tries, HAMT, lazy/bootstrapped primary heaps, persistent vectors, dense bitset graphs, d-ary array heaps, Hinze priority-search queues, obsolete bootstrap modules (`btree_*`, `graph_adj_*`, `heap_binary_*`, node-id B-trees).

---

## 3. Language substrate designs

These documents govern compiler/runtime features required before representation cores (implementation plan Layer 1).

### 3.1 Recursive tuples and region references

| Document | Scope |
|---|---|
| [`recursive_tuple_specification.md`](../../recursive_tuple_specification.md) | `rec`, `ref?(R, Space, T)`, `:none`, `alloc_rec`, occurs check |
| [`silica-specification.md`](../../silica-specification.md) §4.2.2 (recursive tuples), §22 (region/buffer ops) | Authoritative language definition |

**Normative encoding for collection nodes:** recursive inline tuples with optional `ref?(R, Space, rec)` child slots; construction via `alloc_rec(region, (…))` in the collection's canonical arena; empty child position is `:none`. `rec` binds to the innermost enclosing tuple type; a root, parameter or return is spelled with the full node tuple, and an unbound `rec` is E2010 (Q19, data_structure_redesign_requirements.md).

### 3.2 Runtime-sized immutable buffers

| Document | Scope |
|---|---|
| [`silica-specification.md`](../../silica-specification.md) §4.x / buffer types | `buf(L, Space, T, N)` with literal or runtime `int64` extent `N`; `alloc_buf` |
| [`list_implementation_design.md`](../../list_implementation_design.md) | Immutable `List[T, S]` (dependency for skew RAL spine and dense graph cells) |
| [`csr_graph_snapshot.md`](../data_structure_designs/csr_graph_snapshot.md) §extent model | CSR `V`, `V_PLUS_ONE`, `A` as runtime-sized internal extents |
| [`dense_matrix_graph.md`](../data_structure_designs/dense_matrix_graph.md) §extent model | Dense `V`, `V*V` runtime-sized internal extents |

**Normative rule:** runtime-sized buffer capacities are checked `int64` values at construction time; they are internal representation extents, not public graph type parameters. Layer 1 §7.8 adds compiler checked-arithmetic builtins and buffer bounds/overflow enforcement on the `alloc_buf` / `read_buf` path (trials `checked_int64_overflow`, `runtime_buf_dynamic_size`).

### 3.3 Supplementary (non-authoritative for API shape)

| Document | Use |
|---|---|
| [`graph_representation_design.md`](../../graph_representation_design.md) | Historical/supplementary; defer to `data_structure_designs/` for Phase 1 API |
| [`balanced_tree_and_heap_design.md`](../../balanced_tree_and_heap_design.md) | Referenced from trait overview; superseded for Phase 1 by `weight_balanced_tree.md` and `brodal_okasaki_queue.md` |

---

## 4. Reset baseline — what is **not** normative

### 4.1 Removed / empty stdlib

At baseline recording, `compiler/stdlib/data_structures/` contains **no** Phase 1 generated modules. Prior bootstrap modules (`btree_*`, `graph_adj_*`, `heap_binary_*`, phase-04 graph/set/map sources) are **removed** and must not be revived by copy-paste.

The only stdlib unit under `stdlib/` at baseline is `Supervisor` (unrelated actor trait).

### 4.2 Pre-reset trials — do not copy

The following trial trees exercise **obsolete** representations or pre-reset compiler fixtures. They may inform compiler-substrate gaps but are **not** acceptance templates for Phase 1:

| Trial root | Why non-normative |
|---|---|
| `trials/standard_data_structures_phase04_addition/` | `btree_*`, `graph_adj_*`, `heap_binary_*`, node-id CSR adapters |
| `trials/btree_nodeid_addition/` | Node-id B-tree experiments |
| `trials/btree_set_addition/` | B-tree set experiments |
| `trials/standard_data_structures_addition/` | Pre-reset structure registry |
| `trials/error_enforcement_addition/standard_data_structures_phase04/` | Constructor/trait checks tied to phase-04 stubs |

Phase 1 acceptance trials belong under `trials/ordered_data_structures/` ([`README.md`](../../../../trials/ordered_data_structures/README.md); Layer 0 §6.2 complete; the directory was named `trials/standard_data_structures_phase1/` when this baseline was recorded).

### 4.3 Deleted design backups

Files matching `*.silica.bak`, removed `*_phase04.sams` / `*_phase04.silica` in `stdlib/data_structures/`, and similar deleted artifacts in git status are **not** inputs.

---

## 5. Compiler collection type-witness and trait behavior (as of baseline)

This section records **current** compiler support against the normative designs. Gaps listed here are Layer 1 work, not reasons to weaken the designs.

### 5.1 Primary implementation unit

[`src/type_checker/type_checker_collections.silica`](../../../src/type_checker/type_checker_collections.silica) — header comment: “Phase 0.4” partial collection/trait typing.

### 5.2 Bracket-type parsing and witnesses (present)

| Collection type | Parsed | Constructor witness fields checked |
|---|---|---|
| `OrderedSet[Item, mem(Space)]` | yes | `compare_item` |
| `OrderedMap[Key, Value, mem(Space)]` | yes | `compare_key`, `compare_value` |
| `Heap[Item, mem(Space)]` | yes | **`compare_priority`** (design: `compare_item`) |
| `DirectedGraph[NodeId, Edge, mem(Space)]` | yes (3 bracket params) | `compare_node`, `compare_edge`, `edge_target` |

**Not yet parsed / witnessed in `type_checker_collections.silica`:**

- `SearchTree[…]`
- `UndirectedGraph[…]`
- `WeightedGraph[…]`
- `PriorityQueue[Priority, Item, mem(Space)]`
- `Tree[Item, mem(Space)]`
- `BinaryTree[Item, mem(Space)]` (added after the recorded baseline; §7.10 delta)

### 5.3 Comparator return typing (partial)

- `expected_compare_*_fn_type` helpers require `:less | :equal | :greater`.
- `comparator_return_type_ok` still accepts bare `atom` (transitional); normative designs and `data_structures_as_traits.md` require the three-atom union only.

### 5.4 Assoc-type placeholders (partial)

`is_assoc_type_placeholder/1` recognizes: `ItemType`, `KeyType`, `ValueType`, `SpaceType`, `SetType`, `MapType`, `HeapType`, `NodeIdType`, `EdgePayloadType`, `PriorityType`, `WeightType`, `AccType`.

Missing vs designs: `EdgeDataType`, `GraphType`, `QueueType`, `TreeType`, `BinaryTreeType`, and other trait-module placeholders used in detailed trait signatures.

### 5.5 Trait machinery (general — present for non-collection traits)

| Capability | Location | Phase 1 collection status |
|---|---|---|
| `export trait`, `required`, `provided` syntax | parser, module_checker, trait_checker | **present** — substrate trials in `compiler_substrate/lib/` |
| `impl fn` / marker `impl Type;` | parser, module_checker | **present** — trait dispatch trials; collection WBT/graph/heap impls deferred to representation cores |
| Trait call dispatch (`Trait@method`) | type_checker traits pipeline, SIR link mangling | **present** — first-arg receiver dispatch, structural impl match, ambiguity/missing-method diagnostics |
| Provided-method default bodies | trait_specialization monomorphization | **present** — provided bodies call trait methods; override via explicit `impl fn`; multi-param receiver fix (§7.4) |
| Assoc-type placeholders | type_checker_collections | **present** — `GraphType`, `QueueType`, `TreeType`, `EdgeDataType`, `WeightType`, `AccType` |

### 5.6 Recursive tuples and `alloc_rec` (Layer 1 §7.3 complete)

| Capability | Status |
|---|---|
| Lexer/parser `rec` keyword + `ref?` syntax | present (`lexer_recursion_phases.silica`, `parser_tuples.silica`) |
| `alloc_rec` type checking + effect checker, SIR, emitter | present (emitter aliases `alloc_ref` allocation path) |
| Occurs-checked recursive type equality | present (`type_checker_recursive_tuples.silica`) |
| Acceptance trials (one-node, multi-node, fn/list payloads, compile-fail) | `recursive_tuple_alloc_fixture`, `recursive_tuple_multi_node`, `recursive_tuple_fn_in_node`, `recursive_tuple_list_in_node`; compile-fail in `error_enforcement/` |

### 5.7 Canonical arena registry (present — Layer 1 §7.1)

| Capability | Location | Status |
|---|---|---|
| Application-lifetime lookup table | `canonical_arena_runtime_asm.silica` → `_silica_rt_canonical_arena_lookup` | **present** |
| Arena identity comparison | `_silica_rt_canonical_arena_same` | **present** |
| Silica surface | `canonical_arena_lookup(int64)` → `region(L, Space)`; `canonical_arena_same(region, region)` → `boolean` | **present** (prims in `prims_memory.silica`; type checker / SIR / effect checker wired) |
| Stable specialization key | int64 constant per `(family, representation, type args, memory space)` via `collection_specialization_key/2` | **present** (Layer 1 §7.6) |
| Constructor lowering to canonical arena | collection constructors | **present** (Layer 1 §7.5 — `collection_constructor_calls.silica`; trials `constructor_canonical_arena_lowering`) |
| Mismatch diagnostics | deterministic compile/runtime errors for missing arena | **not yet** |

**Acceptance trials (2026-06-29):** `compiler_substrate/canonical_arena_reuse`, `canonical_arena_different_specialization`, `canonical_arena_different_space` — `make record-golden` and `make integrate` pass.

### 5.8 Exact function-value ordering identity (present — Layer 1 §7.2)

| Capability | Location | Status |
|---|---|---|
| Environment instance ids for closures | `_silica_rt_ordering_env_fresh` | **present** |
| Token materialization | `_silica_rt_ordering_identity_make` | **present** |
| Token / bundle comparison | `_silica_rt_ordering_identity_same`, `_silica_rt_ordering_bundle_make` | **present** |
| Silica surface | `ordering_identity_materialize(fn)`, `ordering_identity_same`, `ordering_identity_bundle_make(fn_token, orient)` | **present** |
| Closure env binding | `name.__oid_env` side binding on `fn` let with fresh env for lifted lambdas | **present** |
| Constructor bundle lowering | collection constructors | **present** (Layer 1 §7.9 — `collection_constructor_calls.silica`; trials `constructor_ordering_bundle`, `constructor_stub_empty_run`) |
| Builtin calls from user-defined helpers | SIR lowering in nested functions | **partial** — top-level / sequence trials only |

**Acceptance trials (2026-06-29):** `ordering_identity_top_level`, `ordering_identity_closure_copy`, `ordering_identity_closures`, `ordering_identity_orientation`, `ordering_identity_meld_reject` — pass `make record-golden` and `make integrate`.

### 5.9 Runtime-sized buffer hardening (partial)

`alloc_buf`, `buf_load`, `buf_store`, runtime extent in type strings — present in language pipeline. CSR-specific freeze-fill immutability and overflow rejection trials — **not** part of Phase 1 trial root yet (Layer 1 §7.8, Layer 6).

### 5.10 Known compiler–design mismatches to fix in Layer 1 (not baseline changes)

| Issue | Normative source | Current compiler |
|---|---|---|
| Heap constructor field name | `compare_item` (`heap_trait.md`, `data_structures_as_traits.md`) | `compare_priority` in witnesses |
| Collection trait count | ten public traits after BinaryTree amendment | nine families completed in Layer 1; BinaryTree §7.10 delta pending |
| Provided/required split | each `*_trait.md` | not enforced for collections |
| Comparator bare `atom` | `common_contract.md` §4, trait designs | still accepted by `comparator_return_type_ok` |

Implementation status (2026-10-16): this table is the 2026-06-29 baseline. The comparator rule is enforced (`trial_compile_fail_comparator_bare_atom`), all ten traits exist with provided/required blocks (`stdlib/data_structures/*.silica`), and the BinaryTree family is registered in the type checker; the Heap field-name row and the BinaryTree constructor record (`{ compare_item }` by decision 2026-10-16, not `{}`; §7.10) were not re-verified.

---

## 6. §6.1 acceptance statement

- [x] Parent design documents identified and linked  
- [x] Every `data_structure_designs/*.md` file listed  
- [x] BinaryTree amendment documents and downstream §7.10 delta recorded
- [x] Recursive-tuple and runtime-buffer language authorities identified  
- [x] Current compiler collection witness and trait behavior recorded with explicit gaps  
- [x] Reset baseline declared: no copying from removed stdlib or pre-reset trials  

## 6.4 Closed CSR/dense representation contract

**Artifact:** [`csr_dense_representation_contract.md`](csr_dense_representation_contract.md)  
**Ledger:** [`requirements_to_trials_ledger.md`](requirements_to_trials_ledger.md) §6.4 (`CSR-D1` … `CSR-D7`)

| Clause | Summary |
|---|---|
| CSR-D1 | Private inline layouts; no user field access |
| CSR-D2 | `NodeIdType` public IDs vs `int64` internal slots |
| CSR-D3 | Runtime extents `V`, `A`, `V*V` not public type parameters |
| CSR-D4 | CSR parallel `neighbors` + `edge_data` buffers |
| CSR-D5 | Dense unweighted single boolean RAL sequence |
| CSR-D6 | Dense weighted single `:none \| (:some, EdgeDataType)` RAL sequence |
| CSR-D7 | Distinct WBT / CSR / dense concrete generated types |

---

**Layer 0 status:** §6.1–§6.4 complete. **Exit gate verified 2026-06-29:** `make record-golden` and `make integrate` pass in `trials/standard_data_structures_phase1/` (now `trials/ordered_data_structures/`) (root `.integrate_counts`: `21 0`).

**Layer 1 §7.1 status:** Canonical arena registry and acceptance trials complete (2026-06-29).

**Layer 1 §7.3 status:** Complete (2026-06-29).

**Layer 1 §7.5 status:** Constructor function-record resolution complete (2026-06-29). All nine public families parse, validate, and witness constructor records; exact field-name validation; module/representation matching; canonical arena injection at constructor let-bindings; int64 literal pool collects constants inside `case` branches. Positive trials: `compiler_substrate/` → `constructor_record_resolution`, `constructor_record_field_order`, `constructor_canonical_arena_lowering`. Compile-fail goldens: `error_enforcement/` → `trial_compile_fail_constructor_*`. **Integrate verified:** `compiler_substrate/`, `error_enforcement/`, and repo `error_enforcement_addition`.

**BinaryTree amendment status (2026-07-02):** Normative design added after the nine-family Layer 1 gate. Historical §7.5/§7.6/§7.9 completion remains valid for those nine families; BinaryTree parsing, `{ compare_item }` constructor-record resolution, registry identity, lowering, and runnable stub coverage are pending implementation-plan §7.10 and block only BinaryTree-dependent work.

**Layer 1 §7.6 status:** Collection type witnesses and representation registry complete (2026-07-01). Representation-based module registry for all concrete families; stable specialization keys; registered-module gating and E2017 for unregistered construction modules; constructor arena/spec-key injection in function-body and `sequence proc` lets. Positive trials: `compiler_substrate/` → `collection_bracket_type_parse`, `collection_registry_specialization_distinct`, `collection_record_not_collection`. Compile-fail goldens: `error_enforcement/` → `trial_compile_fail_collection_bracket_missing_mem`, `trial_compile_fail_collection_unregistered_module`. **Integrate verified:** phase-1 root `84 0`. Proceed to Layer 1 §7.7.

**Layer 1 §7.7 status:** Common result and error plumbing complete (2026-07-01). Comparator return types must be `:less | :equal | :greater`; lookup-result records require `status: :not_found | :found` plus a separate payload field; runtime builtins `comparator_result_valid` / `comparator_result_validate` validate comparator atoms at run time. Positive trials: `compiler_substrate/` → `comparator_result_valid`, `comparator_result_validate`, `collection_lookup_status_shape`. Compile-fail goldens: `error_enforcement/` → `trial_compile_fail_comparator_bare_atom`, `trial_compile_fail_lookup_status_union`. **Integrate verified:** `compiler_substrate/` `52 0`, `error_enforcement/` `16 0`, phase-1 root `84 0`. Proceed to Layer 1 §7.9 (constructor runtime lowering — Layer 1 exit gate).

**Layer 1 §7.8 status:** Checked arithmetic and runtime-sized buffers complete (2026-07-01). Builtins `checked_int64_add`, `checked_int64_mul`, `checked_int64_add1`, and `checked_int64_byte_size` return `(boolean, int64)`; `alloc_buf` rejects negative and overflowing sizes with element-type-aware allocation; buffer access emits bounds checks from runtime capacity in type metadata. Positive trials: `compiler_substrate/` → `checked_int64_overflow`, `runtime_buf_dynamic_size`. **Integrate verified:** `compiler_substrate/` `54 0`, phase-1 root `86 0`. Proceed to Layer 1 §7.9.

**Layer 1 §7.9 status:** Constructor runtime lowering and ordering-bundle injection complete (2026-07-01). Registered constructor lets merge stub returns with canonical arena, specialization key, and `{field}_ordering_bundle` side bindings (named bindings; `_` discard omits bundles). Positive trials: `compiler_substrate/` → `constructor_canonical_arena_lowering`, `constructor_record_field_order`, `constructor_record_resolution`, `constructor_stub_empty_run`, `constructor_ordering_bundle`. **Integrate verified:** `compiler_substrate/` `60 0`. **Layer 1 exit gate** satisfied for §7.1–§7.9 substrate criteria; proceed to Layer 2 §8.

**Layer 1 §7.2 remaining acceptance (scheduled):** meld/subtree rejection before allocation — Layer 2 §8C steps 4/9 and exit gate; re-verified at Layer 3 §9C public `Heap@meld`.
