# Region memory safety — design (ROADMAP chunk 4)

**Date:** 2026-10-09
**Status:** design, pre-implementation. Implementation by Fable (compiler code) and lesser models (trials, scripts,
builds, verification), per §16.
**Authority:** [silica-specification.md](silica-specification.md) §4.4, §7.4, §12, §15.1.1, §16, §17. Where this
document proposes a change to the specification it says so (§1.5, §15); until Lee accepts it the specification wins.
**Supersedes:** the plan parts of [Phase1_TODOs/region_memory_safety_todo.md](Phase1_TODOs/region_memory_safety_todo.md)
(its §1 and §2.2 are out of date: bounds checks exist, §1.2 below).
**Related:** [actor_memory_budget_plan.md](actor_memory_budget_plan.md) (items B, F, K),
[list_implementation_design.md](list_implementation_design.md) §6, §9,
[data_structure_designs/common_contract.md](Phase1_TODOs/data_structure_designs/common_contract.md) §7,
[silica_device_actor_specification.md](silica_device_actor_specification.md) §4.7, §5,
[silica_ffi_wrapper_specification.md](silica_ffi_wrapper_specification.md) §6.2, §7.5–§7.7,
[runtime_failure_reporting.md](runtime_failure_reporting.md).

**Superseded in part by the next paragraph (2026-10-24):** **Standard (Lee, 2026-10-23).** [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) is THE STANDARD for the structure model. Where this document disagrees with it, the requirements document wins. Text here that describes an `arena` handle passed by value, or structure memory that is never freed, describes the current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md); the standard is: structures are copied on send by default and moved only on request (Q18), sharing inside one message is preserved, a Q13 read returns a copy, a Q14 child start receives a copy released at the child's death, and chunk 15 decides where a structure's memory lives and who releases it.

**Chunk 15 direction (Lee, 2026-10-24), supersedes parts of the paragraph above.** Per [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) section 2A (decisions 1 to 37): structures and every escaping value live on the actors' stacks; the family arenas (`canonical_arena_lookup`) and the per-actor implicit heap are removed; actor state lives at the base of the stack and grows downward at dispatch end; reclamation is deterministic and compiler-proven, never GC-like (decisions 18 to 21 specify the release log, the reported fallback, evacuation via scratch and exact-size free lists); `arena(L, S)` is not introduced (Q1 superseded) and `region(L, S)` means a lifetime-scoped area of the actor's stack; standard structures carry no region field (a structure is its root reference); Q2 (a) is superseded; Q13 is withdrawn (reads return the stored inner structure); Q14 is confirmed in stack form (a copy into the child's stack base); Q16 is amended (a kept part of a message is evacuated to the stack base); Q18 is amended (a send copies into a per-message mailbox buffer, and `move(x)` copies too, the sender only losing x, E2301); a plain `spawn` initial state is copied into the new actor's stack base before its first dispatch (decision 15); stack regions are not linear and safety is by lifetimes only, so the region checker enforces lifetimes and isolation, the linear-ownership checks, `drop_owned` and per-actor owner lists are dropped, Q5 is superseded and Q11 and E2307 are retired (decision 16); Q3 and Q4 are superseded (decision 17). Open matters are requirements section 7.4. Where this document still describes the family arena, `arena(L, S)`, O(1) cross-actor moves, moving a region into state or the implicit heap, that text is either labelled "today:" (the runtime as it is) or marked superseded in place; section 18 and 19 are rewritten.

**Implementation status (2026-10-23).** Stage 0 is implemented and verified on the Mac and BUILT on pix (linux_aarch64, compiler 999964) and nix (linux_x86_64, build dir) with no compile errors; no trials have been run on the Linux compilers yet, and the ESP32-S3 mirror is not built: H1 (CAS bump loop and locked canonical-arena insert), H3 (a let-bound aggregate passed by name is promoted), H4 (a reply is copied into the caller's arena), H5 and Q9 (a region allocation or growth failure, an out-of-bounds buffer index, an invalid buffer size and a list-index failure end the actor, abort 71 only in `main`), the E2313/E2314 literal checks, and the removal of the `|bounds:N` metadata; the first form of the dispatch-end release of a message's owned regions (SD-7, §18.7 item 2) is in the emitters too. Staged hazard trials: `trials/region_hazards_open_addition`. Not built, as found by the 2026-10-16 survey and not re-read since: the region checker, `drop` nodes, the codes E2300 to E2312 and E2315 to E2318, the `atomic_*` builtins (§9; `alloc_atomic` will not be added, Q8), Phases B and C of the lifetime analysis, and ownership-based release; scope release (`mark`/`release_to`) is still disabled in all four emitters (§1.2); `alloc_region` is still called nowhere in the stdlib or the compiler (§1.4). Lee decided Q3, Q4, Q7, Q8, Q10, Q11, Q13, Q14 and Q18 on 2026-10-23 and Q1, Q2, Q5, Q15, Q16 and Q17 on 2026-10-22 (and Q6 on 2026-10-09, narrowed by Q2 (a) and its default superseded by Q18, with Q12 withdrawn as moot): never-freed family arenas spelled `arena(L, S)`, no counted storage, so there is no counted-storage stage. No decision of §15 remains open. Open details remain for Q13 (the copy's destination and spelling) and Q14 (see §15); ROADMAP chunk 15 owns them and the fate of the family arena (note at the top of §0). §1 below was measured 2026-10-09; the function names are still right, but line numbers have
drifted (for example `let_owns_local_region` is now at line 816 of `term_reg_spill.silica`, `fn_destroys_region_param`
at 2389 of `emitter_core.silica`). The 2026-10-16 re-read found H1, H3, H4 and H5 true by reading (they are now fixed on the Mac as above), and H2 (`fn_destroys_region_param`) and H10 (no `atomic_*` in `compiler/src`) true; H6 to H9 were not re-read. Two things changed after the survey: the 2026-10-12 emitter work of §19
(caller-provided result slot in X8, reused state tuples, case-arm tuples built in the reply buffer) and the
board runtime's item B, J and F work in [actor_memory_budget_plan.md](actor_memory_budget_plan.md); neither alters a
hazard above except by removing allocations in the cases §19 lists as fixed. §19 is the one part of the chunk that
was added after the design was written; its zero-growth trials (`actors_addition/zero_heap_growth_*`,
`stack_budget_board_addition/*_frees_heap`) exist as the pattern (not re-run for this note) for the remaining cases, which wait on this
chunk's ownership model.

**Update 2026-10-24.** The status above is unchanged as a record of what is built. In its sentences on decisions, "never-freed family arenas spelled `arena(L, S)`" and the open details of Q13 are superseded (Q1, Q2, Q13 as above), Q16 and Q18 are amended, and Q5, Q11, Q3 and Q4 are superseded (decisions 16 and 17, added later the same day); "No decision of §15 remains open" now means the 2026-10-22/23 decisions, not the 2026-10-24 direction's open questions ([data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) section 7.4). **Today:** nothing of the direction is implemented: the family arenas, the implicit heap and the region-moving copy of `term_message_copy.silica` are as described in §1 and §18.

---

## 0. Summary

**Note (Lee, 2026-10-23).** The structure model of §3.1, §3.13 and §3.14 is being redesigned as ROADMAP chunk 15 (data structure redesign), with the decisions of §15 (Q1 to Q11, Q13 to Q18) as its requirements, not provisional. The never-freed family arena of Q2 (a) cannot stand as written once Q13 and Q14 need freeable structure copies; chunk 15 decides where a structure's memory lives and who releases it, and is a prerequisite for stage 2. Requirements: [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md), which is the standard (Lee, 2026-10-23): where this design disagrees with it, it wins.

**Update 2026-10-24.** Chunk 15 has chosen its direction (the paragraph at the top of this document and [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) section 2A). The never-freed family arena of Q2 (a) is removed, not excepted. Stage 2 is no longer a type introduction. Later the same day (decisions 16 and 17) stack regions were made non-linear: the region checker keeps lifetimes and isolation only, `drop_owned` and owner lists are dropped, and Q3, Q4, Q5, Q11 and E2307 are superseded or retired (§3 note, §10).

The chunk's premise was that 1,152 stdlib records embed a move-only region and must become linear. Measured, they do
not hold owned regions at all. Every standard data structure takes its region from `canonical_arena_lookup(key)`: one
**application-lifetime arena** per structure family, never freed, shared by every value of the family, and by design
(common_contract.md §7) the basis of persistence and constant-time meld. The stdlib contains no `alloc_region`, and
neither does the compiler. Making those records linear would break the structures' contract: 149 trial updater calls
reuse the old version, and `graph_wbt_core@set_entry` reads one record three times. It would also buy no safety, because
an arena that is never freed cannot dangle.

The arena is safe, but it only grows. A 1,000-key map exhausts the ESP32-S3 heap in about 740 updates, and a busy host
grows by tens of MB a second (§17). So the design separates the type `region(L, Space)` into an owned kind and a
structure kind. **Decided by Lee, 2026-10-22, and superseded 2026-10-24 (chunk 15 direction): Q2 (a), the never-freed family arena with the atomic bump (stage 0), the handle spelled `arena(L, S)` (Q1 a).** Counted storage was considered and is not part of the plan (§17). In the current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md), structures therefore never reclaim memory; chunk 15 (note above) decides where a structure's memory lives and who releases it:

| Kind | Made by | Handle | Lifetime | Release |
| --- | --- | --- | --- | --- |
| **Owned region** | `alloc_region` | linear (move-only, §4.4.2); every record or tuple embedding one is linear | lexical, by ownership | at the last owner's scope end, or at its actor's end |
| **Structure storage, superseded 2026-10-24 (today: the family arena; Q2 a, Lee 2026-10-22)** | `canonical_arena_lookup` | `arena(L, S)`: copyable, not linear (Q1 a) | application | never (process end) |

The linearity rule holds in full for owned regions and the aggregates that embed them (§3). In the current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md), a structure version is an
`arena(L, S)` handle: copyable, immutable, never freed. What the requirements document fixes instead: a send copies a structure by default and moves it only on request (Q18), sharing inside one message is preserved, a Q13 read returns a copy, a Q14 child start receives a copy released when the child dies, and chunk 15 decides each structure's home and release. Lee's version rules still hold (§3.14): a version is created only
by a change, a change leaves its input valid, and a no-op change returns `:unchanged`. The
stdlib and compiler sources change by script (type spelling, Q1: `region(L, normal)` becomes `arena(L, normal)`). The safety properties of §12 are enforced at
compile time by a new **region checker** pass (§3–§6). Release is driven by explicit `drop` nodes that the SIR
generator places from the checker's ownership facts (§7). Those replace the four emitters' name-independent
heuristics. The run-time checks are the bounds checks that already exist (§8), plus the atomic arena bump that closes
a data race found in this survey (§1.3 H1).

**Superseded (before 2026-10-24):** the two-kind split above (an owned region and a family-arena structure handle `arena(L, S)`), the sentence that the stdlib and compiler sources change by script from `region(L, normal)` to `arena(L, normal)`, and the statement that a Q13 read returns a copy (Q13 is withdrawn: a read returns the stored inner structure). **Replaced by (decisions 12 and 13, 2026-10-24):** one kind, memory with a lifetime on the actor's stack, which `region(L, S)` already names; `region(L, atomic)` shared between actors (Q7) and `device_window` stay outside the stack. Standard structures carry no region field: a structure is its root reference with its lifetime in that type, and updaters allocate in the current frame or at the destination. No rename script. Whether a stack region is linear, and what the checker keeps of E2300 to E2318 and Q11, is answered (decisions 16 and 34: not linear; an area in the current frame). Lee's version rules (§3.14) stand.

Ten silent hazards were found by reading the code (§1.3). Four of them are live use-after-free or race paths that need
no new language rule, and they are stage 0 of the migration (§13), now implemented (H1, H3, H4, H5; status above).

---

## 1. Current state, measured

Measured 2026-10-09 by reading `compiler/src` (the compiler tree), the four emitters, `compiler/stdlib` and `trials/`.
Nothing was built or run for this document. Where a hazard below is inferred from code and not yet shown by a trial,
it says "by reading". Line numbers are from `apple_silicon_mac` unless stated. `linux_aarch64` mirrors it, and
`linux_x86_64` and `ESP32-S3_raw` have the same logic through their ISA helpers.

### 1.1 Enforced at compile time

| Check | Where | Code | Gaps |
| --- | --- | --- | --- |
| Shape of `region`/`ref`/`ref?`/`buf`/`atomic_ref`; valid space | `type_checker_memory_regions@validate_memory_region_type` (226) and helpers | E2010 | — |
| `buf` N is a literal or an in-scope `int64` name | `validate_buf_length_param_in_context` (364) | E2010 | lets only; parameters use the unscoped form |
| Prim argument shapes: `alloc_ref`/`alloc_rec`/`alloc_buf` region vs the expected type, `read_ref`/`write_ref`/`buf_load`/`buf_store` operand and element types | `expressions/type_checker_expressions_region_builtins@check_region_builtin_call` (50) | E2010, E2003, E2005 | the size passed to `alloc_buf` is never compared with N |
| Phase A scope exit: a returned type holding `ref(L…)`/`buf(L…)` must also hold `region(L…)` | `type_checker_memory_regions@check_sequence_return_lifetime` (573), `check_ref_lifetimes_covered` (580) | **E2100** (double-booked, below) | sequence returns only; `ref?` not collected; records `{…}` and `List[…]` not traversed; no nested scopes (Phase B), no cross-function rules (Phase C) |
| Region isolation at `alloc_*` | normal type equality, plus `type_checker_expressions_identifiers` binder fallback (1102, `expected_lifetime_is_binder` 1126) | E2003 | enforced only when the expected L is bound in scope; a free lifetime name accepts any region |
| A region spawned as bare-identifier state is unusable afterwards | `type_checker_expressions_bindings@enrich_env_for_actor_spawn` (112–170) rebinds it as `"moved_region"` | E2003 (generic mismatch) | the only "moved" marker in the checker: bare identifiers at top level only; no records, tuples, calls, messages, returns |
| Region prims need `mem(Space)`, and `atomic` in the atomic space; region work only inside a sequence | `effect_checker_memory_regions@get_region_call_effects` (236), `effect_checker_core@check_all_fn_decls` | E3001, E3002, E3010 | — |
| external_danger regions do not leave the FFI worker | `ffi/ffi_taint_checker` | E2101, E2102, E2103 | — |
| `peek`/`poke` name a described register, so access is in-window by construction | `type_checker_expressions_device`, `type_checker_device_descriptions` (533) | E2209, E2211–E2215 | — |

**E2100 has two meanings.** `type_checker_memory_regions.silica:585` emits E2100 for "reference outlives region".
`ffi/ffi_taint_checker.silica:453` emits it for external-danger taint in a produced value, which is the only meaning
`error_codes.md:93` registers. No error golden uses E2100 in either meaning today, so the region meaning can be moved
without touching goldens (§10).

**No move, use-after-move or linearity diagnostic exists anywhere.** ROADMAP's "the compiler checks only a parameter
whose own declared type is a region" describes an emitter release heuristic (§1.2), not a check: it never reports
anything.

### 1.2 Checked or handled at run time

| What | Where | Behaviour |
| --- | --- | --- |
| **Buffer bounds**, all four emitters | `prims_memory@emit_alloc_buf` (302) stores the element count at `[buf-8]` and rejects a negative count or a multiply overflow (`L_buf_invalid`). `emit_buf_bounds_check` (345) emits `LDR X17,[X1,#-8]; CMP X2,X17; B.HS L_buf_bounds`, inline in `emit_buf_store` (414) and at `term_emit_kind_compound_part2:261` for loads. x86 uses `x86_cmp_branch`; ESP32 aborts inline into `silica_rt_abort_buf_bounds` (`rt_console.S:539`). | process-wide **runtime abort, status 71** (`_silica_rt_abort_with`), even inside an actor. **Decided 2026-10-23 (Q9 a), implemented on the Mac: inside an actor this ends the actor instead (§8); abort 71 stays only in `main`.** |
| Region full | `emit_region_bump_check` (169) calls `L_region_grow` (566), which chains a new block of max(4096, request) on `[r+16]`. ESP32 uses `silica_rt_region_grow` (`rt_heap.S:321`). | abort 71 on allocation failure (hosted `L_region_overflow`; board "heap exhausted"). **Decided 2026-10-22/23, implemented on the Mac: inside an actor the actor ends with `(:explicit, :region_alloc_failed)`; abort 71 stays only in `main` (§8, H5).** |
| Owned-region release: a local | `term_reg_spill@let_owns_local_region` (697; ESP32 833), used by `term_emit_kind_let_top:217` and `…_let_named_tail:223` | `_silica_rt_region_destroy` after the let body, **only** when the body contains no SIR kind-4/5 call at all (`body_has_moving_call`) and the name appears only as an `alloc_*`/`region_*`/`ref_in_region` argument (`region_used_outside_borrow`). Otherwise it leaks. |
| Owned-region release: a parameter | `emitter_core@fn_destroys_region_param` (2376), `region_param_index` (2336), `return_type_carries_region` (2325) | destroys the **first** `region(`-typed parameter (index ≤ 7) at the epilogue when the return type's text has no "region" and the body has no kind-4/5 call. It disables TCO (`tco_eligible` 1665). |
| Fresh let-bound composites (ESP32 only) | `ESP32-S3_raw/terms/term_reg_spill@let_owns_fresh_composite` (696), `fresh_name_moves_in` (666) | frees a `record_make`/`tuple_make` tail block, or a `get_actor_memory_usage` record, at scope end unless the name is moved, rebound or projected to an inline aggregate (budget plan §13). Not in the hosted emitters. |
| Region destroy | `_silica_rt_region_destroy` (mac `prims_actors_runtime_asm:2859`, ESP32 `rt_heap.S:291`) | null is a no-op; a registered canonical arena is left alone (it scans the 512-entry table); otherwise frees the `[r+16]` chain, then the block |
| Canonical arena lookup | `terms/canonical_arena_runtime_asm@_silica_rt_canonical_arena_lookup` | a process-global 512-slot table; it mallocs a 4,128-byte arena on first use and never frees it |
| Actor state and replies | `prims_actors@behaviour_result_move_asm` (573) | shallow shell copy (one word per field) into the running actor's arena on hosted; the ESP32 copies and releases per dispatch (`silica_rt_state_release`, `rt_heap.S:473`) |
| Scope release (`mark`/`release_to`) | `emitter_core` `emit_functions(..., false, false)` (231; aarch64 234, x86 241, ESP32 260) | **disabled** in all four (unsound, memory note 2026-09-04); `prim_allocates`, `body_creates_region` and `_silica_rt_region_release_to` are dead code |

### 1.3 Silent today

Silent means the program runs on and computes with freed, shared or garbage memory. Rows are as surveyed 2026-10-09; **H1, H3, H4 and H5 are fixed and verified on the Mac by stage 0 (2026-10-23); built on pix and nix with no compile errors, no trials run on the Linux compilers yet.**

| # | Hazard | Evidence | Kind |
| --- | --- | --- | --- |
| H1 | **Canonical arenas are process-global and their bump allocation is unlocked.** Two actors updating any structure of the same family (two `wbt_map`s, say) bump the same arena from two carrier threads on hosted (hosted carriers are the execution model, ROADMAP item N), or two cores on the board, and can get the same cell. Arena creation in `_silica_rt_canonical_arena_lookup` is also an unlocked probe-and-insert. | by reading: `canonical_arena_runtime_asm.silica`, `emit_region_bump_check`. **Fixed and verified on the Mac, stage 0 (2026-10-23); built on pix and nix, Linux trials not yet run.** | data race, corruption. **[2026-10-24, decision 37: closes with the family arenas; no shared mutable allocator state remains at the language level.]** |
| H2 | **A region parameter carried away by `cast`, `send` or `spawn` is destroyed by its function.** Those are kind-6 prims, not kind-4/5 calls, so `body_has_moving_call` does not see them. `return_type_carries_region` is false for an `atom` or `actor_ref` result, so `fn_destroys_region_param` frees a region the receiver now owns. (The local-let rule catches this through `region_used_outside_borrow`; the parameter rule has no such check.) | by reading: `fn_destroys_region_param`, `sir_generator/terms/terms_actor_lowering` (cast becomes a prim) | use-after-free |
| H3 | **A let-bound frame aggregate passed by name to a call is not promoted.** It dangles once the caller's frame is reused (memory note 2026-09-08, still true). `arg_aggregate_heap_promote` fires only on a literal `tuple_make`/`record_make` (`term_reg_spill@is_aggregate_make` 946). | by reading; staged repro `wbt_map_tuple_value_escapes_via_let` | use-after-free |
| H4 | **Replies and states live in the replying actor's arena on hosted.** `_silica_rt_actor_dealloc_region` (2571) frees the whole arena when that actor ends, so a caller holding a composite reply from an actor that has since ended (crashed and restarted, or removed) reads freed memory. | by reading: `behaviour_result_move_asm`, `_silica_rt_region_alloc` (2714) | use-after-free, to confirm by trial |
| H5 | **The hosted actor arena returns 0 when it cannot grow** (`LBBra_grow_failed`, 2801), and **hosted `emit_alloc_region` has no null check** after `_silica_rt_raw_alloc`. Both store through address 0 or a small offset. | by reading | silent fault or corruption. **Outcome decided by Lee (2026-10-22, recorded 2026-10-23): a growth or allocation failure ends the actor with `(:explicit, :region_alloc_failed)`, handled by its supervisor; abort 71 only in `main`.** |
| H6 | Lifetimes compare literally, with a binder fallback only on identifier arguments. A free lifetime name accepts any region, so `alloc_ref(r2, …)` typed `ref(L1, …)` passes when L1 is not bound. There is no duplicate-lifetime check, and `fresh_lifetime` lowers to `MOV dest, SP`. | `type_checker_expressions_identifiers:1102–1126` | isolation not enforced |
| H7 | `device_window` lifetimes are erased (`device_window_types_equal_modulo_lifetime`, 793) and the window is not move-only, against spec §4.4.6 and device spec §5.1. Two workers can hold one window. | by reading | spec rule unenforced |
| H8 | Phase A misses `ref?`, records and lists, so `fn f(r: region(L, normal)) -> ref?(L, normal, (…, rec))` (a return spelled with its node shape; a bare `-> ref?(L, normal, rec)` is E2010 under Q19) and `-> { root: ref(L, …) }` compile without the region. This is generic-module convention 5 in the memory notes ("returning `ref?` is not caught"). | `collect_lifetime_ids_from_ref_types` (601) | dangling reference accepted |
| H9 | Owned-region **leaks** (not safety violations, listed for completeness): any region in a scope that makes any call; every region parameter after the first; a region inside a record or tuple; regions held by an actor that crashes; canonical arenas (by design); hosted strings and `main`'s implicit allocations (never freed); the board's residual 492 B per supervisor cycle (budget plan §13). **[2026-10-24, decision 37: closes, because the stack releases everything.]** | §1.2 | leak |
| H10 | `ref(L, atomic, T)` is an ordinary cell: plain `LDR`/`STR`, plus `DMB ISH`/`memw`/`mfence` at function entry, exit and calls. The `atomic_*` builtins of §9.2 (Q8) exist nowhere in the compiler (`alloc_atomic` will not be added). Today nothing lets two actors share an atomic cell; Q7 (a) decides that `region(L, atomic)` may be shared (§9). | by reading: `prims_memory:231/241`, `control/control.silica:42-85` | spec feature missing |

### 1.4 What the code base actually holds

| Measure | Count | Method |
| --- | --- | --- |
| stdlib modules with a record type that has a direct `region(…)` field | 30 (line grep, reproduces 2026-09-25) / 53 of 54 (bracket-aware scan) | `compiler/stdlib/data_structures/*.silica` |
| such record-type occurrences | 1,161 (line grep: multi-line types only) / **2,239** (bracket-aware, including the single-line graph, heap and priority-queue types) | wbt_map 415, wbt_set 318, graph_dense_core 94, tree_binary 88, graph_wbt_core 77, … |
| `(region(L, normal), ref?(L, normal, rec))` tuples | 34 | allocator helpers; the `rec` there is unbound (it would bind to the pair), so under Q19 (requirements document) each is spelled with its node shape |
| `x.region` copies of a handle out of a live record | 127 | e.g. `wbt_map.silica:207` `arena: region(L, normal) <- tree.region;` |
| `alloc_region` calls in stdlib / compiler | **0 / 0** | every stdlib region is `canonical_arena_lookup(key)` (11 constructor sites, keys 1, 81, 82, 83, 85, 90, 91) |
| stdlib functions that take a region record: queries / updaters / constructors | 921 / 367 / 38 | queries return no region; all ten trait files are queries only |
| compiler modules using stdlib structures | 25 (`compiler_maps`, the five `atoms/*` modules × 4 emitters, `type_interner`, `type_surface_cache`, `type_checker_callee_env`, `type_checker_device_descriptions`) | 28 updater, 44 query, 28 constructor calls; all rebind; patterns that would conflict with strict linearity: query-then-update of one binding, partial use after an update |
| trial updater calls followed by reuse of the old version | 149 of 748 (`trials/ordered_data_structures`) | persistence is tested on purpose (`bt_persistence_sharing`, `bo_old_heap_valid_after_pop`) |
| lifetime names in stdlib signatures | `L` only (9,428 uses); no `L: lifetime` parameters anywhere | literal comparison forces one name |
| trials: `memory_region_addition` | 402 run trials (≈345 generated `train_memory_region_*`; hand-written `region_move_*`, `region_local_release`, `region_tuple_return_in_actor`, …) | no trial covers use-after-move or linearity |
| error trials mentioning `region(` | 336 (`train_memory_region_*`, `train_compiler_regionarm_*`) | mostly E2003/E2001/E2018/E3010 mutations |
| files using `ref(L…, atomic` | 62 (44 `train_memory_region_atomic_*` run trials use `alloc_ref` + `read_ref` on atomic refs) | |

### 1.5 Specification inconsistencies found

| # | Where | Conflict | Proposed resolution |
| --- | --- | --- | --- |
| S1 | §16.3.5 "Message contents are copied between actors" vs §12.1.6 "the same move discipline applies" | copy vs move | **decided 2026-10-09 (Lee): move; default superseded by Q18 (2026-10-23): copy by default, move on request**; structures are copied on send by default and moved only on request (Q18; their storage and release are chunk 15's, see data_structure_redesign_requirements.md) (§18); §18.5 lists the spec text to change as Q6 decides; fix §16.3.5 |
| S2 | §4.4.2 "The function must return the handle to the caller" vs trial `region_move_pass_no_return` (a callee that consumes and releases) | must return vs may consume | Q3 decided 2026-10-23: (a), may consume; spec reworded |
| S3 | §12.1.1 "atomic: regions … accessed by multiple actors concurrently" vs §12.1.6 "owned by at most one actor at a time" | sharing | Q7 (decided 2026-10-23: (a), the one named exception) |
| S4 | §17 examples: function-level `proc[...]` (now E3009), `{ok, …}` record-tag syntax, `alloc_atomic()` with no arguments, `ref(R, atomic, ref(R, normal, …))` (a cross-actor pointer into normal memory) | stale syntax, unsound example | rewrite with §9 |
| S5 | §12.3.3 "trap on out-of-bounds" vs the supervision model ("crash to the supervisor") | process abort vs actor failure | Q9, **decided 2026-10-23 (a): actor failure; abort 71 only in `main`** |
| S6 | §4.4.1 / §12.1.4 "functions may take `L: lifetime` as a parameter for polymorphism" vs the stdlib's implicit `L` | value parameter vs type-level | Q10 decided 2026-10-23: (a), implicit per-signature quantification; spec reworded |
| S7 | canonical arenas are not in the specification at all (only common_contract.md §7) | undocumented memory kind | §2; spec text after Q1/Q2 |
| S8 | §30 "Advanced Type System" is a placeholder | — | nothing for this chunk; linearity goes into §4.4.2 and §12 |

---

## 2. Memory model

Three kinds of storage, each with one release rule:

| Storage | Holds | Owner | Released |
| --- | --- | --- | --- |
| **Owned region** `region(L, S)` | what the program allocates in it explicitly (`alloc_ref`, `alloc_rec`, `alloc_buf`) | exactly one binding, in exactly one actor (or `main`) | when its owner is dropped (§7). An actor's owned regions that are still live when it ends are released by the runtime (§7.3). |
| **Structure storage** (current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md)) | stdlib nodes | one arena per family, owned by the application (Q2 a, decided 2026-10-22; chunk 15 decides the home and release, see §0) | never, in the current implementation |
| **Actor heap** (implicit) **(today: removed by the chunk 15 direction, 2026-10-24; escaping values move to the actors' stacks, §19)** | lists, promoted tuples and records, strings, message copies | the actor | hosted: the actor's arena, freed at the actor's end; board: per block (`silica_rt_free`); `main`: never |

The frame is not storage a value may outlive. Item B and `arg_aggregate_heap_promote` move every aggregate that leaves
the frame into the actor heap, and H3 is the one path that still escapes.

**Update 2026-10-24.** The three-row table above, and its "owned region" row (released when its owner is dropped, §7; owner lists, §7.3), describe the 2026-10-22 model and today's runtime. Under the direction owned regions fold into the stack and the structure-storage and actor-heap rows are removed (requirements §2A decisions 1, 2, 5, 12); owned regions are not linear and owner lists are dropped (decision 16); an explicit region is an area in the current frame that follows the rules of any value (decision 34) and mailbox buffers at actor end are released by the end-of-actor drain (decision 31).

The region checker reasons about **owned regions and structure storage only**. The actor heap is outside the type system; its
soundness is the runtime's (item B, H3, H4), and it is in this chunk only because "ends use-after-free" covers it.

**Decided from the spec, no question needed:**
- Owned region handles are linear (§4.4.2), and so is `device_window` (§4.4.6, device spec §5.1). A record, tuple or
  sum value embedding one is linear (§12.1.6, "any composite … that embeds them under the usual linearity rules").
- A `ref`/`buf` may not outlive its region (§12.1.4, §12.4.2), and in a returned value or a message its region travels
  with it (§12.1.4 scope exit rule, §12.1.6).
- Ownership of an owned region transfers on `spawn` (§12.1.5) and on `call`/`cast` submission (§12.1.6); replies return
  it (§12.1.6). Since Q18 (2026-10-23) what transfers is the copy made at the send, or the original when the send is an explicit `move`. **[Superseded 2026-10-24, decision 6: nothing is transferred; an explicit `move` copies too and only ends the sender's use (§18.1). Transfer on `spawn` is likewise a copy into the new actor's stack base (§18.4).]**
- Buffer accesses stay checked at run time (§12.3.3). An out-of-bounds write corrupts data, and an out-of-bounds read
  hands a wrong value onward, so both meet Lee's first criterion.

---

## 3. The aggregate linearity rule

**Superseded in its linearity rules, 2026-10-24 (decision 16).** Stack regions are not linear and safety rests on lifetimes only. Sections 3.2 to 3.12 (uses, moves, partial moves, case-arm ownership, closure capture, linear generics and lists, tail calls) describe the 2026-10-22 model and are kept as the record. What survives is the lifetime and isolation checking of §4 to §6. Q3 and Q4 (§3.2, §3.3) are superseded by decision 17.

### 3.1 Linear types

A type is **linear** if it is, or contains at any depth through record fields, tuple elements and sum variants:
`region(L, S)` (owned), `device_window(L, D)`, or `buf(L, S, T, N)` and `ref(L, S, T)` **when L is the lifetime of an
owned region that is itself carried in the same value**. A `ref`/`buf` alone is not linear: it is a borrowed view, and
§4 checks it by lifetime. Structure handles (`arena(L, S)`, Q1, Q2), scalars, strings, atoms, actor references, lists and function
values are not linear. In the current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md), an arena handle is a copyable word over immutable, never-freed nodes, so within one actor it is used and copied freely; a send does not pass the handle: it copies the structure by default and moves it only on request (Q18), with sharing inside the message preserved. Whether a structure type is linear in the redesign is open (requirements 7.2 item 6).

**Update 2026-10-24 (device_window, decision 24).** `device_window` stays linear in the sense of single ownership: two actors driving one register block corrupts it, so it stays outside the stack with its own single-owner check (spec §4.4.6, H7). No code enforces this today (H7: the window is not move-only; no registered code names it); a code is for the detailed design. The rest of this paragraph's linearity (owned regions, aggregates embedding them) is superseded by decision 16.

**Update 2026-10-24.** `arena(L, S)` is not introduced (Q1 superseded). A structure is its root reference (`ref?(L, normal, rec)`); it is not linear in the sense of an owner to be moved, because its nodes are immutable and its release follows its lifetime on the stack. A stack region is not linear (decision 16, 2026-10-24); Q11 and E2307 are retired (requirements §7.4 items 16 and 17 are answered). The sentence above that mentions "structure handles (`arena(L, S)`, Q1, Q2)" describes the 2026-10-22 decision.

A list, a generic type argument and a trait's associated type may not be linear (E2307, §3.10–3.11). **[Retired 2026-10-24, decision 16: nothing is linear, so E2307 has nothing to restrict.]**

### 3.2 Uses

Every occurrence of a binding of linear type is exactly one of:

| Use | Where it occurs | Effect on the binding |
| --- | --- | --- |
| **Borrow** | the region operand of a region prim: `alloc_ref`, `alloc_rec`, `alloc_buf`, `read_ref`, `write_ref`, `buf_load`/`read_buf`, `buf_store`/`write_buf`, `ref_in_region`, `canonical_arena_same`; the window operand of `peek`/`poke` | none: the value stays owned here |
| **Read** of a non-linear field | `x.f` or a destructuring pattern position whose type is not linear | none |
| **Move** | anything else: a user-call argument, a function-value call argument, a return or `produces pure` operand, a record/tuple/sum literal operand, the right-hand side of a binding, a `case` scrutinee, a `spawn` initial state, a `call`/`cast`/`send` message, a behaviour's reply or new state, and `x.f` with `f` linear (the actor-boundary operands, that is the `spawn` initial state, a message, a reply and a new state, move only when explicitly marked `move(...)`; otherwise they copy, Q18) | the binding is **moved**; any later use is E2301 |

The borrow positions are exactly the prim operands the emitter heuristic already treats as borrows (`rgn_is_region_borrow_prim`).
User functions do not borrow (Q4 a, decided 2026-10-23): a function that inspects a linear value takes it and gives it back.

One expression may not move one binding twice: `f(b, b)`, `(r, r)` and `{ a: r, b: r }` are E2303.

### 3.3 Bindings, rebinding and scope

- Binding `y: T <- x` moves `x` into `y`.
- Silica rebinding of a name (`b <- f(b)`) is a move followed by a fresh binding with the same name: legal, and the
  usual way to thread a value.
- At the end of a binding's scope (the end of its sequence or function body, or of a case arm, §3.6), a binding that is
  still owned is **dropped**: the SIR generator places a `drop` there, and dropping releases every owned region the
  value holds (§7). Dropping is not an error (spec §12.1.2, implicit release at scope exit).
- A parameter is a binding of the whole body. If the function neither returns nor moves it, it is dropped at the end of
  the body, which is today's `region_move_pass_no_return` behaviour. Lee decided on 2026-10-23 (Q3 a) that this stays legal.

### 3.4 Records and tuples

- `x.f` with `f` non-linear is a read, legal while `x` is owned **or partially moved**.
- `x.f` with `f` linear moves that field: `x` becomes **partially moved**. Its other non-linear fields stay readable.
  `x` as a whole, and `x.f` again, are E2304. Its remaining linear fields can still be moved out one by one.
- Destructuring `(a, b) <- x` or a record pattern moves `x` and binds the parts. Each part is owned by its new binding.
- A partially moved value is not dropped as a whole. Its unmoved linear fields are dropped individually at scope end.

### 3.5 Calls and returns

- A linear argument is moved into the callee. The callee's parameter owns it.
- A linear result is owned by the binding that receives it, which may reuse the old name.
- The callee's lifetimes are instantiated per call (§5). A region that goes in as `region(L1, normal)` and comes back as
  the callee's `region(L, normal)` is still L1 at the call site, so refs into it stay valid (§4).

### 3.6 Case arms

Each arm is checked from the ownership state before the `case`. After the `case`, a binding moved in **any** arm is
moved, and a later use is E2301 (the message names the arm). In an arm that does not move it, the binding is dropped at
the end of that arm, so the value is released on exactly the paths that do not hand it on. A scrutinee of linear type is
moved into the arm's pattern bindings.

### 3.7 Function literals

A function literal may not capture a linear binding (E2306). It may be called zero or many times, so it can neither
consume the value nor be sure to give it back. To use a field, read the non-linear field into a binding first and
capture that. Calling a function value with a linear argument is an ordinary move.

### 3.8 Actors

| Construct | Rule |
| --- | --- |
| `spawn(state, beh, policy)` | **[Update 2026-10-24, decision 15: the initial state is copied by the spawner into the new actor's stack base before its first dispatch.]** `state` is copied by default and moved only when marked `move` (Q18, 2026-10-23). After an explicit move, any later use of it, or of a linear part of it, is E2301; before Q18 this was the only mode (§12.1.5). This replaces the `"moved_region"` rebinding, and covers records, tuples and any expression holding an owned region. A structure in it is copied like any other part (sharing preserved); the sender keeps its own and uses it freely, and only an explicit `move` gives it up (Q18). **[Update 2026-10-24: an explicit `move` copies too and only ends the sender's use (decision 6); the "moved_region" replacement stands as E2301 on later use.]** |
| supervised child spec (`init` child list, `add_child`) | **[Update 2026-10-24: E2308 lost its reason with decision 16 (no duplicate owner); E2308 is retired (decisions 11, 15 and 23, 2026-10-24).]** the initial state may not be linear (E2308): the supervisor keeps it in its row to restart the child, which would duplicate the owner (§18.4). A worker that needs a region allocates it in its first message, or receives it by message. A structure is allowed (Q14, decided 2026-10-23): the spec holds the original, the child receives a copy at every start and restart, and the copy is released when the child dies. The copy's destination, its type, who makes it and the home of the spec's original are chunk 15's open details. **[Answered 2026-10-24, decision 11: the copy is made into the new child's stack base at each start or restart and is released with the child's stack.]** |
| `call(a, msg)`, `cast(a, msg)`, `send`, the `_registered` forms | `msg` is copied at submission by default (Q18, 2026-10-23); with an explicit `move` it is moved (§12.1.6, §18) and any later use of a linear value in it is E2301. The runtime transfers ownership of every owned region in it to the receiver (§7.3). A structure in it is copied by default (sharing inside the message preserved) and the sender keeps its own; with an explicit `move` it is moved. **[Superseded 2026-10-24: "The runtime transfers ownership of every owned region in it to the receiver (§7.3)" no longer holds; nothing is transferred. The message, including one marked `move`, is copied into a buffer attached to the mailbox entry (§18.7), and `move` only ends the sender's use.]** |
| behaviour `fn beh(msg: M, state: S) -> (:reply, R, S)` | `msg` and `state` are owned parameters. The reply and the new state are moved out: each linear part of `msg` and `state` must be in the reply, in the new state, moved elsewhere, or dropped, and a part that is moved goes to at most one of them. Under copy-by-default (Q18) a region or structure that is in both the reply (or a message) and the new state is not a duplicate owner, because the reply or message carries a copy; E2303 applies only when one of the two is an explicit `move(...)` (§18.1). The usual threading is `(:reply, x, (r2, k + 1))`. **[Update 2026-10-24: the message is a dispatch-scoped buffer, released at dispatch end unless a part is kept; kept parts and the new state are evacuated to the stack base (§18.7, §18.8). "Moved out" above is the earlier model.]** |
| a `call`'s result | ~~moved to and owned by the caller's binding (§12.1.6)~~ **[Superseded 2026-10-24, decision 33:]** the replier copies the reply into the blocked caller's stack, just below the caller's parked SP; it lives in the caller's frame as the call's result and pops with it. One copy, no reply buffer. A reply that arrives after the caller stopped waiting (the future `call_with_timeout`) is dropped under the call record's lock. |
| `cast_exit`, `wait_for_exit` | no ownership effect (§12.4). |

Spec §15.1.1 already says the state is moved into the behaviour and the new state replaces it. These rules only make the
checker enforce it.

### 3.9 Sequences

A `sequence … produces pure e end` is a scope. Bindings made in it that are still owned at `produces` are dropped after
`e` is evaluated, unless `e` moves them. That is spec §12.1.2's scope-tied release, now driven by ownership, not by
allocation site.

### 3.10 Generics and traits

A type parameter (`ItemType`, `KeyType`, `ValueType`, `PriorityType`, `AccType`, …) or a bracket argument may not be
instantiated with a linear type (E2307). Generic code copies its items freely: `get` returns a stored value, and a fold
passes the accumulator around. Allowing linear instantiation would need a linear-aware generic checker; that is decided (Q11, 2026-10-23: a linear type may not instantiate a
generic type parameter, list element type or trait associated type; a linear-aware generic checker may be added later). Trait methods take the trait type, which (after Q1) holds an arena, so traits are unaffected. **[Retired 2026-10-24: decision 16 retires Q11 and E2307; no type is linear.]**

### 3.11 Lists

`List[T, mem(S)]` with `T` linear is E2307. A list shares its suffixes (copy-on-write prepend), so two lists could own
one region.

### 3.12 Recursion and tail calls

A recursive call that passes the region on is a move, so no drop is placed after it, and the tail call stays a tail
call. `tco_eligible` loses its region exclusion once drops replace `fn_destroys_region_param` (§7.4).

### 3.13 Worked examples

**Note 2026-10-24.** The owned-region examples of this section are the 2026-10-22 model (linear owned regions, `alloc_region`), kept as the record. Stack regions are not linear (decision 16): the move, partial-move, drop, `E2301`/`E2303`/`E2304`/`E2306` cases below no longer apply to them, and a region parameter is neither consumed nor returned (decision 17). The lifetime cases (`E2300`, `E2302`) and isolation cases (`E2310`) still do, and so does `E2301` as a lifetime error for use after an explicit `move(x)` (decision 22).Of the list just above, `E2301` is therefore not among the cases that no longer apply. The structure example at the end of the section has its own update. (`device_window` keeps one owner, outside the stack, with its own check: decision 24; see §3.1 and §6.)

The threading pattern: the function gets the aggregate, borrows the region for a prim, and gives the aggregate back.

```silica
fn push(b: { r: region(L, normal), n: int64 }, v: int64) -> { r: region(L, normal), n: int64 } {
    sequence proc[mem(normal)]
        _: ref(L, normal, int64) <- alloc_ref(b.r, v);   // borrow of b.r: b stays owned
    produces
        pure { r: b.r, n: b.n + 1 }                       // b.r moves into the result; b.n is a read
    end
}

fn main() -> int64 {
    sequence proc[mem(normal)]
        L1: lifetime <- fresh_lifetime();
        r: region(L1, normal) <- alloc_region(normal);
        b: { r: region(L1, normal), n: int64 } <- { r: r, n: 0 };   // r moves into b
        b <- push(b, 7);                                              // b moves in, comes back, rebinds
        b <- push(b, 8);
        n: int64 <- b.n;
    produces
        pure n                                                        // b is dropped here: region released
    end
}
```

The misuses the checker reports:

```silica
        b1: { r: region(L1, normal), n: int64 } <- push(b, 7);
        b2: { r: region(L1, normal), n: int64 } <- push(b, 8);   // E2301: b was moved into push on the line above
```

```silica
        b: { r: region(L1, normal), n: int64 } <- { r: r, n: 0 };
        _: ref(L1, normal, int64) <- alloc_ref(r, 1);             // E2301: r was moved into b on the line above
```

```silica
        pair: (region(L1, normal), region(L1, normal)) <- (r, r);  // E2303: r moved twice in one expression
```

Partial moves:

```silica
fn take_region(b: { r: region(L, normal), n: int64 }) -> (region(L, normal), int64) {
    r0: region(L, normal) <- b.r;     // moves the field: b is partially moved
    k: int64 <- b.n;                  // read of a non-linear field: legal
    (r0, k)                           // using b here instead would be E2304
}
```

Case arms:

```silica
fn finish(b: { r: region(L, normal), n: int64 }, keep: boolean) -> int64 {
    case keep of {
        true -> archive(b);           // moves b
        false -> b.n                  // b not moved: dropped at the end of this arm, region released
    }
}
```

Closures:

```silica
        f: fn(int64) -> int64 <- fn(x: int64) -> int64 { x + b.n };   // E2306: captures linear b
        n0: int64 <- b.n;
        g: fn(int64) -> int64 <- fn(x: int64) -> int64 { x + n0 };     // legal
```

Actors: `region_tuple_return_in_actor` is already linear-correct. The state's region is destructured, threaded through
`mk`, and returned in the new state:

```silica
fn beh(msg: int64, state: (region(L, normal), int64)) -> (:reply, int64, (region(L, normal), int64)) {
    sequence
        (r0: region(L, normal), k: int64) <- state;
        (r1: region(L, normal), a: ref(L, normal, (int64, ref?(L, normal, rec)))) <- mk(r0, msg);
        sum: int64 <- val(a) + k
    produces pure (:reply, sum, (r1, k + 1)) end
}

fn main() -> int64 {
    sequence proc[concurrency, mem(normal)]
        L: lifetime <- fresh_lifetime();
        r: region(L, normal) <- alloc_region(normal);
        a: actor_ref <- spawn(move((r, 0)), beh, stack_policy(0, :keep_last_message));   // explicit move (Q18): (r, 0) moved; a plain spawn((r, 0), …) would copy
        v: int64 <- call(a, 1 impl ActorMessage {});
    produces pure v end
}
```

Writing `alloc_ref(r, 5)` after this explicit-move `spawn` is E2301 ("r was moved into spawn"); after a plain, copying `spawn` it is legal. That is the case
`enrich_env_for_actor_spawn` catches today only as a generic E2003.

Within one actor a structure version is today an `arena(L, S)` handle (current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md)), which is copyable, so a change leaves its input usable and a version may be bound again (§3.14; requirements R2 and R3, persistence and reuse, hold whatever the storage):

**Update 2026-10-24.** In the example the `region: arena(L, normal)` field is removed by decision 13: the state record holds the root reference, and `wbt_map@insert` allocates its new nodes in the current frame. `m0` stays valid after the insert for the reason given (a change does not consume its input).

```silica
        m0: { root: ref?(L, normal, (K, V, int64, ref?(L, normal, rec), ref?(L, normal, rec))), …, region: arena(L, normal), … } <- wbt_map@empty(…);
        r1: :unchanged | (:inserted, { … }) | (:replaced, { … }) <- wbt_map@insert(m0, 1, 10);   // m0 is unchanged and still valid
        old: int64 <- wbt_map@size(m0);
        kept: { … } <- m0;                                                                      // a copy of the handle
        again: int64 <- wbt_map@size(m0);                                                       // legal
```

### 3.14 Structure versions: arena handles, and only a change makes one

**Lee's version rules (2026-10-09, option A). The rules stand. Their 2026-10-22 storage basis (Q2 (a), the never-freed family arena) is superseded 2026-10-24: versions live on the actors' stacks (requirements §2A).**
- Current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md): a structure version is a record holding an `arena(L, S)` handle (Q1). It is **not linear**: binding, storing, copying, passing on and returning it within an actor create nothing, because the nodes are immutable and live in a never-freed arena. No count, no `dup` and no ownership check applies to a version. Sending it is not a handle pass under the standard: a send copies by default and moves only on request (Q18, §18).
- A new version is created **only by a change**: insert, update, delete, meld and the like.
- **A change does not consume its input.** After `r <- wbt_map@insert(v1, k, x)`, v1 is still a valid version. A real
  change yields a new version v2 that shares v1's unchanged nodes. Persistence is observable.
