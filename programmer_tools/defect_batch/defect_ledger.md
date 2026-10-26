# Defect ledger — Silica trial baseline

Status: as of 19:54, baseline has reconfirmed EVERY "(S)" stale row below fresh with
identical suite pass/fail counts and identical trial names (float64_addition,
generic_modules_addition, memory_region_addition, modules_addition,
recursive_function_addition, supervisors_addition, traits_addition, list_addition all spot
checked — exact match, nothing changed since Sep 21). Only 7 suites still lack a fresh
report: case_addition, string_addition, tuples_addition, uint8/16/32/64_addition.
cpu_discovery_and_spawn_pinning is permanently excluded from this run via its own
INTEGRATE_PENDING marker file (not a hang, not chunk-gated — just parked pending goldens).

Original status note (superseded by the above): built while the 2026-09-24 18:29 baseline run is still in progress.
Sources: a snapshot of every `.integrate_report` taken at 18:31 (before baseline could
overwrite them; saved under `scratchpad/report_snapshot/`), reconciled against fresh
baseline results as they land. Suites with a Sep-21 timestamp in the snapshot are STALE
(pre-dates today's tree move) and are marked accordingly; they will be overwritten by the
live baseline run and re-checked before this ledger is finalized.

Six parked worktrees (all on commit 29fa5a558, OLD layout) hold uncommitted fix attempts.
Their diffs were extracted, filtered to source files (build products `.sams/.o/.iface/
.ascomp/.sout` excluded), path-rewritten to the new `compiler/src` / `compiler/stdlib`
layout, and saved unapplied to `scratchpad/lanes/<worktree>.patch`. Coverage below is
**inferred from which trial files each lane touches/renames**, not yet verified by
building and running — that verification is still needed before any lane is applied.

## Lane summary

| Lane (worktree) | What it touches | Looks like |
| --- | --- | --- |
| agent-a27f5aea57e9aeb96 | prims_actors (all 4 emitters), term_aggregate_helpers, term_emit_kind_compound_part1/2, term_reg_spill, sir_generator terms_actor_lowering/terms_helpers, string_concat/substring_mmap_nomte | Actor-message-cast / tuple-state fixes |
| agent-a30edade7dcc1c228 | atoms rodata pools, emitter_core, let_dispatcher, prims_memory, prims_tuple, term_case_patterns, term_emit_kind_call/case/compound_part2/3 (4 emitters) | Float-param, list-literal, buffer-bounds-check (real impl, see below), tail-recursion, tuple-pattern-binding fixes |
| agent-a702bdb8999f916ec | main_compile_pipeline, parser_tuples, terms_tuple_lowering, ~10 type_checker files (identifiers/tuples/user_call_*/trait_specialization/type_checker_trait_placeholders/type_checker_collections/type_interner), stdlib/Supervisor.iface | Broad type-checker rework: generic-collection witness-record-to-named-type widening + trait placeholder dispatch + tuple literal parsing |
| agent-a71a809ee0d8dbb5c | ffi_fault_runtime_asm (4 emitters), prims_actors_stack_asm, rt_console.S/rt_vectors.S (ESP32), runtime_failure_reporting.md | Fault/abort reporting format (fault 70 / abort 71 banners) |
| agent-aa8ff68e815c7ffee | ESP32-S3_raw board runtime + emitter_core + new board apps (actor call/cast/core1/migrate/registered/fault/abort) | ESP32 raw-path actor runtime bring-up (board work, not a hosted trial fix) |
| agent-ad9a47f7b9cec922b | atom_table (4 emitters), emitter_core, print_atom_inline, main_driver_first/main_emit/main_lists/main_topo, module_checker_core, stdlib/Supervisor | Cross-unit atom numbering (program-wide atom table) |

**Notable finding:** lane `agent-a30edade7dcc1c228` does not defer
`memory_region_addition/buf_write_out_of_bounds_aborts` to chunk 4 — its diff rewrites the
trial's own comment to describe a real implementation: buffers now carry their element
count below element 0 (`prims_memory@emit_alloc_buf`) and every store/load compares the
index against it (`emit_buf_bounds_check`), fixing the two defects the original comment
named (marker never present on the SIR value; size identifier out of scope at the access
site). This is a working buffer-bounds-check implementation sitting unapplied, not a stub.
**Recommend re-classifying this trial as IN SCOPE** (a fix already exists, pending
verification) rather than OUT OF SCOPE/chunk-4, contrary to the initial read. Needs a
build+run to confirm the patch actually passes the trial before trusting the claim.

## Distinct defects

Each row is one defect (both the "has no .ascomp" and ".sout differs" manifestations of
the same trial are one row). Status column: F = fresh baseline result (today, 2026-09-24),
S = stale snapshot (Sep 21, to be reconfirmed).

| # | Suite / trial | Symptom | Chunk judgement | In/Out | Parked-patch coverage |
| - | --- | --- | --- | --- | --- |
| 1 | codegen_defects_addition/sd16_print_bool_in_case_arm_block | assemble failed printing a bool inside a case-arm block | none (codegen bug in existing feature) | IN SCOPE | Possible partial overlap: a30 touches term_emit_kind_case.silica / term_case_patterns.silica across emitters — unverified |
| 2 | compile_defects_binary_tree_bracket_addition | E1040 parse error, bracket-typed tree parameter (line 32) | none (parser gap on already-supported bracket syntax) | IN SCOPE | a702 DELETES this trial dir entirely (retired as fixed/folded) — unverified |
| 3 | compile_defects_bracket_receiver_arguments_addition | E2003 type mismatch, bracket receiver arg | none | IN SCOPE | a702 DELETES this trial dir — unverified |
| 4 | compile_defects_graph_bracket_receiver_addition | E2003, DirectedGraph bracket-receiver arg type mismatch | none | IN SCOPE | a702 touches gc_*_trait.silica files broadly — likely same root cause as #5-#9,#14 below, unverified |
| 5 | compile_defects_graph_field_annotation_addition | E2003, graph_wbt_undirected@add_edge returns a structural witness record where the field-annotated UndirectedGraph[...] nominal type is expected | none — looks like ONE root cause: the type checker doesn't widen a generic module's structural witness-record return to its declared nominal generic-instantiated type | IN SCOPE | a702's type_checker_expressions_user_call_* + type_checker_collections + type_interner changes are the most likely fix for this whole family — unverified |
| 6 | compile_defects_lifetime_parameter_name_addition | E2003 type mismatch: x (lifetime param name shadowing?) | none | IN SCOPE | not identified in any lane |
| 7 | compile_defects_list_tuple_literal_addition | E1040 parse error, list-of-tuple literal | none (parser gap) | IN SCOPE | a702 touches parser_tuples.silica + terms_tuple_lowering.silica — likely covered, unverified |
| 8 | compile_defects_not_operator_addition | E2002 undefined identifier: not | none (missing `not` operator/keyword support) | IN SCOPE | not identified in any lane |
| 9 | compile_defects_ordered_map_field_annotation_addition | E2003, wbt_map@insert witness record vs OrderedMap[...] nominal type | same root cause family as #5 | IN SCOPE | likely covered by a702, unverified |
| 10 | compile_defects_ordered_set_field_annotation_addition | E2003, wbt_set@insert witness record vs OrderedSet[...] | same family as #5 | IN SCOPE | likely covered by a702, unverified |
| 11 | compile_defects_ordered_set_field_projection_addition | E2003, wbt_set@insert vs inline-projected structural type | same family as #5 (a stricter variant: even an inline structural annotation doesn't match) | IN SCOPE | likely covered by a702, unverified |
| 12 | compile_defects_priority_queue_supervisor_addition | E2003 type mismatch: children (line 110) | none | IN SCOPE | a27f directly modifies this trial's .silica file — likely covered |
| 13 | compile_defects_tagged_optional_type_addition | E1040 parse error, tagged optional type syntax | none (parser gap) | IN SCOPE | not identified in any lane |
| 14 | compile_defects_trait_nested_placeholder_addition | E2092, NestedBox impl fn items signature mismatch | trait-placeholder dispatch, same family as #5/#15 | IN SCOPE | a702 touches trait_specialization.silica + type_checker_trait_placeholders.silica — likely covered |
| 15 | ~~compile_defects_trait_placeholder_result_dispatch_addition~~ | **RETRACTED 20:08 baseline reconciliation: this suite is PASSING today (4/4, 0 fail).** I mistakenly listed it as a fresh failure in the first pass without checking its actual content — it was never actually red. a702's deletion of this trial dir is presumably cleanup of an already-fixed defect, not evidence it fixes anything live. Removed from the true failure count. | n/a | NOT A DEFECT | n/a |
| 16 | compile_defects_trait_placeholder_return_addition | E2003, ItemBag@items return type vs trait placeholder return type | same family as #5/#14 | IN SCOPE | likely covered by a702 |
| 17 | compile_defects_tree_field_annotation_addition | E2003, tree_rose@add_leaf witness record vs Tree[...] | same family as #5 | IN SCOPE | likely covered by a702 |
| 18 | float64_addition/sd14_float_parameter_clobbered (S) | second float param silently wrong value | none (register-clobber codegen bug) | IN SCOPE | a30 renames to float_parameter_survives_let_and_call — covered, unverified |
| 19 | generic_modules_addition/emitter_defect_two_generic_collections_round_trip (S) | fault in wbt_set_size when two generic collections used together | none | IN SCOPE | a27f renames to two_generic_collections_round_trip — covered, unverified |
| 20 | generic_modules_addition/pair_sets (S) | (symptom not captured, has-no-.ascomp only) | none | IN SCOPE | a27f adds pair_sets.silica — covered, unverified |
| 21 | generic_modules_addition/wbt_set (S) | (symptom not captured, has-no-.ascomp only) | none | IN SCOPE | not clearly identified in any lane — may be a side effect of the same generic-module fix, unverified |
| 22 | list_addition/emitter_defect_empty_list_literal (S) | empty list literal wrong value | none | IN SCOPE | a30 renames to empty_list_literal_last_statement — covered, unverified |
| 23 | memory_region_addition/buf_write_out_of_bounds_aborts (S) | out-of-bounds buffer store/load doesn't abort, silently succeeds | **RECLASSIFY: real fix exists (see Notable finding above), not a chunk-4 stub** | IN SCOPE (revised) | a30 has a genuine implementation — HIGH PRIORITY to verify by building |
| 24 | memory_region_addition/emitter_defect_region_param_destroyed_after_ref_in_region (S) | region param destroyed after ref taken inside it | none | IN SCOPE | a30 renames to region_tuple_return_in_actor — covered, unverified |
| 25 | memory_region_addition/sd11_write_buf_uint8_call_argument (S) | write_buf uint8 as call argument mis-faults | none | IN SCOPE | a30 renames to write_buf_call_argument — covered, unverified |
| 26 | modules_addition/sd3_cross_unit_atoms (S) | atom numbered per-unit, not per-program | Lee decided 2026-09-19 "application = one compilation unit" as a design default; but... | SEE NOTE | ad9a47 has a full cross-unit atom-table implementation (all 4 emitters + main_driver + module_checker) — contradicts treating this as an accepted deviation; someone already built the real spec-required fix. Recommend IN SCOPE, verify by building. |
| 27 | modules_addition/sd3_cross_unit_atoms_registered_name (S) | same root cause as #26 | same | SEE NOTE (#26) | same lane (ad9a47) |
| 28 | recursive_function_addition/sd12_tail_recursion_grows_stack (S) | deep tail recursion faults instead of running in constant/bounded stack | Could be chunk-1 (growable actor stacks) territory, but a fix is parked | IN SCOPE (tentative) | a30 renames to tail_recursion_runs_in_constant_stack — covered, unverified; verify this doesn't just paper over a stack-growth dependency |
| 29 | string_addition/defect_print_undefined_builtin (S) | **CORRECTED by lane FRONTEND (relayed via main):** this is not a missing-rejection diagnostic gap. Spec §5.1.1 and the trial say `print` is a real builtin that must compile and run; the type/effect checkers accept it, but the SIR generator has no lowering for it, so it reaches the linker as an unresolved user call. | none (missing SIR lowering for an accepted builtin, not a diagnostics gap) | IN SCOPE | **Lane FRONTEND** — implementing the `print` builtin's lowering, and separately a compile-time diagnostic for the whole class of builtins the checker accepts but the generator cannot lower |
| 30 | supervisors_addition/emitter_defect_cast_registered_double_record_literal (S) | cast to registered double wraps a record literal wrong | none | IN SCOPE | a27f renames to cast_registered_double_record_literal — covered, unverified |
| 31 | supervisors_addition/emitter_defect_cast_registered_double_tuple_literal (S) | same, tuple literal | none | IN SCOPE | a27f renames to cast_registered_double_tuple_literal — covered, unverified |
| 32 | supervisors_addition/emitter_defect_record_message_cast_between_actors (S) | record message cast between actors garbles the value | none | IN SCOPE | a27f renames to record_message_cast_between_actors — covered, unverified |
| 33 | supervisors_addition/emitter_defect_tuple_pattern_named_binding (S) | named tuple-pattern binding wrong inside a behaviour | matches memory note "Book-found defect trials" E2002 tuple pattern family | IN SCOPE | a30 renames to tuple_pattern_named_binding_in_behaviour — covered, unverified |
| 34 | supervisors_addition/sd10_sup_tuple_state (S) | supervisor tuple state faults | none | IN SCOPE | a27f renames to supervisor_child_tuple_state (and adds supervisor_child_record_state) — covered, unverified |
| 35 | traits_addition/emitter_defect_bracket_receiver_impl_order (S) | bracket-receiver impl dispatch order wrong | trait dispatch family, same root as #5 group | IN SCOPE | a702 DELETES this trial dir — covered, unverified |
| 36 | traits_addition/emitter_defect_trait_param_single_impl (S) | trait param single-impl dispatch wrong | same family | IN SCOPE | a702 DELETES this trial dir — covered, unverified |

## Addendum (confirmed fresh + extra findings, added after first pass)

| # | Suite / trial | Symptom | Chunk judgement | In/Out | Parked-patch coverage |
| - | --- | --- | --- | --- | --- |
| 37 | actors_addition/sd19_migrate_actor_expression_core | **CONFIRMED FRESH (18:45 baseline)**: fault inside `silica_rt_migrate_actor` when the second argument is an expression (`1 + i % 2`) instead of a literal/bound name | none | IN SCOPE | not identified in any of the 6 lanes — genuinely unfixed, no parked patch |
| 38 | case_addition/emitter_defect_tuple_pattern_atom_element | Not yet confirmed fresh (case_addition hasn't produced a report in this baseline run yet), but lane a30's own README edit says it's the isolated open half of the tuple-pattern-binding defect family (#33) | none | IN SCOPE (expected) | a30's README calls it still open; not directly touched by code in any lane — verify once case_addition reports |

Also found while reading lane a30's `compile_defects_addition/README.md` edit (a defect changelog the lane updates): it names an unimplemented item, **`compile_defects_float_literal_pattern_addition`** — a float literal is rejected as a case pattern (E2005) — as "open" from "defect batch 2 (2026-09-19)". **This trial suite does not exist in the current tree** (`ls trials/ | grep float_literal_pattern` empty), so it is not part of the current 34,097-trial count and not a baseline failure today — it's a known-but-not-yet-written trial. Flagging for main/Lee: either the trial was never added, or it lives only in this parked lane. Worth adding once a lane lands, but it doesn't affect the current red count.

Lane a30's README edit also confirms defect #1 (`codegen_defects_addition/sd16_print_bool_in_case_arm_block`) is fixed by that lane specifically: the emitter now emits `L_pb_helper` for `print_bool` in any node kind including case arms, and the trial is moved to `boolean_addition/print_bool_in_case_arm_block`. This upgrades that row from "possible partial overlap" to **likely direct fix**, still unverified by a build.

## Addendum 2 (fresh baseline results for previously-no-report suites; requested by main)

| # | Suite / trial | Symptom | Chunk judgement | In/Out | Owning lane |
| - | --- | --- | --- | --- | --- |
| 39 | ffi_addition/app_sd18_worker_second_message/dangerous_sd18_worker_second_message | **CONFIRMED FRESH**: a spawn_dangerous worker faults on its SECOND message (`os_unfair_lock_lock` at addr 0x11) | none | IN SCOPE | **agent-a27f5aea57e9aeb96** — root-caused and fixed: `dangerous_actor_ref` was missing from `term_reg_spill@let_rhs_type_spills_across_io` so the worker ref had no callee-saved home; the second `cast` read back the first cast's stale boolean and locked garbage. Touches term_reg_spill.silica in all 4 emitters. Renames trial to app_worker_second_message. Unverified by build. |
| 40 | error_enforcement_addition/sd1_qualified_call_too_many_args_trial | **CONFIRMED FRESH**: qualified call `hello_lib@answer` with too many args should reject with E2005 "argument count mismatch" but compiles clean | none (missing diagnostic) | IN SCOPE | **no lane owns this** |
| 41 | error_enforcement_addition/ffi_addition/error_app_cast_worker/dangerous_sd15_adapter_called_from_main | **CONFIRMED FRESH**: should reject with E4042 "calls to dangerous_* module functions must appear in the sequence portion... inside an FFI worker actor behavior" but instead gives the wrong diagnostic, E3010 "unused effect declaration: external_danger" | none (wrong diagnostic emitted instead of the correct one) | IN SCOPE | **no lane owns this** |
| 42 | error_enforcement_addition/sd8_cast_to_call_only_behaviour | **CONFIRMED FRESH**: `cast()` to a call-only actor should reject E2005 "(spec §16.2.6.3)" but compiles clean | none (missing diagnostic) | IN SCOPE | **no lane owns this** |
| 43 | error_enforcement_addition/stmt_missing_semicolon_between_binding_and_tail_expr | **CONFIRMED FRESH**: missing `;` between a binding and the tail expression should reject E1040 but compiles clean | none (missing diagnostic) | IN SCOPE | **no lane owns this** |
| 44 | error_enforcement_addition/stmt_missing_semicolon_between_binding_stmts | **CONFIRMED FRESH**: same class, different statement position, should reject E1040 but compiles clean | none (missing diagnostic) | IN SCOPE | **no lane owns this** |
| 45 | ordered_data_structures/standard_data_structures_phase1/graph_collections/emitter_defect_trait_placeholder_result_dispatch | **CONFIRMED FRESH**: fault in `graph_wbt_core_find_outer_go` — a second, runtime-fault manifestation of the same trait-placeholder-dispatch defect family as row #15 (`compile_defects_trait_placeholder_result_dispatch_addition`, which lane a702 deletes as a compile-time trial). This one is a *different* trial location testing the same dispatch path at runtime, not proven to be fixed by the same patch. | trait-placeholder dispatch, same family as #5/#14-#17 | IN SCOPE | Likely a702 (trait_specialization.silica / type_checker_trait_placeholders.silica) but this is a runtime fault not a compile rejection — **needs its own verification, do not assume covered just because the compile-time twin is deleted** |

**Rows 40-44 (all 5 error_enforcement diagnostics): now owned by lane DIAGNOSTICS** (third Fable lane, assigned by main after I confirmed no existing lane covered them).

## FINAL RECONCILIATION — baseline completed 20:08:07

Grand total across all 56 reportable suites: **34,052 passed / 67 failed** (failure *lines*,
counting both manifestations of the same trial separately). Deduplicated to distinct
trials, actual defect count is **44**, one suite (compile_defects_trait_placeholder_result_dispatch_addition,
row 15 above) retracted as a false positive from my own first-pass error — it is
passing (4/4). cpu_discovery_and_spawn_pinning remains permanently excluded via its
INTEGRATE_PENDING marker (not counted either way).

Per-suite fail-line counts (all fresh, 2026-09-24 baseline):
actors_addition=2, case_addition=2, codegen_defects_addition=3, 15×compile_defects_*=1 each,
error_enforcement_addition=5, ffi_addition=1, float64_addition=2, generic_modules_addition=4,
list_addition=2, memory_region_addition=6, modules_addition=4, ordered_data_structures=2,
recursive_function_addition=2, string_addition=3, supervisors_addition=10, traits_addition=4.

**All 44 distinct defects are judged IN SCOPE** (no chunk-1/2/4/15 gate applies to any of
them once actually read) with the one flagged exception already resolved by your decision:
modules_addition's 2 cross-unit-atom trials proceed as a fix per your call.

Compared to the "last full run: 34,008 passed / 89 failed" baseline mentioned at task
start: today's run has MORE passes (34,052) and FEWER fails (67 raw lines, ~44 distinct)
than that prior figure. I cannot fully explain the gap (different suite composition
since the Sep-19/21 batch-2 additions, or genuine fixes landing between then and now) —
flagging rather than guessing.

## Suites with NO prior report at all (never run before this baseline, or report was purged)
actors_addition, bitwise_addition, case_addition, compiler_addition,
cpu_discovery_and_spawn_pinning, error_enforcement_addition, ordered_data_structures.
No historical fail data — waiting on fresh baseline numbers. `actors_addition` contains
`sd19_migrate_actor_expression_core` (see below) and the baseline was compiling this suite
as of 18:42.

## The three trials main asked me to confirm/correct

1. **actors_addition/sd19_migrate_actor_expression_core** — main's read: chunk 2 (migrate_actor).
   **CORRECTED: IN SCOPE.** Read the trial source: `migrate_actor` is already a working,
   already-implemented primitive today (works fine with a literal or a bound-name argument
   per the trial's own comment); it only faults when the argument is an arithmetic
   *expression*, because "the arguments reach the primitive in the wrong registers." That's
   a codegen/argument-evaluation bug in an existing primitive, not a missing chunk-2
   placement/pinning feature. Chunk 2 is about carriers, cooperative scheduling and
   `get_cpu_topology()` — none of that is what this trial exercises.

2. **memory_region_addition/buf_write_out_of_bounds_aborts** — main's read: chunk 4 (buffer
   bounds checking). **CONFIRMED as designed** (the trial's original comment explicitly says
   the emitter has the target but never emits the branch, matching ROADMAP chunk 4's
   deliverable), **but a real fix is already parked and unapplied** in lane
   `agent-a30edade7dcc1c228` (see Notable finding above). Recommend treating this as
   ready-to-verify IN SCOPE work rather than leaving it parked for chunk 4.

3. **modules_addition/sd3_cross_unit_atoms** — main's read: the per-unit atom numbering
   work-around (an accepted design deviation, not a bug). **PARTIALLY CORRECTED**: memory
   does record Lee's 2026-09-19 decision that applications are one compilation unit by
   design and multi-unit builds are a memory work-around — so there's a real basis for
   treating this as accepted, not a defect. However, a full, real cross-unit atom-table
   implementation (touching all 4 emitters, main_driver, module_checker) is sitting parked
   and unapplied in lane `agent-ad9a47f7b9cec922b`, which strongly suggests someone already
   treated this as buildable, in-scope work rather than a permanent deviation. Recommend
   asking Lee directly whether this should be fixed now (patch exists) or the trial retired
   to match the accepted per-unit design — do not resolve this call unilaterally.

## Patches (unapplied, path-rewritten, ready for review)
`scratchpad/lanes/agent-a27f5aea57e9aeb96.patch`
`scratchpad/lanes/agent-a30edade7dcc1c228.patch`
`scratchpad/lanes/agent-a702bdb8999f916ec.patch`
`scratchpad/lanes/agent-a71a809ee0d8dbb5c.patch`
`scratchpad/lanes/agent-aa8ff68e815c7ffee.patch` (ESP32 board work, not a hosted-trial fix)
`scratchpad/lanes/agent-ad9a47f7b9cec922b.patch`

## Lane identity mapping (confirmed by content + build timestamps, 20:30ish)
- INTEGRATE = worktree agent-a4e2fd306e14f8748 (built silica-999969 at 20:00:55, ~41 min build)
- FRONTEND = worktree agent-a0f4cd3fb29ebb8e2 (built 999969 @ 20:10:08, 999968 @ 20:15:06)
- DIAGNOSTICS = worktree agent-a27ee92d458acdfe1 (built 999969 @ 20:07:53, 999968 @ 20:20:30)
- CODEGEN = worktree agent-ae684c103739140b4 (no changes yet, diagnosis only — owns rows
  actors_addition/sd19_migrate_actor_expression_core, case_addition/emitter_defect_tuple_pattern_atom_element,
  generic_modules_addition/wbt_set)

## VERIFICATION LOG (read actual trial output myself, 20:30-20:35)

**FRONTEND claims — verified by compiling+linking+running each trial myself with FRONTEND's
own binary (worktree binaries/silica-compiler -> 999968):**
- compile_defects_not_operator (now boolean_addition/not_operator): **YES, exact match.**
  Output `false\n0`, byte-identical to .scout.
- compile_defects_lifetime_parameter_name (now memory_region_addition/lifetime_parameter_name):
  **YES, exact match.** Exit code 42, no stdout, matches .scout `42`.
- string_addition/defect_print_undefined_builtin (now string_addition/print_undefined_builtin):
  **YES, exact match.** Output `yes`, exit 2, matches .scout `yes\n2`.
- tagged_optional_type (now tuples_addition/emitter_defect_tagged_optional_type):
  **Confirmed accurately characterized, NOT claimed as fixed.** It now compiles, assembles,
  and links (no longer a parse-time rejection), but crashes at runtime: `case_clause` error,
  exit 1, vs expected `0\n7\n0`. FRONTEND's own report (blocked on CODEGEN's tuple-pattern
  row) matches what I independently reproduced.

**DIAGNOSTICS claims — checked against its own worktree's freshest error_enforcement_addition
report (20:24:13, i.e. AFTER its last build, so this supersedes whatever count it told main):**
- Report shows **10,887 passed / 8 failed**, not the "10,802 / 93" figure relayed to me —
  that figure is stale, from before DIAGNOSTICS' own later fix pass.
- **"All five error-enforcement goldens reproduce exactly" is NOT confirmed — it is FALSE
  as stated.** All 5 original rows now raise something close to the right diagnostic, but
  none are byte-exact:
  - sd1_qualified_call_too_many_args_trial: right error, offset off by 1 (400 vs 399).
  - dangerous_sd15_adapter_called_from_main: right error, two offsets off (783/781, 1306/1267).
  - sd8_cast_to_call_only_behaviour: right error, offset off (689 vs 651).
  - stmt_missing_semicolon_between_binding_and_tail_expr: only a trailing-whitespace
    formatting diff on 3 lines ("Files to compile: " vs "Files to compile", etc.) — the
    diagnostic itself looks right, this is a print-statement whitespace bug.
  - stmt_missing_semicolon_between_binding_stmts: identical whitespace-only diff.
- **3 additional failures exist that were not in the original 5, not mentioned by DIAGNOSTICS:**
  - `error_enforcement_addition/standard_data_structures/trial_compile_fail_int64_type`:
    **looks like a real regression, not a leniency case.** I read the trial source — it
    already ends the binding with `;` (`x: int64 <- true;`) and its own comment explicitly
    says the golden's failure is the type checker's (E1055 unused variable), not a missing
    terminator. DIAGNOSTICS' change now wrongly raises E1040 (missing `;`) on code that
    already has one. This does not fit main's "add a semicolon" ruling — the semicolon is
    already there. Needs DIAGNOSTICS' attention as a distinct bug in the new statement check.
  - `error_app_sidecar_metadata/dangerous_sidecar_missing_archive`: the new E4042
    (dangerous-module-placement) diagnostic now fires and aborts compilation BEFORE the
    checker reaches the E4034 (missing archive) check this trial is supposed to exercise —
    an overfire/precedence bug between two diagnostics.
  - `dangerous_missing_foreign_symbol_at_link`: "silica.link not emitted" — not investigated
    further, flagging for DIAGNOSTICS.

**INTEGRATE claims — checked its own worktree's fresh reports:**
- boolean_addition: **YES, confirmed exact.** 417 passed / 1 failed, and the 1 failure is
  exactly "has no .ascomp file" for `print_bool_in_case_arm_block` (a missing golden for a
  newly-landed/renamed trial, not a behavioral defect).
- float32_addition (580/54) and float64_addition (594/58): **partially confirmed.**
  - Spot-checked one of the "`.sams` differs from `.ascomp`" trials
    (train_defect_a1_second_only_float32_0001) all the way through the log: it fails the
    assembly-text comparison but its `.sout` DOES match `.scout` ("output matches .scout"
    in the log) — confirms INTEGRATE's characterization that the bulk of these (52 in
    float32, 54 in float64) are stale assembly goldens from the register-shadow change,
    not behavior bugs.
  - However INTEGRATE's summary omitted two other real things present in both suites:
    (a) 1 missing-golden trial in float32 (`float_literal_in_case_arm`) and 3 in float64
    (`float_literal_in_case_arm`, `float_parameter_survives_let_and_call` — the renamed
    sd14 trial itself has no committed golden yet, `int_let_in_float_function`);
    (b) a real, if minor, **output-formatting difference** in `float_literal_in_case_arm`
    in both suites: prints `10.25`/`42.75` (float32) and `2.25` (float64) where the golden
    expects trailing-zero-padded `10.250`/`42.750`/`2.250` — numerically equal, textually
    different. This is a float-printing format question (how many decimal places), not
    covered by "assembly-golden diffs due to the parameter shadow."

