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

**Implementation status (2026-10-16).** Nothing of the design is built. Checked against the tree that day: the
compiler holds no region checker, no `drop` nodes, none of the codes E2300 to E2318, no `alloc_atomic` and no
`atomic_*` operation (§9); `alloc_region` is still called nowhere in the stdlib or the compiler (§1.4); scope
release (`mark`/`release_to`) is still disabled in all four emitters (§1.2); and Phase A of the lifetime analysis
(`check_sequence_return_lifetime`) is still the only lifetime rule. Lee decided Q1, Q2, Q5, Q15, Q16 and Q17 on 2026-10-22 (and Q6 on 2026-10-09, narrowed by Q2 (a), with Q12 withdrawn as moot): never-freed family arenas spelled `arena(L, S)`, no counted storage, so there is no counted-storage stage. The other open decisions of §15 (Q3, Q4, Q7 to Q11, Q13, Q14) are
still open. §1 below was measured 2026-10-09; the function names are still right, but line numbers have
drifted (for example `let_owns_local_region` is now at line 816 of `term_reg_spill.silica`, `fn_destroys_region_param`
at 2389 of `emitter_core.silica`). Re-read 2026-10-16 and still true by reading: H1 (no lock anywhere in
`canonical_arena_runtime_asm.silica`), H2 (`fn_destroys_region_param`), H5 (`LBBra_grow_failed`), H10 (no
`alloc_atomic` in `compiler/src`); H3's staged repro is not in any suite and no fix was looked for; H4 and H6 to H9 were not re-read. Two things changed after the survey: the 2026-10-12 emitter work of §19
(caller-provided result slot in X8, reused state tuples, case-arm tuples built in the reply buffer) and the
board runtime's item B, J and F work in [actor_memory_budget_plan.md](actor_memory_budget_plan.md); neither alters a
hazard above except by removing allocations in the cases §19 lists as fixed. §19 is the one part of the chunk that
was added after the design was written; its zero-growth trials (`actors_addition/zero_heap_growth_*`,
`stack_budget_board_addition/*_frees_heap`) exist as the pattern (not re-run for this note) for the remaining cases, which wait on this
chunk's ownership model.

---

## 0. Summary

The chunk's premise was that 1,152 stdlib records embed a move-only region and must become linear. Measured, they do
not hold owned regions at all. Every standard data structure takes its region from `canonical_arena_lookup(key)`: one
**application-lifetime arena** per structure family, never freed, shared by every value of the family, and by design
(common_contract.md §7) the basis of persistence and constant-time meld. The stdlib contains no `alloc_region`, and
neither does the compiler. Making those records linear would break the structures' contract: 149 trial updater calls
reuse the old version, and `graph_wbt_core@set_entry` reads one record three times. It would also buy no safety, because
an arena that is never freed cannot dangle.

The arena is safe, but it only grows. A 1,000-key map exhausts the ESP32-S3 heap in about 740 updates, and a busy host
grows by tens of MB a second (§17). So the design separates the type `region(L, Space)` into an owned kind and a
structure kind. **Decided by Lee, 2026-10-22: Q2 (a), the never-freed family arena with the atomic bump (stage 0), the handle spelled `arena(L, S)` (Q1 a).** Counted storage was considered and is not part of the plan (§17). Structures therefore still never reclaim memory until a later project:

| Kind | Made by | Handle | Lifetime | Release |
| --- | --- | --- | --- | --- |
| **Owned region** | `alloc_region` | linear (move-only, §4.4.2); every record or tuple embedding one is linear | lexical, by ownership | at the last owner's scope end, or at its actor's end |
| **Structure storage, decided (Q2 a, Lee 2026-10-22): the family arena** | `canonical_arena_lookup` | `arena(L, S)`: copyable, not linear (Q1 a) | application | never (process end) |

The linearity rule holds in full for owned regions and the aggregates that embed them (§3). A structure version is an
`arena(L, S)` handle: copyable, immutable, never freed. Lee's version rules still hold (§3.14): a version is created only
by a change, a change leaves its input valid, and a no-op change returns `:unchanged`. The
stdlib and compiler sources change by script (type spelling, Q1: `region(L, normal)` becomes `arena(L, normal)`). The safety properties of §12 are enforced at
compile time by a new **region checker** pass (§3–§6). Release is driven by explicit `drop` nodes that the SIR
generator places from the checker's ownership facts (§7). Those replace the four emitters' name-independent
heuristics. The run-time checks are the bounds checks that already exist (§8), plus the atomic arena bump that closes
a data race found in this survey (§1.3 H1).

Ten silent hazards were found by reading the code (§1.3). Four of them are live use-after-free or race paths that need
no new language rule, and they are stage 0 of the migration (§13).

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
| **Buffer bounds**, all four emitters | `prims_memory@emit_alloc_buf` (302) stores the element count at `[buf-8]` and rejects a negative count or a multiply overflow (`L_buf_invalid`). `emit_buf_bounds_check` (345) emits `LDR X17,[X1,#-8]; CMP X2,X17; B.HS L_buf_bounds`, inline in `emit_buf_store` (414) and at `term_emit_kind_compound_part2:261` for loads. x86 uses `x86_cmp_branch`; ESP32 aborts inline into `silica_rt_abort_buf_bounds` (`rt_console.S:539`). | process-wide **runtime abort, status 71** (`_silica_rt_abort_with`), even inside an actor. **Decided 2026-10-23 (Q9 a): inside an actor this ends the actor instead (§8); abort 71 stays only in `main`.** |
| Region full | `emit_region_bump_check` (169) calls `L_region_grow` (566), which chains a new block of max(4096, request) on `[r+16]`. ESP32 uses `silica_rt_region_grow` (`rt_heap.S:321`). | abort 71 on allocation failure (hosted `L_region_overflow`; board "heap exhausted"). **Decided 2026-10-22/23: inside an actor the actor ends with `(:explicit, :region_alloc_failed)`; abort 71 stays only in `main` (§8, H5).** |
| Owned-region release: a local | `term_reg_spill@let_owns_local_region` (697; ESP32 833), used by `term_emit_kind_let_top:217` and `…_let_named_tail:223` | `_silica_rt_region_destroy` after the let body, **only** when the body contains no SIR kind-4/5 call at all (`body_has_moving_call`) and the name appears only as an `alloc_*`/`region_*`/`ref_in_region` argument (`region_used_outside_borrow`). Otherwise it leaks. |
| Owned-region release: a parameter | `emitter_core@fn_destroys_region_param` (2376), `region_param_index` (2336), `return_type_carries_region` (2325) | destroys the **first** `region(`-typed parameter (index ≤ 7) at the epilogue when the return type's text has no "region" and the body has no kind-4/5 call. It disables TCO (`tco_eligible` 1665). |
| Fresh let-bound composites (ESP32 only) | `ESP32-S3_raw/terms/term_reg_spill@let_owns_fresh_composite` (696), `fresh_name_moves_in` (666) | frees a `record_make`/`tuple_make` tail block, or a `get_actor_memory_usage` record, at scope end unless the name is moved, rebound or projected to an inline aggregate (budget plan §13). Not in the hosted emitters. |
| Region destroy | `_silica_rt_region_destroy` (mac `prims_actors_runtime_asm:2859`, ESP32 `rt_heap.S:291`) | null is a no-op; a registered canonical arena is left alone (it scans the 512-entry table); otherwise frees the `[r+16]` chain, then the block |
| Canonical arena lookup | `terms/canonical_arena_runtime_asm@_silica_rt_canonical_arena_lookup` | a process-global 512-slot table; it mallocs a 4,128-byte arena on first use and never frees it |
| Actor state and replies | `prims_actors@behaviour_result_move_asm` (573) | shallow shell copy (one word per field) into the running actor's arena on hosted; the ESP32 copies and releases per dispatch (`silica_rt_state_release`, `rt_heap.S:473`) |
| Scope release (`mark`/`release_to`) | `emitter_core` `emit_functions(..., false, false)` (231; aarch64 234, x86 241, ESP32 260) | **disabled** in all four (unsound, memory note 2026-09-04); `prim_allocates`, `body_creates_region` and `_silica_rt_region_release_to` are dead code |

