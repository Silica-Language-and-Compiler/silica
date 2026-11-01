# Layer 0 §6.3 — Requirements-to-Trials Ledger

**Recorded:** 2026-06-29  
**Status:** Coverage map (Layer 0), amended 2026-07-02 for BinaryTree; synchronized with the landed trials 2026-10-16. Rows marked "was not landed" (and the one planned `csr_freeze_overflow_fail`) have no trial; stems elsewhere name programs that exist
**Authority:** [`standard_data_structures_implementation_plan.md`](../standard_data_structures_implementation_plan.md) §6.3–§6.4  
**Trial root:** [`trials/ordered_data_structures/`](../../../../trials/ordered_data_structures/) (formerly `trials/standard_data_structures_phase1/`). Compile-fail trials: `trials/error_enforcement_addition/standard_data_structures/`. Leaves named below without a path prefix are under the trial root.

## Purpose

Every numbered section in the Phase 1 detailed design suite must appear here with at least one coverage artifact:

| Kind | Code | Meaning |
|---|---|---|
| **Trial** | `T` | Runnable acceptance trial under a dependency leaf (`.silica` + `.ascomp` + `.scout`, or runtime-error `.scout`) |
| **Compile-time** | `C` | Expected compile failure (`.golden_fail`) or compile-only fixture |
| **Invariant** | `I` | Non-executable mathematical or structural rule; checked by `validate/1` or design review until a trial exists |
| **Out-of-scope** | `O` | Explicit exclusion copied from the design; must not be implemented |

