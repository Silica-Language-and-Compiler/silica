# Chunk 15 phase 3: running notes (Fable)

Design: [chunk15_stack_memory_design.md](chunk15_stack_memory_design.md) §2.2, §2.3, §4, §5.4, §11.1 row 3, P5, P6, P15.
Branch `phase3-chunk15` (starts at the phase 2 merge, 0adcec2d8c). Nothing here is committed by the
implementing agent; the main session commits. Builds and trial runs are done by Haiku agents, one at a time,
under the build-slot lock; builder `/Volumes/2T/silica/binaries/silica-compiler` (999939, phase 2).

## 1. Stages and status

**Published (2026-10-31).** The phase 3 selfhost compiler is `binaries/silica-999937-macos-applesilicon` (sha1 85f61850d62404af2b389a1acaacabab8fffa73e), reached through `binaries/silica-compiler`. It was built from the stage 3d sources with the scratch bootstrap binary, and its goldens and the final gate run are not yet verified. The seed is unchanged. Not committed.

**Phase 3 is closed (Lee, 2026-10-31).** The phase-3 completion gate is no longer a blocker: the memory target and stage 3e were removed from it on 2026-10-30, and Lee has now closed phase 3. The 3d gate run on the rebuilt compiler is kept as the record of that compiler's output.


| Stage | What | Status |
| --- | --- | --- |
| 3a | `state_policy(...)` accepted (optional) after `stack_policy(...)` in every hosted spawning form; `compact_state()` builtin; ACB #576 stored at spawn, #584 set by `compact_state()` under `:compact_on_request`; no behaviour change | code done (Mac + the shared front end; ESP32 accepts the prim as a pass-through); Haiku build + gate: see §5 |
| 3b | per-slot copier tables, free lists (§2.3, §5.4, P5) | Mac source written 2026-10-29 (§10), not built; Linux twins listed, not applied |
| 3c | dispatch end (§4.1-§4.7), W2300/E2321, `strict state_release;` | Mac source written 2026-10-30 (§10.8), not built; `strict state_release;` / E2321 and the `\|_upd=` update-call rules deferred (§10.8.4) |
| 3d | `state_policy` required (E2005), the bootstrap rewrite script | not started |
| 3e | linux_aarch64 / linux_x86_64 ports | not started; removed from the phase-3 completion gate by Lee (2026-10-30); Linux and ESP32 ports move to after phase 7, and no Linux builds run until phase 7 (Lee, 2026-10-30) |

## 2. Stage 3a: what was done

Lee's answers (2026-10-27, through the coordinator) shape this stage: Q2, `state_policy` is a first-class type
(bound, passed and returned like a `stack_policy` value); Q1, a child spec carries `state_policy` as a field
(required from 3d, optional in 3a, exactly as for the spawn argument).

**The value and the word.** `state_policy(choice)` is a constructor of the built-in scalar type `state_policy`
(type interner kind 56). Its value is one word, the choice index << 4: 0 `:keep_state_area`, 16
`:shrink_after_compaction`, 32 `:compact_on_request`. A spawn's state policy is joined into the stack-policy word
by the prim `spawn_policy_join` (bits 4-5). `stack_policy` now rounds the reserve to 64 instead of 16, so the
word is: bits 0-3 the release algorithm, 4-5 the state policy, 6 and up the reserve. The flat spawn chains
(`[beh, policy(, core)]` and the registered forms) keep their shape, so no emitter offset moves. The `.ascomp`
of every spawn site with a stack policy drifts (`ADD X9, X9, #63` / `AND X9, X9, #0xffffffffffffffc0`).
`_silica_rt_actor_stack_reserve` masks the reserve with `~63`, stores `ubfx(word, 4, 2)` at ACB #576, and
stores `#360` (the word a row child inherits) without the state bits.

**Optional argument (3a).** Argument p + 1 (p = the stack policy's position) is the state policy when it is a
`state_policy(...)` constructor or any expression of type `state_policy`; otherwise it is the core id. The type
checker decides with `check_surface(arg, "state_policy")`; the SIR lowering lowers the argument and compares its
SIR type with `state_policy`. Arity messages are unchanged in 3a ("expects 3 or 4 arguments ..."), so no
`.golden_fail` moves; they change in 3d.

**Child specs (Q1).** New child-spec ABI (Mac): shape@0, id@8, agent_type@16, initial_state/start.0@24,
behavior/start.1@32, restart@40, shutdown@48, flavor@56, **state_policy@64**, hidden supervisor
trampoline@**72** (was 64). The record was already allocated at 80 bytes, so its size does not change.
* A child spec without the field gets 0 at @64, stored by `term_child_spec@emit_child_spec_hidden_trampoline_store`.
* A child-spec list cell is now 80 bytes in every case (was 72).
* Child-table row nodes grow from 128 to 136 bytes; +128 holds the spec's state policy, copied by materialize
  and by start_child (add_child).
* `_silica_rt_actor_spawn_linked` ORs the row's +128 into the policy word of every start and restart of a row
  child.
* The type checker requires the field's type to be `state_policy` when the field is spelled (E2092, the code
  for the other child-spec field rules).