### 1.3 Silent today

Silent means the program runs on and computes with freed, shared or garbage memory.

| # | Hazard | Evidence | Kind |
| --- | --- | --- | --- |
| H1 | **Canonical arenas are process-global and their bump allocation is unlocked.** Two actors updating any structure of the same family (two `wbt_map`s, say) bump the same arena from two threads on hosted, or two cores on the board, and can get the same cell. Arena creation in `_silica_rt_canonical_arena_lookup` is also an unlocked probe-and-insert. | by reading: `canonical_arena_runtime_asm.silica`, `emit_region_bump_check` | data race, corruption |
| H2 | **A region parameter carried away by `cast`, `send` or `spawn` is destroyed by its function.** Those are kind-6 prims, not kind-4/5 calls, so `body_has_moving_call` does not see them. `return_type_carries_region` is false for an `atom` or `actor_ref` result, so `fn_destroys_region_param` frees a region the receiver now owns. (The local-let rule catches this through `region_used_outside_borrow`; the parameter rule has no such check.) | by reading: `fn_destroys_region_param`, `sir_generator/terms/terms_actor_lowering` (cast becomes a prim) | use-after-free |
| H3 | **A let-bound frame aggregate passed by name to a call is not promoted.** It dangles once the caller's frame is reused (memory note 2026-09-08, still true). `arg_aggregate_heap_promote` fires only on a literal `tuple_make`/`record_make` (`term_reg_spill@is_aggregate_make` 946). | by reading; staged repro `wbt_map_tuple_value_escapes_via_let` | use-after-free |
| H4 | **Replies and states live in the replying actor's arena on hosted.** `_silica_rt_actor_dealloc_region` (2571) frees the whole arena when that actor ends, so a caller holding a composite reply from an actor that has since ended (crashed and restarted, or removed) reads freed memory. | by reading: `behaviour_result_move_asm`, `_silica_rt_region_alloc` (2714) | use-after-free, to confirm by trial |
| H5 | **The hosted actor arena returns 0 when it cannot grow** (`LBBra_grow_failed`, 2801), and **hosted `emit_alloc_region` has no null check** after `_silica_rt_raw_alloc`. Both store through address 0 or a small offset. | by reading | silent fault or corruption. **Outcome decided by Lee (2026-10-22, recorded 2026-10-23): a growth or allocation failure ends the actor with `(:explicit, :region_alloc_failed)`, handled by its supervisor; abort 71 only in `main`.** |
| H6 | Lifetimes compare literally, with a binder fallback only on identifier arguments. A free lifetime name accepts any region, so `alloc_ref(r2, …)` typed `ref(L1, …)` passes when L1 is not bound. There is no duplicate-lifetime check, and `fresh_lifetime` lowers to `MOV dest, SP`. | `type_checker_expressions_identifiers:1102–1126` | isolation not enforced |
| H7 | `device_window` lifetimes are erased (`device_window_types_equal_modulo_lifetime`, 793) and the window is not move-only, against spec §4.4.6 and device spec §5.1. Two workers can hold one window. | by reading | spec rule unenforced |
| H8 | Phase A misses `ref?`, records and lists, so `fn f(r: region(L, normal)) -> ref?(L, normal, rec)` and `-> { root: ref(L, …) }` compile without the region. This is generic-module convention 5 in the memory notes ("returning `ref?` is not caught"). | `collect_lifetime_ids_from_ref_types` (601) | dangling reference accepted |
| H9 | Owned-region **leaks** (not safety violations, listed for completeness): any region in a scope that makes any call; every region parameter after the first; a region inside a record or tuple; regions held by an actor that crashes; canonical arenas (by design); hosted strings and `main`'s implicit allocations (never freed); the board's residual 492 B per supervisor cycle (budget plan §13). | §1.2 | leak |
| H10 | `ref(L, atomic, T)` is an ordinary cell: plain `LDR`/`STR`, plus `DMB ISH`/`memw`/`mfence` at function entry, exit and calls. `alloc_atomic` and the `atomic_*` operations of §17 exist nowhere in the compiler. Two actors cannot share an atomic cell anyway, since nothing lets them (§9). | by reading: `prims_memory:231/241`, `control/control.silica:42-85` | spec feature missing |

### 1.4 What the code base actually holds

| Measure | Count | Method |
| --- | --- | --- |
| stdlib modules with a record type that has a direct `region(…)` field | 30 (line grep, reproduces 2026-09-25) / 53 of 54 (bracket-aware scan) | `compiler/stdlib/data_structures/*.silica` |
| such record-type occurrences | 1,161 (line grep: multi-line types only) / **2,239** (bracket-aware, including the single-line graph, heap and priority-queue types) | wbt_map 415, wbt_set 318, graph_dense_core 94, tree_binary 88, graph_wbt_core 77, … |
| `(region(L, normal), ref?(L, normal, rec))` tuples | 34 | allocator helpers |
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
| S1 | §16.3.5 "Message contents are copied between actors" vs §12.1.6 "the same move discipline applies" | copy vs move | **decided 2026-10-09 (Lee): move**; structure versions are copyable arena handles (Q2 a, 2026-10-22) (§18); §18.5 lists the spec text to change as Q6 decides; fix §16.3.5 |
| S2 | §4.4.2 "The function must return the handle to the caller" vs trial `region_move_pass_no_return` (a callee that consumes and releases) | must return vs may consume | Q3 |
| S3 | §12.1.1 "atomic: regions … accessed by multiple actors concurrently" vs §12.1.6 "owned by at most one actor at a time" | sharing | Q7 |
| S4 | §17 examples: function-level `proc[...]` (now E3009), `{ok, …}` record-tag syntax, `alloc_atomic()` with no arguments, `ref(R, atomic, ref(R, normal, …))` (a cross-actor pointer into normal memory) | stale syntax, unsound example | rewrite with §9 |
| S5 | §12.3.3 "trap on out-of-bounds" vs the supervision model ("crash to the supervisor") | process abort vs actor failure | Q9, **decided 2026-10-23 (a): actor failure; abort 71 only in `main`** |
| S6 | §4.4.1 / §12.1.4 "functions may take `L: lifetime` as a parameter for polymorphism" vs the stdlib's implicit `L` | value parameter vs type-level | Q10 |
| S7 | canonical arenas are not in the specification at all (only common_contract.md §7) | undocumented memory kind | §2; spec text after Q1/Q2 |
| S8 | §30 "Advanced Type System" is a placeholder | — | nothing for this chunk; linearity goes into §4.4.2 and §12 |

---

## 2. Memory model

Three kinds of storage, each with one release rule:

| Storage | Holds | Owner | Released |
| --- | --- | --- | --- |
| **Owned region** `region(L, S)` | what the program allocates in it explicitly (`alloc_ref`, `alloc_rec`, `alloc_buf`) | exactly one binding, in exactly one actor (or `main`) | when its owner is dropped (§7). An actor's owned regions that are still live when it ends are released by the runtime (§7.3). |
| **Structure storage** | stdlib nodes | one arena per family, owned by the application (Q2 a, decided 2026-10-22) | never |
| **Actor heap** (implicit) | lists, promoted tuples and records, strings, message copies | the actor | hosted: the actor's arena, freed at the actor's end; board: per block (`silica_rt_free`); `main`: never |

The frame is not storage a value may outlive. Item B and `arg_aggregate_heap_promote` move every aggregate that leaves
the frame into the actor heap, and H3 is the one path that still escapes.

The region checker reasons about **owned regions and structure storage only**. The actor heap is outside the type system; its
soundness is the runtime's (item B, H3, H4), and it is in this chunk only because "ends use-after-free" covers it.