- **A no-op change returns `:unchanged`, not a version.** Inserting an identical entry, deleting an absent key, melding
  with an empty heap and the like produce no version at all. The program carries on with v1: no copy and no run-time
  check.

**Under the direction (2026-10-24).** A version is its root reference. A change builds its new nodes in the current frame (or at the destination when the compiler sees where the result is kept), pointing up into the older nodes of the input, which stays valid; a no-op returns `:unchanged`. Reading an inner structure returns the stored one (Q13 withdrawn). A returned version is delivered by destination-passing or evacuation of the popped frame's nodes; a version not returned is cleaned up at the pop (§19). The bullet above that says versions "live in a never-freed arena" is today's behaviour.

**Not scheduled in chunk 4.** Moving the stdlib's change results to the shapes below (367 updaters, about 300 caller sites in
`trials/` and 55 in the compiler) is an API change that no stage of this plan carries; it was part of the removed
counted-storage stage, and ROADMAP chunk 15 takes it over. The rules above stay as the design of the result shapes, for whenever it is scheduled. **[Decision 37, 2026-10-24: the reshaping stays in chunk 15, done in the same pass as the stdlib storage rewrite.]**

**Result shapes.** Every change returns a sum whose first alternative is `:unchanged`, and whose other alternatives are
tagged tuples carrying the new version. The tag says *what* changed, so the stdlib's current flags fold into the tag.
Error outcomes that are not no-ops (overflow, incompatible operands, a rejected edge) are their own atom alternatives.