* Projections of child-spec fields read declaration-order offsets, as for the seven fields today, so the field
  must be written after `flavor` (the Supervisor trait's order). This is not enforced, as the order of the
  other seven fields is not.

**Front end (shared by all targets).**

* `type_checker/type_interner.silica`: `kind_state_policy` (56), name maps both ways.
* `type_checker/type_checker_builtin_signatures.silica`: `state_policy` -> `state_policy`.
* `type_checker/expressions/type_checker_expressions_helpers.silica`: `call_nth_arg_expr`, `is_state_policy_call`.
* `type_checker/expressions/type_checker_expressions_actor_spawn.silica`: `spawn_state_policy_present`,
  `spawn_policy_arity_ok`, `check_spawn_policy_tail` (stack policy, optional state policy, optional core id;
  every hosted spawn form), `check_spawn_state_policy_arg`, `check_state_policy_constructor_call` (one known
  atom literal; E2003 against a non-`state_policy` expected type), `compact_state` (0 arguments, `unit`).
* `type_checker_expressions_call_region_actor.silica`: routes `state_policy`.
* `type_checker_tuple_decompose_helpers.silica`: `compact_state` -> `unit`.
* `type_checker/type_checker_supervisor.silica`: `supervisor_child_spec_state_policy_field_ok`.
* `effect_checker/effect_checker_core.silica`: `compact_state` needs `mem(normal)`.
* `sir_generator/terms/terms_actor_lowering.silica`: `lower_spawn_policy_tail`, which returns (policy word, core
  position) and has 8 parameters. The first build failed with E1070: its 9-parameter predecessor
  `lower_spawn_policy_word` broke the parameter limit, and the limit is kept. Also `lower_state_policy_expr`.
* `sir_generator/terms/actor_calls.silica`: `build_state_policy_prim`, `build_spawn_policy_join_prim`,
  `compact_state` (nullary runtime helper).
* `sir_generator_core.silica`: `compact_state` listed.

**apple_silicon_mac.**

* `terms/prims/prims_actors.silica`: `emit_state_policy` (`MOV dest, #idx*16`), `emit_spawn_policy_join`,
  `stack_policy` packs to 64, `compact_state` -> `BL _silica_rt_compact_state`.
* `terms/prims/prims_actors_stack_asm.silica`: reserve mask, ACB #576.
* `terms/prims/prims_actors_runtime_asm.silica`: `_silica_rt_compact_state` (#584 = 1 only when #576 = 2;
  nothing in `main`; nothing reads #584 until 3c); spawn_linked ORs the row's state policy.
* `terms/prims/prims_actors_child_table_asm.silica`: rows 136 B, +128, payload @64/@72.
* `terms/term_child_spec.silica`: ABI table, hidden word at 72, default store at 64.
* `terms/prims/prims_list.silica`: child-spec cell 80 B.
* `shared/reg_conventions.silica` (frame-free scalar), `terms/term_reg_spill.silica` (one-word handle),
  `terms/term_message_copy.silica` (word type): `state_policy`.

**ESP32-S3_raw**: `state_policy` (value 0) and `spawn_policy_join` (the stack policy word passes through) are
accepted, so the 3d rewrite of the board apps does not break the cross compiler; the board keeps no state area
until phase 9. `compact_state()` and the child-spec field are not emitted for the board (phase 9).

**linux_aarch64 / linux_x86_64**: not ported yet (3e). Until then a program using `state_policy`,
`compact_state` or a child-spec `state_policy` field miscompiles or is rejected there: the old child ABI keeps
the trampoline at 64. Nothing in the tree uses any of them yet. The 3e port must carry the whole Mac diff,
child table included.

## 3. Questions for Lee

* Q1, Q2: answered 2026-10-27 (above).
* **Q4 (blocks 3a's gate): quadratic evacuation in the compiler's own non-tail recursions.** See §5, "3a
  gate 2". The 3a compiler is the first one whose own code was generated by the phase-2 code generator:
  999939 was built by the phase-1 compiler 999940. Phase-2 codegen evacuates a let-bound call result at
  every level (design §3.3 (b), §3.4: "a let's right-hand side whose name is later read ... is evacuated at
  that site"). So `rest <- f(t); cons(x, rest)` costs O(N²). The design avoids this only for the
  unbound form `cons(x, f(t))`. The options need Lee:
  * (a) Extend the §3.4 rule: a let in return position whose bound name is read only as an operand of
    return-position allocations or non-TCO return-position user calls adopts its call instead of
    evacuating it. This is safe, because adoption only keeps memory. It must exclude names that reach a
    kind-5 TCO tail call: a loop would keep every iteration's frame, as in the S9 defect.
  * (b) Rewrite the idiom in the compiler and stdlib sources into the unbound form. §11.2 allows this as
    the idiom the model asks for, but user programs keep the quadratic cost.
  Recommended: (a). Design §3.4 changes, with a trial (`recursive_function_addition/map_return_position_linear`
  already names the bound variant's cost) and all three trees.
* **Q3 (3d, the code for a missing child-spec field).** The coordinator's brief says "E2005 when a child spec
  omits it". The existing child-spec field rules (a missing `flavor`, `restart`, ...) are E2092 (the init
  return-type shape check). 3d will use E2092 for a missing `state_policy` field unless Lee wants E2005 there.

## 4. Trial requests (for Sonnet; names from design §11.3, phase 3 rows)

Stage 3a needs these now (positive ones run with the 3a compiler; the `missing_*` ones only become errors in 3d):

* `error_enforcement_addition/state_policy_not_literal` (E2005: `state_policy(k)` with `k` an atom binding),
  `error_enforcement_addition/state_policy_before_stack_policy` (E2005 at the third argument: "must be a
  stack_policy"), plus (not in §11.3, covering 3a rules) `state_policy_unknown_choice` (E2005),
  `state_policy_wrong_type_binding` (E2003 on `p: stack_policy <- state_policy(:keep_state_area)`),
  `compact_state_wrong_arg_count` (E2005), `supervisors_addition` or `error_enforcement_addition`:
  `child_spec_state_policy_field_wrong_type` (E2092, the field typed `int64`).
* Positive: `actors_addition/state_policy_value_bound_and_returned` (a `state_policy` bound, returned by a
  function and passed to `spawn` / `spawn_registered` with a core id); `supervisors_addition/child_spec_state_policy_field`
  (init list and add_child with the field; the shape of `scratchpad/p3/probe3a/pos2/sup.silica`).
* `error_enforcement_addition/state_policy_missing_in_spawn` and `..._missing_in_spawn_registered`: write them in 3a,
  they are expected to compile until 3d (stage them, golden after 3d).
* `actor_stacks_addition/state_policy_compact_state_noop_under_keep` can be written now (a behaviour that calls
  `compact_state()` under `:keep_state_area` and `:shrink_after_compaction`; output unchanged); the other four
  `state_policy_*` trials need 3c.
* A positive form trial (not in §11.3): every hosted spawning form with `state_policy(...)`, with and without a
  core id (the scratch probe `scratchpad/p3/probe3a/pos/sp.silica` is the shape).

## 4a. Sites for 3b/3c (read 2026-10-27, apple_silicon_mac)

* Behaviour epilogue today: `prims_actors@behaviour_result_evacuate_asm` (L_ev_heap / L_ev_heap_shell of the
  new state and reply into the actor heap, phase 2 interim), then `behaviour_result_move_asm` ->
  `bmv_reply_asm` (reply into the caller's arena, `_silica_rt_region_alloc_in`) and `bmv_state_asm` /
  `bmv_state_reuse_asm` (state shell to the heap, tagged block `ACB ^ 0x5C1A57E0...`). These are what 3c
  replaces with `_silica_rt_state_evacuate` / `_silica_rt_state_copy_all` and deletes last.
* Spawn today: `spawn_deep_copy_asm` (stack value walked to the spawner's heap, then `L_mc_root` deep copy
  unless `|mv` / elided) and `spawn_promote_init_x11`; the runtime stores the pointer at ACB #0
  (`stp x21, x20, [x19]` in `_silica_rt_actor_spawn`). 3b replaces this with the per-slot copy into the
  child's state area (§5.4), after `_silica_rt_actor_stack_reserve` has made the reservation.
* `prims_actors_stack_asm.silica` header: the 1,040-byte header above the edge is still released by
  `:release_on_return` "until the state area exists, phase 3": 3b/3c must make every release path keep
  `[edge, top)` committed (design §2.4 rows).

## 5. Build / trial log

* 3a build 1 (Haiku): FAILED, E1070 at `terms_actor_lowering.silica:519` (`lower_spawn_policy_word` had 9
  parameters). Fixed by restructuring (8 parameters), no limit change.
* 3a build 2 (Haiku, with Q1/Q2): build + probe (`scratchpad/p3/probe3a`) + gate (functions, records, tuples, list,
  string, memory_region, actors, carriers, supervisors, actor_stacks, error_enforcement, ordered_data_structures):
  build PASS; run_FAIL = 0 in every suite. **Compile hangs** (900 s harness timeout) in carriers_addition,
  ordered_data_structures (stdlib batch, at `lib/wbt_set.silica`) and 6 multi-file trials of
  error_enforcement_addition. That suite's exit 2 comes from those 6: its 10,962 single-file trials matched.
  Root cause (sample + disassembly of the 3a compiler):
  * The hot thread is in `constraint_runner_tokens_to_slots`, about 512 frames of self-recursion; the top of
    stack is in the module-local helpers after `constraint_runner_parse_program`.
  * `tokens_to_slots+408` is the return address of the recursive `BLR`, followed by the `L_ev_frame`
    descriptor load.
  * The source (`parser/constraint_runner.silica:135`, unchanged in phase 3) is
    `rest <- tokens_to_slots(tokens.tail); cons_slot(slot, rest)`. Each level evacuates the whole remaining
    slot list: O(N²) in the file's token count.
  * The phase-2 compiler 999939 compiles the same batch in 4 s because its own code came from the phase-1
    code generator.
  * Not a phase-3 defect: the 3a changes do not touch the parser, and the evacuation call is phase-2
    codegen. This is the self-hosting risk of design §11.2 row 1, which phase 2's smoke test (`trials/base`
    only) did not reach. Question Q4.
  * Harness gap (for Sonnet): `compile_isolating.sh` cannot blame a unit for a timeout ("named: 'none'").
    It could attribute the hang to the last unit the progress lines name ("Parsing <file>").
* 3a probes (Haiku, 3a compiler): `pos` printed 3, 7, 12, 20, 27, 34, 0 and `pos2` printed 11, 32, 0 (both exit 0).
  `.sams` shows the 64-rounding, the join (`AND X9, X9, #0xffffffffffffffcf` / `AND X10, X10, #0x30`) and
  `BL _silica_rt_compact_state`. All 8 negatives give the expected code (E2005 x5, E2003, E2092; too-many-args
  E2005). The first probe failures were my probe programs (E2236: no failure reporter; then E3010: an unused
  `device_io`), not compiler defects.

## 6. Q4 fix: state at the HALT (2026-10-28)

Lee chose (a). The coordinator halted the work before any build of it.

**Edited, never built or run:**
* `compiler/src/sir_generator/sir_return_position.silica` (shared front end, so it covers all three emitter
  trees):
  * `rp_call_nodes(body, fname)` now takes the function's name.
  * New rule: a let in return position whose value is a user call adopts that call (its node index joins the
    `|_rpn=` list) when the value's type may hold a pointer and the bound name REACHES THE RESULT. Reaching
    means the name is a direct operand of a return-position allocation, a direct argument of a
    return-position user call, or a direct argument of the value call of a later return-position let whose
    own name reaches the result.
  * Other reads of the name are allowed.
  * A non-tail self call as the let's value is allowed (the parser shape).
  * No let is adopted in a function that calls itself in return position (`rp_has_self_call`), so a TCO
    loop's iteration frames cannot accumulate (S9).
  * New helpers: `rp_let_value_adoptable`, `rp_type_may_point`, `rp_reaches_result`, `rp_operand_reaches`,
    `rp_call_args_name`, `rp_rest_args_named`, `rp_arg_is_name`, `rp_has_self_call`.
* The `rp_call_nodes` call site in `emitter_core.silica` now passes `fn_val.name`, in the
  apple_silicon_mac, linux_aarch64 and linux_x86_64 trees (one line each).
* Scratch only (not in the tree): `scratchpad/p3/scale/prog/scale.silica`, the four-shape scaling probe.
  It prints shape, n, length, sum and the best-of-three ns for n = 2500 .. 20000. The compile-time scaling
  input (n, 2n, 4n, 8n tokens) is not written yet.

**Not done:** no build; no scaling measurement; no rerun of carriers_addition, ordered_data_structures or the
6 multi-file error_enforcement trials; no design §3.4 text change; no trial requests written yet.

**Shapes and coverage (by reading, not measured):**
* (1) `rest <- f(t); cons(x, rest)`: covered.
* (2) a let-bound list passed through one intermediate call before the cons: covered when every step is a
  let-bound call in return position.
* (3) a let-bound result used in return position and also read: covered.
* (4) the tail-call loop: deliberately never adopted.

**Not covered (still evacuated, possibly quadratic):**
* A let-bound result that reaches the result only through a non-call expression, for example a case
  scrutinee, a record projection, or an argument nested inside another expression rather than a direct
  argument.
* A let whose value is not a user call: a case or block value, or a prim such as `list_cons`.
* Any let in a function that also calls itself in return position (a recursive function with both a TCO arm
  and a non-tail recursive arm).

**Compile-time cost:** about O(lets² × nodes) per function, because `rp_node_at` walks the list. This is
unmeasured; the heaviest units (emitter_core) need an RSS and time check.

**Harness gap (Sonnet):** `compile_isolating.sh` should blame the last `Parsing <file>` unit on a timeout.

## 7. Step A (option 2: rewrite the hot parser builders), 2026-10-28

**Rewritten** into the form the committed rule adopts: the recursive call passed straight to `prepend` (a
`list_cons` operand), inside a `sequence proc[mem(normal)] ... produces pure p_out end`. The sequence is
required: `prepend` outside one is E3001. The sites:
* `parser/constraint_runner.silica` `tokens_to_slots`.
* `parser/constraint_extract_slots.silica`: `take_prefix_before_role`, `take_prefix_before_role_or_of_keyword`,
  `take_prefix_before_branch_arrow_balanced` (7 arms), `take_prefix_before_if_keyword`.
* `parser/constraint_extract_decls.silica` `declarations_from_slots`.
* `parser/parser_ast.silica` `expr_remap_nodes_onto`.

The Q4 option (a) edit of `sir_return_position.silica` and the three `emitter_core` call sites is set aside
(reverted in the tree; saved as `scratchpad/p3/stepB/q4a.diff`) so Step A measures option 2 alone.

**Other bind-then-cons builders found** (scan `scratchpad/p3/scan_bind_cons.py`, 41 hits, a few false
positives), not rewritten:
* effect_checker `stamp_effect_locations`.
* parser_ast `param_list_normalize`.
* sir_generator `type_context_env_to_sir_env`, `emit_declarations`, `mangle_decls`.
* type_interner `strings_append`, `list_int_append_dag`.
* trait_specialization `nodes_with_copy_tag`, `specialize_decls`, `specialize_trait_param_decls`.
* stdlib `graph_csr_core` / `graph_dense_core` / `graph_wbt_core` `*_go` and `slot_pairs` (12).

**Measured** (Haiku, generated single files of k functions, about 18 tokens each; 600 s cap):

| k (tokens) | 3a + Step A compiler | 999939 (phase 2, built by phase 1) |
| --- | --- | --- |
| 1250 (22.5k) | 93.5 s | 5.5 s |
| 2500 (45k) | > 600 s (killed) | 1.7 s |
| 5000 (90k) | > 600 s | 6.0 s |
| 10000 (180k) | > 600 s | 25.7 s |

The ordered_data_structures batch now gets past `wbt_set` (61 s for that unit, against 4 s), so the
tokens_to_slots hang is gone. Compile time is still far from linear. **BLOCKER.**

**Where the time goes now** (sample at 20 s and 120 s of the k=2500 compile, all inside "Parsing"):
* `constraint_extract_lambda_lift@lift_decl_list` (all samples at 120 s). It returns a record
  `{ decls, seq, lifted }`; each level binds the recursive result (`pack3 <- lift_decl_list(...)`), projects
  its fields and rebuilds the record. The bound record reaches the result only through projections, so
  neither the committed rule nor option (a) adopts it, and every level evacuates the remaining declaration
  list with every declaration's AST.
* `constraint_extract_decls@append_decl_lists` and `append_declaration_lists`: `cons_declaration(a.head,
  append_decl_lists(a.tail, b))`. The recursive call is an argument of a user call, which no rule adopts.
* `constraint_runner_parse_program` (local helpers: the evacuation code).

**Conclusion.** The shape is pervasive in the compiler's own code. Fixing it one site at a time (option 2)
does not converge. The analysis needs at least:
* (i) an argument of a return-position user call (bound or not) adopts;
* (ii) a let-bound result whose projections reach the result adopts.

Both only keep memory, so they are as safe as (a); the cost is retention of the callee's garbage until a
consumer evacuates. This is a design decision for Lee.

## 8. Step B (option 1 extended: shapes (i) and (ii)), 2026-10-28

**Code** (`sir_generator/sir_return_position.silica`, shared front end; the three `emitter_core` call sites pass
`fn_val.name`): the Q4 (a) let-bound rule restored from `q4a.diff`, plus two extensions:
* (i) the arguments of a return-position user call are in return position (`rp_call_args_from`), so an
  argument call adopts;
* (ii) a projection (`record_proj` / `tuple_proj` chain) of a let-bound name counts as the name, and a later
  let whose value is the name, a projection of it, or a call with it as an argument passes reaching on.

Both are off in a function that calls itself in return position (the TCO loop exclusion).

**Haiku measurements, "stage 1" compiler** (this source built by 999939):

| unit | 999939 s / peak RSS | stage 1 s / peak RSS |
| --- | --- | --- |
| emitter_core | 8.5 / 3,585 MB | 90.4 / 256 MB |
| wbt_map | 8.2 / 2,731 MB | 165.5 / 471 MB |
| type_checker_expressions_actor_spawn | 9.4 / 4,389 MB | 128.9 / 515 MB |
| type_checker_expressions_actor_supervision_messaging | 4.5 / 2,197 MB | 52.3 / 328 MB |
| type_checker_expressions_binary_ops | 4.8 / 2,379 MB | 46.8 / 305 MB |

Parser batch (generated, k functions): 999939 0.5 / 1.6 / 5.9 / 24.9 s (peak RSS 0.9 / 3.0 / 6.3 / 7.0 GB);
stage 1 96 s at k=1250 (141 MB), killed at 600 s for k = 2500, 5000, 10000 (RSS 266 / 520 / 1,036 MB at the
kill).

Gate (stage 1 compiling the trials): **run_FAIL = 0 in all 12 suites** (functions 666, records 458, tuples 635,
list 537, string 671, memory_region 423, actors 368, carriers 37, supervisors 115, actor_stacks 11,
error_enforcement all matched, ordered_data_structures all runs matched). No compile timeouts: the
carriers / ordered / error_enforcement hangs are gone. Exit 2 only from `.ascomp` drift: the 64-byte
stack-policy pack, the child-spec ABI (80-byte cells, @64/@72), and evacuations that are now adoptions
(e.g. `records_addition/03_struct_in_list`: `L_ev_frame` -> `BL L_adopt`, the intended effect). The four
shapes were not measured: the scaling program was rejected with E3010 (unused effect, my probe's fault,
fixed in scratch).

**Why the compiler itself is still slow.** Stage 1's own code was generated by 999939, which has the phase-2
rule and not the new one, so the analysis change cannot speed stage 1 up. Only Step A's source rewrites
reach stage 1's own code. What these numbers show is phase-2 codegen applied to the compiler, which is
10-20x slower per unit and 7-14x smaller in RSS (values live in frames instead of the heap). To measure the
rule on the compiler itself, stage 2 is needed: this source rebuilt with stage 1 as the builder, then the
same unit and batch measurements on stage 2. With stage 1 about 10x slower per unit, that full build may
take several hours; it is the coordinator's call.

## 9. Stage 3a confirmation on the stage-2 compiler (2026-10-28)

* Gate (stage 2 on every make line, `stage2_trials/SUMMARY.txt`; see `Phase3_stage2_analysis.md` §1):
  run_FAIL = 0 in all 12 suites. The non-zero exits are `.ascomp` drift only. No `.scout` changed.
* Probes (stage 2): `pos` printed 3, 7, 12, 20, 27, 34, 0; `pos2` printed 11, 32, 0; all 8 negatives gave
  their codes (E2005 x5, E2003, E2092; too-many-args E2005).
* The two exit-70s of the stage-2 measurements, read from their stderr:
  * The shapes probe: `[silica] fault ... in main ... actor=0x0`. The probe's own `main` recursed 20000 deep
    in shape 6 on the 8 MB OS stack (design §13 item 11, decision 9). This is the probe's construction, not a
    compiler defect; a re-run must do the work inside an actor.
  * The parser batch at k=10000 (stage-2 compiler, while Emitting): `fault ... addr=0x82ffede330
    sbase=0x8300000000 ssize=0x4c0000000`, with `time -l` reporting peak memory footprint 20,412,791,496
    bytes and maximum RSS 5.7 GB. The fault address is below the reservation's base, so the emitting actor
    used its whole 19 GB stack reservation. Retained (adopted) frame memory in the emitter is the likely
    cause, ranked 1 in `Phase3_stage2_analysis.md` §2 but not attributed.
* **Open (removed from the phase-3 completion gate by Lee, 2026-10-30):** the whole-batch memory target (4 GB) fails badly at 180k
  tokens (20 GB footprint, then a stack fault), and parse time and memory still grow quadratically
  (§2 of the analysis). Lee's decisions listed in `Phase3_stage2_analysis.md` §5 are open.


## 10. Stage 3b: the state area, its free lists and the per-slot state copier (2026-10-29, Mac source)

Scope (coordinator's brief): spawn, restart and the fallback copy each state slot with its own copier
table (P5; design §4.4 step 1, §5.4), the free lists of the state area (§2.3). No retire, no dispatch-end
change (3c). The stage-3a syntax and type are unchanged. Nothing here is built or run by the implementing
agent; Haiku builds and checks (§10.5), Sonnet reads the results.

### 10.1 What the actor now does

* **Spawn.** `_silica_rt_actor_spawn` (X6) and the `spawn_linked` family (`LBBsl_common`, X7) take the
  ROOT-WORD descriptor of the initial state's type (`L_sd_<fn>_<node>_0: .quad 1, -1; .quad KIND, AUX`,
  the form the evacuation sites already emit) and, right after `_silica_rt_actor_stack_reserve` and before
  the actor can run, call `_silica_rt_state_install(acb, value, desc)`: it measures the value, takes one
  block of the measured size rounded to 16 from the state area (`_silica_rt_state_alloc` first commits the
  header's page when the committed run does not reach `top - 1040`, §10.7, then extends the edge,
  committing pages through `_silica_rt_stack_grow_to`), copies the value into it with one copier table per
  state slot and stores the copy's root at ACB #0 (design §5.4: "into the child's base"). A scalar or atom
  state, and a state whose type the descriptors do not follow (X6/X7 = 0), is stored as given, as before.
  A state the child's reservation cannot hold (a lowered reservation) fails the spawner with
  `(:explicit, :state_too_large)` (decision 39's atom, already in the table); in main the process aborts
  with status 71 ("the initial state does not fit the actor's reservation"). The spawner no longer walks
  the state into its own heap (`L_evp_*`) nor deep-copies it with `L_mc_root`: the runtime copier reads it
  where it lies (frame, heap, literal). `|mv` / `|_mvs` do not apply to a spawn (decision 15: the child's
  state must lie in its own stack).
* **Restart (Q14).** A child spec record carries a hidden word at 80: the same root-word descriptor for
  its `initial_state` / `start.0` type (`L_sdc_<fn>_<node>_0`), written by its record_make beside the
  trampoline at 72. Materialize and start_child copy it into the row (+136, rows 136 -> 144 B), and
  `_silica_rt_actor_spawn_linked_row` passes the row's +136 as X7, so every start and restart copies
  start.0 into the new child's state area exactly as a plain spawn does.
* **Slots (P5).** A slot is a node-bearing position reached from the root only through by-value
  aggregates (records, tuples, sums). The copier walks the root's spine with the table and EMPTIES the
  table (`memset`, count 0) before each word of kind REF1 / REFTUP / BUF / LIST / STRING it meets on the
  spine; inside a node the spine flag is off. A node reachable from two slots is therefore copied twice,
  and within a slot sharing is kept. The measure clears at the same points, so its byte total is the
  copy's; a disagreement (the copy's cursor passing its block) aborts the process ("state copy overran
  its measured block"), never a silent overrun of the state area.
* **Sizes** are `L_mc_measure`'s (aggregate N*8; REF1 8; REFTUP payload rounded to 16 plus 8; buffer
  length word plus elements rounded to 8; list handle 24 and CDATA + 16 per chunk, walked from the cursor
  (later chunks from their claim word) for the handle's length of elements; run-time string 24 + length +
  1 rounded to 8; literal strings, atoms, scalars, region witnesses and function values as words). Two
  additions over the phase-0 measure: inline aggregate slots of a list chunk (child specs and the
  runtime's inline records) are walked in place, and the copy clears the next pointer of the chunk that
  holds the last element, so a copied spine never points into the source's memory. A chunk shared by two
  handles is copied once per handle (the measure counts it per handle); decision 30's shared copy of
  chunks is phase 4's.
* **Free lists (§2.3).** `_silica_rt_state_alloc(acb, n)`: `n <= 1024` pops head `n/8 - 1`; `n > 1024`
  walks head 128 for an exact size (the size in the node's second word); else extends the edge.
  `_silica_rt_state_free(acb, node, n)` pushes. ACB #568 counts live bytes. Nothing frees in 3b (3c's
  release-log drain does); the free lists are exercised by allocation only.
* **Release (§2.4, decision 27).** `_silica_rt_stack_release_to` keeps `prefix_for((top - edge) + X1)`
  whenever the state area holds nodes (`top - edge > 1040`), whatever X1 (`:release_on_return`, the idle
  sweep, `_silica_rt_stack_idle_check` all pass X1 = 0): a non-empty state area is never decommitted while
  the actor lives. An EMPTY area (a scalar state: the edge is still `top - 1040`) is released as in phase
  0: the 1,040-byte header is all zero then and comes back zero with the next commit, so a scalar-state
  actor under `:release_on_return` still holds no stack between messages. This keeps every existing
  `get_actor_memory_usage` trial (all have int64 states; `stack_release_on_return_shrinks`,
  `stack_many_idle_actors_hold_nothing`, `many_actors_one_carrier`) at `committed == 0`; a composite-state
  actor now shows the state pages (one 16 KB chunk at least) in `committed` and `high_water`, which is the
  observable change design §11.6 names ("the first page of the child's reservation is committed at spawn").
  That sentence is true only since §10.7: the reservation is made PROT_NONE with `#288 = 0`, and it is
  `_silica_rt_state_alloc`'s header commit, on the spawn's install, that commits the top chunk; nothing
  else does before the child's first fault.
* **The edge is an SP.** The spawn block is rounded to 16, so `#528` stays 16-byte aligned (every dispatch
  starts with `mov sp, [#528]`). 3c's node-by-node evacuation (exact 8-multiples) must round the final edge
  down to 16 (at most 8 bytes of slack) or align the SP at the switch sites.
* **Dispatch end is unchanged** (phase 2 interim): a behaviour returning its state unchanged keeps the
  state-area root (`bmv_state_asm`: same pointer, nothing moves; `L_ev_heap_shell` finds no new node in
  it); a behaviour returning a new state still promotes its shell to the actor heap and installs it, so
  from the first state change on the state area's nodes are garbage until 3c (never freed, never read;
  the area stays committed). The `bmv_state_reuse_asm` tag test reads `[root - 8]`, which for a state-area
  root is the first word of the behaviour's own frame (a saved X30), never the tag: a fresh block, as for
  any untagged current state.

### 10.2 Files changed (apple_silicon_mac) and the design section each implements

* **New** `emitter/apple_silicon_mac/terms/prims/prims_actors_state_asm.silica` (§2.3, §4.4 step 1,
  §5.4, P5): `_silica_rt_state_alloc`, `_silica_rt_state_free`, `_silica_rt_state_measure`,
  `_silica_rt_state_copy`, `_silica_rt_state_install`, `_silica_rt_spawn_state_too_large`; local
  `Lstc_*` (table, sum lookup, copy walkers), `Lstm_*` (measure walkers). Emitted once, in the runtime
  unit (`__silica_runtime`), so the restart path can reach it.
* `terms/prims/prims_actors_runtime_asm.silica`: `use prims_actors_state_asm`, the helper in
  `emit_actor_runtime_helpers`; `_silica_rt_actor_spawn` frame 80 -> 96, X6 -> X27, the install call after
  the reservation, `LBB0_state_failed` (identity, reservation, block back, then
  `_silica_rt_spawn_state_too_large`); `LBBsl_common` frame 80 -> 96, X7 -> X27, install from `[acb]`,
  `LBBsl_state_failed` (also releases the hold on the supervisor); `_silica_rt_actor_spawn_linked_row`
  loads X7 from the row's +136; the three runtime-internal spawns (registries) pass X6 = 0; ACB comment.
* `terms/prims/prims_actors_stack_asm.silica` (§2.4): `_silica_rt_stack_release_to` keeps a non-empty
  state area; header comment (#528, #568).
* `terms/prims/prims_actors_child_table_asm.silica` (§5.4 Q14): rows 144 B (`ensure_min_cap`), +136 the
  descriptor; materialize and `start_child_in` copy the spec's word at 80 into it; comments.
* `terms/ffi_fault_runtime_asm.silica`: `_silica_rt_abort_state_too_large`, `_silica_rt_abort_state_copy`
  and their reason strings.
* `terms/prims/prims_actors.silica` (§5.4): `spawn_state_desc_asm` (the X6/X7 load and the rodata),
  `spawn_no_desc`, `spawn_state_described`, `spawn_promote_init_reg` (the one-level shell promote only
  for an undescribed type); `emit_spawn`, `emit_spawn_registered`, `emit_spawn_linked` take the
  descriptor; `emit_spawn_registered_supervisor` passes X6 = 0; `spawn_linked` is routed through
  `emit_prim_op_with_atoms` (it needs the table); `spawn_deep_copy_asm` removed.
* `terms/term_child_spec.silica`: `emit_child_spec_hidden_trampoline_store/5` (outer_reg, table) also
  writes the descriptor word at 80 (`emit_child_spec_state_descriptor_word`); `child_spec_state_type`
  exported; ABI comment. Call site: `terms/term_emit_kind_compound_part1.silica` (one line).
* `terms/term_record_layout.silica`: a child-spec record_make allocates 96 (88 B record, 16-aligned).
* `terms/prims/prims_list.silica`: a child-spec list cell is 88 B.
* `terms/term_message_copy.silica`: `mc_agg_desc` emits a child-spec record's descriptor at its ABI
  layout, 11 words (`mc_child_spec_desc`), so every copy and evacuation of a spec carries state_policy,
  the trampoline and the descriptor word, and describes `start.0` at its real word (the spelled-field
  descriptor put `start`'s tuple entry where start.0 lies and lost the hidden words); header comment.

### 10.3 Decisions taken here (for the coordinator)

* The copier lives in the runtime unit as `_silica_rt_*` globals rather than in each module's `L_mc_*`
  family: a row restart happens in the supervisor's drain, with no emitted code at the site, so the
  copier must be reachable from the runtime; descriptors are data and travel by pointer.
* Child-spec records grow 80 -> 88 (allocated 96; cells 88), the fourth hidden-word change of this
  phase. The alternative (a per-type descriptor passed to materialize/start_child) does not reach
  `call_supervisor :add_child`, whose spec arrives in a message.
* The empty-area exception to decision 27 (above) is what keeps the spec's "nothing committed at
  spawn" for scalar states and the 10 memory-usage trials green without touching a `.scout`.
* The spine clear is table-emptying (`memset`), not a new table per slot: one allocation per copy.

### 10.4 Open items

* **3c** (next): `_silica_rt_state_evacuate` into holes / the edge (the free lists are ready), the
  release log, `_silica_rt_state_copy_all` = `_silica_rt_state_measure` + a fresh block from `top - 1040`
  + `_silica_rt_state_copy` with the scratch pass (the copier's bump destination can be a scratch block
  if the copy is given a relocation delta for the pointers it writes; not added in 3b), the 16-byte
  rounding of the edge, the removal of `bmv_state_*` and the phase-2 `L_ev_heap_shell` at the epilogue,
  `compact_state` reading #584.
* The row still points at the supervisor's own copy of `start.0` (the init list's cell / the add_child
  spec's heap copy) as its source; the row spec buffer (§5.4) is phase 4.
* The one-level `heap_promote` of a child-spec MESSAGE (`aggregate_message_type_bytes`, 72 B for the
  initial_state form) still copies the spelled words only; the deep paths (evacuation, `L_mc_root`) now
  carry 11 words. Pre-existing for the trampoline word; worth a trial that sends a `:supervisor` child
  spec through `call_supervisor :add_child` and restarts it.
* Undescribed state types (a type parameter, a trait type) still pass the pointer as before: no copy.
* `module_uses_message_copy` still counts a spawn as a copy site, so modules whose only copy site is a
  spawn keep emitting the (now unused there) `L_mc_*` helper.
* ESP32: nothing (phase 9). The board's `spawn_policy_join` pass-through is untouched.

### 10.5 Checks for Haiku (one at a time, build-slot lock)

1. Build: `make INSTALL_SELFHOST=0 SILICA_TARGET_PROMPT=0` in `compiler/src` with the published builder
   (`binaries/silica-compiler`, 999939), as for 3a build 2. Expected first-build risks: a Silica parse or
   type error in `prims_actors_state_asm.silica` (new unit; the topo script picks it up through
   `use prims_actors_state_asm`), the 5-parameter `emit_child_spec_hidden_trampoline_store`, the record
   result `{ load, data }` of `spawn_state_desc_asm`. Report the first error verbatim; no fix by Haiku.
2. The 3a probes again with the new compiler (`scratchpad/p3/probe3a`: `pos` 3 7 12 20 27 34 0, `pos2`
   11 32 0, the 8 negatives' codes): they spawn record states, so they are the first run of the copier.
3. The 12 gate suites: functions, records, tuples, list, string, memory_region, actors, carriers,
   supervisors, actor_stacks, error_enforcement, ordered_data_structures (`make integrate` per suite;
   run_FAIL must be 0; `.ascomp` drift is expected at every spawn site, every child-spec record_make,
   `__silica_runtime` and every module with a child-spec descriptor; `.sout` must equal `.scout`). Keep
   `stack_release_on_return_shrinks`, `stack_many_idle_actors_hold_nothing`, `many_actors_one_carrier`
   and `add_child_record_initial_state` in view: they are the trials this stage can move.
4. For Sonnet (new trials, design §11.3 phase 3 rows plus 3b): `actors_addition/state_slots_not_shared`
   (a record state `{ a: ref, b: ref }` built with one cell in both fields; the behaviour reports
   `ref_eq(state.a, state.b)`: false after spawn, and writing through `a` does not change `b`);
   `actors_addition/state_area_copy_kinds` (a state holding a List, a string, a ref, a buf, a nested
   record; values read back after spawn match); `supervisors_addition/restart_copies_initial_state`
   (a record initial_state, the child mutates it, crashes, and reports the initial values after the
   restart); `actor_stacks_addition/state_area_stays_committed` (a composite-state actor under
   `:release_on_return`: `committed > 0` and `retained == 0` after a message, `committed == 0` for an
   int64 twin); `error_enforcement_addition` or `actor_stacks_addition/state_too_large_lowered_reservation`
   (a spawn with `stack_policy(16384, ...)` and a state larger than the reservation ends the spawner
   with `(:explicit, :state_too_large)`).

### 10.6 The same diff for linux_aarch64 and linux_x86_64 (not applied; after the Mac passes)

The front end is shared; everything below is emitter-tree work. Symbols lose the leading underscore and
`@PAGE`/`@PAGEOFF` become the tree's own GOT-free addressing; the x86 twin goes through its `x86_isa` /
`x86_mem` helpers and its register map (X19-X28 -> the callee-saved r12-r15, rbx, rbp as the tree uses
them; X7 -> the seventh integer argument is on the stack there, so `LBBsl_common` takes the descriptor
from a stack slot).

* New `terms/prims/prims_actors_state_asm.silica` (both trees): the six globals and the walkers, a
  line-for-line port of the Mac file on AArch64; a rewrite on x86-64 with the same routine boundaries.
  Including the §10.7 header commit at the top of `state_alloc`: after `x21 = top - 1040` and before the
  size test, `ldr x10, [acb, #288]; cmp x10, #1040; b.hs Lsta_header_committed; mov x0, acb; mov x1,
  x21; bl silica_rt_stack_grow_to; cmp x0, #1; b.eq Lsta_fail; cmp x0, #2; b.eq Lsta_fail;
  Lsta_header_committed:` (x86-64: `cmp qword [acb+288], 1040; jae`, the two arguments in rdi/rsi, `cmp
  rax, 1/2; je Lsta_fail`). The Linux `stack_grow_to` has the same contract (0 grown, 1 exhausted,
  2 refused, 3 already committed) and the same first chunk `#304`, so nothing else changes.
* `prims_actors_stack_asm.silica` header comment, line 24 in both trees ("Nothing is committed at
  spawn."): the Mac wording of §10.7 (scalar state: nothing until the first fault; composite state: the
  top chunk through `state_alloc` on the spawn's install).
* `prims_actors_runtime_asm.silica`: `use` + concatenation; spawn and `LBBsl_common` frames grow one slot
  for the descriptor; the install call after the reservation with the two failure labels; `linked_row`
  loads the row's +136; the three registry spawns zero the descriptor argument.
* `prims_actors_stack_asm.silica`: the `release_to` prologue (keep a non-empty area); comments.
* `prims_actors_child_table_asm.silica`: 144-byte rows, +136 from the spec's 80 in materialize and
  `start_child_in`; comments.
* `ffi_fault_runtime_asm.silica`: the two abort entries and strings.
* `prims_actors.silica`: `spawn_state_desc_asm` / `spawn_no_desc` / `spawn_state_described` /
  `spawn_promote_init_reg`; the descriptor argument in `emit_spawn`, `emit_spawn_registered`,
  `emit_spawn_linked` (+ routing through the with-atoms dispatcher); `emit_spawn_registered_supervisor`
  zeroes it; `spawn_deep_copy_asm` removed.
* `term_child_spec.silica` (+ its call site in `term_emit_kind_compound_part1.silica`),
  `term_record_layout.silica` (96), `prims_list.silica` (88), `term_message_copy.silica`
  (`mc_child_spec_desc`): identical to the Mac edits (these files are twins up to spelling).
* The linux trees also still lack the 3a diff (§2, "linux_aarch64 / linux_x86_64: not ported yet"): 3e
  carries 3a + 3b together.

### 10.7 Regression fix: the header's page was read before it was committed (2026-10-29, Mac source)

**Symptom.** 28 trials faulted with exit 70 at `silica_rt_state_alloc+0x3c`, every one with a composite
(record or tuple) initial state; scalar states never reach the allocator. The four used as the first
check: `actors_addition/zero_heap_growth_tuple_state_int_message`,
`memory_region_addition/region_tuple_return_in_actor`, `supervisors_addition/supervisor_child_tuple_state`,
`actors_addition/cast_check_actor_state_accepted`.

**Root cause.** `_silica_rt_actor_stack_reserve` maps the reservation `PROT_NONE` and stores 0 at `#288`
(nothing committed), and both spawn paths call `_silica_rt_state_install` right after it
(`prims_actors_runtime_asm` 206-214 and 470-477), before the child has run an instruction. The install's
`_silica_rt_state_alloc` then read a free-list head in the header at `top - 1040` (the exact-size pop,
`ldr x10, [x9]`): a load from an inaccessible page, which the synchronous fault handler reports as a
fault (it is not stack growth: the faulting SP is not the child's). The design's "the header is zero
when the page is first committed, so an empty table needs no initialisation" (§2.3) assumed the page had
been committed by the time the heads were read; nothing committed it.

**Fix** (`prims_actors_state_asm.silica`, `_silica_rt_state_alloc`, right after `x21 = top - 1040` and
before the size test): when `#288 < 1040` (the committed run does not reach the header), call
`_silica_rt_stack_grow_to(acb, top - 1040)`; answers 1 (a lowered one-page reservation: the lowest page
is never committed) and 2 (the host refused) go to `Lsta_fail`, so the install answers 1 and the spawner
fails with `(:explicit, :state_too_large)` exactly as for a block that does not fit (decision 39). Answer
3 cannot occur (it means the run already reaches the address). A fresh commit reads as zero, whether it
is the first `mprotect` or the anonymous `MAP_FIXED` remap of a release, so the 129 heads are empty
without initialisation. The chunk is `#304`, the same first chunk a fault would have committed, so the
release algorithms' chunk sequence (`_silica_rt_stack_prefix_for`) is unchanged.

**Why in `state_alloc` and not in `state_install`.** The header and its free lists are the allocator's
(design §2.1, §2.3: the allocator is the only reader and writer of the heads, and §2.3's "no
initialisation" argument is about what the allocator finds). Making "the header is committed" a
precondition of its callers would leave the invariant with the spawn's install today and with 3c's
callers tomorrow (`_silica_rt_state_evacuate` into holes at dispatch end, `_silica_rt_state_copy_all`'s
fresh block from `top - 1040`), each of which would have to know how the stack is committed; placed at
the allocator's entry it is one load and one compare on every call and holds for all of them. The
`_silica_rt_stack_grow_to` committing primitive stays where it is; the allocator only asks it for the
top chunk, the same way `Lsta_extend` already asks it for the pages below the run.

**`_silica_rt_state_free`** is a leaf that pushes a node on a head. Its node came from `state_alloc`
(so the header was committed) and a state area holding nodes has `edge < top - 1040`, which
`_silica_rt_stack_release_to` never decommits (the keep branch; decision 27), and the committed run is
a prefix from the top, so the header stays committed for the node's whole life. No commit in the leaf.

**The release path** is unchanged and still right: after the header commit `#288` is one chunk
(16 KB) and the edge lies below `top - 1040`, so `release_to` takes the keep branch,
`prefix_for((top - edge) + X1)` is at least that chunk, nothing above the edge is remapped, and the
zeroing at `Lsrt_zero` is bounded to the bytes below the edge. For an empty area (a scalar state) the
edge is still `top - 1040`, `X1 = 0` releases everything, and the next commit, by a fault or by a 3c
`state_alloc`, reads the header as zero again. One thing 3c must keep: a compaction that moves the
edge back up to `top - 1040` must also zero the 129 heads, since a release of the then-empty area is
what makes them zero otherwise.

**Comments corrected.** `prims_actors_stack_asm.silica` header ("Nothing is committed at spawn." was
true before 3b and is now true only for a scalar state) and §10.1's release bullet above (the
"committed at spawn" sentence quoted from design §11.6 was not true until this fix).

### 10.8 3c implementation (Fable, 2026-10-30, Mac source; not built, not run)

Scope: dispatch end (design §4.2-§4.7), the `retire` builtin and its log, W2300, removal of the
`bmv_state_*` heap shell, `compact_state()` honoured. Nothing here was built or run; Haiku builds and
checks (§10.8.5). The Linux trees and ESP32 are untouched (3e).

**10.8.1 The one design disagreement, and how it is resolved.** Design §4.6 runs the state evacuation
in the behaviour's epilogue ("steps 1 to 3 run on the actor's stack inside the behaviour frame"). On
this runtime that is impossible: every dispatch starts with `mov sp, [#528]`
(`prims_actors_runtime_asm` LBB1_sw_none_1/2), so the behaviour frame lies DIRECTLY below the edge and
the runtime's own frame is on the carrier's stack. Extending the edge by E bytes writes over the
behaviour's saved registers and LR. So the placement runs after the behaviour returned and the
runtime is back on the carrier stack: the epilogue only RECORDS (the state type's root-word
descriptor at a new ACB word #592, the proof flag at #560), and `LBB1_post_beh` calls
`_silica_rt_state_dispatch_end` before `_silica_rt_stack_on_message_return`, so the release algorithm
still measures from the new edge (§4.6 steps 2 and 4 keep their order; the reply copy of step 1 is
unchanged, phase 4's). The ACB grows 592 -> 608 (#592 descriptor, #600 spare): the design's "the next
growth must add words" (§2.2). Second deviation: the copier keeps its table instead of the design's
forwarding words (§3.5, §3.6); the table holds FINAL addresses, so every pointer written into a copy is
final exactly as the forwarding scheme intends; the observable behaviour (holes first, the edge last,
sharing kept within a slot, slots never sharing) is the design's. Third: the old ROOT aggregate (the
state record or tuple itself, not a slot) is freed at a proven dispatch end when the root changed
and the old one lies in the area; the design frees only retired nodes, which would leak one shell per
message under every proven record-state behaviour (`proven_release_flat_memory` could never be flat).
Safe because a proven behaviour cannot pack the old state into the new one (that is an alias the
proof rejects), so nothing in the new state reaches the old root. **Lee: confirm the three.**

**10.8.2 Runtime (`emitter/apple_silicon_mac/terms/prims/`).**
* `prims_actors_state_asm.silica` (header rewritten, lines 18-120):
  * `_silica_rt_state_hole_pop` (new, pop-only entry sharing `Lsta_common` with `state_alloc`; X22 = 1
    makes `Lsta_extend` answer 0), `state_alloc` frame now saves X22.
  * `_silica_rt_state_copy` takes X4 = relocation delta; the walkers run under a copy control block
    (CCB, 64 B on the root routine's frame, X20): +0 end, +8 mode, +16 ACB, +24/+32 the old-node range
    [edge, top), +40 edge-bound bytes E, +48 the lowest committed address, +56 delta. `Lstc_run` is the
    shared walker entry; `Lstc_bump(X7) -> X0 write address, X1 final address` (mode 1: hole pop, else a
    DOWNWARD scratch bump from the committed run's bottom, pages committed through `stack_grow_to`,
    E counted; exhaustion -> `Lstc_fail_actor`). Every site (`Lstc_agg`, `Lstc_ref` buf/REF1/REFTUP,
    `Lstc_list` handle and chunks, `Lstc_str`) keeps the final address in a frame slot, inserts it in
    the table, writes it into cell words / link words / the string's bytes pointer and answers it.
    `Lstc_agg`, `Lstc_ref`, `Lstc_list`, `Lstc_str` and the chunk loop (`Lstc_ml_chunk`) test for an
    OLD node in mode 1 and answer it as it is; an old chunk ends a list walk with the copy linked to it
    (without that a `cons` onto the state's list would copy the whole list every dispatch).
  * New `_silica_rt_state_evacuate` (mode 1; pass 2 = one `memmove` of the edge block to
    [edge - E, edge); #528 = (edge - E) & ~15; #568 += E), `_silica_rt_state_copy_all` (measure; scratch
    below min(run bottom, new area bottom) committed by `stack_grow_to`; copy with delta; `memcpy` to
    [top - 1040 - B, top - 1040); heads zeroed; #528 = compacted end, #568 = B; X1 = 2 when the
    reservation cannot hold it), `_silica_rt_state_retire` (TLS ACB; #560 and [edge, top) tests; log at
    #536/#544/#552, `realloc` doubling from 64), `_silica_rt_state_log_drain`,
    `_silica_rt_state_dispatch_end` (the driver of the header comment: evacuate + old-root free + drain
    for a proven behaviour without a request; `copy_all` otherwise or under #584; policy: 0 keeps the
    old edge (min with the compacted end), 1/2 set the compacted end and call `release_to(keep = the
    committed bytes below the old edge, zero = the gap)`; clears #584, #560, #544, #592),
    `Lstc_fail_actor` (`(:explicit, :reservation_exceeded)` when #376, else `:out_of_memory`, through
    `_silica_rt_actor_fail_current`, which leaves the carrier stack).
* `prims_actors_runtime_asm.silica`: ACB 608 (the two `calloc`s, `_silica_rt_dead_acb` +16, comments);
  `_silica_rt_beh_convention` masks the convention with 3; new leaf `_silica_rt_beh_proven_store(X8 =
  entry, X19 = ACB)` stores the prefix word's bit 2 at #560, called at both dispatch sites right after
  `cbz x8, LBB1_ingress_no_beh`; `LBB1_post_beh` calls `_silica_rt_state_dispatch_end(acb, x9)` unless
  `w22` (an exit notice served in the behaviour's place) and stores its answer at ACB #0.
* `prims_actors_stack_asm.silica`: comment (608).

**10.8.3 Emitter and front end.**
* `prims_actors.silica`: `bmv_state_asm/5` now emits the #592 store (descriptor `L_std_<entry>_0`,
  `ev_site_descriptor_rodata`) and the #560 flag; `bmv_state_reuse_asm`, `bmv_tag_x12`,
  `bmv_copy_words` and the tagged block are gone; the phase-2 one-level promote survives only as
  `bmv_state_undescribed_asm` for a composite type the descriptors cannot follow (#592 = 0 then; a
  3c gap, as 3b's spawn gap). `behaviour_result_move_asm/5` (proven, table) always emits the TLS head
  so every behaviour-shaped epilogue writes #592 (a nested behaviour-shaped helper may have set it).
  `behaviour_result_evacuate_asm` evacuates the reply only. `behaviour_convention_prefix/2`:
  `0x5C1AC0F5` / `0x5C1AC0F6` when proven.
* `emitter_core.silica`: `state_release_proven` (top of `emit_sir_function`), passed to the prefix and
  the move; `behaviour_state_reusable` and `state_param_uses_ok` removed; `use sir_state_release`.
* **New** `sir_generator/sir_state_release.silica` (shared): `behaviour_release_reason(fn_val) ->
  reason` ("" = proven), `is_behaviour_return_type`. The rules are in its header: Old = the state
  parameter and every projection-bound name / bind arm over one; proven iff every result arm's new
  state is an Old projection or a record_make / tuple_make whose pointer-carrying operands are Old
  projections kept once; a user call, any fresh pointer-carrying value, a record/tuple/list pattern
  over the state, or any `write_ref` in the body is unproven, with the design's reason texts.
  Conservative by construction: with no logging updater in existence every update is unproven (P4).
* `main_compile_pipeline.silica`: `report_state_release` prints W2300 (`RegionWarning`, spec
  §15.1.1) per unproven behaviour after the SIR module is built, location from the declaration of the
  same name (the program's location as the fallback).
* `retire(r)`: `type_checker_memory_regions@is_region_builtin_call`,
  `type_checker_expressions_call_region_actor` routes to the new
  `type_checker_expressions_region_builtins@check_retire_call` (E2010 unless `ref`/`ref?`, E2003 unless
  `unit`/discard), `effect_checker_memory_regions` (`proc[mem(S)]` of the ref, as `read_ref`),
  `memory_region_calls` (`is_region_builtin`, result `unit`), `terms_region_lowering`
  (`build_region_prim_in_body_retire` / `build_region_prim_retire`, the argument lowered with its
  inferred type), `prims_memory` (`is_memory_prim`, `emit_retire`: `MOV X0, X1; MOV X1, #size; BL
  _silica_rt_state_retire`; size = the copier's: REF1 8, REFTUP payload rounded to 16 + 8),
  `term_emit_kind_compound_part2` loads its argument into X1 as `read_ref`'s.

**10.8.4 Not done, and why.**
* `strict state_release;` and E2321: the parser skips an unrecognised top-level token
  (`declarations_from_slots`: `decl.tag < 0 -> declarations_from_slots(slots.tail)`), so the line is
  silently ignored today; a real statement needs a new declaration tag (0-9 are taken; 72 `tag == 0`
  tests and 9 `tag of` switches would need an audit) read by `main_compile_pipeline` to turn W2300
  into E2321. Deferred to a 3c-2 pass with that audit.
* The `|_upd=` marker and the update-chain rules of §4.1 (P1, P4, the version argument): no logging
  updater exists before the stdlib's phase 5, so every update is unproven now (the conservative side).
  The `.iface` carriage of the marker goes with it.
* The design's sizes for `retire` say "REF1: 16"; the state copier allocates 8 for a REF1 cell, and
  the free must match the allocation, so 8 is used.
* The copier's old test is by address range; a state kept in an actor heap block (phase 2's implicit
  heap, until phase 4) is "new" and copied into the area each time it is reached: correct, and the
  heap block leaks until the actor ends, as before.
* Under `:compact_on_request` for a proven behaviour the log is dropped, not drained (§4.7 says
  drained first): the copy walks only reachable nodes and the heads are zeroed afterwards, so the
  drain would push onto a header that is wiped; same result, one pass less.
* W2300 will fire for many existing trial behaviours (any that replaces a pointer-carrying slot):
  decision 19's reporting as the design states it (§4.1 "a dropped non-empty slot is unproven"; §12
  offers Lee the alternative of accepting the leak). The warning is on the compiler's standard
  output: `error_enforcement_addition` captures the whole compiler output into `.cur_fail`, so a
  multi-file error trial whose other unit holds an unproven behaviour, or an error raised after SIR
  generation, would move a `.golden_fail`; `warning_enforcement_addition` compares `.golden_warn`
  (its one actor trial, `device_w1c_read_modify_write`, may gain a W2300 line). Not changed by me.
* Nested behaviour-shaped helpers: the prefix bit of a helper called non-tail inside a behaviour is
  not read (only the spawned function's is, at dispatch start), its epilogue may flip #560/#592; the
  outer epilogue stores both last, so the drain and the descriptor are the outer's. A proven helper
  inside an unproven outer logs retires that are then dropped: a leak, never a wrong free.

**10.8.5 Checks for Haiku** (one builder at a time, build-slot lock; no trial, `.scout`, golden or
`.ascomp` edits; report the first error verbatim).
1. Build: `make INSTALL_SELFHOST=0 SILICA_TARGET_PROMPT=0` in `compiler/src` with the published
   builder. First-build risks: the new unit `sir_state_release` (string `case` on types, the
   recursive helpers), the 5-parameter `bmv_state_asm`, the `check_retire_call` signature copy, the
   two region-lowering dispatchers' brace balance, and assembler errors in the new runtime text
   (`csel`, `ubfx`, `ldur`, `memmove`).
2. First trials (the dispatch-end path): `actor_stacks_addition/stack_release_on_return_shrinks`,
   `stack_many_idle_actors_hold_nothing`, `carriers_addition/many_actors_one_carrier`,
   `supervisors_addition/add_child_record_initial_state`, every `state_*` / `state_policy_*` trial in
   `actors_addition` and `actor_stacks_addition`, then the 3a probes (`scratchpad/p3/probe3a`).
   Expected: `.sout == .scout`; the int64-state memory-usage trials still `committed == 0`; W2300
   lines on the compiler's output for unproven behaviours (not a failure).
3. The 12 gate suites of §10.5 item 3 (`make integrate`; run_FAIL 0). `.ascomp` drift is expected in
   every behaviour's prefix and epilogue, `__silica_runtime`, and every unit with a `retire`-free
   memory prim table (none). Report any `.golden_fail` / `.golden_warn` that moves because of W2300.
4. For Sonnet, trials to write (design §11.3): `actors_addition/proven_release_flat_memory`,
   `actors_addition/fallback_copy_compacts_holes`, `warning_enforcement_addition/state_release_not_proven_alias`
   (W2300), `actor_stacks_addition/state_policy_shrink_after_compaction` / `_compact_on_request` /
   `_keep_state_area_holds`, `memory_region_addition/retire_outside_actor_is_noop`, and a
   `retire` type-error pair (E2010 non-ref argument, E2003 bound to int64).

**Checks for Haiku** (one builder at a time, build-slot lock at `scratchpad/build_slot/lock`; no
board, no board lock, no change to any `.scout`, golden or trial):

1. Incremental build with the published builder: `make INSTALL_SELFHOST=0 SILICA_TARGET_PROMPT=0` in
   `compiler/src` with `binaries/silica-compiler`, as §10.5 item 1. Only `prims_actors_state_asm` and
   `prims_actors_stack_asm` changed (both are runtime-unit text); report the first error verbatim.
2. The four failing trials first, `make integrate` in each suite directory restricted to the trial
   where the harness allows it, else the suite: `actors_addition/zero_heap_growth_tuple_state_int_message`,
   `memory_region_addition/region_tuple_return_in_actor`,
   `supervisors_addition/supervisor_child_tuple_state`, `actors_addition/cast_check_actor_state_accepted`.
   Expected: exit code and `.sout` equal to `.scout`; no "fault" banner; no `silica_rt_state_alloc` in
   any backtrace.
3. Then the 12 gate suites of §10.5 item 3 (functions, records, tuples, list, string, memory_region,
   actors, carriers, supervisors, actor_stacks, error_enforcement, ordered_data_structures): run_FAIL 0,
   `.sout == .scout` everywhere. The runtime-unit `.ascomp` drifts (the new instructions in
   `_silica_rt_state_alloc`); no other `.ascomp` should move relative to the 3b build. The memory-usage
   trials (`stack_release_on_return_shrinks`, `stack_many_idle_actors_hold_nothing`,
   `many_actors_one_carrier`, int64 states) must still report `committed == 0`; a composite-state
   `get_actor_memory_usage` reports one chunk committed.
2026-11-01: superseded: alloc_region is a frame area (Lee's decision); see chunk15 section 3.8.
