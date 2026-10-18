# Plan: resolving HIGH_PRIORITY compiler defects and diagnostic gaps (2026-09-08 + 09-09 addendum)

## Implementation status (2026-10-16)

Executed. Phase 0 (validation trials) is done: the `train_defect_*` trials are installed in the real suites. Phases 1 (A1, A4, A7, A8), 2 (A5), 4 (A3, A9, A10), 5 (A6) and 6 (B1-B14) are done and each item is pinned by an installed trial whose behaviour or error golden matches the last run. Phase 3 is done only as 3a: the diagnostic E1067 (a function literal that captures local bindings cannot be returned from the function that owns them) is in place; 3b (closure environments, a two-word fn value) is NOT implemented and still needs the design decision. The message-text cleanups at the end of Phase 6 were not re-checked and are still open. Per-item table: [HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md](./HIGH_PRIORITY_compiler_defects_and_diagnostic_gaps_2026-09-08.md); what was found while executing: [compiler_defects_execution_status_2026-09-10.md](./compiler_defects_execution_status_2026-09-10.md). The plan below is kept as written; its tree names are historical (`src_selfhost` is now `compiler/src`, the Rust-free tree; there is no separate seed source tree).

Scope: the 8 silent miscompilations (A1-A8), the 14 diagnostic gaps (B1-B14), the four misleading
diagnostics, plus two related defects recorded in memory since the document was written
(record message + List state in behaviours; a `call` whose message is a call expression).
No code was changed and nothing was compiled to produce this plan; every source site below was
located by reading.

## Ground rules

1. Which tree. `binaries/silica-compiler` is a selfhost-built generation, so fixes land in
   `src/` and are mirrored into `src/` (the seed) corrected for dialect. Lee builds.
2. Every item starts with the 8 ms scratch repro from the document (one .silica + one-line
   silica.config), rerun against the CURRENT binary before any edit: A3 may already be fixed
   (the three seed actor-reply fixes of 09-09 are committed in both trees).
3. Validate before fixing, with trials. Each error, or family of errors, is pinned BEFORE any
   compiler edit by adding training trials to the appropriate trials/<area>_addition
   subdirectory: `train_*` pairs in the same style as the generated corpus
   (programmer_tools/train_trial_generator), one per shape in the document's probe tables,
   with hand-derived .scout goldens (Part A) or .golden_fail goldens (Part B, under
   error_enforcement_addition). The trials are expected to fail red on the current compiler;
   that red run is the validation that the defect is real, reproducible in CI, and that the
   fix has a target. A defect whose trial passes today is closed as already fixed, not
   worked on. The same trials are the acceptance test for the fix.
4. The .ascomp side of a new Part A trial is recorded from the compiler once the fix lands
   (the .scout side is derived by hand up front and never recorded).
5. Emitter fixes change .ascomp goldens broadly (any nested binary expression re-stages).
   Regenerate per suite only after the .scout (behaviour) side is green, and review the
   diff shape (register renames only) before accepting.
6. Trials run with `make -C trials/<suite> integrate` for the touched suites, then the full
   tree. Until a family's fix lands, its red trials are expected failures in the tree-wide
   report; the report's failure list is the open-defect list.

## Source map (seed file -> selfhost file)