| Family | Change | Result type (`V` = the family's version record, written inline in real code) | Today's flags it replaces |
| --- | --- | --- | --- |
| maps (`wbt_map`) | `insert` | `:unchanged \| (:inserted, V) \| (:replaced, V)` | `inserted`, `replaced` |
| | `delete` | `:unchanged \| (:removed, V)` | `removed` |
| sets (`wbt_set`) | `insert` / `delete` | `:unchanged \| (:inserted, V)` / `:unchanged \| (:removed, V)` | `inserted` / `removed` |
| heaps (`brodal_okasaki_*`, `PriorityQueue`) | `insert` | `(:inserted, V)` (never a no-op) | — |
| | `pop` | `:unchanged \| (:popped, T, V)` (`:unchanged` on an empty heap) | `status: :not_found` |
| | `meld` | `:unchanged \| :incompatible \| (:melded, V)` (`:unchanged` when the other heap is empty) | `compatible` |
| skew lists (`skew_ral_*`) | `update` / `append` / bulk | `:unchanged \| :overflow \| (:updated, V)`, … | `updated`, `appended`, `status`, `valid` |
| trees (`tree_binary`, `tree_rose`) | `replace_*` / `clear_*` / `add_child` / `remove_child` | `:unchanged \| :incompatible \| (:changed, V)` (`(:added, V, slot)`, `(:removed, V, count)` where a payload is returned today) | `changed`, `added`, `removed`, `compatible` |
| graphs (`graph_*`) | `add_vertex` / `add_edge` | `:unchanged \| :rejected \| (:inserted, V) \| (:replaced, V)` | `inserted`, `replaced`, `rejected` |
| | `remove_edge` / `remove_vertex` | `:unchanged \| (:removed, V)` | `removed` |

Callers match the variants by destructuring patterns, which is how Silica matches sums (no typed variant bindings):

```silica
        r: :unchanged | (:inserted, { … }) | (:replaced, { … }) <- wbt_map@insert(m1, k, x);   // borrows m1
        n: int64 <- case r of {
            :unchanged -> wbt_map@size(m1);                       // no new version: carry on with m1
            (:inserted, m2: { … }) -> wbt_map@size(m2);           // m2 shares m1's unchanged nodes
            (:replaced, m2: { … }) -> wbt_map@size(m2)
        };
```

**No-op changes in the stdlib today**, for the migration: these return their input and become `:unchanged`. About 69
return sites in 23 modules, found by grep for `{ map: old_map, … }`-style results:

| Family | No-op cases | Sites |
| --- | --- | --- |
| maps | identical insert, delete of an absent key | 5 |
| sets | insert of a present item, delete of an absent item | 5 |
| heaps | pop of an empty heap, meld with an empty or incompatible heap | 5 |
| skew lists | out-of-range update, overflow, invalid bulk input | 25 |
| trees | replace or clear with no change, incompatible attach, remove of an absent child | 9 |
| graphs | existing vertex or identical edge, rejected add, absent edge or vertex | 16 |

Callers inspect today's flags about 300 times in `trials/` and 55 times in the compiler, mostly `.inserted` through
`compiler_maps@map_insert_or_get_index`. Each would become a `case` on the result when the reshaping is scheduled.

---

## 4. Static region-lifetime analysis (Phases B and C)

**Note 2026-10-24.** "Arena lifetime" below refers to the family arenas and `arena(L, S)`, removed by the direction (requirements §2A decisions 1, 12); what replaces the arena exception (a structure's lifetime is carried in its root reference's type) is for the detailed design. Decision 16 (2026-10-24): safety is by lifetimes, so this section is the part of the checker that stays; "owned binding" below reads as "binding of a lifetime-scoped stack area", and the "moved out or dropped" ends of a lifetime become "its frame or area is popped" (no ownership moves).

With linearity in place, the lifetime environment of spec §12.1.4 falls out of ownership:

- **A lifetime is live** in a scope while some owned binding in that scope holds the owned region of that lifetime,
  whole or as a field. It is also live for the whole body when it is a signature lifetime of a region parameter,
  until that parameter is moved out, and for the whole program when it is an arena lifetime.
- **A lifetime ends** when the last binding holding its region is moved out of the function (returned, sent, spawned,
  passed to a callee that does not return it) or dropped. A region passed to a callee and returned (the threading
  pattern) does not end its lifetime: the result is the same lifetime, by §5's instantiation.
- **Reference use rule (Phase B).** Every operand of type `ref(L…)`/`ref?(L…)`/`buf(L…)` to a prim, call, literal or
  return must have L live at that point, else **E2302** ("reference used after its region was moved or released at
  line N"). This subsumes the spec's `scope_current ≤ scope_r` and `scope_current ≤ scope_ref`.
- **Return and message rule (Phases A + C).** A value leaving the function (return, `produces pure`, message, spawn
  state, reply, new state) that contains `ref(L…)`/`ref?(L…)`/`buf(L…)` at any depth, through records, tuples, sums and
  lists, must contain `region(L…)` in the same value, or L must be an arena lifetime. Otherwise it is **E2300** (the
  renumbered E2100), which fixes H8.
- **Parameter rule (Phase C).** Inside a callee, a parameter `ref(L…)` with no `region(L…)` parameter is a borrowed
  view, valid for the whole body: the caller cannot drop the region during the call. It may not be returned or sent
  (E2300), because the callee has no proof of how long L lives.
- **Duplicate lifetime.** Two owned regions live at once under one lifetime name is **E2309**. Allocating a second
  `alloc_region` into a binding whose type names a lifetime that is still live is the common form.

The analysis is flow-sensitive over one function body only, so the checker never needs to look into another
function's body. Cross-function facts come from signatures alone, which is what keeps it compatible with interface
files (`.iface`) and per-unit compilation.

---

## 5. Lifetime polymorphism

Today a callee must spell the caller's lifetime name. That is why the stdlib uses `L` everywhere and trials use `L1`.

**Options:**

| | Spelling | Cost | Notes |
| --- | --- | --- | --- |
| A | **Implicit per-signature quantification.** Every lifetime name in a function's signature is a variable of that function. Each call instantiates them, consistently across all arguments and the result. | no source change; the stdlib's `L` and the trials' `L1` both just work | a lifetime appearing only in the result is a fresh lifetime the callee creates and returns with its region (E2300 otherwise) |
| B | Spec §12.1.4: `L: lifetime` value parameters | every polymorphic function gains a run-time argument that means nothing at run time; 9,428 stdlib sites change | contradicts "nothing hidden" only mildly, but costs a register per call |
| C | Bracket generics `fn f[L](…)` | parser and generic machinery change; stdlib rewrite | mixes lifetime with type generics, which the module conventions already strain |

**Decided (Q10, Lee, 2026-10-23): A.** Implementation: in the call checker (`type_checker_expressions_user_call_check_args_result`)
build one substitution per call: callee lifetime name → caller lifetime. Unify every argument against it, and a
conflict is **E2311** ("lifetime L of push is bound to both L1 and L2"). Apply the substitution to the result type.
`types_equal_surface` keeps comparing literally *after* substitution, so the change is local to call sites,
tuple-decomposition of call results (`tuple_decompose_helpers:819`) and the identifier binder fallback, which this
replaces. `fresh_lifetime()` keeps its role of naming a local lifetime. Its `MOV dest, SP` lowering becomes dead code
and can be removed.

---

## 6. Region isolation

**Note 2026-10-24.** The arena exceptions and `arena`/`canonical_arena_same` mentions below are the 2026-10-22 model; `arena(L, S)` is not introduced (decision 12). Isolation stays (decision 16, 2026-10-24); only the arena exception is obsolete. `device_window` keeps its lifetime and its one owner (decision 24); that check needs its own code, for the detailed design.

- `alloc_ref(r, v)`, `alloc_rec(r, v)`, `alloc_buf(r, n)`: the result's L must equal r's L after §5's substitution
  (E2310), whether or not L is bound in scope. This fixes H6.
- Storing a reference into a region cell: if `v` contains `ref(L2…)` or `buf(L2…)` and r's lifetime is L1 ≠ L2, it is
  **E2310** unless L2 is an arena lifetime. Spec §12.4.1 forbids cross-region references, and the arena exception is
  sound because an arena outlives every owned region. A ref into an owned region inside an arena node is E2310 too,
  since arena nodes outlive the owned region.
- Comparison operators (`==`, `!=`, `<`, …) are not defined on `region`, `arena`, `ref`, `buf`, `device_window` (E2318),
  mirroring §7.4 for actor references. Identity is `ref_eq` and `canonical_arena_same`.
- `device_window` keeps its lifetime (remove the erasure in `device_window_types_equal_modulo_lifetime`) and is linear
  (§3.1).

---

## 7. Ownership-based release

**Superseded 2026-10-24 (decision 16).** `drop_owned`, ownership facts from the checker, and per-actor owner lists are dropped: stack areas are released when their frame pops or the message ends, and an actor's end releases its whole stack. §7.1 to §7.4 are kept as the record. Pending mailbox buffers at actor end are released by the end-of-actor drain (decision 31).

### 7.1 One mechanism: `drop` nodes in SIR

The region checker (§11) records, for every function, the owned bindings still owned at each scope exit and at the end
of each case arm that did not move them. The SIR generator inserts a kind-6 prim `drop` (name `drop_owned`, value = the
binding, type = its type) at exactly those points. The checker has already accepted the program, so the SIR pass only
re-derives "owned here and not moved later on this path" over the let spine. It reports nothing.

Emitters lower `drop_owned`:

| Type of the dropped value | Lowering |
| --- | --- |
| `region(L, S)` | `_silica_rt_region_destroy(handle)`, X0/X1 (the scope's result) preserved, as `emit_region_destroy_reg` does today |
| record/tuple/sum embedding owned regions | load each owned-region field and destroy it; for a sum, branch on the tag first. The field offsets come from the boxed layout (one word per field, `prims_record`). |
| `device_window` | no code (unmapping is not specified); the checker still enforces single ownership **[2026-10-24: `drop_owned` is dropped (decision 16), but `device_window` keeps one owner (decision 24); the check needs its own code]** |

Then remove `let_owns_local_region`, `fn_destroys_region_param`, `body_has_moving_call`, `region_used_outside_borrow`, the
dead `region_name_escapes`/`body_has_user_call`, and the disabled `mark`/`release_to` scope path with
`prim_allocates`/`body_creates_region`, in all four emitters. That leaves one mechanism for one invariant, as the
memory notes ask. The ESP32 `let_owns_fresh_composite` frees **actor-heap** blocks, not regions, and stays as it is; a
later chunk can fold it into `drop_owned` once composites have owners.

**Why this is sound where scope release was not:** a `drop` is placed only where the checker proved the value is owned
and every later path neither names nor moves it. Scope release freed by allocation time, not by ownership, and freed
moved values (memory note 2026-09-04).

### 7.2 Run-time cost

A drop is one call per owned region per scope exit, only in functions that own one. The compiler and the stdlib own
none, so their emitted code and goldens are unchanged by §7.1 except where the removed heuristics fired. They never
fire there (0 `alloc_region` sites).

### 7.3 The runtime's part: owner lists

Owned regions must also be released when their actor ends with them still in locals or state (a crash, `remove_actor`,
supervisor shutdown). Otherwise every restart leaks the crashed instance's regions (H9).

**Update 2026-10-24 (decision 16: confirmed; Q5 is superseded).** Owned regions fold into the stack and an actor's end releases its whole stack, so per-actor owner lists are dropped. What releases mailbox buffers still pending when an actor ends (they hang off mailbox entries, not the stack) is the end-of-actor drain (decision 31, 2026-10-24): the runtime walks the mailbox queue once and frees each pending buffer, O(pending); the queue is the list, with no owner list. The recommendation below is the 2026-10-22 decision (Q5 (a)) and is kept as the record.

**Recommendation (Q5).** Every owned region's header carries a doubly linked owner link (two words: header 32 → 48 bytes)
on its owning actor's region list, rooted in two new ACB words (`main` has a static root).

- `alloc_region` links the region into the current actor's list; `_silica_rt_region_destroy` unlinks it.
- **[Superseded 2026-10-24: no region is transferred on a send; the payload is copied into the mailbox buffer (§18.7).]** Message submission (`call`/`cast`/`send`) and `spawn` move every owned region in the payload (since Q18, the payload is the copy made into a fresh owned region, or the original on an explicit `move`): the compiler emits,
  after the payload is built, one `_silica_rt_region_transfer(handle, target)` per owned region it contains, from
  the payload's type, which unlinks it from the sender's list and links it into the receiver's. The ESP32 has two cores,
  so this runs under the scheduler lock there.
- A reply moves the other way.
- Actor end walks the list and destroys every region still on it, before the ACB is recycled.

The alternative, a compiler-generated "state destructor" per behaviour, misses regions held only in locals at the
moment of a crash. So does doing nothing.

### 7.4 Effects on existing behaviour

- The trials `region_move_pass_and_return`, `region_move_pass_no_return`, `region_move_conditional` and
  `region_local_release` keep their outputs. Their release now comes from drops.
- Regions in scopes that make calls stop leaking. A trial must show it with the write-every-page method, not by
  allocation (memory note: untouched pages never fault in).
- `tco_eligible` drops its region-parameter exclusion.

---

## 8. Buffer bounds checking

Already done at run time on all four targets (§1.2). Remaining:

| Item | Proposal |
| --- | --- |
| failure outcome | **Q9, decided by Lee, 2026-10-23: (a).** Inside an actor an out-of-bounds buffer index, an invalid buffer size (`L_buf_invalid`) and a list-index failure **terminate the actor**, with failure reasons `(:explicit, :buf_bounds)`, `(:explicit, :buf_invalid)` and `(:explicit, :list_index)`, reported like a fault and handled by its supervisor. Only in `main` do they remain runtime abort 71. The access is never performed, so no data is corrupted. Region growth failure and the raw allocation failure of H5 follow the same rule with `(:explicit, :region_alloc_failed)` (Lee, 2026-10-22). This is Lee's "crash to the supervisor". |
| static: literal size | `alloc_buf(r, 10)` bound to `buf(L, S, T, 16)` is **E2313**. A name N must be the same binding as the size argument, or a binding equal to it by a straight-line copy. |
| static: literal index | `read_buf(b, 15)` with literal N = 10 is **E2314**. |
| `\|bounds:N` SIR metadata | **Removed (2026-10-23): nothing read it.** The run-time check stays for every index, including literal indexes that E2314 has already proved in range. |
| foreign buffers (chunk 13) | a `buf` that crosses from a wrapper must be built by the lowering in a Silica region with the length word at `[buf-8]`. The bounds check then needs no special case. The FFI design inherits this as a representation contract. |
| MTE (§12.3.3, §21.3) | not in this chunk; the software check is the specified fallback. |

---

## 9. Atomic references

### 9.1 The question underneath

An atomic cell is useful only when two actors (two threads or cores) touch it. Today nothing lets two actors hold one
region: §12.1.6 forbids it, and §1.3 H10 notes the compiler offers nothing for it. Spec §12.1.1 and §17.2.4 assume
sharing. Lee decided Q7 on 2026-10-23: (a), model A below. `region(L, atomic)` is the one named exception to §12.1.6's
no-cross-actor-sharing rule, on all targets: hosted actors are threads in one process and share an address space, atomic
instructions (LDAXR/STXR on AArch64, `lock cmpxchg` on x86-64) are ordinary user-mode instructions that the H1 bump loop
already uses, and the ESP32-S3's two cores use S32C1I. Only the chunk 14 uses (interrupt handlers, DMA and peripheral
registers as the second party) are unavailable on hosted OSes; those wait for chunk 14.

| | Model | Consequence |
| --- | --- | --- |
| A | **Shared atomic regions.** `region(L, atomic)` is an application-lifetime region like an arena: copyable handle, may go in messages and spawn state, never released. Only `ref(L, atomic, T)` cells live in it, with `T` a word scalar (`int64`, `uint64`, `int32`, `uint32`, `boolean`, `atom`); a pointer into normal memory may not be stored (E2316). | the one place actors share mutable memory, and only through atomic operations. The lock-free stack of §17 (an atomic cell holding a ref into a normal region) is rejected and is removed from the spec. |
| B | Atomics only within an actor's owned region | sound and simple, but an atomic cell then has no second party except interrupts and DMA (chunk 14) |
| C | Remove atomics from the language until chunk 14 | the 62 trial files and §17 go |

**Decided (Q7, Lee, 2026-10-23): A**, created by `alloc_region(atomic)`. Allocation into a shared atomic region uses an atomic bump
(below), because several actors may allocate.

### 9.2 Surface (Q8)

**Decided (Q8, Lee, 2026-10-23): the recommended surface below.** It keeps the 44 run trials and Silica's current style (atoms, tagged tuples, no conversions):

```
alloc_ref(r: region(L, atomic), initial: T) -> ref(L, atomic, T)          // alloc_atomic is not added
read_ref(c: ref(L, atomic, T)) -> T                                         // = atomic_load(c, :seq_cst)
write_ref(c: ref(L, atomic, T), v: T) -> atom                               // = atomic_store(c, v, :seq_cst)
atomic_load(c: ref(L, atomic, T), order: atom) -> T
atomic_store(c: ref(L, atomic, T), v: T, order: atom) -> atom
atomic_fetch_add(c: ref(L, atomic, T), v: T, order: atom) -> T              // integer T only
atomic_compare_exchange(c: ref(L, atomic, T), expected: T, new: T, order: atom) -> (:ok, T) | (:fail, T)
```

`order` must be an atom literal from `:relaxed | :acquire | :release | :acq_rel | :seq_cst`, legal for the operation (a
load takes no `:release`, a store no `:acquire`), else **E2317**. An `atomic_*` operation on a non-atomic ref is
**E2315**. The effects stay `mem(atomic)` plus `atomic` (`effect_checker_memory_regions`).

### 9.3 Lowering

| Target | load / store | fetch_add | compare_exchange | allocation bump |
| --- | --- | --- | --- | --- |
| apple_silicon_mac (LSE present) | `LDAR`/`LDR` + ordering, `STLR`/`STR` | `LDADDAL` (or `LDADD{A,L}` by order) | `CASAL` | `LDADDAL` on `[r]` |
| linux_aarch64 | same; if the host lacks LSE, `LDAXR`/`STLXR` loops (the port checks `HWCAP_ATOMICS` once, or always loops: Fable's choice) | | | |
| linux_x86_64 | `MOV` (+ `MFENCE` after a `:seq_cst` store, or `XCHG`) | `LOCK XADD` | `LOCK CMPXCHG` | `LOCK XADD` |
| ESP32-S3_raw (LX7) | `L32AI`/`S32RI` (acquire/release), `memw` for `:seq_cst` | `S32C1I` loop with `SCOMPARE1` | `S32C1I` | `S32C1I` loop |

ESP32: 64-bit atomics are not native on the LX7. `int64`/`uint64` cells there take the runtime's spinlock (the
scheduler lock pattern), so one program means one thing on every target (decided, Q8).

The function-level `DMB ISH`/`memw`/`mfence` barriers that `mem(atomic)` adds today (`control/control.silica`,
`effects/emitter_effects`) become redundant once each operation carries its own ordering, and are removed (decided, Q8).

### 9.4 The same bump fixes H1

**Note 2026-10-24 (decision 37).** With the family arenas gone, H1 (the shared canonical arena table) closes and no shared mutable allocator state remains at the language level; the atomic bump stays for `region(L, atomic)` (Q7). The text below is today's stage 0.

**Today (2026-10-24 note: the canonical arenas are removed by the direction; the atomic bump stays for `region(L, atomic)`):** canonical arena allocation (`alloc_rec`/`alloc_ref` into an arena) switches to the atomic bump, and
`_silica_rt_canonical_arena_lookup`'s insert becomes a compare-and-swap on the key slot. That is stage 0 (§13). It
costs one atomic RMW per stdlib node allocation, which is uncontended in the common case.

---

## 10. Error codes

**Update 2026-10-24 (decision 16).** The region checker enforces lifetimes and isolation only. The last column gives each code's disposition. Retired codes stay in the table as the record and stay numbered (numbers are not reused); the registry (`error_codes.md`, `error_codes.jsonld`) is not edited here. Codes that will need registry updates: E2300 (moved from E2100), E2302, E2310, E2311, E2315, E2316, E2317 and E2318 are to be registered as active; E2301 is also to be registered as active (a lifetime error, decision 22); E2303 to E2309 and E2312 are to be registered, if at all, as retired (E2308 and E2309 by decision 23); a new code for the `device_window` single-owner check is for the detailed design (decision 24); E2313 and E2314 are already registered.

`E23xx` is unused (registry and sources). The block `E2300–E2318` becomes the region-safety family, next to the
device family (E22xx). The type checker's "reference outlives region" moves from E2100 to E2300, which leaves E2100 with
its one registered meaning. E2319 and E2320, drafted for counted storage, were removed in revision 1.9 and their numbers are not reused.

| Code | Name | Raised when | Phase | Disposition (decision 16, 2026-10-24) |
| --- | --- | --- | --- | --- |
| E2300 | ReferenceOutlivesRegion | a returned, sent or spawned value holds `ref`/`ref?`/`buf` of lifetime L without `region(L)`, L not an arena lifetime (§4) | region checker (moved from type checker E2100) | **Stays** (lifetime) |
| E2301 | UseAfterMove | a linear binding used after it was moved (names the move's line and, for case, the arm). For messages only an explicitly `move`d value qualifies (Q18, 2026-10-23); a plain send copies | region checker | **Stays** (lifetime: use after an explicit `move(x)` reads released memory; decision 22) |
| E2302 | ReferenceAfterRegionGone | a `ref`/`buf` of lifetime L used after L's region was moved out or dropped | region checker | **Stays** (lifetime; "moved out or dropped" reads "frame or area popped") |
| E2303 | LinearMovedTwice | one expression moves one binding twice; or a linear value (an owned region) is both kept in an actor's new state and given away as its reply or in a message by an explicit `move(...)` (Q18, 2026-10-23: a plain, copying send is not a duplicate owner; §18.1) | region checker | **Retired** (linearity: duplicate owner) |
| E2304 | PartiallyMovedValueUsed | whole use, or second move, of a record or tuple after a linear field was moved out | region checker | **Retired** (linearity: partial move) |
| E2305 | RegionParameterNotReturned | reserved and unused: Q3 was decided (a) on 2026-10-23, so an unreturned, unmoved parameter is legal; the number is not reused | region checker | **Retired** (already reserved and unused; Q3 superseded, decision 17) |
| E2306 | LinearCapture | a function literal captures a linear binding | region checker | **Retired** (linearity: closure capture) |
| E2307 | LinearTypeArgument | a linear type as a list element type, generic type argument or associated type | type checker | **Retired** (decision 16: Q11 retired) |
| E2308 | LinearRestartableState | a supervised child spec's initial state is linear (§18.4) | type checker (`type_checker_supervisor`) | **Retired** (decision 23: the spec is copied into each child's stack base) |
| E2309 | DuplicateLifetime | two live owned regions share a lifetime name | region checker | **Retired** (decision 23: named owned regions; lifetime conflicts are E2311) |
| E2310 | CrossRegionReference | `alloc_*` result L differs from the region's L, or a ref of L2 is stored in region L1 (L2 not an arena) | type checker | **Stays** (isolation; the arena exception is obsolete) |
| E2311 | LifetimeConflictAtCall | one callee lifetime bound to two caller lifetimes | type checker (call checker) | **Stays** (lifetime polymorphism) |
| E2312 | ArenaSpaceMismatch | reserved (moot since 2026-10-24: `arena(L, S)` is not introduced): arena space differs from the record's declared space (Q1 implementation detail) | type checker | **Retired** (moot: `arena(L, S)` is not introduced) |
| E2313 | BufferLengthMismatch | `alloc_buf` literal size ≠ literal N | type checker | **Stays** (bounds) |
| E2314 | BufferIndexOutOfRange | literal index ≥ literal N, or negative | type checker | **Stays** (bounds) |
| E2315 | AtomicOperandNotAtomic | `atomic_*` on a non-atomic ref | type checker | **Stays** (atomics) |
| E2316 | AtomicCellType | atomic cell type not a word scalar | type checker | **Stays** (atomics) |
| E2317 | AtomicOrderingInvalid | ordering not a literal atom, or illegal for the operation | type checker | **Stays** (atomics) |
| E2318 | ComparisonOnRegionType | `==`/`!=`/ordering operators on region, arena, ref, buf or device_window | type checker | **Stays** (comparison on region-kind types; "arena" is obsolete) |

Run-time outcomes, not codes (decided 2026-10-23): buffer bounds, invalid size and list index (actor failure `(:explicit, :buf_bounds)` /
`:buf_invalid` / `:list_index` per Q9), region growth failure and H5's null paths (actor failure `(:explicit, :region_alloc_failed)`); each is abort 71 only in `main`.

E2313 *BufferLengthMismatch* and E2314 *BufferIndexOutOfRange* (§8, spec §12.3.3) are registered in `compiler/error_codes.md` and `error_codes.jsonld`.

Each message carries `spec:§4.4.2`, `§12.1.4`, `§12.1.6`, `§12.4.1`, `§12.3.3` or `§17` and the standard metadata
block (spec §1.6), like every other code.

---

## 11. Where the checks run

**Update 2026-10-24 (decision 16).** The region checker enforces lifetimes and isolation only (the region checker raises E2300, E2301 and E2302; E2310 and E2311 stay in the type checker, §10). It keeps no per-binding ownership state (owned / moved / partially moved), emits no ownership facts for SIR, and the SIR generator places no `drop_owned`. The runtimes have no owner lists (atomic bump and actor failure on bounds remain). The table below is the 2026-10-22 record; read its type-checker row without E2307 and E2308, the region-checker row as E2300, E2301 and E2302 only (E2309 retired), and drop the SIR and owner-list entries.

| Phase | Data it needs | Checks |
| --- | --- | --- |
| type checker | types, the per-call lifetime substitution | E2307, E2308, E2310–E2318, and §5 |
| **region checker** (new directory `region_checker/`, after the type and effect checkers, before SIR) | the typed AST with locations; each binding's type from the type checker's environment; per function: binding → owned / moved(line, arm) / partially moved(fields); lifetime → live / gone(line) | E2300–E2306, E2309; emits per-function ownership facts for SIR |
| SIR generator | the accepted program | places `drop_owned` (§7.1); stops emitting `\|bounds:` unless used (§8) |
| emitters (four) | `drop_owned`, transfer calls, atomic prims | lowering only; no ownership decisions |
| runtimes | owner lists, atomic bump, actor failure on bounds | §7.3, §8, §9.4 |

The region checker reads the type checker's results the way the effect checker does. A program with type errors does
not reach it, so its codes never duplicate E2003 noise.

---

## 12. Interactions

| With | Effect |
| --- | --- |
| **Item K** (`wait_for_exit`, `cast_exit`) | no ownership effect. When `main` returns, actors are abandoned with their owned regions still linked; the process end reclaims them, and on the board `silica_rt_exit` halts. `main`'s own owned bindings are dropped at its scope end, after `wait_for_exit` returns. That is safe: anything an actor holds was moved and is not `main`'s to drop. |
| **Growable actor stacks** (chunk 1, board item F) | stacks are released at the message boundary, so nothing may point into a stack across it. Regions are heap blocks, and a handle in a frame slot is fine. Aggregates rely on item B and H3's fix. A crash mid-behaviour leaves owned regions in frame slots, which §7.3's owner list reclaims. **[Update 2026-10-24: under the direction escaping values and state live on the stack. Nothing points into a stack across the message boundary because kept data is evacuated to the stack base, which the release algorithms never pop (§18.8; decision 27: the policies measure from the state edge, a word in the actor control block). "Regions are heap blocks" is today's behaviour.]** |
| **Actor messages and replies** | copy by default, move on request (Q18, 2026-10-23; Q6's move default is superseded; §18). The copy goes into a fresh owned region that moves by pointer plus owner transfer (§7.3), as does an explicitly moved original. A structure is copied like any other part of the message, sharing preserved, and moved only on request (Q18). Plain immutable values are copied into the receiver; the H4 case needs the targeted stage 0 fix. **[Superseded in part 2026-10-24: the copy goes into a mailbox buffer, not a fresh owned region that moves; there is no owner transfer, and an explicit `move` copies too (§18.7).]** |
| **Supervised restart** | E2308 keeps owned regions out of child specs (E2308 is retired, decision 23, 2026-10-24); a structure may be in a spec, and each start or restart gives the child a copy, released when it dies (Q14). **[Decision 11, 2026-10-24: the copy goes into the child's stack base and is released with the child's stack.]** |
| **FFI** (dangerous actors) | E2101–E2103 stay as they are. The region checker treats `external_danger` regions as ordinary owned regions, and the taint checker's "only into actor state or an FFI result cast" is stricter, so the two compose. Chunk 13 inherits §8's length-word contract for `buf(L, S, uint8, N)`. |
| **Device windows** | linear (§3.1). The `spawn_device` initial state moves the window. A window message is an explicit ownership transfer (device spec §5.1–§5.2). DMA buffers moved to the worker and back (device spec §5.3) are ordinary linear region moves, which this chunk finally enforces. Window lifetimes are no longer erased (H7). `peek`/`poke` borrow. |
| **Board memory** | an owned region's first block is 4,128 B on every target (`emit_alloc_region`), 1.2% of the board's 354,816-byte heap per region. Proposal (decidable without Lee): a per-target first-block size, 512 B on `ESP32-S3_raw`, growing as now. The owner links add 16 B per region. Canonical arenas are 4,128 B each on first use and are never freed; nine families means ≤ 37 KB on the board if all are used. Worse, they only grow: a 1,000-key map updated ten times a second exhausts the heap in about 74 s (§17). Q2 (a) (2026-10-22) keeps the arena for now, so a long-running board app that updates a structure still exhausts the heap until chunk 15 decides otherwise. **[Update 2026-10-24: the direction removes the canonical arenas, so their sizing and "Q2 (a) keeps the arena for now" are today's behaviour; a board actor's stack and state area count against its existing stack reservation, the board memory budget for the chunk chain on the ESP32-S3 (decision 26), and `stack_policy` measures from the state edge (decision 27).]** |
| **Chunk 9** (networking) | received bytes arrive in `buf(L, S, uint8, N)`. §8 gives the bounds check, and an overrun fails the connection's actor (Q9), not the server. |
| **Chunk 13** | depends on §8 and on Q9's failure outcome for `recreate`'s limit checks. |
| **Chunk 2** (carriers) | owner lists are per actor, not per thread, so carriers change nothing (owner lists are dropped, decision 16, 2026-10-24). H1's fix is needed either way. |

---

## 13. Migration plan

**Bootstrap rule.** A rule or type the compiler's own source uses must be implemented by the **published** compiler that
builds that source. The seed rejects what it does not know, with E2005/E2003. So every language change lands in two
steps, implement-and-publish then use, and an error that the compiler's own source would trip may be switched on only
after a published compiler can build that source cleanly. Each stage ends at fixed points on apple_silicon_mac, then
linux_aarch64 and linux_x86_64 (lock-step), and with a green ESP32 cross build and board suites. "Gate" below means:
`make integrate` green on every host, gen3 == gen2 on all three, and the board suites named.

| Stage | Content | Language change? | Gate |
| --- | --- | --- | --- |
| **0. Silent hazards** | H1 atomic arena bump and CAS arena insert (§9.4); H2 count `cast`/`send`/`spawn`/`call` prims as moving in the existing heuristics (interim, removed at stage 4); H3 promote let-bound frame aggregates passed by name (wire the staged trial); H5 null checks, ending the actor with `(:explicit, :region_alloc_failed)` (abort 71 in `main`; Lee, 2026-10-22); renumber the region meaning of E2100 to E2300 | no | the hazard trials of §14.2 fail before and pass after; fixed points. **Status 2026-10-23: H1, H3, H4, H5 and Q9 implemented and verified on the Mac; built on pix (linux_aarch64, compiler 999964) and nix (linux_x86_64) with no compile errors; no trials run on the Linux compilers yet; ESP32-S3 mirror not built.** |
| **1. Lifetime polymorphism** | §5 option A: per-call substitution, E2311 | yes, relaxing only (accepts more) | trials that spell a generic `R` pass; the `L1` workaround comments go from the trials; fixed points. Nothing in the compiler's source needs it. |
| **2. Structure handle type** | **Superseded 2026-10-24 (decisions 12 and 13): `arena(L, S)` is not introduced and no rename script is run. Stage 2 is now the removal of the family-arena field from the stdlib records, allocating in the frame: a stdlib change with no new type; it waits on the chunk 15 design, not on a type.** Superseded text (before 2026-10-24): the handle spelled `arena(L, S)` (Q1 a, Q2 a, decided 2026-10-22; not linear, accepted by the allocation prims, obtained from `canonical_arena_lookup`): type checker, interner, SIR, emitters. No cell is ever freed, so run-time behaviour is today's arena exactly and the fixed points cannot move. The constructors' `canonical_arena_lookup` result is accepted into the new type, and during the transition also into a `region` binding (a named transition rule, removed at stage 5). Specification addition S7. **Publish.** Then a script renames the stdlib's handle fields from `region(L, normal)` to `arena(L, normal)` and rewrites the allocator tuples (2,239 record types, 34 tuples, the `x.region` lets) and the 25 compiler modules' inline map types, verified with `git diff`, not the masked regex view (memory note). | yes | stdlib, `ordered_data_structures` and the compiler build; fixed points with the rewritten source. **Waits on ROADMAP chunk 15 (2026-10-23), which decides whether the handle and the family arena stand.** |
| **3. Region checker, report-only** | §11 checker behind a `silica.config` switch (`region_check: report`), writing `<unit>.regions` reports, no diagnostics, so no golden changes. | no (reports only) | reports over the stdlib and the compiler show **no linear misuse**; reports over `trials/` are reviewed, and every entry is either a real misuse (it becomes an error trial in §14) or a checker defect (fixed). Board trial sources are included. **[Update 2026-10-24, decision 16: the report-only checker reports lifetime and isolation findings only (E2300, E2302, and E2310 where it is checked); "no linear misuse" has no meaning.]** |
| **4. Drops and owner lists; copy-on-send and `move(x)` (Q18)** | **Language change (Q18):** the copy-on-send mechanism (a send copies the message into a fresh owned region that then moves; type-directed copy, with the per-message sharing table where the type allows sharing, requirements R4.1 and R4.2) and the `move(x)` marker, beside `copy_to` and the mailbox drain. The legacy `move` builtin was removed in commit 146f34bf19 (2026-10-17), so `move(...)` gets E2007 today; the negative trial `error_enforcement_addition/actor_move_removed_unknown_function` must change when `move(x)` is implemented. §7.1 `drop_owned` in SIR and emitters for owned regions; remove the heuristics; §7.3 runtime owner lists and transfers; the per-target first-block size; **message regions (§18.7):** `drop_owned` at behaviour return for a message's owned regions unless they flow into the new state, partial move out of a message record, `copy_to`, release on a failed send, reply regions dropped for a dead or timed-out caller, and the actor-end walk covering the unprocessed mailbox | **yes** (Q18: sends copy by default, `move(x)` marker; `copy_to` is a new compiler builtin `copy_to(region, value)` derived per type like `recreate`, Q15 decided 2026-10-22) | §14.2 release trials (write-every-page) on every host and the board; the message-region trials of §18.6 (`message_region_released_at_dispatch_end` and the others except the chunk-11 one); positive copy-on-send trials (the sender keeps and uses its data; sharing inside a message preserved) and `move(x)` trials, with `actor_move_removed_unknown_function` changed; `memory_region_addition` and `actors_addition` unchanged; `.ascomp` goldens refreshed only where `.sout` = `.scout`; fixed points **[Update 2026-10-24: under the direction the copy goes into a mailbox buffer (not a fresh owned region that moves), kept parts are evacuated to the stack base (not moved into state), `move(x)` copies, `copy_to` is retired (decision 34), and owner lists and `drop_owned` are dropped (decision 16, 2026-10-24; mailbox buffers at actor end are released by the end-of-actor drain, decision 31). Read this row's "owner lists", "partial move" and "moves" accordingly.]** |
| **5. Errors on** | `region_check` defaults to `error`; the transition rule from stage 2 is removed; E2300–E2318 error trials wired; **E2301 narrowed (Q18): it applies only to explicit `move(...)` and function-call moves, and E2303 likewise (a region in both a message and the new state is a duplicate owner only when one is an explicit move)** | yes | the compiler's own source passed stage 3 clean, so it builds; fixed points; the error suite is green on the three hosts **[Update 2026-10-24: the stage 2 transition rule no longer exists; which of E2300 to E2318 remain is decided by decision 16 and listed in §10: errors on means E2300, E2301, E2302, E2310, E2311 and the unchanged bounds and atomics codes; E2301 stays as a lifetime error (decision 22); E2303 to E2309 and E2312 are retired, so the narrowing of E2301 and E2303 in this row is moot for E2303.]** |
| **7. Atomics** (after stage 1, parallel to 3–6) | §9: builtins, lowering on four targets, shared atomic regions per Q7 | yes | the atomic run trials plus two-actor counter and CAS trials on the hosts and both board cores |
| **8. Bounds outcome and static buffer checks** (any time after 0) | Q9 actor failure (decided 2026-10-23: `:buf_bounds`, `:buf_invalid`, `:list_index`; abort 71 only in `main`); E2313/E2314; `\|bounds:` removed | yes (E2313/E2314) | §14 trials. **Status 2026-10-23: Q9 outcome and E2313/E2314 literal checks implemented and verified on the Mac, built on pix and nix (no Linux trials run yet), ESP32-S3 mirror not built; `\|bounds:` removed.** |

Stages 0, 1 and 8 do not depend on the open decisions. Stage 2 needed Q1 and Q2 (decided 2026-10-22: `arena(L, S)`) and now also waits on chunk 15; stage 4 needed Q5 (decided 2026-10-22, with Q15 to Q17); stage 5 needed
Q11 (decided 2026-10-23, with Q3 and Q4); stage 7 needed Q7 and Q8 (both decided 2026-10-23). There is no stage 6: the counted-storage stage was removed under Q2 (a) (2026-10-22), and the numbers 7 and 8 are kept so that references stay stable. The ROADMAP gate ("enforced at compile time or halted at run time, never silent;
the linearity rule holding for a region in a record or tuple; trials; stdlib and compiler at their fixed points under it")
is met at the end of stage 5 plus the targeted stage 0 fix for H4 named in participate.md. Structures do not reclaim memory unless chunk 15 changes that, and stage 7 closes
"atomic references".

**Update 2026-10-24.** Stage 2 no longer needs Q1 or Q2 as written: both are superseded, and stage 2 is the stdlib field removal that waits on the chunk 15 design. Stage 4 needs the direction's mailbox buffer and stack-base design instead of owner lists and region moves. Decision 16 (same day, later) reduces stages 3 and 5 to lifetime and isolation checking and removes `drop_owned` and owner lists from stage 4. Decisions 18 to 21 give stage 4 its release machinery instead: the per-behaviour use analysis and per-dispatch release log (18), the fallback copy with a compiler note and a strict mode (19), evacuation via scratch with two copies (20) and exact-size free lists in the state area (21); the analysis, the note's code number and the strict-mode spelling are for the detailed design. "Structures do not reclaim memory unless chunk 15 changes that" in the paragraph above is today's behaviour.

---

## 14. Trials

### 14.1 Error trials (misuse catalogue)

**Update 2026-10-24 (decision 16).** Rows for retired codes (E2303 to E2309, E2312) are not to be written. Rows for E2300, E2301 (as a lifetime error: the cases with an explicit `move`), E2302, E2310, E2311, E2313 to E2318 stand. The rows below are the record.

Each case is one `.silica` + `.golden_fail` under `trials/error_enforcement_addition/`, golden re-derived from real output.
A construct that the bootstrap compiler rejects in a batch goes into its own `compile_defects_<slug>_addition` directory
(memory note: a rejected unit aborts a suite's batch compile).

| Code | Cases (one trial each) |
| --- | --- |
| E2301 | region used after move into a call; after an explicit `move` into `spawn` state; into a `cast` message; into a `call` message (a plain, copying send leaves the sender's use legal and needs a positive trial instead, Q18); after return in one arm, used after the `case`; record holding a region moved twice in sequence; tuple holding a region used after destructure; parameter used after passing on; rebinding inside a `case` arm, used outside. **[Dated note 2026-10-24 (decision 24): the case "device_window used after `spawn_device`" moved to the device_window single-owner row below; its old place in this row was after "tuple holding a region used after destructure".]** |
| future `device_window` single-owner code (decision 24; no code today, it needs one in the detailed design) | device_window used after `spawn_device`; a window moved to a worker and used by the sender; the same window sent to two actors |
| E2302 | `read_ref` after the region was moved into a callee that did not return it; `buf_load` after the owning record was sent; ref used after its region was dropped by a `case` arm; ref of a parameter region used after that region was passed on |
| E2300 | return `ref?(L…)` without the region (H8); return `{ root: ref(L…) }`; return `List[ref(L…), mem(normal)]`; cast a message holding a ref without its region; spawn state holding a ref without its region; a callee returning its borrowed `ref` parameter |
| E2303 | `f(b, b)`; `(r, r)`; `{ a: r, b: r }` |
| E2304 | whole record after `x.r`; `x.r` twice |
| E2306 | function literal capturing a region; capturing a record holding one |
| E2307 | `List[region(L, normal), mem(normal)]`; `wbt_map` with a region value type; generic `ItemType` instantiated with a region record |
| E2308 | supervisor `init` child spec whose initial state holds a region |
| E2309 | two `alloc_region` into the same `L1` both live |
| E2310 | `alloc_ref(r2, …)` typed `ref(L1, …)` with L1 unbound (H6); storing `ref(L1…)` into a cell of region L2 |
| E2311 | callee `f(r: region(L, normal), c: ref(L, normal, int64))` called with L1 and L2 |
| E2313, E2314 | literal size mismatch; literal index 15 into N = 10; negative literal index |
| E2315–E2317 | `atomic_fetch_add` on a normal ref; atomic cell of a record type; `atomic_load(c, :release)`; ordering passed as a variable |
| E2318 | `r1 == r2` on regions; `c1 != c2` on refs |
| E2301, E2303 (moves) | the message-move cases of §18.6: an owned region, or a record holding one, used after an explicit `move` into `cast`, `call`, `send`, `spawn`; sent in one arm and used after the `case`; replied and kept in the new state, with one of the two an explicit `move(...)` (a plain, copying send is legal and needs a positive trial); `cast(a, (r, r))` |

### 14.2 Run trials

| Trial | Shows |
| --- | --- |
| `region_released_in_calling_scope` | a local region in a scope that calls a function is released (RSS, write every page): leaks today |
| `region_second_param_released` | the second region parameter is released |
| `region_in_record_released` | a record holding a region dropped at scope end releases it |
| `region_case_arm_release` | released only on the arm that does not move it; no double free on the arm that does |
| `region_param_sent_by_cast_not_freed` | H2: callee casts its region parameter to an actor that writes and reads it after the callee returned |
| `region_spawn_state_param_not_freed` | H2 via `spawn` |
| `wbt_map_tuple_value_escapes_via_let` | H3 (staged today) |
| `two_actors_same_family_inserts` | H1: two actors insert 100,000 keys each into their own `wbt_map`; validate both |
| `reply_after_callee_ended` | H4: read a composite reply after the replying actor was removed |
| `crashed_actor_regions_released` | §7.3: a worker that allocates a region and divides by zero, restarted 1,000 times; heap growth bounded |
| `region_moved_between_actors` | an owned region in a `cast` with an explicit `move`, written by the receiver; the sender's list no longer holds it (released once, at the receiver's end) **[Update 2026-10-24: under the direction an explicit `move` copies and nothing moves between actors; the trial becomes: the receiver reads the message buffer, it is released at the end of the receiving dispatch, and the sender's use after the `move` is E2301. "Released once, at the receiver's end" is superseded.]** |
| `generic_lifetime_name` | a callee spelled `region(R, normal)` called with `region(L1, normal)` (stage 1) |
| `buf_bounds_ends_actor` | Q9: an out-of-bounds write in a worker ends the worker, the supervisor restarts it, `main` continues |
| atomic: `atomic_counter_two_actors`, `atomic_cas_loop`, `atomic_orderings`, on hosts and the board's two cores | §9 |
| `device_window_moved_once` (board) | window moved into a worker, used there |
| `no_op_change_returns_unchanged` | per family: identical insert (map, set), delete of an absent key/item, meld with an empty heap, pop of an empty heap, skew-list update out of range, tree replace with the same subtree, graph remove of an absent edge and add of an existing vertex; each returns `:unchanged`, the program carries on with v1 and its contents are intact; no node is allocated (allocator probe). Waits on the result reshaping of §3.14, which no stage of chunk 4 carries (chunk 15 owns it). |
| `change_result_variants` | every tagged alternative of §3.14's result table matched by destructuring (`(:inserted, m2: …)`, `(:replaced, …)`, `(:popped, item, h2)`, `:incompatible`, `:overflow`, `:rejected`), with the old version still used after the match |
| `persistence_old_versions_valid` | `bt_persistence_sharing` and `bo_old_heap_valid_after_pop` shapes under the stage-5 checker: old versions stay valid after changes |
| `no_op_change_on_moved_version` | the same no-op changes on a structure received from another actor (a copy, Q18): `:unchanged`, and the sender's own structure is untouched |
| move trials of §18.6 | `reply_and_keep_same_version`, `move_reply_version`, `move_map_of_sets`, `supervised_child_restarts_with_version`, `move_two_cores` (board), and the owned-region trials listed there **[Update 2026-10-24: `move_two_cores` is superseded (§18.6).]** |

Each existing `region_move_*` and `region_local_release` trial keeps its output through stage 4.

---

## 15. Decisions for Lee (all decided; Q13 and Q14 open details are owned by chunk 15; the chunk 15 direction of 2026-10-24 supersedes Q1, Q2 and Q13, amends Q6, Q16, Q17 and Q18, confirms Q14 in stack form, supersedes Q3, Q4, Q5 and Q11 (decisions 16 and 17) and puts Q15 up for revisit, see the notes under each)

**Q1. How is a structure's storage handle told apart from an owned region in the type?**
**Decided by Lee, 2026-10-22: (a), spelled `arena(L, Space)`** (Q2 is (a)): a new non-linear type constructor, accepted by the allocation prims and obtained from `canonical_arena_lookup`; a script renames the stdlib handle fields from `region(L, normal)` to `arena(L, normal)`; the transition rule during stage 2 is removed at stage 5; specification addition S7.
The spelling follows Q2 (a). (a) A new type constructor `arena(L, Space)`. It is not linear, it is accepted by the allocation prims, and the constructors obtain it. (b) A reserved
lifetime name (`app`), so `region(app, normal)` is the structure handle. (c) Infer it from where the handle came from.
*Recommend (a)*, spelled `arena(L, Space)`.
- It is explicit (nothing hidden) and a script can do the rename.
- It keeps the per-family L.
- It names what the handle does.
- (b) rewrites all 9,428 `L` uses and merges all families' lifetimes.
- (c) cannot work through generic signatures.

Any choice makes S7 a spec addition.

**(First note, replaced by the next one on 2026-10-24.) Amended by the chunk 15 direction (2026-10-24):** the family arena that `arena(L, Space)` names no longer exists (structures live in the actors' stacks), so the handle has no referent; its replacement, and therefore chunk 4 stage 2, is open. See [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) section 2A and section 7.4.

**Superseded by the chunk 15 direction, decisions 12 and 13 (2026-10-24):** `arena(L, Space)` is not introduced. `region(L, S)` means a lifetime-scoped area of the actor's stack in memory space S (atomic regions and `device_window` stay outside the stack); standard structures carry no region field and are their root reference. See [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) section 2A.

**Q2 [superseded 2026-10-24, see the full wording after this entry]. How are the standard data structures stored, and is their memory ever given back? — Decided by Lee, 2026-10-22: (a), the never-freed family arena with the atomic bump (stage 0).** Counted storage (biased counting, a size-class allocator, counted list chunks, change-result reshaping at the counted level) is not part of this plan and its design was removed from this document (§17). Consequences: stage 2 spells the handle `arena(L, S)`; structures still never reclaim memory (a 1,000-key map exhausts the ESP32-S3 heap in about 740 updates, a busy host grows by tens of MB/s) until a later project; H4 (replies in the replier's arena) needed the targeted stage 0 fix listed in participate.md (implemented on the Mac, 2026-10-23); biased counting is not needed.
The options considered (§17):
- (a) **Never-freed family arena**, as today: one process-global arena per structure family, with an atomic bump
  (stage 0). Simple and fast, with O(1) meld within a family. Nothing is ever reclaimed.
- (b) **Counted regions**: each node a small region with a count; memory returns when the last version goes.
- (c) **Hybrid:** (b) by default, plus an immortal constructor per family.
- (d) Per-actor arenas freed at actor end: reclaims only on actor end or restart. A long-running actor still grows.
- (e) One owned region per structure with explicit `compact`: reclamation by hand, and versions die at each compaction.
Lee chose (a). Q13 and Q14 (2026-10-23) need structure copies that are freed, which a never-freed arena cannot hold; ROADMAP chunk 15 resolves that tension and is not resolved here.

**Superseded by the chunk 15 direction (2026-10-24):** there is no family arena and no `canonical_arena_lookup`; structures live in the actors' stacks, state at the base of the stack, released deterministically (compiler-proven release). See [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) section 2A.

**Q2 as superseded (Lee, 2026-10-24, requirements §2A decisions 1, 2, 3, 4).** Standard data structures are not stored in a family allocation. They live in the actors' stacks; every escaping value (returned structures, records, tuples, list cells, strings, call replies) is on the stack too, by destination-passing or evacuation of the popped frame's nodes. Actor state is at the base of the stack. Memory is given back deterministically: at a frame pop, at the message boundary, and for old state versions by compiler-proven release (with the dispatch-end copy as the fallback), never by a collector. Options (a) to (e) above stay as the record; the direction is none of them: it is closest to (d) with the stack as the arena. **Today:** the never-freed family arena is the implementation (§1.2, §17).

**Q3. May a function consume a region parameter without returning it? — Decided by Lee, 2026-10-23: (a).** E2305 RegionParameterNotReturned stays reserved and unused.
(a) Yes: an unreturned, unmoved parameter is dropped and released, as `region_move_pass_no_return` expects today.
(b) No, per §4.4.2's "must return": E2305.
*Recommend (a)*, rewording §4.4.2 to "must return it if the caller is to keep it". Releasing is a legitimate end of
ownership, and locals already drop.

**Superseded by decision 17 (2026-10-24):** a callee cannot release its caller's frame, so a region parameter is neither consumed nor returned; E2305 stays unused.

**Q4. Should user functions be able to borrow? — Decided by Lee, 2026-10-23: (a).** Revisit (b) only if real owned-region code shows the threading to be a burden; (a) never rejects a program (b) would accept, so (b) can be added later. (Structure versions are copyable arena handles and need no borrowing, §3.14. The question is for owned regions. [Update 2026-10-24: a structure is now its root reference and still needs no borrowing; owned regions are not a separate linear kind (decisions 16, 17 and 34: Q4 is superseded).])
(a) No. Only the region prims borrow, and a function that inspects a linear value takes it and returns it.
(b) A parameter marker for a borrowed linear value.
*Recommend (a)* for chunk 4. After Q1 the stdlib's 921 queries take arena records, which are copyable, so the pressure
for borrowing is gone. Revisit if real owned-region code shows the threading to be a burden.

**Superseded by decision 17 (2026-10-24):** the take-and-return rule followed from linearity; reading needs no take-and-return.

**Q5. Who releases the owned regions of an actor that ends? — Decided by Lee, 2026-10-22: (a), a per-actor runtime owner list, ownership transferred on message and spawn (§7.3).** It covers locals at a crash, queued mailbox messages and failed sends.
(a) A per-actor runtime owner list, with ownership transferred on message and spawn (§7.3). (b) A compiler-generated
destructor of the state type. (c) Nobody: they leak until process end.
*Recommend (a).* Only it covers regions held in locals at a crash.

**Superseded by decision 16 (2026-10-24; first recorded the same day as a consequence for Lee to confirm):** owned regions fold into the stack and an actor's end releases its whole stack, so per-actor owner lists are dropped. What releases mailbox buffers still pending at actor end is the end-of-actor drain (decision 31). See [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) section 2A.

**Q6. Messages: move or copy? [default superseded by Q18; the O(1) move superseded 2026-10-24] — Decided by Lee, 2026-10-09: move; narrowed by Q2 (a), 2026-10-22.** An owned region carried by a message, reply or spawn state is moved, and the sender may not use it afterwards (E2301). **Default superseded by Q18 (2026-10-23): a send copies by default and moves only on request; E2301 then applies only to explicitly moved values.**
- **[Superseded 2026-10-24, decision 6: a move is not an O(1) handle transfer.]** Every move is an O(1) handle transfer (§7.3).
- Structures (Q18, requirements R4): a send copies a structure by default, preserving sharing inside the message, and moves it only on request; after a copy the sender keeps its own. (The current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md), passes the `arena(L, S)` handle by value.) Nothing is counted (the biased-counting design of 2026-10-09 was removed with the counted-storage stage, §17).
- Plain immutable values are copied by the runtime. H4 (a reply in the replier's arena) needs the targeted stage 0 fix.

**Q6 as it stands (2026-10-24).** Messages COPY by default (Q18). An explicit `move(x)` copies the data to the receiver too; it only means the sender may not use x afterwards (E2301), so the sender's frame can release it at once. There is no O(1) cross-actor transfer of memory; the copy is made into a buffer on the mailbox entry (§18.7). Function calls still move. The list above is the 2026-10-09 decision as narrowed on 2026-10-22, kept as the record.

Spec changes: §18.5.


**Q12. How does a program send a version it also keeps? — Withdrawn 2026-10-22: moot under Q2 (a).** Lee decided on 2026-10-09 that there is no `share` builtin and that keeping and giving away one version is E2303. That rule existed because a counted version had exactly one handle. Under Q18 a send copies by default, so there is nothing to share and nothing to forbid: a version may be kept in the new state and also replied or sent (a copy goes out). Today's copyable arena handle was the Q2 (a) reason (current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md)). E2303 keeps its other meanings (one expression moving a binding twice; an owned region both kept and given away by an explicit `move(...)`, Q18), where the second use really is a second owner.


**Q13 [withdrawn 2026-10-24, see the note after this entry]. Reading a version stored inside a structure (a graph's inner adjacency set from `get`). — Decided by Lee, 2026-10-23: structural copy.** Reading an inner structure version out of a container returns a copy of the inner structure, built the way `copy_to` builds a copy (Q15), not the stored arena handle. The alternatives were (a) return the handle (recommended) and (b) queries only; Lee chose neither.
- The stored original is untouched.
- Cost: O(size of the inner structure) per read.
- In the current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md), arenas are never freed (Q2 a), so each read would leave a new copy behind for the life of the application; that cannot stand with Q13 (requirements R1.2), and chunk 15 decides where the copy lives and who releases it.
- A loop of such reads over a graph is quadratic in the worst case.
- Queries over the inner structure (`has_edge`, `neighbors`) are unaffected and need no copy.

*Open detail (not decided; owned by chunk 15):* (1) which arena receives the copy, the caller's arena or the inner type's family arena; (2) the exact signature and spelling, an explicit `copy_to`-style call or `get` copying implicitly. Until Lee answers, neither is chosen.


**Withdrawn by the chunk 15 direction (2026-10-24):** `get`, and any read of an inner structure, returns the stored inner structure itself with no copy; it is immutable and sits in an older frame or at the stack base. See [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) section 2A, decision 10.

**Q14. May a supervised child's initial state hold a structure version? — Decided by Lee, 2026-10-23: a copy is sent to the child at start and cleaned up when the child dies.** The supervisor's child spec may hold the version. At every start and every restart the child receives a COPY of it, a structural copy built the way `copy_to` builds one (Q15, Q13), and that copy is released when the child dies. This is neither (a) restarts reuse the shared handle (the earlier recommendation) nor (b) E2308 forbids versions in specs. E2308 stays for owned regions (linear, so the row would duplicate the owner). Consequences and OPEN DETAILS (not decided; owned by chunk 15): (1) a copy that is cleaned up at child death cannot live in the never-freed family arena of Q2 (a); it must live in a region the child owns, released by the Q5 per-actor owner list at the child's end, so the child's state then holds data in an owned region, not an `arena(L, S)` handle. How that copy's type is spelled, and how it relates to `arena(L, S)` and to Q16 (a received region may move into state), is undecided. (2) The cost is O(size of the version) per start and per restart, which matters for restart storms. (3) Which side makes the copy (the supervisor at spawn, or the runtime on spawn) and the destination of the copy are undecided. (4) Whether this shows that Q2 (a) needs a per-instance exception for structures that must be freed is for Lee.


**Confirmed in stack form by the chunk 15 direction (2026-10-24):** each start or restart copies the spec's structure into the new child's stack base (cost proportional to its size per start); the child's death releases it with the stack. See [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) section 2A, decision 11. E2308, which this entry says stays for owned regions, is retired (decision 23, 2026-10-24).

**Q7. May two actors share atomic memory? — Decided by Lee, 2026-10-23: (a), on all targets.** `region(L, atomic)` is the one named exception to §12.1.6; hosted actors are threads sharing an address space, atomic instructions are ordinary user-mode instructions (already used by the H1 bump loop), and the ESP32-S3 cores use S32C1I. Only the chunk 14 uses (interrupt handlers, DMA, peripheral registers as the second party) are unavailable on hosted OSes and wait for chunk 14.
(a) Yes: `region(L, atomic)` is application-lifetime and copyable, and holds only word-scalar atomic cells.
(b) No: atomics stay within one actor's owned region. (c) Remove atomics until chunk 14.
*Recommended (a), chosen* (§9.1). It is the only form in which atomics do anything, it keeps pointers into normal memory out of
shared cells, and it amends §12.1.6's "no cross-actor sharing" with one named exception.

**Q8. What is the atomic surface? — Decided by Lee, 2026-10-23: the recommended surface of §9.2.**
Chosen:  no `alloc_atomic` (`alloc_ref` into an atomic region); `read_ref`/`write_ref` on atomic refs mean
`:seq_cst`, which keeps the 62 trial files valid; four `atomic_*` builtins with literal atom orderings; tagged-tuple CAS
result (`(:ok, T) | (:fail, T)`); 64-bit cells on the ESP32-S3 take the runtime spinlock; the function-level barriers of `mem(atomic)` are removed once each operation carries its ordering. E2317 is an illegal order, E2315 a non-atomic ref. The alternative was spec §17 as written, with `alloc_atomic`, bare ordering identifiers and a record-tag CAS
result; spec §17 is updated.

**Q9. What does an out-of-bounds buffer access do? — Decided by Lee, 2026-10-23: (a); it covers the invalid buffer size and the list-index failure too, and (2026-10-22) region growth and raw allocation failure (H5) with `(:explicit, :region_alloc_failed)`.**
(a) End the actor (`(:explicit, :buf_bounds)`), handled by its supervisor, and abort 71 only in `main`. (b) A
process-wide abort 71, as today.
*Recommended (a), chosen*, per "crash to the supervisor". The access is still never performed, so no data is corrupted. It
applies to `L_buf_invalid` and to the list-index abort by the same reasoning, which is worth deciding together.

**Q10. How is lifetime polymorphism spelled? — Decided by Lee, 2026-10-23: (a).** Implicit per-signature quantification (§5 A): each call instantiates the callee's lifetime names consistently across the arguments and the result; a conflict is E2311; a lifetime that appears only in the result is fresh and returned with its region, else E2300. No `L: lifetime` value parameters and no bracket generics. Spec §4.4.1/§12.1.4's sentence is reworded.

**Q11. May a linear type instantiate a generic type parameter? — Decided by Lee, 2026-10-23: (a).** A linear (owned-region) type may not instantiate a generic type parameter, a list element type or a trait associated type: E2307 (LinearTypeArgument).
(a) No (E2307). (b) Yes, with a linear-aware generic checker. No stdlib or compiler code needs it. Reversible: (a) only rejects programs, so (b) may be added later without breaking any accepted program.

**Retired by decision 16 (2026-10-24; first recorded the same day as a revisit):** stack regions are not linear and nothing is linear, so Q11 and E2307 are retired. See [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) section 2A, section 7.4.

**Q15. How is `copy_to` spelled? (§18.7) — Decided by Lee, 2026-10-22: (a), a compiler builtin `copy_to(region, value)` derived per type like `recreate`; no copy for `device_window` or atomic cells.** (a) A compiler builtin `copy_to(region, value)`, derived per type
like `recreate`. (b) A derived trait method (a `Copyable` trait beside `Recreatable`), so a library type may refine
it. *Decided (a).* The builtin is the smaller change; the trait follows the FFI wrapper spec's `Recreatable` precedent and
lets a type reject the copy. Either way a `device_window` and an atomic cell have none.

**Retired by decision 34 (2026-10-24; first recorded the same day as a revisit):** evacuation and copy-on-send cover every case `copy_to` served; the compiler builtin is not added. See [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) section 2A, section 7.4.

**Q16 [amended 2026-10-24, see the full wording after this entry]. May a behaviour move a whole received region into its state? (§18.7) — Decided by Lee, 2026-10-22: (a), yes (the state owns it, no drop, O(1)).** (a) Yes: the state owns it, no drop, O(1).
(b) No: only `copy_to`. *Recommend (a)*: it keeps the move O(1) and is the same ownership transfer as the send. The cost
is that state may then hold a region that grows with each message, which is the program's choice.

**Amended by the chunk 15 direction (2026-10-24):** a kept part of a received message is evacuated from the mailbox buffer to the actor's stack base; the region is not moved into state. See [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) section 2A, decision 7.

**Q16 as amended (Lee, 2026-10-24, decision 7).** May a behaviour keep part of a received message in its state? Yes. The message waits in a per-message buffer attached to the mailbox entry; the behaviour reads it there during its dispatch; at dispatch end the buffer is released, and any part the behaviour keeps is evacuated to the base of the actor's stack, only the nodes in the buffer. The region is not moved into the state, and the earlier "O(1), no copy" no longer holds: a kept part costs the size of the kept nodes. `copy_to` is retired (decision 34). The 2026-10-22 wording above is the record.

**Q17. Who owns a region when a send fails? (§18.7) — Decided by Lee, 2026-10-22: (a), the runtime releases the region on a failed send; a sender that needs the data copies first.** (a) The runtime releases it on the failed send (the sender's use
is already E2301). (b) The sender keeps ownership on `actor_not_found`, which contradicts the static moved rule and
would make a region both moved and not moved after the call. *Recommend (a).* Lee chose (a).

**Applies to the mailbox buffer under the chunk 15 direction (2026-10-24):** a failed send releases the per-message buffer attached to the mailbox entry. See [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) section 2A, decision 7.

**Q18. Messages: copy by default, move on request. — Decided by Lee, 2026-10-23 (option C).** Supersedes Q6's default. Q6 stays above as history; the move machinery of §18 and §18.7 now serves explicit moves and the copy's own transfer.
- A send (`cast`, `send`, `call` message, reply, spawn state) COPIES its value by default, for data structures and owned regions. The sender keeps its data. A value the code explicitly marks for moving is transferred in O(1) and the sender may not use it afterwards. E2301 therefore applies to explicitly moved values only (and to function-call moves, which are unchanged: calls still move).
- The explicit move is spelled `move` (Lee, 2026-10-23, decided). The legacy `move` builtin (an old actor-migration alias; migration is `migrate_actor`) is being removed from the compiler, so there is no collision.
- **How the copy works (recommended, accepted as part of C):** the sender copies the message into a fresh owned region, and that region then moves to the receiver. The decided machinery applies unchanged: the dispatch-scoped message region dropped at behaviour return unless moved into state (§18.7, SD-7 work stays valid), Q16 move into state, Q17 failed-send release, the mailbox drain. Copying is type-directed: tree-shaped parts are walked with no bookkeeping; a per-message table (source node address to copy) is kept only where the type allows sharing. A raw owned region is copied by traversal from the message's typed roots, not by memcpy, because it holds internal pointers.
- **Sharing is preserved** across every value in one message, including two versions of a structure sent together (Lee: yes). One node in the source is one node in the copy, so the per-message table is required.
- **Evacuation** (return from a frame, copy into state at dispatch end, candidate D of the data structure redesign): the source frame is dying, so forwarding pointers may be written into it (no table), preserving sharing. Non-tail recursion would copy a returned version once per frame (quadratic); the direction is destination-passing (build directly where the result is kept, as region passing does) when the compiler sees the value flows to the return, evacuation otherwise. Lee's cleanup-on-pop rule is unchanged.
- **Later optimisation, only if measured to be needed:** in-place forwarding with an undo log (valid because the sender's data is private and the sender does the copy; needs a spare word or bit per node, which the boxed one-word-per-field record layout may not have; cannot write read-only constants).
- Consequences: the spec text of §18.5 and spec §12.1.6, §15.1.1, §16.3.5 and the other places that state "messages move" must be revisited (spec not edited in this pass). The `send_then_use_*` error trials of §18.6 apply to explicit `move` sends; plain sends need positive trials that the sender still uses its data. Requirements: [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) R4.

**Amended by the chunk 15 direction (2026-10-24):** copy by default stays. `move(x)` still copies the data to the receiver; it only means the sender may not use x afterwards (E2301), so the sender's frame releases it at once. There is no O(1) cross-actor transfer. The copy goes into a per-message buffer attached to the mailbox entry, released at dispatch end unless kept (kept part evacuated to the stack base). See [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) section 2A, decisions 6 and 7.

---

## 16. Work breakdown

Per [silica-fable-use-reduction](../../.claude/skills/silica-fable-use-reduction/SKILL.md): Fable writes compiler code in
`compiler/src` (checkers, SIR, emitters, the runtimes inside the emitter trees) and root-causes defects, checking with
quick incremental Mac builds and minimal repros only. Everything else goes to lesser models.

| # | Stage | Work | Model |
| --- | --- | --- | --- |
| 1 | 0 | hazard trials H1–H5 (sources, `.scout`), confirm each fails today | Opus (sources), Sonnet (runs) |
| 2 | 0 | atomic arena bump and CAS insert in four runtimes; moving prims in the interim heuristics; let-var aggregate promotion; null checks; E2100 → E2300 in `type_checker_memory_regions` | **Fable** |
| 3 | 0–8 | every full build (Mac, pix, nix, ESP32 cross), fixed-point runs, `make integrate`, board suites, golden refresh under the rules | Sonnet / Haiku |
| 4 | 1 | per-call lifetime substitution, E2311, removal of the binder fallback and `device_window` lifetime erasure | **Fable** |
| 5 | 1 | remove the `L1` workaround comments from trials; `generic_lifetime_name` and E2311 trials | Opus |
| 6 | 2 | (waits on chunk 15) `arena(L, S)` (Q1 a, Q2 a, decided 2026-10-22) through lexer/parser (if needed), interner, type checker, SIR, emitters, no cell ever freed; transition rule **[Superseded 2026-10-24: no type is introduced; this item becomes removing the family-arena field from the stdlib records and allocating in the frame (decision 13), waiting on the chunk 15 design.]** | **Fable** |
| 7 | 2 | (waits on chunk 15) stdlib and compiler-source rewrite script: exact-token rewrite of handle field types and allocator tuples only, verified with `git diff` per file, the count reconciled against §1.4's 2,239 | Opus (script), Sonnet (run and verify) **[Superseded 2026-10-24: no rename script (`region(L, normal)` to `arena(L, normal)` is not run); the work is the field removal of item 6.]** |
| 8 | 3 | `region_checker/` (ownership state, lifetime liveness, report mode, `silica.config` switch) **[Update 2026-10-24, decision 16: scope is lifetime liveness and isolation only; no ownership state, no ownership facts for SIR.]** | **Fable** |
| 9 | 3 | report collection over stdlib, compiler and `trials/`; triage into misuse vs checker defect | Sonnet |
| 10 | 4 | the Q18 language change (copy-on-send into a fresh owned region with the per-message sharing table, the `move(x)` marker, and the change of trial `actor_move_removed_unknown_function`); `drop_owned` placement in SIR; lowering in four emitters; removal of the heuristics and dead scope-release code; owner lists, transfer and actor-end walk in four runtimes (the walk covers the unprocessed mailbox, §18.7); per-target first-block size; dispatch-end drops for message regions, the partial-move rule, `copy_to` derivation, region release on a failed send and for a dead or timed-out caller (§18.7) | **Fable** **[Update 2026-10-24: read "fresh owned region", "owner lists, transfer", "the partial-move rule" and "`copy_to` derivation" per §18.7 as adapted: mailbox buffer, evacuation to the stack base, `drop_owned`, owner lists, transfer and the actor-end walk are dropped (decision 16); `copy_to` is retired (decision 34); mailbox buffers at actor end are released by the end-of-actor drain (decision 31).]** |
| 11 | 4 | positive copy-on-send and `move(x)` trials, release trials (write-every-page), `crashed_actor_regions_released`, `region_moved_between_actors`, and the message-region trials of §18.6 (§18.7; the timed-out-call trial waits on chunk 11) | Opus **[Update 2026-10-24: trials follow §18.6 as revised.]** |
| 12 | 5 | switch to errors, with E2301 and E2303 narrowed to explicit `move(...)` and call moves (Q18); E2300–E2318 messages and metadata; `error_codes.md` and `.jsonld` entries | **Fable** (code); Sonnet (registry text) **[Update 2026-10-24, decision 16: only the codes that stay (§10) are switched on; E2303 to E2309 and E2312 are retired; E2301 stays as a lifetime error (decision 22).]** |
| 13 | 5 | the §14.1 error catalogue, goldens re-derived from real output | Opus (sources), Sonnet (goldens) **[Update 2026-10-24: rows for retired codes are not written (§14.1 note).]** |
| 14 | 7 | atomic builtins in the checkers and SIR; lowering in four emitters; ESP32 64-bit spinlock path; removal of the function-level barriers | **Fable** |
| 15 | 7 | atomic run and error trials, two-core board runs (console-only) | Opus / Sonnet |
| 16 | 8 | actor-failure outcome for bounds, invalid size, list index and region allocation failure; E2313/E2314; `\|bounds:` removed (done) | **Fable** |
| 17 | all | spec text: §4.4.1–§4.4.2, §12.1.2–§12.1.6, §12.3.3, §12.4, §16.3.5, §17 rewrite, arenas (S7), per decisions; `region_memory_safety_todo.md` closed with a pointer here; ROADMAP status | main session or Sonnet **[Update 2026-10-24: "arenas (S7)" is dropped with Q1.]** |

Fable's estimated scope, by size: the region checker (8) and drops and owner lists (10) are
the large items; 2, 4, 6, 12, 14 and 16 are each a few modules across four emitters.

## 17. Structure storage: record of the options (Q2)

Lee's concern (2026-10-09): a never-freed arena only grows. Measured against the code:

- A `wbt_map` update path-copies about one node per level. The node is `alloc_rec(arena, (key, value, size, left,
  right))` (`wbt_map.silica:180`): five boxed words, 40 B. Bump allocation adds no header.
- The height of a weight-balanced tree is about 1.2·log₂ n typically and at most about 2·log₂ n. So an update to a
  1,000-key map leaves about 12 × 40 = 480 B of unreachable nodes in the arena.
- On the board (354,816 B of heap) that exhausts the heap after about 740 updates: 74 seconds at ten updates a second.
- On a host, a server doing 100,000 updates a second grows by about 48 MB/s, about 170 GB an hour.
- Constructor sites, `canonical_arena_lookup` and the destroy path never free an arena block (§1.2).

The arena is safe (leaks are not a §12 safety violation) but unusable for a long-running program that keeps updating a
structure, and on the board it fails within minutes.

**Options considered.** (a) the never-freed family arena; (b) counted regions, one small region per node with a count of
the versions and nodes that reach it; (c) (b) by default plus an immortal constructor per family; (d) per-actor arenas
freed at actor end; (e) one owned region per structure with an explicit `compact`.

**[Superseded 2026-10-24 by the chunk 15 direction: the family arena is removed and structures live on the actors' stacks (requirements §2A). The measurements above and the options stay as the record; the paragraph below is the 2026-10-22 choice.]** **Chosen by Lee, 2026-10-22: Q2 (a), the never-freed family arena with the atomic bump of stage 0, handle `arena(L, S)`
(Q1 a), subject to chunk 15's redesign of structure storage (§0 note).** Counted storage (b, c) is not part of this plan. Its design (per-node counts, biased counting across actors,
a per-actor size-class allocator, counted list chunks, benchmarks and migration estimates) was in revisions 1.1 to 1.8 of
this document and was removed in 1.9; version control holds it if the project is reopened. What stays true:
- structures never reclaim memory until a later project, and the figures above are the cost;
- H1's atomic arena bump is permanent, not interim;
- H4 needed its targeted stage 0 fix (implemented on the Mac);
- sends of structures copy by default and move only on request (Q18, §18); the handle pass is the current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md).

## 18. Messages and escaping values on the actors' stacks (Q18; rewritten 2026-10-24 for the chunk 15 direction)

**Status of this section.** Rewritten on 2026-10-24 for the chunk 15 direction (Lee, [data_structure_redesign_requirements.md](data_structure_redesign_requirements.md) §2A, decisions 1 to 13; later passes the same day added decisions 14 to 37, applied in place). What follows describes the **direction**, not the runtime. Wherever the runtime differs, the text says **today:** plainly. Every question of requirements §7.4 is now answered; what the decisions leave to the design is requirements §7.5. The text that held before 2026-10-24 and no longer holds is kept verbatim in §18.H; text that still holds is carried into the subsections below, adapted. Subsection numbers 18.1 to 18.7 are unchanged so that references from elsewhere in this document stay valid.

**History.** Lee decided on 2026-10-09 that a message carrying a data structure is a **move** (Q6). Q18 (2026-10-23, requirements R4) made a plain send a **copy**, with sharing inside the message preserved, and kept the explicit `move`. On 2026-10-24 (decision 6) the explicit `move` was changed too: it **still copies** the data to the receiver; it only ends the sender's use of the value. There is no O(1) cross-actor transfer of memory. The specification conflict S1 resolved toward §12.1.6 (move) on 2026-10-09; since Q18 and decision 6 messages copy, so §16.3.5's "copied" is now the nearer wording and §12.1.6 is the text to change (§18.5).

**The memory model of the direction in one paragraph.** Working values are built in stack frames. A value that escapes its frame is built by destination-passing where the compiler sees it flow to the return, and otherwise evacuated, on return, from the frame being popped (§19). An actor's state lives at the base of its stack (§18.8). A message is copied by the sender into a buffer attached to the mailbox entry; the behaviour reads it there; the buffer is released at dispatch end unless a part is kept, and a kept part is evacuated to the stack base (§18.7). Reclamation is deterministic and compile-time decided; nothing resembles a garbage collector (decision 4). `region(L, S)` means a lifetime-scoped area of the actor's stack in memory space S (decision 12); structures carry no region field (decision 13). **Today:** escaping values go to a per-actor implicit heap (`_silica_rt_region_alloc`, a chain of 64 MB blocks released when the actor ends); standard structures allocate from process-shared family arenas that are never freed; actor state is not at the stack base (not verified where it lives). The inventory of what must be replaced is requirements §8.2 and §8.3.

### 18.1 The rule at the language level

A value given to any actor-boundary operand is **copied** to the receiver. If the code marks it `move(x)`, it is copied as well, and the sender may not use `x` afterwards (E2301), so the sender's frame can release it at once (decision 6). The operands:
- a `cast`, `send` or `call` message, and the `_registered` and `_dangerous` forms;
- a behaviour's reply and its new state;
- a `spawn` initial state.

Where the copy goes: a `cast`, `send` or `call` message into a buffer attached to the mailbox entry (§18.7); a reply straight into the blocked caller's stack (decision 33); a `spawn` initial state into the new actor's stack base (decision 15). For the classes of §3.1 this means:

| Class of the value | After the send |
| --- | --- |
| `device_window`, and aggregates embedding one | not copyable: no copy exists (Q15's no-copy rule, kept although `copy_to` is retired; `device_window` stays outside the stack, decision 8, and keeps one owner, decision 24). A send of one is a compile error as before. |
| stack regions (`region(L, S)`, lifetime-scoped stack areas, decision 12) and aggregates embedding them | a plain send copies the value into the message buffer and the sender keeps its original; after an explicit `move`, E2301 on any later use (§3.8). A stack region is sent like any value: copied into the message buffer (decision 34). `region(L, atomic)` is shared by reference between actors under Q7 and is not copied. |
| structures (and records, tuples and lists holding them) | a plain send copies the structure into the message buffer, type-directed, sharing inside the message preserved (R4.2); the sender keeps using its own. An explicit `move` copies too and the sender gives it up (E2301). **Today:** the receiver gets a copy of the `arena(L, S)` handle over never-freed nodes; `term_message_copy.silica` does not yet copy a structure's nodes (see §18.3). |
| plain values (scalars, atoms, strings, actor references, records/tuples/lists of those) | usable. They are immutable, so a move and a copy cannot be told apart. They are copied into the message buffer with the rest of the message. **Today:** the copy out of the replier's arena is the targeted stage 0 fix for H4. Strings built at run time are ordinary escaping values (decision 29: exact-length allocation in the current frame; evacuated on return; copied to the base when kept; literals stay in read-only data). |

**No use after an explicit move (Lee, 2026-10-22; narrowed to explicit moves by Q18, 2026-10-23; meaning changed by decision 6, 2026-10-24).** It is a compile error, **E2301**, for the sender to do any work with a value after it has been sent by an explicit `move`. "Work" is any use: read, write, pass to a call, return, store in state, send again. The rule holds for the value by itself **and** for the value contained in anything else (a record, tuple, list, closure or any aggregate embedding it), and it holds however the value is reached afterwards: through a name bound to the aggregate, through a field read from it, or through a copy of the handle. It applies to every actor-boundary operand of this section, not only `cast`, `send` and `call`: a **reply** and a **spawn initial state** (and a behaviour's new state, once it has been moved out) are sends in the same sense. The error trials are in §18.6 (`send_then_use_*`). Under the direction the rule no longer protects a transferred owner (nothing is transferred); it lets the sender's frame release the value at once, and it keeps programs from relying on a value the compiler may have released.

The lifetime of a message in the receiver, and how a receiver keeps data past the dispatch, are in §18.7 (Lee, 2026-10-22, adapted 2026-10-24): the message buffer is dispatch-scoped, and keeping anything is explicit.

**Structures (Q18, 2026-10-23).** A send, a reply and a spawn state COPY a structure by default (sharing inside the message preserved) and the sender keeps its own; only an explicit `move(...)` gives it up. Only a change makes a version (§3.14). Keeping a version in the state and also replying with it or sending it is legal (the reply carries a copy), so E2303 does not apply (Q12 is withdrawn); E2303 applies to a value that is both kept and given away by an explicit `move(...)`, whose second use would be a second owner. **[2026-10-24: E2303 is retired (decision 16, §10); this sentence is the record.]** Under decision 13 a structure is its root reference and carries no region field; the examples below are written that way. **Today:** state records still hold `region: arena(L, normal)`, and updaters allocate through it.

```silica
fn beh(msg: int64, state: { root: ref?(L, normal, (K, V, int64, ref?(L, normal, rec), ref?(L, normal, rec))), … })
    -> (:reply, :unchanged | (:inserted, { … }) | (:replaced, { … }),
                { root: ref?(L, normal, (K, V, int64, ref?(L, normal, rec), ref?(L, normal, rec))), … }) {
    sequence proc[mem(normal)]
        r: :unchanged | (:inserted, { … }) | (:replaced, { … }) <- wbt_map@insert(state, msg, 0);
    produces
        pure (:reply, r, state)          // legal: reply with the change result, keep v1 = state
    end
}
```

```silica
        pure (:reply, state, state)      // legal (the reply carries a copy); E2303 only if the reply were an explicit `move(state)` while the state also kept it
```

### 18.2 Shared nodes inside one actor, and across actors

Within one actor, nodes of a structure version are immutable, and versions share nodes: an update builds new nodes in the current frame (or at the destination, §19) and refers to the unchanged older nodes, which sit in an older frame or at the stack base. Old nodes never point to new ones. Nothing is counted. Across actors nothing is shared: a send copies (§18.7), so one actor never holds another's nodes (nothing in a message is shared with the sender, decision 38; lists are copied too, decision 30, 2026-10-24: the copier gains a List kind and the slice-1 sharing ends). The one exception is `region(L, atomic)` (Q7), shared between actors by design.

**Today:** nodes of a structure version live in a never-freed family arena and are immutable, so any number of actors may hold versions that share nodes, with nothing to count and nothing to free. The only shared mutable state is the arena's bump pointer and insert table, which stage 0 makes atomic (H1). No shared mutable allocator state remains at the language level under the direction (decision 37).

### 18.3 Structures under a copy or a move

Under the direction a plain send copies the structure into the message buffer, O(size of the structure), type-directed and with sharing preserved. An explicit `move` copies as well and so costs the same; it differs only in that the sender gives the value up (decision 6). There is no O(1) path.

**Today:** a send of a structure is a handle pass, O(1), because the nodes sit in a family arena the receiver can also read (`term_message_copy.silica` states the interim limit: structure handles pass as today and their nodes are not copied; chunk 15, candidate D, slice 2). Two actors on different cores may derive versions from one lineage concurrently, both allocating from the family arena with the atomic bump.

### 18.4 Calls, replies, state, spawn and supervised restart

"Copied" below means the copy made into the message buffer (§18.7), except that a reply goes straight into the blocked caller's stack (decision 33) and a spawn state into the new actor's stack base (decision 15). An explicit `move` copies too; it adds E2301 for the sender and lets its frame release the value at once.

| Operand | Semantics | Checker |
| --- | --- | --- |
| `cast(a, m)`, `send(a, m)` | `m` is copied into a buffer attached to the mailbox entry (structures copied with sharing preserved); with an explicit `move(m)` it is copied too and the sender may not use `m` | later use of an explicitly moved `m` is E2301 |
| `call(a, m)` argument | as `cast` | as `cast` |
| `call` reply `(:reply, r, s)` | `r` is copied by the replier straight into the blocked caller's stack, just below the caller's parked SP (decision 33, 2026-10-24); it lives in the caller's frame as the call's result and pops with it; one copy, no reply buffer; a late reply after the caller stopped waiting (the future `call_with_timeout`) is dropped under the call record's lock | E2303 is retired (decision 16); the reply is a copy and both `r` and `s` may hold the structure |
| behaviour new state `s` | stays in the actor. At dispatch end the nodes built during the dispatch are evacuated to the stack base (§18.8); no walk of the older state | the state's parts must each end in exactly one of reply, new state, a send, or release at the frame pop |
| `spawn(st, beh, policy)` | `st` is copied into the new actor's stack base at spawn (decision 15, 2026-10-24: copied by the spawner into the new actor's stack base before its first dispatch, the same as a supervised child, decision 11); an explicit `move(st)` copies too | later use of an explicitly moved `st` is E2301 (replaces `"moved_region"`) |
| values in a `cast`/`send`/`call` message or a reply | **dispatch-scoped** in the receiver (a `cast`/`send`/`call` message; a reply is not a buffer, see the `call` reply row): the buffer is released at dispatch end unless a part is kept, and a kept part is evacuated to the stack base (§18.7). Failure paths (dead receiver, crashed receiver with queued messages) release the buffer in the runtime (the end-of-actor drain, decision 31); a late reply or a reply to a dead caller is dropped under the call record's lock (decision 33) | E2301 for the sender's later use after an explicit `move`; a lifetime error for a reference into the message buffer stored into state without being kept (§18.7 item 3) |
| supervised child spec initial state | a structure may be in it (Q14, confirmed in stack form, decision 11): the spec holds the original, each start or restart copies it into the new child's stack base (cost proportional to its size per start), and the child's death releases it with the stack. An owned region may not be in it (E2308): the supervisor's row keeps the initial state to restart the child. E2308 is retired now that regions are not linear and the spec is copied (decision 23) | E2308 is retired (decision 23). The `init` code that builds the spec copies its values into the spec; a later use after an explicit `move` is E2301. |

### 18.5 Specification text to change (not edited here)

The wording proposed in the first rows below is the Q6 wording; Q18 (2026-10-23) changes it to "copied by default, moved only by an explicit `move`", and decision 6 (2026-10-24) adds that the explicit `move` copies too, when the specification is edited.

| Section | Change |
| --- | --- |
| §16.3.5 "Isolation: Message contents are copied between actors" | "Message contents are copied into a buffer the receiver reads. A value marked `move` is copied as well, and the sender may not use it afterwards (E2301). Immutable plain values are indistinguishable from copies." (Replaces the Q6 wording "Message contents are moved ... owned regions change owner", which no longer holds.) |
| §12.1.6 | extend from regions to data structures: a structure is copied on `call`, `cast`, `send` and reply (sharing inside the message preserved); `move` ends the sender's use and the data is still copied; the storage and release of its nodes follow the actors' stacks (requirements §2A) |
| §12.1.5, §15.1.1 "Region handles in initial state" | structures in a spawn initial state are copied by the spawner into the new actor's stack base before its first dispatch (decision 15); an explicit `move` copies too |
| §15.4 child specs (`initial_state` in rows, §15.4.12) | a supervised child's initial state is copied into the child's stack base at each start (decisions 11, 15); the E2308 restriction on owned regions is not added (E2308 retired, decision 23); a structure may be in it (Q14) |
| §16.3.5 "Immutability" | unchanged; add that a message is copied into a buffer the receiver reads during the dispatch |
| §15.1.1 "State Semantics" and §12.1.6 replies | under copy-by-default a value in both the new state and a reply or message is not an error; the E2303 restriction proposed here is retired (decision 16) |
| common_contract.md §6–§7 | a change borrows its input version and returns `:unchanged` or a tagged new version (§6's "a no-op may return the identical root" and its flags give way to the result sums of §3.14); a structure sent to another actor is a copy (Q18), and both actors may keep using their own; a structure carries no region field (decision 13) |

### 18.6 Trials for moves

Under the direction `move` copies, so the trial names below that say "moved" keep their names; where a trial's mechanism is superseded it says so and the old description is in §18.H.

**Error trials** (added to §14.1's catalogue):

| Code | Case |
| --- | --- |
| E2303 **(retired, decision 16: not to be written; row kept as the record)** | (with the reply, message or state an explicit `move(...)`; a plain send is legal) a value kept in the new state and also replied; kept and sent through `cast`; kept and sent through `call`'s argument; kept and replied inside a record; `cast(a, (r, r))` |
| E2301 (no use after an explicit `move` send, §18.1, **not written**; plain sends need positive trials that the sender still uses its data) | `send_then_use_bare_region`; `send_then_use_region_in_record`; `send_then_use_region_in_tuple`; `send_then_use_region_in_list_element`; `send_then_use_via_field_read` (a field read from the aggregate after the send); `send_then_use_via_name_alias` and `send_then_use_via_handle_copy` (a copy of the handle); `send_then_use_region_in_closure`; `send_then_use_in_later_case_branch` (sent in one arm or before the `case`, used in a later branch); `send_then_use_in_loop` and `send_then_use_in_recursion` (sent in an iteration, used in the next, or by the recursive call). Each is repeated for `cast`, `send`, `call`, a reply and a spawn state, and for each of read, write, pass to a call, return, store in state and send again |
| E2308 | child spec whose initial state holds an owned region (retired, decision 23: not to be written) |

**Run trials:**

| Trial | Shows |
| --- | --- |
| `move_reply_version` | `call` returning a version built in the callee; the caller keeps using it after the callee ends (H4 for structures; the targeted stage 0 fix) |
| `move_map_of_sets` | a `graph_wbt` adjacency version sent; the receiver and the sender both query it |
| `supervised_child_restarts_with_version` | a child whose initial state holds a map version crashes and restarts 1,000 times (Q14); every start receives a copy with the same contents, released with that child's stack when it dies |
| `reply_and_keep_same_version` | a server keeps v1 in its state and replies with the same version on every call, 10⁴ calls; the caller and the server both validate it |
| `move_two_cores` (board) | **superseded 2026-10-24** (it assumed two cores deriving versions from one lineage in one family arena with the atomic bump); see §18.H. A replacement that shows two cores each copying a version across actors for 10⁵ rounds is not written. |
| `message_region_released_at_dispatch_end` | **not written** (§18.7; write-every-page, the SD-7 shape). A receiver is cast 100,000 messages, each holding several pages of data, and writes every page; it keeps nothing. RSS stays flat. Fails today (SD-7). Under the direction the buffer is the mailbox buffer. |
| `message_part_kept_evacuated_to_stack_base` | **not written** (§18.7). The behaviour keeps a part of the message in its new state; the part is evacuated to the stack base at dispatch end, it is intact in the next dispatch, and a 100,000-message run keeps memory bounded by the state. (Replaces `message_region_moved_into_state_not_dropped` and `copy_to_rebuilds_in_state_region`, see §18.H.) |
| `crashed_actor_queued_message_regions_released` | **not written** (§18.7, H9). Messages are queued to a worker that faults on its first dispatch; the supervisor restarts it 1,000 times. The buffers of the unprocessed mailbox are released with the actor; memory growth is bounded. Fails today. |
| `send_to_dead_actor_releases_region` | **not written** (§18.7). A `cast`, a `send` and a `call` to a removed actor return `actor_not_found`; the runtime releases the message buffer (Q17); a sender that used an explicit `move` may not use the value (E2301); 100,000 repetitions, RSS flat. |
| `timed_out_call_late_reply_region_released` | **not written; blocked on chunk 11** (`call_with_timeout` is not started). A call times out; the callee's later reply is dropped under the call record's lock (decision 33), with nothing allocated in the caller's stack. |
| `caller_dies_reply_region_dropped` | **not written** (§18.7). A caller is removed while awaiting a reply; the callee replies; the reply is dropped under the call record's lock (decision 33), nothing is leaked and nothing is released twice. |

`partial_move_of_region_out_of_message_record` (old §18.7 item 5) is **retired** under the direction (decision 16); see §18.7 item 5 and §18.H.

**Error trials** (added by §18.7, **not written**): the lifetime error for a reference into the message buffer stored into state typed with the state's lifetime without being kept (§18.7 item 3); `copy_to_rejected_for_device_window_and_atomic` is not needed (`copy_to` is retired, decision 34); the sender's later use of a value after an explicit `move` send is E2301, also when the send fails at run time.

### 18.7 Dispatch-scoped message buffers and keeping data (Lee, 2026-10-22; adapted 2026-10-24)

**Decision.** A message is **copied on send** into a buffer attached to the mailbox entry (the R4.1 machinery, the fresh region renamed a mailbox buffer, decision 7). The behaviour reads it there during its dispatch. The buffer is **dispatch-scoped**: released at dispatch end unless a part is kept; a kept part is evacuated to the actor's stack base (Q16, amended). Keeping anything past the dispatch is explicit. This fixes BEES's SD-7 (data received in a message is never freed while the actor lives) without later reclamation. **Today:** the sender copies into a fresh owned region (`alloc_region`'s shape) that moves to the receiver, and the dispatch-scoped release destroys the message record's region fields at behaviour return (`term_message_regions`); there is no mailbox buffer and no stack base.

**1. Copy on send.** The copy is type-directed and runs in one module-local helper in `term_message_copy.silica` (`L_mc_root`), interpreting a descriptor the module emits from the message's type string. **Carried over unchanged:**
- The descriptor lists the words of the aggregate and one entry per word, by kind: WORD (scalars, atoms, strings, actor references, function values, type parameters, copied as is), REGION (an owned region handle replaced by the fresh region it maps to; today's mapping, under the direction a region is an area in the current frame, sent as a copy, decision 34), REF1 (ref to a one-word cell), REFTUP (ref to an `alloc_rec` cell; `rec` is bound to its innermost enclosing tuple type, Q19, so the entry points back at that tuple's descriptor), AGG (pointer to a record or tuple), SUM (a sum value matched against its first word) and BUF (a buffer, length word before the elements).
- Tree-shaped parts (records, tuples, sums, buffers) are walked with no bookkeeping. Where the type allows one value to be reached twice (refs, and region handles), one per-message table (source address to copy) makes one source node one copy node across every value in the message, so two versions of a structure sent together still share their nodes (R4.2).
- A ref whose cell can hold a ref to itself (`write_ref`) is entered in the table before its content is copied.
- The unbound-`rec` limit is closed by decision 38 (2026-10-24): nothing in a message is shared with the sender. A `ref?(L, normal, rec)` with no enclosing tuple cannot reach a send once Q19 is enforced (unbound `rec` is E2010 everywhere), so every reference in a message has a known layout and is copied. **Today:** until Q19 is enforced in the compiler the copier still shares unbound refs with the sender (KIND 0, WORD); the implementation must close this (requirements §7.5 item 11).
- **Last-use elision.** `fn_copy_markers` finds the sends and spawns whose operand is a last use (nothing evaluated afterwards mentions the operand's data or an alias, by a taint closure over the lets in both directions, and the operand is not a parameter) and marks them `|_mvs=<node>,`; those hand over the original as a `move` did before Q18, unobservable to the sender. A reply is copied only when a reply site needs it (`|_mvr=1` marks the elided function): its data is a parameter's, or is also in the new state. **Under the direction** this elision needs a new basis, because a transfer of the original no longer exists (decision 6): decision 32 (2026-10-24) gives it: last-use elision is forwarding only. If the value sent on is wholly a received message's buffer (or a part that owns its own buffer), that buffer is handed on in O(1) without copying; every other send copies. The `|_mvs`/`|_mvr` markers are reinterpreted that way.
- **Slice-1 limits today:** a List is shared with the sender, not copied (KIND 0; ends under decision 30: the copier gains a List kind); a structure's handle is passed and its nodes are not copied; the pre-map pass maps region words to fresh regions and a handle the canonical arena table holds is not mapped.

An explicit `move(x)` marks the send prim's value `|mv` (or wraps a reply element in a kind-6 prim `move`). Under decision 6 it copies, and the sender's later use is E2301.

**2. Dispatch scope.** The receiver reads the message buffer for the length of that behaviour call. At dispatch end the buffer is released, except for parts the behaviour kept (item 3). No runtime test and no reference counting are involved; this is the static ownership rule of §3.8 **[retired as a linear rule by decision 16, 2026-10-24; the buffer's release at dispatch end is the default]** ("each part of `msg` must be in the reply, in the new state, moved elsewhere, or dropped") with the release made the default for a message part that goes nowhere. **Today:** the checker places no `drop_owned` (no `drop` nodes exist, §1); the release is the emitters' dispatch-end destroy of region fields. How a buffer interacts with `stack_policy`: the policies measure from the state edge (decision 27), and a mailbox buffer is not part of the stack or the state area (its release at dispatch end is §18.7 item 2); any remaining interaction is for the detailed design.

**3. Keeping data past the dispatch.** Explicit. The part to keep is **evacuated to the stack base** at dispatch end, only the nodes in the buffer (older kept nodes are left alone). Sharing is preserved, with forwarding as for returns (§19). The earlier two ways are changed:
- (a) *Move the whole region into the new state*: **superseded** (Q16 amended, decision 7); the buffer is not handed to the state, the kept part is copied out of it. Old text in §18.H.
- (b) *`copy_to(state_region, value)`*: **retired** (decision 34), since there is no state region to name once state is the stack base.

A reference into the message buffer stored into state without being kept is the **existing lifetime error** (§4); no new code is needed for it (the lifetime codes E2300 and E2302 stay, decision 16). Under Q18 a plain send copies and the sender keeps its data; a sender that explicitly moves and still wants the data keeps a copy of it before the move (a visible O(n)).

**4. By value class.**

| Class of the message part | Send | Keep past the dispatch |
| --- | --- | --- |
| stack region, or an aggregate embedding one | copy into the message buffer (Q18); an explicit `move` copies too | evacuate the kept part to the stack base (a region as such is copied to the base like any value, decision 34) |
| structure | copy into the message buffer, sharing preserved; an explicit `move` copies too (**today:** handle pass by value, §18.3) | evacuate the kept nodes to the stack base; older kept nodes are left alone |
| plain scalars, atoms, strings | copy (§18.1) | already a copy |

**5. Partial move.** **Retired (decision 16, 2026-10-24: a partial move out of an aggregate is a linear-ownership rule and is dropped; kept data is evacuated, item 3). Earlier status, Open:** The old text defined a partial move: a message `{ r: region, root: ref? }` is received, the behaviour pulls the region `r` out and moves it into the state, and a `ref` whose lifetime is `r`'s cannot be used afterwards (E2301). That rule assumed a region that moves into state, which the direction replaces by evacuation. What remained of it depended on §7.4 items 12, 16 and 17, all now answered (decisions 34 and 16): nothing remains. The old text is in §18.H.

**6. Cross-core receivers.** The receiver releases the buffer; it does not need the sender's thread. **Today:** on the hosts the receiver's drop is the plain region destroy of a whole `alloc_region` block chain; the board heap is one heap under the scheduler lock (§7.3) and is not checked by this section.

**7. Failure paths.** These were not covered by the earlier design. All belong to stage 4 (§13, §16 item 10) and have trials in §18.6.
- **(i) Mailbox drain at actor end.** The buffers of the actor's **unprocessed mailbox** must be released when the actor ends, as well as its stack (which an actor's end releases whole). Owner lists are dropped (decision 16, Q5 superseded), so how the pending mailbox buffers are released, which hang off mailbox entries and not the stack, is the end-of-actor drain (decision 31): the runtime walks the mailbox queue once and frees each pending buffer, O(pending), with no owner list. **Today:** a crashed actor leaks them (H9), and the transfer links the region into the receiver's list at submission (§7.3), which already puts a queued message's regions on the list. Trial `crashed_actor_queued_message_regions_released`.
- **(ii) Failed send.** A `cast`, `send` or `call` to a dead actor returns `actor_not_found`. The runtime releases the message buffer on the failed send (Q17, decided (a), 2026-10-22; applies to the buffer under decision 7). A sender that used an explicit `move` cannot use the value (E2301 is static and cannot know the send failed), so keeping ownership with the sender on failure would contradict the static rule.
- **(iii) A timed-out call.** Under `call_with_timeout` (chunk 11, not started) the late reply is dropped under the call record's lock (decision 33; it was never in a buffer). The trial is blocked on chunk 11.
- **(iv) The caller dies awaiting a reply.** A reply delivered to a dead caller is dropped under the call record's lock (decision 33); there is no reply buffer to release.
- **(v) A worker dies holding the only copy.** Nothing is recovered: data received and not yet kept dies with the worker. Under Q18 a plain send already copies, so the sender keeps its own data, as in BEAM. A sender that sent with an explicit `move` and needs the data to survive the receiver's crash must keep a copy before the move. Documented here and in the language guide, not enforced.

**8. What this changes in the plan.**
- There is no counting of any kind and no family arena: structures live on the actors' stacks (requirements §2A). Q2 (a) is superseded.
- It **closes H4 for plain values** (they are copied, §18.1) and **SD-22 and SD-7** (released at dispatch end). SD-22 is H2's stage-0 fix plus the release; SD-7 needs this section and stage 4.
- Stage 2 is now the removal of the family-arena field from the stdlib records (decision 13); it no longer introduces a type.
- Stages 2 to 5 are still required for S-15 (memory release inside a living actor): the checker and the release placement are what place the dispatch-end release **[2026-10-24, decision 16: `drop_owned` is dropped; the release is the buffer release at dispatch end and the frame pop, not an ownership drop]**. Because safety now rests on lifetimes, not linearity, the stage 1 lifetime polymorphism and the stage 3 region checker carry more weight (decision 16, 2026-10-24: the checker enforces lifetimes and isolation only; §7.4 items 16 and 17 answered).

**9. Inconsistencies found in the earlier text (to reconcile at implementation).**
- The `behaviour new state` row of §18.4 said the state "stays in the actor: no transfer, no walk". The same behaviour also releases the message buffer at return; the sentence applies to the state alone.
- §14.2 `region_moved_between_actors` says the region is "released once, at the receiver's end". Under this section the buffer is released at the end of the receiving dispatch unless a part was kept. The trial's expectation must be adjusted when it is written.
- §3.8 describes the behaviour's message parameter as owned and requires each part to end in "the reply, the new state, moved elsewhere, or dropped"; it does not say that the release is placed by the checker by default. This section says it is.
- The §18.1 row for plain values: with release at dispatch end, a plain value inside a message that also holds other data is copied with the message and remains usable in the state only if it does not borrow the buffer (see item 3).

### 18.8 Actor state at the stack base, and release (decisions 3 and 4; direction, nothing implemented)

- **Place.** The actor's state lives at the base of its stack, an area the `stack_policy` release algorithms never pop. At dispatch end the new state is evacuated into it: only the nodes built during the dispatch, older nodes left alone (immutable structures never point from old nodes to new). **Today:** where actor state lives is not verified; the stack release algorithms pop down to what they retain (`prims_actors_stack_asm.silica`). How the base area grows when a dispatch ends with more state than before is decision 14 (below); the release algorithms are exempted by decision 27 (2026-10-24): the state area's edge is one word in the actor control block, every `stack_policy` release algorithm measures from it instead of the stack base, keeping its behaviour, and the state area is never decommitted while the actor lives.
- **Deterministic reclamation.** Nothing resembles garbage collection: no thresholds, no sweeps, nothing done "every so often". The dead nodes of old state versions at the stack base are released by **compiler-proven release**: where the compiler proves the old state is dead after the update (its last use, no other live version), the nodes the update replaced are released at once, at a cost proportional to the nodes replaced. Where it cannot prove that, the fallback is to copy the live state into a fresh base area at dispatch end and release the old base area whole, at a cost proportional to the state size. Which path is taken is decided at compile time, not at run time.
- **Growth downward (decision 14, 2026-10-24).** The stack grows down from its base and the state area is at the base. During a dispatch the state area neither moves nor grows: an update builds new nodes in the current frames, pointing up into older state nodes, so every pointer from a frame into state stays valid (a call waiting for its reply keeps its frames, so no evacuation happens before the behaviour returns). The state area grows only at dispatch end, when every frame has been popped, by extending downward into the freed frame space, so no live frame is invalidated. The reservation (machine memory plus swap) bounds it as it bounds deep recursion (decision 26: no new limit; at the limit the actor ends with `(:explicit, :stack_exhausted)`). The `stack_policy` release algorithms decommit only below the state area's current (moving) edge. A separate per-actor state reservation was offered and not chosen.

```
 high addresses   +----------------------+  <- stack base
                  | actor state          |  never popped; fixed during a dispatch
                  |  (older nodes)       |
 state edge   --> +----------------------+  <- moves down at dispatch end only
                  | frame of behaviour   |  new state nodes are built here,
                  | frame of callee ...  |  pointing up into the state area
                  |        (grows down)  |
                  +----------------------+  <- stack pointer
                  | free reservation     |  decommit by stack_policy only below
 low addresses    +----------------------+     the state edge
```

  Two consequences are **answered (2026-10-24)**: the evacuation overlap, since at dispatch end the new nodes sit in the frames directly below the edge where the area must extend, is handled by decision 20 (copy the new nodes reachable from the new state to scratch space below the deepest point the dispatch reached, leaving forwarding pointers in the dead source nodes; then copy the contiguous block up to the edge, or into holes, adjusting pointers by a constant offset: two copies of the new nodes, never the whole state; sliding in place was not chosen); and the holes left by compiler-proven release are handled by decision 21 (one exact-size free list per node size; evacuated nodes fill an exact-size hole first and extend the edge only when none is free; allocate and free are O(1); live nodes never move; waste is holes of sizes no longer used, compacted whenever the fallback copy runs; compaction after release was not chosen). The fallback copy's destination (decision 28, 2026-10-24) is the same scratch technique applied to the whole state: copy the live state into scratch below the dispatch's deepest point, then copy it back to the base with one constant pointer offset, releasing the old base area in place; two copies of the state, peak memory about twice the state while copying; the decision 19 note names the behaviours that pay it.
- **Compiler-proven release (decision 18, answers §7.4 item 1).** At dispatch end exactly one thing is live, the new state (sends and replies were copied; frames are gone), so "no other live version" is checked within the behaviour only. A per-behaviour use analysis, decided at compile time, proves that the old state and any structure read out of it flow only into updates (not also kept in the new state, captured, or returned another way). Where proven, each update appends the state-area nodes it replaced (its path-copied nodes) to a per-dispatch release log, freed at dispatch end at a cost proportional to the nodes replaced. One kept alias anywhere means no proof, and that behaviour uses the fallback.
- **The fallback is reported (decision 19, answers §7.4 item 8).** Where a behaviour cannot be proven, every dispatch end copies its whole live state (cost proportional to state size). The compiler emits a note naming the behaviour and the alias that blocked the proof; a strict mode turns the note into an error. Code numbers and the strict-mode spelling are for the detailed design.
- **Sizing (decision 26, answers §7.4 item 6).** State and structures count against the actor's existing stack reservation (machine memory plus swap, lowerable per spawn; the board memory budget for the chunk chain on the ESP32-S3). No new limit. Hitting the limit during an allocation or evacuation ends the actor with `(:explicit, :stack_exhausted)` under Q9; its supervisor decides.
- **Open:** the analysis itself (its exact rules, for the detailed design).

### 18.9 Memory outside ordinary stack frames (decisions 8, 9, 10, 11, 12)

- **Reads of an inner structure (Q13 withdrawn).** `get`, and any read of an inner structure, returns the stored inner structure itself with no copy. It is immutable and sits in an older frame or at the stack base; if it ends up in new state, evacuation leaves already-kept nodes alone. (The earlier text that copied on read is in §15 Q13 and requirements Q13, marked withdrawn.)
- **Supervised children (Q14).** See the last row of §18.4.
- **Foreign code.** Buffers passed to foreign code live on the calling actor's stack, valid for the call only. A library that keeps a pointer past the call must be declared in its wrapper (decision 36): such a buffer is allocated in the dangerous actor's existing FFI arena (outside the stack; today `ffi_arena_runtime_asm`, ACB 248 to 264) and released when that actor ends; undeclared retention is a library bug, contained by the guarded region; the declaration's spelling is for the detailed design and the FFI wrapper specification.
- **Outside the stack.** `region(L, atomic)` shared between actors (Q7) and device windows stay outside the stack under today's rules.
- **`main`.** `main` follows the same stack rules on its own thread stack; nothing `main` builds goes to a heap. **Today:** `main` allocates in the implicit heap like any actor.
- **`region(L, S)`.** A lifetime-scoped area of the actor's stack in memory space S, released when its frame pops or the message ends, as its lifetime L says (decision 12). Q1 is superseded: `arena(L, S)` is not introduced. Standard structures carry no region field; a structure is its root reference with its lifetime in that type, and updaters allocate in the current frame, or at the destination when the compiler sees where the result is kept (decision 13).

### 18.10 Open questions this section left (all answered 2026-10-24)

Every question of requirements §7.4 was answered by Lee on 2026-10-24; the answers are decisions 16 to 37 of requirements §2A. By item: 1 compiler-proven release (decision 18); 2 the replacement for `arena(L, S)` (decisions 12, 13); 3 `copy_to` (retired, 34); 4 and 17 Q11 and E2307 (retired, 16); 5 List sharing on send (lists copied, 30); 6 sizing (26); 7 `stack_policy` (27); 8 fallback copy cost (reported, 19); 9 FFI buffers kept past the call (declared, 36); 10 strings built at run time (29); 11 Q5 owner lists (dropped, 16); 12 owned regions as stack areas (34); 13 mutable cells holding structures (35); 14 shared allocator state (none at the language level, 37); 15 change-result reshaping and H9 (reshaping stays in chunk 15, H9 closes, 37); 16 safety by lifetimes (16; §10 lists which codes stay); 18 evacuation overlap (via scratch, 20); 19 holes (exact-size free lists, 21); 20 mailbox buffers at actor end (the end-of-actor drain, 31); 21 last-use elision (forwarding only, 32); 22 reply buffer (the caller's stack, no buffer, 33); 23 E2301 (stays, 22); 24 E2308 and E2309 (retired, 23); 25 `device_window` (one owner, 24); 26 fallback copy destination and peak (28). What the decisions leave to the design is requirements §7.5, "Left to the detailed design".

### 18.H Superseded text (before 2026-10-24)

The whole of §18 as it stood before the chunk 15 direction follows, verbatim except that its headings are shown as bold lines so that they do not repeat the live subsection numbers. Replaced by: §18 above (copy into a mailbox buffer; stack base for kept data and state; no region move, no family arena, no `arena(L, S)`). Parts that still hold were carried into the sections above in adapted form; this copy is the record.

**Old 18. Messages move: what a move means (Q6, decided; default superseded by Q18, 2026-10-23: copy by default, move on request, so this section describes the explicit move and the transfer of the copy)**

**Lee's decision, 2026-10-09 (default superseded by Q18, 2026-10-23, which makes a plain send a copy):** when a message carries a data structure, it is a **move**, not a copy. Under Q18 (2026-10-23, requirements R4) a send of a structure copies it by default (sharing inside the message preserved) and moves it only on request. (The current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md), has a structure version as a copyable `arena` handle that a send passes by value; that is not the standard.) The specification
conflict S1 resolves toward §12.1.6.

**Old 18.1 The rule at the language level**

A value given to any actor-boundary operand is **moved** (since Q18, 2026-10-23, only when explicitly marked `move`; otherwise it is copied and the sender keeps it):
- a `cast`, `send` or `call` message, and the `_registered` and `_dangerous` forms;
- a behaviour's reply and its new state;
- a `spawn` initial state.

For the classes of §3.1 this means:

| Class of the value | After the send |
| --- | --- |
| linear (owned region, `device_window`, aggregates embedding them) | after an explicit `move`, E2301 on any later use (already §3.8); after a plain send the sender keeps its original and the receiver has a copy (Q18) |
| structures (and records, tuples and lists holding them) | a plain send copies the structure into the message (sharing inside the message preserved, requirements R4.2) and the sender keeps using its own; an explicit `move` transfers it and a later use is E2301. Its home and how a move is realised are chunk 15's. Current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md): the receiver gets a copy of the `arena(L, S)` handle over never-freed nodes. |
| plain values (scalars, atoms, strings, actor references, records/tuples/lists of those) | usable. They are immutable, so a move and a copy cannot be told apart. The runtime copies them into the receiver; the copy out of the replier's arena is the targeted stage 0 fix for H4. |


**No use after an explicit move (Lee, 2026-10-22; narrowed to explicit moves by Q18, 2026-10-23).** It is a compile error, **E2301**, for the sender to do any work with a region
after it has been sent by an explicit `move`. "Work" is any use: read, write, pass to a call, return, store in state, send again. The rule
holds for a region by itself **and** for a region contained in anything else (a record, tuple, list,
closure or any aggregate embedding one; in the current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md), a structure version holds an `arena` handle, not an owned region; whether a structure is an owned region in the redesign is chunk 15's), and it holds however the region is reached afterwards: through a
name bound to the aggregate, through a field read from it, or through a copy of the handle. It applies to every
actor-boundary operand of this section, not only `cast`, `send` and `call`: a **reply** and a **spawn initial state**
(and a behaviour's new state, once it has been moved out) are sends in the same sense. The error trials are listed in
§18.6 (`send_then_use_*`).

The lifetime of a moved owned region after it arrives, and how a receiver keeps data past the dispatch, are in §18.7
(Lee, 2026-10-22): the regions are dispatch-scoped, and keeping anything is explicit.

**Structures (Q18, 2026-10-23).** A send, a reply and a spawn state COPY a structure by default (sharing inside the message preserved) and the sender keeps its own; only an explicit `move(...)` gives it up. Only a
change makes a version (§3.14). Keeping a version in the state and also replying with it or sending it is legal (the reply carries a copy), so E2303 does
not apply (Q12 is withdrawn); E2303 applies to an owned region (or structure) that is both kept and given away by an explicit `move(...)`, whose second use would be a second owner. Today's handle pass by value is the current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md):

```silica
fn beh(msg: int64, state: { root: ref?(L, normal, (K, V, int64, ref?(L, normal, rec), ref?(L, normal, rec))), …, region: arena(L, normal), … })
    -> (:reply, :unchanged | (:inserted, { … }) | (:replaced, { … }),
                { root: ref?(L, normal, (K, V, int64, ref?(L, normal, rec), ref?(L, normal, rec))), …, region: arena(L, normal), … }) {
    sequence proc[mem(normal)]
        r: :unchanged | (:inserted, { … }) | (:replaced, { … }) <- wbt_map@insert(state, msg, 0);
    produces
        pure (:reply, r, state)          // legal: reply with the change result, keep v1 = state
    end
}
```

```silica
        pure (:reply, state, state)      // legal (the reply carries a copy); E2303 only if the reply were an explicit `move(state)` while the state also kept it
```


**Old 18.2 Shared nodes under a move**

Current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md): nodes of a structure version live in a never-freed arena and are immutable, so any number of actors may hold versions that share nodes, with nothing to count and nothing to free. The only shared mutable state is the arena's bump pointer and insert table, which stage 0 makes atomic (H1). Under the standard this is not the send mechanism: a send copies (Q18) and the copy is released, so actors do not hold each other's nodes.

**Old 18.3 Structures under a copy or a move (arena handles are the current implementation)**

Standard (Q18, R4): a plain send copies the structure into a fresh owned region that moves to the receiver, O(size of the structure); an explicit `move` is O(1) and the sender gives the structure up. Current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md): a send is a handle pass, O(1); two actors on different cores may derive versions from one lineage concurrently, both allocating from the family arena with the atomic bump.


**Old 18.4 Calls, replies, state, spawn and supervised restart**

Under Q18 (2026-10-23) "moved" in this table means the move of the copy made at the send (the default) or of the original on an explicit `move`; E2301 for the sender applies only to explicit moves.

| Operand | Semantics | Checker |
| --- | --- | --- |
| `cast(a, m)`, `send(a, m)` | `m` is copied into a fresh owned region that moves to the receiver at submission (structures copied with sharing preserved); with an explicit `move(m)` the original moves, O(1) | later use of a linear part of an explicitly moved `m` is E2301 |
| `call(a, m)` argument | as `cast` | as `cast` |
| `call` reply `(:reply, r, s)` | `r` copied (moved on an explicit `move`) from the callee to the caller, by the same transfer; the caller's binding owns it | a region in both `r` and `s` is E2303 only when one is an explicit `move(...)`; otherwise the reply is a copy and both may hold the structure |
| behaviour new state `s` | stays in the actor: no transfer, no walk | the state's linear parts must each end in exactly one of reply, new state, a send, or a drop |
| `spawn(st, beh, policy)` | `st` copied into a fresh owned region that moves to the new actor at spawn; an explicit `move(st)` moves the original, O(1) | later use of a linear part of an explicitly moved `st` is E2301 (replaces `"moved_region"`) |
| owned regions in a `cast`/`send`/`call` message or a reply | moved on send (O(1) handle transfer); **dispatch-scoped** in the receiver: dropped at behaviour return unless moved into the new state, or the needed part is rebuilt with `copy_to`. Failure paths (dead receiver, timed-out call, dead caller, crashed receiver with queued messages) release the region in the runtime. All in §18.7 | E2301 for the sender's later use; `drop_owned` placed at behaviour return; lifetime error for a message ref stored into state without `copy_to` |
| supervised child spec initial state | an owned region may not be in it (E2308): the supervisor's row keeps the initial state to restart the child, which would duplicate the owner. A structure may (Q14, decided 2026-10-23): the spec holds the original, each start or restart gives the child a copy (built as `copy_to` builds one, sharing preserved), and the copy is released when the child dies; the copy's destination and type, who makes it, and the home of the spec's original are chunk 15's open details. | E2308 for an owned region. The `init` code that builds the spec moves its owned values into the spec, and later use is E2301. |

**Old 18.5 Specification text to change (not edited here)**

The wording proposed in the first rows below is the Q6 wording; Q18 (2026-10-23) changes it to "copied by default, moved only by an explicit `move`" when the specification is edited.

| Section | Change |
| --- | --- |
| §16.3.5 "Isolation: Message contents are copied between actors" | "Message contents are moved: the sender may not use a moved value afterwards (E2301). Immutable plain values are indistinguishable from copies; owned regions change owner; structures are copied by default and moved only on request." (Q18 changes this wording to copy-by-default when the specification is edited.) |
| §12.1.6 | extend from regions to data structures: a structure is copied on `call`, `cast`, `send` and reply by default (sharing inside the message preserved) and moved only on request (`move`); the storage and release of its nodes are chunk 15's |
| §12.1.5, §15.1.1 "Region handles in initial state" | owned regions and structures in a spawn initial state are copied by default and moved only on request |
| §15.4 child specs (`initial_state` in rows, §15.4.12) | a supervised child's initial state may not contain an owned region (E2308) |
| §16.3.5 "Immutability" | unchanged; add that a moved message is owned by the receiver from submission |
| §15.1.1 "State Semantics" and §12.1.6 replies | one owned region may not be both kept in the new state and given away as the reply or in a message by an explicit `move(...)` (E2303); under copy-by-default a region or structure in both is not an error |
| common_contract.md §6–§7 | a change borrows its input version and returns `:unchanged` or a tagged new version (§6's "a no-op may return the identical root" and its flags give way to the result sums of §3.14); a structure sent to another actor is a copy (Q18), and both actors may keep using their own |

**Old 18.6 Trials for moves**

**Error trials** (added to §14.1's catalogue):

| Code | Case |
| --- | --- |
| E2303 | (with the reply, message or state an explicit `move(...)`; a plain send is legal) an owned region kept in the new state and also replied; kept and sent through `cast`; kept and sent through `call`'s argument; kept and replied inside a record; `cast(a, (r, r))` |
| E2301 (no use after an explicit `move` send, §18.1, **not written**; plain sends need positive trials that the sender still uses its data) | `send_then_use_bare_region`; `send_then_use_region_in_record`; `send_then_use_region_in_tuple`; `send_then_use_region_in_list_element`; `send_then_use_via_field_read` (a field read from the aggregate after the send); `send_then_use_via_name_alias` and `send_then_use_via_handle_copy` (a copy of the handle); `send_then_use_region_in_closure`; `send_then_use_in_later_case_branch` (sent in one arm or before the `case`, used in a later branch); `send_then_use_in_loop` and `send_then_use_in_recursion` (sent in an iteration, used in the next, or by the recursive call). Each is repeated for `cast`, `send`, `call`, a reply and a spawn state, and for each of read, write, pass to a call, return, store in state and send again |
| E2308 | child spec whose initial state holds an owned region |

**Run trials:**

| Trial | Shows |
| --- | --- |
| `move_reply_version` | `call` returning a version built in the callee; the caller keeps using it after the callee ends (H4 for structures; the targeted stage 0 fix) |
| `move_map_of_sets` | a `graph_wbt` adjacency version sent; the receiver and the sender both query it |
| `supervised_child_restarts_with_version` | a child whose initial state holds a map version crashes and restarts 1,000 times (Q14); every start receives a copy with the same contents, released when that child dies |
| `reply_and_keep_same_version` | a server keeps v1 in its state and replies with the same handle on every call, 10⁴ calls; the caller and the server both validate it |
| `move_two_cores` (board) | sender and receiver pinned to different cores, each deriving versions from one lineage for 10⁵ rounds with the atomic bump; validate both |
| `message_region_released_at_dispatch_end` | **not written** (§18.7; write-every-page, the SD-7 shape). A receiver is cast 100,000 messages, each holding an owned region of several pages, and writes every page; it keeps nothing. RSS stays flat. Fails today (SD-7). |
| `message_region_moved_into_state_not_dropped` | **not written** (§18.7). The behaviour moves the message's whole region into the new state; no `drop_owned` is placed on that path, the region is read intact by the next dispatch, and it is released once, at the actor's end. |
| `copy_to_rebuilds_in_state_region` | **not written** (§18.7). The behaviour copies a part of the message value into the state region with `copy_to`; the message region is dropped at return, the copy is intact in the next dispatch, its type carries the state's lifetime, and a 100,000-message run keeps RSS bounded by the state. |
| `partial_move_of_region_out_of_message_record` | **not written** (§18.7). A message `{ r: region, root: ref? }` is received; the behaviour moves `r` out of it into the state (partial move). The remaining fields may not be used afterwards where they borrow `r` (E2301), and `r` is released exactly once. |
| `crashed_actor_queued_message_regions_released` | **not written** (§18.7, H9). Messages with owned regions are queued to a worker that faults on its first dispatch; the supervisor restarts it 1,000 times. The regions of the unprocessed mailbox are released with the actor; heap growth is bounded. Fails today. |
| `send_to_dead_actor_releases_region` | **not written** (§18.7). A `cast`, a `send` and a `call` with a region to a removed actor return `actor_not_found`; the runtime releases the region that moved (the copy, or the original on an explicit `move`, where the sender may not use it, E2301); 100,000 repetitions, RSS flat. |
| `timed_out_call_late_reply_region_released` | **not written; blocked on chunk 11** (`call_with_timeout` is not started). A call times out; the callee's later reply carries a region; the runtime discards the reply and releases the region. |
| `caller_dies_reply_region_dropped` | **not written** (§18.7). A caller is removed while awaiting a reply; the callee replies with a region; the region is dropped, not leaked, and not freed twice. |

**Error trials** (added by §18.7, **not written**): `message_ref_stored_in_state_without_copy_to_is_error` (a ref carrying the message region's lifetime stored into state typed with the state's lifetime is the lifetime error, and the program with `copy_to` compiles); `copy_to_rejected_for_device_window_and_atomic` (`copy_to` of a `device_window` or an atomic cell is rejected); the sender's later use of a region after an explicit `move` send is E2301, also when the send fails at run time.

**Old 18.7 Dispatch-scoped message regions and explicit `copy_to` (Lee, 2026-10-22)**

**Decision.** The regions a message carries are **moved on send** (since Q18, 2026-10-23: the sender's copy of the message is the region that moves, or the original when the send is an explicit `move`) and are **dispatch-scoped** in the receiver. Keeping
anything past the dispatch is explicit. This is the plan for messages that carry regions; it fixes BEES's SD-7 (a
region received in a message is never freed while the actor lives) without later reclamation.

**1. Move on send.** The no-use-after-send rule of §18.1 (E2301 for any use of the region, bare or embedded, by name, field read or handle copy, on `cast`, `send`, `call`, reply and spawn state) is the static half of this section. A message's owned regions (and the aggregates embedding them) change owner in O(1): a handle
transfer (§7.3's `_silica_rt_region_transfer`), no byte copied. The sender's later use of an explicitly moved region is E2301, as §3.8 and §18.1
already decide. Replies follow the same rule: a reply's regions belong to the caller's continuation, that is, the
binding that receives the `call` result owns them (§18.4), and are dispatch-scoped there in the same way.

**2. Dispatch scope.** The receiver owns the message's regions for the length of that behaviour call. The checker
places a `drop_owned` (§7.1) for each of them at behaviour return, unless the region flowed into the new state. No
runtime test and no reference counting are involved; this is the static ownership rule of §3.8 ("each linear part of
`msg` must be in the reply, in the new state, moved elsewhere, or dropped") with the drop made the default for a
message part that goes nowhere.

**3. Keeping data past the dispatch.** Two ways, both explicit:

- (a) **Move the whole region into the new state.** The state then owns the region; there is no drop on that path. O(1).
- (b) **`copy_to(state_region, value)`**: a compiler-derived copy that rebuilds `value` in the state's region and
  returns it typed with the state's lifetime. It is built on the same derivation machinery as the Recreatable
  `recreate` of the FFI wrapper specification (§7.7), the compiler walking the value's type. It is O(size of the
  value), visibly. There is no `copy_to` for a `device_window` or an atomic cell (they are neither copyable nor
  rebuildable); using one is a compile error.

Nothing is implicit. A `ref` that carries the message region's lifetime, stored into state typed with the state's
lifetime, is the **existing lifetime error** (§4); it is what forces the explicit `copy_to`, and no new code is needed
for it. Under Q18 a plain send copies and the sender keeps its data; only an explicit `move` gives it up, and a sender that moves but still wants the data calls `copy_to` before the move (a visible O(n)).

**4. By value class.**

| Class of the message part | Send | Keep past the dispatch |
| --- | --- | --- |
| owned region, or an aggregate embedding one | copy into a fresh owned region that moves (Q18); an explicit `move` sends the original | move the whole into the state, or `copy_to` a part |
| structure | copy into the fresh owned region that moves (Q18), sharing preserved; an explicit `move` sends the original (current implementation, replaced by chunk 15: handle pass by value, §18.3) | keep a copy in the state's home (chunk 15; today: store the handle) |
| plain scalars, atoms, strings | copy (§18.1) | already a copy |

**5. Partial move.** A message such as `{ r: region, root: ref? }` moves as a unit; the receiver binds `r` and `root`
by destructuring. The checker needs a rule for pulling the region out of an aggregate: **moving a linear field out of a
record or tuple parameter is a partial move.** It consumes that field; the other fields stay usable, except that a
`ref` whose lifetime is the moved region's cannot be used after the region has been moved into the state or dropped
(E2301 on the remaining fields that borrow it). The aggregate as a whole is not usable after a partial move. This rule
is new to §3.4 (§3.4 states only the whole-aggregate case) and has to be added there when stage 3 implements it.

**6. Cross-core receivers.** The receiving carrier or core must be able to free the region's blocks: on the hosts
the receiver's drop is the plain region destroy of a whole `alloc_region` block chain and does not require the sender's
thread. The board heap is not checked by this section (it is one heap under the scheduler lock, §7.3).


**7. Failure paths.** The design had not covered the following. All of them belong to stage 4 (§13, §16 item 10) and
have trials in §18.6.

- **(i) Mailbox drain at actor end.** The actor-end owner-list walk (§7.3) must include the regions in the actor's
  **unprocessed mailbox** as well as those in its state and locals. Today a crashed actor leaks them (H9). Whether
  they are already on the receiver's list depends on when the transfer links them (at submission, as §7.3 says, or at
  dispatch); stage 4 must pick submission, so the walk covers them with no mailbox traversal, and must show it by
  `crashed_actor_queued_message_regions_released`.
- **(ii) Failed send.** A `cast`, `send` or `call` to a dead actor returns `actor_not_found`. The sender cannot use the
  moved region (E2301 is static and cannot know the send failed), so **the runtime releases the region on the failed
  send**. The alternative, keeping ownership with the sender on failure, would contradict the static moved rule: the
  checker would have to treat the region as both moved and not moved. Q17 is decided (a), 2026-10-22.
- **(iii) A timed-out call.** Under `call_with_timeout` (chunk 11, not started) the late reply is discarded; its
  regions must be released at that point. The trial is blocked on chunk 11.
- **(iv) The caller dies awaiting a reply.** The reply's regions are dropped when the reply is delivered to a dead
  caller, as in (ii).
- **(v) A worker dies holding the only copy.** Nothing is recovered: a region received and not yet moved into state
  dies with the worker, and its sender no longer has it. Under Q18 a plain send already copies, so the sender keeps its own data, as in BEAM; a sender that sent with an explicit `move`
  and needs the data to survive the receiver's crash must `copy_to` before the move and keep the copy. Documented here and in the language guide, not enforced.

**8. What this changes in the plan.**

- There is no counting of any kind: Q2 (a) was decided on 2026-10-22 and structure versions are arena handles (current implementation, replaced by chunk 15 (see data_structure_redesign_requirements.md)).

- It **closes H4 for plain values** (they are copied, §18.1) and **SD-22 and SD-7 for owned regions** (dropped at
  dispatch end). SD-22 is H2's stage-0 fix plus the drop; SD-7 needs this section and stage 4.
- Stage 2 (owned versus structure kind) is still needed: the rule applies to owned regions, not to structure handles.
- Stages 2 to 5 are still required for S-15 (region release inside a living actor): the checker, the drops and the
  errors are what places the dispatch-end drop.

**9. Inconsistencies found in the earlier text (to reconcile at implementation).**

- §18.4 says a behaviour's new state "stays in the actor: no transfer, no walk". The same behaviour now also drops
  message regions at return; the sentence applies to the state alone.
- §14.2 `region_moved_between_actors` says the region is "released once, at the receiver's end". Under this section it
  is released at the end of the receiving dispatch unless it was moved into the state. The trial's expectation must
  be adjusted when it is written.
- §7.3 links a region into the receiver's list at submission, which already puts a queued message's regions on the
  list; the "mailbox drain" of 7(i) is then a requirement on that choice and on the failed-send path, not a new walk.
  If a stage-4 implementation transfers at dispatch instead, the walk must add the mailbox.
- §3.8 describes the behaviour's message parameter as owned and requires each part to end in "the reply, the new
  state, moved elsewhere, or dropped"; it does not say that the drop is placed by the checker by default. This section
  says it is.
- §18.1's table row for plain values says the runtime copies them into the receiver; with the drop at dispatch end,
  a plain value inside a message that also holds a region is copied with the message and remains usable in the state
  only if it does not borrow the region (see 5).

---

## 19. Escaping values on the actors' stacks (added 2026-10-12, Lee: option b; rewritten 2026-10-24 for the chunk 15 direction)

**Status of this section.** The 2026-10-12 text assumed a per-actor implicit heap that is reclaimed only when the actor dies. The chunk 15 direction removes that heap (requirements §2A, decision 2). This section keeps the 2026-10-12 findings (what escapes, and what is already fixed) and states how each case is handled under the direction. It describes the direction, not the runtime; **today:** is marked wherever they differ. The earlier text is verbatim in §19.H.

### 19.1 What already does not allocate (fixed 2026-10-12, still true)

The 2026-10-12 emitter fix gave tuple- and record-returning calls a caller-provided result slot (X8), so a result used where it is made never touches the heap (destructured, discarded, field-read only, or returned along the caller's own return spine). Behaviour state tuples are reused in place on the hosts, and case-arm tuples are built in the reply buffer. This is the destination-passing of the direction in its first form.

### 19.2 What escapes, and the rule under the direction

Working values are built in stack frames. A value escapes when it must outlive the frame that made it. Under the direction:

- **Destination-passing** where the compiler sees the value flow to the return: the callee builds it where the caller keeps it, as region passing does (requirements R4.3).
- **Evacuation on return** otherwise: the nodes whose addresses lie inside the frame being popped are copied to the caller's area, forwarding pointers are written into the dying frame (so no table is needed and sharing is preserved), and pointers to older nodes are left alone. Intermediate versions unreachable from the result are not copied. Non-tail recursion would copy a returned version once per frame (quadratic), which is why destination-passing is preferred.
- **Cleanup on pop (Lee's rule, 2026-10-23, unchanged):** a version created in a callee's frame and not returned is cleaned up at the pop. This is the same rule as §3.3 (an owned value not returned or moved is dropped at scope end), with "moved" meaning "evacuated to the caller".
- **State.** What survives a dispatch is evacuated to the stack base (§18.8).

The 2026-10-12 findings below remain the checklist of cases the implementation must cover. Each is an escaping value and so follows the rule above:

- a result bound to a name that escapes, or stored in a tuple, record or list element (`[bounds(x) | seen]`, `{ range: bounds(x), ... }`);
- a result passed as a call argument (`total(bounds(x))`);
- an aggregate sent in a message, and composite replies (copied each message at the boundary; under the direction a message goes into the mailbox buffer, §18.7, and a reply into the blocked caller's stack, decision 33);
- fresh makes nested inside an actor's new state (evacuated to the stack base at dispatch end);
- the `(ok, value)` pair of checked int64 arithmetic (16 B per operation) (it escapes only if returned or stored);
- case scrutinees built as aggregates;
- values a function receives and drops (e.g. `main` keeping every `call_supervisor` reply record and its child lists: about 464 B per supervisor start/end cycle on the board, measured 2026-10-12), which the pop now releases because a function's values are cleaned up when the frame pops (the 2026-10-12 text said they were not, because scope release is disabled until ownership-based release exists; the direction replaces that by stack frames).

Also escaping under the direction (decision 2): list cells, strings and call replies. Strings are ordinary escaping values (decision 29): each concatenation allocates its exact result length in the current frame, returning evacuates, keeping in state copies to the base, and string literals stay in read-only data and are only pointed to. List-cell building on the stack is for the detailed design. Structures returned from functions follow the same rule; their update allocates new nodes in the current frame (decision 13).

**Today:** every case above is promoted into the per-actor implicit heap, a chain of 64 MB blocks served by `_silica_rt_region_alloc` and released only when the actor ends. On a long-lived actor these grow without bound even when the copy is dead at once (an argument a callee only reads) or when the structure holding it later drops it. The sites that allocate are inventoried in requirements §8.2 (Mac 22, linux_aarch64 22, linux_x86_64 20, ESP32-S3 5 call lines).

### 19.3 Why not patch case by case

Lee decided (2026-10-12) not to patch these case by case in the emitters: reclaiming them needs to know when the last reference is gone, which is this chunk's ownership model. Under the direction the model is the frame pop, the dispatch-end evacuation and the compiler-proven release of §18.8, all decided at compile time. The earlier reference to "messages copy by default and move on request (Q18), versions only by a change" stands, with the amendment that a move copies (decision 6).

### 19.4 Trials

The chunk-4 implementation must cover every case above with a zero-growth trial for each (the `zero_heap_growth_*` trials in actors_addition and the `*_frees_heap` trials in stack_budget_board_addition are the pattern). Under the direction the measure is stack depth and base-area size across a long run, not heap growth; the form of the trial is unchanged.

### 19.5 What is left

The questions of this section are answered: the stack base and `stack_policy` (decision 27), the sizing (decision 26), strings (decision 29), the fallback copy's cost (decision 19, reported with a strict mode) and mutable cells holding structures (decision 35: a ref cell may only be given a value whose lifetime is at least the cell's, and a cell in state takes only values that will be in state, a compile-time lifetime check). The one matter left for the detailed design is the cost of evacuating a returned value across many frames when the compiler cannot see the flow to the return (requirements §7.5 item 3).

### 19.H Superseded text (before 2026-10-24)

The whole of §19 as it stood before the chunk 15 direction follows verbatim (heading shown as a bold line). Replaced by: §19.1 to §19.5 above (stack frames, destination-passing, evacuation on return, state at the stack base; no per-actor implicit heap). The findings that still hold were carried into §19.1 and §19.2.

**Old 19. Escaping aggregates in actor regions (added 2026-10-12, Lee: option b)**

The 2026-10-12 emitter fix gave tuple- and record-returning calls a caller-provided result slot (X8), so a
result used where it is made never touches the heap (destructured, discarded, field-read only, or returned
along the caller's own return spine). Behaviour state tuples are reused in place on the hosts, and case-arm
tuples are built in the reply buffer.

What still allocates in the actor's region, and is reclaimed only when the actor dies, is every aggregate
whose value must outlive the frame that made it:

- a result bound to a name that escapes, or stored in a tuple, record or list element (`[bounds(x) | seen]`,
  `{ range: bounds(x), ... }`);
- a result passed as a call argument (`total(bounds(x))`);
- an aggregate sent in a message, and composite replies (copied each message by the boundary move);
- fresh makes nested inside an actor's new state;
- the `(ok, value)` pair of checked int64 arithmetic (16 B per operation);
- case scrutinees built as aggregates.
- values a function receives and drops (e.g. `main` keeping every `call_supervisor` reply record and its child lists: about 464 B per supervisor start/end cycle on the board, measured 2026-10-12), because a function's values are not released when it returns (scope release is disabled until ownership-based release exists).

On a long-lived actor these grow without bound even when the copy is dead at once (an argument a callee only
reads) or when the structure holding it later drops it. Lee decided (2026-10-12) not to patch these case by
case in the emitters: reclaiming them needs to know when the last reference is gone, which is this chunk's
ownership model (ownership of owned regions, messages copy by default and move on request (Q18), versions only by a change). The chunk-4 implementation
must cover every case above, with a zero-growth trial for each (the zero_heap_growth_* trials in
actors_addition and the *_frees_heap trials in stack_budget_board_addition are the pattern).

## Revision history

| Version | Date | Changes |
| --- | --- | --- |
| 1.32 | 2026-10-24 | Decision 38 (nothing in a message is shared with the sender; unbound `rec` cannot reach a send once Q19 is enforced) applied to §18.2 and §18.7 item 1. |
| 1.31 | 2026-10-24 | Decisions 34 to 37 (explicit regions are frame areas and `copy_to` is retired; ref cells are a lifetime check; declared FFI retention in the dangerous actor's FFI arena; H1 and H9 close, reshaping stays in chunk 15) applied to the top block, §0, H1, H9, §3.8, §3.14, §9.4, §13, §15 Q15, §16, §18.1, §18.2, §18.4, §18.6, §18.7, §18.9, §18.10, §19.5. The §3.8 and §18.4 reply rows now name the caller's stack explicitly. All requirements §7.4 items are answered; §7.5 lists what is left to the detailed design. |
| 1.30 | 2026-10-24 | Decisions 30 to 33 (lists copied on send; end-of-actor mailbox drain; forwarding-only last-use elision; replies copied into the blocked caller's stack) applied to §3.8, §7, §13, §15 Q5, §16 item 10, §18.2, §18.4, §18.7 (items 1, 7), §18.10; requirements §7.4 items 5, 20, 21, 22 answered. |
| 1.29 | 2026-10-24 | Decisions 26 to 29 (sizing against the existing reservation with `(:explicit, :stack_exhausted)`; `stack_policy` measuring from the state edge word; the fallback copy via scratch, two copies of the state; strings as ordinary escaping values) in §18.7, §18.8, §18.10, §19.2, §19.5 and §12; §14.1 moves the `device_window` case out of the E2301 row into a row for the future single-owner code. |
| 1.28 | 2026-10-24 | Decisions 22 to 25 (E2301 stays as a lifetime error; E2308 and E2309 retired; `device_window` keeps one owner with a check that needs its own code; E2300/E2302 reading confirmed) applied to §3.1, §3.8, §3.13, §6, §7.1, §10 (dispositions), §11, §12, §13, §14.1, §16, §18.4 to §18.6, §18.10; new requirements §7.4 item 26. Registry not edited. |
| 1.27 | 2026-10-24 | Decisions 18 to 21 (compiler-proven release by a per-behaviour use analysis and a release log; the fallback reported by a note and a strict mode; evacuation via scratch with two copies; exact-size free lists) recorded in §18.8 and §18.10, §19.5; requirements §7.4 items 1, 8, 18, 19 answered. |
| 1.26 | 2026-10-24 | Decisions 15 (spawn state copied into the new actor's stack base), 16 (stack regions not linear, safety by lifetimes only; linear-ownership checks, `drop_owned`, owner lists dropped; Q5 superseded, Q11 and E2307 retired) and 17 (Q3 and Q4 superseded) applied: top block, §0 update, §3 note and §3.1, §3.8, §3.10, §3.13, §4, §6, §7 note and §7.3, §10 disposition column for E2300 to E2318, §11, §12, §13 stages 3 to 5, §14.1 note, §15 (Q3, Q4, Q5, Q11), §16 items 8, 10, 12, 13, §18.4 to §18.7, §18.10. Superseded text kept in place. Registry not edited. |
| 1.25 | 2026-10-24 | Consistency pass over 1.23 and 1.24, wording only: notes on §2 (actor heap and owned-region rows), §3.8 spawn row, §3.13, §4, §6, E2312, §9.4; §2 owner-transfer sentence marked superseded; §13 "paragraph above"; §15 heading list of affected decisions; §18 history on S1; §18.2 lists; §18.4 reply item number (22) and spawn row marked inferred; §18.7 elision item number (21), REGION descriptor note and provisional lifetime-error note; §18.8 place bullet points to decision 14. No decision changed. |
| 1.24 | 2026-10-24 | Remaining text brought in line with the chunk 15 direction (requirements §2A, decisions 1 to 14): top Standard and status paragraphs, §0 note, summary and kinds table, §3.1, §3.8, §3.13, §3.14, §7.3, §12, §13 (stages 2, 4, 5), §14.2, §15 (Q1 to Q6, Q13, Q16 full wording), §16 items 6, 7, 10, 11, 17, §17. Text that no longer holds is kept in place and labelled superseded; present-day behaviour is labelled today. Nothing decided beyond the requirements; open matters point to requirements §7.4. Sections 1, 2, 4 to 11 describing the current runtime are unchanged. |
| 1.23 | 2026-10-24 | §18 and §19 rewritten for the chunk 15 direction (requirements §2A, decisions 1 to 13): values on the actors' stacks, destination-passing then evacuation for escaping values, state at the stack base with compiler-proven release and the dispatch-end copy fallback, copy-on-send into a mailbox buffer, `move(x)` copies, Q16 amended, Q13 withdrawn, Q1 superseded. Carried over: the type-directed copy and descriptors, sharing tables, SD-7 dispatch scope, failed-send handling, last-use elision, E2301 and E2303 rules, trials. Superseded text kept verbatim in §18.H and §19.H. Subsections 18.1 to 18.7 keep their numbers; 18.8 to 18.10 are new. Open items point to requirements §7.4. No code or specification text changed. |
| 1.22 | 2026-10-23 | Lee's decision of 2026-10-23, recorded as Q19 in `data_structure_redesign_requirements.md`: `rec` binds to its innermost enclosing tuple type in every position, and an unbound `rec` is E2010 in record fields, parameter types and return types as it already is in binding annotations (no new code). Structure roots, parameters and returns are spelled with the node shape (H8, the `(region, ref?)` allocator tuples and the state records in §§3 and 15 are described that way here). Brodal-Okasaki and rose-tree children become `List[ref?(L, normal, rec)]` with the rank in the child node. Reason: Q18 copy-on-send is type-directed from compile-time descriptors and a per-cell runtime layout header (+8 bytes per record cell) was rejected. See the requirements document, Q19. |
| 1.21 | 2026-10-23 | Aligned to data_structure_redesign_requirements.md, which is the standard (Lee, 2026-10-23). Arena-handle text for structure versions (§0, §1.5 S1, §2, §3.1, §3.8, §3.13, §3.14, §12, §17, §18 lead, §18.1, §18.2, §18.3, §18.4, §18.5, §18.7) rewritten to the requirements (structures copied on send by default, move on request, sharing preserved within a message, Q13 copy on read, Q14 copy per child start released at death, home and release decided by chunk 15) and the description of today's arena behaviour labelled as current implementation, replaced by chunk 15. E2303 narrowed to explicit `move(...)` (§3.8, §10, §14.1, §18.1, §18.4, §18.5, §18.6). Q18 staged: copy-on-send and the `move(x)` marker in stage 4 (a language change; the legacy `move` builtin was removed in 146f34bf19 and `move(...)` gets E2007 until then, so trial `actor_move_removed_unknown_function` must change), narrowed E2301 and E2303 in stage 5 (§13, §16 items 10 to 12). Build status: stage 0 implemented and verified on the Mac, built on pix (compiler 999964) and nix with no compile errors, no Linux trials run, ESP32-S3 mirror not built. Spec not edited. |
| 1.20 | 2026-10-23 | Consistency cleanup after Q18 and stage 0, no new decisions. Implementation-status paragraph rewritten (stage 0 implemented on the Mac and built on pix and nix; E2313/E2314 literal checks; first SD-7 release); H1 row (hosted carriers, fixed) and the §1.3 intro; H10 and S1 rows; chunk 15 noted wherever the never-freed family arena is stated as settled (§0, §2, §3.14, §12, §13 stages 2, §15 Q2/Q13/Q14, §16 items 6-7, §17, §18.1); Q18 applied to the stale "messages move / E2301 after a send" text (§2, §3.2, §3.13 spawn example now `move((r, 0))`, §7.3, §12, §14.1, §14.2, §15 heading, §18 lead, §18.1, §18.4, §18.5, §18.6, §18.7 items 1, 3, 4, 7(v), §19); `alloc_atomic` text brought to Q8; the `send_then_use_region_in_structure_version` trial dropped (a version holds an arena handle, not an owned region); the stale note about a duplicated `shared_owner_ends_first` row removed (the row went in 1.9); §15 heading no longer says decisions are open. Conflicts that need Lee are reported separately, not resolved here. Spec not edited. |
| 1.19 | 2026-10-23 | Q18 (Lee, option C): messages copy by default, move on request (explicit move spelled `move`; the legacy `move` builtin is being removed). The copy is made into a fresh owned region that then moves to the receiver, so §18.7, Q16 and Q17 stand; sharing is preserved by a per-message table; evacuation uses forwarding pointers in the dying frame, destination-passing preferred. E2301 narrowed to explicitly moved values in §3.8, §10, §18 and §18.7; Q6 kept as history. Spec not edited. |
| 1.18 | 2026-10-23 | Lee is not happy with the design of the standard data structures: ROADMAP chunk 15 (data structure redesign: ownership, copy and release) added, with the decisions of 2026-10-22/23 as requirements, none provisional. Note at the top of §0; stage 2 (structure handle type) waits on chunk 15, which takes over the stdlib rename, H9 and the §3.14 change-result reshaping. Q13 and Q14 open details are owned by chunk 15. |
| 1.17 | 2026-10-23 | Lee's decision of 2026-10-23: Q14, a copy is sent to the child at start and cleaned up when the child dies. The supervisor's child spec may hold a structure version; every start and restart gives the child a structural copy (built as `copy_to` builds one, Q15, Q13), released at the child's death; neither (a) reuse of the handle nor (b) E2308 for versions; E2308 stays for owned regions. §0, §3 and §7 text, §15 Q14 and the trial row updated. Every §15 decision is now made. Open details, not decided: Q13, which arena receives the copy and the spelling; Q14, (1) the copy cannot live in the never-freed family arena (Q2 a), so it needs a child-owned region freed by the Q5 owner list, and its type spelling and relation to `arena(L, S)` and Q16 are undecided, (2) O(size) cost per start and restart (restart storms), (3) whether the supervisor or the runtime makes the copy and its destination, (4) whether Q2 (a) needs a per-instance exception for structures that must be freed (for Lee). |
| 1.16 | 2026-10-23 | Lee's decision of 2026-10-23: Q13, a structural copy. Reading an inner structure version out of a container (a graph's adjacency set from `get`) returns a copy built the way `copy_to` builds one (Q15), not the stored arena handle; neither (a) return the handle nor (b) queries only. Recorded consequences: O(size of the inner structure) per read; arenas are never freed (Q2 a), so each read leaves a copy behind; a loop of reads over a graph is quadratic in the worst case; the stored original is untouched; queries need no copy. Open detail, not decided: which arena receives the copy (caller's or the inner type's family arena) and the spelling (explicit `copy_to`-style call or implicit in `get`). Q14 is now the only open decision of §15. |
| 1.15 | 2026-10-23 | Lee's decision of 2026-10-23: Q11 (a), a linear (owned-region) type may not instantiate a generic type parameter, list element type or trait associated type (E2307 LinearTypeArgument); (b), a linear-aware generic checker, may be added later because (a) only rejects programs. §0, §3.10, §13 and §15 Q11 updated. Stage 5 is no longer blocked on an open decision. Still open: Q13, Q14. |
| 1.14 | 2026-10-23 | Lee's decision of 2026-10-23: Q10 (a), implicit per-signature quantification of lifetimes (§5 A): each call instantiates the callee's lifetime names consistently across arguments and result, conflict is E2311, a result-only lifetime is fresh and returned with its region else E2300; no `L: lifetime` value parameters, no bracket generics. §0, S6, §5, §15 Q10 updated; spec §4.4.1/§12.1.4 reworded. Stage 1 is no longer blocked on an open decision. Still open: Q11, Q13, Q14. |
| 1.13 | 2026-10-23 | Lee's decision of 2026-10-23: Q8, the recommended surface of §9.2: no `alloc_atomic` (`alloc_ref` into an atomic region); `read_ref`/`write_ref` on atomic refs mean `:seq_cst`; four `atomic_*` builtins (`atomic_load`, `atomic_store`, `atomic_fetch_add` integer-only, `atomic_compare_exchange`) with literal atom orderings (E2317 illegal order, E2315 non-atomic ref); compare_exchange returns `(:ok, T) \| (:fail, T)`; 64-bit cells on the ESP32-S3 take the runtime spinlock; the `mem(atomic)` function-level barriers are removed. §0, §9.2, §9.3, §13 stage 7 and §15 Q8 updated; spec §17 and its `alloc_atomic` mentions updated, the lock-free stack example removed (Q7 rejects it). Stage 7 is no longer blocked on an open decision. Still open: Q10, Q11, Q13, Q14. |
| 1.12 | 2026-10-23 | Lee's decision of 2026-10-23: Q7 (a), `region(L, atomic)` is an application-lifetime, copyable shared region holding only word-scalar atomic cells, the one named exception to spec §12.1.6's no-cross-actor-sharing rule, on all targets (hosted threads share an address space; LDAXR/STXR, lock cmpxchg and S32C1I are ordinary instructions); interrupt, DMA and peripheral uses wait for chunk 14. §0, S3, §9.1, §13 and §15 Q7 updated; spec §12.1.6 reconciled. Still open: Q8 to Q11, Q13, Q14. |
| 1.11 | 2026-10-23 | Lee's decision of 2026-10-23: Q3 (a), a function may consume a region parameter without returning it; an unreturned, unmoved parameter is dropped and released at the end of the body (trial `region_move_pass_no_return`). Q4 (a), user functions cannot borrow in chunk 4: only the region prims borrow, and a function that inspects an owned region takes it and returns it; (b) may be added later since (a) rejects nothing (b) would accept. E2305 stays reserved and unused (number not reused). §0, §3.3, S2, §13, §15 Q3 and Q4 and the E2305 row updated; spec §4.4.2 reworded. Still open: Q7 to Q11, Q13, Q14. |
| 1.10 | 2026-10-23 | Lee's decisions of 2026-10-23: Q9 (a), an out-of-bounds buffer index, an invalid buffer size and a list-index failure end the actor with `(:explicit, :buf_bounds)` / `:buf_invalid` / `:list_index`, abort 71 only in `main`; H5 (region growth and raw allocation failure, chosen 2026-10-22) likewise ends the actor with `(:explicit, :region_alloc_failed)`. §1.2, H5, S5, §8, §10, §13 stages 0 and 8, §15 Q9 and §16 item 16 updated; `\|bounds:N` metadata removal recorded; E2313/E2314 registered. |
| 1.9 | 2026-10-22 | Pruned the counted-storage text that Q2 (a) made contradictory. Removed: the counted class of structure versions (§3.1, §3.8, §3.13, §3.14) and its rules; the counted row of §7.1; error codes **E2319** *WriteToSharedCell* and **E2320** *VersionAliased* (the block is now E2300 to E2318; the numbers are not reused), and their trial rows in §14.1; the version-borrow/consume table, `dup` placement and count increments of §3.14 (the version rules that still hold, and the result shapes, are kept for arena handles); stage 6 of §13 (there is no stage 6; 7 and 8 keep their numbers) and §16 items 14 to 17 (old 18 to 21 are now 14 to 17); §17 reduced to the measurements, the options considered and the choice (old §17.1 to §17.9 removed); §18.2 (biased counting: header, owner test, count queue, merge at actor end, crash cleanup maps, cores) and §18.3's immortal versions, replaced by two short paragraphs; the counted and immortal rows of §18.1; the counted-version trials of §14.2 and §18.6; the stage-6a text of §18.7 item 6. Decided on the way: E2303 stays for owned regions only, because an arena handle is copyable and a second use of a version is not a second owner; Q12 is withdrawn as moot; Q6 is narrowed to owned regions; Q13 and Q14 stay open but are rewritten for arena handles (recommend: return the handle; allow a version in a child spec); E2308 now covers owned regions only. The stdlib change-result reshaping of §3.14 and the trials that need it are no longer carried by any stage. References to revisions 1.1 to 1.8 above use the old §16 numbering and the removed sections. |
| 1.8 | 2026-10-22 | Lee's decisions of 2026-10-22: Q2 (a), the never-freed family arena with the atomic bump, so counted storage and stage 6 (items 14 to 17 of §16) are dropped, may be reopened later; Q1 (a) spelled `arena(L, S)`; Q5 (a) per-actor owner list; Q15 (a) compiler builtin `copy_to(region, value)`; Q16 (a) a received region may move into the state; Q17 (a) the runtime releases the region on a failed send. §0, §13 (stages 2, 4, 6 and the dependency paragraph), §15, §16 (items 6, 14 to 17), §17 and §17.9, §18.7 updated; H4 now needs the targeted stage 0 fix, biased counting is not needed. Still open: Q3, Q4, Q7 to Q11, Q13, Q14. |
| 1.7 | 2026-10-22 | Lee's approach for messages that carry regions: moved on send, dispatch-scoped in the receiver (dropped at behaviour return unless moved into the new state), kept past the dispatch only by moving the whole region into the state or by a compiler-derived `copy_to`. New §18.7, with the failure paths the design had not covered (mailbox drain at actor end, failed send, timed-out call, dead caller, worker dying with the only copy); §18.1, §18.4 cross references; ten trials in §18.6, not written; stage 4 (§13) and item 10 and 11 (§16) extended; new open questions Q15 to Q17. Closes SD-7, SD-22 and H4's owned-region case without later reclamation; biased counting is needed only for counted storage (Q2 b or c). |
| 1.6 | 2026-10-09 | Lee chose option A, replacing 1.5's "every change consumes its input" (the coordinator's wording, not Lee's): changes borrow their input, so old versions stay valid and persistence is observable; a no-op change returns `:unchanged`, not a version; result sums per family replace today's flags (§3.14). Restored: Q12's two-version reply pattern, the persistence trials and the 149 reuse sites, §17.3/§17.6 costs, §18.2's hard case and drop-order trials. Re-evaluated: supervised child specs still may not hold a version (new Q14), and Q13 (inner versions) under A. Trials, stage 6d, item 16 and the spec-change list updated. |
| 1.5 | 2026-10-09 | Lee's version rules: only a change makes a version (no aliasing, no implicit duplication), and every change consumes its input; a no-op change returns the same version with no count change, no check and no failure (this replaced, the same day, a proposal to fail no-op changes with `(:explicit, :no_op_change)`, which was withdrawn with its static E2321 and query-first requirement). New §3.14 with the stdlib no-op inventory (≈ 69 return sites, 23 modules); E2320 *VersionAliased*; supervised child specs may not hold versions (E2308 extended); §17.3/§17.5/§17.6, §18.1 (examples), §18.2 (where cross-actor counting arises; no-op row), Q12, Q13 (container reads), §13 stage 6d, the trials and the spec-change list updated. Consequence recorded: old versions are not kept, so the Q12 "keep v1, reply v2" pattern and 149 trial reuse sites are no longer legal. |
| 1.4 | 2026-10-09 | Q12 decided by Lee: no `share` builtin. One version kept in state and also replied or sent is E2303 with no escape hatch; two versions (keep v1, reply or send v2 derived from it) are the legal pattern, counted by biased counting. §3.8, §10 E2303, §18.1 (examples), §18.4, §18.5, Q12, stage 6c, item 15 and the trials updated. |
| 1.3 | 2026-10-09 | Lee's decision on shared nodes under a move: biased counting. §18.2 specifies it (header 16 B hosts / 12 B board, owner test, plain owner count, atomic shared count, negative-count queue with count-only dispatch, merge to shared-only at owner end, crash cleanup maps, cores and `migrate_actor`, immortal interaction, costs); option (b) rejected as copying unchanged nodes, the others marked not chosen; §17.2 overhead table, §17.4, §17.5, §18.3, §18.4 restart row, Q6, Q12, stage 6a/6c, work items 14–15 and the §18.6 trials updated. |
| 1.2 | 2026-10-09 | Q6 decided by Lee: messages move. New §18: language rule (E2301 after any send, no implicit dup across actors), immortal versions, calls/replies/spawn/supervised restart, spec text to change, move trials; new Q12 (`share`). The shared-node counting on a move (§18.2) is listed with Lee's constraint (a move copies no unchanged node) and left open, under discussion with Lee. §1.5, §12, §13, §15, §16, §17.4 updated. |
| 1.1 | 2026-10-09 | Lee's alternative added: counted regions for structure storage (§17); Q2 restructured into (a) arena, (b) counted, (c) hybrid, (d) per-actor arenas, (e) compaction, recommending (c); Q1 and Q6 follow it; §0, §2, §3.1, §7.1, §10 (E2319), §12, §13 (new stage 6) and §16 updated. |
| 1.0 | 2026-10-09 | Initial design: measured state, owned regions vs arenas, linearity rule, lifetime analysis and polymorphism, isolation, drop-based release, bounds, atomics, codes E2300–E2318, staged migration, trials, eleven open decisions. |