**Decided from the spec, no question needed:**
- Owned region handles are linear (§4.4.2), and so is `device_window` (§4.4.6, device spec §5.1). A record, tuple or
  sum value embedding one is linear (§12.1.6, "any composite … that embeds them under the usual linearity rules").
- A `ref`/`buf` may not outlive its region (§12.1.4, §12.4.2), and in a returned value or a message its region travels
  with it (§12.1.4 scope exit rule, §12.1.6).
- Ownership of an owned region transfers on `spawn` (§12.1.5) and on `call`/`cast` submission (§12.1.6); replies return
  it (§12.1.6).
- Buffer accesses stay checked at run time (§12.3.3). An out-of-bounds write corrupts data, and an out-of-bounds read
  hands a wrong value onward, so both meet Lee's first criterion.

---

## 3. The aggregate linearity rule

### 3.1 Linear types

A type is **linear** if it is, or contains at any depth through record fields, tuple elements and sum variants:
`region(L, S)` (owned), `device_window(L, D)`, or `buf(L, S, T, N)` and `ref(L, S, T)` **when L is the lifetime of an
owned region that is itself carried in the same value**. A `ref`/`buf` alone is not linear: it is a borrowed view, and
§4 checks it by lifetime. Structure handles (`arena(L, S)`, Q1, Q2), scalars, strings, atoms, actor references, lists and function
values are not linear: an arena handle is a copyable word over immutable, never-freed nodes, so it is used, copied and
sent freely.

A list, a generic type argument and a trait's associated type may not be linear (E2307, §3.10–3.11).

### 3.2 Uses

Every occurrence of a binding of linear type is exactly one of:

| Use | Where it occurs | Effect on the binding |
| --- | --- | --- |
| **Borrow** | the region operand of a region prim: `alloc_ref`, `alloc_rec`, `alloc_buf`, `read_ref`, `write_ref`, `buf_load`/`read_buf`, `buf_store`/`write_buf`, `ref_in_region`, `canonical_arena_same`; the window operand of `peek`/`poke` | none: the value stays owned here |
| **Read** of a non-linear field | `x.f` or a destructuring pattern position whose type is not linear | none |
| **Move** | anything else: a user-call argument, a function-value call argument, a return or `produces pure` operand, a record/tuple/sum literal operand, the right-hand side of a binding, a `case` scrutinee, a `spawn` initial state, a `call`/`cast`/`send` message, a behaviour's reply or new state, and `x.f` with `f` linear | the binding is **moved**; any later use is E2301 |

The borrow positions are exactly the prim operands the emitter heuristic already treats as borrows (`rgn_is_region_borrow_prim`).
User functions do not borrow (Q4): a function that inspects a linear value takes it and gives it back.

One expression may not move one binding twice: `f(b, b)`, `(r, r)` and `{ a: r, b: r }` are E2303.

### 3.3 Bindings, rebinding and scope

- Binding `y: T <- x` moves `x` into `y`.
- Silica rebinding of a name (`b <- f(b)`) is a move followed by a fresh binding with the same name: legal, and the
  usual way to thread a value.
- At the end of a binding's scope (the end of its sequence or function body, or of a case arm, §3.6), a binding that is
  still owned is **dropped**: the SIR generator places a `drop` there, and dropping releases every owned region the
  value holds (§7). Dropping is not an error (spec §12.1.2, implicit release at scope exit).
- A parameter is a binding of the whole body. If the function neither returns nor moves it, it is dropped at the end of
  the body, which is today's `region_move_pass_no_return` behaviour. Q3 asks whether that stays legal.

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
| `spawn(state, beh, policy)` | `state` is moved (§12.1.5). Any later use of it, or of a linear part of it, is E2301. This replaces the `"moved_region"` rebinding, and covers records, tuples and any expression holding an owned region. Structure versions in it are arena handles and stay usable. |
| supervised child spec (`init` child list, `add_child`) | the initial state may not be linear (E2308): the supervisor keeps it in its row to restart the child, which would duplicate the owner (§18.4). A worker that needs a region allocates it in its first message, or receives it by message. A structure version (an arena handle) is allowed; each restart reuses the same handle (Q14). |
| `call(a, msg)`, `cast(a, msg)`, `send`, the `_registered` forms | `msg` is moved at submission (§12.1.6, §18). Any later use of a linear value in it is E2301. The runtime transfers ownership of every owned region in it to the receiver (§7.3). Structure versions in it are arena handles, passed by value; the sender keeps its own. |
| behaviour `fn beh(msg: M, state: S) -> (:reply, R, S)` | `msg` and `state` are owned parameters. The reply and the new state are moved out: each linear part of `msg` and `state` must be in the reply, in the new state, moved elsewhere, or dropped, and in at most one of them: an owned region in both the reply and the new state, or in a message and the new state, is E2303. A structure version is an arena handle and may be in both (§18.1). The usual threading is `(:reply, x, (r2, k + 1))`. |
| a `call`'s result | moved to and owned by the caller's binding (§12.1.6). |
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
passes the accumulator around. Allowing linear instantiation would need a linear-aware generic checker, which Q11
defers. Trait methods take the trait type, which (after Q1) holds an arena, so traits are unaffected.

### 3.11 Lists

`List[T, mem(S)]` with `T` linear is E2307. A list shares its suffixes (copy-on-write prepend), so two lists could own
one region.

### 3.12 Recursion and tail calls

A recursive call that passes the region on is a move, so no drop is placed after it, and the tail call stays a tail
call. `tco_eligible` loses its region exclusion once drops replace `fn_destroys_region_param` (§7.4).

### 3.13 Worked examples

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
        a: actor_ref <- spawn((r, 0), beh, stack_policy(0, :keep_last_message));   // (r, 0) moved
        v: int64 <- call(a, 1 impl ActorMessage {});
    produces pure v end
}
```

Writing `alloc_ref(r, 5)` after the `spawn` is E2301 ("r was moved into spawn"). That is the case
`enrich_env_for_actor_spawn` catches today only as a generic E2003.

Structure versions are `arena(L, S)` handles, which are copyable, so a change leaves its input usable and a version may be bound again (§3.14):

```silica
        m0: { root: ref?(L, normal, rec), …, region: arena(L, normal), … } <- wbt_map@empty(…);
        r1: :unchanged | (:inserted, { … }) | (:replaced, { … }) <- wbt_map@insert(m0, 1, 10);   // m0 is unchanged and still valid
        old: int64 <- wbt_map@size(m0);
        kept: { … } <- m0;                                                                      // a copy of the handle
        again: int64 <- wbt_map@size(m0);                                                       // legal
