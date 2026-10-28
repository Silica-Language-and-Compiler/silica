# Chunk 15 phase 2: running notes (Fable)

Design: [chunk15_stack_memory_design.md](chunk15_stack_memory_design.md) §3, §9.1, §11.1 row 2.
Branch `phase2_of_chunk15`. Nothing here is committed by the implementing agent; the main session commits.

## 0. Implementation decision that differs from §3.1 (read first)

§3.1 assumes the only SP-relative state left in an emitted body is the sret slab and the tuple
argument slab, so a frame allocation can simply be `SUB SP` and SP is the dynamic part's cursor.
The emitter does not match that: argument staging (`term_user_call_helpers`, 16-byte `STR ..., [SP, #-16]!`
per argument, released after the call), operand parks in `term_emit_kind_compound_compare` (46 sites),
`compound_part2/3` parks, case-pattern parks, the indirect-callee X17 park, and `[SP, #k]` reads of
those parks are all live across nested calls and allocations. A `SUB SP` for a node, or a callee that
returns with SP lowered (adoption), between such a push and its pop makes the pop read the wrong word.

The phase therefore keeps a **floor** per frame:

```
 caller SP at entry  -> +----------------------+
                        | [X29,#24] precall SP |  two words above the frame record (prologue is now
                        | [X29,#16] floor      |  STP X29, X30, [SP, #-32]!; MOV X29, SP)
 X29                 -> | saved X29, X30       |
                        | fixed part (spills,  |  X29-relative, unchanged
                        |  frame regions, saves)|
 floor               -> | dynamic part (nodes) |  grows down; never freed before the frame pops
                        | transient pushes     |  SP-relative pushes/parks, exactly as today
 SP                  -> +----------------------+
```

* A frame allocation of n bytes (`L_dyn_alloc`, X16 = n in, X16 = block out, X0-X15 kept) moves the
  transient area [SP, floor) down by n (a memmove of a few words) and hands out [floor-n, floor).
  SP-relative addressing of the transient area is preserved because both SP and its contents move
  by n. The only thing that may not exist is an absolute pointer into the transient area; the ones
  that did (the `SUB SP; MOV X8, SP` sret slab is re-derived just before the call, the checked-pair
  slab is a frame allocation) are converted.
* Every Silica function's epilogue restores callee-saved registers X29-relative (derived from the
  prologue text, `emitter_core@epilogue_restores_off_fp`). All functions except behaviours and
  `main` end `LDP X29, X30, [X29]; RET` (adopting: SP stays where the body left it, the frame's
  nodes stay for the caller); behaviours and `main` end `MOV SP, X29; LDP X29, X30, [SP], #32; RET`.