| Item | Seed site | Selfhost site |
|---|---|---|
| A1 caller-side FP args | emitter/.../terms/term_emitter.silica emit_rest_args (~890-1000), user_call_arg_reg_for_type (862) | terms/term_emit_kind_call.silica, terms/term_user_call_abi.silica |
| A1 callee side (looks correct) | emitter_core.silica param_reg_for_aapcs_slots (509), aapcs_arg_slots_at_index (497), bind_reg_for_param (548) | emitter_core.silica |
| A7/A8 operand staging | term_emitter.silica prim path ~3970-4200: left_reg X9/S1, right_reg X10/S2 fixed per nesting | terms/term_emit_kind_compound_compare.silica |
| A4 tuple param destructure | emitter_core.silica build_param_outer_reg* (989-1046), terms/let/let_tuple.silica compute_rhs_reg_* | emitter_core.silica, term_emit_kind_let*.silica |
| A5 overload set on resume | module_checker/module_iface.silica IfaceExport (name, arity, decl_tag, effects, type_surface), stub_decls_from_exports* (1408-1424); sir_generator/declarations/overload_mangle.silica count_tag0_same_name_arity, link_name_from_decl, mangle_fn_part_if_overloaded | same paths |
| A2 closures | parser/constraint_extract.silica lambda lifting (4523-5290): captures become trailing params; "HOF arity shim" forwards only literal captures; no closure environment exists | parser/constraint_extract.silica + constraint_extract_hof_wrap.silica |
| A3 record actor state | emitter reg_conventions/term_emitter (fixed 09-09), remaining gap in bind_reg_for_param/aggregate X20 shadow | same |
| B1/B2 call arguments | type_checker/expressions/type_checker_expressions.silica check_user_call_args_recursive (3659-3712) | type_checker_expressions_user_call_check_args.silica |
| B8/B12 literals | type_checker_expressions_literals.silica check_expr (28-60), type_id_accepts_numeric_literal | same name |
| B9/B11 builtins | type_checker_expressions.silica inline checks (print_bool 2471, concatenate 2575, length_bytes 2601) | type_checker_builtin_signatures.silica (a table already exists here) |
| B10 main signature | type_checker/declarations/type_checker_declarations_functions.silica check_body_after_params (240) | same |
| B13/B14 actors | type_checker/expressions/type_checker_expressions_actors.silica | same |
| B3/B4/B5 effects | effect_checker_capabilities.silica check_sequence_blocks_in_expr_at (309-350), check_sequence_unused_effects (276); effect_checker_propagation.silica outside-walker (107-175, case = kind 13) | same |
| B6/B7 parser | constraint_extract.silica is_op_token (615), op_precedence (1728, unknown lexeme -> 0), extract_binary_tail (3879), extract_if_expression dispatch (2687) | constraint_extract_slots.silica, constraint_extract_expr.silica |

## Phase 0 — Re-verify and pin (no compiler edits)

- Rerun every repro (A1-A8, B1-B14, the two memory items) against `binaries/silica-compiler`
  and record pass/fail in a table appended to the document. Expected: A3 fixed; the rest open.
- Add the validating training trials to the real trial subdirectories (this is the
  validation step of ground rule 3; every one is expected to fail today):

  | Family | Subdirectory | Trials to add |
  |---|---|---|
  | A1 | float16/32/64_addition | two-float params (`x + y`), int-then-float (`y`), float32 second-only (`y`), three floats |
  | A7 | int8/16/32/64_addition, uint8/16/32/64_addition | the six wrong rows of the addendum probe table, one file per width where the row's type applies |
  | A8 | float32_addition, float64_addition | the five print_bool compares, each side compound, plus float64 typed variants |
  | A4 | tuples_addition | tuple_param_after_scalar_callback (already written), tuple second param direct read, record-after-scalar sibling |
  | A2 | functions_addition | make_adder (returned), closure stored in a record, closure returned then passed to a HOF |
  | A3 | actors_addition | the tally record-state repro; actor_list_state_stack's missing exit line; record message with List state; call with a call-expression message |
  | A5 | traits_addition | the two extra units from the document so the suite crosses the reclaim threshold; a provided-method call in each root |
  | A6 | deep_frame_spill_addition | the six 20-40 binding candidates |
  | B1-B14 | error_enforcement_addition (train_* .golden_fail pairs) | one file per row of the Part B table, golden written by hand from the intended diagnostic; B1/B2 also get a positive twin in functions_addition |
  | misleading messages | error_enforcement_addition | one pair per message, golden = the corrected text |

- Run each touched suite once; record the red list in the document as the validated
  baseline. Anything green here is closed as already fixed (A3 is the candidate).
- Fold the addendum's A7/A8, the record-message + List-state behaviour gap, and the
  "message argument is a call expression" defect into Part A of the main document (A9, A10).

## Phase 1 — Emitter argument and operand staging (A7, A8, A4, A1)

These four share one cause family: a value is left in a scratch or parameter register that a
later sub-evaluation reuses.

1. A7/A8 first (most common shape in real code). In the prim path the left operand always
   goes to X9/W9 (S1/D1 for floats) and the right to X10 (S2), regardless of nesting depth,
   so a compound right operand clobbers the outer left result. Fix: when the right operand is
   itself compound, spill the left result to a frame slot (the fixed-frame X29 slots already
   used by short-circuit and/or) before evaluating it, and reload it into left_reg after;
   same for the float registers. A7's "x read as 20" also says a literal was materialised
   into the register that still bound parameter x; add a guard that a bound parameter
   register is never chosen as a staging register while the parameter is live.
   Selfhost has the frame-region machinery; prefer a depth-indexed slot over a register
   stack so the fix is the same in both trees.