```

### 3.14 Structure versions: arena handles, and only a change makes one

**Lee's version rules (2026-10-09, option A), as they stand under Q2 (a), 2026-10-22.**
- A structure version is a record holding an `arena(L, S)` handle (Q1). It is **not linear**: binding, storing,
  copying, passing on, returning and sending it are legal and create nothing, because the nodes are immutable and live in
  a never-freed arena. No count, no `dup` and no ownership check applies to a version.
- A new version is created **only by a change**: insert, update, delete, meld and the like.
- **A change does not consume its input.** After `r <- wbt_map@insert(v1, k, x)`, v1 is still a valid version. A real
  change yields a new version v2 that shares v1's unchanged nodes. Persistence is observable.
- **A no-op change returns `:unchanged`, not a version.** Inserting an identical entry, deleting an absent key, melding
  with an empty heap and the like produce no version at all. The program carries on with v1: no copy and no run-time
  check.

**Not scheduled.** Moving the stdlib's change results to the shapes below (367 updaters, about 300 caller sites in
`trials/` and 55 in the compiler) is an API change that no stage of this plan carries; it was part of the removed
counted-storage stage. The rules above stay as the design of the result shapes, for whenever it is scheduled.

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

**Recommendation: A (Q10).** Implementation: in the call checker (`type_checker_expressions_user_call_check_args_result`)
build one substitution per call: callee lifetime name → caller lifetime. Unify every argument against it, and a
conflict is **E2311** ("lifetime L of push is bound to both L1 and L2"). Apply the substitution to the result type.
`types_equal_surface` keeps comparing literally *after* substitution, so the change is local to call sites,
tuple-decomposition of call results (`tuple_decompose_helpers:819`) and the identifier binder fallback, which this
replaces. `fresh_lifetime()` keeps its role of naming a local lifetime. Its `MOV dest, SP` lowering becomes dead code
and can be removed.

---

## 6. Region isolation

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
| `device_window` | no code (unmapping is not specified); the checker still enforces single ownership |

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

**Recommendation (Q5).** Every owned region's header carries a doubly linked owner link (two words: header 32 → 48 bytes)
on its owning actor's region list, rooted in two new ACB words (`main` has a static root).

- `alloc_region` links the region into the current actor's list; `_silica_rt_region_destroy` unlinks it.
- Message submission (`call`/`cast`/`send`) and `spawn` move every owned region in the payload: the compiler emits,
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
sharing. Q7 settles which way the language goes.

| | Model | Consequence |
| --- | --- | --- |
| A | **Shared atomic regions.** `region(L, atomic)` is an application-lifetime region like an arena: copyable handle, may go in messages and spawn state, never released. Only `ref(L, atomic, T)` cells live in it, with `T` a word scalar (`int64`, `uint64`, `int32`, `uint32`, `boolean`, `atom`); a pointer into normal memory may not be stored (E2316). | the one place actors share mutable memory, and only through atomic operations. The lock-free stack of §17 (an atomic cell holding a ref into a normal region) is rejected and is removed from the spec. |
| B | Atomics only within an actor's owned region | sound and simple, but an atomic cell then has no second party except interrupts and DMA (chunk 14) |
| C | Remove atomics from the language until chunk 14 | the 62 trial files and §17 go |

**Recommendation: A**, created by `alloc_region(atomic)`. Allocation into a shared atomic region uses an atomic bump
(below), because several actors may allocate.

### 9.2 Surface (Q8)

Recommended, to keep the 44 run trials and Silica's current style (atoms, tagged tuples, no conversions):

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
scheduler lock pattern) or are rejected by the ESP32 emitter. Recommend the spinlock, so one program means one thing
on every target.

The function-level `DMB ISH`/`memw`/`mfence` barriers that `mem(atomic)` adds today (`control/control.silica`,
`effects/emitter_effects`) become redundant once each operation carries its own ordering, and are removed.

### 9.4 The same bump fixes H1

Canonical arena allocation (`alloc_rec`/`alloc_ref` into an arena) switches to the atomic bump, and
`_silica_rt_canonical_arena_lookup`'s insert becomes a compare-and-swap on the key slot. That is stage 0 (§13). It
costs one atomic RMW per stdlib node allocation, which is uncontended in the common case.

---

## 10. Error codes

`E23xx` is unused (registry and sources). The block `E2300–E2318` becomes the region-safety family, next to the
device family (E22xx). The type checker's "reference outlives region" moves from E2100 to E2300, which leaves E2100 with
its one registered meaning. E2319 and E2320, drafted for counted storage, were removed in revision 1.9 and their numbers are not reused.

| Code | Name | Raised when | Phase |
| --- | --- | --- | --- |
| E2300 | ReferenceOutlivesRegion | a returned, sent or spawned value holds `ref`/`ref?`/`buf` of lifetime L without `region(L)`, L not an arena lifetime (§4) | region checker (moved from type checker E2100) |
| E2301 | UseAfterMove | a linear binding used after it was moved (names the move's line and, for case, the arm) | region checker |
| E2302 | ReferenceAfterRegionGone | a `ref`/`buf` of lifetime L used after L's region was moved out or dropped | region checker |
| E2303 | LinearMovedTwice | one expression moves one binding twice; or a linear value (an owned region) is both kept in an actor's new state and given away as its reply or in a message (§18.1) | region checker |
| E2304 | PartiallyMovedValueUsed | whole use, or second move, of a record or tuple after a linear field was moved out | region checker |
| E2305 | RegionParameterNotReturned | reserved for Q3 option "spec-strict"; unused under the recommendation | region checker |
| E2306 | LinearCapture | a function literal captures a linear binding | region checker |
| E2307 | LinearTypeArgument | a linear type as a list element type, generic type argument or associated type | type checker |
| E2308 | LinearRestartableState | a supervised child spec's initial state is linear (§18.4) | type checker (`type_checker_supervisor`) |
| E2309 | DuplicateLifetime | two live owned regions share a lifetime name | region checker |
| E2310 | CrossRegionReference | `alloc_*` result L differs from the region's L, or a ref of L2 is stored in region L1 (L2 not an arena) | type checker |
| E2311 | LifetimeConflictAtCall | one callee lifetime bound to two caller lifetimes | type checker (call checker) |
| E2312 | ArenaSpaceMismatch | reserved: arena space differs from the record's declared space (Q1 implementation detail) | type checker |
| E2313 | BufferLengthMismatch | `alloc_buf` literal size ≠ literal N | type checker |
| E2314 | BufferIndexOutOfRange | literal index ≥ literal N, or negative | type checker |
| E2315 | AtomicOperandNotAtomic | `atomic_*` on a non-atomic ref | type checker |
| E2316 | AtomicCellType | atomic cell type not a word scalar | type checker |
| E2317 | AtomicOrderingInvalid | ordering not a literal atom, or illegal for the operation | type checker |
| E2318 | ComparisonOnRegionType | `==`/`!=`/ordering operators on region, arena, ref, buf or device_window | type checker |

Run-time outcomes, not codes (decided 2026-10-23): buffer bounds, invalid size and list index (actor failure `(:explicit, :buf_bounds)` /
`:buf_invalid` / `:list_index` per Q9), region growth failure and H5's null paths (actor failure `(:explicit, :region_alloc_failed)`); each is abort 71 only in `main`.

E2313 *BufferLengthMismatch* and E2314 *BufferIndexOutOfRange* (§8, spec §12.3.3) are registered in `compiler/error_codes.md` and `error_codes.jsonld`.

Each message carries `spec:§4.4.2`, `§12.1.4`, `§12.1.6`, `§12.4.1`, `§12.3.3` or `§17` and the standard metadata
block (spec §1.6), like every other code.

---

## 11. Where the checks run

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
| **Growable actor stacks** (chunk 1, board item F) | stacks are released at the message boundary, so nothing may point into a stack across it. Regions are heap blocks, and a handle in a frame slot is fine. Aggregates rely on item B and H3's fix. A crash mid-behaviour leaves owned regions in frame slots, which §7.3's owner list reclaims. |
| **Actor messages and replies** | moves (Q6, decided 2026-10-09; §18). Owned regions move by pointer plus owner transfer (§7.3). Structure versions are arena handles passed by value (Q2 a). Plain immutable values are copied into the receiver; the H4 case needs the targeted stage 0 fix. |
| **Supervised restart** | E2308 keeps owned regions out of child specs. |
| **FFI** (dangerous actors) | E2101–E2103 stay as they are. The region checker treats `external_danger` regions as ordinary owned regions, and the taint checker's "only into actor state or an FFI result cast" is stricter, so the two compose. Chunk 13 inherits §8's length-word contract for `buf(L, S, uint8, N)`. |
| **Device windows** | linear (§3.1). The `spawn_device` initial state moves the window. A window message is an explicit ownership transfer (device spec §5.1–§5.2). DMA buffers moved to the worker and back (device spec §5.3) are ordinary linear region moves, which this chunk finally enforces. Window lifetimes are no longer erased (H7). `peek`/`poke` borrow. |
| **Board memory** | an owned region's first block is 4,128 B on every target (`emit_alloc_region`), 1.2% of the board's 354,816-byte heap per region. Proposal (decidable without Lee): a per-target first-block size, 512 B on `ESP32-S3_raw`, growing as now. The owner links add 16 B per region. Canonical arenas are 4,128 B each on first use and are never freed; nine families means ≤ 37 KB on the board if all are used. Worse, they only grow: a 1,000-key map updated ten times a second exhausts the heap in about 74 s (§17). Q2 (a) (2026-10-22) keeps the arena, so a long-running board app that updates a structure still exhausts the heap until a later project. |
| **Chunk 9** (networking) | received bytes arrive in `buf(L, S, uint8, N)`. §8 gives the bounds check, and an overrun fails the connection's actor (Q9), not the server. |
| **Chunk 13** | depends on §8 and on Q9's failure outcome for `recreate`'s limit checks. |
| **Chunk 2** (carriers) | owner lists are per actor, not per thread, so carriers change nothing. H1's fix is needed either way. |

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
| **0. Silent hazards** | H1 atomic arena bump and CAS arena insert (§9.4); H2 count `cast`/`send`/`spawn`/`call` prims as moving in the existing heuristics (interim, removed at stage 4); H3 promote let-bound frame aggregates passed by name (wire the staged trial); H5 null checks, ending the actor with `(:explicit, :region_alloc_failed)` (abort 71 in `main`; Lee, 2026-10-22); renumber the region meaning of E2100 to E2300 | no | the hazard trials of §14.2 fail before and pass after; fixed points |
| **1. Lifetime polymorphism** | §5 option A: per-call substitution, E2311 | yes, relaxing only (accepts more) | trials that spell a generic `R` pass; the `L1` workaround comments go from the trials; fixed points. Nothing in the compiler's source needs it. |
| **2. Structure handle type** | the handle spelled `arena(L, S)` (Q1 a, Q2 a, decided 2026-10-22; not linear, accepted by the allocation prims, obtained from `canonical_arena_lookup`): type checker, interner, SIR, emitters. No cell is ever freed, so run-time behaviour is today's arena exactly and the fixed points cannot move. The constructors' `canonical_arena_lookup` result is accepted into the new type, and during the transition also into a `region` binding (a named transition rule, removed at stage 5). Specification addition S7. **Publish.** Then a script renames the stdlib's handle fields from `region(L, normal)` to `arena(L, normal)` and rewrites the allocator tuples (2,239 record types, 34 tuples, the `x.region` lets) and the 25 compiler modules' inline map types, verified with `git diff`, not the masked regex view (memory note). | yes | stdlib, `ordered_data_structures` and the compiler build; fixed points with the rewritten source |
| **3. Region checker, report-only** | §11 checker behind a `silica.config` switch (`region_check: report`), writing `<unit>.regions` reports, no diagnostics, so no golden changes. | no (reports only) | reports over the stdlib and the compiler show **no linear misuse**; reports over `trials/` are reviewed, and every entry is either a real misuse (it becomes an error trial in §14) or a checker defect (fixed). Board trial sources are included. |
| **4. Drops and owner lists** | §7.1 `drop_owned` in SIR and emitters for owned regions; remove the heuristics; §7.3 runtime owner lists and transfers; the per-target first-block size; **message regions (§18.7):** `drop_owned` at behaviour return for a message's owned regions unless they flow into the new state, partial move out of a message record, `copy_to`, release on a failed send, reply regions dropped for a dead or timed-out caller, and the actor-end walk covering the unprocessed mailbox | no (`copy_to` is a new compiler builtin `copy_to(region, value)` derived per type like `recreate`, Q15 decided 2026-10-22) | §14.2 release trials (write-every-page) on every host and the board; the message-region trials of §18.6 (`message_region_released_at_dispatch_end` and the others except the chunk-11 one); `memory_region_addition` and `actors_addition` unchanged; `.ascomp` goldens refreshed only where `.sout` = `.scout`; fixed points |
| **5. Errors on** | `region_check` defaults to `error`; the transition rule from stage 2 is removed; E2300–E2318 error trials wired | yes | the compiler's own source passed stage 3 clean, so it builds; fixed points; the error suite is green on the three hosts |
| **7. Atomics** (after stage 1, parallel to 3–6) | §9: builtins, lowering on four targets, shared atomic regions per Q7 | yes | the atomic run trials plus two-actor counter and CAS trials on the hosts and both board cores |
| **8. Bounds outcome and static buffer checks** (any time after 0) | Q9 actor failure (decided 2026-10-23: `:buf_bounds`, `:buf_invalid`, `:list_index`; abort 71 only in `main`); E2313/E2314; `\|bounds:` removed | yes (E2313/E2314) | §14 trials |

Stages 0, 1 and 8 do not depend on the open decisions. Stage 2 needed Q1 and Q2 (decided 2026-10-22: `arena(L, S)`); stage 4 needed Q5 (decided 2026-10-22, with Q15 to Q17); stage 5 needs
Q3/Q4/Q11; stage 7 needs Q7/Q8. There is no stage 6: the counted-storage stage was removed under Q2 (a) (2026-10-22), and the numbers 7 and 8 are kept so that references stay stable. The ROADMAP gate ("enforced at compile time or halted at run time, never silent;
the linearity rule holding for a region in a record or tuple; trials; stdlib and compiler at their fixed points under it")
is met at the end of stage 5 plus the targeted stage 0 fix for H4 named in participate.md. Structures do not reclaim memory, and stage 7 closes
"atomic references".

---

## 14. Trials

### 14.1 Error trials (misuse catalogue)

Each case is one `.silica` + `.golden_fail` under `trials/error_enforcement_addition/`, golden re-derived from real output.
A construct that the bootstrap compiler rejects in a batch goes into its own `compile_defects_<slug>_addition` directory
(memory note: a rejected unit aborts a suite's batch compile).

| Code | Cases (one trial each) |
| --- | --- |
| E2301 | region used after move into a call; after `spawn` state; after `cast` message; after `call` message; after return in one arm, used after the `case`; record holding a region moved twice in sequence; tuple holding a region used after destructure; device_window used after `spawn_device`; parameter used after passing on; rebinding inside a `case` arm, used outside |
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
| E2301, E2303 (moves) | the message-move cases of §18.6: an owned region, or a record holding one, used after `cast`, `call`, `send`, `spawn`; sent in one arm and used after the `case`; replied and kept in the new state; `cast(a, (r, r))` |

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
| `region_moved_between_actors` | an owned region in a `cast` written by the receiver; the sender's list no longer holds it (released once, at the receiver's end) |
| `generic_lifetime_name` | a callee spelled `region(R, normal)` called with `region(L1, normal)` (stage 1) |
| `buf_bounds_ends_actor` | Q9: an out-of-bounds write in a worker ends the worker, the supervisor restarts it, `main` continues |
| atomic: `atomic_counter_two_actors`, `atomic_cas_loop`, `atomic_orderings`, on hosts and the board's two cores | §9 |
| `device_window_moved_once` (board) | window moved into a worker, used there |
| `no_op_change_returns_unchanged` | per family: identical insert (map, set), delete of an absent key/item, meld with an empty heap, pop of an empty heap, skew-list update out of range, tree replace with the same subtree, graph remove of an absent edge and add of an existing vertex; each returns `:unchanged`, the program carries on with v1 and its contents are intact; no node is allocated (allocator probe). Waits on the result reshaping of §3.14, which no stage carries. |
| `change_result_variants` | every tagged alternative of §3.14's result table matched by destructuring (`(:inserted, m2: …)`, `(:replaced, …)`, `(:popped, item, h2)`, `:incompatible`, `:overflow`, `:rejected`), with the old version still used after the match |
| `persistence_old_versions_valid` | `bt_persistence_sharing` and `bo_old_heap_valid_after_pop` shapes under the stage-5 checker: old versions stay valid after changes |
| `no_op_change_on_moved_version` | the same no-op changes on a version received from another actor: `:unchanged`, and the sender's copy of the handle is untouched |
| move trials of §18.6 | `reply_and_keep_same_version`, `move_reply_version`, `move_map_of_sets`, `supervised_child_restarts_with_version`, `move_two_cores` (board), and the owned-region trials listed there |

Each existing `region_move_*` and `region_local_release` trial keeps its output through stage 4.

---

## 15. Open decisions for Lee

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

**Q2. How are the standard data structures stored, and is their memory ever given back? — Decided by Lee, 2026-10-22: (a), the never-freed family arena with the atomic bump (stage 0).** Counted storage (biased counting, a size-class allocator, counted list chunks, change-result reshaping at the counted level) is not part of this plan and its design was removed from this document (§17). Consequences: stage 2 spells the handle `arena(L, S)`; structures still never reclaim memory (a 1,000-key map exhausts the ESP32-S3 heap in about 740 updates, a busy host grows by tens of MB/s) until a later project; H4 (replies in the replier's arena) now needs the targeted stage 0 fix already listed in participate.md; biased counting is not needed.
The options considered (§17):
- (a) **Never-freed family arena**, as today: one process-global arena per structure family, with an atomic bump
  (stage 0). Simple and fast, with O(1) meld within a family. Nothing is ever reclaimed.
- (b) **Counted regions**: each node a small region with a count; memory returns when the last version goes.
- (c) **Hybrid:** (b) by default, plus an immortal constructor per family.
- (d) Per-actor arenas freed at actor end: reclaims only on actor end or restart. A long-running actor still grows.
- (e) One owned region per structure with explicit `compact`: reclamation by hand, and versions die at each compaction.
Lee chose (a).

**Q3. May a function consume a region parameter without returning it?**
(a) Yes: an unreturned, unmoved parameter is dropped and released, as `region_move_pass_no_return` expects today.
(b) No, per §4.4.2's "must return": E2305.
*Recommend (a)*, rewording §4.4.2 to "must return it if the caller is to keep it". Releasing is a legitimate end of
ownership, and locals already drop.

**Q4. Should user functions be able to borrow?** (Structure versions are copyable arena handles and need no borrowing, §3.14. The question is for owned regions.)
(a) No. Only the region prims borrow, and a function that inspects a linear value takes it and returns it.
(b) A parameter marker for a borrowed linear value.
*Recommend (a)* for chunk 4. After Q1 the stdlib's 921 queries take arena records, which are copyable, so the pressure
for borrowing is gone. Revisit if real owned-region code shows the threading to be a burden.

**Q5. Who releases the owned regions of an actor that ends? — Decided by Lee, 2026-10-22: (a), a per-actor runtime owner list, ownership transferred on message and spawn (§7.3).** It covers locals at a crash, queued mailbox messages and failed sends.
(a) A per-actor runtime owner list, with ownership transferred on message and spawn (§7.3). (b) A compiler-generated
destructor of the state type. (c) Nobody: they leak until process end.
*Recommend (a).* Only it covers regions held in locals at a crash.

**Q6. Messages: move or copy? — Decided by Lee, 2026-10-09: move; narrowed by Q2 (a), 2026-10-22.** An owned region carried by a message, reply or spawn state is moved, and the sender may not use it afterwards (E2301).
- Every move is an O(1) handle transfer (§7.3).
- Structure versions are `arena(L, S)` handles (Q1, Q2 a): copyable words over immutable, never-freed nodes. A send passes the handle by value and the sender keeps using its own. Nothing is counted (the biased-counting design of 2026-10-09 was removed with the counted-storage stage, §17).
- Plain immutable values are copied by the runtime. H4 (a reply in the replier's arena) needs the targeted stage 0 fix.

Spec changes: §18.5.


**Q12. How does a program send a version it also keeps? — Withdrawn 2026-10-22: moot under Q2 (a).** Lee decided on 2026-10-09 that there is no `share` builtin and that keeping and giving away one version is E2303. That rule existed because a counted version had exactly one handle. An arena handle is a copyable word, so there is nothing to share and nothing to forbid: a version may be kept in the new state and also replied or sent. E2303 keeps its other meanings (one expression moving a binding twice; an owned region both kept and given away), where the second use really is a second owner.


**Q13. Reading a version stored inside a structure** (a graph's inner adjacency set from `get`). *Open, narrowed by Q2 (a).* The stored inner version is an arena handle, so `get` can return it by value and nothing is aliased. (a) return the handle (a value like any other); (b) only queries over inner structures (`has_edge`, `neighbors`), never the inner version itself. *Recommend (a)* now that the aliasing worry is gone; (b) is what the graph traits already present.


**Q14. May a supervised child's initial state hold a structure version?** *Open, narrowed by Q2 (a).* A version is an arena handle, and the arena is never freed, so the supervisor's row can keep the handle and every restart reuses it. (a) yes, with no new rule; (b) no, E2308 extends to versions. *Recommend (a).* E2308 stays for owned regions (linear, so the row would duplicate the owner).


**Q7. May two actors share atomic memory?**
(a) Yes: `region(L, atomic)` is application-lifetime and copyable, and holds only word-scalar atomic cells.
(b) No: atomics stay within one actor's owned region. (c) Remove atomics until chunk 14.
*Recommend (a)* (§9.1). It is the only form in which atomics do anything, it keeps pointers into normal memory out of
shared cells, and it amends §12.1.6's "no cross-actor sharing" with one named exception.

**Q8. What is the atomic surface?**
*Recommend* §9.2: no `alloc_atomic` (`alloc_ref` into an atomic region); `read_ref`/`write_ref` on atomic refs mean
`:seq_cst`, which keeps the 62 trial files valid; four `atomic_*` builtins with literal atom orderings; tagged-tuple CAS
result. The alternative is spec §17 as written, with `alloc_atomic`, bare ordering identifiers and a record-tag CAS
result.

**Q9. What does an out-of-bounds buffer access do? — Decided by Lee, 2026-10-23: (a); it covers the invalid buffer size and the list-index failure too, and (2026-10-22) region growth and raw allocation failure (H5) with `(:explicit, :region_alloc_failed)`.**
(a) End the actor (`(:explicit, :buf_bounds)`), handled by its supervisor, and abort 71 only in `main`. (b) A
process-wide abort 71, as today.
*Recommended (a), chosen*, per "crash to the supervisor". The access is still never performed, so no data is corrupted. It
applies to `L_buf_invalid` and to the list-index abort by the same reasoning, which is worth deciding together.

**Q10. How is lifetime polymorphism spelled?**
*Recommend* implicit per-signature quantification (§5 A). The alternatives are spec §12.1.4's `L: lifetime` value
parameters, or bracket generics. Either way §4.4.1/§12.1.4's sentence changes.

**Q11. May a linear type instantiate a generic type parameter?**
(a) No (E2307). (b) Yes, with a linear-aware generic checker.
*Recommend (a)* now. No stdlib or compiler code needs it.

**Q15. How is `copy_to` spelled? (§18.7) — Decided by Lee, 2026-10-22: (a), a compiler builtin `copy_to(region, value)` derived per type like `recreate`; no copy for `device_window` or atomic cells.** (a) A compiler builtin `copy_to(region, value)`, derived per type
like `recreate`. (b) A derived trait method (a `Copyable` trait beside `Recreatable`), so a library type may refine
it. *Decided (a).* The builtin is the smaller change; the trait follows the FFI wrapper spec's `Recreatable` precedent and
lets a type reject the copy. Either way a `device_window` and an atomic cell have none.

**Q16. May a behaviour move a whole received region into its state? (§18.7) — Decided by Lee, 2026-10-22: (a), yes (the state owns it, no drop, O(1)).** (a) Yes: the state owns it, no drop, O(1).
(b) No: only `copy_to`. *Recommend (a)*: it keeps the move O(1) and is the same ownership transfer as the send. The cost
is that state may then hold a region that grows with each message, which is the program's choice.

**Q17. Who owns a region when a send fails? (§18.7) — Decided by Lee, 2026-10-22: (a), the runtime releases the region on a failed send; a sender that needs the data copies first.** (a) The runtime releases it on the failed send (the sender's use
is already E2301). (b) The sender keeps ownership on `actor_not_found`, which contradicts the static moved rule and
would make a region both moved and not moved after the call. *Recommend (a).* Lee chose (a).

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
| 6 | 2 | `arena(L, S)` (Q1 a, Q2 a, decided 2026-10-22) through lexer/parser (if needed), interner, type checker, SIR, emitters, no cell ever freed; transition rule | **Fable** |
| 7 | 2 | stdlib and compiler-source rewrite script: exact-token rewrite of handle field types and allocator tuples only, verified with `git diff` per file, the count reconciled against §1.4's 2,239 | Opus (script), Sonnet (run and verify) |
| 8 | 3 | `region_checker/` (ownership state, lifetime liveness, report mode, `silica.config` switch) | **Fable** |
| 9 | 3 | report collection over stdlib, compiler and `trials/`; triage into misuse vs checker defect | Sonnet |
| 10 | 4 | `drop_owned` placement in SIR; lowering in four emitters; removal of the heuristics and dead scope-release code; owner lists, transfer and actor-end walk in four runtimes (the walk covers the unprocessed mailbox, §18.7); per-target first-block size; dispatch-end drops for message regions, the partial-move rule, `copy_to` derivation, region release on a failed send and for a dead or timed-out caller (§18.7) | **Fable** |
| 11 | 4 | release trials (write-every-page), `crashed_actor_regions_released`, `region_moved_between_actors`, and the message-region trials of §18.6 (§18.7; the timed-out-call trial waits on chunk 11) | Opus |
| 12 | 5 | switch to errors; E2300–E2318 messages and metadata; `error_codes.md` and `.jsonld` entries | **Fable** (code); Sonnet (registry text) |
| 13 | 5 | the §14.1 error catalogue, goldens re-derived from real output | Opus (sources), Sonnet (goldens) |
| 14 | 7 | atomic builtins in the checkers and SIR; lowering in four emitters; ESP32 64-bit spinlock path; removal of the function-level barriers | **Fable** |
| 15 | 7 | atomic run and error trials, two-core board runs (console-only) | Opus / Sonnet |
| 16 | 8 | actor-failure outcome for bounds, invalid size, list index and region allocation failure; E2313/E2314; `\|bounds:` removed (done) | **Fable** |
| 17 | all | spec text: §4.4.1–§4.4.2, §12.1.2–§12.1.6, §12.3.3, §12.4, §16.3.5, §17 rewrite, arenas (S7), per decisions; `region_memory_safety_todo.md` closed with a pointer here; ROADMAP status | main session or Sonnet |

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

**Chosen by Lee, 2026-10-22: Q2 (a), the never-freed family arena with the atomic bump of stage 0, handle `arena(L, S)`
(Q1 a).** Counted storage (b, c) is not part of this plan. Its design (per-node counts, biased counting across actors,
a per-actor size-class allocator, counted list chunks, benchmarks and migration estimates) was in revisions 1.1 to 1.8 of
this document and was removed in 1.9; version control holds it if the project is reopened. What stays true:
- structures never reclaim memory until a later project, and the figures above are the cost;
- H1's atomic arena bump is permanent, not interim;
- H4 needs its targeted stage 0 fix;
- moves of structure versions are handle passes (§18).

## 18. Messages move: what a move means (Q6, decided)

**Lee's decision, 2026-10-09:** when a message carries a data structure, it is a **move**, not a copy. Since Q2 (a) (2026-10-22) a structure version is a copyable arena handle, so the move applies to owned regions and a version handle is passed by value. The specification
conflict S1 resolves toward §12.1.6.

### 18.1 The rule at the language level

A value given to any actor-boundary operand is **moved**:
- a `cast`, `send` or `call` message, and the `_registered` and `_dangerous` forms;
- a behaviour's reply and its new state;
- a `spawn` initial state.

For the classes of §3.1 this means:

| Class of the value | After the send |
| --- | --- |
| linear (owned region, `device_window`, aggregates embedding them) | E2301 on any later use (already §3.8) |
| structure versions (`arena(L, S)` handles, and records, tuples and lists holding them) | usable. A handle is a copyable word over immutable, never-freed nodes; the receiver gets a copy of it and the sender keeps its own. |
| plain values (scalars, atoms, strings, actor references, records/tuples/lists of those) | usable. They are immutable, so a move and a copy cannot be told apart. The runtime copies them into the receiver; the copy out of the replier's arena is the targeted stage 0 fix for H4. |


**No use after a send (Lee, 2026-10-22).** It is a compile error, **E2301**, for the sender to do any work with a region
after it has been sent. "Work" is any use: read, write, pass to a call, return, store in state, send again. The rule
holds for a region by itself **and** for a region contained in anything else (a record, tuple, list, structure
version, closure or any aggregate embedding one), and it holds however the region is reached afterwards: through a
name bound to the aggregate, through a field read from it, or through a copy of the handle. It applies to every
actor-boundary operand of this section, not only `cast`, `send` and `call`: a **reply** and a **spawn initial state**
(and a behaviour's new state, once it has been moved out) are sends in the same sense. The error trials are listed in
§18.6 (`send_then_use_*`).

The lifetime of a moved owned region after it arrives, and how a receiver keeps data past the dispatch, are in §18.7
(Lee, 2026-10-22): the regions are dispatch-scoped, and keeping anything is explicit.

**Versions (Q2 a, 2026-10-22).** A send, a reply, a spawn state and a new state pass a version's handle by value. Only a
change makes a version (§3.14). Keeping a version in the state and also replying with it or sending it is legal, so E2303 does
not apply to versions (Q12 is withdrawn); it applies to owned regions, whose second use would be a second owner:

```silica
fn beh(msg: int64, state: { root: ref?(L, normal, rec), …, region: arena(L, normal), … })
    -> (:reply, :unchanged | (:inserted, { … }) | (:replaced, { … }),
                { root: ref?(L, normal, rec), …, region: arena(L, normal), … }) {
    sequence proc[mem(normal)]
        r: :unchanged | (:inserted, { … }) | (:replaced, { … }) <- wbt_map@insert(state, msg, 0);
    produces
        pure (:reply, r, state)          // legal: reply with the change result, keep v1 = state
    end
}
```

```silica
        pure (:reply, state, state)      // legal for a version handle; E2303 if `state` held an owned region