* Every user call site saves SP in [X29,#24] just before the BLR and, after it
  (`call@call_post_sp_asm`):
  * frame-free scalar result type (`reg_conventions@is_frame_free_scalar_type`) -> SP restored from [X29,#24];
  * the call is in return position (`|_rpn=` list), a tuple result, or a type the descriptor
    generator cannot describe -> `BL L_adopt` (the caller's transient area moves below the callee's
    region; floor := callee SP);
  * otherwise -> `BL L_ev_frame` with a per-site descriptor `L_ev_<fn>_<node>` (§3.5 evacuation:
    the result's reachable new nodes are copied to just below the caller's floor, everything else
    of the callee's region is dropped, the transient area moves below the copies).
* Everything stays on the actor's stack (no second stack, no second cursor register); this is an
  implementation of §3.1's "dynamic part", not a change to it. Lee should know §3.1's premise was wrong.

## 1. Stages and status

| Stage | What | Status |
| --- | --- | --- |
| S1 | 32-byte frame record (floor + precall words), floor init, X29-relative epilogue restores, precall save + SP restore at every user call, TCO stub floor reset, supervisor trampolines and the failure-reporter `region_dump_limit` call restore SP | done, green |
| S2 | return-position analysis (`sir_generator/sir_return_position.silica`, `rp_call_nodes`); the emitter threads the node list as `|_rpn=,i,j,` in the body's binding string (a call node's SIR `value` is its effect string, read by many consumers, so the marker is not appended there) | done |
| S3 | `L_dyn_alloc`, `L_adopt`, `L_ev_frame` / `L_ev_heap` / `L_ev_heap_shell` (Cheney walk, scratch below the routine's frame, two passes in frame mode), module-local, emitted in every module | done; standalone harness passes (frame and heap modes, sharing preserved, transient moved, data survives a 64 KB clobber) |
| S4 | adopting epilogues; post-call restore / adopt / evacuate | done, green |
| S5 | `alloc_*` as frame allocations (normal spaces; atomic/device keep their blocks), witness `alloc_region` = `MOV dest, X29`, region-less `alloc_ref(v)` / `alloc_rec(v)` / `alloc_buf(n)` (P1, type checker + SIR lowering with a fresh lifetime witness), `ref_in_region` retired (P7, front end + stdlib validators answer `true`), TCO keeps the dynamic part for pointer parameters, tail BR blocked in `main` and when the frame may hold nodes, behaviour state/reply evacuated to the heap, send/spawn payloads walked to the heap (interim for phases 3/4), region-destroy heuristics and message-region release disabled (a region is a witness now) | done, green |
| S6 | strings (concat result block in the caller's frame, the bump arena removed), lists (cons handle+chunk and tail handle are frame blocks passed in X15; the free-slot rule only lets a pointer element into a chunk in the caller's own frame), checked pairs (16-byte frame block), substring caches made one process-wide block cleared by `L_str_forget` | done, green |
| S6c | evacuation of old aggregates: a record/tuple/sum outside the callee's region (a heap shell an older promote made, the caller's sret home) can hold words that name new nodes; it is queued once, as a header-only entry, and its words are rewritten in place. Fixed the wbt_set corruption (a second scan of the same heap shell read final addresses as new nodes) | done (repro green; gate re-run in §4) |
| S6d | heap-mode evacuation (sends, calls, spawns, behaviour results) restores the words its forwarding marks overwrote: the sources stay live in the sender. Found by `compiler_substrate/type_interner_roundtrip` (exit 133: a string marker overwritten by a forwarding word, the next marker check trapped) | done, green (repro `type_interner_roundtrip` exits 0) |
| S7 | removals: substring results in the caller's frame (both bump arenas gone), `term_message_regions` deleted (`type_is_pointer_free` moved into `term_message_copy` as `mc_type_is_pointer_free`), the region-destroy machinery of `emitter_core` removed (`fn_destroys_region_param`, `region_param_index`, `msg_drop`/`msg_offs`, the owned-region slot), the timer release thunk reduced to `X2 = 0`, `let_owns_local_region_retired` deleted; the main promote path (`aggregate_return_heap_promote_x0_copy`) copies into a frame block (`L_dyn_alloc_src`) | done in all three trees; Mac build green, gate re-run in §5 |
| S8 | promote-site removal (design §11.1 row 2, Lee 2026-10-26): aggregates are built where they live from the start, so every promote copy and every slab pop is gone. See §6 | applied in all three trees; Mac Pass A gated (one run failure, `fn_tuple_nested`, root-caused and fixed, §6); Pass B (dead-code removal) building |
| L1 | linux_aarch64 port | applied and synced with the Mac tree (ELF spellings: `ADRP x, sym` / `:lo12:`, no leading underscore, `.comm` alignment in bytes, `L_stack_top` through `pthread_getattr_np`); built on pix with 999964; gate suites green there (§5); rebuilt from the final tree (emitter_core touched, see §3 item 5) and smoke-checked |
| L2 | linux_x86_64 port | applied (§2a); helpers unit-tested under Rosetta (evacuation frame and heap modes, substring/concat in a frame with a transient push); built on nix with 999972 (12 min) and the gate suites green there (§5) |

## 2. Files changed

Shared front end:

* `type_checker/expressions/type_checker_expressions_region_builtins.silica` — region-less checks for `alloc_ref` / `alloc_rec` / `alloc_buf`; `ref_in_region` branch removed.
* `type_checker/type_checker_memory_regions.silica`, `effect_checker/effect_checker_memory_regions.silica`, `sir_generator/terms/memory_region_calls.silica` — `ref_in_region` removed.
* `sir_generator/terms/terms_region_lowering.silica` — region-less forms lowered with a `fresh_lifetime` witness (`build_region_prim_in_body_2arg` / `build_region_prim_2arg`; originals renamed `_regioned`).
* `sir_generator/sir_return_position.silica` — new: `rp_call_nodes`.
* stdlib `brodal_okasaki_node`, `skew_ral_node`, `tree_binary`, `tree_rose`, `wbt_set`, `wbt_map` and the compiler's own `src/lib/wbt_map.silica`: `ref_in_region(node_ref, X.region)` -> `true`.

Apple Silicon (`emitter/apple_silicon_mac/`), mirrored in `emitter/linux_aarch64/`:

* `control/control.silica` — 32-byte frame record; `function_epilogue_tail_with_effects(effects, adopt)`; tail release pops 32.
* `emitter_core.silica` — `epilogue_restores_off_fp` and helpers, `frame_floor_init_asm`, `fn_epilogue_adopts`, `tco_params_frame_free` / TCO stub `keep_dynamic`, `body_may_hold_frame_nodes`, `frame_allocating_prim`, `|_rpn=` list, `msg_offs` "", behaviour result evacuation before the move, frame/evacuation/stack-top helpers appended to every module.
* `terms/call.silica` — `call_precall_sp_asm`, `call_post_sp_asm`; `emit_call_body_effects` takes the atom table.
* `terms/term_emit_kind_call.silica` — passes the atom table; X8 re-derived from the result slab just before the call.
* `terms/term_message_copy.silica` — `ev_type_described`, `ev_site_descriptor_rodata` (descriptor kinds 0 WORD, 1 REGION, 2 REF1, 3 REFTUP, 4 AGG, 5 SUM, 6 BUF, 7 LIST, 8 STRING, 9 CLOSURE; 17 is the evacuator's internal chunk kind).
* `terms/prims/prims_memory.silica` — frame `alloc_ref` (16-byte cell) / `alloc_rec` (word count from `memory_tuple_word_count`; it copied 2 of 3 words of a 3-tuple) / `alloc_buf` (zero-filled), `alloc_region` witness, `ref_in_region` removed, `emit_frame_helpers` (L_dyn_alloc, L_adopt, L_str_forget, `_silica_ss_cache`), `emit_evacuation_helper` (source: Appendix A), `emit_ev_region_alloc`, `emit_stack_top_helper`.
* `terms/prims/prims_actors.silica` — `behaviour_result_evacuate_asm` (L_ev_heap_shell for record/tuple shells), `stack_value_to_heap_asm` before send/spawn deep copies, failure-reporter SP save, timer thunk without region release.
* `terms/prims/prims_list.silica`, `terms/term_case_patterns.silica`, `terms/term_emit_kind_compound_part2.silica` — list blocks in the frame (X15), head box via L_dyn_alloc.
* `terms/prims/prims_checked_int64.silica` — frame pair.
* `terms/string_concat_mmap_nomte.silica`, `terms/prims/prims_string.silica` — `L_concat_size` + L_dyn_alloc + `L_concat_helper`; bump arena gone.
* `terms/string_substring_mmap_nomte.silica` — the caches are one global 80-byte block `_silica_ss_cache` (key 0, flag 8, key2 16, flag2 24, victim 32, cached_len 40, cur_key 48, cur_char 56, cur_byte 64) plus `_silica_ss_lock` (the code indexes key + victim*16, so separate `.comm` words broke it).
* `terms/term_reg_spill.silica` — `let_owns_local_region` returns false (old body kept as `let_owns_local_region_retired`).
* `module_linkage.silica` — supervisor trampolines `SUB SP, X29, #16` before the epilogue.
* `shared/reg_conventions.silica` — `is_frame_free_scalar_type`, `regcv_has_bracket`.

## 2a. linux_x86_64 port (virtual-register model)

* Frame words: `[rbp - 8]` the floor and `[rbp - 16]` the pre-call rsp, reserved by
  `emitter_core@x86_frame_header` in every frame (the SVR homes now start at `rbp - 24`). They are
  fixed offsets so module-level helpers can address them through the calling frame's rbp.
* Epilogues: an adopting function ends `mov rax, [rbp + 8]; mov rbp, [rbp]; jmp rax` (rsp stays
  where the body left it; `control@function_epilogue_tail_with_effects`); main and behaviours keep
  `leave; ret`. X19-X28 are slots, so there are no callee-saved restores to move.
* Call sites: `mov [rbp - 16], rsp` before the call; after it `mov rsp, [rbp - 16]` (scalar),
  `call L_adopt`, or `L_ev_frame` with the site descriptor (`call@call_post_sp_asm`).
* Helpers (prims_memory) use only the x86 scratch set (rax, r12, r13, xmm8, xmm9): `L_dyn_alloc`
  (rax = n in, rax = block out; it pops its own return address so it does not move with the transient
  area), `L_adopt`, `L_str_forget` (r10 = address), `L_stack_top`
  (glibc), `L_ev_region_alloc` (`jmp silica_rt_region_alloc` or `ud2`).
* The evacuation routine is generated from the AArch64 source (Appendix A) by the translator in the
  session scratchpad (`ev_to_x86.py`): X0-X7 in the VR homes (so the arguments arrive in place),
  X9-X12 in r10-r13, X8/X13-X17/X19-X28/X30 in slots of the routine's own 336-byte frame, internal
  BL/RET through a link slot (a pushed return address would land in the scratch area the walk grows
  below rsp), entry, frame-mode placement and heap exit hand-written, and a check that no
  flag-clobbering instruction lands between a compare and its consumer. Regenerate it whenever
  Appendix A changes.
* Lists: the prepend block travels in rdi with bit 0 = "the element can be a pointer"; the tail block
  in rax straight from `L_dyn_alloc`; both helpers keep it at `[rbp - 16]` of their own frame and now
  end with `leave`. The frame-chunk bound is `[rsp, caller's rbp)`.
* Strings: concat takes its block in rax (`L_concat_size` -> `L_dyn_alloc` -> `L_concat_helper`); the
  substring helpers, which keep their own rbp frame, call `L_dyn_alloc` with rbp set to the calling
  function's frame and then move their own rbp down by the allocated size (their saved registers and
  return address are transient pushes of the caller and moved with it). The caches are one global
  80-byte `silica_ss_cache` plus `silica_ss_lock`, as on AArch64.
* Checked pairs and the promote copy are frame blocks; behaviour results are evacuated with
  hi = rbp + 16; sends and spawns walk their payload to the heap first; the failure reporter's
  `region_dump_limit` call saves and restores rsp.

## 3. Open items (what remains of phase 2)

1. **linux_aarch64**: the full integrate on pix (the gate suites ran on the pre-removal build; the
   final build passed recursive_function and records).
2. **linux_x86_64**: the full integrate on nix (only the gate suites ran), and the memory_region
   suite once its three `ref_in_region` trials are rewritten.
3. **S7 removals still open.**
   * The promote sites are done (S8, §6). `prims_actors` `heap_promote_stack_aggregate_x0` /
     `heap_promote_reply_x0` / `spawn_promote_init_x11` (actor state, reply and spawn shells) stay on
     the heap: phases 3/4.
   * `emitter_core@record_make_link_promotes_field` still gives the parameters of a body with a nested
     aggregate record field callee-saved shadows, for a promote BL that no longer exists. It is now
     conservative only (extra shadows); remove it when a trial shows it can go.
   * The scope-release code (`arena_scope` / `region_scope`, `L_sc_arena_mark`, region mark/release)
     is unreachable and still emitted text: remove it with the arena_ok / region_ok parameters.
   * `L_region_grow` stays for atomic/device regions and the message copier.
   * The implicit heap routines stay (runtime lists/strings, state, messages) as the brief says.
4. **Known hazards, not covered by trials yet.**
   * `write_ref` of a frame-young value into an older cell
     (`region_hazards_open_addition/write_ref_young_into_older_cell`). The design does not make the
     evacuator chase this: §6.3 / decision 35 makes it E2302 at compile time (the region checker,
     phase 6), because the young value's frame is popped before the older cell is read. The trial's
     expectation (7, 0) contradicts that rule; under the design it becomes an error trial (expect
     E2302) once phase 6's checker lands. Making the evacuator scan every older cell would mean a
     remembered set (a write barrier on every pointer store into a ref cell), which is not in the
     design.
   * Heap-mode evacuation of a send/call payload rewrites, in place, the words of an *old* aggregate
     that reaches young nodes (S6c): the sender's old shell then names the heap copies. Equal for
     immutable values, but a mutable ref cell reached that way is copied, so the sender's later writes
     through other paths no longer reach the copy its shell now names.
   * `write_ref` of a pointer to a younger frame's node into a cell of an older frame (or the heap):
     evacuation only scans old *aggregates* in place, not old REF1/REFTUP cells.
   * `main` runs on the 8 MB OS stack (design §13 item 11): trials that build large structures in
     `main` can exhaust it now that lists/strings/nodes live in frames.
   * Every frame is 16 bytes bigger (deep recursion on the main thread).
   * Send/spawn payload walk uses `L_stack_top` (ACB #272/#280, else `pthread_get_stackaddr_np`):
     interim until phases 3/4.
5. **Remote rebuild trap.** `sync_to_hosts.sh` keeps this Mac's mtimes, so a source edited here after a
   host built it can still look older than the host's `.sams` and an incremental host build skips it
   ("Compile time: 1s"). Touch the edited sources on the host before rebuilding.
6. **Builder.** Build with `SILICA_COMPILER=/Volumes/2T/silica/binaries/silica-compiler` (999940).
   The Makefile default `binaries/seed-compiler` is too old (its runtime lacks
   `_silica_rt_list_index_failed`). Units compiled by the wrong builder must be `touch`ed.
7. No `codegen_regressions` suite exists in trials/ (gate list item).

## 4. Trials

### Trials that must be rewritten (they use `ref_in_region`, retired by P7) — for the trial agents

* `memory_region_addition/canonical_arena_survives_owning_callee`
* `memory_region_addition/record_bind_after_destructures`
* `memory_region_addition/region_param_threaded_through_ref_query`
* `compiler_addition/region_grow`
* `generic_modules_addition/wbt_set`
* `ordered_data_structures/binary_tree_core/staged/record_bind_after_destructures`
* `ordered_data_structures/binary_tree_core/staged/region_param_destroyed_after_ref_in_region`
* `ordered_data_structures/tree_collections/rt_direct_constructor_binding`

Validator trials whose goldens expect a `wrong_arena` / mixed-arena verdict: the validators can no
longer tell arenas apart (P7: the membership test answers `true`), so these now print their failure
code instead of the expected one. They need new expectations or the wrong-arena case removed:

* `ordered_data_structures/wbt_core/wbt_validate_malformed_fixture` (7 expected, 6 printed)
* `ordered_data_structures/tree_collections/rt_validate`
* `ordered_data_structures/skew_ral_core/ral_validate_invariants` (`arena_case` expects code 6)
* `ordered_data_structures/graph_live_core/gl_validate` (`mixed_arena 2000` expected, 10000 printed)
* `ordered_data_structures/brodal_okasaki_core/bo_validate_invariants`
* `ordered_data_structures/binary_tree_core/bt_validate`

A rejected unit aborts its suite's batch compile, so the first three keep memory_region_addition red
until they are rewritten; the gate runs used a mirror of trials/ without them
(scratchpad `tmirror/`).

Also: `carriers` trial `workers_two_field_record_return_at_arena_block_end` measures heap use
(heap_used): the returned record is now frame-resident, so its golden assumption changed; and every
suite's `.ascomp` needs refreshing (only when `.sout == .scout`).

### Trials to add (design §11.3)

* region-less `alloc_ref(v)`, `alloc_rec(v)`, `alloc_buf(n)` in a function and in `main` (P1), plus E-code
  trials for the rejected forms;
* a 3-tuple `alloc_rec` read back word by word (the 2-of-3 copy defect);
* return-position chains: f returns g(...) returns h(...) with records, lists, strings (adoption);
* evacuation: a non-return-position call whose result shares a node twice (sharing preserved), whose
  result is a list of strings, a sum with a record variant, a `REFTUP` reached from a heap shell
  (the S6c wbt_set case: insert into a balanced tree three times and validate);
* TCO loop that conses onto a list parameter (keep_dynamic) and a kind-5 tail call whose argument names a frame node;
* list prepend onto an older frame's list with a free slot (the free-slot rule), scalar and pointer elements;
* string concat results reused across many iterations next to `substring` (the `L_str_forget` cache rule);
* checked_int64 pair returned through two calls;
* behaviour state/reply holding frame-built records, lists and strings (heap evacuation);
* send/spawn of a frame-built message payload;
* a call/send whose payload is a frame-built string or list, after which the SENDER reads the same
  value again (the S6d forwarding-word restore: before it, the sender's string marker was overwritten
  and the next read trapped, exit 133);
* a substring result longer than one byte returned through two calls and compared afterwards (frame
  substring blocks, both helpers: `substring` and `substring_until_char`);
* `write_ref` of a pointer to a node of a younger frame into a ref cell of an older frame, then the
  younger frame returns and the older one reads the cell (the open hazard in §3 item 4: evacuation
  does not scan old ref cells; the trial should be staged as a known failure until it is fixed);
* the same with a heap shell (a record built in a behaviour and kept in state) that gets a young
  pointer written into a ref inside it;
* a non-adopting caller (main) and a behaviour each calling a function that returns a list built in
  its frame, in a loop of a few thousand iterations (frame growth stays bounded by evacuation).

### Golden refresh list (for the trial agents; only where `.sout` matches `.scout`)

* Every suite's `.ascomp` on all three hosted targets: the frame record is 32 bytes (AArch64) / two
  extra frame words (x86), every user call carries the pre/post-call SP lines, epilogues restore
  X29-relative and adopt, and the region-destroy / promote code changed. Expect drift in nearly every
  golden (`programmer_tools/update_goldens.sh` per platform).
* `__silica_runtime.ascomp` is not touched by these changes beyond the helpers emitted per module; refresh it
  only if it differs.
* `.scout` changes are NOT golden refreshes: the six validator trials and the `ref_in_region` trials
  listed above need new expectations or rewritten sources (P7 semantics), and the carriers heap-use
  trial needs a new measurement basis.

### Gate runs

(see §5)

## 5. Build / trial log

* S1-S6: 10 gate suites green (all run outputs match; only `.ascomp` drift); mirror memory_region 402/402.
* Full integrate after S6: 10,985 outputs match; ordered_data_structures ~150 run failures (wbt), the
  carriers heap_used trial, compile aborts from the `ref_in_region` trials; ffi app entries were `.ascomp` drift only.
* E4001 on a function whose body is one checked_int64 call (`fn f(a, b) -> (boolean, int64) {
  checked_int64_add(a, b) }`): `terms@expr_to_sir_function_body` decided "whole-body tail user call"
  with `terms_helpers@root_body_is_tail_user_call`, whose builtin list had fallen behind the kind-4
  dispatch (checked_int64, collection results, ordering identities, float specials/predicates,
  spawn_registered_supervisor, call_supervisor, device prims, actor_ref_equal, bnot/not). The body
  path now also asks `terms@call_lowers_as_builtin`, which mirrors the dispatch chain; shared front
  end, so all three targets. Covering trial: `memory_region_addition/frame_checked_pair_returned_through_two_calls`.
* S6c (old-aggregate in-place scan, queued once): wbt repro n=3 and n=30 green, evacuation harness green.
* Gate 4 (Mac, S6d + S7 except the scope-release removal): every gate suite run_FAIL=0 / other_FAIL=0;
  ordered_data_structures only the six P7 validator trials; mirror memory_region 402/402.
* nix (linux_x86_64, 999972 builder, final tree): ordered_data_structures only the six P7 validator
  trials; list 537, string 671, records 458, tuples 635, functions 666, recursive_function 326,
  deep_frame_spill 8, actors 361, supervisors 115 outputs match, run_FAIL=0 everywhere;
  memory_region_addition aborts at compile on the three `ref_in_region` trials (expected).
* pix (linux_aarch64, 999964 builder, tree before the scope-release removal): identical results to
  nix suite by suite (same six validator trials, same match counts, run_FAIL=0).
* Full Mac integrate (final tree, every suite): 11,276 `.ascomp` drifts and exactly seven `.scout`
  differences, all known: the six P7 validator trials and
  `carriers_addition/workers_two_field_record_return_at_arena_block_end` (heap-use measurement).
  The batch-compile aborts are the `ref_in_region` trials (compiler_addition, generic_modules_addition,
  memory_region_addition). No other run failure.
* ordered_data_structures with S6c: everything matches except the six validator trials above
  (P7 semantics) and two assemble failures (`search_tree_collections/ordered_set_field_projection`,
  `compiler_substrate/lib/type_interner`): the direct-call text lost its trailing newline when the
  post-call SP code was appended (`BL L_adopt    MOV X11, X0`). Fixed in `call.silica` (both trees).
* S7a: `aggregate_return_heap_promote_x0_copy` copies into a frame block (`L_dyn_alloc_src`, which
  re-bases a source in the moved transient area) instead of `_silica_rt_region_alloc`.

## 6. S8: promote-site removal (2026-10-26)

Lee's decision: build aggregates where they live from the start so the ~30 promote copies and their
slab pops go. All three trees carry the same change (x86 with its own instruction text).

**Why the promotes existed.** A `tuple_make` / `record_make` lives in a node-indexed fixed frame region
(X29-relative, `term_reg_spill@frame_region_for`), or a call result sat in an SP slab. Regions were
shared between sibling subtrees and slabs were popped at the end of a case arm, a let tail or the
epilogue, so a pointer that outlived either had to be copied out. With adopting epilogues and
evacuation the frame persists for the caller, so the copy is only needed where a region is reused
while the old value is still live.

**Region rules now** (`term_reg_spill@agg_subtree_bytes`, `agg_offset_for`, `agg_offsets_walk`):
a region may be shared only between the arms of a case (kind 7: one arm runs) and for the boxed head
of a `list_cons` (copied into the list block before anything else runs). A let reserves its RHS and
its body side by side (`own + let_sret_home_bytes + a + b`), so nothing a let binds is overwritten in
the same activation. `agg_persist_bytes*` and `agg_child_is_make` are gone.

**TCO loops with pointer parameters** (`keep_dynamic`) re-enter the same frame, so a fixed region
would be reused by the next iteration while the previous value is still reachable from a parameter.
Their bodies carry `|_dynagg=1` (`emitter_core`, when `tco_on` and not `tco_params_frame_free`):
each make takes a block from `L_dyn_alloc` (`term_aggregate_helpers@agg_dyn_block_asm`) and keeps its
address in the make's region slot; stores go through that slot (`*<slot>` base, X16 indirect,
`agg_indirect_base`, `agg_far_region`, `agg_addr_prefix`, `term_child_spec@hidden_field_store`), the
result is `agg_dyn_load`, and the binding is a pointer (`packs_escape` in let_top / let_named).

**Tuple-returning calls** get their X8 result buffer from `L_dyn_alloc` right before the call
(`term_emit_kind_call` `x8_alloc`; not for tail calls or FFI). No SP slab exists, so every slab size
(`flat_tuple_dealloc_size` and its callers) was 0 and has been deleted with its pops. Reply-form calls
take the buffer as `MOV breg, X8`. `L_dyn_alloc` now does `SUB X16, SP, X16` first and keeps X0-X15
and X17 (an indirect callee waits in X17 while the buffer is allocated).

**sret epilogue** (`emitter_core@sret_tuple_epilogue_copy`): with a buffer it copies into it; without
one (X8 was 0) the result stays where the body built it. The heap/frame promote branch is gone.

**Root cause found by the Pass A gate (`functions_addition/fn_tuple_nested`, printed 54 for 6).**
Kind-5 whole-body tail calls were emitted with `param_outer_emit_fnret`, which lacks `_broot`, so
`frame_region_for` saw no body root and gave every make region offset 0: the two nested tuple
arguments overwrote each other. The kind-5 body call now passes `body_outer_root` (all three trees).

**Pass B (dead code).** Removed: the promote/reclaim bindings in case, let_top, let_named_tail,
compound_part1 (tuple elements and record fields), the call argument promote and the staged-path
promote/reclaim in call_tail, the part2/part3 slab pops (`cons_dealloc`, `tuple_stack_bytes`,
`tuple_bytes`, `unary_sp_bytes`, `tuple_bytes_a`; their `[SP, #n]` reloads are `[SP]`),
`list_cons_join_tail_head_op`'s slab branch, the `arg_stack_bytes_before_call` field (always 0),
`L_dyn_alloc_src`, and 38 helpers nothing referenced any more (`esf_tuple_ret_promote/dealloc`, the
`tuple_return_*` / `sum_variant_*_promotes_in_epilogue` predicates, `aggregate_return_heap_promote_x0*`,
`arg_aggregate_heap_promote`, `tuple_elem_*_promote`, `frame_var_arg_promote`,
`let_early_heap_promote_asm`, `*_promote_bytes`, `*_stack_bytes`, `flat_record_dealloc_size`,
`let_owns_local_region`, `emit_region_destroy_reg`, ...). Kept: the actor heap promotes (phases 3/4).

**S8 verification status (2026-10-26, when this agent handed back).**
* Mac, Pass A tree (before the kind-5 `_broot` fix and Pass B): build green; E4001 repros green;
  run_FAIL=0 in recursive_function 326, records 458, tuples 635, list 537, string 671,
  deep_frame_spill 8, memory_region 423, carriers 37, actors 368, supervisors 115, generic_modules 11,
  ordered_data_structures (every run matched; the ❌ there are `.ascomp` drift); functions 665/666
  (`fn_tuple_nested`, fixed since). The 18 memory_region and 7 actors "no .ascomp" entries are new
  trials without goldens yet, not failures.
* Mac, final tree (kind-5 fix + Pass B): a Haiku build + the same suites was running under the build
  slot lock (`$SP/bisect_p7b.txt`, `$SP/p7b_trials/SUMMARY.txt`, repro `r_tn` must exit 6). Not yet verified.
* linux_aarch64 (pix) and linux_x86_64 (nix): the S8 diff is applied in the source trees but NOT
  built or gated on either host. Next: sync, touch the edited emitter sources on the host (rsync
  mtime trap), rebuild (pix builder 999964, nix builder 999972, `~/p2_remote_gate.sh`), run the suites below.

**S9: `actor_ref` is frame-free (2026-10-27).** `bees_regions_addition/bees_sd7_message_region_released`
faulted (exit 70, actor 0, fault address in the main stack's guard area) on pix and nix. Root cause:
`send_n(a: actor_ref, n: int64)` is a TCO loop; `reg_conventions@is_frame_free_scalar_type` did not
list `actor_ref`, so `tco_params_frame_free` was false and the restart stub kept the dynamic part
(`LDR X16, [X29, #16]; MOV SP, X16`). Each iteration's message, evacuated into send_n's frame after
`build_message` returned, was kept until the loop ended: about 90 bytes per cast, 100,000 casts, more
than main's 8 MB stack. The Mac code is identical and also faults with the default `ulimit -s 8176`
(checked by running the Mac trial binary: it needs a stack between 8 and 12 MB, so it passed only
where the harness ran it with a larger limit). Fix in all three trees: `actor_ref` names a runtime
control block, never a frame node, so it is frame-free. The restart now drops the iteration's
allocations, and calls returning `actor_ref` restore SP instead of adopting or evacuating. Assembly
changes wherever an `actor_ref` is a TCO parameter or a user-call result type, so the `.ascomp` and
`.linux_*.ascomp` goldens of the actor-using suites drift (actors, supervisors, bees_regions,
carriers, ordered_data_structures where actors appear, generic_modules if any; regenerate where
`.sout` matches `.scout`).

**`actors_addition/actor_call_after_abnormal_kill_returns_death` on pix after S9: a race that was already there, not a regression.**
For this trial S9 only removes two no-op heap walks of a WORD value: the killer's `actor_ref` state at
behaviour entry, and the spawn payload walk, with its `L_stack_top`/`pthread_getattr_np` call. The
only effect is timing. Ten runs each:

| Binary | Runs that print the echo's `(:explicit, :killed)` banner |
| --- | --- |
| Mac, old binary | 10/10 |
| pix, new compiler | 9/10 |
| pix, old assembly relinked | 8/10 |

When that banner is missing, the root exits through `restart_intensity_breach` before the killed
victim's banner is printed. The trial is unchanged.

**Suites to rerun on all three hosts** after S8: the gate list (functions, recursive_function,
records, tuples, list, string, deep_frame_spill), carriers, memory_region, actors, supervisors,
generic_modules, ordered_data_structures; and every `.ascomp` refresh (prologues, region offsets and
call sequences all changed).

## Appendix A. Evacuation routine source

`prims_memory@emit_evacuation_helper` is this text with comments stripped (regenerated by a script;
the ELF variant only renames `_silica_rt_region_alloc`). Keep this appendix in step when editing it.

```
// L_ev_frame / L_ev_heap draft (chunk 15 phase 2, design §3.5). See Phase2_notes.md.
// L_ev_frame: X0 value, X1 kind, X2 aux, X3 hi (pre-call SP), X4 F (caller floor)
//   -> X0 new value, X1 new floor, SP = new SP (hi - k). New nodes are [entry SP, hi).
// L_ev_heap:  X0 value, X1 kind, X2 aux, X3 hi -> X0 new value; nodes in [entry SP, hi) are
//   copied into _silica_rt_region_alloc blocks; SP unchanged.
// L_ev_heap_shell: as L_ev_heap, but an aggregate root stays where it is (its words are evacuated in
//   place): the caller copies the shell itself (a behaviour's state and reply moves).
L_ev_heap_shell:
    MOV X5, #1
    MOV X6, #1
    B L_ev_common
L_ev_heap:
    MOV X5, #1
    MOV X6, #0
    B L_ev_common
L_ev_frame:
    MOV X5, #0
    MOV X6, #0
L_ev_common:
    STP X29, X30, [SP, #-192]!
    MOV X29, SP
    STP X19, X20, [SP, #16]
    STP X21, X22, [SP, #32]
    STP X23, X24, [SP, #48]
    STP X25, X26, [SP, #64]
    STP X27, X28, [SP, #80]
    ADD X19, X29, #192
    MOV X20, X3
    MOV X26, X4
    MOV X21, X4
    MOV X22, X5
    MOV X24, SP
    STP X0, X1, [X29, #144]
    STR X2, [X29, #160]
    CBNZ X6, Lev_root_shell
    // An old root (the caller's sret home, a heap shell) is queued by L_evw to be scanned in place.
    BL L_evw
    STR X0, [X29, #128]
    B Lev_root_done
Lev_root_shell:
    // Shell mode: the root is new but stays where it is; its fields are evacuated in place.
    STR X0, [X29, #128]
    LDP X9, X1, [X29, #144]
    LDR X2, [X29, #160]
    CMP X0, X9
    B.NE Lev_root_done
    MOV X10, #65536
    CMP X9, X10
    B.LO Lev_root_done
    CMP X1, #5
    B.NE Lev_root_agg
    LDR X10, [X9]
    LDR X11, [X2]
    MVN X11, X11
    ADD X12, X2, #8
Lev_root_sum:
    CBZ X11, Lev_root_done
    LDP X13, X14, [X12], #16
    SUB X11, X11, #1
    CMP X13, X10
    B.NE Lev_root_sum
    MOV X1, #4
    MOV X2, X14
Lev_root_agg:
    CMP X1, #4
    B.NE Lev_root_done
    MOV X0, X9
    MOV X1, X2
    BL Lev_words
Lev_root_done:
    MOV X23, X24
Lev_scan:
    MOV X9, SP
    CMP X23, X9
    B.LS Lev_scan_done
    LDP X10, X11, [X23, #-48]
    LDP X12, X13, [X23, #-32]
    LDP X14, X15, [X23, #-16]
    SUB X16, X23, #48
    SUB X16, X16, X15
    CMP X15, #0
    CSEL X16, X16, X11, NE
    SUB X23, X23, #48
    SUB X23, X23, X15
    CMP X12, #4
    B.EQ Lev_s_agg
    CMP X12, #3
    B.EQ Lev_s_reftup
    CMP X12, #2
    B.EQ Lev_s_ref1
    CMP X12, #7
    B.EQ Lev_s_handle
    CMP X12, #17
    B.EQ Lev_s_chunk
    B Lev_scan
Lev_s_agg:
    MOV X0, X16
    MOV X1, X13
    BL Lev_words
    B Lev_scan
Lev_s_reftup:
    ADD X0, X16, #8
    MOV X1, X13
    BL Lev_words
    B Lev_scan
Lev_s_ref1:
    MOV X0, X16
    MOV X1, X13
    BL Lev_words
    B Lev_scan
Lev_s_handle:
    STR X16, [X29, #144]
    LDR X0, [X16, #8]
    MOV X1, #17
    MOV X2, X13
    BL L_evw
    LDR X16, [X29, #144]
    STR X0, [X16, #8]
    B Lev_scan
Lev_s_chunk:
    STR X16, [X29, #144]
    STR X13, [X29, #152]
    LDR X9, [X13, #8]
    MOV X10, #16
    CMP X9, X10
    CSEL X10, X9, X10, HI
    STR X10, [X29, #168]
    ADD X11, X16, X10
    LDR X12, [X11, #8]
    STR X12, [X29, #160]
    LDP X1, X2, [X13, #16]
    CMP X1, #0
    B.EQ Lev_sc_next
    CMP X1, #1
    B.EQ Lev_sc_next
    CMP X1, #9
    B.EQ Lev_sc_next
Lev_sc_loop:
    LDR X9, [X29, #160]
    LDR X10, [X29, #168]
    CMP X9, X10
    B.HS Lev_sc_next
    LDR X13, [X29, #152]
    LDR X11, [X13, #8]
    ADD X12, X9, X11
    STR X12, [X29, #160]
    STR X9, [X29, #176]
    LDR X16, [X29, #144]
    LDP X1, X2, [X13, #16]
    CMP X11, #8
    B.HI Lev_sc_inline
    LDR X0, [X16, X9]
    BL L_evw
    LDR X16, [X29, #144]
    LDR X9, [X29, #176]
    STR X0, [X16, X9]
    B Lev_sc_loop
Lev_sc_inline:
    CMP X1, #4
    B.NE Lev_sc_loop
    ADD X0, X16, X9
    MOV X1, X2
    BL Lev_words
    B Lev_sc_loop
Lev_sc_next:
    LDR X16, [X29, #144]
    LDR X10, [X29, #168]
    LDR X0, [X16, X10]
    MOV X1, #17
    LDR X2, [X29, #152]
    BL L_evw
    LDR X16, [X29, #144]
    LDR X10, [X29, #168]
    STR X0, [X16, X10]
    B Lev_scan
Lev_scan_done:
    LDR X0, [X29, #128]
    CBNZ X22, Lev_heap_done
    SUB X9, X26, X21
    MOV X10, X20
    MOV X11, X26
    MOV X12, X24
    MOV X13, SP
    SUB X14, X10, X9
    CMP X12, X14
    B.LS Lev_f_noshift
    SUB X15, X12, X14
    ADD X15, X15, #15
    AND X15, X15, #0xfffffffffffffff0
    SUB X16, X13, X15
    MOV SP, X16
    MOV X17, X13
Lev_f_shift:
    CMP X17, X12
    B.HS Lev_f_shifted
    LDR X8, [X17], #8
    STR X8, [X16], #8
    B Lev_f_shift
Lev_f_shifted:
    SUB X12, X12, X15
    SUB X13, X13, X15
Lev_f_noshift:
    LDP X19, X20, [X29, #16]
    LDP X21, X22, [X29, #32]
    LDP X23, X24, [X29, #48]
    LDP X25, X26, [X29, #64]
    LDP X27, X28, [X29, #80]
    LDP X29, X30, [X29]
    MOV X15, X10
    MOV X16, X14
Lev_f_tmove:
    CMP X15, X11
    B.HS Lev_f_tmoved
    LDR X17, [X15], #8
    STR X17, [X16], #8
    B Lev_f_tmove
Lev_f_tmoved:
    MOV X15, X12
Lev_f_body:
    CMP X15, X13
    B.LS Lev_f_done
    LDP X1, X2, [X15, #-48]
    LDP X3, X4, [X15, #-16]
    SUB X15, X15, #48
    SUB X15, X15, X4
    ADD X3, X3, #7
    AND X3, X3, #0xfffffffffffffff8
    MOV X5, #0
Lev_f_copy:
    CMP X5, X3
    B.HS Lev_f_body
    LDR X6, [X15, X5]
    STR X6, [X2, X5]
    ADD X5, X5, #8
    B Lev_f_copy
Lev_f_done:
    MOV SP, X14
    SUB X1, X11, X9
    RET
Lev_heap_done:
    MOV X9, X29
    LDP X19, X20, [X9, #16]
    LDP X21, X22, [X9, #32]
    LDP X23, X24, [X9, #48]
    LDP X25, X26, [X9, #64]
    LDP X27, X28, [X9, #80]
    LDP X29, X30, [X9]
    ADD X9, X9, #192
    MOV SP, X9
    RET
// Lev_words(X0 = base, X1 = aggregate descriptor): every pointer word of the aggregate at base is
// replaced by its evacuated value. Uses the locals #96..#136 of L_ev's frame (X29).
Lev_words:
    STR X30, [X29, #136]
    STR X0, [X29, #96]
    STR X1, [X29, #104]
    LDR X9, [X1]
    STR X9, [X29, #120]
    STR XZR, [X29, #112]
Lev_w_loop:
    LDR X9, [X29, #112]
    LDR X10, [X29, #120]
    CMP X9, X10
    B.HS Lev_w_done
    LDR X11, [X29, #104]
    ADD X11, X11, #16
    ADD X11, X11, X9, LSL #4
    LDP X1, X2, [X11]
    ADD X12, X9, #1
    STR X12, [X29, #112]
    CMP X1, #0
    B.EQ Lev_w_loop
    CMP X1, #1
    B.EQ Lev_w_loop
    CMP X1, #9
    B.EQ Lev_w_loop
    LDR X12, [X29, #96]
    LDR X0, [X12, X9, LSL #3]
    BL L_evw
    LDR X12, [X29, #96]
    LDR X9, [X29, #112]
    SUB X9, X9, #1
    LDR X10, [X12, X9, LSL #3]
    CMP X10, X0
    B.EQ Lev_w_loop
    STR X0, [X12, X9, LSL #3]
    B Lev_w_loop
Lev_w_done:
    LDR X30, [X29, #136]
    RET
// L_evw(X0 = word, X1 = kind, X2 = aux) -> X0: the word's value after evacuation. A word that is
// not a pointer kind, an atom, or outside [lo, hi) is returned unchanged; a node already copied
// is found by its forwarding word (bit 63 set over the copy's final address).
L_evw:
    MOV X28, X30
    CMP X1, #0
    B.EQ Lw_ret
    CMP X1, #1
    B.EQ Lw_ret
    CMP X1, #9
    B.EQ Lw_ret
    MOV X9, #65536
    CMP X0, X9
    B.LO Lw_ret
    CMP X0, X19
    B.LO Lw_old
    CMP X0, X20
    B.HS Lw_old
    CMP X1, #5
    B.NE Lw_kind
    LDR X9, [X0]
    LDR X10, [X2]
    MVN X10, X10
    ADD X11, X2, #8
Lw_sum:
    CBZ X10, Lw_ret
    LDP X12, X13, [X11], #16
    SUB X10, X10, #1
    CMP X12, X9
    B.NE Lw_sum
    MOV X1, #4
    MOV X2, X13
Lw_kind:
    CMP X1, #4
    B.EQ Lw_agg
    CMP X1, #3
    B.EQ Lw_reftup
    CMP X1, #2
    B.EQ Lw_ref1
    CMP X1, #6
    B.EQ Lw_buf
    CMP X1, #7
    B.EQ Lw_handle
    CMP X1, #17
    B.EQ Lw_chunk
    CMP X1, #8
    B.EQ Lw_string
Lw_ret:
    RET X28
// An aggregate outside [lo, hi) -- a shell an older promotion copied to the heap, an older frame's
// record -- may still hold words that name new nodes: it is queued to be scanned where it lies (an
// entry with no scratch body, final = itself, size 0, so the placement pass copies nothing). It is
// queued once: its words are rewritten to final addresses, which lie where sources lie, so a second
// scan would take them for new nodes. A word
// in [SP, lo) names the dead stack under the callee, where this routine's own frame and scratch live:
// it is left alone.
Lw_old:
    MOV X9, SP
    CMP X0, X9
    B.LO Lw_old_ok
    CMP X0, X19
    B.LO Lw_ret
Lw_old_ok:
    CMP X1, #4
    B.EQ Lw_old_agg
    CMP X1, #5
    B.NE Lw_ret
    LDR X9, [X0]
    LDR X10, [X2]
    MVN X10, X10
    ADD X11, X2, #8
Lw_old_sum:
    CBZ X10, Lw_ret
    LDP X12, X13, [X11], #16
    SUB X10, X10, #1
    CMP X12, X9
    B.NE Lw_old_sum
    MOV X2, X13
Lw_old_agg:
    MOV X10, X24
Lw_old_seen:
    MOV X9, SP
    CMP X10, X9
    B.LS Lw_old_new
    LDP X11, X12, [X10, #-16]
    LDR X13, [X10, #-48]
    SUB X10, X10, #48
    SUB X10, X10, X12
    CBNZ X12, Lw_old_seen
    CBNZ X11, Lw_old_seen
    CMP X13, X0
    B.NE Lw_old_seen
    RET X28
Lw_old_new:
    SUB SP, SP, #48
    MOV X11, SP
    STP X0, X0, [X11]
    MOV X9, #4
    STP X9, X2, [X11, #16]
    STP XZR, XZR, [X11, #32]
    RET X28
Lw_fwd:
    AND X0, X9, #0x7fffffffffffffff
    RET X28
Lw_agg:
    LDR X3, [X2]
    LSL X3, X3, #3
    BL Lw_copy
    MOV X0, X5
    RET X28
Lw_reftup:
    LDR X9, [X0]
    TBNZ X9, #63, Lw_fwd
    LDR X3, [X2]
    LSL X3, X3, #3
    ADD X3, X3, #8
    BL Lw_copy
    ADD X9, X5, #8
    STR X9, [X6]
    ORR X9, X5, #0x8000000000000000
    STR X9, [X0]
    MOV X0, X5
    RET X28
Lw_ref1:
    LDR X9, [X0, #8]
    TBNZ X9, #63, Lw_fwd
    MOV X3, #16
    BL Lw_copy
    STR XZR, [X6, #8]
    ORR X9, X5, #0x8000000000000000
    STR X9, [X0, #8]
    MOV X0, X5
    RET X28
Lw_buf:
    LDR X9, [X0, #-8]
    TBZ X9, #63, Lw_buf_copy
    AND X9, X9, #0x7fffffffffffffff
    ADD X0, X9, #8
    RET X28
Lw_buf_copy:
    MUL X3, X9, X2
    ADD X3, X3, #15
    AND X3, X3, #0xfffffffffffffff8
    SUB X0, X0, #8
    BL Lw_copy
    ORR X9, X5, #0x8000000000000000
    STR X9, [X0]
    ADD X0, X5, #8
    RET X28
Lw_handle:
    LDR X9, [X0]
    TBNZ X9, #63, Lw_fwd
    MOV X3, #24
    BL Lw_copy
    ORR X9, X5, #0x8000000000000000
    STR X9, [X0]
    MOV X0, X5
    RET X28
Lw_chunk:
    LDR X9, [X2, #8]
    MOV X10, #16
    CMP X9, X10
    CSEL X10, X9, X10, HI
    ADD X11, X0, X10
    LDR X9, [X11, #8]
    TBNZ X9, #63, Lw_fwd
    ADD X3, X10, #16
    BL Lw_copy
    LDR X9, [X2, #8]
    MOV X10, #16
    CMP X9, X10
    CSEL X10, X9, X10, HI
    ADD X11, X0, X10
    ORR X9, X5, #0x8000000000000000
    STR X9, [X11, #8]
    MOV X0, X5
    RET X28
Lw_string:
    LDR X9, [X0]
    CMN X9, #1
    B.EQ Lw_str_copy
    TBZ X9, #63, Lw_ret
    CMN X9, #2
    B.EQ Lw_ret
    B Lw_fwd
Lw_str_copy:
    LDR X3, [X0, #16]
    ADD X3, X3, #25
    BL Lw_copy
    LDR X9, [X0, #8]
    ADD X10, X0, #24
    CMP X9, X10
    B.EQ Lw_str_fix
    LDR X11, [X0, #16]
    ADD X11, X11, #1
    ADD X12, X6, #24
Lw_str_bytes:
    CBZ X11, Lw_str_fix
    LDRB W13, [X9], #1
    STRB W13, [X12], #1
    SUB X11, X11, #1
    B Lw_str_bytes
Lw_str_fix:
    MOV X9, X5
    BL L_str_forget
    ADD X9, X5, #24
    STR X9, [X6, #8]
    ORR X9, X5, #0x8000000000000000
    STR X9, [X0]
    MOV X0, X5
    RET X28
// Lw_copy(X0 = source block, X1 = kind, X2 = aux, X3 = bytes) -> X5 = final address, X6 = the copy
// to edit (the scratch body in frame mode, the heap block in heap mode). X0-X3 are kept. Records an
// entry {src, final, kind, aux, size, scratch body size} at the top of a new scratch block.
Lw_copy:
    MOV X27, X30
    ADD X7, X3, #7
    AND X7, X7, #0xfffffffffffffff8
    CBNZ X22, Lw_copy_heap
    ADD X8, X3, #15
    AND X8, X8, #0xfffffffffffffff0
    SUB X21, X21, X8
    MOV X5, X21
    ADD X9, X8, #48
    MOV X10, SP
    SUB X10, X10, X9
    MOV SP, X10
    MOV X6, X10
    ADD X11, X10, X8
    STP X0, X5, [X11]
    STP X1, X2, [X11, #16]
    STP X3, X8, [X11, #32]
    B Lw_copy_bytes
Lw_copy_heap:
    STP X0, X1, [SP, #-48]!
    STP X2, X3, [SP, #16]
    STR X7, [SP, #32]
    MOV X0, X7
    BL L_ev_region_alloc
    MOV X5, X0
    LDR X7, [SP, #32]
    LDP X2, X3, [SP, #16]
    LDP X0, X1, [SP], #48
    MOV X6, X5
    SUB SP, SP, #48
    MOV X11, SP
    STP X0, X5, [X11]
    STP X1, X2, [X11, #16]
    STP X3, XZR, [X11, #32]
Lw_copy_bytes:
    MOV X12, #0
Lw_copy_loop:
    CMP X12, X7
    B.HS Lw_copy_done
    LDR X13, [X0, X12]
    STR X13, [X6, X12]
    ADD X12, X12, #8
    B Lw_copy_loop
Lw_copy_done:
    RET X27
```

## Trial agent requests (written by the trial-sources agent, 2026-10-26; for a Haiku agent)

Nothing below has been run: the sources were written by hand and are unverified. `$P2` is the phase 2 Mac
compiler the main session names (not the phase 1 `binaries/silica-compiler`, which still accepts
`ref_in_region`). Run on the Mac only (one build at a time; do not run while Lee's build runs). The harness
ignores `SILICA_COMPILER` from the environment: pass it on the make command line. For every item report the
real output verbatim; DO NOT edit any `.scout`, `.golden_fail` or source to make a trial pass, and do not
touch `.ascomp`.

### R1. The eight rewritten `ref_in_region` trials (must compile and print their `.scout`)

From `/Volumes/2T/silica/trials`: `make integrate TRIAL_TARGET=host SILICA_COMPILER=$P2 TRIAL_SUITES=memory_region_addition`
(then `compiler_addition`, `generic_modules_addition`). Report: does each suite now compile as a batch (no
abort), and per trial the output diff against `.scout`:

* `memory_region_addition/canonical_arena_survives_owning_callee` (want 1 7 1 35 0)
* `memory_region_addition/record_bind_after_destructures` (want 1111 / 1111)
* `memory_region_addition/region_param_threaded_through_ref_query` (want 1111 / 1111)
* `compiler_addition/region_grow` (want 42)
* `generic_modules_addition/wbt_set` (only `in_arena` changed to `true`)
* staged, not harness-compiled, run by hand per the header of each file:
  `ordered_data_structures/binary_tree_core/staged/record_bind_after_destructures` (want 1111 twice) and
  `.../staged/region_param_destroyed_after_ref_in_region` (want 1111 twice; it needs a `main` + `use`-less build as its header says)
* `ordered_data_structures/tree_collections/rt_direct_constructor_binding` (comment-only change: want 7 1 7 0)

### R2. Validator trials and carriers (new expectations, source changed)

`make integrate TRIAL_TARGET=host SILICA_COMPILER=$P2 TRIAL_SUITES=ordered_data_structures` and
`TRIAL_SUITES=carriers_addition`. Report the output of exactly these, against the new `.scout`:

| trial | change | new `.scout` |
| --- | --- | --- |
| `wbt_core/wbt_validate_malformed_fixture` | wrong-arena fixture and `a6` removed | `6` |
| `tree_collections/rt_validate` | `arena_cases`, `foreign_arena` removed, cycle/missing is group 6 | unchanged (ends with `0`) |
| `skew_ral_core/ral_validate_invariants` | `arena_case` removed, repeat group is 6 | unchanged (`0`) |
| `graph_live_core/gl_validate` | `mixed_arena` removed | the `mixed_arena 2000` line deleted |
| `brodal_okasaki_core/bo_validate_invariants` | wrong-arena case removed, `missing_case` kept | unchanged (`0`) |
| `binary_tree_core/bt_validate` | `wrong_arena` fixture, line and group removed | the `wrong_arena` / `2` lines deleted |
| `carriers_addition/workers_two_field_record_return_at_arena_block_end` | heap-use byte counting and the fill loop removed | unchanged (`9`, the failure banner of removed worker b, `3`, `0`) |

If a `.sout` differs from the new `.scout`, report the diff and stop (the main session decides whether the
source or the expectation is wrong).

### R3. New positive trials (first run: compile + output only)

All are new `.silica` + `.scout` pairs; the suites regenerate `silica.config` with `find`. Run the suite and
report, per trial, compile errors verbatim or the output diff. A compile error in one of these aborts its
suite's batch: if that happens, move the offending pair out of the suite directory (to the scratchpad), say
which, and rerun the rest.

* `memory_region_addition/`: `alloc_ref_regionless_in_function`, `alloc_ref_regionless_in_main`,
  `alloc_rec_regionless_three_word_tuple`, `alloc_buf_regionless_fill_readback`, `frame_adopt_chain_record`,
  `frame_adopt_chain_list`, `frame_adopt_chain_string`, `frame_evacuate_shared_node_twice`,
  `frame_evacuate_list_of_strings`, `frame_evacuate_sum_with_record_variant`, `frame_tco_cons_onto_list_parameter`,
  `frame_tail_call_argument_names_frame_node`, `frame_list_prepend_onto_older_frame_scalar`,
  `frame_list_prepend_onto_older_frame_string`, `frame_string_concat_reuse_with_substring_cache`,
  `frame_substring_result_returned_through_two_calls`, `frame_checked_pair_returned_through_two_calls`,
  `frame_bounded_growth_list_loop_in_main`
* `actors_addition/`: `behaviour_reply_frame_built_string`, `behaviour_state_frame_built_record`,
  `behaviour_state_frame_built_list`, `call_payload_frame_built_string_sender_rereads`,
  `call_payload_frame_built_list_sender_rereads`, `spawn_payload_frame_built_string_sender_rereads`,
  `behaviour_frame_built_list_loop_bounded` (the actor ones may print a failure banner only if something fails)
* `ordered_data_structures/wbt_core/wbt_set_insert_three_validate` (want 3 1 3 0)

Known risks to report on, not to fix: (1) whether `alloc_ref(v)` / `alloc_rec((..))` / `alloc_buf(n)` accept the
annotation `ref(L1, normal, ...)` with `L1: lifetime <- fresh_lifetime()` in a function and in `main`; (2) the
`nothing: ref?(...) <- :none` binding and a `ref` passed in a tuple literal's `ref?` slot; (3) the unused `n`
binding in the `case link of` arm of `alloc_rec_regionless_three_word_tuple`; (4) string `==` in the
`frame_string_*` trials; (5) a state/reply that is a `string`, a record or a list in the three `behaviour_*` trials;
(6) names `sum_list`, `run_loop`, `first_word`, `extend`, `grow`, `build`, `scrub`, `twin`: if E2020 (builtin-name
ambiguity) fires on one, report it.

### R4. New error trials (need goldens)

`error_enforcement_addition/alloc_ref_regionless_non_ref_binding.silica`,
`alloc_rec_regionless_non_ref_binding.silica` (expected E2010, "alloc_ref/alloc_rec result must be ref(R, Space, T)")
and `alloc_buf_regionless_literal_size_mismatch.silica` (expected E2313). They have no `.golden_fail` yet.
Run `make -C /Volumes/2T/silica/trials/error_enforcement_addition SILICA_COMPILER=$P2` (single-file rule) or compile each
file the way the Makefile does, and report each `.cur_fail` verbatim. If the error code is the expected one and the
position is on the allocation call, the main session copies `.cur_fail` to `.golden_fail` (error goldens are derived
from real output); if it is a different code, report and stop.

### R5. Open hazard trials (expected to FAIL; the point is the observed output)

`region_hazards_open_addition/write_ref_young_into_older_cell` (want 7 then 0; expected to print a stale number, -1 or
fault). Run by hand as the suite README says (`make -C region_hazards_open_addition integrate TRIAL_TARGET=host
SILICA_COMPILER=$P2`, from `trials/`). Report the observed output and record it in the README row.
`write_ref_young_into_heap_shell_ref.silica` is NOT in the suite's `silica.config` (it may not compile): compile it by hand
in a scratch directory first (see the header of `reply_after_callee_ended.silica` for the by-hand recipe); only if it compiles,
add it to `silica.config` and report its output (want 0, 7, 0).

### R6. Golden refresh (after R1-R5 are settled)

`.ascomp` refresh on the Mac for every suite whose `.sout == .scout`, per the "Golden refresh list" above
(`programmer_tools/update_goldens.sh`); do not refresh any suite that still has a `.sout != .scout` trial. Linux hosts: nix
(x86-64) and pix (aarch64) get the same sources by `sync_to_hosts.sh`; remember §3 item 5 (touch edited sources on the host).