2. A1. The callee side assigns D0/D1 correctly, so the defect is on the caller side in
   emit_rest_args: trace how the second FP argument is materialised (likely evaluated into
   the scratch S0/D0 or the left_reg S1 and never moved into its slot register, or the
   `_fpool=X9` staging is GPR-only). Fix: evaluate each FP argument into its own slot
   register, spilling earlier FP arguments when a later argument's evaluation is compound.
3. A4. Destructure a tuple parameter from the register that holds it (X1 for the second
   parameter) instead of staging through X0; if X0 staging must stay, save the live
   parameter registers first. Check the same path for record parameters after a scalar.
4. Acceptance: the Phase 0 trials for A1/A4/A7/A8 turn green; additionally restore the
   fold-over-tuple checks removed from ordered_data_structures/skew_ral_core/ral_generic_payloads.
5. Expect wide .ascomp drift; regenerate only after .scout is green everywhere.

## Phase 2 — A5: provided-method overloads across the exit-75 resume

Mechanism: the link name is mangled only when count_tag0_same_name_arity sees more than one
tag-0 declaration with that name and arity in the callee module. In one process the callee
module is the parsed AST and the provided-method specialisations are present; on resume the
callee module is rebuilt from .iface stubs, whose IfaceExport carries name, arity, tag,
effects and a type surface but not the overload set, so the count is 1 and the bare name is
emitted while the trait module's own emission used the mangled one.

1. Publish every provided-method specialisation as its own export with its parameter types
   (or an explicit overload index) so stub_decls_from_exports rebuilds a declaration list on
   which count_tag0_same_name_arity and link_name_from_decl give the same answer as the
   parsed AST.
2. Make the two paths share one function that computes the link name from (module exports)
   rather than from ASTs, so they cannot diverge again.
3. Add a driver switch (environment variable, no new builtin) that forces process-per-unit
   below the 32-unit threshold, and run traits_addition and modules_addition both ways in a
   staged differential check; then grow traits_addition by the two units from the document
   so CI exercises the resume path permanently (these are the Phase 0 A5 trials; they stay).

## Phase 3 — A2: returned closures

There is no closure representation: lambdas are lifted to top-level functions whose captured
locals become trailing parameters, and a call site can only supply them when the captures are
literals visible in the let environment. A returned lambda loses them by construction.

1. Decision gate with Lee: implement closure environments (the specification's
   make_multiplier requires it) versus rejecting escaping capturing lambdas. Recommendation:
   both, in order.
2. 3a (small, immediate): a diagnostic when a lambda that captures a non-literal local is
   returned, stored in a record/tuple/list, or passed to an actor: stops the silent wrong
   answer today. Trial under error_enforcement_addition.
3. 3b (large): fn-typed values become a two-word closure (code pointer, environment
   pointer); the lifted function reads captures from the environment; indirect calls through
   X17 pass the environment in a fixed register; captured aggregates are promoted per the
   move rule for aggregate arguments; the region/ownership pass treats the environment as an
   owned aggregate. Touches parser lifting, type checker (fn type carries closure-ness),
   SIR, emitter call paths in both trees. Trials in functions_addition for returned,
   stored, and nested closures.

## Phase 4 — A3 and the remaining actor codegen gaps

1. Confirm A3 passes with the current binary; wire the tally repro and the missing exit
   line of actor_list_state_stack.scout as trials; close A3.
2. Record message with a List-typed state (bind_reg_for_param shadows the aggregate first
   parameter into X20, which is also the reply buffer): move the aggregate first parameter
   to X22 when the reply sret buffer is in use, hold the second in X21, and save the pair in
   the behaviour prologue. Trial in actors_addition.
3. `call(w, f(x) impl ActorMessage {})`: the actor ref is evaluated into a register the
   message evaluation clobbers. Evaluate the message first into a spill slot, then the ref.
   Trial in actors_addition (call and call_registered forms).

## Phase 5 — A6: compiler killed on large single units

