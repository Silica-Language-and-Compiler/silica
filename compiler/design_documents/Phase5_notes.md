# Chunk 15 phase 5: running notes (Fable)

Design: `chunk15_stack_memory_design.md` §8.1, §8.2, §3.2, §9.2, §11.1 row 5. Stage 5a is the field
removal in the stdlib and the compiler's own modules; 5b rewrites the trials, 5c reshapes the results
(design §3.14), 5d removes `canonical_arena_*` from the runtimes and the front-end declarations. Nothing
here was built or run (Haiku builds, Sonnet reads). The Linux twins, the ESP32-S3 tree and src_selfhost
are untouched (Lee 2026-10-30: after phase 7).

## 1. Stage 5a: the before list (read 2026-10-31, before any edit)

Scopes: `compiler/stdlib/data_structures` (53 `.silica` files), `compiler/src` without `emitter/`
(the front end, `data_structures/compiler_maps`, the staged `lib/` copies), `compiler/src/emitter/apple_silicon_mac`.
Lines matched (`grep -c`, comments included):

| Pattern | stdlib/data_structures | src (non-emitter) | src/emitter/apple_silicon_mac |
| --- | --- | --- | --- |
| `region:` | 2216 | 1552 | 480 |
| `arena:` | 38 | 3 | 5 |
| `ph:` | 96 | 21 | 0 |
| `canonical_arena` | 19 | 25 | 32 |
| `alloc_rec(` | 9 | 4 | 4 |
| `alloc_ref(` | 2 | 4 | 7 |
| `alloc_buf(` | 6 | 5 | 4 |
| `ref_in_region(` | 0 | 0 | 0 |
| `.region` | 117 | 14 | 0 |

(`ph:` is almost entirely `graph:` / `{ ph: int64, id: int64 }` / a `ph: ValueType` placeholder; the two
`ph: region(L, normal) <- canonical_arena_lookup(1)` lets of §8.1 are in `wbt_map` 53 and `wbt_set` 47.
`ref_in_region` had no stdlib use left: the §3.2 note about `wbt_map.silica:7953` was already retired in
phase 2. `.region` with `-F` also matches `cfg.region_type` and the like.)

The forms the stage removes (`grep -o` occurrences, not lines):

| Form | stdlib/data_structures | src (non-emitter) | src/emitter/apple_silicon_mac |
| --- | --- | --- | --- |
| `region: region(L, normal),` (field in a record type) | 2233 | 2972 | 1332 |
| `region: <x>.region,` (field copy in a result record) | 87 | 10 | 0 |
| `region: arena,` / `region: ph,` (constructor literals) | 14 | 1 | 0 |
| `arena: region(L, normal) <- …;` / `ph: … <- canonical_arena_lookup(1);` lets | 16 | 2 | 0 |
| `canonical_arena_lookup(` | 15 (11 bindings, 4 comments) | 3 | 3 |
| `canonical_arena_same(` | 4 | 0 | 3 |
| `(region(L, normal), ref` (allocator pair returns) | 38 | 3 | 0 |
| `arena: region(L, normal)` parameters | 17 | 1 | 0 |

Every field spelling carried a trailing comma (none was the last field of a record, in either the one-line
or the multi-line form), so a removal never leaves a dangling separator.

Per-file line counts of `region: region(L, normal),` (the 174 files the mechanical pass touched; `src/lib/*`
are the makefile's staged copies of the stdlib sources):

```
stdlib/data_structures: BinaryTree 8, brodal_okasaki 18, brodal_okasaki_boot 9, brodal_okasaki_compare 2,
  brodal_okasaki_dispatch_bulk 12, brodal_okasaki_dispatch_core 17, brodal_okasaki_extract 9,
  brodal_okasaki_forest 16, brodal_okasaki_link 10, brodal_okasaki_max 10, brodal_okasaki_min 10,
  brodal_okasaki_node 9, brodal_okasaki_priority 21, brodal_okasaki_validate 11, DirectedGraph 33,
  graph_csr_core 67, graph_csr_directed 33, graph_csr_undirected 36, graph_csr_weighted 42,
  graph_csr_weighted_undirected 46, graph_dense_core 85, graph_dense_directed 40, graph_dense_undirected 46,
  graph_dense_weighted 47, graph_dense_weighted_undirected 55, graph_wbt_core 73, graph_wbt_directed 43,
  graph_wbt_undirected 51, graph_weighted 50, graph_weighted_undirected 60, Heap 3, OrderedMap 7, OrderedSet 4,
  PriorityQueue 2, SearchTree 2, skew_ral 30, skew_ral_build 8, skew_ral_dispatch_access 12,
  skew_ral_dispatch_bulk 23, skew_ral_forest 8, skew_ral_index 6, skew_ral_node 5, skew_ral_traverse 8,
  skew_ral_tree_read 12, skew_ral_tree_write 3, skew_ral_validate 11, tree_binary 87, tree_rose 76, Tree 8,
  UndirectedGraph 66, wbt_map 413, wbt_set 316, WeightedGraph 36
src (non-emitter): data_structures/compiler_maps 18, lib/OrderedMap 7, lib/wbt_map 413, main_compile_pipeline 4,
  main_emit 2, module_checker/module_iface_type_dag 28, module_checker/module_iface 1,
  sir_generator/declarations/overload_mangle 1, sir_generator/declarations/qualified_call_mangler 14,
  sir_generator/sir_generator_core 6, type_checker/declarations/type_checker_declarations_functions 11,
  type_checker/device/type_checker_device_descriptions 7, type_checker/expressions/: boolean_type_checker_expressions 2,
  actor_concurrency 2, actor_spawn 22, actor_supervision_children 12, actor_supervision_links 7,
  actor_supervision_messaging 13, actors 5, atoms 4, binary_ops 15, bindings 17, call_builtins 1, call_numeric 1,
  call_region_actor 1, call_strings 1, control 6, data 7, decl_queries 1, device 15, dispatch_collections 1,
  dispatch_data 1, dispatch_direct 1, dispatch_ops 1, float32_calls 2, helpers 4, identifiers 1, list_primitives 3,
  literals 3, numeric_builtins 9, print_negate 2, region_builtins 2, string_calls 20, tuples 7,
  user_call_check_args_result 2, user_call_check_args_tuple 2, user_call_check_args 2, user_call_check_defined_body 3,
  user_call_check_defined_parsed 1, user_call_check_defined_world_infer 1, user_call_check_defined_world 1,
  user_call_check_defined 3, user_call_check 2, user_call_collections 8, user_call_resolve_infer 2,
  user_call_resolve 1, user_call_world 1, type_checker_expressions 5, type_checker_tuple_decompose_helpers 29;
  type_checker/type_checker_callee_env_cache 4, type_checker_callee_env 28, type_checker_core 32,
  type_checker_memory_regions 3, type_checker_modules 13, type_checker_runner 10, type_interner 663,
  type_surface_cache 9
src/emitter/apple_silicon_mac: atoms/atom_rodata 1, atoms/atom_table 100, atoms/const_atoms 1,
  atoms/float32_literal_pool 29, atoms/float64_literal_pool 29, atoms/int_rodata 102, atoms/int64_literal_pool 35,
  emitter_core 14, terms/call 2, terms/const/const_atom 1, const_bool 1, const_default 2, const_dispatcher 1,
  const_float16 1, const_float32 1, const_float64 1, const_int64 2, const_uint64 2, const_unit 1,
  terms/prims/prims_actors_child_table_asm 1, prims_actors_runtime_asm 6, prims_actors_stack_asm 1, prims_actors 11,
  prims_collection_result 5, terms/print_atom_inline 6, print_bool_inline 3, print_char_inline 1,
  print_float16_inline 1, print_float32_inline 1, print_float64_inline 1, print_int16_inline 5, print_int32_inline 5,
  print_int64_inline 5, print_int8_inline 5, print_string_inline 9, term_case_patterns 15, term_child_spec 2,
  term_emit_const 1, term_emit_kind_call_tail 5, term_emit_kind_call 4, term_emit_kind_case 3,
  term_emit_kind_compound_compare 17, term_emit_kind_compound_part1 5, term_emit_kind_compound_part2 2,
  term_emit_kind_compound_part3 1, term_emit_kind_compound 1, term_emit_kind_let_named_tail 1,
  term_emit_kind_let_named 1, term_emit_kind_let_top 1, term_emit_kind_let 1, term_emit_kind_prim 1, term_emit_var 1,
  term_emitter 7, term_message_copy 15
```

The design's "25 compiler modules" (§1.4 of region_memory_safety_design.md: `compiler_maps`, the atoms
modules, `type_interner`, `type_surface_cache`, `type_checker_callee_env`, `type_checker_device_descriptions`)
undercounts the spellings: every module that passes an interner, a callee env or an atom table by value spells
the inline record type, so 67 front-end files and 54 Mac emitter files carry it. The Mac build's `silica.config`
lists one emitter tree, so the Linux and ESP32-S3 emitter files (159 of them) are left for phases 8 and 9.