**Maintenance rule:** When a `T` or `C` trial lands, update the **Artifact** column and remove any provisional `I` for the same requirement. When §6.4 CSR/dense contract rows gain trials, update those rows in [§6.4](#64-closed-csrdense-representation-contract).

**Layer 0 smoke only:** `*/smoke_harness_ready.silica` verifies harness integration; it does **not** satisfy design-section coverage.

---

## Algorithm map — locked decisions

Source: [`data_structure_to_algorithms.md`](../data_structure_to_algorithms.md) §Locked decisions

| # | Decision | Kind | Artifact |
|---|---|---|---|
| 1 | Adams WBT for all `OrderedSet` key types | T | `ordered_collections/` → `wbt_set_empty_insert`; `wbt_core/` → `wbt_set_insert_duplicate`, `wbt_set_insert_orders` (**§8A.5 pass**) |
| 2 | No integer-key Patricia / crit-bit specialization | O | "None — no Patricia / crit-bit trie" |
| 3 | `OrderedMap` uses WBT map | T | `wbt_core/` → `wbt_map_insert_replace`, `wbt_map_insert_orders`, `wbt_map_canonical_key`, `wbt_map_value_pairing`, `wbt_map_compare_value_not_called`, `wbt_map_replace_persistence`, `wbt_map_insert_payload_shapes`, `wbt_map_insert_tuple_value`, `trial_collection_error_wbt_map_insert_invalid_comparator` (**§8A.6 pass**) |
| 4 | `SearchTree` same as `OrderedSet` (WBT) | T | `search_tree_collections/` → `st_ordered_set_agree`, `st_updates` (**§25 pass**) |
| 5 | Graph vertex index is WBT keyed by `compare_node` | T | `graph_live_core/` → `gl_directed_vertices`, `gl_directed_folds_reachable`, `gl_large_oracle` (**graph pass 2026-09-18**) |
| 6 | Unweighted neighbors: inner WBT **set** of targets | T | `graph_live_core/` → `gl_directed_add_edge`, `gl_unit_edges` (**graph pass 2026-09-18**) |
| 7 | Weighted neighbors: inner WBT map `to → edge data` | T | `graph_live_core/` → `gl_weighted_directed`, `gl_weighted_undirected`, `gl_undirected_symmetry` (**graph pass 2026-09-18**) |
| 8 | CSR = live WBT + optional O(V+E) freeze | T | `graph_csr_core/` → `gcsr_directed_freeze`, `gcsr_snapshot_isolation`, `gcsr_equivalence_large` (**graph pass 2026-09-18**) |
| 9 | Dense matrix = skew RAL cells (not bitset) | T | `graph_dense_core/` → `gd_directed_updates`, `gd_weighted`, `gd_equivalence`; cells are `ref?` optionals over `skew_ral` (graph_dense_core header deviation 1) (**graph pass 2026-09-18**) |
| 10 | Dense bitset graph not in scope | O | "Dense bitset graph — family removed" |
| 11 | `Tree` children = skew binary RAL | T | `skew_ral_core/` → `ral_prepend_head_tail`, `ral_lookup_boundaries`; `tree_collections/` → `rt_add_leaf_slots`, `rt_wide_node` (**pass 2026-09-18**) |
| 12 | `Heap` = Brodal–Okasaki | T | `brodal_okasaki_core/` → `bo_pop_order_oracle`, `bo_meld_tree` (**§16 pass**) |
| 13 | `PriorityQueue` = Brodal–Okasaki on pairs | T | `heap_collections/` → `pq_push_pop_lexicographic`, `pq_meld` (**pass 2026-09-18**) |
| 14 | No decrease-key / arbitrary PQ deletion in Phase 1 | O | "Decrease-key — not in Phase 1 PriorityQueue API" |
| 15 | Bulk WBT: fold insert + optional `from_sorted` O(n) | T | `wbt_core/` → `wbt_from_sorted_linear`, `wbt_from_sorted_persistence`, `wbt_persistence_fanout` (**§8A.8 / §8A.11**) |
| 16 | `BinaryTree` = fixed left/right persistent tree + zipper | T | `binary_tree_core/` → `bt_replace_item`, `bt_zipper` (**pass 2026-09-18**) |

---

## `common_contract.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Public bracket types for ten collection families | C | nine-family `collection_bracket_type_parse` (**§7.6 pass**); `BinaryTree` and `Tree` brackets accepted: `binary_tree_core/` → `binary_tree_bracket`, `tree_collections/` → `tree_field_annotation`; `binary_tree_bracket_type_parse` itself was not landed (§7.10 partial) |
| 1.1 | Overriding genericity rule — no hard-coded payload types | C | `trial_compile_fail_constructor_witness_mismatch` (in `error_enforcement_addition/standard_data_structures/`) |
| 2 | No user-defined surface aliases; inline shapes only | I | Design §2; emitter uses inline records only |
| 3 | Constructor resolves from binding type + possibly-empty function record + explicit value witnesses | C | nine-family constructor trials (**§7.5 pass**); BinaryTree takes `{ compare_item }` by decision 2026-10-16 (a witness the core never calls; `tree_binary.silica` header, deviation 1): `binary_tree_empty_constructor_record` and `trial_compile_fail_binary_tree_empty_unwitnessed` are not yet written (§7.10 partial) |
| 4 | Comparator returns only `:less \| :equal \| :greater` | T | `compiler_substrate/` → `comparator_result_valid`, `comparator_result_validate`; `error_enforcement_addition/standard_data_structures/` → `trial_compile_fail_comparator_bare_atom`; runtime: `bo_invalid_comparator_status`, `trial_collection_error_wbt_*_invalid_comparator` |
| 5 | Exact function-value ordering identity; no override | T | `compiler_substrate/` → `ordering_identity_top_level`, `ordering_identity_closure_copy`, `ordering_identity_closures`, `ordering_identity_orientation`, `ordering_identity_meld_reject` (**§7.2 pass**) |
| 6 | Query status `{status, value}`; update result shapes | T | `compiler_substrate/` → `collection_lookup_status_shape`; `error_enforcement_addition/standard_data_structures/` → `trial_compile_fail_lookup_status_union` |
| 7 | Canonical arena; path copying; no in-place mutation | T | `compiler_substrate/` → `canonical_arena_reuse`, `canonical_arena_different_specialization`, `canonical_arena_different_space` (**§7.1 pass**) |
| 8 | Recursive tuples, `ref?`, `alloc_rec` encoding | T | `compiler_substrate/` → `recursive_tuple_alloc_fixture`, `recursive_tuple_multi_node`, `recursive_tuple_fn_in_node`, `recursive_tuple_list_in_node`; `error_enforcement/` → `trial_compile_fail_recursive_type_mismatch`, `trial_compile_fail_unguarded_rec` (**§7.3 pass**) |
| 7.4 | Trait dispatch; required/provided; link-name mangling | T | `compiler_substrate/` → `trait_dispatch_provided_fold_contains`, `trait_dispatch_dual_trait_record`, `trait_dispatch_override_provided`, `trait_dispatch_link_mangle_specializations`; `error_enforcement/` → `trial_compile_fail_trait_dispatch_no_impl`, `trial_compile_fail_trait_assoc_unresolved`, `trial_compile_fail_trait_missing_required_impl` (**§7.4 pass**) |
| 7.6 | Collection type witnesses and representation registry | C | `compiler_substrate/` → `collection_bracket_type_parse`, `collection_registry_specialization_distinct`, `collection_record_not_collection`; `error_enforcement/` → `trial_compile_fail_collection_bracket_missing_mem`, `trial_compile_fail_collection_unregistered_module` (**§7.6 pass, integrate verified**) |
| 9 | Checked `int64` arithmetic rejects overflow | T | `compiler_substrate/` → `checked_int64_overflow`, `runtime_buf_dynamic_size` (**§7.8 pass, integrate verified**) |
| 7.9 | Constructor runtime lowering; ordering bundles on merge | C | `compiler_substrate/` → `constructor_canonical_arena_lowering`, `constructor_record_field_order`, `constructor_record_resolution`, `constructor_stub_empty_run`, `constructor_ordering_bundle` (**§7.9 pass, integrate verified `60 0`**; goldens re-recorded 2026-07-02 after constructor-arg marshaling fix) |
| 7.10 | BinaryTree family registration; `{ compare_item }` constructor lowering without ordering bundle | C | `binary_tree_core/` → `binary_tree_bracket` (family accepted by the checker); `StubBinaryTree`, `binary_tree_empty_constructor_record`, `binary_tree_stub_run` and the `trial_compile_fail_binary_tree_*` trials are not yet written |
| 10 | Trait vs generated-module separation | I | Design §10; stdlib module layout review |
| 11 | Materialization policy; internal fold hooks | T | `graph_live_core/` → `gl_directed_folds_reachable` (graph folds, no temporary lists) (**pass 2026-09-18**); `live_graphs/` → `neighbors_fold_no_temp` was not landed (`live_graphs/` holds only `smoke_harness_ready`) |
| 12 | `validate` result shape `{valid, error, logical_count}` | T | `wbt_core/` → `wbt_validate_malformed_fixture`; `binary_tree_core/` → `bt_validate`; also `bo_validate_invariants`, `ral_validate_invariants`, `gl_validate`, `gcsr_validate`, `gd_validate`, `heap_validate`, `pq_validate`, `rt_validate` |

---

## `weight_balanced_tree.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | WBT core boundary (shared set/map/graph index) | T | `stdlib/data_structures/wbt_set.silica`, `wbt_map.silica`; `wbt_core/` → `wbt_empty_representation`, `wbt_constructor_ordering_bundle` (**§8A.1 pass**) |
| 2 | Mathematical BST model with cached size | I | Design §2 |
| 3 | `(DELTA, GAMMA) = (3, 2)` balance definition | I | Design §3; HY11 reference |
| 4 | Logical node shapes (set vs map) | T | `wbt_core/` → `wbt_representation_specializations`, `wbt_representation_string_specialization`, `wbt_generic_payload_shapes`, `wbt_generic_tuple_map_empty` (**§8A.1 pass**) |
| 5 | Smart constructor with overflow-safe size | T | `stdlib/data_structures/wbt_set.silica`, `wbt_map.silica`; `wbt_core/` → `wbt_smart_node_size`, `wbt_smart_node_arena`, `wbt_smart_node_production_path`, `trial_collection_error_wbt_smart_node_overflow`; `check-wbt-alloc-rec-gate` (**§8A.3 pass**) |
| 6 | Search helpers | T | `stdlib/data_structures/wbt_set.silica`, `wbt_map.silica` (read-only exports); `wbt_core/` → `wbt_read_only_empty`, `wbt_search_contains`, `wbt_minimum_maximum`, `trial_collection_error_wbt_search_invalid_comparator` (**§8A.2 pass**) |
| 7 | `balance_left` / `balance_right` contract | T | `stdlib/data_structures/wbt_set.silica`, `wbt_map.silica`; `wbt_core/` → `wbt_balance_boundaries`, `wbt_rotation_single_left`, `wbt_rotation_single_right`, `wbt_rotation_double_left`, `wbt_rotation_double_right`, `wbt_rotation_gamma_equality`, `wbt_rebalance_adversarial`, `trial_collection_error_wbt_balance_missing_child` (**§8A.4 pass**) |
| 8 | Set insertion + duplicate no-op | T | `stdlib/data_structures/wbt_set.silica` (`insert/2`); `wbt_core/` → `wbt_set_insert_duplicate`, `wbt_set_insert_orders`, `wbt_set_insert_adversarial`, `wbt_set_insert_persistence`, `wbt_set_insert_sharing`, `wbt_set_insert_payload_shapes` (string payload matrix), `trial_collection_error_wbt_set_insert_invalid_comparator`; `compiler_substrate/` → `collection_ordered_set_space_matrix` (all supported `SpaceType` keys) (**§8A.5 pass**); trace hardening `wbt_oracle_harness_smoke`, `wbt_set_exhaustive_trace`, `wbt_set_randomized_oracle`, `wbt_persistence_fanout` (**§8A.11**) |
| 9 | Map insert/replace on duplicate key | T | `stdlib/data_structures/wbt_map.silica` (`insert/3`); `wbt_core/` → `wbt_map_insert_replace`, `wbt_map_insert_orders`, `wbt_map_canonical_key`, `wbt_map_value_pairing`, `wbt_map_compare_value_not_called`, `wbt_map_replace_persistence`, `wbt_map_insert_payload_shapes`, `wbt_map_insert_tuple_value`, `trial_collection_error_wbt_map_insert_invalid_comparator`; `check-wbt-alloc-rec-gate` (**§8A.6 pass**); trace hardening `wbt_oracle_harness_smoke`, `wbt_map_exhaustive_trace`, `wbt_map_randomized_oracle`, `wbt_persistence_fanout` (**§8A.11**) |
| 10 | Deletion + successor/min extraction | T | `stdlib/data_structures/wbt_set.silica`, `wbt_map.silica` (`delete/2`, `delete_min`, `delete_max`); `wbt_core/` → `wbt_delete_absent`, `wbt_delete_leaf`, `wbt_delete_one_child`, `wbt_delete_two_child`, `wbt_delete_root`, `wbt_delete_extreme`, `wbt_delete_heavier_side`, `wbt_delete_rebalance`, `wbt_delete_persistence`, `wbt_delete_payload_shapes`, `trial_collection_error_wbt_{set,map}_delete_invalid_comparator` (**§8A.7 pass**); exhaustive/randomized delete steps in `wbt_{set,map}_exhaustive_trace`, `wbt_{set,map}_randomized_oracle` (**§8A.11**) |
| 11 | Ordered fold / early-exit fold order | T | `wbt_core/` → `wbt_fold_ascending`, `wbt_read_only_alloc_free`, `wbt_weight_checked` (**§8A.2 pass**) |
| 12 | `from_sorted` linear O(n) builder | T | `wbt_core/` → `wbt_from_sorted_empty`, `wbt_from_sorted_singleton`, `wbt_from_sorted_two`, `wbt_from_sorted_shape`, `wbt_from_sorted_shape_large`, `wbt_from_sorted_set_map`, `wbt_from_sorted_ten_plus`, `wbt_from_sorted_valid_invalid`, `wbt_from_sorted_count_mismatch`, `wbt_from_sorted_map_invalid_two`, `wbt_from_sorted_linear`, `wbt_from_sorted_persistence`, `trial_collection_error_wbt_from_sorted_{set,map}_invalid_comparator` (**§8A.8 pass**); periodic rebuild cross-check in `wbt_persistence_fanout`; preflight bounds in `wbt_complexity_observations` (**§8A.11**) |
| 13 | Optional join/split (same balance law) | O | **Deferred Layer 2A (2026-07-15, §8A.9)**; **reopen at Layer 3 §9B.1** after `OrderedSet`/`OrderedMap` — reaffirm deferral or accept a named-consumer mini-gate; not part of initial §9A/§9B trait surface |
| 14 | Structural invariants (size, order, balance) | T | `wbt_core/` → `wbt_validate_invariants`, `wbt_validate_malformed_fixture`, `wbt_validate_error_precedence`, `wbt_validate_map_pairing` (**§8A.10 pass**); per-step validate in `wbt_oracle_harness_smoke`, `wbt_{set,map}_exhaustive_trace`, `wbt_{set,map}_randomized_oracle`, `wbt_persistence_fanout` (**§8A.11**) |
| 15 | Postorder validation algorithm | T | `wbt_core/` → `wbt_validate_malformed_fixture` (cycle/repeated), `trial_collection_error_wbt_validate_invalid_comparator` (**§8A.10 pass**) |
| 16 | Complexity table | T | `wbt_core/` → `wbt_complexity_observations` (trial-only search/order-walk compare counters + coarse height/size); invalid-comparator first/middle/last via `trial_collection_error_wbt_*` companions (**§8A.11**) |
| 17 | References | I | Bibliography only |

---

## `persistent_binary_tree.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Fixed-role persistent binary-tree boundary | I | Design §1 |
| 2 | Empty/node mathematical model and logical counts | I | Design §2 |
| 3 | Inline recursive tuple; no node alias | C | `binary_tree_core/` → `bt_node_and_queries`, `binary_tree_bracket` (**pass 2026-09-18**); `binary_tree_inline_recursive_shape` was not landed |
| 4 | Canonical arena + specialization owning record | T | `binary_tree_core/` → `bt_compatibility` (arena and specialization-key check), `bt_generic_payloads` (**pass 2026-09-18**) |
| 5 | Sole smart constructor with checked counts | T | `binary_tree_core/` → `bt_node_and_queries` (**pass 2026-09-18**); `trial_collection_error_binary_tree_count_overflow` not landed (checked `count_preflight/2` exported) |
| 6 | Constant-time root/child queries | T | `binary_tree_core/` → `bt_empty_and_root`, `bt_node_and_queries` (**pass 2026-09-18**) |
| 7 | `:left \| :right` path model | T | `binary_tree_core/` → `bt_node_and_queries` (**pass 2026-09-18**) |
| 8 | Persistent item/child replacement | T | `binary_tree_core/` → `bt_replace_item`, `bt_replace_children` (**pass 2026-09-18**) |
| 9 | Subtree graft arena compatibility | T | `binary_tree_core/` → `bt_compatibility` (**pass 2026-09-18**) |
| 10 | Pre/in/postorder folds and shape-preserving maps | T | `binary_tree_core/` → `bt_folds`, `bt_maps` (**pass 2026-09-18**) |
| 11 | Inline functional zipper | T | `binary_tree_core/` → `bt_zipper` (**pass 2026-09-18**) |
| 12 | Structural sharing and logical multiplicity | T | `binary_tree_core/` → `bt_persistence_sharing`, `bt_folds` (**pass 2026-09-18**) |
| 13 | Failure behavior | T | `binary_tree_core/` → `bt_empty_and_root`, `bt_replace_item` (**pass 2026-09-18**) |
| 14 | Structural invariants | T | `binary_tree_core/` → `bt_validate` (**pass 2026-09-18**) |
| 15 | Active-path cycle validation | T | `binary_tree_core/` → `bt_validate` (**pass 2026-09-18**) |
| 16 | Complexity bounds | I | Design §16; `binary_tree_complexity_observations` was not landed |
| 17 | Exclusions + Huet zipper reference | O | Design §17 exclusion list; bibliography |

---

## `skew_binary_random_access_list.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Abstract immutable sequence | I | Design §1 |
| 2 | Skew weights and digit invariant | I | Design §2; `skew_ral_core/` → `ral_weight_overflow` (skew-form and link-weight table) (**§15 pass**) |
| 3 | Tree + forest spine encoding | T | `stdlib/data_structures/skew_ral_node.silica`, `skew_ral_forest.silica`; `skew_ral_core/` → `ral_encoding_roundtrip` (**§15 pass**) |
| 4 | Prepend | T | `skew_ral_core/` → `ral_prepend_head_tail`, `ral_persistence_fanout` (**§15 pass**) |
| 5 | Head and tail | T | `skew_ral_core/` → `ral_prepend_head_tail` (lengths 0–20, empty head/tail `:not_found`) (**§15 pass**) |
| 6 | Logarithmic lookup | T | `skew_ral_core/` → `ral_lookup_boundaries` (first/middle/last/negative/past-end, lengths 1–17) (**§15 pass**) |
| 7 | Persistent update at index | T | `skew_ral_core/` → `ral_update_persistence`, `ral_persistence_fanout` (**§15 pass**) |
| 8 | Append convention for tree/dense consumers | T | `skew_ral_core/` → `ral_append_convention` (`reversed = true`: append, `get`/`set`, `logical_to_physical`; `reversed = false` declines) (**§15 pass**) |
| 9 | Bulk construction | T | `skew_ral_core/` → `ral_bulk_build` (`from_list` both orientations, `filled`, negative count, weight-overflow preflight) (**§15 pass**) |
| 10 | Fold and range traversal | T | `skew_ral_core/` → `ral_fold_range` (`fold_logical`/`fold_physical`, every `(start, count)` window of 20 items in both orientations, invalid ranges) (**§15 pass**) |
| 11 | Forest invariants | T | `skew_ral_core/` → `ral_validate_invariants` (size, rank/order/duplicate digit, missing tree, shape, arena, repeated child) (**§15 pass**) |
| 12 | Validation | T | `stdlib/data_structures/skew_ral_validate.silica`; `ral_validate_invariants`, `valid_with_count` in every positive trial (**§15 pass**) |
| 13 | Complexity | I | Design §13 bounds; `ral_fold_range` counts visits per window |
| 14 | Exclusions (no finger-tree RAL variant) | O | Design §14 explicit exclusions |

Genericity: `ral_generic_payloads` (string and tuple items through build/head/lookup/update/get/set/fold-of-strings). Fold with a tuple-typed callback parameter is a known bootstrap-emitter defect (plan §15 status); its repro is staged, not wired.

---

## `brodal_okasaki_queue.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Brodal–Okasaki algorithm identity | I | Design §1 |
| 2 | Min orientation; max via adapter (no negation) | T | `brodal_okasaki_core/` → `bo_max_orientation_adapter` (**§16 pass**) |
| 3 | Skew-binomial tree shape | I | Design §3 |
| 4 | Primitive forest invariant | T | `brodal_okasaki_core/` → `bo_rank_collisions`, `bo_validate_invariants` (**§16 pass**) |
| 5 | Bootstrapped representation | T | `brodal_okasaki_core/` → `bo_meld_tree`, `bo_from_list` (**§16 pass**) |
| 6 | Empty, peek, length | T | `brodal_okasaki_core/` → `bo_empty_peek` (**§16 pass**) |
| 7 | Insert O(1) | T | `brodal_okasaki_core/` → `bo_push_duplicate` (**§16 pass**) |
| 8 | Meld O(1); compatibility checks | T | `brodal_okasaki_core/` → `bo_meld_incompatible`, `bo_meld_tree` (**§16 pass**) |
| 9 | Delete-min | T | `brodal_okasaki_core/` → `bo_pop_order_oracle`, `bo_pop_persistence` (**§16 pass**) |
| 10 | Delete-min normalization | T | `brodal_okasaki_core/` → `bo_pop_order_oracle`, `bo_pop_persistence` (**§16 pass**) |
| 11 | Persistence and strict bootstrapping | T | `brodal_okasaki_core/` → `bo_old_heap_valid_after_pop` (**§16 pass**) |
| 12 | Rank/size/arena invariants | T | `brodal_okasaki_core/` → `bo_validate_invariants` (**§16 pass**) |
| 13 | Validation | T | `brodal_okasaki_core/` → `bo_validate_invariants` (**§16 pass**) |
| 14 | Complexity bounds | I | Design §14 table |
| 15 | Out of scope (decrease-key, array heaps, …) | O | Design §15 bullet list |

---

## `live_wbt_graph.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Outer WBT map + inner set/map adjacency | T | `graph_live_core/` → `gl_directed_add_edge`, `gl_undirected_symmetry`, `gl_weighted_directed` (**graph pass 2026-09-18**) |
| 2 | Outer record fields | I | Design §2 layout |
| 3 | Explicit vertices; auto-add on edge (directed) | T | `graph_live_core/` → `gl_directed_vertices`, `gl_directed_add_edge` (**graph pass 2026-09-18**) |
| 4 | Directed insertion semantics | T | `graph_live_core/` → `gl_directed_add_edge`, `gl_directed_payloads`, `gl_large_oracle` (**graph pass 2026-09-18**) |
| 5 | Undirected symmetric insertion | T | `graph_live_core/` → `gl_undirected_symmetry`, `gl_unit_edges`, `gl_weighted_undirected` (**graph pass 2026-09-18**) |
| 6 | Removal without vertex delete | T | `graph_live_core/` → `gl_directed_remove_edge`, `gl_large_oracle` (**graph pass 2026-09-18**) |
| 7 | Queries (`has_vertex`, `has_edge`, degree) | T | `graph_live_core/` → `gl_directed_folds_reachable`, `gl_undirected_symmetry` (**graph pass 2026-09-18**) |
| 8 | Ordering of neighbors | T | `graph_live_core/` → `gl_directed_folds_reachable`, `gl_large_oracle` (**graph pass 2026-09-18**) |
| 9 | Count invariants (self-loop rules) | T | `graph_live_core/` → `gl_undirected_symmetry`, `gl_validate`, `gl_large_oracle` (**graph pass 2026-09-18**) |
| 10 | Path copying persistence | T | `graph_live_core/` → `gl_persistence_sharing` (**graph pass 2026-09-18**) |
| 11 | Validation complexity | T | `graph_live_core/` → `gl_validate` (**graph pass 2026-09-18**) |
| 12 | Complexity table | I | Design §12 bounds |

---

## `csr_graph_snapshot.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Snapshot-only semantic role | I | Design §1; no incremental CSR update |
| 2 | Deterministic dense slot assignment | T | `graph_csr_core/` → `gcsr_directed_freeze`, `gcsr_generic_payloads` (**graph pass 2026-09-18**) |
| 3 | Physical buffer shape | I | Design §3; see [§6.4](#64-closed-csrdense-representation-contract) |
| 4 | Freeze algorithm O(V+A) | T | `graph_csr_core/` → `gcsr_directed_freeze`, `gcsr_equivalence_large` (**graph pass 2026-09-18**) |
| 5 | Offset monotonicity invariant | T | `graph_csr_core/` → `gcsr_validate` (**graph pass 2026-09-18**) |
| 6 | Query behavior via traits | T | `graph_collections/` → `gc_csr_directed_trait`, `gc_csr_undirected_trait`, `gc_csr_weighted_trait`, `gc_csr_weighted_undirected_trait`; `graph_csr_core/` → `gcsr_directed_freeze` (**graph pass 2026-09-18**) |
| 7 | Directed/undirected count equations | T | `graph_csr_core/` → `gcsr_undirected`, `gcsr_equivalence_large` (**graph pass 2026-09-18**) |
| 8 | Immutable trait conformance | I | Design §8; no runtime mutation API |
| 9 | Freeze failure leaves live graph valid | T | `graph_csr_core/` → `gcsr_snapshot_isolation` (freeze leaves the live graph unchanged); overflow failure path not reachable in a trial (planned `csr_freeze_overflow_fail`) (**graph pass 2026-09-18**) |
| 10 | Validation checks | T | `graph_csr_core/` → `gcsr_validate` (**graph pass 2026-09-18**) |
| 11 | Complexity | I | Design §11 table |

---

## `dense_matrix_graph.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Fixed-vertex dense use case | I | Design §1 boundary |
| 2 | `node_to_slot` WBT index | T | `graph_dense_core/` → `gd_universe`, `gd_generic_payloads` (**graph pass 2026-09-18**) |
| 3 | Cell index `from * V + to` | I | Design §3 formula |
| 4 | Physical RAL cell sequence | I | Design §4; see [§6.4](#64-closed-csrdense-representation-contract) |
| 5 | Construction for fixed V | T | `graph_dense_core/` → `gd_universe`, `gd_directed_updates` (**graph pass 2026-09-18**) |
| 6 | Edge updates (no auto-add vertex) | T | `graph_dense_core/` → `gd_directed_updates`, `gd_undirected`, `gd_weighted` (**graph pass 2026-09-18**) |
| 7 | Neighbor traversal scans row | T | `graph_dense_core/` → `gd_directed_updates`, `gd_equivalence` (**graph pass 2026-09-18**) |
| 8 | Query/update bounds | I | Design §8 |
| 9 | Persistence via RAL path copy | T | `graph_dense_core/` → `gd_directed_updates`, `gd_undirected` (**graph pass 2026-09-18**) |
| 10 | Invariants | T | `graph_dense_core/` → `gd_validate`, `gd_undirected` (**graph pass 2026-09-18**) |
| 11 | Validation | T | `graph_dense_core/` → `gd_validate` (**graph pass 2026-09-18**) |
| 12 | Complexity | I | Design §12 table |
| 13 | Representation choice rule | I | Design §13 vs live WBT |

---

## `ordered_set_trait.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Immutable multiset with unique comparator classes | I | Design §1 |
| 2 | Type + `{compare_item}` constructor | C | `error_enforcement/` → `trial_compile_fail_ordered_set_constructor_{missing,extra}_field` (**§10 pass**) |
| 3 | Trait `required`/`provided` split | T | `ordered_collections/` → `ordered_set_trait_dispatch`, `ordered_set_empty_public` (**§10 pass**) |
| 4 | `wbt_set` module surface | T | `ordered_collections/` → `wbt_set_empty_insert`, `ordered_set_from_sorted` (**§10 pass**) |
| 5 | Insert/delete/contains semantics | T | `ordered_collections/` → `ordered_set_duplicate_insert` (**§10 pass**) |
| 6 | Empty + invalid comparator failures | T | `ordered_collections/` → `ordered_set_invalid_comparator` (**§10 pass**; deep invalid-comparator remains in `wbt_core/`) |
| 7 | WBT invariants delegated to core | T | `wbt_core/` → `wbt_validate_invariants`, `wbt_validate_malformed_fixture` (**§8A.10 pass**) |
| 8 | Persistence and memory effects | T | `ordered_collections/` → `ordered_set_persistence` (**§10 pass**) |
| 9 | Complexity | I | Design §9 table |
| 10 | Example usage | T | `ordered_collections/` → `ordered_set_string_example` (**§10 pass**) |
| 11 | Exclusions | O | "No hash-set, insertion-order iteration, integer trie, …" |

---

## `ordered_map_trait.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Finite key→value map | I | Design §1 |
| 2 | `{compare_key, compare_value}` constructor | C | `error_enforcement/` → `trial_compile_fail_ordered_map_constructor_{missing,extra}_field` (**§9 pass**) |
| 3 | Trait contract | T | `ordered_collections/` → `ordered_map_trait_dispatch`, `ordered_map_empty_public` (**§9 pass**) |
| 4 | `wbt_map` module surface | T | `ordered_collections/` → `wbt_map_get_insert` (**§9 pass**) |
| 5 | Key identity; replace on duplicate | T | `ordered_collections/` → `ordered_map_insert_replace` (**§9 pass**) |
| 6 | Get/contains/fold/find_value | T | `ordered_collections/` → `ordered_map_find_value_linear` (**§9 pass**) |
| 7 | Delete by key | T | `ordered_collections/` → `ordered_map_delete_absent` (**§9 pass**) |
| 8 | `from_list` / `from_sorted` bulk | T | `ordered_collections/` → `ordered_map_from_sorted` (**§9 pass**) |
| 9 | Empty/failure behavior | T | `ordered_collections/` → `ordered_map_not_found_status` (**§9 pass**) |
| 10 | Invariants | T | `wbt_core/` → `wbt_validate_invariants`, `wbt_validate_map_pairing` (**§8A.10 pass**) |
| 11 | Persistence | T | `ordered_collections/` → `ordered_map_persistence` (**§9 pass**) |
| 12 | Complexity | I | Design §12 table |
| 13 | Example | T | `ordered_collections/` → `ordered_map_string_example` (**§9 pass**) |
| 14 | Exclusions | O | Design §14 exclusion list |
| — | `compare_value` unused on key paths | T | `ordered_collections/` → `ordered_map_compare_value_not_called` (**§9 pass**) |

---

## `search_tree_trait.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Behavioral view over WBT set | I | Design §1 |
| 2 | Same record as `OrderedSet` | T | `stdlib/data_structures/SearchTree.silica`; `search_tree_collections/` → `st_ordered_set_agree` (both views of one value, both bracket families), `st_empty_and_singleton`, `st_parameter_accepts_updated_tree` (an updated tree is accepted by a `SearchTree`-typed parameter; the former open defect `compile_defects_search_tree_parameter_addition` is fixed) (**§25 pass**) |
| 3 | `contains_key` + `compare_item` required | T | `search_tree_collections/` → `st_contains_key`, `st_compare_item`, `st_trait_dispatch`, `st_generic_payloads`, `st_composite_payloads` (**§25 pass**) |
| 4 | Updates via `wbt_set` only | T | `search_tree_collections/` → `st_updates` (empty/singleton/insert/delete/from_list/from_sorted) (**§25 pass**) |
| 5 | Comparator-class semantics | T | `search_tree_collections/` → `st_duplicates`, `st_compare_item`, `st_persistence`, `st_large_runs` (sorted-list oracle) (**§25 pass**) |
| 6 | Distinct trait rationale | I | Design §6 documentation |
| 7 | Invariants + complexity | I | Design §7 inherits OrderedSet |
| 8 | Non-goals | O | "No range-search, predecessor/successor cursor, …" |

---

## `directed_graph_trait.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Directed graph abstract value | I | Design §1 |
| 2 | Constructor `{compare_node, compare_edge, edge_target}` | C | `directed_graph_constructor_record` was not landed; no `error_enforcement` trial exists for this family (`trial_compile_fail_constructor_*` use `StubWbtSet`) |
| 3 | Trait contract | T | `graph_collections/` → `gc_directed_trait`, `gc_csr_directed_trait`, `gc_dense_directed_trait`; `traits_addition/` → `trait_param_dispatch_per_impl`, `bracket_receiver_dispatch_by_representation` (**graph pass 2026-09-18**) |
| 4 | `graph_wbt_directed` module surface | T | `graph_live_core/` → `gl_directed_vertices`, `gl_directed_add_edge`, `gl_directed_payloads` (**graph pass 2026-09-18**) |
| 5 | Vertex retain; auto-add endpoints on edge | T | `graph_live_core/` → `gl_directed_add_edge`, `gl_directed_remove_edge` (**graph pass 2026-09-18**) |
| 6 | Query semantics (`reachable`, empty neighbors) | T | `graph_live_core/` → `gl_directed_folds_reachable`, `gl_directed_vertices`; `graph_collections/` → `gc_directed_trait` (**graph pass 2026-09-18**) |
| 7 | WBT / CSR / dense module families | T | `graph_live_core/` → `gl_directed_add_edge`; `graph_csr_core/` → `gcsr_directed_freeze`; `graph_dense_core/` → `gd_directed_updates`; `graph_collections/` → `gc_csr_directed_trait`, `gc_dense_directed_trait` (**graph pass 2026-09-18**) |
| 8 | Count definitions | I | Design §8 equations |
| 9 | Invariants | T | `graph_live_core/` → `gl_validate`, `gl_directed_payloads` (**graph pass 2026-09-18**) |
| 10 | Complexity | I | Design §10 table |
| 11 | Example | T | `graph_live_core/` → `gl_directed_add_edge` (**graph pass 2026-09-18**) |
| 12 | Exclusions (no `remove_vertex` in Phase 1) | O | Design §12 exclusion list |

---

## `undirected_graph_trait.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Undirected abstract graph | I | Design §1 |
| 2 | `{to, data}` wrapper model | I | Design §2 |
| 3 | Trait contract | T | `graph_collections/` → `gc_undirected_trait`, `gc_undirected_trait_weighted`, `gc_csr_undirected_trait`, `gc_dense_undirected_trait` (**graph pass 2026-09-18**) |
| 4 | Live module surface (`add_edge/3` + `/4`) | T | `graph_live_core/` → `gl_undirected_symmetry`, `gl_unit_edges` (**graph pass 2026-09-18**) |
| 5 | Symmetric update semantics | T | `graph_live_core/` → `gl_undirected_symmetry`, `gl_weighted_undirected`; `graph_dense_core/` → `gd_undirected` (**graph pass 2026-09-18**) |
| 6 | Degree and neighbors | T | `graph_live_core/` → `gl_undirected_symmetry`; `graph_collections/` → `gc_undirected_trait` (**graph pass 2026-09-18**) |
| 7 | Edge fold | T | `graph_live_core/` → `gl_undirected_symmetry`, `gl_weighted_undirected` (**graph pass 2026-09-18**) |
| 8 | `connected/3` | T | `graph_live_core/` → `gl_undirected_symmetry`; `graph_collections/` → `gc_undirected_trait` (**graph pass 2026-09-18**) |
| 9 | Counts (self-loop double count) | T | `graph_live_core/` → `gl_undirected_symmetry`; `graph_collections/` → `gc_undirected_trait` (**graph pass 2026-09-18**) |
| 10 | CSR/dense query backends | T | `graph_csr_core/` → `gcsr_undirected`; `graph_dense_core/` → `gd_undirected`; `graph_collections/` → `gc_csr_undirected_trait`, `gc_dense_undirected_trait`, `gc_csr_weighted_undirected_trait`, `gc_dense_weighted_undirected_trait` (**graph pass 2026-09-18**) |
| 11 | Invariants | T | `graph_live_core/` → `gl_validate`, `gl_undirected_symmetry` (**graph pass 2026-09-18**) |
| 12 | Complexity | I | Design §12 table |
| 13 | Example | T | `graph_live_core/` → `gl_unit_edges` (**graph pass 2026-09-18**) |
| 14 | Exclusions | O | Design §14 exclusion list |

---

## `weighted_graph_trait.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Orthogonal capability trait | I | Design §1 |
| 2 | `WeightedGraph[EdgeData, Weight, mem]` | C | `weighted_graph_type_witness` was not landed; no `error_enforcement` trial exists for this family (`trial_compile_fail_constructor_*` use `StubWbtSet`) |
| 3 | Constructor record | C | `weighted_graph_constructor_record` was not landed; no `error_enforcement` trial exists for this family (`trial_compile_fail_constructor_*` use `StubWbtSet`) |
| 4 | Trait contract (`weight_of`, weighted neighbors) | T | `graph_collections/` → `gc_weighted_trait`, `gc_weighted_trait_undirected`, `gc_csr_weighted_trait`, `gc_dense_weighted_trait` (**graph pass 2026-09-18**) |
| 5 | Edge identity separate from weight | I | Design §5 |
| 6 | Directed update semantics | T | `graph_live_core/` → `gl_weighted_directed` (**graph pass 2026-09-18**) |
| 7 | Undirected wrapper model | T | `graph_live_core/` → `gl_weighted_undirected` (**graph pass 2026-09-18**) |
| 8 | Query semantics | T | `graph_live_core/` → `gl_weighted_directed`, `gl_weighted_undirected`; `graph_collections/` → `gc_weighted_trait` (**graph pass 2026-09-18**) |
| 9 | CSR/dense forms | T | `graph_csr_core/` → `gcsr_weighted`; `graph_dense_core/` → `gd_weighted`; `graph_collections/` → `gc_csr_weighted_trait`, `gc_csr_weighted_undirected_trait`, `gc_dense_weighted_trait`, `gc_dense_weighted_undirected_trait` (**graph pass 2026-09-18**) |
| 10 | Weight validity in algorithms not graph | I | Design §10 |
| 11 | Invariants | T | `graph_live_core/` → `gl_weighted_directed`, `gl_weighted_undirected` (**graph pass 2026-09-18**) |
| 12 | Complexity | I | Design §12 table |
| 13 | Example | T | `graph_live_core/` → `gl_record_edge_data` (record edge data through the generic modules; formerly the open defect `defect_generic_payload_record_edge_data`, passes since the 2026-09-18 boxed record layout); int64 form in `gl_weighted_directed` (**graph pass 2026-09-18**) |
| 14 | Exclusions | O | Design §14 exclusion list |

---

## `heap_trait.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Immutable multiset; min/max modules | I | Design §1 |
| 2 | `{compare_item}` constructor | C | `heap_constructor_record` was not landed; no `error_enforcement` trial exists for this family (`trial_compile_fail_constructor_*` use `StubWbtSet`) |
| 3 | Trait contract | T | `heap_collections/` → `heap_trait_dispatch` (**pass 2026-09-18**) |
| 4 | `brodal_okasaki_min/max` surface | T | `heap_collections/` → `heap_push_pop_order`, `heap_from_list`, `heap_generic_payloads` (**pass 2026-09-18**) |
| 5 | Orientation behavior | T | `brodal_okasaki_core/` → `bo_max_orientation_adapter`; `heap_collections/` → `heap_push_pop_order`, `heap_duplicates` (**pass 2026-09-18**) |
| 6 | push/pop/meld/singleton | T | `heap_collections/` → `heap_push_pop_order`, `heap_meld`, `heap_empty_and_singleton` (**pass 2026-09-18**) |
| 7 | Persistence and arena | T | `heap_collections/` → `heap_persistence`, `heap_meld` (**pass 2026-09-18**) |
| 8 | Empty peek/pop status | T | `heap_collections/` → `heap_empty_and_singleton` (**pass 2026-09-18**) |
| 9 | Invariants | T | `heap_collections/` → `heap_validate`; `brodal_okasaki_core/` → `bo_validate_invariants` (**pass 2026-09-18**) |
| 10 | Complexity | I | Design §10 table |
| 11 | Example | T | `heap_collections/` → `heap_persistence` (the design example), `heap_large_runs` (**pass 2026-09-18**) |
| 12 | Exclusions | O | Design §12 exclusion list |

---

## `priority_queue_trait.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Lexicographic (priority, value) multiset | I | Design §1 |
| 2 | Separate comparators constructor | C | `priority_queue_constructor_record` was not landed; no `error_enforcement` trial exists for this family (`trial_compile_fail_constructor_*` use `StubWbtSet`) |
| 3 | Trait contract | T | `heap_collections/` → `pq_trait_dispatch`, `pq_item_type_is_value` (**pass 2026-09-18**) |
| 4 | Priority module surface | T | `heap_collections/` → `pq_push_pop_lexicographic`, `pq_generic_payloads`, `pq_priority_type_composite_result` (**pass 2026-09-18**) |
| 5 | Duplicate/tie behavior (not FIFO) | T | `heap_collections/` → `pq_duplicates`, `pq_push_pop_lexicographic` (**pass 2026-09-18**) |
| 6 | Core heap operations on entries | T | `heap_collections/` → `pq_meld`, `pq_large_runs`; `brodal_okasaki_core/` → `bo_pop_order_oracle` (**pass 2026-09-18**) |
| 7 | No decrease-key / delete-entry | O | "Neither arbitrary-entry deletion nor decrease-key" |
| 8 | `from_entries` bulk | T | `heap_collections/` → `pq_from_entries` (**pass 2026-09-18**) |
| 9 | Empty/failure | T | `heap_collections/` → `pq_empty` (**pass 2026-09-18**) |
| 10 | Persistence | T | `heap_collections/` → `pq_persistence` (**pass 2026-09-18**) |
| 11 | Invariants | T | `heap_collections/` → `pq_validate` (**pass 2026-09-18**) |
| 12 | Complexity | I | Design §12 table |
| 13 | Example | T | `heap_collections/` → `pq_push_pop_lexicographic` (the design example) (**pass 2026-09-18**) |
| 14 | Explicit exclusion | O | Design §14 exclusion list |

---

## `tree_trait.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Rose tree abstract value | I | Design §1 |
| 2 | `{compare_item}` + `with_root/2` | C | `tree_constructor_record` was not landed; no `error_enforcement` trial exists for this family (`trial_compile_fail_constructor_*` use `StubWbtSet`) |
| 3 | Path model (root + child indices) | I | Design §3 |
| 4 | Node + RAL child slots | T | `tree_collections/` → `rt_wide_node`, `rt_add_leaf_slots` (**pass 2026-09-18**) |
| 5 | Trait contract | T | `tree_collections/` → `rt_trait_dispatch` (**pass 2026-09-18**) |
| 6 | `tree_rose` module surface | T | `tree_collections/` → `rt_root_only`, `rt_add_leaf_slots`, `rt_add_subtree` (the stdlib exports `add_leaf/3`; `add_child` is a supervisor built-in name) (**pass 2026-09-18**) |
| 7 | Path lookup `get/2` | T | `tree_collections/` → `rt_path_edge_cases`, `rt_deep_chain` (**pass 2026-09-18**) |
| 8 | Add child path cost | T | `tree_collections/` → `rt_add_leaf_slots`, `rt_persistence_sharing` (**pass 2026-09-18**) |
| 9 | Remove child (tombstone/stable slot) | T | `tree_collections/` → `rt_remove_child_stable_slots` (**pass 2026-09-18**) |
| 10 | Replace + preorder fold | T | `tree_collections/` → `rt_replace_item`, `rt_fold_preorder`, `rt_find_first` (**pass 2026-09-18**) |
| 11 | No compaction / slot reuse | O | "Child slots are never compacted, reused, or renumbered" |
| 12 | Empty/failure cases | T | `tree_collections/` → `rt_path_edge_cases`, `rt_root_only` (**pass 2026-09-18**) |
| 13 | Invariants | T | `tree_collections/` → `rt_validate` (**pass 2026-09-18**) |
| 14 | Validation | T | `tree_collections/` → `rt_validate` (**pass 2026-09-18**) |
| 15 | Complexity (path-dependent) | I | Design §15; not whole-tree O(log n) |
| 16 | Example | T | `tree_collections/` → `rt_generic_payloads` (string items); no dedicated example trial (`tree_string_example` was not landed) |
| 17 | Exclusions | O | Design §17 exclusion list |

---

## `binary_tree_trait.md`

| Sec | Summary | Kind | Artifact |
|---|---|---|---|
| 1 | Possibly empty fixed-role binary-tree abstract value | I | Design §1 |
| 2 | `BinaryTree[...]` + constructor record `{ compare_item }` | C | `binary_tree_core/` → `binary_tree_bracket` (bracket type accepted); the constructor record is `{ compare_item }` by decision 2026-10-16 and `tree_binary@empty` takes it (§7.10 partial); the constructor-record trials are not yet written |
| 3 | No named node/path/frame/zipper surface types | C | `binary_tree_inline_surface_compile` was not landed; every `binary_tree_core/` program uses only inline types |
| 4 | Private owning record + recursive node | T | `binary_tree_core/` → `bt_validate`, `bt_compatibility` (**pass 2026-09-18**) |
| 5 | `List[:left \| :right, SpaceType]` paths | T | `binary_tree_core/` → `bt_node_and_queries` (paths built with `tree_binary@path_*`) (**pass 2026-09-18**) |
| 6 | Trait required/provided contract | T | `binary_tree_core/` → `bt_trait_dispatch` (**pass 2026-09-18**) |
| 7 | `tree_binary` module surface | T | `binary_tree_core/` → `bt_empty_and_root`, `bt_node_and_queries`, `bt_maps` (**pass 2026-09-18**) |
| 8 | Empty/root/direct-child behavior | T | `binary_tree_core/` → `bt_empty_and_root`, `bt_node_and_queries` (**pass 2026-09-18**) |
| 9 | Node construction and graft compatibility | T | `binary_tree_core/` → `bt_compatibility`, `bt_node_and_queries` (**pass 2026-09-18**) |
| 10 | Item replacement | T | `binary_tree_core/` → `bt_replace_item` (**pass 2026-09-18**) |
| 11 | Left/right replacement and clearing | T | `binary_tree_core/` → `bt_replace_children` (**pass 2026-09-18**) |
| 12 | Fold orders and shape-preserving maps | T | `binary_tree_core/` → `bt_folds`, `bt_maps` (**pass 2026-09-18**) |
| 13 | Inline zipper operations | T | `binary_tree_core/` → `bt_zipper` (**pass 2026-09-18**) |
| 14 | Result/failure conventions | T | `binary_tree_core/` → `bt_empty_and_root`, `bt_compatibility`; `binary_tree_failure_matrix` was not landed |
| 15 | Invariants and validation | T | `binary_tree_core/` → `bt_validate` (**pass 2026-09-18**) |
| 16 | Persistence and memory effects | T | `binary_tree_core/` → `bt_persistence_sharing` (**pass 2026-09-18**) |
| 17 | Complexity | I | Design §17; `binary_tree_complexity_observations` was not landed |
| 18 | Example | T | `binary_tree_core/` → `bt_generic_payloads` (string items); `binary_tree_string_example` was not landed |
| 19 | Exclusions | O | Design §19 exclusion list |

---

## 6.4 Closed CSR/dense representation contract

**Normative contract:** [`csr_dense_representation_contract.md`](csr_dense_representation_contract.md)  
Source: implementation plan §6.4; designs `csr_graph_snapshot.md`, `dense_matrix_graph.md`, `common_contract.md` §1

| ID | Requirement | Kind | Artifact |
|---|---|---|---|
| CSR-D1 | Compiler-version-private inline layouts (generated modules only) | I | [`csr_dense_representation_contract.md`](csr_dense_representation_contract.md) §CSR-D1; the compile-fail `graph_layout_not_in_source` was not landed |
| CSR-D2 | Public `NodeIdType` IDs ≠ internal `int64` dense-slot domain | T | [`csr_dense_representation_contract.md`](csr_dense_representation_contract.md) §CSR-D2; `graph_csr_core/` → `gcsr_directed_freeze`, `gcsr_generic_payloads`; `graph_dense_core/` → `gd_universe`, `gd_generic_payloads` (**graph pass 2026-09-18**) |
| CSR-D3 | Runtime-sized internal extents not in public graph type params | T | [`csr_dense_representation_contract.md`](csr_dense_representation_contract.md) §CSR-D3; `graph_csr_core/` → `gcsr_directed_freeze`; `graph_dense_core/` → `gd_universe` (**graph pass 2026-09-18**) |
| CSR-D4 | Parallel CSR neighbor + edge-data buffers (attributed/weighted) | T | [`csr_dense_representation_contract.md`](csr_dense_representation_contract.md) §CSR-D4; `graph_csr_core/` → `gcsr_weighted` (**graph pass 2026-09-18**) |
| CSR-D5 | Dense unweighted: one boolean cell sequence | T | [`csr_dense_representation_contract.md`](csr_dense_representation_contract.md) §CSR-D5; `graph_dense_core/` → `gd_directed_updates` (cells are `ref?` payload optionals, not booleans: graph_dense_core deviation 1) (**graph pass 2026-09-18**) |
| CSR-D6 | Dense attributed/weighted: `:none \| (:some, EdgeDataType)` cells | T | [`csr_dense_representation_contract.md`](csr_dense_representation_contract.md) §CSR-D6; `graph_dense_core/` → `gd_weighted` (`:none \| (:some, T)` does not parse, `ref?` cells used; `compile_defects_tagged_optional_type_addition/`) (**graph pass 2026-09-18**) |
| CSR-D7 | Distinct WBT, CSR, dense concrete generated types (+ specializations) | T | [`csr_dense_representation_contract.md`](csr_dense_representation_contract.md) §CSR-D7; `graph_csr_core/` → `gcsr_equivalence_large`, `gcsr_snapshot_isolation`; `graph_dense_core/` → `gd_equivalence`; `graph_collections/` → `gc_csr_*_trait`, `gc_dense_*_trait` (**graph pass 2026-09-18**) |

---

## Trial leaf index

| Leaf directory | Primary design sources |
|---|---|
| `compiler_substrate/` | `common_contract` §3, §5, §7–§9; impl plan Layer 1 |
| `wbt_core/` | `weight_balanced_tree.md` |
| `skew_ral_core/` | `skew_binary_random_access_list.md` |
| `brodal_okasaki_core/` | `brodal_okasaki_queue.md` |
| `binary_tree_core/` | `persistent_binary_tree.md`, `binary_tree_trait.md` (13 programs) |
| `binary_tree/` | `binary_tree_trait.md` (never created; covered in `binary_tree_core/`) |
| `ordered_collections/` | `ordered_set_trait`, `ordered_map_trait` (20 programs) |
| `heap_collections/` | `heap_trait`, `priority_queue_trait` (23 programs) |
| `tree_collections/` | `tree_trait` (16 programs) |
| `live_graphs/` | `live_wbt_graph`, `directed_graph_trait`, `undirected_graph_trait`, `weighted_graph_trait` (superseded by `graph_live_core/`; only `smoke_harness_ready`) |
| `search_tree_collections/` | `search_tree_trait` (14 programs) |
| `terminal_structures/` | superseded by `search_tree_collections/`, `heap_collections/`, `tree_collections/`; only `smoke_harness_ready` |
| `snapshot_graphs/` | superseded by `graph_csr_core/`, `graph_dense_core/`; only `smoke_harness_ready` |
| `error_enforcement/` | Now `trials/error_enforcement_addition/standard_data_structures/` (18 compile-fail trials): constructor/type/comparator compile failures (`C` rows) |
| `cross_representation/` | CSR/dense vs WBT conformance through public traits (only `smoke_harness_ready`; the comparison is made in `gd_equivalence`, `gcsr_equivalence_large` and `graph_collections/`) |
| `ordered_data_structures/graph_live_core/` | `live_wbt_graph`; live modules of `directed_graph_trait`, `undirected_graph_trait`, `weighted_graph_trait` (landed 2026-09-18) |
| `ordered_data_structures/graph_csr_core/` | `csr_graph_snapshot`; §6.4 CSR rows (landed 2026-09-18) |
| `ordered_data_structures/graph_dense_core/` | `dense_matrix_graph`; §6.4 dense rows (landed 2026-09-18) |
| `ordered_data_structures/graph_collections/` | `DirectedGraph`, `UndirectedGraph`, `WeightedGraph` traits over live, CSR and dense (landed 2026-09-18) |

---

## §6.3 acceptance checklist

- [x] Every numbered section in `data_structure_designs/*.md` has a ledger row  
- [x] Algorithm map locked decisions (1–16) recorded
- [x] Closed CSR/dense contract (§6.4) recorded in ledger  
- [x] Each row uses exactly one coverage kind (`T`, `C`, `I`, or `O`)  
- [x] Trial leaf assignment for all `T` and `C` rows  

**Open items (2026-10-16):** the BinaryTree `{ compare_item }` constructor-record `compiler_substrate` / compile-fail trials and `StubBinaryTree` (§7.10), constructor-record compile-fail trials for the graph, Heap, PriorityQueue and Tree families, BinaryTree randomized-oracle and complexity trials, `neighbors_fold_no_temp`, and the dated deferral record for WBT join/split (§14).