1. Reproduce the six candidates under /usr/bin/time -l and a hard timeout; classify signal 9
   as OOM versus stack overflow by RSS at death and by ulimit -s variation.
2. Likely site: the spill-slab sizing and live-range walk in the emitter for 20-40 live
   bindings (quadratic list walks per binding, see the .tail allocation note). Fix the
   allocation pattern; add the six candidates to deep_frame_spill_addition with a per-unit
   memory ceiling asserted by the trial harness.

## Phase 6 — Diagnostics (Part B and the misleading messages)

Type checker
- B1: in check_user_call_args_recursive the branch for the last formal returns OK without
  checking that the argument chain is exhausted; the two-parameter shape is caught by a
  different branch. Add the exhaustion check on every branch and delete the duplicated
  arity logic (one walker for 1, 2, and n parameters).
- B2: same walker; later arguments are checked through check_expr_surface_type with a
  collection-context override that can widen a string formal; make the literal-vs-formal
  check unconditional for literal arguments.
- B8/B12: type_id_accepts_numeric_literal accepts any numeric literal for any numeric type.
  Split into integer-literal and float-literal acceptance, add a width/sign range check
  (new code, e.g. E2012 literal out of range), and reject a float literal where an integer
  type is expected.
- B9/B11/B13/B14: give the seed the builtin signature table that selfhost already has
  (type_checker_builtin_signatures.silica) and route print_*, length_bytes, concatenate,
  call/cast message typing, and spawn behaviour arity through it.
- B10: validate main's signature in check_body_after_params: return int64 or atom only,
  no parameters.
- Misleading messages: E2002 for an undefined head identifier in a field access; E2003 to
  print expected and actual types; unterminated string as E1010-class lexer error instead of
  E1060; E1040 to name the two statements. Do these last: message text changes move
  existing .golden_fail files, so each is a deliberate golden regeneration.

Effect checker
- B3: the outside-walker does descend into case branches (kind 13), so trace the repro to
  find which node is skipped (likely a let-bound arm body or the produces expression) and
  extend the walker.
- B4: expand_effect_list / is_effect_subsumed treats mem(normal_writeback) as subsumed by
  device_io; make writeback a distinct capability that only mem(normal_writeback) declares.
- B5: check_sequence_unused_effects is correct in isolation, so the early return is
  upstream (a block with no calls skips the check); remove the shortcut so a declared
  effect with an empty used set is E3010.

Parser
- B6: bxor is not an operator token, so the trailing tokens are being swallowed by the
  statement splitter; make a stray identifier after a complete expression an E1040 with the
  offending token named (or add bxor properly if the specification is amended).
- B7: no compiler source uses a standalone if, so reject extract_if_expression outside a
  case guard with a new syntax error; keep the guard path.

Acceptance for every B item is its Phase 0 .golden_fail trial turning green (and the
positive twins for B1/B2 staying green).

## Order, dependencies, and effort

| Order | Item | Effort | Depends on |
|---|---|---|---|
| 1 | Phase 0 re-verify + staged trials | 1 day | — |
| 2 | A7/A8 operand spill | 2-3 days + golden regen | — |
| 3 | A1 FP argument staging | 1-2 days | A7 fix (shares the spill helper) |
| 4 | A4 tuple parameter | 1 day | — |
| 5 | A5 iface overload set | 2 days | — (parallel with 2-4) |
| 6 | A3 confirm + actor gaps | 1-2 days | — |
| 7 | B1/B2/B8/B12/B10 type checks | 2 days | — |
| 8 | B9/B11/B13/B14 builtin table | 2 days | seed gets the selfhost table |
| 9 | B3/B4/B5 effects, B6/B7 parser | 2 days | — |
| 10 | A2 3a diagnostic | 1 day | decision gate |
| 11 | A6 large units | 1-2 days | Phase 3 harness of the selfhost plan |
| 12 | A2 3b closure environments | 1-2 weeks | design sign-off |
| 13 | Message-text cleanups + golden regen | 1 day | everything else landed |

Each row: validating train_* trials added to the subdirectory and seen red -> fix in
src -> mirror in src -> Lee builds -> those trials green -> touched suites green ->
full tree green -> .ascomp recorded and goldens reviewed -> document row marked fixed ->
generator skip list updated so the next train_* batch covers the shape.