**IMPORTANT SIDE EFFECT found in INTEGRATE's combined build, not reported by any lane:**
INTEGRATE's list_addition run (20:20:19) shows **971 passed / 95 failed** — not the 1
failure (emitter_defect_empty_list_literal) my ledger expected. 94 of those 95 are
`.sams differs from .ascomp` on `train_list_fold_*` trials: the merged build now emits a
genuine tail-call-optimized loop (`L_tco_*`/`L_tcob_*` labels, direct branch) instead of the
old golden's indirect `ADRP/BLR` call sequence — almost certainly a side effect of the
recursive-tail-call fix (ledger row 28) landing more broadly than just its own trial.
**Checked behavior, not just text: `grep -c ".sout differs from .scout"` across the whole
list_addition log = 0.** Every one of those 94 is a stale assembly golden, not a behavior
regression — confirmed by the log line "output matches .scout" for every one I checked. This
means reaching green will require regenerating ~94 assembly goldens in list_addition alone
once the combined build is accepted, and probably more in any other suite exercising
tail-recursive patterns (memory_region_addition, recursive_function_addition,
supervisors_addition etc. — INTEGRATE has not yet run those suites in its own worktree, so
I don't have that data yet).

## CORRECTIONS TO MY OWN EARLIER VERIFICATION (snapshot-mismatch, caught by main 20:40)

**trial_compile_fail_int64_type — RETRACTED, this is not a regression.** My earlier read
mixed two snapshots: I read the CURRENT source (worktree agent-a27ee92d458acdfe1 =
DIAGNOSTICS, file mtime 20:25:49, already has `;` — main's semicolon ruling was already
applied) against a REPORT generated at 20:24:13, i.e. BEFORE that edit landed, from the OLD
semicolon-less source. Re-verified cleanly at 20:40:45 in the same worktree
(agent-a27ee92d458acdfe1), binary `silica-999968-macos-applesilicon`: compiling the CURRENT
source now raises **E1055 "unused variable 'x'"** — the same code and message the
`.golden_fail` expects. The only diff left is line/column/offset (golden says line 3, actual
is line 5) because the golden predates the two explanatory comment lines DIAGNOSTICS added
above the code. That's a golden-metadata staleness, not a defect. **Row is clean once the
golden's line/offset is refreshed to match the current file.**

**float32_addition & float64_addition / float_literal_in_case_arm — RETRACTED, not a
mismatch.** Re-checked at 20:41:25-20:42 in worktree agent-a4e2fd306e14f8748 (INTEGRATE),
binary `silica-999969-macos-applesilicon`. The current `.scout` goldens (git-diff shows them
as newly-added at 20:19:11/20:19:12, i.e. after INTEGRATE's correction) read `10.25`/`42.75`
(float32) and `1.5`/`2.25` (float64) — no trailing zero. I compiled, assembled, linked and
ran both trials myself just now: output is exactly `10.25`/`42.75` and `1.5`/`2.25`,
matching the current goldens byte-for-byte. My earlier "10.25 vs 10.250" finding was against
a report generated before INTEGRATE's correction landed. **Both rows are clean now — the
printer's behavior (no forced trailing zero) is correct and the golden agrees.**

**DIAGNOSTICS' error_enforcement offsets — reframed.** "Byte-exact" was main's summary word,
not DIAGNOSTICS' own claim. Per main: the off-by-a-few-byte offsets I found are the
**golden's** error, not the compiler's, proven against file bytes and a sibling golden.
Judging on the current files: sd1_qualified_call_too_many_args_trial, dangerous_sd15_adapter_called_from_main,
and sd8_cast_to_call_only_behaviour raise the right diagnostic; the offset mismatches are
golden staleness, not compiler bugs. Only the 2 whitespace-only diffs
(stmt_missing_semicolon_between_binding_and_tail_expr / _stmts) still need a look — those
are a real print-statement formatting question (trailing space after "Files to compile:"
etc.), not yet resolved either way.

**Still open, unresolved, kept as their own rows (main confirmed these are real):**
- `error_app_sidecar_metadata/dangerous_sidecar_missing_archive`: E4042 fires and aborts
  compilation before E4034 (missing-archive) ever runs — a genuine diagnostic-precedence
  bug, not a missing check.
- `dangerous_missing_foreign_symbol_at_link`: "silica.link not emitted" — cause not yet
  identified, not to be called fixed until it is.

## RUST LINKER RULING (from Lee via main)
The rust-lld linker path is retired; clang is the only linker on this path going forward
(the GNU linker variant stays for Linux). Any ledger row that would have called for
regenerating a rust-lld-produced golden is a **deletion** of that golden/expectation
instead, not a regeneration. I found no ledger row currently referencing a rust-lld golden
directly, but noting this ruling here so it's applied if one surfaces during verification
(several Makefiles I've read do `test -x rust-lld && use it || use clang` — any golden that
only matches the rust-lld branch's output should be deleted, not chased).

## a702 trial-directory deletions — scrutiny against the no-workaround rule (20:44-20:47)

Reconstructed each deleted trial's exact source from the a702 patch (it's a plain delete
diff, so the removed `-` lines are the original file) and rebuilt it in a scratch dir,
compiling/assembling/linking/running against **worktree agent-a4e2fd306e14f8748 (INTEGRATE),
binary silica-999969-macos-applesilicon, verified 20:44-20:47**:

- **compile_defects_trait_placeholder_result_dispatch_addition** (row 15): confirmed
  PRE-EXISTING passing in the untouched baseline tree (before any of today's 6 lanes ran) —
  this was never broken by anything a702 did. Deletion is harmless cleanup of an
  already-obsolete trial, not a workaround.
- **compile_defects_binary_tree_bracket_addition** (row 2): reconstructed and ran —
  **YES, genuinely fixed** (no E1040 any more). AND it is not a bare workaround: an
  equivalent permanent trial already exists and passes —
  `ordered_data_structures/binary_tree_core/binary_tree_bracket.silica`, same scenario
  (`BinaryTree[...]` bracket type as return/binding/trait-call target), same expected
  output (`root`/`1`). **No coverage lost.**
- **compile_defects_bracket_receiver_arguments_addition** (row 3): reconstructed and ran —
  **YES, genuinely fixed**, prints `5`, exit 0, matches the deleted golden exactly. **I did
  NOT find a permanent replacement trial for this exact scenario** (a placeholder-typed
  parameter after the receiver, `id: KeyType`, with two fitting trait implementations) —
  this looks like a real coverage gap per the "add trials for gaps" principle: the compiler
  fix is real, but the regression trial for this specific shape is gone.
- **traits_addition/emitter_defect_bracket_receiver_impl_order** (row 35): reconstructed
  and ran — **YES, genuinely fixed**, prints `5`, exit 0, matches the deleted golden
  exactly (declaration-order dispatch ambiguity resolved by construction/value identity
  instead). **No permanent replacement trial found — same coverage-gap concern.**
- **traits_addition/emitter_defect_trait_param_single_impl** (row 36): reconstructed and
  ran — **YES, genuinely fixed**, prints `20`/`42`, exit 0, matches the deleted golden
  exactly (a trait-typed parameter's body now re-dispatches per call site instead of
  binding to one implementation for the whole function). **No permanent replacement trial
  found — same coverage-gap concern.**

**Bottom line for main:** none of these five deletions are hiding a live bug — every fix is
real and independently reproduced by me from scratch. But two of the five (rows 3, 35, 36 —
three trials) remove the only regression coverage for their specific defect shape with
nothing standing in for them. That's a process gap worth closing (write a permanent trial
under the matching `ordered_data_structures`/`traits_addition` location) even though it
does not block calling the underlying defects fixed.

## RULINGS RECORDED (from main, 20:3x)
1. **Semicolon question is settled** by spec §3.3.4's statement production, which carries
   the `;`. Trials that relied on the previous lenient (no-semicolon-required) parsing get
   a semicolon added to their source rather than being retired. NOTE: this does not appear
   to cover `trial_compile_fail_int64_type` above, which already has its semicolon — that
   one is a distinct DIAGNOSTICS regression, not a leniency case; flagging the difference
   rather than silently filing it under this ruling.
2. **The cross-unit-atoms fix (ledger rows 26-27, lane ad9a47f7b9cec922b) stays held** until
   everything else is merged and green, then lands alone with its five supervisors goldens
   refreshed. Not to be merged early with the other lanes.

## HANDOVER (overseer stood down 20:48, duplicated by a Haiku verification lane)

Lane mapping: INTEGRATE=agent-a4e2fd306e14f8748 (bin 999969), FRONTEND=agent-a0f4cd3fb29ebb8e2
(bin 999968), DIAGNOSTICS=agent-a27ee92d458acdfe1 (bin 999968), CODEGEN=agent-ae684c103739140b4
(took the build slot 20:46:42, no result read yet).

### Proven fixed (exact match or confirmed-behavior-correct, verified by running the trial myself)
| Row | Trial | Evidence |
| --- | --- | --- |
| 1 | codegen_defects_addition/sd16_print_bool_in_case_arm_block (now boolean_addition/print_bool_in_case_arm_block) | log "output matches .scout"; missing .ascomp only |
| 8 | compile_defects_not_operator_addition (now boolean_addition/not_operator) | ran myself, byte-exact |
| 6 | compile_defects_lifetime_parameter_name_addition (now memory_region_addition/lifetime_parameter_name) | ran myself, byte-exact |
| 29 | string_addition/defect_print_undefined_builtin (now print_undefined_builtin) | ran myself, byte-exact |
| 18 | float64_addition/sd14_float_parameter_clobbered (now float_parameter_survives_let_and_call) | log "output matches .scout"; missing .ascomp only |
| — | float32_addition/float_literal_in_case_arm | ran myself, byte-exact (post golden-fix) |
| — | float64_addition/float_literal_in_case_arm | ran myself, byte-exact (post golden-fix) |
| 24 | memory_region_addition/emitter_defect_region_param_destroyed_after_ref_in_region (now region_tuple_return_in_actor) | ran myself, byte-exact |
| 25 | memory_region_addition/sd11_write_buf_uint8_call_argument (now write_buf_call_argument) | ran myself, byte-exact |
| 23 | memory_region_addition/buf_write_out_of_bounds_aborts | ran myself, exact under documented normalization |
| 15 | compile_defects_trait_placeholder_result_dispatch_addition | pre-existing pass, untouched by today's lanes |
| 2 | compile_defects_binary_tree_bracket_addition | reconstructed+ran, exact; permanent replacement already exists (ordered_data_structures/binary_tree_core/binary_tree_bracket.silica) |
| 3 | compile_defects_bracket_receiver_arguments_addition | reconstructed+ran, exact; **no permanent replacement trial — coverage gap** |
| 35 | traits_addition/emitter_defect_bracket_receiver_impl_order | reconstructed+ran, exact; **no permanent replacement trial — coverage gap** |
| 36 | traits_addition/emitter_defect_trait_param_single_impl | reconstructed+ran, exact; **no permanent replacement trial — coverage gap** |
| 42 | error_enforcement/sd8_cast_to_call_only_behaviour | right diagnostic; golden offset is stale (not a compiler bug, per main) |
| 40 | error_enforcement/sd1_qualified_call_too_many_args_trial | right diagnostic; golden offset stale |
| 41 | error_enforcement/dangerous_sd15_adapter_called_from_main | right diagnostic; golden offsets stale |
| — | error_enforcement/standard_data_structures/trial_compile_fail_int64_type | right diagnostic (E1055) on current (semicolon-added) source; golden line/offset stale only |

### Not yet proven / needs a fresh reader
- tuples_addition/emitter_defect_tagged_optional_type: now compiles+links, crashes at runtime
  (`case_clause`, exit 1, expected `0/7/0`) — correctly blocked on CODEGEN's tuple-pattern row.
- actors_addition/sd19_migrate_actor_expression_core, case_addition/emitter_defect_tuple_pattern_atom_element,
  generic_modules_addition/wbt_set: owned by CODEGEN; CODEGEN took the build slot at 20:46:42,
  no output read yet — check its worktree's build/report next.
- supervisors_addition (5 trials), generic_modules_addition/two_generic_collections_round_trip,
  generic_modules_addition/pair_sets: attempted isolated scratch-dir compiles in INTEGRATE's
  worktree; the multi-actor ones (cast_registered_double_record_literal, cast_registered_double_tuple_literal,
  record_message_cast_between_actors, tuple_pattern_named_binding_in_behaviour,
  two_generic_collections_round_trip) need the full suite's `Supervisor` stdlib wiring that a
  single-file scratch dir doesn't have (E1009 "unknown module in use: Supervisor") — **not a
  real defect, just an incomplete isolated repro; run the real suite instead.** pair_sets and
  wbt_set compiled clean in isolation but were not run to a final output check.
  recursive_function_addition/tail_recursion_runs_in_constant_stack compiled clean in isolation;
  **run+compare was in progress when I was told to stand down — not completed.**
- INTEGRATE's own trials/.integrate.lock was held by case_addition (pid 94629, started 20:20:22)
  for the whole session — never got a chance to run supervisors_addition/traits_addition/
  generic_modules_addition/recursive_function_addition as full suites there. Next reader should
  just wait for that lock and read the reports it produces.

### Retracted (were snapshot-mismatch errors on my part, not real findings)
- error_enforcement/trial_compile_fail_int64_type "regression" — retracted: compared post-fix
  source against a pre-fix report from a different point in time.
- float32/float64 float_literal_in_case_arm "10.25 vs 10.250 mismatch" — retracted: read the
  golden before INTEGRATE's correction landed; current goldens agree with the printer.
- compile_defects_trait_placeholder_result_dispatch_addition as a first-pass "failing" row —
  retracted: never actually failed, an error in my initial ledger pass (didn't check content).
- DIAGNOSTICS "byte-exact" framing — reframed per main: offset mismatches are the golden's
  error, not the compiler's, proven against file bytes and a sibling golden.

### Three open items nobody has resolved
1. **Diagnostic precedence bug**: `error_enforcement_addition/ffi_addition/error_app_sidecar_metadata/dangerous_sidecar_missing_archive`
   — the newer E4042 (dangerous-module-placement) check fires and aborts compilation before
   the older E4034 (missing-archive) check the trial is meant to exercise ever runs.
2. **Missing link file**: `error_enforcement_addition/ffi_addition/error_app_sidecar_metadata/dangerous_missing_foreign_symbol_at_link`
   reports "silica.link not emitted" — cause not identified.
3. **Whitespace-only diffs**: `error_enforcement_addition/stmt_missing_semicolon_between_binding_and_tail_expr`
   and `_between_binding_stmts` — the diagnostic itself (E1040) looks right; the only diff is
   trailing-space formatting on lines like "Files to compile: " vs "Files to compile" — a
   print-statement bug, not chased down.

### Also recorded, not yet fully explored
- **Mass golden staleness side effect**: INTEGRATE's list_addition run (20:20:19, its combined
  build) shows 971/95, not the expected 971/1 — 94 of those are `.sams differs from .ascomp`
  on `train_list_fold_*` trials from a genuine tail-call-optimization codegen change (0
  behavior regressions confirmed — every one logs "output matches .scout"). Reaching green
  needs ~94 assembly goldens regenerated in list_addition alone, likely more in
  memory_region_addition/recursive_function_addition/supervisors_addition once those suites
  are run under the combined build (not yet done as of stand-down).
- **Cross-unit-atoms** (rows 26-27, lane agent-ad9a47f7b9cec922b): held per main's ruling
  until everything else is merged and green, then lands alone with its five supervisors
  goldens refreshed. Do not merge early.
- **Rust linker retired**: clang only going forward; GNU linker variant stays for Linux. Any
  ledger row that would call for regenerating a rust-lld-produced golden is a **deletion**
  instead. No row currently needs this, but apply it if one surfaces.
- Suites still fully un-run under any combined build as of stand-down: memory_region_addition,
  recursive_function_addition, supervisors_addition, traits_addition, generic_modules_addition
  (full suite), modules_addition (intentionally held), case_addition (INTEGRATE was running it
  at stand-down), actors_addition, string_addition, codegen_defects_addition.

## Open work
- Reconcile every "(S)" row against the live baseline once it reaches that suite (in
  progress; suites completed so far all clean except the compile_defects_*/codegen_defects
  families, which are fresh and confirmed still red).
- Verify each "likely covered, unverified" claim by actually applying a patch in isolation
  and building — not yet done. Do not report any of these as fixed until a build confirms.
- Suites with no prior report (actors_addition, bitwise_addition, case_addition,
  compiler_addition, cpu_discovery_and_spawn_pinning, error_enforcement_addition,
  ordered_data_structures) still need first-time fresh results.