```


### 18.2 Shared nodes under a move

Nodes of a structure version live in a never-freed arena and are immutable, so any number of actors may hold versions
that share nodes. There is nothing to count and nothing to free: no owner, no merge at actor end, no crash cleanup of
references. The only shared mutable state is the arena's bump pointer and insert table, which stage 0 makes atomic (H1).

### 18.3 Arena versions under a move

A move of a version is a **handle pass, O(1)**, like every move. Two actors on different cores may derive versions from
one lineage concurrently; both allocate from the family arena with the atomic bump.


### 18.4 Calls, replies, state, spawn and supervised restart

| Operand | Semantics | Checker |
| --- | --- | --- |
| `cast(a, m)`, `send(a, m)` | `m` moved to the receiver at submission, O(1); version handles in it are passed by value | later use of a linear part of `m` is E2301 |
| `call(a, m)` argument | as `cast` | as `cast` |
| `call` reply `(:reply, r, s)` | `r` moved from the callee to the caller, by the same transfer; the caller's binding owns it | an owned region in both `r` and `s` is E2303; a version handle may be in both |
| behaviour new state `s` | stays in the actor: no transfer, no walk | the state's linear parts must each end in exactly one of reply, new state, a send, or a drop |
| `spawn(st, beh, policy)` | `st` moved to the new actor at spawn, O(1) | later use of a linear part is E2301 (replaces `"moved_region"`) |
| owned regions in a `cast`/`send`/`call` message or a reply | moved on send (O(1) handle transfer); **dispatch-scoped** in the receiver: dropped at behaviour return unless moved into the new state, or the needed part is rebuilt with `copy_to`. Failure paths (dead receiver, timed-out call, dead caller, crashed receiver with queued messages) release the region in the runtime. All in §18.7 | E2301 for the sender's later use; `drop_owned` placed at behaviour return; lifetime error for a message ref stored into state without `copy_to` |
| supervised child spec initial state | an owned region may not be in it (E2308): the supervisor's row keeps the initial state to restart the child, which would duplicate the owner. A structure version may (Q14, open, recommended yes): the row keeps the arena handle and every restart reuses it. | E2308 for an owned region. The `init` code that builds the spec moves its owned values into the spec, and later use is E2301. |

### 18.5 Specification text to change (not edited here)

| Section | Change |
| --- | --- |
| §16.3.5 "Isolation: Message contents are copied between actors" | "Message contents are moved: the sender may not use a moved value afterwards (E2301). Immutable plain values are indistinguishable from copies; owned regions change owner; structure versions are arena handles passed by value." |
| §12.1.6 | extend from regions to data structures: a version handle is copied on `call`, `cast`, `send` and reply, and the nodes it reaches are shared, immutable and never freed; owned regions move |
| §12.1.5, §15.1.1 "Region handles in initial state" | owned regions in a spawn initial state move; structure version handles are copied |
| §15.4 child specs (`initial_state` in rows, §15.4.12) | a supervised child's initial state may not contain an owned region (E2308) |
| §16.3.5 "Immutability" | unchanged; add that a moved message is owned by the receiver from submission |
| §15.1.1 "State Semantics" and §12.1.6 replies | one owned region may not be both kept in the new state and given away as the reply or in a message (E2303); a structure version handle may |
| common_contract.md §6–§7 | a change borrows its input version and returns `:unchanged` or a tagged new version (§6's "a no-op may return the identical root" and its flags give way to the result sums of §3.14); a version sent to another actor is a copy of the handle, and both actors may keep using it |

### 18.6 Trials for moves

**Error trials** (added to §14.1's catalogue):

| Code | Case |
| --- | --- |
| E2303 | an owned region kept in the new state and also replied; kept and sent through `cast`; kept and sent through `call`'s argument; kept and replied inside a record; `cast(a, (r, r))` |
| E2301 (no use after a send, §18.1, **not written**) | `send_then_use_bare_region`; `send_then_use_region_in_record`; `send_then_use_region_in_tuple`; `send_then_use_region_in_list_element`; `send_then_use_region_in_structure_version`; `send_then_use_via_field_read` (a field read from the aggregate after the send); `send_then_use_via_name_alias` and `send_then_use_via_handle_copy` (a copy of the handle); `send_then_use_region_in_closure`; `send_then_use_in_later_case_branch` (sent in one arm or before the `case`, used in a later branch); `send_then_use_in_loop` and `send_then_use_in_recursion` (sent in an iteration, used in the next, or by the recursive call). Each is repeated for `cast`, `send`, `call`, a reply and a spawn state, and for each of read, write, pass to a call, return, store in state and send again |
| E2308 | child spec whose initial state holds an owned region |

**Run trials:**

| Trial | Shows |
| --- | --- |
| `move_reply_version` | `call` returning a version built in the callee; the caller keeps using it after the callee ends (H4 for structures; the targeted stage 0 fix) |
| `move_map_of_sets` | a `graph_wbt` adjacency version sent; the receiver and the sender both query it |
| `supervised_child_restarts_with_version` | a child whose initial state holds a map version crashes and restarts 1,000 times (Q14 a); every start sees the same contents |
| `reply_and_keep_same_version` | a server keeps v1 in its state and replies with the same handle on every call, 10⁴ calls; the caller and the server both validate it |
| `move_two_cores` (board) | sender and receiver pinned to different cores, each deriving versions from one lineage for 10⁵ rounds with the atomic bump; validate both |
| `message_region_released_at_dispatch_end` | **not written** (§18.7; write-every-page, the SD-7 shape). A receiver is cast 100,000 messages, each holding an owned region of several pages, and writes every page; it keeps nothing. RSS stays flat. Fails today (SD-7). |
| `message_region_moved_into_state_not_dropped` | **not written** (§18.7). The behaviour moves the message's whole region into the new state; no `drop_owned` is placed on that path, the region is read intact by the next dispatch, and it is released once, at the actor's end. |
| `copy_to_rebuilds_in_state_region` | **not written** (§18.7). The behaviour copies a part of the message value into the state region with `copy_to`; the message region is dropped at return, the copy is intact in the next dispatch, its type carries the state's lifetime, and a 100,000-message run keeps RSS bounded by the state. |
| `partial_move_of_region_out_of_message_record` | **not written** (§18.7). A message `{ r: region, root: ref? }` is received; the behaviour moves `r` out of it into the state (partial move). The remaining fields may not be used afterwards where they borrow `r` (E2301), and `r` is released exactly once. |
| `crashed_actor_queued_message_regions_released` | **not written** (§18.7, H9). Messages with owned regions are queued to a worker that faults on its first dispatch; the supervisor restarts it 1,000 times. The regions of the unprocessed mailbox are released with the actor; heap growth is bounded. Fails today. |
| `send_to_dead_actor_releases_region` | **not written** (§18.7). A `cast`, a `send` and a `call` with a region to a removed actor return `actor_not_found`; the sender may not use the region (E2301) and the runtime releases it; 100,000 repetitions, RSS flat. |
| `timed_out_call_late_reply_region_released` | **not written; blocked on chunk 11** (`call_with_timeout` is not started). A call times out; the callee's later reply carries a region; the runtime discards the reply and releases the region. |
| `caller_dies_reply_region_dropped` | **not written** (§18.7). A caller is removed while awaiting a reply; the callee replies with a region; the region is dropped, not leaked, and not freed twice. |

**Error trials** (added by §18.7, **not written**): `message_ref_stored_in_state_without_copy_to_is_error` (a ref carrying the message region's lifetime stored into state typed with the state's lifetime is the lifetime error, and the program with `copy_to` compiles); `copy_to_rejected_for_device_window_and_atomic` (`copy_to` of a `device_window` or an atomic cell is rejected); the sender's later use of a region after the send is E2301, also when the send fails at run time.

### 18.7 Dispatch-scoped message regions and explicit `copy_to` (Lee, 2026-10-22)

**Decision.** The regions a message carries are **moved on send** and are **dispatch-scoped** in the receiver. Keeping
anything past the dispatch is explicit. This is the plan for messages that carry regions; it fixes BEES's SD-7 (a
region received in a message is never freed while the actor lives) without later reclamation.

**1. Move on send.** The no-use-after-send rule of §18.1 (E2301 for any use of the region, bare or embedded, by name, field read or handle copy, on `cast`, `send`, `call`, reply and spawn state) is the static half of this section. A message's owned regions (and the aggregates embedding them) change owner in O(1): a handle
transfer (§7.3's `_silica_rt_region_transfer`), no byte copied. The sender's later use is E2301, as §3.8 and §18.1
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
for it. A sender that wants to keep data calls `copy_to` before sending (a visible O(n)); sending never copies.

**4. By value class.**

| Class of the message part | Send | Keep past the dispatch |
| --- | --- | --- |
| owned region, or an aggregate embedding one | move | move the whole into the state, or `copy_to` a part |
| arena structure version (Q2 a) | handle pass by value (§18.3) | store the handle |
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
  dies with the worker, and its sender no longer has it. A sender that needs the data to survive the receiver's crash
  must `copy_to` before sending and keep the copy. This is the pattern, as in BEAM (messages are copied, and the sender
  keeps its own). Documented here and in the language guide, not enforced.

**8. What this changes in the plan.**

- There is no counting of any kind: Q2 (a) was decided on 2026-10-22 and structure versions are arena handles.

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
- §14.2 lists `shared_owner_ends_first` twice in its last row.

---

## 19. Escaping aggregates in actor regions (added 2026-10-12, Lee: option b)

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
ownership model (ownership of owned regions, messages move, versions only by a change). The chunk-4 implementation
must cover every case above, with a zero-growth trial for each (the zero_heap_growth_* trials in
actors_addition and the *_frees_heap trials in stack_budget_board_addition are the pattern).

## Revision history

| Version | Date | Changes |
| --- | --- | --- |
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