## 2. What 5a changed (2026-10-31, source only)

Two passes, each verified per file against `git show HEAD:<file>` with the four mechanical forms applied
(script `verify_against_head.py`: a file is accepted when working == strip(HEAD); anything else is printed
and was read). 148 of the 176 files are exactly strip(HEAD); 18 carry the hand edits below; 10 differ only
by the phase-4e working-tree changes that were already in the tree (emitter_core, prims_actors*,
term_child_spec, term_message_copy, sir_generator_core, type_checker_expressions_actor_spawn,
type_checker_tuple_decompose_helpers: `heap_used` -> `state_area_bytes`, the deleted heap stubs).

**Mechanical pass** (174 files, `strip_region_field.py`): F1 delete the line `region: region(L, normal),`;
F2 remove the inline `region: region(L, normal), ` inside one-line record types; F3 delete the line
`region: <x>.region,` / `region: arena,` / `region: ph,`; F4 delete the line
`arena: region(L, normal) <- …;` / `ph: region(L, normal) <- canonical_arena_lookup(1);`.
`git diff --numstat` over the 176 files: 3072 added, 5876 deleted (an inline removal counts as one deleted
plus one added line). Largest: `type_interner` 664 lines, `wbt_map` / `lib/wbt_map` 435, `wbt_set` 354,
`tree_binary` 164, `tree_rose` 106, `atoms/atom_table` 100, `graph_dense_core` 99, `graph_csr_core` 77.

**Hand edits** (`hand_edits.py`, every replacement with an asserted occurrence count), design §8.1/§3.2:

* `wbt_map` (and the staged `src/lib/wbt_map.silica`, re-copied and `cmp`-identical): `smart_node_finish_alloc`
  loses its `arena` parameter and returns the `ref?` (`alloc_rec((node_key, node_value, cached_size, left, right))`,
  `pure cell`); `smart_node` calls it directly (the `arena <- tree.region` let, the pair and its destructuring go);
  `alloc_buf(map.region, n)` -> `alloc_buf(n)` (from_sorted), `alloc_ref(map.region, (h_key, h_value, 1))` ->
  `alloc_ref((h_key, h_value, 1))`.
* `wbt_set`: the same four sites (`smart_node_finish_alloc`, `smart_node`, `alloc_buf(set.region, n)`,
  `alloc_ref(set.region, (h, 1))`).
* `brodal_okasaki_node`: `alloc_cell` returns the `ref?` from `alloc_rec((item, rank, child_count, :none, kids))`;
  `alloc_node` is the direct call. `brodal_okasaki_link` `make_node`'s pair destructuring becomes one binding.
* `skew_ral_node`: `alloc_cell` / `alloc_node` likewise (`alloc_rec((item, left, right))`).
* `tree_binary`: the arena thread through `alloc_node`, `overflow_halt`, `smart_node`, `rebuild_with`,
  `rebuild_ancestor`, `replace_item_at`, `replace_child_at`, `replace_child_here`, `none_pair`, `map_pre_node`,
  `map_post_node` is removed (7 `arena` parameters, 6 pair result types, 19 pair bindings at the callers
  `with_root`, `node`, `replace_item`, `replace_child`, `map_preorder`, `map_postorder`, the zipper's
  `zipper_replace_item` and `zipper_up`); `alloc_rec((item, count, left, right))`.
* `tree_rose`: `alloc_node`, `alloc_cell`, `alloc_leaf_cell` lose `arena` and the pair; callers `new_cell`,
  `new_leaf_cell`, `with_root`, `rebuild_changed`'s allocation and `add_leaf` bind the `ref?` directly.
* `graph_dense_core`: `alloc_cell(v)`, `write_cell`, `slot_root_of(w, xs)`, `build_dense`.
* `graph_csr_core`: `slot_root_of(adj)`, `freeze`'s four `alloc_buf(n)`.
* `canonical_arena_same` (4 sites the §8.1 table does not list; they read the removed field):
  `brodal_okasaki_forest@compatible` (the `same_arena` binding and its conjunct go), `tree_rose@compatible_trees`
  (same), `tree_binary@compatible_trees` (now the bare `specialization_key` comparison, no sequence),
  `tree_binary@zipper_replace_subtree` (the `case` keeps the key comparison). By §8.2 a melded or grafted
  structure references the other's nodes wherever they are, so arena identity is no longer a compatibility
  condition; `compatible` / `graft` results keep their shape (5c reshapes them).
* Five header comments that described the arena (`brodal_okasaki` 35-36, `skew_ral` 25, `tree_binary` 36,
  `tree_rose` 54 and 540, `skew_ral_node` 7) and the two "Allocators return (region, ref) pairs" comments.

**Effect declarations (found while reading, not in the design).** E3010 UnusedEffectDeclaration is checked per
sequence block over the builtins it calls directly (`effect_checker_capabilities@check_sequence_unused_effects`;
a user function's declared effects are empty whatever its body's sequences declare: the `.iface` effects line of
`from_sorted` is blank). `canonical_arena_lookup` was the only `mem` builtin in nine constructor sequences, so
their `sequence proc[mem(normal)]` became `sequence`: `wbt_map@empty_map`, `wbt_set@empty_set`,
`tree_binary@empty_tree`, `brodal_okasaki@empty_heap`, `tree_rose@with_root` (its allocation is the user call
`alloc_node`), and `empty` of `graph_wbt_directed`, `graph_wbt_undirected`, `graph_weighted`,
`graph_weighted_undirected`. `skew_ral@empty_ral` (`empty[…]()`) and `graph_csr_core@freeze` (`alloc_buf`) keep
theirs. No caller changes: the public `empty` wrappers never had effects (`compiler_maps`, `type_surface_cache`,
`type_interner`, `type_checker_callee_env` call `wbt_map@empty` from sequences that are already plain or use
a list builtin). The `L: lifetime <- fresh_lifetime();` binders stay: the result annotations name `L`.

**Compiler modules.** Besides the inline spellings: `sir_generator/terms/collection_constructor_calls@bind_has_runtime_fields_i`
and `type_checker/type_checker_collections@bind_type_has_collection_runtime_fields` now test `specialization_key`
alone (both required a `region` field too; every stdlib record had both, so the set of recognised binds is
unchanged). `record_runtime_space_from_region_field` now yields "" for an inline record, which
`collection_specialization_key` maps to the same space tag (1) as `mem(normal)`, so no key changes.

## 3. Design points not followed, or followed with a note

* §8.1 counts "nine allocation sites"; the allocation helpers also threaded the arena as a parameter and
  returned `(region(L, normal), ref?)` pairs (17 parameters, 41 pair sites). With no arena to pass they return
  the reference (the type checker's E2100 collector matches `ref(` only, not `ref?(`, so a bare `ref?` return
  from a sequence is accepted, as `wbt_map@smart_node` already showed).
* §8.1 lists `canonical_arena_lookup` only; the four `canonical_arena_same` reads above had to go with the field.
* §9.2 row 1 (the synthesised `canonical_arena_lookup` let in the collection-constructor lowering): left in
  place for 5d. The lowering still binds `<name>.__arena <- canonical_arena_lookup(key)` and
  `value_for_merge_field`'s `region` arm is now unreachable (no record has the field); the runtime still has
  `canonical_arena_runtime_asm` (phase 4e left it). `region_type_for_bind`, `arena_binding_name`,
  `build_arena_lookup_sir` and the front-end builtin lists are 5d's.
* The ESP32-S3 board app `board/apps/silica_14_wbt_map` and the linux_x86_64 ladder twin spell the field;
  they are sample programs outside the compiler (memory note) and belong to phases 8/9.
* Stale `.iface` / `.sams` files beside the stdlib sources were not touched; they regenerate with the build.

## 4. For 5b: what now fails to compile because it still spells or reads the field

`trials/`: 289 files spell `region: region(L, …)` in an inline type, 51 read `.region`, call
`canonical_arena_*` or allocate with an arena argument. By suite: `ordered_data_structures` 281,
`memory_region_addition` 6, `generic_modules_addition` 4, `region_hazards_open_addition` 2,
`error_enforcement_addition` 2, `compile_defects_trait_typed_record_call_x8_addition` 1. The pair-returning
allocator helpers and `compatible` sites changed in §2 are internal; the public signatures that changed are
none (every exported constructor and updater keeps its parameters and result record minus the field).
No stdlib file outside `data_structures/` spelled the field (`Supervisor`, `DeviceDescription`, the registers).

## 5. After counts (same greps as §1)

| Pattern | stdlib/data_structures | src (non-emitter) | src/emitter/apple_silicon_mac |
| --- | --- | --- | --- |
| `region:` | 0 | 15 (diagnostic strings, `next_region:` tuple names, comments) | 4 (comments, `base_region:` in var.silica) |
| `arena:` | 3 (`in_arena:` booleans) | 1 (`arena:` comment) | 5 (comments) |
| `ph:` | 94 (`graph:`, placeholders) | 20 | 0 |
| `canonical_arena` | 0 | 24 (front-end lists, 5d) | 32 (runtime + prim dispatch, 5d) |
| `alloc_rec(` | 9 (all region-less) | 4 | 4 |
| `alloc_ref(` | 2 (region-less) | 4 | 7 |
| `alloc_buf(` | 6 (region-less) | 5 | 4 |
| `ref_in_region(` | 0 | 0 | 0 |
| `.region` | 0 | 1 (`cfg.region_type`) | 0 |

The eight removed forms count 0 in all three scopes except `canonical_arena_lookup(` 2 / 3 (front end, emitter
prim dispatch: 5d) and one `(region(L, normal), ref` in a `type_checker_recursive_tuples` comment.

## 6. Not verified (Haiku builds, Sonnet reads)

Nothing built or run. Expected: every stdlib unit and every compiler unit that spelled the field recompiles with
the 4e compiler as builder (the inline types match the stdlib records again); `ordered_data_structures` and the
five other suites of §4 fail to compile until 5b. Risks judged highest: (a) a `sequence` that lost its
`proc[mem(normal)]` still being asked for it by E3001/E3002 through a path this reading missed (the nine
constructors); (b) the type checker's handling of the bare `ref?` returns from `alloc_node`-style helpers in
`tree_rose` / `tree_binary` where `L` is only in the parameter types; (c) the constructor lowering's dead
`__arena` let now that `bind_has_runtime_fields_i` ignores the field.

## 7. Stage 5c: change-result reshaping (2026-10-31, source only)

Design §3.14 (region_memory_safety_design.md:417-471) and chunk15 §8.3 (decision 37). Scope: the
stdlib updaters whose result was a flag record (`inserted`, `replaced`, `removed`, `updated`,
`appended`, `changed`, `added`, `compatible`, plus the dense graphs' `rejected`) and the compiler's own
readers of them. Not the trials (a separate step), not `canonical_arena_*` (5d). Nothing built or run
except four scratch probes against the installed compiler (§7.5).

### 7.1 The sums, updater by updater

The payload `V` is always the family's version record, spelled inline exactly as the old record's
payload field spelled it (multi-line payloads keep their old indentation inside the sum). A no-op
returns `:unchanged` and builds nothing. Every internal helper on an updater's path carries the same
sum as its public entry, so the tag is produced once at the leaf and passed up unchanged.

| File | Sum | Updaters |
| --- | --- | --- |
| `wbt_map` | `:unchanged \| (:inserted, V) \| (:replaced, V)` | `insert`, `insert_at_node`, `insert_after_key`, `insert_at_node_less`, `insert_at_node_greater`, `insert_descend_left`, `insert_descend_right`, `insert_leaf_as_left_maybe_right`, `insert_leaf_as_left_with_right_read`, `insert_leaf_as_right_maybe_left`, `insert_leaf_as_right_with_left_read`, `insert_finish_left_child`, `insert_finish_right_child`, `insert_leaf_as_left_child`, `insert_leaf_as_right_child`, `insert_singleton`, `insert_invalid_halt`, `insert_pair_new` (`(:inserted, m)`), `insert_pair_replaced` (`(:replaced, m)`), `insert_pair_unchanged` (`:unchanged`) (20) |
| | `:unchanged \| (:removed, V)` | `delete`, `delete_at_node`, `delete_after_key`, `delete_at_node_equal`, `delete_equal_by_children`, `delete_equal_left_present`, `delete_equal_left_empty`, `delete_equal_two_children`, `delete_splice_from_right`, `delete_splice_from_left`, `delete_at_node_greater`, `delete_at_node_less`, `delete_descend_right_present`, `delete_descend_left_present`, `delete_after_right_child`, `delete_after_left_child`, `delete_finish_after_right_reread`, `delete_finish_after_left_reread`, `delete_finish_after_right`, `delete_finish_after_left`, `delete_invalid_halt`, `delete_pair_removed`, `delete_pair_unchanged` (23) |
| `wbt_set` | `:unchanged \| (:inserted, V)` | `insert`, `insert_at_node`, `insert_after_key`, `insert_at_node_less`, `insert_at_node_greater`, `insert_descend_left`, `insert_descend_right`, `insert_leaf_as_left_maybe_right`, `insert_leaf_as_left_with_right_read`, `insert_leaf_as_right_maybe_left`, `insert_leaf_as_right_with_left_read`, `insert_finish_left_child`, `insert_finish_left_after_right_read`, `insert_finish_left_with_right_present`, `insert_finish_right_child`, `insert_finish_right_after_left_read`, `insert_finish_right_with_left_present`, `insert_leaf_as_left_with_right`, `insert_leaf_as_right_with_left`, `insert_leaf_as_left_child`, `insert_leaf_as_right_child`, `insert_singleton`, `insert_invalid_halt`, `insert_pair_true`, `insert_pair_false` (25) |
| | `:unchanged \| (:removed, V)` | the 23 `delete*` functions named for `wbt_map` |
| `graph_wbt_core` | `:unchanged \| (:inserted, ROOT)` (`ROOT` = the outer root `ref?`) | `add_vertex` |
| | `:unchanged \| (:inserted, ROOT, int64) \| (:replaced, ROOT, int64)` (the int64 is `nodes_added`) | `set_entry`, new helper `set_entry_publish` |
| | `:unchanged \| (:removed, ROOT)` | `remove_entry` |
| `graph_wbt_directed`, `graph_weighted` | `:unchanged \| (:inserted, V)` | `add_vertex` |
| | `:unchanged \| (:inserted, V) \| (:replaced, V)` | `add_edge`, `add_edge_set` (directed) |
| | `:unchanged \| (:removed, V)` | `remove_edge` |
| `graph_wbt_undirected`, `graph_weighted_undirected` | `:unchanged \| (:inserted, V)` | `add_vertex` |
| | `:unchanged \| (:inserted, V) \| (:replaced, V)` | `add_edge`, `add_edge_pair`, `add_unit_edge` (wbt only) |
| | `:unchanged \| (:removed, V)` | `remove_edge`, `remove_edge_pair` (now takes the removed root, not the result), `remove_edge_absent` |
| `graph_dense_core` | `:unchanged \| (:removed, DS)` | `clear_entry` (`set_entry` keeps its `{ ds, status }` record: `status` is not a flag of this stage) |
| `graph_dense_directed`, `graph_dense_weighted` | `:unchanged \| :rejected \| (:inserted, V) \| (:replaced, V)` | `add_edge`, `add_edge_set` (directed) |
| | `:unchanged \| (:removed, V)` | `remove_edge` |
| `graph_dense_undirected`, `graph_dense_weighted_undirected` | `:unchanged \| :rejected \| (:inserted, V) \| (:replaced, V)` | `add_edge`, `add_pair`, `add_unit_edge` (undirected only) |
| | `:unchanged \| (:removed, V)` | `remove_edge`, `remove_pair` (now takes the cleared `ds`, not the result) |
| `tree_binary` | `:incompatible \| (:built, V)` | `node` (a constructor: no input version, so no `:unchanged`) |
| | `:unchanged \| (:changed, NODE)` | `rebuild_with`, `rebuild_ancestor`, `replace_item_at`, `replace_child_at`, `replace_child_here` (`rebuild_missing`, `rebuild_unchanged` deleted: both are `:unchanged`) |
| | `:unchanged \| (:changed, V)` | `replace_item`, `graft`, `clear_left`, `clear_right` |
| | `:unchanged \| :incompatible \| (:changed, V)` | `replace_left`, `replace_right` |
| | `:unchanged \| :incompatible \| (:changed, Z)` (`Z` = the zipper record) | `zipper_replace_subtree` |
| `tree_rose` | `:unchanged \| (:updated, SPINE)` | `spine_set` |
| | `:unchanged \| (:changed, NODE, int64, int64)` (delta, info) | `res_alloc`, `rebuild_changed` (now takes `sub_node`, `sub_delta`, `sub_info`), `rebuild_ancestor`, `replace_item_at`, `attach_child`, `add_leaf_here`, `add_leaf_at`, `add_subtree_at`, `remove_occupied`, `remove_here`, `remove_child_at` (`res_missing`, `res_declined` deleted: both are `:unchanged`) |
| | `:unchanged \| (:changed, V)` | `replace_item` |
| | `:unchanged \| (:added, V, int64)` (child slot) | `add_leaf` |
| | `:unchanged \| :incompatible \| (:added, V, int64)` | `add_subtree`, `add_subtree_checked` |
| | `:unchanged \| (:removed, V, int64)` (removed node count) | `remove_child` |
| `skew_ral` | `:unchanged \| (:updated, V)` | `update`, `set` |
| | `:unchanged \| (:appended, V)` | `append` (`:unchanged` for the :front orientation) |
| `skew_ral_dispatch_access` | `:unchanged \| (:updated, V)` | `update_physical` |
| `skew_ral_index` | `:unchanged \| (:updated, FOREST)` | `forest_update`, `update_digit`, `update_deeper`, `update_here`, `update_here_result` |
| `brodal_okasaki`, `brodal_okasaki_max`, `brodal_okasaki_min`, `brodal_okasaki_dispatch_core` | `:unchanged \| :incompatible \| (:melded, H)` | `meld` (all four), `meld_counted` (`:unchanged` when `right.count == 0`) |
| `brodal_okasaki_priority` | `:unchanged \| :incompatible \| (:melded, Q)` | `meld_priority` |
| `brodal_okasaki_forest` | `:unchanged \| :incompatible \| (:melded, F)` | `merge_checked` (`:unchanged` when `f2` is nil) |

Count: 179 functions returned a flag record (the scan `fnscan.py`, return records only, comments
excluded); 175 now return a sum, 4 trivial helpers were deleted, 1 helper was added. Stdlib callers
rewritten in the same pass: `wbt_map@singleton` / `from_list_cons`, `wbt_set@singleton` /
`from_list_cons`, `graph_wbt_core@search_go`, `graph_dense_core@search_go`, `write_cell`, `clear_at`,
`graph_csr_core@search_go`, every graph facade's reads of `graph_wbt_core` / `graph_dense_core` results,
`brodal_okasaki_priority@meld_priority`'s read of `brodal_okasaki@meld`. The staged copy
`src/lib/wbt_map.silica` was re-copied (`cmp`-identical); `src/lib/OrderedMap.silica` is unchanged.
No trait file (`OrderedMap`, `OrderedSet`, ... `WeightedGraph`) declares an updater result, so none changed.

### 7.2 How a caller reads a result

```silica
        r: :unchanged | (:inserted, { ... }) | (:replaced, { ... }) <- wbt_map@insert(m, k, v);
        m2: { ... } <- case r of {
            :unchanged -> m;
            (:inserted, m_ins: { ... }) -> m_ins;
            (:replaced, m_rep: { ... }) -> m_rep
        }
```

Inside the stdlib a tagged result is built from a let-bound name (`out: V <- publish(...); (:inserted, out)`),
never from a call expression inside the tuple literal, and a result that is only forwarded is forwarded
untouched. Where a function needs the payload of a result it was handed (the undirected `*_pair`
helpers), it now receives the payload itself.

**Compiler callers (6 call sites in 4 files, all `wbt_map@insert`; the compiler calls no other reshaped
updater):** `data_structures/compiler_maps.silica` `insert_new_index`, `insert_new_int64_index`;
`type_checker/type_surface_cache.silica` `store_in`; `type_checker/type_checker_callee_env.silica`
(the ref-name set, `pure r.map`); `type_checker/type_interner.silica` the insert-or-get helper (:457) and
the parse memo (:4561). Each binds the sum, cases it into a `new_map` / `new_index` / `out` / `names2`
binding and uses that where `r.map` was read. The compiler's own `{ map, index, inserted }` insert-or-get
records (`compiler_maps@map_insert_or_get_index`, `int64_map_insert_or_get_index`, `type_interner`'s
twin) and their readers (the atom and literal tables, `type_checker_device_descriptions`) are unchanged:
they are compiler helpers, not stdlib updaters, and `inserted` there means "was absent", so the 55 of
design §3.14 were mostly these spellings, not stdlib reads.

### 7.3 Design points not followed, or followed with a note

* §3.14:443-444 (heap `insert` `(:inserted, V)`, `pop` `:unchanged | (:popped, T, V)`) and :446's
  `status` / `valid` bulk results: not reshaped. Those results carry no flag field of this stage's list
  (`status: :not_found | :found`, `valid`, `error`); they stay as they are until decided.
* §3.14:446 `:overflow`: not added. `update` / `set` / `append` have no overflow outcome today (an
  out-of-range index and the :front orientation are no-ops, now `:unchanged`); a never-produced
  alternative would only force dead arms on every caller.
* §3.14:447: `tree_binary@node` is a constructor, so `:incompatible | (:built, V)` without `:unchanged`;
  `graft`, `clear_left`, `clear_right` never fail, so no `:incompatible` (`replace_left` / `replace_right`
  re-tag `graft`'s result under their own sum); `zipper_replace_subtree` keeps `:unchanged` first
  (§3.14:434) although nothing produces it today.
* §3.14:448 `:rejected`: only the dense families, which are the only ones that reject an endpoint today.
* §3.14:445, meld `:unchanged` when the other heap is empty: implemented as a new shortcut in
  `meld_counted` (`right.count == 0`) and `merge_checked` (`f2.is_nil`). Today those cases built a melded
  copy of the left heap; this is the one place 5c changes an observable result beyond its shape.
* Internal rebuild results dropped the `found` flag (no reader distinguished missing from unchanged).
* `graph_wbt_core@set_entry`: an unchanged inner insert now answers `:unchanged` without the outer
  re-insert it used to do (nodes_added is 0 in that case: a new endpoint cannot already hold the entry).
  When the outer insert answers `:unchanged` in `set_entry_publish` / `remove_entry`, the old root is
  carried in the tagged result, exactly as today's code answered `oins.map.root`.
* The undirected `add_edge_pair` still performs the mirror `set_entry` and publishes `out` when its first
  result is `:unchanged`, to keep the symmetry halt check; that no-op therefore still builds the discarded
  graph record (§3.14:424-426 says a no-op allocates nothing). The halt paths of `remove_edge_absent`
  keep `update_halt(0)` in a discarded binding before `:unchanged`.
* Multi-line payloads keep their old indentation inside the sum (fields one level deeper than the sum's
  line); the parser does not care, a later tidy may.

### 7.4 Verified by reading and by probe

Every file's 5c-only diff (against a copy taken after 5a) was reviewed with the type-text lines filtered
out, so each remaining changed line is a hand edit (scripts `reshape_wbt.py`, `reshape_rest.py`,
`reshape_compiler.py`, every replacement asserted to match exactly once; the generic record-to-sum pass
is brace-aware and matches a record type only when its top-level field names are exactly a payload plus
the stage's flags with their declared types, so record literals and the compiler's own `{ map, index,
inserted }` records never match). After the pass no `inserted: boolean` / `.inserted` / `removed:
true` style spelling remains under `stdlib/data_structures`, and the only `r.ds` / `r.status` reads left
are of `graph_dense_core@set_entry`'s unchanged status record.

Four scratch programs compiled with `binaries/silica-compiler` (999937) and ran correctly (not trials,
not builds): (1) a sum return with record payloads, a sequence binding of the sum, a case whose tuple
pattern binds a record-typed element; (2) the same inside a generic module on the witness conventions,
the sum as a parameter, a cross-unit caller; (3) three-element variants with a `ref?` element, an atom
arm beside a call arm of the same sum, `pure :unchanged` after a discarded binding; (4) int-literal arms
yielding tagged tuples from a let-bound record, a block ending in a bare atom, `pure (:removed, out)`,
a block arm inside `pure case`. Each form the rewrite relies on appears in one of them.

Not verified: no stdlib unit or compiler unit was compiled. Judged highest risk: the doubled inline
payload text in every signature (type-check time, memory note on `parse_type` memoisation); the
`case` on a sum-typed *parameter* in the wbt internals (`child`) is probe 2's form, but at generic
depth; `graph_wbt_core@set_entry_publish` is the one new exported-adjacent function (not exported).

Observed, not touched: `type_interner.silica` prints `WeightedGraph[...]` (search `concat("WeightedGraph["`)
with one `)` fewer than it opens, and the compiler accepts it; the brace scanner had to skip that region.

### 7.5 For the trial step: files that must change

138 files (`grep -rlE` of `<module>@<updater>(` over the reshaped modules' updaters: 130; plus 8 that
spell or read a flag record of their own without calling a reshaped updater, marked below, to inspect).
By suite: `ordered_data_structures` 133, `region_hazards_open_addition` 2, `generic_modules_addition`
1, `supervisor_exit_reports_addition` 1, `compile_defects_trait_typed_record_call_x8_addition` 1. The
trials that print flags change their goldens (design §11.1 row 5); every `ins.map` / `.set` / `.tree`
read needs the case of §7.2. Updaters called from trials, by count: `wbt_set@insert` 187,
`wbt_map@insert` 126, `wbt_set@delete` 32, `wbt_map@delete` 25, the six `*@add_edge` 25/24/20/14/12/12/8,
`tree_binary@replace_item` 19, `graph_wbt_directed@remove_edge` 9, `brodal_okasaki_min@meld` 9,
`tree_binary@replace_left` 9, `clear_left` 8, `tree_rose@add_leaf` 7, `brodal_okasaki@meld` 7,
`meld_priority` 7, `skew_ral@append` 6, and the rest below 6.

* `compile_defects_trait_typed_record_call_x8_addition/` (1): defect_trait_typed_record_call_x8
* `generic_modules_addition/` (1): wbt_set [no updater call; own flag record]
* `ordered_data_structures/binary_tree_core/` (6): bt_empty_and_root, bt_generic_payloads, bt_persistence_sharing, bt_replace_children, bt_replace_item, bt_zipper
* `ordered_data_structures/binary_tree_core/lib/` (1): bt_trial_i64
* `ordered_data_structures/brodal_okasaki_core/` (4): bo_generic_payloads, bo_meld_incompatible, bo_meld_tree, bo_old_heap_valid_after_pop
* `ordered_data_structures/compiler_substrate/` (1): ordering_identity_meld_reject [no updater call; own flag record]
* `ordered_data_structures/graph_collections/` (8): defect_generic_payload_trait_record_data, gc_dense_directed_trait, gc_dense_undirected_trait, gc_dense_weighted_trait, gc_dense_weighted_undirected_trait, gc_trait_generic_payloads, gc_trait_record_edge_data, graph_field_annotation
* `ordered_data_structures/graph_collections/lib/` (1): live_trial_i64
* `ordered_data_structures/graph_csr_core/` (6): defect_generic_payload_csr_record_data, gcsr_equivalence_large, gcsr_generic_payloads, gcsr_record_edge_data, gcsr_snapshot_isolation, gcsr_undirected
* `ordered_data_structures/graph_csr_core/lib/` (1): live_trial_i64
* `ordered_data_structures/graph_dense_core/` (9): defect_generic_payload_dense_record_data, gd_directed_updates, gd_equivalence, gd_generic_payloads, gd_record_edge_data, gd_undirected, gd_universe, gd_validate, gd_weighted
* `ordered_data_structures/graph_dense_core/lib/` (1): live_trial_i64
* `ordered_data_structures/graph_live_core/` (16): defect_generic_payload_record_edge_data, defect_generic_payload_tuple_node_ids, gl_directed_add_edge, gl_directed_payloads, gl_directed_remove_edge, gl_directed_vertices, gl_generic_payloads, gl_large_oracle, gl_persistence_sharing, gl_record_edge_data, gl_tuple_node_ids, gl_undirected_symmetry, gl_unit_edges, gl_validate, gl_weighted_directed, gl_weighted_undirected
* `ordered_data_structures/graph_live_core/lib/` (1): live_trial_i64
* `ordered_data_structures/heap_collections/` (5): heap_generic_payloads, heap_meld, heap_validate, pq_meld, pq_validate
* `ordered_data_structures/ordered_collections/` (15): ordered_map_compare_value_not_called, ordered_map_delete_absent, ordered_map_field_annotation, ordered_map_find_value_linear, ordered_map_insert_replace, ordered_map_persistence, ordered_map_string_example, ordered_map_trait_dispatch, ordered_set_duplicate_insert, ordered_set_invalid_comparator, ordered_set_persistence, ordered_set_string_example, ordered_set_trait_dispatch, wbt_map_get_insert, wbt_set_empty_insert
* `ordered_data_structures/search_tree_collections/lib/` (2): StubWbtSet [no updater call; own flag record], st_trial_i64
* `ordered_data_structures/search_tree_collections/` (9): ordered_set_field_annotation, ordered_set_field_projection, st_composite_payloads, st_duplicates, st_generic_payloads, st_parameter_accepts_updated_tree [no updater call; own flag record], st_persistence, st_trait_dispatch, st_updates
* `ordered_data_structures/self_host_maps/` (1): compiler_string_index_map [no updater call; own flag record]
* `ordered_data_structures/skew_ral_core/lib/` (1): ral_trial_i64
* `ordered_data_structures/skew_ral_core/` (4): ral_append_convention, ral_generic_payloads, ral_persistence_fanout, ral_update_persistence
* `ordered_data_structures/tree_collections/lib/` (1): rt_trial_i64
* `ordered_data_structures/tree_collections/` (2): rt_generic_payloads, tree_field_annotation
* `ordered_data_structures/wbt_core/lib/` (2): wbt_trial_oracle_i64 [no updater call; own flag record], wbt_trial_trace_i64 [no updater call; own flag record]
* `ordered_data_structures/wbt_core/` (36): wbt_complexity_observations, wbt_delete_absent, wbt_delete_extreme, wbt_delete_heavier_side, wbt_delete_leaf, wbt_delete_one_child, wbt_delete_payload_shapes, wbt_delete_persistence, wbt_delete_rebalance, wbt_delete_root, wbt_delete_two_child, wbt_from_sorted_linear, wbt_map_canonical_key, wbt_map_compare_value_not_called, wbt_map_exhaustive_trace, wbt_map_insert_orders, wbt_map_insert_payload_shapes, wbt_map_insert_replace, wbt_map_insert_tuple_value, wbt_map_randomized_oracle, wbt_map_replace_persistence, wbt_map_tuple_value_escapes_frame, wbt_map_value_pairing, wbt_oracle_harness_smoke, wbt_persistence_fanout, wbt_set_exhaustive_trace, wbt_set_insert_adversarial, wbt_set_insert_duplicate, wbt_set_insert_orders, wbt_set_insert_payload_shapes, wbt_set_insert_persistence, wbt_set_insert_sharing, wbt_set_insert_three_validate, wbt_set_randomized_oracle, wbt_validate_invariants, wbt_validate_map_pairing
* `region_hazards_open_addition/` (2): four_actors_same_family_inserts, wbt_map_tuple_value_escapes_via_let
* `supervisor_exit_reports_addition/` (1): report_exits_before_sink_unreported [no updater call; own flag record]

## 8. Stage 5d: canonical_arena_* removal from the Mac compiler (2026-10-31, source only)

Scope: the front end (`compiler/src` without `emitter/`) and `compiler/src/emitter/apple_silicon_mac`. The
Linux twins, the ESP32-S3 tree and src_selfhost are phases 8 and 9 and are untouched.

### 8.1 The before list

`grep -rn canonical_arena compiler/src --include='*.silica' | grep -v 'linux_\|ESP32\|src_selfhost'`: **56 lines**
in 11 files (comments included).

| File | Lines |
| --- | --- |
| `effect_checker/effect_checker_memory_regions.silica` | 160 (builtin list), 253 (`alloc_*`/`build`/`canonical_arena_lookup` arm), 284 (`canonical_arena_same`/`ref_eq` arm) |
| `sir_generator/terms/memory_region_calls.silica` | 36 (`is_region_builtin`), 147, 149 (`effect_for_prim`), 186, 187 (`result_type_for_prim`) |
| `sir_generator/terms/collection_constructor_calls.silica` | 56, 58 (comment), 232 (`build_arena_lookup_sir`) |
| `sir_generator/terms/terms_region_lowering.silica` | 36, 38 (in-body dispatch), 125, 127 (dispatch), 201, 202 (`arg_type_for_region_prim`), 211 (`arg_type_for_region_prim_inferred`) |
| `type_checker/type_checker_memory_regions.silica` | 571 (`is_region_builtin_call`) |
| `type_checker/expressions/type_checker_expressions_region_builtins.silica` | 293 (`canonical_arena_lookup` arm), 304, 311, 313, 315 (`canonical_arena_same` arm and its three E2010/E2003 texts) |
| `emitter/apple_silicon_mac/terms/canonical_arena_runtime_asm.silica` | 31, 33, 37, 38, 40, 41, 47, 49, 73, 74, 123, 124, 142, 144 (whole module: table, count, lookup, same) |
| `emitter/apple_silicon_mac/terms/term_emit_kind_compound_part2.silica` | 244, 246, 254 (the 1-arg prim arm), 268 (the 2-arg prim list) |
| `emitter/apple_silicon_mac/terms/prims/prims_actors_runtime_asm.silica` | 126 (`use`), 7411 (`canonical_arena_asm` binding), 7415 (its concat) |
| `emitter/apple_silicon_mac/terms/prims/prims_memory.silica` | 20 (comment), 100 (`is_memory_prim`), 111-123 (`emit_canonical_arena_lookup`, `emit_canonical_arena_same`), 598 (comment), 764, 765 (dispatch arms) |

Non-`.silica` Mac files that name the symbols: `compiler/src/__silica_runtime.sams` (a build output; it regenerates).
Other trees, left for phases 8/9 (`grep -rn canonical_arena compiler/src | grep 'linux_\|ESP32\|src_selfhost'`,
150 lines): `emitter/ESP32-S3_raw` 13 files, `emitter/linux_aarch64` 5 files, `emitter/linux_x86_64` 6 files.

### 8.2 What was removed (in the order: SIR lowering, type and effect checkers, Mac runtime)

* `sir_generator/terms/collection_constructor_calls.silica`: the synthesised `<name>.__arena <- canonical_arena_lookup(key)`
  let (`arena_binding_name`, `region_type_for_bind`, `build_arena_lookup_sir`, the `arena_let` wrap and the
  `arena_var` / `region_type` threads through `build_merged_record`, `build_merge_layers`, `build_merge_layers_step`)
  and the dead `region` arm of `value_for_merge_field`; `use memory_region_calls` had no other use. The lowering now
  binds `<name>.__spec_key`, `<name>.__raw` (and the bundle lets) only. The `arena_key/0` mark that keeps
  tree_rose / tree_binary constructor calls as plain lets is unchanged (it gates behaviour, not the arena); the
  header comments were rewritten.
* `sir_generator/terms/memory_region_calls.silica`: `is_region_builtin`, `effect_for_prim`, `result_type_for_prim`.
* `sir_generator/terms/terms_region_lowering.silica`: both dispatch chains (`build_region_prim`, `_in_body`),
  `arg_type_for_region_prim` (two arms), `arg_type_for_region_prim_inferred` (the `canonical_arena_same` case; the
  `ref_eq` case is now the outer one).
* `type_checker/type_checker_memory_regions.silica`: `is_region_builtin_call`.
* `type_checker/expressions/type_checker_expressions_region_builtins.silica`: the `canonical_arena_lookup` and
  `canonical_arena_same` arms with their three diagnostics (E2010 x2, E2003); the chain falls from `fresh_lifetime`
  to `ref_eq` and then to the existing E2005 "unknown region built-in". No error code existed only for them.
* `effect_checker/effect_checker_memory_regions.silica`: `is_region_builtin_fn`, the `alloc_*`/`build` effect arm,
  the empty-effect arm (now `ref_eq` alone).
* `emitter/apple_silicon_mac/terms/canonical_arena_runtime_asm.silica`: deleted (table, count, lookup, same).
* `emitter/apple_silicon_mac/terms/prims/prims_actors_runtime_asm.silica`: the `use`, the `canonical_arena_asm`
  binding and its `concat` in `emit_actor_runtime_helpers`.
* `emitter/apple_silicon_mac/terms/prims/prims_memory.silica`: `is_memory_prim`, `emit_canonical_arena_lookup`,
  `emit_canonical_arena_same`, the two `emit_prim_op` arms, two comments.
* `emitter/apple_silicon_mac/terms/term_emit_kind_compound_part2.silica`: the `alloc_region | canonical_arena_lookup`
  arm is `alloc_region` alone (`prims@emit_prim_op` with no X1 argument emission); `canonical_arena_same` out of the
  two-argument list.
* `emitter/apple_silicon_mac/terms/ffi_fault_runtime_asm.silica`: the three per-site abort entries
  `_silica_rt_abort_arena_key` / `_full` / `_nomem` and their reason strings (`Lrta_r_arena_*`): their only caller was
  the deleted lookup.

### 8.3 Design points not followed, or followed with a note

* Design §9.1 says `_silica_rt_region_lock` "has no remaining user once `L_region_grow` is gone". `L_region_grow`
  (`prims_memory@emit_region_grow_helper`, emitted per module that still allocates regions) is not gone in 5d and
  takes that lock three times, so the word could not be deleted with the module. It moved, as one `.bss` word, into
  `prims_actors_runtime_asm@actor_rt_asm_chunk_10` (beside the other process-wide lock words; the runtime object is
  linked once per executable, as the canonical module was). It goes when `L_region_grow` goes.
* The ESP32-S3 twins of the abort entries and the lock are the board's (`rt_ordering.S`, phase 9); untouched.
* `compiler/src/__silica_runtime.sams` and `compiler/build/apple_silicon_mac/{silica.config,.silica.config.units}`
  name the module; both are gitignored build outputs the topo script and the build regenerate.
* `compiler/src/silica.config.p23` (tracked, last changed 2026-09-25, no makefile or script reads it; it predates
  `prims_actors_state_asm`) still lists the Mac module at line 33; `compiler/src/silica.config{,.compiler}` list only the
  ESP32-S3 twin (phase 9). Neither was edited.
* The trial `.silica` sources under `trials/` were being modified by another process during this stage (5b); none
  was touched here, and no golden, `.scout`, `.sout`, `.ascomp` or `.sams` was.

### 8.4 After counts

`grep -rn canonical_arena compiler/src --include='*.silica' | grep -v 'linux_\|ESP32\|src_selfhost'`: **2 lines**, both
comments that record the removal (`collection_constructor_calls.silica:58`, `prims_actors_runtime_asm.silica:3754`).
No `.silica` line in the Mac tree or the front end spells `canonical_arena_lookup(` / `canonical_arena_same(` as code;
`emit_canonical_arena_*`, `build_arena_lookup_sir`, `arena_binding_name`, `region_type_for_bind`,
`_silica_rt_canonical_*`, `_silica_rt_abort_arena_*`, `Lrta_r_arena_*` have 0 occurrences. `_silica_rt_region_lock`:
one definition (chunk 10), three uses (`L_region_grow`). Left for phases 8/9 (`.silica` lines / files):
`emitter/linux_aarch64` 36 / 5, `emitter/linux_x86_64` 33 / 6, `emitter/ESP32-S3_raw` 30 / 5 (plus the board's
`rt_ordering.S` and `rt_heap.S` twins, which are not `.silica`). There is no `compiler/src_selfhost` directory in this
tree (the tree-layout move made `src` the selfhost source). Nothing was built or run.

## 9. Phase 5 close (2026-10-31)

Full 12-suite gate on the final sources (compiler sha1 d6438413...): zero `.scout` differences, zero faults,
zero assembly or link failures, zero compile failures after two deletions decided by Lee: the canonical-arena trials
(5d) and region_param_threaded_through_ref_query and ordered_set_field_projection (the explicit region handle and the
removed field projection). Assembly goldens refreshed by copying `.sams` (rule); the 13 `traits/` units left alone.
Phase 5 is closed on the Mac tree. Phase 6 (region checker) is next.
2026-11-01: superseded: alloc_region is a frame area (Lee's decision); see chunk15 section 3.8.
